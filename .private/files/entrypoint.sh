#!/bin/bash
#
# PID 1 of the CS193V container.
#
# Two jobs, and only two:
#
#   1. Never exit, so the container stays up for `podman exec` to attach shells to.
#
#   2. Reap orphaned processes. This is not a theoretical concern here. A container has
#      its own PID namespace, so PID 1 inherits init's duties *within* it — and every
#      `podman exec` session is parented by conmon OUTSIDE the container, not by PID 1.
#      So anything still running when a session ends is orphaned and reparented here.
#      In this course that is the normal case: agents background processes, shells come
#      and go dozens of times a day, and the container lives for weeks.
#
#      A bare `sleep infinity` would be WRONG: sleep never calls wait(), so it cannot
#      reap, and every orphan that dies becomes a permanent zombie holding a pid slot
#      against pids.max (2048). Exhausting that WEDGES the container — `podman exec`
#      needs to fork into the same cgroup, so the launcher cannot even get back in, and
#      it does not self-heal.
#
#      A shell does reap: bash's SIGCHLD handler reaps *any* dead child it learns about,
#      not only the one it named in `wait`. This is the same shape the devcontainer CLI
#      uses, measured with zero zombies after two days of uptime.
#
# podman's own --init flag was rejected: it bind-mounts the HOST's catatonit, which
# Ubuntu's podman package only Recommends, so a host missing it fails to start the
# container at all — a hard failure from a host package we do not control.

set -u

# ~/.claude.json must be a FILE, and a single file cannot be a volume target. So the
# volume is a directory and we symlink into it. Idempotent: safe on every start.
store="$HOME/.claude-json"
link="$HOME/.claude.json"
if [ -d "$store" ]; then
    [ -e "$store/.claude.json" ] || printf '{}\n' > "$store/.claude.json" 2>/dev/null || true
    ln -sfn "$store/.claude.json" "$link" 2>/dev/null || true
fi

# If given a command, run it instead (used by --dev-build smoke tests).
if [ "$#" -gt 0 ]; then
    exec "$@"
fi

# Clean shutdown so `podman stop` returns promptly rather than timing out into SIGKILL.
trap 'exit 0' TERM INT

# The keep-alive loop. `sleep 1 &` + `wait` gives bash a chance to run its SIGCHLD
# handler every second, which is what does the reaping.
while sleep 1 & wait $!; do :; done
