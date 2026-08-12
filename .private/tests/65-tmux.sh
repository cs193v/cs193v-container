#!/usr/bin/env bash
# TIER: container
#
# The tmux landing point, tested at the level a student actually experiences it: rendered
# screens, injected keystrokes, real mouse bytes, measured colour contrast.
#
# WHY THIS IS A DIFFERENT SHAPE FROM EVERY OTHER SUITE HERE. The others assert on files,
# settings and podman metadata. None of them can see whether brushing the scroll wheel
# strands a beginner in a mode with a dead keyboard, whether the chrome is legible on a
# light terminal theme, or whether clicking a tab works — and those are the failures that
# matter, because tmux is now the only way in. So this one drives the real thing.
#
# The instrument is an OUTER tmux, which gives three things a plain script cannot get: a
# real pty at a fixed known size, `send-keys -H` to write exact bytes (so a macOS
# Terminal.app key and a Windows Terminal key can be told apart), and `capture-pane -p -e`
# to screenshot the inner program's output with its colour sequences intact.
#
# IT ALL RUNS INSIDE THE CONTAINER. tmux-harness/ is copied in with `podman cp` — the same
# mechanism 60-container.sh uses for its port probe — so what is exercised is the installed
# /etc/cs193v/tmux.conf, the image's own tmux and terminfo, and the real /etc/bash.bashrc
# hook. Running it on the host would test a copy of the config against a different tmux,
# and would add tmux to this project's host-side test dependencies for no gain.
#
# THIS FILE must stay bash 3.2 clean (TAs run the suite on Macs). tmux-harness/ need not,
# and is deliberately exempt — see the note at bash32:tests-are-bash32-safe in 10-static.sh.
#
# Slowest suite in the project by a wide margin. `run-tests.sh -k tmux` runs it alone.

set -u
. "$(dirname -- "$0")/lib/assert.sh"

require_running
require_cmd podman

HARNESS_SRC="$(dirname -- "$0")/tmux-harness"
DEST=/tmp/cs193v-tmux-tests
TSV_IN="$DEST/results.tsv"

assert_ok "tmux:harness-sources-exist" test -f "$HARNESS_SRC/suite.sh"

# Copy in fresh every run. `podman cp` of a directory onto an existing path merges rather
# than replaces, so a stale file from a previous run could survive an edit and be the thing
# that actually ran.
podman exec "$NAME" rm -rf "$DEST" >/dev/null 2>&1 || true
podman exec "$NAME" mkdir -p "$DEST" >/dev/null 2>&1
if ! podman cp "$HARNESS_SRC/." "$NAME:$DEST/" >/dev/null 2>&1; then
    fail "tmux:harness-copied-into-the-container" "podman cp failed"
    exit 0
fi
pass "tmux:harness-copied-into-the-container"

# ─── the instrument, before anything is trusted to it ──────────────────────────
# A broken harness and a broken configuration look identical from the outside — both are
# just a screen that does not say what was expected. Running the self-test first makes them
# distinguishable, and makes "the suite is lying to you" a named failure rather than a
# mystery.
self="$(podman exec "$NAME" bash "$DEST/selftest.sh" 2>&1)"
self_rc=$?
if [ "$self_rc" -eq 0 ]; then
    pass "tmux:harness-selftest"
else
    fail "tmux:harness-selftest" \
"the measuring instrument itself failed, so nothing below can be believed.
$(printf '%s' "$self" | tail -20)"
    exit 0
fi

# ─── the suite ─────────────────────────────────────────────────────────────────
# Results come back as one tab-separated STATUS<TAB>NAME<TAB>DETAIL line per check, written
# by hx_emit in the harness, and are replayed here through pass/fail/skip so that all ~130
# checks land individually in the project's own report with the project's own counters.
# Without that the whole suite would collapse to one line and a failure would name nothing.
# Two optional passthroughs, as a plain string rather than an array: bash 3.2 empty-array
# expansion under `set -u` is a trap this project already documents, and two flags do not
# justify the guard idiom.
#
#   CS193V_TIMING     -> per-section elapsed, replayed below as record() lines. This is the
#                        only window into where the slowest suite spends its time: the suite's
#                        own stdout goes to a temp file and is discarded.
#   CS193V_TMUX_CONF  -> run against a copy of the config rather than the installed one. That
#                        is how a deliberately reintroduced bug is checked to still be caught,
#                        without rebuilding the image. RECORDED when set, so a run that tested
#                        something other than what the image installs says so in its results
#                        instead of looking like an ordinary green run.
HX_ENV=""
[ -n "${CS193V_TIMING:-}" ] && HX_ENV="$HX_ENV -e HX_TIMING=1"
if [ -n "${CS193V_TMUX_CONF:-}" ]; then
    HX_ENV="$HX_ENV -e CS193V_TMUX_CONF=$CS193V_TMUX_CONF"
    record "tmux:config-under-test" "$CS193V_TMUX_CONF — NOT the installed /etc/cs193v/tmux.conf"
fi
# shellcheck disable=SC2086
podman exec -e HX_TSV="$TSV_IN" $HX_ENV "$NAME" bash "$DEST/suite.sh" > "$(new_tmpdir)/suite.log" 2>&1
out="$(podman exec "$NAME" cat "$TSV_IN" 2>/dev/null)"

if [ -z "$out" ]; then
    fail "tmux:suite-produced-results" "the suite ran but reported nothing at all"
    exit 0
fi

n=0
# A while-read over a here-doc, not a pipe: a pipe puts the loop in a subshell on bash 3.2,
# and the counter would come back zero.
while IFS="$(printf '\t')" read -r status name detail; do
    [ -n "${name:-}" ] || continue
    # TIME rows are section timings, not checks. They need their own case or the `*)` default
    # below would report each one as a failure — and they must not be counted as checks either,
    # or "checks-replayed" would say something different depending on CS193V_TIMING.
    if [ "$status" = TIME ]; then record "$name" "${detail:-}"; continue; fi
    n=$((n + 1))
    case "$status" in
        PASS) pass "$name" ;;
        SKIP) skip "$name" "${detail:-}" ;;
        *)    fail "$name" "${detail:-}" ;;
    esac
done <<EOF
$out
EOF

record "tmux:checks-replayed" "$n"

# THE REAL CLAUDE CLI MUST NOT HAVE BEEN STARTED.
#
# Unlike the machine the harness was written on, this container HAS Claude Code installed
# and possibly logged in. The label fixtures are a copy of the python3 binary renamed
# `claude`, and they are always invoked by absolute path for exactly this reason: a bare
# `claude` would resolve through the pane's own PATH to the real CLI, which on the
# prototype machine started ~490 MB processes, exhausted RAM, and passed the fixture's
# argument to Claude Code AS A PROMPT — posting test text into a live session.
#
# The harness only prints a note about this. Here it is an assertion, because in this
# container the consequence is someone's actual account.
real="$(podman exec "$NAME" sh -c \
    'for p in $(pgrep -x claude 2>/dev/null); do readlink -f /proc/$p/exe 2>/dev/null; done' 2>/dev/null \
    | grep -v '^/tmp/hx-fakebin' || true)"
if [ -z "$real" ]; then
    pass "tmux:no-real-claude-process-was-started"
else
    fail "tmux:no-real-claude-process-was-started" \
"a claude process is running that is NOT the test fixture: $real
A fixture is resolving through PATH to the real CLI. See hx_fake_run in tmux-harness/lib.sh."
fi

# The suite kills its own tmux servers on exit, but a crashed run might not have.
#
# The reason changed with #41 and the cleanup is still needed. It used to be that a session left on
# a stray socket would be ADOPTED by the next `./cs193v`, handing a student a test fixture instead
# of a shell -- nothing reattaches now, so that particular hazard is gone. What remains is that
# these servers hold processes and pid slots inside a container that is meant to be idle, and a
# fixture left on the `cs193v` socket itself would make the next launch's session claim fail: the
# launcher would refuse with err.session-in-use against a container nobody is really in.
#
# Match on the socket files rather than on process names: tmux rewrites its own argv, so
# `pkill -f "tmux -L …"` does not reliably match a running server.
podman exec "$NAME" sh -c '
    for s in /tmp/tmux-*/*; do
        [ -S "$s" ] || continue
        case "${s##*/}" in
            cs193v) continue ;;
            *) tmux -S "$s" kill-server 2>/dev/null; rm -f "$s" ;;
        esac
    done
    true' >/dev/null 2>&1 || true
podman exec "$NAME" rm -rf "$DEST" >/dev/null 2>&1 || true
