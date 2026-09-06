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

CLOSING THE WINDOW: SEND US SIGUSR1, DO NOT KILL US. `kill -9` on this process closes the pty
master first, and no macOS terminal does that when a window is closed -- Terminal.app signals the
foreground process group and keeps the master open until the child has gone. The two orderings put
fd 1 into different states in the child, and a launcher that tears down correctly under one can
fail under the other. That is #169.

CS193V_PTY_JOB=1 IS WHAT MAKES THAT ORDERING REACHABLE AT ALL, and it follows directly from the
paragraph above. Without it we exec the shell here, in the pty's SESSION LEADER -- so the leader is
in the foreground process group, a polite close signals it, and if the shell interposed then that
leader dies and the kernel REVOKES the controlling terminal for the whole session. The command's
teardown then writes to a revoked terminal and fails, which is the rude outcome arriving by the
polite route. Measured with lib/sh-fake: every close strategy fails there, because the revoke has
already happened before any of them decides anything.

A real terminal does not have that problem, because its session leader is the student's login
shell and the job is in a DIFFERENT process group. So in job mode this file builds that shape: the
leader forks the command into its own process group, makes it the foreground one, and stays.
_close_politely then signals the job and not the leader, nothing is revoked, and the command's
teardown writes succeed -- measured 3/3 under an interposing shell and 3/3 without one.
"""

import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time

BUF = 65536

# How long a polite close waits for the child before giving up and closing the master anyway.
# BOUNDED ON PURPOSE: 70-sighup.sh's EXIT trap kills with -9, so a wedged close could not hang
# the suite -- it would just read as a run that took the full `wait_until 45`, which is the
# expensive kind of green. Generous against a real teardown, which measures 4.6-4.9s.
CLOSE_WAIT = 30.0


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


def _install_close_handler():
    """Arm SIGUSR1 as "close the window politely", and return the fd that says it arrived.

    A SELF-PIPE, NOT A FLAG, and that is not defensive style. Under PEP 475 (Python 3.5+)
    select.select() and os.read() RETRY on EINTR when a Python-level handler returns normally,
    so a handler that merely sets a global is not noticed until the next byte of I/O -- and for
    a `sleep 600` child there is no next byte, ever. signal.set_wakeup_fd puts the signal number
    into a pipe the select loop is already watching, which is the one shape that cannot be
    swallowed.

    SIGUSR1 BECAUSE EVERYTHING ELSE IS TAKEN. SIGTERM already means "die now, be reapable" at
    lib/podman-shim.sh's launcher_pty_silent_stop, which rm -f's its fifo the moment we are
    reaped, and at 14-test-harness.sh's cleanup -- and it is what run-tests.sh's kill_tree sends
    down the whole cheap lane on a Ctrl-C. SIGHUP is unused but it is the very thing under test,
    so naming it as the trigger would be a trap for the next reader.
    """
    r, w = os.pipe()
    os.set_blocking(r, False)
    os.set_blocking(w, False)
    signal.signal(signal.SIGUSR1, lambda *_: None)   # a Python handler, so the wakeup fd fires
    signal.set_wakeup_fd(w)
    return r


def _close_requested(wake_fd):
    """True if what woke us was SIGUSR1 and not some other signal Python happens to handle."""
    try:
        return signal.SIGUSR1 in os.read(wake_fd, BUF)
    except OSError:
        return False


def _close_politely(master, pid, out):
    """Close the window the way a terminal actually closes it. Returns the child's wait status.

    MEASURED, on macOS 26 with a real Terminal.app window and a subject sampling fd 1 inside its
    own SIGHUP handler: Terminal signals the FOREGROUND PROCESS GROUP and never touches the login
    shell, so the shell does not exit, the controlling terminal is never revoked, the master stays
    open, and every write the teardown makes SUCCEEDS. Killing the pty owner instead -- which is
    what this file's callers used to do, and all any of them could do -- closes the master first,
    which no terminal does on a window close and which puts fd 1 into a state (isatty true, write
    EIO) a student cannot reach by closing a window. That difference is #169; the launcher defect it
    was exposing is #170, and it is latent rather than reachable.

    So: signal the group, KEEP DRAINING, reap the child, and close the master LAST. The order is
    the entire point; a shortcut through the ordinary exit path below would close it first.

    tcgetpgrp(master) RATHER THAN THE CHILD'S PID. pty.fork() makes the child a session leader, so
    in the ordinary case the two coincide -- but the foreground group is what a terminal signals,
    and writing down the coincidence rather than the rule is how the next shape change breaks this
    silently.
    """
    try:
        pgrp = os.tcgetpgrp(master)
    except OSError:
        pgrp = os.getpgid(pid)
    try:
        os.killpg(pgrp, signal.SIGHUP)
    except OSError:
        pass

    status = None
    deadline = time.monotonic() + CLOSE_WAIT
    while time.monotonic() < deadline:
        try:
            ready, _, _ = select.select([master], [], [], 0.05)
        except OSError:
            ready = []
        if master in ready:
            try:
                data = os.read(master, BUF)
            except OSError:
                data = b""
            if data:
                out.write(data)
                out.flush()
        try:
            done, st = os.waitpid(pid, os.WNOHANG)
            if done == pid and status is None:
                status = st
        except ChildProcessError:
            pass
        # THE JOB GROUP EMPTYING IS THE CONDITION, NOT OUR CHILD BEING REAPED. Under an interposing
        # shell our child is the wrapper, which has no handler and dies in microseconds while the
        # command is still in its own -- so reaping it and closing would cut the teardown off at the
        # knees. Nor can this wait for EOF on the master: in job mode the leader legitimately holds
        # the slave open, so EOF never comes and we would burn the whole ceiling every time.
        try:
            os.killpg(pgrp, 0)
        except OSError:
            break                 # ESRCH: everything we signalled has gone

    try:
        os.close(master)          # LAST, and only now
    except OSError:
        pass
    return status


def _be_the_leader(shell, cmd):
    """Job mode: run the command as a foreground JOB and STAY, the way a login shell does.

    WHY A SECOND PROCESS AT ALL. Without this we exec the shell in the session leader itself, so
    the leader is in the foreground process group -- and _close_politely signals that group. If a
    shell interposed, that leader is a trap-less wrapper, it dies, and the kernel revokes the
    controlling terminal for the whole session. Everything below then writes to a revoked terminal.
    A real terminal is not like that: its leader is the login shell, which is in its OWN group and
    is never signalled. This reproduces that, and it is the only thing that does -- measured, no
    choice of what to wait for before closing the master repairs it afterwards.

    THREE DETAILS, EACH MEASURED BY GETTING IT WRONG FIRST.

    SIGTTOU AROUND tcsetpgrp, RESTORED BEFORE exec. We have just put ourselves in a background
    process group, so tcsetpgrp(2) sends us SIGTTOU, whose default action stops us -- forever, with
    nothing to continue us. And SIG_IGN survives execve, so a command inheriting an ignored SIGTTOU
    is not the command a student runs.

    THE LEADER LINGERS INSTEAD OF EXITING WITH ITS CHILD. Exiting here would make the SESSION
    LEADER exit, and the kernel revokes the terminal on that -- the same trap one level up, and
    measured: a leader that exits with its child produces exactly the failure this function exists
    to prevent, because under an interposing shell its child is the WRAPPER and not the command.
    A login shell goes back to its prompt when a job ends; it does not hang up the terminal.

    AND IT DOES NOT IGNORE SIGHUP. It is not in the job's process group, so a polite close cannot
    reach it and there is nothing to defend against -- while ignoring would ALSO survive the master
    closing, which is how the pty owner tears this down. Measured: with SIGHUP ignored, a rude close
    leaks two processes holding the pty; without, none.
    """
    kid = os.fork()
    if kid == 0:
        os.setpgid(0, 0)
        signal.signal(signal.SIGTTOU, signal.SIG_IGN)
        try:
            os.tcsetpgrp(0, os.getpgrp())
        except OSError:
            pass
        signal.signal(signal.SIGTTOU, signal.SIG_DFL)
        try:
            os.execv(shell, [shell, "-c", cmd])
        except OSError as exc:
            os.write(2, ("ptyrun: cannot exec %s: %s\r\n" % (shell, exc)).encode())
        os._exit(127)
    while True:
        try:
            os.waitpid(kid, 0)
            break
        except InterruptedError:
            continue
        except ChildProcessError:
            break
    while True:
        signal.pause()          # hold the terminal open; the master closing HUPs us and we go


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: ptyrun.py COMMAND\n")
        return 2
    cmd = argv[1]

    rows = os.environ.get("CS193V_PTY_ROWS")
    cols = os.environ.get("CS193V_PTY_COLS")
    shell = os.environ.get("CS193V_PTY_SHELL") or "/bin/sh"

    job = os.environ.get("CS193V_PTY_JOB") == "1"

    pid, master = pty.fork()
    if pid == 0:
        # Child: pty.fork() has already made this the session leader with the slave as its
        # controlling terminal. WHETHER A SHELL SURVIVES BELOW THIS POINT IS NOT THIS FILE'S
        # CLAIM TO MAKE -- see the header, and lib/pty-announce for how a caller that needs the
        # command's pid gets it.
        if job:
            _be_the_leader(shell, cmd)      # never returns
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
    wake_fd = _install_close_handler()
    polite = False

    while True:
        rfds = [master, wake_fd] + ([stdin_fd] if watch_stdin else [])
        try:
            ready, _, _ = select.select(rfds, [], [])
        except OSError:
            break

        if wake_fd in ready and _close_requested(wake_fd):
            polite = True
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

    status = None
    if polite:
        status = _close_politely(master, pid, out)
    else:
        # THE ORDINARY EXIT: the child ended, so there is nothing left to be polite to.
        try:
            os.close(master)
        except OSError:
            pass

    # A GRACE, THEN INSIST. Closing the master HUPs the session leader, which is how job mode's
    # leader is meant to go -- but this wait is otherwise unbounded, and a leader that did not die
    # would hang the suite rather than fail it. Costs nothing when the ordinary thing happens.
    grace = time.monotonic() + 2.0
    while status is None:
        try:
            done, st = os.waitpid(pid, os.WNOHANG)
        except InterruptedError:
            continue
        except ChildProcessError:
            return 0
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

    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
