#!/usr/bin/env python3
"""Run a command with no controlling terminal.

    nosid.py COMMAND [ARG...]        # COMMAND is an argv, not a shell string

WHY THIS EXISTS. installer_host arranges "there is no terminal" with `</dev/null`, and that
was true enough while nothing looked any further than fd 0. It is not the same condition:
a process started from a developer's terminal still has a CONTROLLING terminal, so
`/dev/tty` opens and delivers that terminal's input. Once install-cs193v.sh reattaches stdin
from /dev/tty when it is piped (#297), `</dev/null` stopped arranging what it claims -- the
installer would find the developer's terminal and carry on, and the password:no-terminal-*
cases would be asserting against a machine that does have somewhere to type.

Measured, on this Mac: under a pty, `bash script </dev/null` opens /dev/tty; through here it
does not ("Device not configured").

A SESSION, NOT A REDIRECT, because that is what "no terminal" means to the kernel. setsid(2)
detaches the new session from the controlling terminal, and every later open("/dev/tty")
fails for the whole process tree underneath -- which is the thing the test is about.

setsid(1) IS NOT AN OPTION: macOS does not ship it, which 10-static.sh:3158 already records
for the launcher's own backgrounding. Hence a file, and hence python -- the suite already
requires python3 for ptyrun.py, so this adds no dependency.

FORK FIRST, THEN setsid. setsid(2) fails with EPERM when the caller is already a process
group leader, which is exactly what an interactive shell makes of the first process in a
pipeline. The child of a fork never is one, so forking first makes this work the same way
from a script and from a prompt.

THE CHILD'S STATUS IS THIS PROCESS'S STATUS, decoded with WIFEXITED/WEXITSTATUS rather than
waitstatus_to_exitcode: the latter landed in python 3.9 and 3.9.6 is what macOS ships, so
the older spelling costs one line and removes a floor. A child killed by a signal is
reported the way a shell reports it, 128+N, so `installer_host_rc` reads the same number it
would have read without this wrapper.
"""

import os
import sys

if len(sys.argv) < 2:
    sys.stderr.write("nosid.py: needs a command\n")
    sys.exit(2)

pid = os.fork()
if pid == 0:
    os.setsid()
    try:
        os.execvp(sys.argv[1], sys.argv[1:])
    except OSError as exc:
        sys.stderr.write("nosid.py: cannot run %s: %s\n" % (sys.argv[1], exc))
        os._exit(127)

_, status = os.waitpid(pid, 0)
if os.WIFSIGNALED(status):
    sys.exit(128 + os.WTERMSIG(status))
sys.exit(os.WEXITSTATUS(status))
