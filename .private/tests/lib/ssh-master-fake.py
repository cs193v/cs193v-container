#!/usr/bin/env python3
"""The fake ssh master's own process, for lib/podman-shim.sh's shim_fake_ssh.

    ssh-master-fake.py hold CTL SENTINEL   bind and listen on CTL, then become the master
    ssh-master-fake.py ask  CTL VERB       ask the master on CTL; prints its pid, or fails like ssh

WHY A PROCESS AT ALL (#339). The fake used to bind the control socket and exit, and answer every
`-O` verb itself -- so `-O check` reported `pid=$$`, the pid of a fake that had already exited.
That was harmless while nothing looked at the pid. The supervisor now asks `kill -0` about the
pidfile's pid every tick, because a master killed with SIGKILL leaves its socket behind and the
socket alone cannot say it has gone; against that pid, every shim master would read as dead. So
the master is now something that lives, and dies, the way an ssh master does:

  * `-f` RETURNS ONLY ONCE THE LISTENER IS UP. The parent of the fork below exits after listen(),
    as ssh forks only after its mux socket is ready; tunnel_start's tunnel_alive comes straight
    after and would otherwise race the bind.
  * IT DETACHES THE WAY ssh DOES -- setsid, stdio onto /dev/null, every other fd closed. A holder
    that kept a pty or a `$(...)` pipe open would hang launcher_tty or the substitution waiting
    for an EOF that never comes. os.setsid(), because setsid(1) does not exist on macOS.
  * ITS ARGV CARRIES CTL, which is tunnel_kill_pid's identity test for "this is our master".
  * LIVENESS IS A CONNECT, as it is for a real client: refused, or no such file, and the asker
    fails with ssh's own wording and rc 255 (measured against OpenSSH 10.2). So `kill -9` of the
    holder is a SIGKILLed master exactly: the socket file stays and nothing answers on it.
  * TERM AND `-O exit` UNLINK THE SOCKET, as a real master does on a clean exit (#338) -- but
    only while the path is still OURS. The #338 case removes a socket and makes a new master on
    the same path, so the old holder outlives its file; deleting by name would take the new one's.
  * IT ENDS WHEN THE SENTINEL GOES, the way podman-fake's watcher ends when watch_out goes, so a
    case reaps its masters by removing one file. The hour is a backstop for a suite that was
    killed and never swept, not a lifetime any case is meant to reach.
"""
import os
import signal
import socket
import sys
import time


def hold(ctl, sentinel):
    s = socket.socket(socket.AF_UNIX)
    try:
        s.bind(ctl)
    except OSError as e:
        # LOUD, unlike the fake this replaced, which swallowed the failure and exited 0 -- so a
        # path one byte over AF_UNIX's limit read as a master that came up.
        sys.stderr.write("unix_listener: cannot bind to path %s: %s\n" % (ctl, e.strerror))
        return 255
    s.listen(8)
    ino = os.stat(ctl).st_ino
    if os.fork():
        os._exit(0)
    os.setsid()
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(devnull, fd)
    for fd in range(3, 256):
        if fd != s.fileno():
            try:
                os.close(fd)
            except OSError:
                pass

    def ours():
        try:
            return os.stat(ctl).st_ino == ino
        except OSError:
            return False

    def leave(*_):
        if ours():
            os.unlink(ctl)
        os._exit(0)

    signal.signal(signal.SIGTERM, leave)
    s.settimeout(1.0)
    deadline = time.monotonic() + 3600
    while os.path.exists(sentinel) and time.monotonic() < deadline:
        try:
            c, _ = s.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        try:
            c.settimeout(2.0)
            verb = c.recv(64).decode(errors="replace").strip()
            if verb == "exit":
                if ours():
                    os.unlink(ctl)
                c.sendall(b"%d\n" % os.getpid())
                c.close()
                os._exit(0)
            c.sendall(b"%d\n" % os.getpid())
        except OSError:
            pass
        finally:
            c.close()
    leave()


def ask(ctl, verb):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(5.0)
    try:
        s.connect(ctl)
    except OSError as e:
        sys.stderr.write("Control socket connect(%s): %s\n" % (ctl, e.strerror))
        return 255
    try:
        s.sendall((verb + "\n").encode())
        pid = s.recv(64).decode(errors="replace").strip()
    except OSError as e:
        sys.stderr.write("mux_client_hello_exchange: %s\n" % e)
        return 255
    if not pid:
        return 255
    print(pid)
    return 0


def main(argv):
    if len(argv) == 4 and argv[1] == "hold":
        return hold(argv[2], argv[3])
    if len(argv) == 4 and argv[1] == "ask":
        return ask(argv[2], argv[3])
    sys.stderr.write("usage: ssh-master-fake.py hold CTL SENTINEL | ask CTL VERB\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
