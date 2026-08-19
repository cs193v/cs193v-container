#!/usr/bin/env python3
"""What the TERMINAL receives when something is copied.

THE BLIND SPOT THIS EXISTS FOR. Every other check in this directory watches the inner tmux through
an OUTER tmux, which is what makes screens, keys and mouse bytes testable at all -- but an outer
tmux is not a terminal. It accepts an OSC 52 clipboard write and stores the payload no matter which
selection the sequence names, so "the text reached the host clipboard" passed in the harness while
a student's real terminal was putting that text on the PRIMARY selection, where Ctrl+V and
`wl-paste` do not look. The same blind spot hides a copy that emits no OSC 52 at all (issue #66).

SO WHAT THIS ASSERTS IS NOW AN ABSENCE. Text selection belongs to the terminal (SHIFT+drag), the
config makes no clipboard claim, and no gesture should put a single OSC 52 byte on the wire. This
runs the real tmux on a bare pty with nothing above it, performs the real gestures, and reports the
selection target of any clipboard write it sees -- so a regression names what it emitted rather than
merely failing a boolean:

    c       CLIPBOARD -- what the config used to promise, before selection went back to the terminal
    p       PRIMARY
    EMPTY   the target-less `\033]52;;...` form, which xterm's ctlseqs defines as `s0`
            (PRIMARY + cut buffer 0) and which is what tmux emits with no terminal-overrides help
    NONE    no clipboard write happened at all -- the expected answer for every gesture

Usage:  clipprobe.py [/path/to/tmux.conf]
Output: one `<gesture>\\t<target>` line per gesture, for the caller to assert on.
Exit 1 only if tmux could not be started at all -- a missing write is a result, not an error.
"""
import fcntl, os, pty, select, struct, subprocess, sys, termios, time

CONF = sys.argv[1] if len(sys.argv) > 1 else "/etc/cs193v/tmux.conf"
SOCK = "clipprobe-%d" % os.getpid()
COLS, ROWS = 100, 30
# 2 status lines + the pane-border row sit above the pane, so a wire row is a pane row plus this.
CHROME = 3


def tm(*args):
    return subprocess.run(["tmux", "-L", SOCK] + list(args),
                          capture_output=True, text=True).stdout


class Pty:
    def __init__(self):
        self.buf = bytearray()
        self.pid, self.fd = pty.fork()
        if self.pid == 0:                      # child: the tmux under test, on a real pty
            os.environ["TERM"] = "xterm-256color"
            os.environ.pop("TMUX", None)       # or tmux believes it is nested
            os.execvp("tmux", ["tmux", "-L", SOCK, "-f", CONF, "new-session", "-s", "cs193v"])
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if not r:
                continue
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                return
            if not data:
                return
            self.buf.extend(data)

    def send(self, data):
        os.write(self.fd, data)
        time.sleep(0.03)

    def press(self, row, col):   self.send(b"\033[<0;%d;%dM" % (col, row))
    def release(self, row, col): self.send(b"\033[<0;%d;%dm" % (col, row))

    def drag(self, row1, col1, row2, col2):
        self.press(row1, col1)
        for c in range(col1, col2 + 1):
            self.send(b"\033[<32;%d;%dM" % (c, row1))
        self.send(b"\033[<32;%d;%dM" % (col2, row2))
        self.release(row2, col2)

    def multiclick(self, row, col, n):
        for _ in range(n):
            self.press(row, col)
            self.release(row, col)
            time.sleep(0.06)


def target_since(p, mark):
    """The selection target of the first OSC 52 written since `mark`, or NONE."""
    seg = bytes(p.buf[mark:])
    i = seg.find(b"\033]52;")
    if i < 0:
        return "NONE"
    rest = seg[i + 5:]
    j = rest.find(b";")
    if j < 0:
        return "MALFORMED"
    field = rest[:j].decode("ascii", "replace")
    return field if field else "EMPTY"


def pane_row(p, prefix):
    """Wire row of the first pane line starting with `prefix`. Live screen only: capture-pane
    reports the pane's own screen, not the copy-mode view, so this cannot find scrolled-back text."""
    for i, line in enumerate(tm("capture-pane", "-p", "-t", "cs193v").split("\n"), 1):
        if line.startswith(prefix):
            return i + CHROME
    return None


def main():
    p = Pty()
    p.pump(3.0)
    if "cs193v" not in tm("list-sessions"):
        print("clipprobe: tmux did not start with %s" % CONF, file=sys.stderr)
        return 1
    results = []

    # 1. a drag in the SCROLLBACK. The rows are fixed rather than found: capture-pane cannot see
    #    the copy-mode view, and for this probe any text in the history will do -- the question is
    #    which selection the write names, not which characters it carries.
    p.send(b"clear; for i in $(seq 1 100); do echo $i; done\n")
    p.pump(2.5)
    for _ in range(30):
        p.send(b"\033[<64;40;15M")
    p.pump(1.0)
    tm("delete-buffer")
    mark = len(p.buf)
    p.drag(10, 1, 13, 3)
    p.pump(1.5)
    results.append(("scrolled-back-drag", target_since(p, mark)))
    tm("send-keys", "-X", "-t", "cs193v", "cancel")
    time.sleep(0.4)

    # 2. the same gesture at a live prompt, which takes the other arm of the config's conditional.
    p.send(b"clear; echo LIVEWORD here\n")
    p.pump(2.0)
    row = pane_row(p, "LIVEWORD") or 5
    tm("delete-buffer")
    mark = len(p.buf)
    p.drag(row, 1, row, 9)
    p.pump(1.5)
    results.append(("live-prompt-drag", target_since(p, mark)))

    # 3. double-click at a live prompt -- a third gesture rather than a special case, now that none
    #    of them copies. (This is also what issue #66 was about, back when it did.)
    tm("delete-buffer")
    mark = len(p.buf)
    p.multiclick(row, 3, 2)
    p.pump(1.5)
    results.append(("live-prompt-double-click", target_since(p, mark)))

    for name, target in results:
        print("%s\t%s" % (name, target))
    tm("kill-server")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    finally:
        subprocess.run(["tmux", "-L", SOCK, "kill-server"],
                       stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
