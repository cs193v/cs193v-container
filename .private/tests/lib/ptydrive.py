#!/usr/bin/env python3
"""Drive an interactive program through a pty from a SESSION SCRIPT, not a clock.

    ptydrive.py COMMAND          # the session script arrives on stdin
                                 # the transcript goes to stdout, exactly as ptyrun.py's does

WHY THIS EXISTS BESIDE ptyrun.py RATHER THAN INSIDE IT. ptyrun forwards a STREAM: whatever is on
its stdin goes to the child as fast as the child will take it, and it is right for the eight
callers that only need a pty and a few keystrokes. This one answers a different question -- WHEN
may the next keystroke be sent, and IS THE CHILD WHERE THE TEST THINKS IT IS -- which needs the
master fd, the accumulated output and the slave's terminal settings all in one loop. Keeping them
apart leaves ptyrun's twenty assertions in 14-test-harness.sh measuring what they always measured.

THE CLOCK IS THE DEFECT THIS REPLACES. lib/setup-git-shim.sh's sg_feed slept 0.3s between
keystrokes with no knowledge of the child at all. Measured, at that pacing: the first answer is
echoed at byte offset 0 -- before the program's first byte -- 10 runs out of 10; under CPU
oversubscription the row structure of the transcript collapses 6 runs out of 6; and on Linux/bash 5
keystrokes are LOST outright, which hangs the run until the outer `timeout` truncates the
transcript, on which about 125 negative assertions then pass vacuously.

── THE THREE THINGS A STEP KNOWS ──────────────────────────────────────────────────────────────

A step is  KIND, NAME, NEEDLES, KEYS  and all four are load-bearing.

KIND is the SHAPE OF THE READ the child must be sitting in, and it is checked against the SLAVE'S
TERMIOS -- read through tcgetattr(master), which reflects the slave's line discipline on both
platforms (measured on macOS 26 and on Linux):

    line     ICANON and ECHO on   -- `IFS= read -r`, the terminal echoing as usual
    secret   both off             -- `stty -echo -icanon` plus `read -rsn1`
    menu     both off             -- bash's own `read -rsn1`, which is -s and -n
    password ICANON on, ECHO off  -- sudo's own password prompt (#226)

THAT IS WHAT MAKES A LEAKED CREDENTIAL UNREACHABLE RATHER THAN UNLIKELY. A `secret` step is not
written until the terminal says echo is OFF. If read_secret ever loses its stty -- which is the
exact defect the tally and the three secret:* assertions exist to catch -- this driver refuses to
type the token at all and reports the step by name, instead of pasting 93 characters of a real
credential into a transcript that 90-setup-git-github.sh:235 `record`s to a file.

NEEDLES are the prose of the CATALOGUE KEYS naming the screen this step answers, flattened by the
caller (lib/setup-git-shim.sh's sg_phrase) so that nothing here knows any wording. Every needle
must be present in the output since the previous step, in order. For a menu that is the whole
ordered option list, which is a complete state test: "correct/retype" cannot be mistaken for
"all-done/need-help", and a reflow that inserts a screen fails HERE, by name, instead of leaving
the keystrokes to land one prompt out for the rest of the run.

NAME is what a failure is reported as. KEYS are the bytes, in `printf %b` escaping.

── THE ARM SIGNAL ─────────────────────────────────────────────────────────────────────────────

Needles alone are not enough: the prose is on the screen a moment before the child is blocked. So
a step is sent when its needles have matched AND the child is demonstrably at a read:

  * ESC[?25h (cursor_show) for `line` and `secret`. setup-git's two readers show the cursor for
    exactly as long as they are waiting and hide it again on the way out (files/setup-git:396,491),
    so it is emitted once per read arm and never otherwise -- except by the EXIT trap, which is
    after the last step and cannot be mistaken for one.
  * The terminal going raw for `menu`. cs193v-ui.sh's menu() never shows the cursor; what it does
    do is `read -rsn1`, and bash puts the line discipline into -icanon -echo for the duration.
  * ECHO alone going off for `password`. sudo shows no cursor and never will, but it clears ECHO
    and leaves ICANON set, which is a state no resting terminal and neither keystroke read is
    ever in -- so for that kind the level is the arm. #226 needs it because sudo DISCARDS the
    input queue at its own password read, measured both ways, so a password cannot be written
    ahead of the prompt at all.

Both are properties of the PROGRAM'S OWN BEHAVIOUR rather than of its wording, so neither can drift
when somebody rewrites a message.

── WHAT IT DOES NOT DO ────────────────────────────────────────────────────────────────────────

IT WRITES NO DIAGNOSTICS TO stdout OR stderr. lib/setup-git-shim.sh's runner ends `2>&1`, so this
process's stderr IS the transcript under test: a line of ours in it would be read by every
assertion in the suite, would be counted by the 80-column row lint, and would be searched for the
token. Everything this has to say goes to the file named by $CS193V_DRIVE_REPORT.

ONE STEP, ONE WRITE, and never a whole session pushed up front.

THE REASON IS NOT THE ONE lib/setup-git-shim.sh USED TO GIVE. That comment blamed bash's `read -n1`
restore for DISCARDING the queue, on the strength of a measurement taken through script(1) -- and
the `04` in its transcript is script's own injected VEOF, which ptyrun.py:15-21 documents. Through
ptyrun nothing is discarded: the whole of setup-git's happy path pushed as one write(2) reaches
`all set`, 3 runs of 3.

WHAT ACTUALLY HAPPENS IS WORSE, because it is silent. On a cbreak -> canonical transition with
bytes still queued, the line discipline marks only the LAST queued byte as a terminator, so the
whole queue collapses into a single "line" and the next `read -r` returns whatever precedes the
first embedded newline -- usually nothing. Measured, identically on macOS 26 and on Linux/bash 5:

    canonical only, no mode change      a=[one] b=[two]        intact
    cbreak -> canonical, bytes queued   a=[one] k=[X] b=[]     b is GONE

It MANGLES rather than discards, which is why the same push succeeds for setup-git (after a menu
Enter the queue reads `Jane Doe\n...`, no leading newline) and destroys the probe above (whose
queue reads `\ntwo\n`). On Linux that is a real lost keystroke, a hang, and a transcript truncated
by the outer `timeout` -- on which ~125 negative assertions pass vacuously.

    THE INVARIANT: never leave bytes in the input queue that no read ever takes.

Gating on the arm signal satisfies it by construction. A mode change with bytes queued does NOT
break it on its own -- the child arming the read we wrote for is one, every time -- so the
detector below asks again a second later and reports only a queue that nobody read.
"""

import errno
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time

BUF = 65536
FS = "\t"            # between a step's four fields
US = "\x1f"          # between needles within a step

# How long one step may wait for its screen before the run is failed BY NAME. Generous against
# setup-git's slowest screen (the probe list, which the fakes answer in about a second) and far
# under the caller's whole-run ceiling, which is the thing it exists to stop reaching: a run that
# hits that ceiling comes back TRUNCATED, and a truncated transcript is what makes ~125 negative
# assertions pass vacuously.
STEP_SECS = float(os.environ.get("CS193V_DRIVE_STEP_SECS") or 20.0)

# An OPTIONAL step gets a short one instead: by the time it is pending, either its screen is on
# the way or it is never coming, and waiting the full deadline for each would add a minute to a
# run that behaved perfectly.
OPT_SECS = float(os.environ.get("CS193V_DRIVE_OPT_SECS") or 3.0)

# HOW LONG A SCREEN MUST BE STILL before "the child is slow" becomes "the child is somewhere
# else". A program that has stopped writing AND is sitting in a read is not going to produce the
# screen this step is waiting for; waiting out the whole deadline for each of 38 cases turns a
# one-line reflow into a twelve-minute red run. Generous against the slowest thing that draws in
# pieces -- run_step`s spinner redraws every 100ms while a probe runs, so a screen that is merely
# being drawn is never quiet this long.
SETTLE_SECS = float(os.environ.get("CS193V_DRIVE_SETTLE_SECS") or 2.0)

# HOW LONG A QUEUE THAT CROSSED A TTY MODE CHANGE IS GIVEN TO DRAIN before it is called stranded.
# Not a pause anything pays for: a keystroke the next read wants is gone in a millisecond or two,
# and this is only ever waited out on the way to a failure. Generous on purpose -- the gap being
# covered is one preemption between the child's tcsetattr and its read(), which on an
# oversubscribed 2-core box is tens of milliseconds and not a bound worth cutting fine. See the
# loss detector for what asking twice buys.
STRAND_SECS = float(os.environ.get("CS193V_DRIVE_STRAND_SECS") or 1.0)

# After the script is exhausted the child is left to finish on its own -- the caller's `timeout`
# is the ceiling, exactly as it is for ptyrun.py.

_CSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
_WS = re.compile(r"\s+")

_ESCAPES = {"n": "\n", "r": "\r", "t": "\t", "e": "\x1b", "a": "\a", "b": "\b",
            "f": "\f", "v": "\v", "\\": "\\"}


def unescape(s):
    """`printf %b` escaping, which is what every call site in the suite already writes.

    \\033 IS THE FORM THE TESTS USE for an arrow key, and bash's %b accepts three octal digits
    with or without the leading 0. Both are handled; a backslash before anything else is kept, so
    a stray one in a name cannot silently eat the character after it.
    """
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c != "\\" or i + 1 >= n:
            out.append(c); i += 1; continue
        nxt = s[i + 1]
        if nxt in _ESCAPES:
            out.append(_ESCAPES[nxt]); i += 2; continue
        j = i + 1
        if nxt == "0":
            j += 1
        k = j
        while k < n and k - j < 3 and s[k] in "01234567":
            k += 1
        if k > j:
            out.append(chr(int(s[j:k], 8))); i = k; continue
        out.append(c); i += 1
    return "".join(out)


def flatten(raw):
    """The window, as the phrases the caller is looking for would appear in it.

    THE SAME TWO LAYERS lib/setup-git-shim.sh's sg_plain takes off, and for the same reasons: the
    terminal added colour, cursor moves and a \\r before every \\n, and the markup took the
    *asterisks* away by turning them into colour. Escapes go first so that what is left of an
    emphasised phrase is its words.
    """
    txt = _CSI.sub("", raw)
    txt = txt.replace("\r", "\n")
    return _WS.sub(" ", txt)


def read_script(fh):
    """The session, from stdin, as (steps, error). DECODED HERE rather than by the locale: the
    suite runs several seds under LC_ALL=C and a step naming an em dash would raise
    UnicodeDecodeError under it.

    IT RETURNS ITS ERROR RATHER THAN RAISING. An earlier draft used SystemExit, whose message goes
    to stderr -- and lib/setup-git-shim.sh's runner ends `2>&1`, so stderr IS the transcript under
    test. A malformed script would have put a python message where every assertion in
    35-setup-git-shim.sh could read it, the 80-column row lint could count it, and the token sweep
    could search it. The caller routes this to the report file and exits 90 like any other
    conversation failure.
    """
    steps = []
    for lineno, line in enumerate(fh.read().decode("utf-8", "replace").splitlines(), 1):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        parts = line.split(FS)
        if len(parts) != 4:
            return ([], "script line %d has %d fields, want 4" % (lineno, len(parts)))
        kind, name, needles, keys = parts
        optional = kind.startswith("?")
        kind = kind[1:] if optional else kind
        if kind not in ("line", "secret", "menu", "password"):
            return ([], "script line %d: unknown kind %r" % (lineno, kind))
        steps.append({
            "optional": optional,
            "kind": kind,
            "name": name,
            "needles": [n for n in needles.split(US) if n != ""],
            "keys": unescape(keys),
        })
    return (steps, None)


def tty_state(fd):
    """(icanon, echo) as the SLAVE sees them, or (None, None) while that cannot be read.

    tcgetattr ON THE MASTER, which reflects the slave's line discipline: the pair shares it.
    Measured on macOS 26 -- `read -rsn1` in the child reads back icanon=0 echo=0 here and the
    settings come back the moment the read returns.
    """
    try:
        attrs = termios.tcgetattr(fd)
    except (OSError, termios.error):
        return (None, None)
    lflag = attrs[3]
    # ICANON AND ECHO ONLY, never the whole structure. The line discipline toggles PENDIN on its
    # own, so comparing whole termios structures reports three spurious transitions in a
    # four-transition run -- measured on macOS 26.
    return (bool(lflag & termios.ICANON), bool(lflag & termios.ECHO))


def queued(fd):
    """Bytes the child has been sent and has not read yet, or 0 when that cannot be asked.

    FIONREAD ON THE SLAVE, NEVER ON THE MASTER, and the difference is a trap rather than a detail.
    On Linux FIONREAD(master) reports bytes readable FROM the master -- the child's output -- and
    on macOS it reports 0 while data is readable regardless. A check built on the master is
    therefore vacuously true on macOS, which is the platform this suite has always been green on.
    A slave fd held by the parent behaves identically on both: N while the bytes are queued, 0 the
    instant the child consumes them (measured, both platforms).
    """
    try:
        return struct.unpack("i", fcntl.ioctl(fd, termios.FIONREAD, b"\0\0\0\0"))[0]
    except (OSError, ValueError):
        return 0


def needles_in_order(window, needles):
    """Every needle present, in order. Returns the index of the first one that is not."""
    at = 0
    for i, needle in enumerate(needles):
        found = window.find(needle, at)
        if found < 0:
            return i
        at = found + len(needle)
    return -1


class Report(object):
    """Everything this process has to say, in a FILE. Never stdout, never stderr -- see the header."""

    def __init__(self, path):
        self.fh = open(path, "w") if path else None

    def line(self, *fields):
        if not self.fh:
            return
        self.fh.write(FS.join(str(f) for f in fields) + "\n")
        self.fh.flush()

    def detail(self, text):
        if not self.fh:
            return
        for row in str(text).splitlines() or [""]:
            self.fh.write("# " + row + "\n")
        self.fh.flush()


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: ptydrive.py COMMAND\n")
        return 2
    cmd = argv[1]

    steps, script_error = read_script(sys.stdin.buffer)
    report = Report(os.environ.get("CS193V_DRIVE_REPORT"))
    if script_error is not None:
        report.line("FAIL", "(script)", "MALFORMED", script_error)
        return 90
    rows = os.environ.get("CS193V_PTY_ROWS")
    cols = os.environ.get("CS193V_PTY_COLS")
    shell = os.environ.get("CS193V_PTY_SHELL") or "/bin/sh"

    # openpty + fork RATHER THAN pty.fork(), for one reason: pty.fork() closes the slave in the
    # parent, and the slave is the only fd on which the child's INPUT QUEUE can be measured.
    # Everything else about the shape is what pty.fork() does -- setsid, then make the slave the
    # controlling terminal, then dup it onto 0/1/2.
    master, slave = pty.openpty()
    pid = os.fork()
    if pid == 0:
        try:
            os.close(master)
            os.setsid()
            try:
                fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
            except OSError:
                pass
            for target in (0, 1, 2):
                os.dup2(slave, target)
            if slave > 2:
                os.close(slave)
            os.execv(shell, [shell, "-c", cmd])
        except OSError as exc:
            # LOUD, and os.write rather than sys.stderr, for the reason ptyrun.py records: an
            # unreachable shell used to produce rc 127 with an EMPTY transcript, and every negative
            # assertion behind these helpers passes on an empty string.
            os.write(2, ("ptydrive: cannot exec %s: %s\r\n" % (shell, exc)).encode())
        os._exit(127)

    if rows or cols:
        try:
            fcntl.ioctl(master, termios.TIOCSWINSZ,
                        struct.pack("HHHH", int(rows or 24), int(cols or 80), 0, 0))
        except OSError:
            pass

    out = sys.stdout.buffer
    step_i = 0
    prev_icanon = None          # for the loss detector below
    strand = None               # (count, was, now, deadline) while a queue is under suspicion
    slave_open = True
    window = ""                 # output since the previous step was sent
    armed_cursor = False        # ESC[?25h seen in this window
    deadline = time.monotonic() + (OPT_SECS if (steps and steps[0]["optional"]) else STEP_SECS)
    started = time.monotonic()
    last_output = time.monotonic()
    failure = None
    eof = False

    report.line("BEGIN", "steps=%d" % len(steps))

    while True:
        if step_i >= len(steps) and eof:
            break
        try:
            ready, _, _ = select.select([master], [], [], 0.02)
        except OSError:
            break
        if master in ready:
            try:
                data = os.read(master, BUF)
            except OSError:
                data = b""      # EIO: the child is gone and the slave is closed
            if not data:
                eof = True
                # AN OPTIONAL TAIL IS NOT A FAILURE, and it exists for exactly one caller:
                # 90-setup-git-github.sh drives the real GitHub, where whether a probe fails is
                # the finding rather than the fixture. Everything before it is still required.
                if any(not s["optional"] for s in steps[step_i:]):
                    failure = ("CHILD-ENDED", steps[step_i], "the child exited with %d step(s) unsent"
                               % (len(steps) - step_i))
                break
            out.write(data)
            out.flush()         # PER READ: nothing here may buffer a transcript another process reads
            last_output = time.monotonic()
            chunk = data.decode("utf-8", "replace")
            window += chunk
            if "\x1b[?25h" in chunk:
                armed_cursor = True

        # THE SLAVE IS RELEASED THE MOMENT THE SCRIPT IS EXHAUSTED, and that is not tidiness -- it
        # is what lets this loop end at all. Our slave fd keeps the pty open, so the master would
        # never reach EOF and `eof` above would never be set, however long ago the child exited.
        # Nothing after the last step needs to ask about the input queue either: there is no
        # keystroke left that could be stranded by a mode change.
        if step_i >= len(steps):
            if slave_open:
                try:
                    os.close(slave)
                except OSError:
                    pass
                slave_open = False
            continue

        # ── THE LOSS DETECTOR ──────────────────────────────────────────────────────────────────
        # THE ONE FAILURE NEITHER A NEEDLE NOR THE TERMINAL STATE CAN SEE. Gating means nothing is
        # written ahead of a prompt, but a keystroke is still briefly QUEUED between our write and
        # the child's read -- and if the child changes tty mode inside that window the byte does not
        # survive it. Measured, identically on macOS 26 and Linux/bash 5: on a cbreak -> canonical
        # transition with bytes queued, the line discipline marks only the LAST queued byte as a
        # terminator, so the whole queue collapses into one "line" and the next `read -r` returns
        # whatever precedes the first embedded newline -- usually nothing.
        #
        #     canonical only, no mode change      a=[one] b=[two]        intact
        #     cbreak -> canonical, bytes queued   a=[one] k=[X] b=[]     b is GONE
        #
        # It MANGLES rather than discards, which is why it is silent: the read succeeds and returns
        # the wrong answer. On Linux that is the keystroke loss behind #206, and the run then hangs
        # until the caller's `timeout` truncates the transcript.
        #
        # THE QUEUE IS READ AT THE SAME INSTANT AS THE MODE CHANGE, never a tick earlier. An
        # earlier draft compared a change seen now against a count taken last tick and reported
        # every clean run as a loss -- because the ordinary end of `read -rsn1` IS a
        # cbreak -> canonical transition, and the byte it just consumed was still in last tick's
        # count.
        #
        # AND A MODE CHANGE WITH BYTES QUEUED IS STILL NOT A LOSS, which is what #249 was bounced
        # by. THE OTHER ORDER IS ORDINARY DELIVERY: we write at the arm, the byte sits in the queue
        # for as long as the child takes to get from its tcsetattr to its read() -- and ARMING that
        # read is itself a mode change, so the two are indistinguishable at the instant they
        # happen. Measured in 35-setup-git-shim.sh's retoken case on a 2-core box under load:
        # 3 runs in 8 crossed a mode change with a keystroke queued, all of them
        # canonical -> cbreak, every one of them consumed by the next read, all 8 conversations
        # correct. Sampling decided which of those runs went red, which is the shape of a flake
        # rather than of a finding.
        #
        # SO THE SUSPICION IS CONFIRMED RATHER THAN REPORTED: the queue has to still be there
        # STRAND_SECS later. Stranded bytes are the ones nobody ever reads, and that is the only
        # question whose answer differs between the two cases.
        icanon_now, _echo_now = tty_state(master)
        if icanon_now is not None:
            if (prev_icanon is not None and icanon_now != prev_icanon
                    and slave_open and strand is None and queued(slave) > 0):
                strand = (queued(slave), prev_icanon, icanon_now,
                          time.monotonic() + STRAND_SECS)
            prev_icanon = icanon_now

        if strand is not None:
            count, was, became, by = strand
            # DRAINED TO EMPTY, not merely smaller. A cbreak -> canonical strand is read as ONE
            # mangled line, so the count does drop -- it just drops to the wrong place, which is
            # the silent failure this exists to catch. Only an empty queue says every byte we
            # wrote reached a read.
            #
            # WHAT CONFIRMING GIVES UP: a queue the child FLUSHES rather than reads drains to zero
            # too, and sudo's own password read is one (#226). That is the `password` gate's job
            # rather than this one's -- nothing is written until sudo has cleared ECHO, so there is
            # never anything ahead of the flush to lose.
            if not slave_open or queued(slave) == 0:
                strand = None
            elif time.monotonic() > by:
                failure = ("LOST", steps[step_i],
                           "the child changed tty mode with %d byte(s) still unread:"
                           " icanon %s -> %s, and %gs later nothing had read them."
                           % (count, was, became, STRAND_SECS))
                break

        step = steps[step_i]
        flat = flatten(window)
        missing = needles_in_order(flat, step["needles"])
        icanon, echo = tty_state(master)

        # TTY MODE IS A LEVEL HERE, NEVER A COUNTED EDGE, and that is measured rather than
        # stylistic. An arrow key is TWO arms -- cs193v-ui.sh:659-660 reads the ESC with
        # `read -rsn1` and the `[B` with `read -rsn2` -- and the canonical window between them is
        # 12-130us. No poll can see it, and a gate built on counting arms wedges: a prototype that
        # required a fresh cbreak edge hung 7 gates for 60s each and finished 160/15 in 19:45.
        # A redrawn option list is durable evidence; a 12us dip is not.
        if step["kind"] == "line":
            at_read = armed_cursor and icanon is True and echo is True
        elif step["kind"] == "secret":
            at_read = armed_cursor and icanon is False and echo is False
        elif step["kind"] == "password":
            # A FOURTH STATE, AND IT IS SUDO'S (#226). sudo clears ECHO and leaves ICANON alone,
            # so its prompt is canonical-with-echo-off -- a combination none of the three above
            # describes, and one no resting terminal is ever in: canonical+echo is the resting
            # state, and the two keystroke reads clear both. So the level IS the arm here, with
            # no cursor marker needed, which matters because sudo emits none and never will.
            #
            # MEASURED THROUGH THIS DRIVER, in the fixture 26-installer-sandbox.sh builds:
            # icanon=1 echo=1 at the start, icanon=1 echo=0 for exactly as long as the prompt is
            # waiting, and the password written at that moment authenticates. The same password
            # written BEFORE the prompt does not -- sudo discards the queue at its own read, so
            # this gate is the only way the suite can answer one.
            at_read = icanon is True and echo is False
        else:                                   # menu
            at_read = icanon is False and echo is False

        if missing < 0 and at_read:
            os.write(master, step["keys"].encode())
            # CONFIRM DELIVERY BEFORE MOVING ON. A master write is not instantly visible on the
            # slave: measured at up to 49ms on Linux, 0 on macOS. Without this the next tick reads
            # FIONREAD as 0, concludes the child has consumed the key, and both the loss detector
            # above and the gate below reason from a queue state that has not happened yet.
            # Bounded and cheap: it is over as soon as the bytes appear, and a platform where they
            # appear instantly never enters the loop at all.
            confirm_by = time.monotonic() + 0.25
            while slave_open and time.monotonic() < confirm_by and queued(slave) == 0:
                time.sleep(0.001)
            report.line("OK", step["name"], "%dms" % int((time.monotonic() - started) * 1000))
            step_i += 1
            window = ""
            armed_cursor = False
            deadline = time.monotonic() + (OPT_SECS if (step_i < len(steps) and steps[step_i]["optional"]) else STEP_SECS)
            started = time.monotonic()
            last_output = time.monotonic()
            continue

        # PARKED SOMEWHERE ELSE, which is a DIVERGENCE and not slowness. The child has stopped
        # writing and is demonstrably blocked on a read -- and it is not the read this step
        # describes. Saying so now rather than at the deadline is what keeps a reflow a fast red
        # run instead of 38 twenty-second waits, and the screen in the report is the one the
        # program is actually sitting on.
        # `window` MUST BE NON-EMPTY, and that is not belt and braces. A menu redraws its whole
        # option list after every arrow key, so between our keystroke and the redraw the terminal
        # is ALREADY raw again with nothing yet written -- and under contention that gap can
        # outlast the settle. Measured: with this clause missing, one case in 38 reported a
        # divergence at the wrong step on a machine carrying 24 runaway CPU burners, and was not
        # reproducible in isolation 3/3. Silence with nothing drawn is a slow child, not a
        # different screen.
        # `echo is False` IS THE THIRD WAY TO BE DEMONSTRABLY AT A READ, added with the password
        # kind: a sudo prompt is canonical, so `icanon is False` cannot see it and it shows no
        # cursor, so `armed_cursor` cannot either -- and without this a password step whose
        # screen never comes waits out the whole deadline instead of naming the screen the child
        # is really parked on. It widens the clause by exactly the state the new kind describes.
        if (missing >= 0 and not step["optional"] and window != ""
                and (icanon is False or echo is False or armed_cursor)
                and time.monotonic() - last_output > SETTLE_SECS):
            failure = ("DIVERGED", step,
                       "the child is parked at a read this step does not describe:"
                       " needle %d of %d (%r) is not on the screen"
                       % (missing + 1, len(step["needles"]), step["needles"][missing]))
            break

        if time.monotonic() > deadline:
            if step["optional"]:
                report.line("SKIP", step["name"], "never reached")
                step_i += 1
                window = ""
                armed_cursor = False
                deadline = time.monotonic() + STEP_SECS
                started = time.monotonic()
                continue
            why = ("the screen never arrived: needle %d of %d is missing"
                   % (missing + 1, len(step["needles"]))) if missing >= 0 else \
                  ("the screen arrived but the terminal was never at a %s read"
                   " (icanon=%s echo=%s, cursor_show=%s)"
                   % (step["kind"], icanon, echo, armed_cursor))
            failure = ("TIMEOUT", step, why)
            break

    if failure:
        what, step, why = failure
        report.line("FAIL", step["name"], what, why)
        report.detail("step %d of %d: %s %s" % (step_i + 1, len(steps), step["kind"], step["name"]))
        report.detail("wanted, in order:")
        for i, needle in enumerate(step["needles"]):
            mark = "??" if i >= 0 and needles_in_order(flatten(window), step["needles"][:i + 1]) >= 0 else "ok"
            report.detail("  [%s] %s" % (mark, needle))
        report.detail("the screen since the previous step:")
        shown = _CSI.sub("", window).replace("\r", "\n").rstrip().splitlines()[-24:]
        for row in shown:
            report.detail("  | " + row)
        # KILLED, NOT ABANDONED. Letting the caller's `timeout` fire instead would come back as
        # rc 124 with a TRUNCATED transcript, which is the shape that makes negative assertions
        # pass vacuously -- the very failure this file exists to remove.
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass

    # THE SLAVE GOES BEFORE THE DRAIN. Holding it open is what made the input queue observable,
    # and it is also what would stop the master ever reaching EOF -- the drain below and the exit
    # condition above both depend on that EOF, and ptyrun.py:220-228 records the same trap in job
    # mode. Nothing after this point needs to ask about the queue.
    if slave_open:
        try:
            os.close(slave)
        except OSError:
            pass
        slave_open = False

    # Drain whatever the child still has to say, then let it go.
    end = time.monotonic() + (2.0 if failure else STEP_SECS)
    while time.monotonic() < end:
        try:
            ready, _, _ = select.select([master], [], [], 0.05)
        except OSError:
            break
        if master in ready:
            try:
                data = os.read(master, BUF)
            except OSError:
                data = b""
            if not data:
                break
            out.write(data)
            out.flush()
            continue
        try:
            done, _ = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            break
        if done == pid:
            break

    try:
        os.close(master)
    except OSError:
        pass

    status = None
    grace = time.monotonic() + 2.0
    while status is None:
        try:
            done, st = os.waitpid(pid, os.WNOHANG)
        except InterruptedError:
            continue
        except ChildProcessError:
            status = 0
            break
        if done == pid:
            status = st
            break
        if time.monotonic() > grace:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
            grace = float("inf")
        time.sleep(0.01)

    report.line("END", "sent=%d" % step_i, "of=%d" % len(steps))

    if failure:
        # 90 IS NOT A CHILD STATUS, and that is the point: a caller reading only the exit code can
        # still tell "the conversation went wrong" from "the program failed", and 124 stays what it
        # has always been -- the whole-run ceiling.
        return 90
    if isinstance(status, int) and status not in (0,):
        if os.WIFEXITED(status):
            return os.WEXITSTATUS(status)
        if os.WIFSIGNALED(status):
            return 128 + os.WTERMSIG(status)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
