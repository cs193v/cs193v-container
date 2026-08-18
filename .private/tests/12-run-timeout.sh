#!/usr/bin/env bash
# TIER: unit
#
# run_timeout's contract, one property at a time. No podman, no container, no terminal.
#
# WHY THIS EXISTS AS ITS OWN SUITE. Every podman call in the launcher goes through this one
# function, and until #38 it learned that its child had finished by asking again every 100ms --
# which cost ~0.9s of every launch and was INVISIBLE to every other assertion in the suite,
# because nothing else here measures latency and being 100ms late about a 4ms probe changes no
# output at all. So the regression this guards is one that cannot fail anywhere else.
#
# The exact path is also the only place in either script that depends on FIFO open semantics and
# on which process `$!` names, and both of those fail in ways that look like something else: a
# status that never arrives reads as a hang, and a wrapper killed instead of its command reads as
# a successful timeout that left podman running. Better here in a second than on a student's Mac.
#
# SOURCED, not driven through the launcher. run_timeout lives in files/cs193v-ui.sh precisely so
# the container can use it too -- setup-git's run_step is the same function -- and every property
# below is about the function rather than about any one caller of it.

set -u
. "$(dirname -- "$0")/lib/assert.sh"

cd "$REPO" || exit 1

# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=.private/files/cs193v-ui.sh
. "$PRIVATE/files/cs193v-ui.sh"

# A TMPDIR OF OUR OWN, because two of the assertions below are "it left nothing behind" and
# run_timeout reads TMPDIR on every call. Without this they would be asking a question about
# whatever else on the machine happens to write there.
WORK="$(new_tmpdir)"
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK"

# Elapsed real seconds, to milliseconds, WITHOUT EPOCHREALTIME -- that is bash 5 and this suite
# runs on the 3.2 macOS ships. The `time` keyword with TIMEFORMAT is in every bash that matters,
# and the command substitution passes the command's own exit status through, so a caller can have
# both from one run.
elapsed() {                           # elapsed CMD... -> seconds as 0.000, rc is the command's
    { TIMEFORMAT=%R; time "$@" >/dev/null 2>&1; } 2>&1
}
# Floats, so awk rather than [ -lt ].
faster_than() {                       # faster_than LIMIT ELAPSED
    awk -v e="$2" -v lim="$1" 'BEGIN { exit !(e < lim) }'
}
# What run_timeout leaves in TMPDIR. Named on the pid the way rt_cleanup sweeps them, so the
# suite's own scratch files are not counted.
litter() { ls -A "$WORK" 2>/dev/null | grep '^cs193v-' | tr '\n' ' ' | sed 's/ *$//'; }

# ─── the status it returns ─────────────────────────────────────────────────────
# Half the launcher's control flow is `if pm inspect ...`, so a status that does not survive the
# wrapper turns "no such container" into "podman is broken" and vice versa.
assert_exit "rt:zero-passes-through"      0   run_timeout 5 true
assert_exit "rt:nonzero-passes-through"   3   run_timeout 5 sh -c 'exit 3'
# 125 is what `podman inspect` returns for a container that does not exist, which is exactly how
# state() tells absent from present -- the one status in this list with a caller depending on it.
assert_exit "rt:125-passes-through"       125 run_timeout 5 sh -c 'exit 125'
assert_exit "rt:signal-death-passes-through" 137 run_timeout 5 sh -c 'kill -9 $$'
# 124 IS THE CEILING'S NUMBER AND A COMMAND MAY RETURN IT TOO. Nothing distinguishes them, before
# #38 or after; asserted so the conflation is on the record rather than a surprise to whoever
# next reads the 124 branch.
assert_exit "rt:a-command-may-also-exit-124" 124 run_timeout 5 sh -c 'exit 124'

# ─── the output it captures ────────────────────────────────────────────────────
# RT_OUT is read by half the callers, and err.create-failed interpolates it into what a student
# sees. Both streams, because podman says the interesting things on stderr.
run_timeout 5 sh -c 'echo to-stdout; echo to-stderr >&2' || true
assert_contains "rt:captures-stdout" "to-stdout" "$RT_OUT"
assert_contains "rt:captures-stderr" "to-stderr" "$RT_OUT"

# ─── the ceiling ───────────────────────────────────────────────────────────────
# The reason the function exists: after a Mac wakes from sleep `podman info` HANGS rather than
# failing (containers/podman#21675), and an unguarded probe makes the launcher look frozen.
boxed_1s() { run_timeout 1 sh -c 'exec sleep 30'; }
E="$(elapsed boxed_1s)"; RC=$?
assert_eq "rt:the-ceiling-returns-124" "124" "$RC"
if faster_than 1 "$E"; then
    fail "rt:the-ceiling-waits-its-full-second" "returned in ${E}s, so the box did not hold"
elif faster_than 4 "$E"; then
    pass "rt:the-ceiling-waits-its-full-second"
else
    fail "rt:the-ceiling-waits-its-full-second" "took ${E}s for a 1s box"
fi
record "rt:one-second-box-seconds" "$E"

# AND IT KILLS THE COMMAND, not merely whatever bash happened to background. `exec sleep 30`
# above makes the command identifiable; a timeout that left it running would be a disowning
# dressed as a timeout, and the wedged podman it was called on would still be wedged.
if pgrep -f '^sleep 30$' >/dev/null 2>&1; then
    fail "rt:the-ceiling-kills-the-command" "sleep 30 outlived the box"
    pkill -9 -f '^sleep 30$' 2>/dev/null
else
    pass "rt:the-ceiling-kills-the-command"
fi

# ─── the pipe's two failure modes ──────────────────────────────────────────────
# A GRANDCHILD MUST NOT HOLD THE WRITE END. podman leaves conmon behind, so anything that
# inherited the pipe would keep it open after podman had gone and turn the status into a hang.
# This is what `9>&-` in the wrapper is for, and dropping it would fail nothing else.
outlived() { run_timeout 20 sh -c 'sleep 4 >/dev/null 2>&1 & exit 0'; }
E="$(elapsed outlived)"; RC=$?
assert_eq "rt:a-lingering-grandchild-still-returns-0" "0" "$RC"
if faster_than 1 "$E"; then pass "rt:a-lingering-grandchild-does-not-delay-it"
else fail "rt:a-lingering-grandchild-does-not-delay-it" "took ${E}s, so something held the pipe"; fi

# ─── what it leaves behind ─────────────────────────────────────────────────────
assert_eq "rt:leaves-no-scratch-file" "" "$(litter)"

# A SIGNAL MID-CALL is the one path that does not reach run_timeout's own rm -f, and it has
# orphaned a file per interrupted call since long before the pipe arrived -- a Ctrl-C during the
# three minutes of `podman run` is the common way to get one. rt_cleanup is what the launcher's
# transient_cleanup and setup-git's sg_cleanup call to sweep them.
cat > "$WORK/interrupted.sh" <<'EOF'
set -u
. "$CS193V_UI"
trap 'rt_cleanup; exit 143' TERM
run_timeout 30 sh -c 'sleep 3'
EOF
CS193V_UI="$PRIVATE/files/cs193v-ui.sh" bash "$WORK/interrupted.sh" >/dev/null 2>&1 &
VICTIM=$!
scratch_exists() { [ -n "$(litter)" ]; }
if wait_until 5 scratch_exists; then
    kill -TERM "$VICTIM" 2>/dev/null
    wait "$VICTIM" 2>/dev/null; VRC=$?
    assert_eq "rt:a-signal-exits-128-plus-the-signal" "143" "$VRC"
    assert_eq "rt:a-signal-leaves-no-scratch-file" "" "$(litter)"
else
    kill "$VICTIM" 2>/dev/null
    fail "rt:a-signal-exits-128-plus-the-signal" "no scratch file ever appeared to interrupt"
    fail "rt:a-signal-leaves-no-scratch-file" "see above"
fi

# ─── the latency this suite exists for  (#38) ──────────────────────────────────
# TWENTY PROBES, which is roughly what a launch plus a doctor run costs. The old poll loop
# noticed a finished child on its next 100ms tick, so twenty of them could not come in under
# two seconds however fast the commands were; the pipe makes it fork-bound instead. The margin
# is wide on purpose -- this has to survive a loaded CI box and a slow Mac without flaking.
twenty() {
    local i=0
    while [ "$i" -lt 20 ]; do run_timeout 5 true || return 1; i=$((i + 1)); done
}
E="$(elapsed twenty)"
if faster_than 1 "$E"; then pass "rt:twenty-probes-in-under-a-second"
else fail "rt:twenty-probes-in-under-a-second" "took ${E}s -- is it polling again?"; fi
record "rt:twenty-probes-seconds" "$E"

# ─── the labelled path is deliberately still a poll loop ───────────────────────
# RT_SPIN and RT_ROW animate a spinner, which needs a frame clock, and bash 3.2 cannot
# `read -t 0.1`. So they keep the 10 Hz loop and its one tick of latency -- invisible on a 180s
# `podman run`. What must not break is the contract: the status, the capture and the row.
RT_ROW='a row'
run_timeout 5 sh -c 'echo row-output; exit 7'; RC=$?
RT_ROW=''
assert_eq       "rt:row-mode-passes-the-status-through" "7" "$RC"
assert_contains "rt:row-mode-captures-output" "row-output" "$RT_OUT"
assert_eq       "rt:row-mode-leaves-no-scratch-file" "" "$(litter)"
