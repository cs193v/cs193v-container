#!/usr/bin/env python3
# TIER: unit
#
# Unit and end-to-end tests for files/ports, the in-container diagnostic.
#
# It exists because a fixed published port range has exactly two failure modes and BOTH
# are invisible from inside the container, so this is the tool standing between a student
# and a lost afternoon. Two things get tested:
#
#   * the parsers, against captured /proc/net/tcp{,6} fixtures — including the IPv6 case,
#     which used to print 32 raw hex digits at the student in the single most common
#     failure situation (a server told to bind "localhost" binds ::1 on a dual-stack box).
#   * the whole command, against real sockets bound on this machine, asserting each of the
#     four states it claims to diagnose.
#
# Results are appended to $CS193V_RESULTS in the same format the shell suites use, so
# run-tests.sh aggregates all tiers together.

import importlib.util
import os
import socket
import subprocess
import sys
import unittest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TESTS_DIR)
PORTS_BIN = os.path.join(REPO, "files", "ports")

# files/ports has no .py extension by design — it is installed as a command — so load it
# by path rather than importing it.
#
# dont_write_bytecode first: SourceFileLoader would otherwise drop a files/__pycache__
# next to the source, which shows up as untracked cruft in the course repo and would get
# shipped to every student inside the install tarball.
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_loader(
    "cs193v_ports", importlib.machinery.SourceFileLoader("cs193v_ports", PORTS_BIN))
ports = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ports)

COURSE_PORTS = "3000-3009,4173-4176,5173-5179,6173-6182,8000-8009,8080-8084"


def proc_line(hex_addr, hex_port, state="0A"):
    """One /proc/net/tcp row. Only fields 1 and 3 are read, but keep the real shape."""
    return ("   0: %s:%s 00000000:0000 %s 00000000:00000000 00:00000000 00000000 "
            "1000 0 12345 1 0000000000000000 100 0 0 10 0" % (hex_addr, hex_port, state))


def write_proc(tmpdir, v4_rows=(), v6_rows=()):
    header = ("  sl  local_address rem_address   st tx_queue rx_queue tr tm->when "
              "retrnsmt   uid  timeout inode\n")
    p4 = os.path.join(tmpdir, "tcp")
    p6 = os.path.join(tmpdir, "tcp6")
    open(p4, "w").write(header + "".join(r + "\n" for r in v4_rows))
    open(p6, "w").write(header + "".join(r + "\n" for r in v6_rows))
    return ((p4, False), (p6, True))


class TestParseRanges(unittest.TestCase):
    def test_single_range(self):
        self.assertEqual(ports.parse_ranges("3000-3009"), [(3000, 3009)])

    def test_bare_port(self):
        self.assertEqual(ports.parse_ranges("8888"), [(8888, 8888)])

    def test_the_real_course_spec(self):
        r = ports.parse_ranges(COURSE_PORTS)
        self.assertEqual(len(r), 6)
        # The count students are told about, and what container.args publishes.
        self.assertEqual(sum(hi - lo + 1 for lo, hi in r), 46)

    def test_whitespace_and_empty_chunks(self):
        self.assertEqual(ports.parse_ranges(" 3000-3001 , , 8888 "),
                         [(3000, 3001), (8888, 8888)])


class TestPublished(unittest.TestCase):
    def setUp(self):
        self.r = ports.parse_ranges(COURSE_PORTS)

    def test_inclusive_at_both_ends(self):
        for p in (3000, 3009, 5173, 5179, 8080, 8084):
            self.assertTrue(ports.published(p, self.r), p)

    def test_just_outside(self):
        # 5180 is the first port vite's auto-increment can reach that is NOT published.
        for p in (2999, 3010, 5172, 5180, 8085, 4000, 7000, 5000):
            self.assertFalse(ports.published(p, self.r), p)


class TestDecodeV4(unittest.TestCase):
    def test_loopback(self):
        self.assertEqual(ports.decode_v4("0100007F"), "127.0.0.1")

    def test_wildcard(self):
        self.assertEqual(ports.decode_v4("00000000"), "0.0.0.0")

    def test_systemd_resolved_stub(self):
        self.assertEqual(ports.decode_v4("3500007F"), "127.0.0.53")

    def test_a_lan_address(self):
        self.assertEqual(ports.decode_v4("0A01A8C0"), "192.168.1.10")


class TestDecodeV6(unittest.TestCase):
    """The regression this whole class exists for.

    A server told to bind "localhost" in a dual-stack container binds ::1. That is the
    most common way to land in the "my browser can't see it" situation, and the tool used
    to answer with `[00000000000000000000000001000000]`, which also broke the column
    alignment of every row after it.
    """

    def test_loopback_is_not_raw_hex(self):
        got = ports.decode_v6("00000000000000000000000001000000")
        self.assertEqual(got, "::1")
        self.assertNotIn("0000", got)

    def test_wildcard(self):
        self.assertEqual(ports.decode_v6("0" * 32), "::")

    def test_v4_mapped_is_unwrapped(self):
        # ::ffff:127.0.0.1 — what a dual-stack listener on an IPv4 address looks like.
        self.assertEqual(ports.decode_v6("0000000000000000FFFF00000100007F"), "127.0.0.1")

    def test_link_local(self):
        # Word-order matters as much as byte-order: each 32-bit word is little-endian, but
        # the four words are in network order. Getting only one of those right still yields
        # a plausible-looking address, so assert an exact known pair.
        self.assertEqual(ports.decode_v6("000080FE000000000000000001000000"), "fe80::1")
        self.assertEqual(ports.decode_v6("000080FE00000000FF57000001000000"),
                         "fe80::57ff:0:1")

    def test_malformed_input_falls_back_instead_of_crashing(self):
        # A garbled row must not take the whole diagnostic down with it.
        self.assertEqual(ports.decode_v6("nonsense"), "nonsense")
        self.assertEqual(ports.decode_v6(""), "")


class TestSuggest(unittest.TestCase):
    def setUp(self):
        self.r = ports.parse_ranges(COURSE_PORTS)

    def test_auto_increment_overflow_points_back_at_its_range(self):
        # vite walks 5173 -> 5179 and can step past the end; the fix is that range.
        self.assertEqual(ports.suggest(5180, self.r), "5173-5179")
        self.assertEqual(ports.suggest(3010, self.r), "3000-3009")

    def test_a_freely_chosen_port_gets_no_false_precision(self):
        for p in (4000, 9100, 1234):
            self.assertIn("published ranges", ports.suggest(p, self.r))

    def test_no_ranges_at_all(self):
        self.assertIn("published", ports.suggest(3000, []))


class TestListenersFromFixtures(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.mkdtemp()

    def test_only_listening_sockets_are_reported(self):
        paths = write_proc(self.tmp, v4_rows=[
            proc_line("00000000", "0BB8", "0A"),   # 3000 LISTEN
            proc_line("00000000", "0BB9", "01"),   # 3001 ESTABLISHED, must be ignored
        ])
        self.assertEqual(ports.listeners(paths), {(3000, "0.0.0.0", True)})

    def test_wildcard_and_loopback_v4(self):
        paths = write_proc(self.tmp, v4_rows=[
            proc_line("00000000", "0BB8"),         # 0.0.0.0:3000
            proc_line("0100007F", "0BB9"),         # 127.0.0.1:3001
        ])
        self.assertEqual(ports.listeners(paths),
                         {(3000, "0.0.0.0", True), (3001, "127.0.0.1", False)})

    def test_v6_loopback_is_not_wildcard(self):
        paths = write_proc(self.tmp, v6_rows=[
            proc_line("00000000000000000000000001000000", "1442"),   # [::1]:5186
        ])
        self.assertEqual(ports.listeners(paths), {(5186, "::1", False)})

    def test_v6_wildcard_is_wildcard(self):
        paths = write_proc(self.tmp, v6_rows=[proc_line("0" * 32, "1442")])
        self.assertEqual(ports.listeners(paths), {(5186, "::", True)})

    def test_v4_mapped_wildcard_counts_as_wildcard(self):
        # A node server on :: reported as ::ffff:0.0.0.0 still accepts every interface.
        paths = write_proc(self.tmp, v6_rows=[
            proc_line("0000000000000000FFFF000000000000", "1442")])
        self.assertEqual(ports.listeners(paths), {(5186, "0.0.0.0", True)})

    def test_missing_proc_files_are_survivable(self):
        self.assertEqual(ports.listeners((("/nonexistent/tcp", False),)), set())

    def test_truncated_row_is_skipped(self):
        import tempfile
        p = os.path.join(self.tmp, "short")
        open(p, "w").write("header\n   0: 00000000:0BB8\n")
        self.assertEqual(ports.listeners(((p, False),)), set())


class TestEndToEnd(unittest.TestCase):
    """Run the real command against real sockets, and assert on what a student reads."""

    @classmethod
    def setUpClass(cls):
        cls.socks = []

        def listen(family, addr, port):
            s = socket.socket(family, socket.SOCK_STREAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if family == socket.AF_INET6:
                try:
                    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                except OSError:
                    pass
            s.bind((addr, port))
            s.listen(5)
            cls.socks.append(s)
            return s

        # One socket per state the tool claims to diagnose. The bind address no longer decides
        # reachability for IPv4 -- the tunnel's far end is the container's own loopback, so
        # 127.0.0.1 and 0.0.0.0 both work -- so what is left is the PORT, plus the one bind
        # address that still cannot be reached, ::1.
        listen(socket.AF_INET, "0.0.0.0", 3007)      # forwarded + wildcard -> OK
        listen(socket.AF_INET, "127.0.0.1", 3008)    # forwarded + loopback -> OK (was UNREACHABLE)
        listen(socket.AF_INET, "0.0.0.0", 4007)      # not forwarded        -> NOT FORWARDED
        listen(socket.AF_INET, "127.0.0.1", 4008)    # not forwarded        -> NOT FORWARDED
        listen(socket.AF_INET, "0.0.0.0", 5180)      # just past vite's range
        # The IPv6 case, on a FORWARDED port. Two things are asserted about it: that the
        # address renders readably rather than as 32 hex digits (the original regression), and
        # that it is still called out -- an ssh -L whose far end is 127.0.0.1 cannot reach an
        # IPv6-only listener, so this is the last remaining bind-address failure.
        cls.have_v6 = True
        try:
            listen(socket.AF_INET6, "::1", 5177)
        except OSError:
            cls.have_v6 = False

        env = dict(os.environ, CS193V_PORTS=COURSE_PORTS)
        r = subprocess.run([sys.executable, PORTS_BIN], capture_output=True, text=True,
                           env=env)
        cls.out, cls.rc = r.stdout, r.returncode
        cls.rows = {}
        for line in cls.out.splitlines():
            f = line.split()
            if len(f) >= 3 and f[0].isdigit():
                cls.rows[int(f[0])] = line

    @classmethod
    def tearDownClass(cls):
        for s in cls.socks:
            s.close()

    def test_published_wildcard_is_OK_with_a_clickable_url(self):
        self.assertIn("OK", self.rows[3007])
        self.assertIn("http://localhost:3007/", self.rows[3007])

    def test_forwarded_loopback_is_now_OK(self):
        # THE regression test for this whole change. A server bound to the container's
        # 127.0.0.1 was the failure this command existed to explain, and the tunnel makes it
        # work -- so the old UNREACHABLE verdict would now be a lie, and the old
        # "--host 0.0.0.0" advice would send a student to fix something that is not broken.
        self.assertIn("OK", self.rows[3008])
        self.assertIn("http://localhost:3008/", self.rows[3008])
        self.assertNotIn("UNREACHABLE", self.rows[3008])

    def test_nothing_still_demands_binding_all_interfaces(self):
        # The 0.0.0.0 requirement is retired everywhere, not just on the row above.
        self.assertNotIn("--host 0.0.0.0", self.out)
        self.assertNotIn("Why 0.0.0.0", self.out)

    def test_unforwarded_wildcard_says_not_forwarded(self):
        self.assertIn("NOT FORWARDED", self.rows[4007])
        self.assertNotIn("--host", self.rows[4007])

    def test_unforwarded_loopback_is_only_a_port_problem_now(self):
        # It used to be "two problems"; the bind address is no longer one of them.
        self.assertIn("NOT FORWARDED", self.rows[4008])
        self.assertNotIn("two problems", self.rows[4008])
        self.assertNotIn("--host", self.rows[4008])

    def test_auto_increment_overflow_is_pointed_back_at_its_range(self):
        self.assertIn("5173-5179", self.rows[5180])

    def test_ipv6_loopback_renders_as_an_address(self):
        if not self.have_v6:
            self.skipTest("no IPv6 on this machine")
        row = self.rows[5177]
        self.assertIn("::1", row)
        # The original regression: 32 raw hex digits, which also wrecked column alignment.
        self.assertNotIn("00000000", row)
        # Still the one bind address the tunnel cannot reach, since the forward's far end is
        # 127.0.0.1 -- and the advice must now name IPv4, not 0.0.0.0 specifically.
        self.assertIn("UNREACHABLE", row)
        self.assertIn("127.0.0.1", row)

    def test_points_at_doctor_for_what_it_cannot_see(self):
        # A missing forward and a downed tunnel are host-side facts that /proc cannot show,
        # so an OK here is not a promise of reachability and must not read like one.
        self.assertIn("cs193v doctor", self.out)

    def test_columns_stay_aligned(self):
        # Every data row must put STATUS at the same offset, or the table is unreadable.
        offsets = {self.rows[p].index(s)
                   for p in self.rows
                   for s in ("OK", "UNREACHABLE", "NOT FORWARDED", "system")
                   if s in self.rows[p]}
        self.assertEqual(len(offsets), 1, "STATUS column offsets: %s" % offsets)

    def test_privileged_system_ports_are_not_called_student_problems(self):
        # systemd-resolved on :53 and cups on :631 are not a student's dev server, and
        # rootless podman could not publish them anyway. Reporting them as problems made
        # the closing explanation and the exit status fire on a healthy container.
        for port, line in self.rows.items():
            if port < 1024:
                self.assertIn("system", line, line)
                self.assertNotIn("NOT PUBLISHED", line, line)

    def test_explains_why_and_lists_the_forwarded_set(self):
        self.assertIn("forwarded:", self.out)
        self.assertIn("3000-3009", self.out)
        # The explanation is now about the PORT rather than the bind address, because the port
        # is the only thing left for a student to get wrong on this side.
        self.assertIn("port is what matters", self.out)

    def test_exit_status_is_nonzero_when_there_are_real_problems(self):
        self.assertEqual(self.rc, 1)

    def test_missing_CS193V_PORTS_is_explained_not_crashed(self):
        env = dict(os.environ)
        env.pop("CS193V_PORTS", None)
        r = subprocess.run([sys.executable, PORTS_BIN], capture_output=True, text=True,
                           env=env)
        self.assertEqual(r.returncode, 2)
        self.assertIn("--rebuild", r.stderr)

    def test_a_clean_container_reports_no_problems(self):
        # With a spec covering only ports nothing is bound to, and privileged system
        # listeners excluded, the command must exit 0 rather than inventing a problem.
        env = dict(os.environ, CS193V_PORTS="9990-9999")
        r = subprocess.run([sys.executable, PORTS_BIN], capture_output=True, text=True,
                           env=env)
        for line in r.stdout.splitlines():
            f = line.split()
            if len(f) >= 3 and f[0].isdigit() and int(f[0]) >= 1024:
                return unittest.skip("something unrelated is listening on a high port")
        self.assertEqual(r.returncode, 0, r.stdout)


# ─── report in the shell suite's format ────────────────────────────────────────
if __name__ == "__main__":
    def walk(s):
        for t in s:
            if isinstance(t, unittest.TestSuite):
                for inner in walk(t):
                    yield inner
            else:
                yield t

    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    # Snapshot the cases BEFORE running: TestSuite.run() replaces each entry with None as
    # it goes, to release memory, so walking it afterwards yields nothing usable.
    cases = list(walk(suite))
    result = unittest.TextTestRunner(stream=open(os.devnull, "w"), verbosity=0).run(suite)

    failed = {}
    for case, tb in list(result.failures) + list(result.errors):
        failed[case.id()] = tb.strip().splitlines()[-1]
    skipped = {case.id(): why for case, why in result.skipped}

    results_file = os.environ.get("CS193V_RESULTS")
    suite_name = os.environ.get("CS193V_SUITE", "40-ports.py")
    lines = []

    GRN, RED, YEL, OFF = "\033[32m", "\033[1;31m", "\033[33m", "\033[0m"
    if not sys.stdout.isatty():
        GRN = RED = YEL = OFF = ""

    for t in cases:
        # ports:ClassName.method_name, trimmed to something readable in the summary.
        cls = t.__class__.__name__.replace("Test", "", 1)
        name = "ports:%s.%s" % (cls, t._testMethodName.replace("test_", ""))
        if t.id() in failed:
            status, colour = "FAIL", RED
            print("  %sFAIL%s  %s\n        %s" % (RED, OFF, name, failed[t.id()]))
        elif t.id() in skipped:
            status, colour = "SKIP", YEL
            print("  %sSKIP%s  %s (%s)" % (YEL, OFF, name, skipped[t.id()]))
        else:
            status, colour = "PASS", GRN
            print("  %sPASS%s  %s" % (GRN, OFF, name))
        lines.append("%s\t%s\t%s\n" % (status, suite_name, name))

    if results_file:
        with open(results_file, "a") as fh:
            fh.writelines(lines)

    sys.exit(1 if failed else 0)
