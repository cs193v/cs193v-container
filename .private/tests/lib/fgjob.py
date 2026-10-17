#!/usr/bin/env python3
"""Run a command with a student's signal dispositions, and say how it ended.

    CS193V_FGJOB_PIDFILE=F CS193V_FGJOB_STATUS=S fgjob.py ARGV...

WHY THIS EXISTS (#449). A Ctrl-C test has to deliver SIGINT to a launcher that can trap it, and
nothing between the suite and a pty guarantees that. A non-interactive shell hands SIG_IGN for
SIGINT and SIGQUIT to everything it starts with `&` -- which is how every pty in this tree is
started, and how run-tests.sh starts its background lane -- and SIG_IGN survives fork and execve.
A shell cannot undo it either: a trap for a signal that was ignored on entry is silently not armed,
and `trap -` does not reset it. lib/ptyrun.py resets SIGHUP for its child and deliberately nothing
else (its header says why), so a launcher under it gets an ignored SIGINT, and a test that types
^C at it measures nothing. That is not hypothetical: the first measurement for #449 sent ^C to a
backgrounded --rebuild and watched the launcher spin on, the handler never run.

PYTHON, BECAUSE IT CAN. signal.signal() installs a handler even over an inherited ignore, and a
CAUGHT signal is reset to SIG_DFL by execve. So catching INT, QUIT, TERM and HUP here does two
things at once: the child starts with all four at their defaults, and this process survives the
^C or the window close that is aimed at the child's process group, so it is still here to record
what happened to it.

HOW IT ENDED, NOT A NUMBER. ptyrun.py folds a signal death into 128+N, which cannot tell a child
that died of SIGINT from one that caught it and exited 130 -- and that difference is the one #448
and #450 measured a parent shell acting on. In CS193V_PTY_JOB mode ptyrun reports nothing at all,
because its leader outlives the job. So the status file says `exit N` or `signal N`.

THE PID IS PUBLISHED, write-then-rename as lib/pty-announce does it, because a caller that sends
TERM or HUP to the launcher ALONE needs the launcher's pid and not the pty owner's, and a file that
appears complete or not at all is the only kind a poll can read safely.
"""

import os
import signal
import subprocess
import sys

CAUGHT = (signal.SIGINT, signal.SIGQUIT, signal.SIGTERM, signal.SIGHUP)


def _publish(path, text):
    with open(path + ".tmp", "w") as f:
        f.write(text)
    os.rename(path + ".tmp", path)


def main(argv):
    pidfile = os.environ.get("CS193V_FGJOB_PIDFILE")
    statusfile = os.environ.get("CS193V_FGJOB_STATUS")
    if len(argv) < 2 or not pidfile or not statusfile:
        sys.stderr.write("usage: CS193V_FGJOB_PIDFILE=F CS193V_FGJOB_STATUS=S fgjob.py ARGV...\n")
        return 2
    for s in CAUGHT:
        signal.signal(s, lambda *_: None)
    try:
        child = subprocess.Popen(argv[1:])
    except OSError as exc:
        # LOUD, and the status file still written: a caller polling for it would otherwise burn
        # its whole ceiling and then report the launcher as hung.
        sys.stderr.write("fgjob: cannot run %s: %s\n" % (argv[1], exc))
        _publish(statusfile, "exit 127\n")
        return 127
    _publish(pidfile, "%d\n" % child.pid)
    # PEP 475: a handler that returns makes wait() retry, so the signals caught above cannot cut
    # this short.
    rc = child.wait()
    if rc < 0:
        _publish(statusfile, "signal %d\n" % -rc)
        return 128 - rc
    _publish(statusfile, "exit %d\n" % rc)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
