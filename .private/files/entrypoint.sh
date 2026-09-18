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
    # COPY-ON-SELECT OFF, ONCE PER CONFIG. `"tui": "fullscreen"` (see
    # files/claude-code/managed-settings.json) turns on the renderer's own text selection,
    # whose `copyOnSelect` DEFAULTS TO TRUE: a drag inside Claude Code then copies with
    # `tmux load-buffer -w -` and toasts "copied N chars to tmux buffer - paste with
    # prefix + ]". This configuration sets `prefix None`, so that names a key that does not
    # exist -- and on macOS Terminal.app, which does not implement OSC 52 (measured; see
    # files/tmux/tmux.conf Part 3), the copy does not reach the clipboard either. That is
    # issue #66 arriving through the application instead of through tmux.
    #
    # WHAT THIS DOES NOT BUY, so nobody reads it as more than it is: with copyOnSelect off a
    # drag no longer copies, but Claude Code's footer then offers `ctrl+c to copy` and that
    # path uses the SAME transport. On a terminal without OSC 52 it still claims a copy that
    # did not happen -- opt-in behind a keystroke rather than fired by an unintended gesture,
    # which is the whole of the improvement. Tracked as #318.
    #
    # HERE, AND NOT IN THE IMAGE, because podman copies image content only into an EMPTY
    # named volume: a copy baked in at this path would be seeded on first mount and never
    # refreshed, which is every student and every staff checkout that already exists. Same
    # trap and same shape of fix as ~/.codex/AGENTS.md below. It is also why this runs
    # UNCONDITIONALLY rather than inside the seed arm above -- a new volume and a volume
    # created weeks ago then reach the outcome by the same code path, which is the whole
    # point and also what makes the test of it non-vacuous.
    #
    # ONLY WHEN THE KEY IS ABSENT, which the helper decides. /config offers "Copy on
    # select" as a toggle and nothing here can mark a value as policy the way `tui` is, so
    # forcing it every start would make that toggle appear to work and then revert.
    #
    # THE REAL FILE, NOT $link: the helper replaces the file by renaming a temp beside it,
    # and rename(2) does not follow a symlink on its destination. The helper resolves the
    # path itself, so this is belt and braces rather than the only guard.
    #
    # THIS IS THE SAFE MOMENT AND THE ONLY ONE: PID 1's prologue runs before any `claude`
    # exists, and Claude Code holds this file parsed in memory and writes it back whole.
    if [ -f "$store/.claude.json" ] && [ -r /etc/cs193v/claude-global-defaults.py ]; then
        python3 /etc/cs193v/claude-global-defaults.py \
                "$store/.claude.json" >/dev/null 2>&1 || true
    fi
fi

# The course notes, for Codex. Same class of problem as the line above and a different shape of
# fix: codex reads global instructions ONLY from $CODEX_HOME/AGENTS.md, and ~/.codex is a named
# volume — so a copy baked into the image there would be seeded on first mount and never
# refreshed again, which is the whole reason the notes live in /etc. Linking them on every start
# means an image update reaches a student who logged in weeks ago.
#
# `-f` because the volume outlives the image: a stale link, or a copy left by an earlier build,
# must lose to the current file. A student who wants their own global instructions writes
# ~/.codex/AGENTS.override.md, which codex reads FIRST — and which therefore also replaces the
# course notes entirely rather than adding to them.
if [ -d "$HOME/.codex" ]; then
    ln -sfn /etc/cs193v/agent-notes.md "$HOME/.codex/AGENTS.md" 2>/dev/null || true
fi

# If given a command, run it instead of keeping the container alive. NOTHING IN THIS REPO USES
# THIS: the comment here used to credit --dev-build's smoke tests, which was already wrong before
# that verb was removed -- verb_dev_build passed no command, and 50-image.sh reaches into the
# image with `--entrypoint sh`, bypassing this file entirely. Kept because `podman run <image>
# <cmd>` is the obvious thing to try by hand and silently keeping the container alive instead
# would be a poor answer to it.
if [ "$#" -gt 0 ]; then
    exec "$@"
fi

# Clean shutdown so `podman stop` returns promptly rather than timing out into SIGKILL.
trap 'exit 0' TERM INT

# The keep-alive loop. `sleep 1 &` + `wait` gives bash a chance to run its SIGCHLD
# handler every second, which is what does the reaping.
while sleep 1 & wait $!; do :; done
