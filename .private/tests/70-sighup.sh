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
# files/claude-code/CLAUDE.md telling an agent to "prefer your own background-execution
# mechanism" and CONTAINER-DESIGN.md telling students to "keep the window open" are the
# only workable guidance, and if they DO survive there is a better answer to give.
#
# §5.1 still needs a human to close a real window and confirm it matches.

set -u
. "$(dirname -- "$0")/lib/assert.sh"

require_running
require_cmd script "needed to give the exec client a pty, as a real terminal would"

SRV='python3 -m http.server 3000 --bind 0.0.0.0'
MATRIX=""

cleanup() { podman exec cs193v pkill -f 'http.server 3000' >/dev/null 2>&1 || true; }
trap cleanup EXIT

probe() {                             # probe LABEL COMMAND -> sets PROBE_ALIVE
    local label="$1" cmd="$2"
    cleanup; sleep 1
    # A pty, because that is what a terminal window gives it — pty teardown is one of the
    # candidate mechanisms for the server dying.
    script -q -c "podman exec -it cs193v sh -c '$cmd'" /dev/null >/dev/null 2>&1 &
    local client=$!
    sleep 3
    kill -9 "$client" 2>/dev/null          # <-- the window being closed
    wait "$client" 2>/dev/null || true
    sleep 3

    PROBE_ALIVE="$(podman exec cs193v sh -c \
        'pgrep -f "http.server 3000" >/dev/null && echo yes || echo no' 2>/dev/null)"
    local ppid fd1 http
    ppid="$(podman exec cs193v sh -c \
        'p=$(pgrep -f "http.server 3000" | head -1); [ -n "$p" ] && awk "{print \$4}" /proc/$p/stat' 2>/dev/null)"
    fd1="$(podman exec cs193v sh -c \
        'p=$(pgrep -f "http.server 3000" | head -1); [ -n "$p" ] && readlink /proc/$p/fd/1' 2>/dev/null)"
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
cleanup; sleep 1
podman exec cs193v sh -c "$SRV" >/dev/null 2>&1 &
NOTTY_CLIENT=$!
sleep 3
kill -9 "$NOTTY_CLIENT" 2>/dev/null; wait "$NOTTY_CLIENT" 2>/dev/null || true
sleep 3
NOTTY_ALIVE="$(podman exec cs193v sh -c \
    'pgrep -f "http.server 3000" >/dev/null && echo yes || echo no' 2>/dev/null)"
record "sighup:no-tty" "alive=$NOTTY_ALIVE"
MATRIX="$MATRIX
  $(printf '%-12s alive=%s' no-tty "$NOTTY_ALIVE")"
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
workable advice and $PRIVATE/files/claude-code/CLAUDE.md must not suggest backgrounding."
fi

# Whatever the outcome, the container must not be damaged by a client dying — that happens
# every time anyone closes a window.
assert_eq "sighup:container-survives-the-client-dying" "running" "$(I '{{.State.Status}}')"
assert_ok "sighup:launcher-can-still-attach" sh -c "podman exec cs193v true"
# Killed clients are the normal case, so their leftovers must be reaped rather than
# accumulate against pids.max and eventually wedge the container.
sleep 2
# `grep -c` prints 0 AND exits 1 when nothing matches, so a trailing `|| echo 0` in the
# HOST shell would append a second line and break the integer comparison. Keep the
# fallback inside the container's shell instead.
z="$(podman exec cs193v sh -c 'ps -eo stat --no-headers | grep -c Z || true' 2>/dev/null)"
z="$(printf '%s' "$z" | head -1 | tr -d ' \r')"
record "sighup:zombies-after-five-killed-clients" "$z"
if [ "${z:-0}" -le 2 ]; then
    pass "sighup:killed-clients-do-not-leak-zombies"
else
    fail "sighup:killed-clients-do-not-leak-zombies" \
         "$z zombies after five killed exec clients — these hold pid slots against
pids.max (2048), and exhausting it wedges the container beyond podman exec's reach."
fi

# Documentation consistency. Both files currently say a closed window "may stop" a server.
# On this platform every shape survived, so that warning is at best over-cautious here — but
# it is hedged with "may", and the answer may genuinely differ on macOS and WSL where the
# exec client lives outside the VM. So: record the discrepancy loudly rather than assert a
# wording, and let the per-platform runs decide what the docs should say.
if [ "$FG_ALIVE" = yes ]; then
    record "sighup:DOCS-vs-REALITY" \
        "a FOREGROUND server survived the client being killed on this platform, while
$PRIVATE/CONTAINER-DESIGN.md and $PRIVATE/files/claude-code/CLAUDE.md both warn that closing a
window 'may stop' it. Confirm on macOS and WSL before rewording — see ERRORS.md D."
else
    record "sighup:DOCS-vs-REALITY" "foreground server died, matching what the docs warn"
fi
assert_contains "sighup:CONTAINER-DESIGN-mentions-the-caveat" "closing a terminal window" \
    "$(tr 'A-Z' 'a-z' < "$PRIVATE/CONTAINER-DESIGN.md")"
assert_contains "sighup:CLAUDE.md-mentions-the-caveat" "closing a terminal window" \
    "$(tr 'A-Z' 'a-z' < "$PRIVATE/files/claude-code/CLAUDE.md")"
