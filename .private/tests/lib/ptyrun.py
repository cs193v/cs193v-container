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

WHAT SHELL RUNS THE COMMAND, AND WHAT IS *NOT* CLAIMED ABOUT IT (#151). The command string is
handed to `/bin/sh -c`, and whether that shell then exec-optimises itself away is NOT a property
this file asserts, relies on, or can know. It varies by shell, by build of the same shell, and by
the shape of the command -- measured on macOS 26:

    sh -c '...'            /bin/sh (bash 3.2)  /bin/dash (Apple dash-16)  /bin/ksh    /bin/zsh
    sleep 5                replaces            replaces                   INTERPOSES  replaces
    sleep 5 >/dev/null     INTERPOSES          replaces                   INTERPOSES  replaces
    true && sleep 5        INTERPOSES          replaces                   INTERPOSES  replaces

An earlier version of this file DID claim it ("`sh -c` with a single simple command exec-optimises
and replaces itself, so `pgrep -P` on our pid names the command directly"), and three sites walked
the tree on that basis. On Ubuntu, where /bin/sh is dash 0.5.12, the shell stays and `pgrep -P`
returns IT -- so 70-sighup.sh killed the pty session leader instead of the launcher, the kernel
HUPed the launcher, its trap ran, and the assertion inverted; while 60-container.sh's close_client
killed the wrong pid and the three non-event assertions after it passed anyway. That is #151.

SO A CALLER THAT NEEDS THE PID OF THE COMMAND ASKS THE COMMAND, NOT THE PROCESS TABLE. It runs it
through lib/pty-announce, which announces the pid it is about to become and then execs. `$$` and
`exec` are POSIX-MANDATED, unlike the optimisation, and lib/portable.sh's pty_start wraps the whole
arrangement. 14-test-harness.sh asserts that channel under the host's own /bin/sh AND under
lib/sh-fake, a shell that always interposes, so the property cannot go green by accident on a
machine whose shell happens to optimise.

CS193V_PTY_SHELL overrides /bin/sh, and exists only so that fixture is reachable.
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
    shell = os.environ.get("CS193V_PTY_SHELL") or "/bin/sh"

    pid, master = pty.fork()
    if pid == 0:
        # Child: pty.fork() has already made this the session leader with the slave as its
        # controlling terminal. WHETHER A SHELL SURVIVES BELOW THIS POINT IS NOT THIS FILE'S
        # CLAIM TO MAKE -- see the header, and lib/pty-announce for how a caller that needs the
        # command's pid gets it.
        try:
            os.execv(shell, [shell, "-c", cmd])
        except OSError as exc:
            # LOUD, AND os.write RATHER THAN sys.stderr. This used to _exit(127) in silence, so an
            # unreachable shell produced rc 127 with an EMPTY transcript -- and the ~125
            # assert_says_not / assert_not_contains / assert_eq-to-empty assertions behind these
            # helpers all pass on an empty string. lib/portable.sh's do_listeners comment records
            # what that class of failure cost this suite once already: "every consumer reported a
            # confident zero". A buffered write would not survive _exit, and pty.fork() has put
            # the slave on fd 2, so this lands in the transcript where a reader will see it.
            os.write(2, ("ptyrun: cannot exec %s: %s\r\n" % (shell, exc)).encode())
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
