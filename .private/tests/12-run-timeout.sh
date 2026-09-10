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

# SC2034 FOR THE WHOLE FILE, AND FILE-LEVEL ON PURPOSE -- do not "tidy" this into three per-line
# directives. RT_BARE, RT_SPIN and RT_ROW are this suite's three modes: it sets them, run_timeout
# in files/cs193v-ui.sh reads them, and shellcheck cannot see across the `.` without -x. What
# makes the placement matter is that shellcheck reports only the LAST assignment of each, and
# each is written at several -- so one more case appended below moves all three findings, and a
# directive pinned to a line would be excusing a line that had stopped needing it while the new
# one went unexcused. (No line numbers here on purpose: they are what would rot.)
# shellcheck disable=SC2034
set -u
. "$(dirname -- "$0")/lib/assert.sh"

cd "$REPO" || exit 1

# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=.private/files/cs193v-ui.sh
. "$PRIVATE/files/cs193v-ui.sh"

# WHICH BASH RAN, recorded rather than asserted, because it decides what half the assertions below
# can see. `local cpid` leaves the name EMPTY on the 3.2 macOS ships and UNSET from 4.4 on, so
# #205's crash -- a labelled call reading that name in the 124 arm under `set -u` -- and the
# assertions that now cover it only exist on the newer shell. A green run on 3.2 is compatibility
# evidence, not coverage of that arm; this line is what stops it reading as the latter.
record "rt:bash-version" "$BASH_VERSION"

# A TMPDIR OF OUR OWN, because two of the assertions below are "it left nothing behind" and
# run_timeout reads TMPDIR on every call. Without this they would be asking a question about
# whatever else on the machine happens to write there.
WORK="$(new_tmpdir)"
# The decoy below is started after this line, so the trap has to read it lazily. A killed run
# would otherwise leave a `sleep 30` behind -- harmless in itself, but this file is about not
# leaving processes for other runs to trip over.
trap 'rm -rf "$WORK"; [ -n "${DECOY:-}" ] && kill -9 "$DECOY" 2>/dev/null; true' EXIT
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
#
# A GLOB RATHER THAN `ls | grep` (SC2010). The prefix is the whole filter, and a glob applies it
# without a pipeline -- which also means the empty case is `[ -e ]` saying no rather than ls
# saying nothing, and every caller below tests this for emptiness.
litter() {
    local e l=''
    for e in "$WORK"/cs193v-*; do
        [ -e "$e" ] || continue
        l="$l ${e##*/}"
    done
    printf '%s' "${l# }"
}

# ─── the status it returns ─────────────────────────────────────────────────────
# Half the launcher's control flow is `if pm inspect ...`, so a status that does not survive the
# wrapper turns "no such container" into "podman is broken" and vice versa.
assert_exit "rt:zero-passes-through"      0   run_timeout 5 true
assert_exit "rt:nonzero-passes-through"   3   run_timeout 5 sh -c 'exit 3'
# 125 is what `podman inspect` returns for a container that does not exist -- AND what it returns
# when it cannot reach podman at all, which is why state() no longer reads it as "absent" on its
# own (#171). It still has a caller depending on it: 125 is now the one status that makes state()
# ask `podman container exists` a second question, so a 125 that does not survive the wrapper
# would stop that tiebreak ever running. Note run_timeout ALSO returns 125 from its own failed
# mktemp, which lands in the same "could not answer" bucket rather than in "absent".
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

# ─── RT_BARE: the mode that does NOT merge them  (#171) ────────────────────────
# A read whose answer is used as a value cannot afford stderr in it: podman warns and exits 0
# -- one unrecognised key in storage.conf does it to every call -- and merged, the warning
# becomes part of the value. preflight compared such an answer against the string `true` and
# refused the machine as "rootful". pmv sets this; nothing else does.
#
# THE TWO ASSERTIONS ABOVE ARE THIS ONE'S GUARD. They run with RT_BARE unset, so if it ever
# became the default they go red rather than this going quietly unused.
RT_BARE=1
run_timeout 5 sh -c 'echo to-stdout; echo to-stderr >&2' || true
assert_contains     "rt:bare-keeps-stdout"  "to-stdout" "$RT_OUT"
assert_not_contains "rt:bare-drops-stderr"  "to-stderr" "$RT_OUT"
# BOTH BRANCHES, because run_timeout has two ways of waiting and they redirect separately: no
# label takes the fifo branch, a label forces the 10 Hz poll loop. A fix applied to one of them
# would leave the other merging, and which branch a call gets is not visible from the call.
RT_SPIN='working'
run_timeout 5 sh -c 'echo to-stdout; echo to-stderr >&2' >/dev/null 2>&1 || true
assert_contains     "rt:bare-keeps-stdout-on-the-poll-branch" "to-stdout" "$RT_OUT"
assert_not_contains "rt:bare-drops-stderr-on-the-poll-branch" "to-stderr" "$RT_OUT"
RT_SPIN=''
# The ceiling still fires, and the status still comes back, with stderr going nowhere.
assert_exit "rt:bare-still-times-out"        124 run_timeout 1 sleep 5
assert_exit "rt:bare-still-passes-a-status"  3   run_timeout 5 sh -c 'echo x >&2; exit 3'
RT_BARE=''
# ...and cleared, the default is back, so nothing below this line inherits the bare mode.
run_timeout 5 sh -c 'echo to-stderr >&2' || true
assert_contains "rt:bare-is-per-call-not-sticky" "to-stderr" "$RT_OUT"

# ─── RT_ERR: what RT_BARE takes out of the answer is KEPT  (#171 review) ──────
# RT_BARE's first cut sent stderr to /dev/null, which fixed the value and threw away the only
# evidence of why it had needed fixing. That matters here more than it usually would, because
# the trigger is TRANSIENT: the population case is the first podman call after a boot, and the
# machine is clean again minutes later, so a refusal that quotes nothing leaves the student a
# dead end and staff nothing to read. err.create-failed's `OUT=` is the house precedent.
#
# THE FOUR ASSERTIONS ABOVE ARE THIS ONE'S GUARD: RT_OUT must stay clean, or the refusal gets
# its evidence back by putting it in the value again, which is what #171 was.
RT_BARE=1
run_timeout 5 sh -c 'echo to-stdout; echo to-stderr >&2' || true
assert_eq           "rt:bare-keeps-stderr-in-rt-err"   "to-stderr" "$RT_ERR"
assert_not_contains "rt:bare-keeps-rt-out-clean-anyway" "to-stderr" "$RT_OUT"
# BOTH BRANCHES, for the reason the assertions above give: no label takes the fifo branch, a
# label forces the 10 Hz poll loop, and the two redirect separately.
RT_SPIN='working'
run_timeout 5 sh -c 'echo to-stdout; echo to-stderr >&2' >/dev/null 2>&1 || true
assert_eq "rt:bare-keeps-stderr-in-rt-err-on-the-poll-branch" "to-stderr" "$RT_ERR"
RT_SPIN=''
# EMPTY RATHER THAN STALE. A caller that tests RT_ERR to decide whether it has anything to quote
# must not be handed the PREVIOUS call's stderr -- that would attach one command's warning to a
# different command's refusal, which is a worse diagnosis than none.
run_timeout 5 sh -c 'echo only-stdout' || true
assert_eq "rt:bare-clears-rt-err-when-there-was-no-stderr" "" "$RT_ERR"
# The ceiling still fires, and what the command managed to say on its way out is still readable
# afterwards -- which is the case that matters most, a hung podman being what this whole wrapper
# is for (#157).
#
# NOT THROUGH assert_exit, and that is not a style preference: it runs its command inside a
# `$( )`, so RT_ERR would be assigned in a subshell and the assertion below would read the
# parent's stale copy. Same channel problem rt_cleanup documents, arriving in a test.
run_timeout 1 sh -c 'echo dying >&2; sleep 5'; rc_bare=$?
assert_eq "rt:bare-still-times-out-with-stderr-kept" 124     "$rc_bare"
assert_eq "rt:bare-keeps-stderr-from-a-timed-out-command" "dying" "$RT_ERR"
RT_BARE=''
# THE MERGING DEFAULT LEAVES RT_ERR EMPTY, deliberately: stderr is already in RT_OUT there, and
# a second copy of it would be a second thing for a caller to keep in step with the first.
run_timeout 5 sh -c 'echo to-stderr >&2' || true
assert_contains "rt:merged-mode-still-merges"        "to-stderr" "$RT_OUT"
assert_eq       "rt:merged-mode-leaves-rt-err-empty" ""          "$RT_ERR"


# ─── A COLLEAGUE'S RUN, STANDING RIGHT HERE  (#74) ─────────────────────────────
# `pgrep` and `pkill` are machine-wide and `sleep 30` is not ours: it is what EVERY run of this
# file spawns, and what 60-container.sh backgrounds ~63 of inside a container to reach
# --pids-limit -- host-visible, since a rootless container's processes are ordinary host
# processes, and in the OTHER LANE OF THE SAME RUN. So the kill check below used to answer a
# question about a process it had not started, and then SIGKILL it.
#
# Both halves land in the other checkout. It reports a survivor that was never ours; and the
# pkill reaches a command whose own ceiling had not fired yet, so THEIR
# rt:the-ceiling-returns-124 sees 137 and THEIR box looks like it did not hold.
#
# The decoy makes that deterministic rather than a race between two developers. It is deliberately
# named the old way, because "a sleep 30 on this machine that this file did not start" is exactly
# what must be invisible here.
sh -c 'exec sleep 30' & DECOY=$!
# WAITED FOR, or this passes vacuously: until the exec has happened the decoy is still a `sh` and
# the pattern under test would not have matched it either way.
decoy_is_up() { pgrep -f '^sleep 30$' >/dev/null 2>&1; }
wait_until 5 decoy_is_up || true

# ─── the ceiling ───────────────────────────────────────────────────────────────
# The reason the function exists: after a Mac wakes from sleep `podman info` HANGS rather than
# failing (containers/podman#21675), and an unguarded probe makes the launcher look frozen.
#
# THE COMMAND CARRIES A NAME OF OURS, keyed on this process, because the kill check below has to
# ask about a process THIS run started and `sleep 30` names half the machine (see the decoy above).
#
# `exec -a` rather than a wrapper or a distinctive duration. The exec is load-bearing -- it is what
# makes run_timeout's $cpid the sleep itself rather than a shell around it, which is the whole
# distinction the check is testing -- and -a renames argv[0] without adding a process, so what the
# ceiling has to kill is byte-for-byte what it was. A duration nobody else would pick would work
# too and is worse: a kill that failed would then leave the process for minutes instead of 30 s.
NAP="vt-nap-$$"
boxed_1s() { run_timeout 1 bash -c "exec -a $NAP sleep 30"; }
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

# AND IT KILLS THE COMMAND, not merely whatever bash happened to background. `exec -a $NAP`
# above makes the command identifiable AS OURS; a timeout that left it running would be a
# disowning dressed as a timeout, and the wedged podman it was called on would still be wedged.
if pgrep -f "^$NAP 30\$" >/dev/null 2>&1; then
    fail "rt:the-ceiling-kills-the-command" "$NAP 30 outlived the box"
    pkill -9 -f "^$NAP 30\$" 2>/dev/null
else
    pass "rt:the-ceiling-kills-the-command"
fi

# ...AND IT LEFT THE DECOY ALONE. Not a nicety: a pkill that reaches it is this suite reaching
# into another developer's run and killing the command their own ceiling was about to time out.
# By pid rather than by pattern, because the pattern is the thing under test.
#
# THE STATE, NOT `kill -0`, and that is not fussiness -- it is the first way this was written and
# it PASSED while the decoy was being SIGKILLed. The decoy is this shell's child, so a kill leaves
# a zombie until bash reaps it, and kill -0 succeeds on a zombie. Whether the reap has happened
# yet is a race with how loaded the machine is: standalone it had, so the check went red; inside a
# full run it had not, so the same code went green. A check that reports "left alone" for a
# process this suite just killed is worse than no check.
case "$(ps -p "$DECOY" -o state= 2>/dev/null | do_tr -d ' \n')" in
    ''|Z*) fail "rt:a-neighbours-sleep-is-left-alone" \
                "the decoy standing in for another checkout's run was killed by this suite" ;;
    *)     pass "rt:a-neighbours-sleep-is-left-alone" ;;
esac
kill -9 "$DECOY" 2>/dev/null || true
wait "$DECOY" 2>/dev/null || true
DECOY=''

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

# ─── ...AND THE 124 ARM IT SHARES WITH THE FIFO BRANCH  (#205) ────────────────
# THE CELL NOBODY HAD FILLED IN was (label set) x (rc == 124). The three assertions above hold the
# labelled path for a command that FINISHES, and the ceiling block above holds 124 on the fifo
# branch -- so `cpid`, which only the fifo branch assigned, could be read by the epilogue both
# branches share with nothing here passing through it. From bash 4.4 on, `local cpid` leaves the
# name unset rather than empty, so that read aborted the shell under `set -u`: a labelled
# `run_timeout` that reached its ceiling died with `cpid: unbound variable` instead of timing out.
# Latent since #38, and not cosmetic -- it is the launcher's 180s `podman run` under a spinner, and
# every one of setup-git's rows, since run_step sets RT_ROW on all of them.
#
# BOTH LABELS, because both callers land here: RT_SPIN below is the launcher's shape, which is what
# the WSL2 report crashed on, and RT_ROW is setup-git's.
#
# CONTAINED, NOT MERELY ASSERTED. assert_exit runs its command in a `$( )` and the subshell below
# is one on purpose, so the abort was reported as a wrong status with the unbound-variable line
# quoted rather than taking this suite down at line one of the block.
RT_ROW='a row'
assert_exit "rt:row-mode-may-also-exit-124" 124 run_timeout 5 sh -c 'exit 124'
RT_ROW=''
RT_SPIN='working'
assert_exit "rt:the-ceiling-returns-124-on-the-poll-branch" 124 run_timeout 1 sleep 5
RT_SPIN=''

# AND IT KILLS THE COMMAND, the `exec -a` twin of rt:the-ceiling-kills-the-command above and for
# the same reason: the poll branch's `$!` IS the command, so a ceiling that returns 124 without
# reaching its kill is a disowning dressed as a timeout. A NAME OF ITS OWN, keyed on this process
# like $NAP is, so this check and that one cannot answer each other's question.
#
# PINNED AWAY FROM THE TTY the way the RT_BARE poll-branch cases do it: with a terminal on stdout
# the label draws spinner frames into the middle of the results and without one it prints a line,
# and that difference is what would make `-k run-timeout` behave unlike a full run.
PNAP="vt-pnap-$$"
( RT_SPIN='working'; run_timeout 1 bash -c "exec -a $PNAP sleep 30" ) >/dev/null 2>&1
if pgrep -f "^$PNAP 30\$" >/dev/null 2>&1; then
    fail "rt:the-poll-branch-ceiling-kills-the-command" "$PNAP 30 outlived the box"
    pkill -9 -f "^$PNAP 30\$" 2>/dev/null
else
    pass "rt:the-poll-branch-ceiling-kills-the-command"
fi

# ─── and reading a version out of what it captured ─────────────────────────────
# HERE, BESIDE run_timeout, because RT_OUT is what run_timeout produces and the launcher reads
# the podman version out of it. Testing the parse next to the thing that fills it keeps the two
# facts together.
assert_eq "ver:plain"       "5.7.0" "$(podman_version_of 'podman version 5.7.0')"

# A version this does not anticipate must come back WHOLE for version_lt to judge, not truncated
# into something that compares wrong.
assert_eq "ver:another-version" "4.9.3" "$(podman_version_of 'podman version 4.9.3')"
assert_eq "ver:a-prerelease-is-returned-whole" "5.7.0-rc1" \
          "$(podman_version_of 'podman version 5.7.0-rc1')"
assert_eq "ver:a-distro-epoch-is-not-truncated" "4:5.7.0+ds1" \
          "$(podman_version_of 'podman version 4:5.7.0+ds1')"
# ...and returning it whole is only useful if the comparison then survives it.
assert_eq "ver:a-prerelease-still-compares" "no" \
          "$(version_lt "$(podman_version_of 'podman version 5.7.0-rc1')" 4.9.0)"

# THE FALLBACK, which exists so that anchoring on podman's wording cannot become a NEW way to
# fail. If podman ever stops saying "podman version N", the old reading is used.
assert_eq "ver:fallback-reads-the-last-field" "9.9.9" \
          "$(podman_version_of 'some other wording 9.9.9')"
# Nothing at all is empty rather than a wrong guess: version_lt reads empty as below any floor, so
# an unreadable podman is refused rather than waved through.
assert_eq "ver:nothing-parseable-is-empty" "" "$(podman_version_of '')"

# ─── dynports_read: what read's exit status does and does NOT mean  (#244) ─────
# THE SAME REFUSAL run_timeout MAKES, ONE NOTCH FINER, AND THIS IS WHERE IT IS SETTLED. The
# comment at the fifo branch's second read says the status is ">128 on bash 4 and 1 on the 3.2
# macOS ships, so testing it would mean two behaviours" -- and run_timeout can stop there,
# because its payload is always a number, so "did a value arrive" answers everything.
#
# The supervisor's frame reader cannot stop there. Its payload may legitimately be nothing, and
# the empty string is exactly what a closed stream produces, so "a value arrived" cannot tell a
# five-second silence from the watcher having gone away. What CAN is subtler and is not in any
# man page: bash 3.2 does not touch the variable when `read -t` times out, and does assign when
# the stream ends. Measured on both shells, all five outcomes:
#
#                              bash 3.2.57            bash 5.3.9
#     timeout                  rc 1,   UNTOUCHED      rc 142, set
#     timeout, partial input   rc 1,   UNTOUCHED      rc 142, set
#     EOF                      rc 1,   set ""         rc 1,   set ""
#     EOF, partial input       rc 1,   set "BEG"      rc 1,   set "BEG"
#     a line arrives           rc 0,   set            rc 0,   set
#
# WHICH IS WHY THESE ASSERTIONS EXIST AT ALL. #244 was that difference going unnoticed: sup_loop
# branched on `[ "$rc" -gt 128 ]`, which cannot be true on any Mac, so TUNNEL_SUP_SILENCE_MAX was
# dead code and the first five-second gap in the watcher's stream ended dynamic port forwarding
# for the rest of the session. The rc test is still there and still authoritative on bash 4+;
# what is new is the half that runs where it cannot work. An undocumented behaviour load-bearing
# in the product is a behaviour the suite has to hold down, and this is that hold.
#
# IT RUNS UNDER WHATEVER BASH THE DEVELOPER HAS, so a Mac proves the 3.2 half and CI proves the
# other. rt:bash-version above records which one this run was.

# Asserted first and on its own, the way 17-portparse-fuzz.sh does it for the rest of the gate:
# every property below is vacuous if the function is missing, and a suite that drives nothing
# passes everything.
if command -v dynports_read >/dev/null 2>&1; then
    pass "read:the-function-under-test-was-sourced"
else
    fail "read:the-function-under-test-was-sourced" \
"dynports_read is not in files/cs193v-ui.sh, so every assertion below is asserting nothing."
fi

# WORDS, NOT THE THREE RETURN CODES, so a failure says which of the three things happened
# instead of leaving a reader to look 0/1/2 up.
verdict() {                           # verdict SECS  <caller redirects stdin>  -> word
    dynports_read "$1"
    case "$?" in
        0) printf 'line:%s' "$DYNPORTS_LINE" ;;
        1) printf 'timeout' ;;
        2) printf 'ended' ;;
        *) printf 'unknown' ;;
    esac
}

# A FIFO OPENED READ-WRITE IS A STREAM THAT CANNOT END: this process is its own writer, so there
# is never an EOF to find and the only thing the read can do is time out. That is the whole
# stimulus -- no second process, and nothing to wait for.
RDF="$WORK/rd.fifo"
mkfifo "$RDF"
exec 7<>"$RDF"
assert_eq "read:silence-is-a-timeout" "timeout" "$(verdict 1 <&7)"
# ...and with bytes in flight that never became a line. bash 4 hands the partial back and bash
# 3.2 discards it; both must still call it a timeout rather than an ending.
printf 'partial' >&7
assert_eq "read:a-partial-line-that-stops-is-a-timeout" "timeout" "$(verdict 1 <&7)"
exec 7<&-
rm -f "$RDF"

assert_eq "read:a-closed-stream-has-ended"  "ended" "$(verdict 1 </dev/null)"
# THE CASE THE STATUS ALONE GETS WRONG ON EVERY SHELL: a writer that died mid-line. rc is 1 here
# on bash 5 too, so this is the one outcome both halves of the predicate have to agree on.
assert_eq "read:a-partial-line-then-a-close-has-ended" "ended" "$(verdict 1 < <(printf 'BEG'))"
assert_eq "read:a-whole-line-is-a-line" "line:hello" "$(verdict 1 < <(echo hello))"

# ─── ...and the three of them in one stream, which is the shape sup_loop sees ──
# The cases above each start from a clean variable. This one does not: it is here because the
# predicate reads a variable that the PREVIOUS call may have set, so "a timeout after a line"
# is the case where a stale value would be mistaken for a fresh one, and it cannot be caught by
# testing the outcomes one at a time.
RDS="$WORK/rd.seq"
mkfifo "$RDS"
(
    exec 3>"$RDS"
    printf 'alpha\nbeta\n' >&3
    # A DURATION, DELIBERATELY. This sleep is the stimulus -- the silence itself -- not a wait
    # for anything to appear. See wait_until in lib/assert.sh for why that distinction decides.
    sleep 3
    printf 'gamma\n' >&3
    exec 3>&-
) &
RDS_W=$!
RD_SAW=''
rd_drain() {                          # read until the stream ends, or give up
    local n=0
    while [ "$n" -lt 12 ]; do
        RD_SAW="$RD_SAW $(verdict 1)"
        case "$RD_SAW" in *ended) return 0 ;; esac
        n=$(( n + 1 ))
    done
    return 1
}
# A GROUP, NOT A SUBSHELL: `{ ...; } < FILE` redirects without forking, so what rd_drain
# accumulates is still here to assert on.
{ rd_drain; } < "$RDS"
RD_SAW="${RD_SAW# }"
wait "$RDS_W" 2>/dev/null || true
rm -f "$RDS"
record "read:the-sequence-seen" "$RD_SAW"
assert_match "read:lines-arrive-in-order"                '^line:alpha line:beta' "$RD_SAW"
assert_match "read:a-gap-after-a-line-is-a-timeout"      'line:beta timeout'     "$RD_SAW"
# gamma, not beta: had the previous line survived the next call, this would read `line:beta`.
assert_match "read:a-line-after-a-gap-still-arrives"     'timeout line:gamma'    "$RD_SAW"
assert_match "read:and-the-end-is-still-found-after-all-that" 'line:gamma ended$' "$RD_SAW"
