#!/usr/bin/env python3
"""Run a command on a real pty, forwarding our stdin to it and its output to ours.

    ptyrun.py COMMAND            # COMMAND is a shell command STRING, like script -c

WHY THIS EXISTS RATHER THAN script(1). Eleven sites in this suite drive an interactive program
by piping keystrokes into a pty, and every one exists ONLY to deliver those keystrokes -- the
arrow keys menu() reads, the consent digits, the `exit\\n` that ends a shell, the leading bare
ENTER 80-launcher-live.sh:336 calls load-bearing.

util-linux `script -q -c CMD /dev/null` does that correctly. BSD script, which is what a Mac
has, does not, and there is nothing to install: Homebrew's util-linux lists script and
scriptlive among the tools it does not build on Darwin. Measured on macOS 26:

    printf 'one\\ntwo\\n' | script -q /dev/null sh -c 'read a; read b; echo "a=[$a] b=[$b]"'
      -> ^D\\b\\bone\\r\\ntwo\\r\\n   a=[] b=[one]

It writes a VEOF to the master before forwarding piped stdin, so every read is shifted by one
and the last keystroke is never consumed. Unchanged by -k and -F. And it hard-errors on a fifo
stdin ("tcgetattr/ioctl: Operation not supported on socket", rc 1, nothing run), which is
exactly what launcher_pty_silent_start feeds it.

The failure mode that makes this worth a file of its own: the program under test then takes its
EOF/safe-default path, which is LOUD for a positive assertion and SILENT for the ~125
assert_says_not / assert_not_contains / assert_eq-to-empty assertions sitting behind these
helpers.

TWO CONSTRAINTS ON THE IMPLEMENTATION, both learned the hard way:

  * pty.spawn() IS DISQUALIFIED. CPython's own documentation records that it loops forever when
    stdin closes, and `printf ... | ptyrun` is exactly that shape -- our stdin hits EOF almost
    immediately while the child is still running. Hence pty.fork() and an explicit select loop.

  * ON OUR STDIN'S EOF, STOP WATCHING IT BUT DO NOT CLOSE THE MASTER. Closing it would send the
    child EOF, which is the very thing script(1) gets wrong. The child decides when it is done;
    we only stop asking. `sleep 600` fed into a launcher has to keep the session open.

A FILE, NOT A SHELL FUNCTION, because do_script hands it to `timeout`, which execvp()s its
argument and cannot see a function.

THE WINDOW SIZE IS LEFT UNSET BY DEFAULT, which means `stty size` reports 0 0 -- exactly what
script(1) does. That is deliberate and it is NOT a limitation to be improved away: the meter
tests in 30-launcher-shim.sh drive meter_fit's fallback chain, which is
`stty size` -> `tput` -> $LINES/$COLUMNS. They break tput on purpose and set $LINES/$COLUMNS to
simulate a narrow or short terminal, and that lever only works because `stty size` gives no
usable answer. 30-launcher-shim.sh:1752-1755 states the dependency outright. An earlier version
of this file set a real 80x24 "for determinism", which made `stty size` answer, stopped the chain
at its first link, and left fifteen meter and tailbox assertions unable to see the size they had
just set.

Set CS193V_PTY_ROWS / CS193V_PTY_COLS when a caller genuinely wants a sized pty.
"""

import fcntl
import os
import pty
import select
import struct
import sys
import termios

BUF = 65536


def _set_winsize(fd, rows, cols):
    """Give the pty a known size, so rendered-width assertions are platform-independent."""
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    except OSError:
        pass


def _write_all(fd, data):
    """os.write may write short; a dropped keystroke is a silent test failure."""
    while data:
        try:
            n = os.write(fd, data)
        except OSError:
            return False
        data = data[n:]
    return True


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: ptyrun.py COMMAND\n")
        return 2
    cmd = argv[1]

    rows = os.environ.get("CS193V_PTY_ROWS")
    cols = os.environ.get("CS193V_PTY_COLS")

    pid, master = pty.fork()
    if pid == 0:
        # Child: pty.fork() has already made this the session leader with the slave as its
        # controlling terminal. `sh -c` with a single simple command exec-optimises and
        # replaces itself, so `pgrep -P` on our pid names the command directly -- which is
        # what 70-sighup.sh:213 and 60-container.sh:275 walk the tree expecting.
        try:
            os.execv("/bin/sh", ["/bin/sh", "-c", cmd])
        except OSError:
            pass
        os._exit(127)

    # Only when asked -- see the header on why 0x0 is the right default here.
    if rows or cols:
        _set_winsize(master, int(rows or 24), int(cols or 80))

    out = sys.stdout.buffer
    stdin_fd = sys.stdin.fileno()
    watch_stdin = True

    while True:
        rfds = [master] + ([stdin_fd] if watch_stdin else [])
        try:
            ready, _, _ = select.select(rfds, [], [])
        except OSError:
            break

        if master in ready:
            try:
                data = os.read(master, BUF)
            except OSError:
                data = b""          # EIO: the child is gone and the slave is closed
            if not data:
                break
            out.write(data)
            out.flush()             # FLUSHED PER READ: launcher_pty_silent_wait and
                                    # 70-sighup.sh:91 read the transcript WHILE it grows.

        if watch_stdin and stdin_fd in ready:
            try:
                data = os.read(stdin_fd, BUF)
            except OSError:
                data = b""
            if not data:
                watch_stdin = False  # See the header: stop asking, do NOT close the master.
            elif not _write_all(master, data):
                watch_stdin = False

    try:
        os.close(master)
    except OSError:
        pass

    while True:
        try:
            _, status = os.waitpid(pid, 0)
            break
        except InterruptedError:
            continue
        except ChildProcessError:
            return 0

    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
