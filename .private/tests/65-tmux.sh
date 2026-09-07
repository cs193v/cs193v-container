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
# AND A TUNNEL, because the open-url case at the end of the harness goes through the real
# shortlink -- which binds a port and then waits to be told the tunnel carried it, and degrades
# when nothing ever does. Without this that case failed with "the box shows an error rather than
# a link", which is a true statement about a container with no tunnel and a wholly misleading one
# about the box. The dependency used to be met by accident: 60-container.sh runs first in the
# same lane and raises the tunnel on its way past. This file's own header offers `-k tmux` as a
# way to run it alone, so accident is not good enough. require_tunnel RAISES one rather than
# only checking for it, so declaring it here is what makes running alone actually work.
require_tunnel

HARNESS_SRC="$(dirname -- "$0")/tmux-harness"
DEST=/tmp/cs193v-tmux-tests
TSV_IN="$DEST/results.tsv"

# EVERY SCRATCH PATH THE HARNESS WRITES, and THIS FILE PICKS IT rather than the harness.
#
# The harness runs inside the container and cannot be signalled from here (ERRORS.md D1a), so
# the thing that has to be able to clean up after it is this file -- and this is also the only
# place where every inner server is provably dead. Choosing the path here leaves ONE spelling of
# it: the harness reads HX_TMPROOT, and the /proc filter below and the sweeps agree with it by
# construction instead of by a literal repeated on both sides of the container boundary.
#
# $$ is this driver's pid, used as a NAME. Nothing asks a kernel about it — see the sweep below
# for why a container-side pid would be the wrong question to ask.
HX_ROOT="/tmp/hx-run.$$"

# Scratch for the harness's own output, removed on any exit. A `$(new_tmpdir)` inline at the
# podman exec below is what this was, and nothing ever deleted it: 16 KB in /tmp per run of the
# suite, found while measuring #76's leaks.
TMP="$(new_tmpdir)"

# BOTH SIDES OF THE RUN, FROM THE TRAP, and moving the container half in here is a fix rather
# than a tidy-up. The socket sweep and the `rm -rf "$DEST"` used to sit at the FOOT of this
# file, which all three `exit 0` bailouts below skip — including the one taken when the suite
# ran and reported nothing, which is precisely the run whose 15 MB is sitting in there (#190).
#
# $DEST IS ASSIGNED ABOVE THIS ON PURPOSE. The file is `set -u`, and an unbound variable inside
# a trap aborts the trap where it stands rather than skipping one line -- so a `cleanup` that
# named $DEST before it existed would clean nothing at all. The container scratch is reached by
# a glob instead of by $HX_ROOT, deliberately: this run's root and a killed earlier run's both
# match it, and only one of those is knowable from a variable.
cleanup() {
    rm -rf "$TMP"
    # Sockets by FILE, not by process name: tmux rewrites its own argv, so `pkill -f "tmux -L
    # …"` does not reliably match a running server. The suite kills its own servers on exit, but
    # a crashed run might not have.
    #
    # The reason changed with #41 and the cleanup is still needed. A session left on a stray
    # socket used to be ADOPTED by the next `./cs193v`, handing a student a test fixture instead
    # of a shell -- nothing reattaches now, so that hazard is gone. What remains is that these
    # servers hold processes and pid slots inside a container meant to be idle, and a fixture
    # left on the `cs193v` socket itself would make the next launch's session claim fail: the
    # launcher would refuse with err.session-in-use against a container nobody is really in.
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
    E 'rm -rf /tmp/hx-*' >/dev/null 2>&1 || true
    clean_vt_processes
}
trap cleanup EXIT

assert_ok "tmux:harness-sources-exist" test -f "$HARNESS_SRC/suite.sh"

# ─── what an earlier run left in the container ─────────────────────────────────
# BOTH ENDS, and the start half is the one a kill cannot skip. The harness runs inside the
# container, and per ERRORS.md D1a killing the host-side `podman exec` client does not signal
# the process in there at all -- so its EXIT trap is not something this file can rely on. Same
# reasoning 60-container.sh gives for its own two-ended cleanup (#34) and lib/assert.sh gives
# for sweep_stale_tmpdirs (#76).
#
# BLANKET, NOT BY PID, and that is the correction that matters. `/tmp` in the container is on the
# writable layer (.config/container.args:205-208) so it survives `podman stop`/`start` -- but the
# PID NAMESPACE DOES NOT, and since #41 stopped is the resting state, so hold_container restarts
# routinely. A leftover named for a pid from a previous container lifetime, asked about with
# `kill -0` in a fresh namespace whose pids start at 1 again, is likely to be told "still alive"
# -- which pins the leak permanently and silently. Pid-keying is HOST reasoning, and
# sweep_stale_tmpdirs says why: one shared /tmp that CS193V_INSTANCE does not namespace. In here
# the path is namespaced by $NAME, and the in-container precedent is clean_vt_processes: blanket,
# narrowed by name, both ends, count recorded.
#
# Two runs against one $NAME are ALREADY fatal -- the `rm -rf "$DEST"` below deletes the other
# run's harness mid-execution and the socket sweep kills its servers -- so a blanket glob in here
# adds no hazard those two do not already impose.
#
# RECORDED RATHER THAN SWEPT SILENTLY, the rule lib/assert.sh states at count_vt_processes: a
# run that was killed leaves a trace in the results instead of being invisible. Counted before
# the fixture below is planted, so the number is what an earlier run left rather than what this
# one is about to arrange.
record "tmux:leftover-scratch-from-an-earlier-run" "$(E 'ls -d /tmp/hx-* 2>/dev/null | wc -l | tr -d " "')"
record "tmux:leftover-processes-from-an-earlier-run" "$(count_vt_processes)"

# A PLANTED LEFTOVER, because "an earlier run's scratch is gone" is satisfied just as well by a
# container that never had any -- which is the state every green run is in. Without this the
# sweep below could be deleted outright and the suite would stay green, and that is exactly the
# shape #34 and #76 were both about: a number that looks measured and is not.
STALE=/tmp/hx-run.stale
podman exec "$NAME" mkdir -p "$STALE" >/dev/null 2>&1 || true

clean_vt_processes
E 'rm -rf /tmp/hx-* /tmp/slfail /tmp/cs193v-openurl-*' >/dev/null 2>&1 || true

assert_eq "tmux:earlier-runs-scratch-is-swept-at-start" "" "$(E "ls -d $STALE 2>/dev/null")"
# REMOVED UNCONDITIONALLY, so this fixture cannot be mistaken for something the harness left.
# Without this line one broken sweep reddens TWO assertions: the one above, correctly, and
# tmux:harness-left-no-scratch-in-the-container at the foot of the file, which would then be
# reporting the test's own plant rather than anything the run produced. Measured by disabling the
# sweep -- both went red. One cause, one failure, and each assertion measuring only its own thing.
podman exec "$NAME" rm -rf "$STALE" >/dev/null 2>&1 || true

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
self="$(podman exec -e HX_TMPROOT="$HX_ROOT" "$NAME" bash "$DEST/selftest.sh" 2>&1)"
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
podman exec -e HX_TSV="$TSV_IN" -e HX_TMPROOT="$HX_ROOT" $HX_ENV "$NAME" bash "$DEST/suite.sh" > "$TMP/suite.log" 2>&1
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
    # REC rows are the same shape for the same two reasons, and they are what hx_record emits:
    # a value the harness measured that is genuinely platform- and load-dependent, so record()
    # rather than an assertion. #145's stale-label count is the first one — a green run that
    # recorded zero of them proved nothing, and this is what makes that visible.
    if [ "$status" = REC ]; then record "$name" "${detail:-}"; continue; fi
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
#
# THE DECISION IS ON cmdline, NOT ON `readlink -f /proc/PID/exe`, and that is what makes this
# survive the harness cleaning up after itself. `-f` resolves through the link, so it returns
# NOTHING once the fixture binary has been unlinked -- mapping "our fixture" and "cannot be read
# at all" onto the same empty string, and passing this check vacuously for a fixture that is
# still running. cmdline cannot be unlinked, and the harness already ENFORCES the invariant that
# makes it answer: hx_fake_run always invokes the fixture by absolute path ("ALWAYS ABSOLUTE, AND
# THIS MATTERS ENORMOUSLY"), so argv[0] carries $HX_ROOT. exe is still reported, because it is
# what names a real install in the failure.
#
# `pgrep -x`, a name match, so the pattern is not in this `sh -c`'s own argv -- the trap
# container_pgrep documents in lib/assert.sh. A pid that vanishes mid-probe is skipped rather
# than reported as an unattributable claude.
real="$(podman exec "$NAME" sh -c \
    'for p in $(pgrep -x claude 2>/dev/null); do
         c="$(tr "\0" " " < /proc/$p/cmdline 2>/dev/null)"
         e="$(readlink /proc/$p/exe 2>/dev/null)"
         [ -n "$c$e" ] || continue
         printf "%s | exe=%s\n" "$c" "$e"
     done' 2>/dev/null \
    | grep -v '/hx-' || true)"
if [ -z "$real" ]; then
    pass "tmux:no-real-claude-process-was-started"
else
    fail "tmux:no-real-claude-process-was-started" \
"a claude process is running that is NOT the test fixture: $real
A fixture is resolving through PATH to the real CLI. See hx_fake_run in tmux-harness/lib.sh."
fi

# ─── and it must have left nothing of its own behind ───────────────────────────
# TWO QUESTIONS, NOT ONE, and the second is the one that is easy to leave out.
#
# (1) NOTHING IN /tmp. The container's /tmp is on the writable layer by deliberate choice
#     (.config/container.args:205-208), so what leaks here is not reclaimed by anything short of
#     `--rebuild` -- 15 MB per run of this suite, 230 MB across sixteen runs of it (#190).
#
# (2) NO FIXTURE STILL RUNNING, which is not the same question and cannot be folded into the
#     first. Unlinking a 7.5 MB ELF that a live process is still executing frees NOTHING: the
#     inode survives until the last reference closes. So (1) alone is green in exactly the
#     state where the cleanup silently failed, and greener than today, where the leak is at
#     least visible as a directory.
#
# `pgrep -x`, a NAME match, deliberately: `pgrep -f` for a path would match the `sh -c` this
# runs in, which is the trap lib/assert.sh documents at container_pgrep. Both fixture names are
# asked after -- suite.sh runs `claude-npm`, a `#!/usr/bin/env node` script, so `node` is a
# fixture process here as much as `claude` is.
left="$(E 'ls -d /tmp/hx-* /tmp/slfail /tmp/cs193v-openurl-* 2>/dev/null')"
assert_eq "tmux:harness-left-no-scratch-in-the-container" "" "$left"

fixtures="$(podman exec "$NAME" sh -c \
    'for n in claude node; do for p in $(pgrep -x "$n" 2>/dev/null); do
         tr "\0" " " < /proc/$p/cmdline 2>/dev/null; printf "\n"; done; done' 2>/dev/null \
    | grep '/hx-' || true)"
assert_eq "tmux:no-fixture-process-outlived-the-harness" "" "$fixtures"

# Everything this run put inside the container is removed by cleanup(), from the EXIT trap at the
# top of this file -- see the comment there for why it is not down here any more.
