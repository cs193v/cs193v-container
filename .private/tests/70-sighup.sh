#!/usr/bin/env bash
# TIER: container
#
# VERIFICATION.md §A.8 — the SIGHUP matrix, which is the single most important open
# question in the design and the one the docs currently hedge on.
#
# "Closing the terminal window" is simulatable: kill the local `podman exec` CLIENT process.
# That turns a question nobody could answer from source into a repeatable matrix.
#
# The result is RECORDED, not asserted, for the four shapes a student or an agent might
# use — because the point is to find out, and then make the docs say it. What IS asserted
# is the part the advice depends on: if `setsid` and `nohup` do not survive, then
# CONTAINER-DESIGN.md telling students to "keep the window open" is the only workable
# guidance, and if they DO survive there is a better answer to give.
#
# The managed CLAUDE.md used to carry the same caveat and no longer does — it was slimmed to
# the few things an agent gets wrong here, and an unverified-off-Linux hedge did not make the
# cut. Nothing in this suite asserts on that file's content any more.
#
# §5.1 still needs a human to close a real window and confirm it matches.

set -u
. "$(dirname -- "$0")/lib/assert.sh"

require_running
require_cmd script "needed to give the exec client a pty, as a real terminal would"

SRV='python3 -m http.server 3000 --bind 0.0.0.0'
MATRIX=""

# On 3000, which is FORWARDED, and this suite's whole subject is processes that outlive the
# client that started them -- so a run killed here leaves a wildcard-bound listener on a
# forwarded port, and 60-container.sh's loopback assertions then pass against it with nothing
# of their own bound (#34). An EXIT trap does not run on KILL, so sweep at start too.
cleanup() { container_pkill 'http.server 3000'; }
trap cleanup EXIT
clean_vt_processes

# Alive means "a server is answering", and asking that question is where this suite was wrong.
# It ran `podman exec $NAME sh -c 'pgrep -f "http.server 3000" ...'`, and the sh -c's OWN
# command line contains the pattern, so pgrep matched the shell: measured answering "yes" with
# no server anywhere and curl returning 000. Every alive= below was therefore unconditionally
# yes, which made sighup:setsid-survives... and the destroy-unattached regression test pass
# whatever happened (#34). container_pgrep execs pgrep directly, which cannot self-match.
#
# The measurements this restores are unchanged from what ERRORS.md's §A.8 matrix records --
# every shape really does survive here. The tests just could not have told us otherwise.
alive() { container_pgrep 'http.server 3000' && echo yes || echo no; }
srv_pid() { podman exec "$NAME" pgrep -f 'http.server 3000' 2>/dev/null | head -1; }

probe() {                             # probe LABEL COMMAND -> sets PROBE_ALIVE
    local label="$1" cmd="$2"
    cleanup
    # A pty, because that is what a terminal window gives it — pty teardown is one of the
    # candidate mechanisms for the server dying.
    script -q -c "podman exec -it ${NAME} sh -c '$cmd'" /dev/null >/dev/null 2>&1 &
    local client=$!
    sleep 3
    kill -9 "$client" 2>/dev/null          # <-- the window being closed
    wait "$client" 2>/dev/null || true
    sleep 3

    PROBE_ALIVE="$(alive)"
    local p ppid fd1 http
    # The pid comes from the same self-match-free lookup, or ppid and fd1 describe the shell
    # that went looking rather than the server. ppid=0 is expected and not a bug: the parent
    # is conmon, which lives outside the container's pid namespace.
    p="$(srv_pid)"
    if [ -n "$p" ]; then
        ppid="$(E "awk '{print \$4}' /proc/$p/stat")"
        fd1="$(E "readlink /proc/$p/fd/1")"
    fi
    http="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:3000/)"

    record "sighup:$label" "alive=$PROBE_ALIVE http=$http ppid=${ppid:-none} fd1=${fd1:-none}"
    MATRIX="$MATRIX
  $(printf '%-12s alive=%-4s http=%-4s ppid=%-6s fd1=%s' \
      "$label" "$PROBE_ALIVE" "$http" "${ppid:-none}" "${fd1:-none}")"
    cleanup
}

# The four shapes, in increasing order of detachment.
probe foreground "$SRV"
FG_ALIVE="$PROBE_ALIVE"
probe background "$SRV & sleep 60"
BG_ALIVE="$PROBE_ALIVE"
probe nohup      "nohup $SRV >/tmp/s.log 2>&1 & sleep 60"
NOHUP_ALIVE="$PROBE_ALIVE"
probe setsid     "setsid $SRV >/tmp/s.log 2>&1 & sleep 60"
SETSID_ALIVE="$PROBE_ALIVE"

# Without -it, to isolate whether pty teardown is the mechanism rather than SIGHUP itself.
cleanup
podman exec "$NAME" sh -c "$SRV" >/dev/null 2>&1 &
NOTTY_CLIENT=$!
sleep 3
kill -9 "$NOTTY_CLIENT" 2>/dev/null; wait "$NOTTY_CLIENT" 2>/dev/null || true
sleep 3
NOTTY_ALIVE="$(alive)"
record "sighup:no-tty" "alive=$NOTTY_ALIVE"
MATRIX="$MATRIX
  $(printf '%-12s alive=%s' no-tty "$NOTTY_ALIVE")"
cleanup

# THE SHAPE A STUDENT ACTUALLY HAS, now that `./cs193v` lands in tmux.
#
# The four shapes above are direct children of the exec client. A student's server is not:
# it runs in a tmux pane, owned by a tmux server that lives in the container and is not a
# descendant of the connection the terminal made. So the mechanism is different, and so is
# what can break it -- not conmon, but `destroy-unattached`, which the upstream prototype
# set to `on` and which would destroy the session, and every pane in it, the instant the
# client went away. This is the regression test for that setting being off.
#
# ASSERTED, not recorded, unlike the four above: those were open questions being measured,
# this is a documented promise (CONTAINER-DESIGN.md, ERRORS.md D1) that a one-line config
# change could silently reverse.
TMX="tmux -L cs193v -f /etc/cs193v/tmux.conf"
cleanup
podman exec "$NAME" sh -c "$TMX kill-server" >/dev/null 2>&1 || true
sleep 1
# Fed a long-running command rather than left with the suite's own stdin. With stdin at EOF
# the login shell in tab one exits immediately, which closes the tab, which ends the session
# -- and the probe below would then be measuring a container with no tmux in it at all.
# `$!` after a pipeline is its LAST element, which is script, so the kill still lands.
printf 'sleep 600\n' | script -q -c "podman exec -it ${NAME} cs193v-shell" /dev/null >/dev/null 2>&1 &
TMUX_CLIENT=$!
sleep 6
podman exec "$NAME" sh -c "$TMX new-window -d '$SRV'" >/dev/null 2>&1
sleep 3
TMUX_BEFORE="$(alive)"
kill -9 "$TMUX_CLIENT" 2>/dev/null; wait "$TMUX_CLIENT" 2>/dev/null || true
sleep 4
TMUX_ALIVE="$(alive)"
TMUX_HTTP="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:3000/)"
record "sighup:in-a-tmux-tab" "before=$TMUX_BEFORE alive=$TMUX_ALIVE http=$TMUX_HTTP"
MATRIX="$MATRIX
  $(printf '%-12s alive=%-4s http=%s' tmux-tab "$TMUX_ALIVE" "$TMUX_HTTP")"

if [ "$TMUX_BEFORE" != yes ]; then
    fail "sighup:server-in-a-tab-survives-the-window-closing" \
         "the probe server never started in the tab, so the check proved nothing"
elif [ "$TMUX_ALIVE" = yes ]; then
    pass "sighup:server-in-a-tab-survives-the-window-closing"
else
    fail "sighup:server-in-a-tab-survives-the-window-closing" \
         "a server running in a tmux tab died when the exec client was killed. Almost
certainly destroy-unattached is back on in files/tmux/tmux.conf: it destroys an unattached
session and every pane in it. CONTAINER-DESIGN.md promises the opposite, and ERRORS.md D1
records the measurement it rests on."
fi
# ...and the orphaned session must still be there to be picked up, or "run ./cs193v again
# and your tabs come back" is false even though the process survived.
assert_ok "sighup:orphaned-session-is-still-reattachable" \
          sh -c "podman exec ${NAME} $TMX list-sessions >/dev/null 2>&1"
podman exec "$NAME" sh -c "$TMX kill-server" >/dev/null 2>&1 || true
cleanup

record "sighup:MATRIX" "$(printf '%s' "$MATRIX" | tr '\n' '|')"
printf '\n  the §A.8 matrix, for $PRIVATE/VERIFICATION.md §10:%s\n\n' "$MATRIX"

# What the advice in the docs actually rests on. If setsid cannot outlive the client, then
# there is no way for a student or an agent to keep a server running across a closed window,
# and "keep the window open" is the only truthful thing the docs can say. If it can, the
# docs should say how.
if [ "$SETSID_ALIVE" = yes ]; then
    pass "sighup:setsid-survives-so-there-is-a-way-to-detach"
else
    fail "sighup:setsid-survives-so-there-is-a-way-to-detach" \
         "setsid did NOT survive the client being killed. Nothing a student runs can outlive
a closed window, so $PRIVATE/CONTAINER-DESIGN.md's 'keep the window open' is the only
workable advice, and nothing anywhere should suggest backgrounding as a way around it."
fi

# Whatever the outcome, the container must not be damaged by a client dying — that happens
# every time anyone closes a window.
assert_eq "sighup:container-survives-the-client-dying" "running" "$(I '{{.State.Status}}')"
assert_ok "sighup:launcher-can-still-attach" sh -c "podman exec ${NAME} true"
# Killed clients are the normal case, so their leftovers must be reaped rather than
# accumulate against pids.max and eventually wedge the container.
sleep 2
# `grep -c` prints 0 AND exits 1 when nothing matches, so a trailing `|| echo 0` in the
# HOST shell would append a second line and break the integer comparison. Keep the
# fallback inside the container's shell instead.
z="$(podman exec "$NAME" sh -c 'ps -eo stat --no-headers | grep -c Z || true' 2>/dev/null)"
z="$(printf '%s' "$z" | head -1 | tr -d ' \r')"
record "sighup:zombies-after-five-killed-clients" "$z"
if [ "${z:-0}" -le 2 ]; then
    pass "sighup:killed-clients-do-not-leak-zombies"
else
    fail "sighup:killed-clients-do-not-leak-zombies" \
         "$z zombies after five killed exec clients — these hold pid slots against
pids.max (2048), and exhausting it wedges the container beyond podman exec's reach."
fi

# Documentation consistency. CONTAINER-DESIGN.md says a closed window "may stop" a server.
# On this platform every shape survived, so that warning is at best over-cautious here — but
# it is hedged with "may", and the answer may genuinely differ on macOS and WSL where the
# exec client lives outside the VM. So: record the discrepancy loudly rather than assert a
# wording, and let the per-platform runs decide what the docs should say.
if [ "$FG_ALIVE" = yes ]; then
    record "sighup:DOCS-vs-REALITY" \
        "a FOREGROUND server survived the client being killed on this platform, while
$PRIVATE/CONTAINER-DESIGN.md warns that closing a window 'may stop' it. Confirm on macOS and
WSL before rewording — see ERRORS.md D."
else
    record "sighup:DOCS-vs-REALITY" "foreground server died, matching what the docs warn"
fi
# Deliberately loose. This used to look for the exact phrase "closing a terminal window",
# and broke when the paragraph was reworded -- correctly -- from a hedged caveat into a
# statement that a server survives, which is what the tabs made true. Matching a two-word
# topic rather than a sentence keeps the check meaningful (the doc must still address what
# closing the window does) without failing every time the prose improves. The behaviour
# itself is asserted above, against a real server.
assert_contains "sighup:CONTAINER-DESIGN-mentions-the-caveat" "terminal window" \
    "$(tr 'A-Z' 'a-z' < "$PRIVATE/CONTAINER-DESIGN.md")"
# The matching assertion against the managed CLAUDE.md is GONE, by decision. That file was
# deliberately slimmed to the few things an agent gets wrong here, and the SIGHUP caveat did
# not survive the cut: it is a hedge about behaviour that is measured on Linux and unverified
# elsewhere, which is worth a paragraph in the student-facing doc and not worth spending an
# agent's context on. The check stays on CONTAINER-DESIGN.md, which is where the caveat now
# lives and where a student reads it.
