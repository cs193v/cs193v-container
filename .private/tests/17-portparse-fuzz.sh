#!/usr/bin/env bash
# TIER: unit
#
# The dynamic-port frame parser, fuzzed. No podman, no container, no terminal.
#
# WHY A FUZZER AND NOT A CORPUS. This parser is the only place bytes the CONTAINER controls reach
# the host, and the only container-derived value that ever lands in an ssh argument comes out of
# it. A fixed corpus tests the cases somebody thought of; the cases that matter here are the ones
# nobody did. Three of the bugs this suite was written against were found by hand-fuzzing during
# design -- leading zeros parsed as octal so the checked port and the forwarded port differed,
# an over-long digit string silently wrapping in $(( )), and a \r that made the failure message
# read "non-decimal port: 3000" with the carriage return invisible.
#
# SOURCED, not driven through the launcher, for the reason 12-run-timeout.sh gives: the parser
# lives in files/cs193v-ui.sh precisely so it can be exercised as a function. Driving it through
# `cs193v` would cost ~50ms of launcher startup per case and cap us at a few hundred cases.
#
# DETERMINISTIC. The generator is a hand-rolled LCG rather than $RANDOM, which is not guaranteed
# reproducible across bash versions -- and this suite's results file is compared across instances
# and across machines. Same seed, same cases, everywhere. The seed is printed on any failure so a
# case can be replayed.

set -u
. "$(dirname -- "$0")/lib/assert.sh"

cd "$REPO" || exit 1

# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=.private/files/cs193v-ui.sh
. "$PRIVATE/files/cs193v-ui.sh"

# ─── the contract under test ───────────────────────────────────────────────────
# dynports_reset              start a fresh parse
# dynports_line LINE          0 = consumed, 1 = frame complete, 2 = fatal
#                             on 1: $DYNPORTS_FRAME is "port:class port:class ..."
#                             on 2: $DYNPORTS_FATAL is a one-line reason
#
# Asserted first and on its own, because every property below is vacuous if the functions are
# missing -- a fuzzer that drives nothing passes everything.
if ! command -v dynports_reset >/dev/null 2>&1 || ! command -v dynports_line >/dev/null 2>&1; then
    fail "fuzz:the-parser-exists" \
"dynports_reset / dynports_line are not defined in files/cs193v-ui.sh.
Every assertion in this suite drives them, so there is nothing to test."
    exit 1
fi
pass "fuzz:the-parser-exists"

SEED=20260821
LCG=$SEED
# SETS A VARIABLE, does not echo. `$(lcg N)` is a fork, and the generators below call this tens
# of thousands of times -- measured at 13s for 800 cases before this changed, in a tier whose
# whole point is being cheap. Same reason quoted() uses printf -v.
lcg() {                               # lcg N -> $R in [0,N)
    LCG=$(( (LCG * 1103515245 + 12345) & 0x7FFFFFFF ))
    R=$(( LCG % ${1:-256} ))
}

# A CHARACTER TABLE BUILT ONCE. The first version did `s="$s$(printf "\\$(printf '%03o' $c)")"`
# per character, which is two forks per byte -- 13s for 800 cases, in a tier whose whole point is
# being cheap. Indexing a precomputed string is a builtin and costs nothing.
CHARS=''
__i=32
while [ "$__i" -lt 127 ]; do
    CHARS="$CHARS$(printf "\\$(printf '%03o' "$__i")")"
    __i=$(( __i + 1 ))
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cs193v-fuzz.XXXXXX")"
CANARY="$WORK/canary"
ERRF="$WORK/err"
trap 'rm -rf "$WORK"' EXIT

CLASSES="lo any v6lo eth loalt"

# ─── drive one transcript, and record everything the oracle needs ──────────────
# Returns nothing; sets RUN_RC (last code), RUN_PORTS (all accepted), RUN_ERR (stderr).
run_case() {                          # run_case LINE...
    local l
    dynports_reset
    RUN_RC=0; RUN_PORTS=''
    # ONE redirect for the whole transcript, not one per line, and a BRACE group so the
    # assignments inside still land in this shell. `$(<file)` to read it back: that form is a
    # bash builtin with no fork, where $(cat ...) is one fork per case.
    { for l in "$@"; do
        dynports_line "$l"
        RUN_RC=$?
        case "$RUN_RC" in
            0) ;;
            1) RUN_PORTS="$RUN_PORTS ${DYNPORTS_FRAME:-}" ;;
            *) break ;;
        esac
      done
    } 2>"$ERRF"
    RUN_ERR="$(<"$ERRF")"
}

# ─── property 1: nothing is ever executed ──────────────────────────────────────
# The strongest one. $(( )), (( )), [[ -eq ]], ${v:x:y} and ${a[x]} all EXECUTE command
# substitutions found in their operands -- measured -- so a parser that reaches any of them with
# unvalidated input is a shell injection. `case` is the only construct that evaluates nothing,
# which is why it has to come first in the parser.
INJECT='$('"'"'touch '"$CANARY"''"'"')'
rm -f "$CANARY"
run_case "cs193v-portwatch 1" "BEGIN 1" "3000:$INJECT" "END"
run_case "cs193v-portwatch 1" "BEGIN 1" "$INJECT:lo" "END"
run_case "cs193v-portwatch 1" "BEGIN $INJECT" "END"
run_case "cs193v-portwatch 1" "a[\$(touch $CANARY)]"
run_case "cs193v-portwatch 1" "BEGIN 1" "3000:lo\`touch $CANARY\`" "END"
assert_no_file "fuzz:nothing-is-executed" "$CANARY"

# ─── property 7 (checked early, so the rest is not vacuous) ────────────────────
# A parser that rejects EVERYTHING satisfies every "must not" below. This is the assertion that
# stops the suite passing on one.
run_case "cs193v-portwatch 1" "BEGIN 3" "3000:lo" "5173:any" "9000:v6lo" "END"
assert_eq "fuzz:a-valid-frame-is-accepted" " 3000:lo 5173:any 9000:v6lo" "$RUN_PORTS"
assert_eq "fuzz:a-valid-frame-returns-1"   "1" "$RUN_RC"
run_case "cs193v-portwatch 1" "BEGIN 0" "END"
assert_eq "fuzz:an-empty-frame-is-accepted" "1" "$RUN_RC"
# The boundaries are valid, not hostile: 1 and 65535 are real ports and must survive the gate.
run_case "cs193v-portwatch 1" "BEGIN 2" "1:lo" "65535:eth" "END"
assert_eq "fuzz:boundary-ports-are-accepted" " 1:lo 65535:eth" "$RUN_PORTS"

# ─── the hostile corpus: every one of these MUST be fatal ──────────────────────
# Hand-built during design, kept as permanent regressions. Anything a future fuzz run finds is
# promoted in here beside them.
HOSTILE_RAN=0
hostile_fatal() {                     # hostile_fatal NAME LINE...
    local name="$1"; shift
    run_case "$@"
    if [ "$RUN_RC" = 2 ] && [ -n "${DYNPORTS_FATAL:-}" ]; then
        pass "fuzz:rejects:$name"
    else
        fail "fuzz:rejects:$name" "rc=$RUN_RC reason='${DYNPORTS_FATAL:-}' ports='$RUN_PORTS'"
    fi
    # COUNTED LAST, after the verdict, not first. An arithmetic error inside run_case unwinds
    # straight past everything below it, so counting on entry would count a case that never
    # reached its assertion -- which is the exact hole this guard exists to close. Measured: the
    # first version incremented on entry and reported a happy 34 while two cases had vanished.
    HOSTILE_RAN=$(( HOSTILE_RAN + 1 ))
}
H="cs193v-portwatch 1"
hostile_fatal "bad-handshake"        "cs193v-portwatch 2" "BEGIN 0" "END"
hostile_fatal "no-handshake"         "BEGIN 0" "END"
hostile_fatal "octal-port"           "$H" "BEGIN 1" "03000:lo" "END"
# 08 AND 09 SPECIFICALLY, and they are not the same case as 03000. Without the 10# base prefix,
# `$(( 08 ))` does not misparse -- it ERRORS, "value too great for base", straight to stderr, and
# the caller falls through. 03000 is caught by the canonicality compare either way, so it does not
# exercise 10# at all; these two are the only corpus entries that do. Found by mutation testing:
# deleting 10# left every assertion green until these were added.
hostile_fatal "leading-zero-eight"   "$H" "BEGIN 1" "08:lo" "END"
hostile_fatal "leading-zero-nine"    "$H" "BEGIN 1" "09:lo" "END"
hostile_fatal "double-zero"          "$H" "BEGIN 1" "00:lo" "END"
hostile_fatal "port-zero"            "$H" "BEGIN 1" "0:lo" "END"
hostile_fatal "port-too-high"        "$H" "BEGIN 1" "65536:lo" "END"
hostile_fatal "port-overlong"        "$H" "BEGIN 1" "99999999999999999999:lo" "END"
hostile_fatal "negative-port"        "$H" "BEGIN 1" "-5:lo" "END"
hostile_fatal "plus-port"            "$H" "BEGIN 1" "+3000:lo" "END"
hostile_fatal "hex-port"             "$H" "BEGIN 1" "0x1f:lo" "END"
hostile_fatal "exponent-port"        "$H" "BEGIN 1" "3e3:lo" "END"
hostile_fatal "unicode-digits"       "$H" "BEGIN 1" "٣٠٠٠:lo" "END"
hostile_fatal "glob-port"            "$H" "BEGIN 1" "*:lo" "END"
hostile_fatal "glob-class"           "$H" "BEGIN 1" "3000:*" "END"
hostile_fatal "unknown-class"        "$H" "BEGIN 1" "3000:wat" "END"
hostile_fatal "empty-class"          "$H" "BEGIN 1" "3000:" "END"
hostile_fatal "empty-port"           "$H" "BEGIN 1" ":lo" "END"
hostile_fatal "no-colon"             "$H" "BEGIN 1" "3000" "END"
hostile_fatal "two-colons"           "$H" "BEGIN 1" "3000:lo:extra" "END"
hostile_fatal "count-too-high"       "$H" "BEGIN 3" "3000:lo" "END"
hostile_fatal "count-too-low"        "$H" "BEGIN 1" "3000:lo" "5173:lo" "END"
hostile_fatal "count-noncanonical"   "$H" "BEGIN 003" "3000:lo" "END"
hostile_fatal "count-over-cap"       "$H" "BEGIN 129" "END"
hostile_fatal "count-nondecimal"     "$H" "BEGIN xx" "END"
hostile_fatal "nested-begin"         "$H" "BEGIN 1" "BEGIN 1" "END"
hostile_fatal "end-without-begin"    "$H" "END"
hostile_fatal "record-outside-frame" "$H" "3000:lo"
hostile_fatal "trailing-space"       "$H" "BEGIN 1" "3000:lo " "END"
hostile_fatal "leading-space"        "$H" "BEGIN 1" " 3000:lo" "END"
hostile_fatal "carriage-return"      "$H" "BEGIN 1" "$(printf '3000\r'):lo" "END"
hostile_fatal "record-too-long"      "$H" "BEGIN 1" "3000:loooooooooooooooo" "END"
hostile_fatal "unknown-line-type"    "$H" "BEGIN 1" "MAYBE 3" "END"

# ─── properties 2-6, over generated input ──────────────────────────────────────
# 2 always terminates       (the suite's own timeout catches a hang)
# 3 exactly three outcomes  (0, 1 or 2 -- never a bash error status)
# 4 clean stderr            (no "integer expected", no "value too great for base", no "unbound")
# 5 accepted ports are sound
# 6 bounded                 (nothing here should be slow; the tier budget catches it)
#
# Property 4 has teeth: the overflow case leaked `[: ...: integer expected` to stderr during
# design and fell through, which is exactly the shape "never fail silently" forbids.
BAD_RC=''; BAD_ERR=''; BAD_PORT=''; N=0
check_run() {                         # check_run LABEL
    N=$(( N + 1 ))
    case "$RUN_RC" in 0|1|2) ;; *) BAD_RC="${BAD_RC:-$1 -> rc=$RUN_RC}" ;; esac
    case "$RUN_ERR" in
        '') ;;
        *) BAD_ERR="${BAD_ERR:-$1 -> stderr: $RUN_ERR}" ;;
    esac
    local e p c
    for e in $RUN_PORTS; do
        p="${e%%:*}"; c="${e#*:}"
        case "$p" in ''|*[!0-9]*) BAD_PORT="${BAD_PORT:-$1 -> non-decimal '$e'}"; continue ;; esac
        [ "${#p}" -le 5 ] || { BAD_PORT="${BAD_PORT:-$1 -> overlong '$e'}"; continue; }
        [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || BAD_PORT="${BAD_PORT:-$1 -> range '$e'}"
        [ "$p" = "$(( 10#$p ))" ] || BAD_PORT="${BAD_PORT:-$1 -> noncanonical '$e'}"
        case " $CLASSES " in *" $c "*) ;; *) BAD_PORT="${BAD_PORT:-$1 -> class '$e'}" ;; esac
    done
}

# (a) random bytes
i=0
while [ "$i" -lt 400 ]; do
    lcg 6; n=$(( R + 1 )); j=0; lines=()
    while [ "$j" -lt "$n" ]; do
        lcg 24; len=$R; s=''; k=0
        while [ "$k" -lt "$len" ]; do
            lcg 95; s="$s${CHARS:$R:1}"
            k=$(( k + 1 ))
        done
        lines[$j]="$s"; j=$(( j + 1 ))
    done
    run_case ${lines[@]+"${lines[@]}"}; check_run "random#$i"
    i=$(( i + 1 ))
done

# (b) mutated valid transcripts -- byte flips, deletions, duplications, truncation
i=0
while [ "$i" -lt 400 ]; do
    lcg 4; np=$(( R + 1 )); j=0; recs=()
    while [ "$j" -lt "$np" ]; do
        lcg 64000; port=$(( R + 1024 ))
        lcg 5; set -- $CLASSES; shift $R 2>/dev/null || set -- lo
        recs[$j]="$port:${1:-lo}"; j=$(( j + 1 ))
    done
    lines=("cs193v-portwatch 1" "BEGIN $np" ${recs[@]+"${recs[@]}"} "END")
    # mutate exactly one line
    lcg ${#lines[@]}; t=$R; v="${lines[$t]}"
    lcg 5
    case "$R" in
        0) lines[$t]="${v}X" ;;
        1) lines[$t]="${v%?}" ;;
        2) lines[$t]="$v$v" ;;
        3) lines[$t]="" ;;
        *) lines[$t]="${v//[0-9]/9}" ;;
    esac
    run_case ${lines[@]+"${lines[@]}"}; check_run "mutant#$i"
    i=$(( i + 1 ))
done

assert_eq "fuzz:only-three-outcomes-ever" "" "$BAD_RC"
assert_eq "fuzz:stderr-stays-clean"       "" "$BAD_ERR"
assert_eq "fuzz:accepted-ports-are-sound" "" "$BAD_PORT"
record "fuzz:cases-run" "$N (seed $SEED)"

# ─── every hostile case actually RAN ───────────────────────────────────────────
# NOT BOOKKEEPING. A bash arithmetic error -- $(( 08 )) with no 10# prefix, say -- does not
# return a status: it unwinds the ENTIRE function call stack to top level, so hostile_fatal's
# check never executes and the assertion silently disappears. Measured. The suite then reports
# "0 fail" while two cases did not run, which is precisely the failure this project forbids.
#
# A LITERAL, deliberately, in the same spirit as ports:count-is-47 in 10-static.sh: add a case
# and you are made to come and look at this line.
assert_eq "fuzz:every-hostile-case-ran" "34" "$HOSTILE_RAN"

# ─── a malformed frame must not corrupt the next parse ─────────────────────────
# Halting, not resyncing: after a fatal the supervisor stops. What must hold is that a FRESH
# parse is unaffected by the last one -- otherwise one bad frame poisons the session.
run_case "$H" "BEGIN 1" "0x1f:lo" "END"
run_case "$H" "BEGIN 1" "3000:lo" "END"
assert_eq "fuzz:a-fresh-parse-is-not-poisoned" " 3000:lo" "$RUN_PORTS"
