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
# dynports_line LINE          0 = consumed, 1 = frame complete, 2 = fatal, 3 = skipped
#                             on 1: $DYNPORTS_FRAME is "port:class port:class ..."
#                             on 2: $DYNPORTS_FATAL is a one-line reason
# dynports_lost               a read timed out: the front of the next line may be gone (#340).
#                             3 is only ever returned after one; see the last section.
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
#
# THE PAYLOADS HAVE TO FIT THE PARSER'S OWN LENGTH CAPS, and until the #155 audit they did not.
# A canary path is long, so all five were 123-126 characters -- while dynports_line rejects a
# record over 10 characters and a BEGIN line over 9. Every one of them therefore died at the
# length check and never reached the port parser, the class allowlist, or any arithmetic. The
# assertion was checking that a 125-character string is rejected by a 10-character cap, and it
# would have passed just as happily against a parser that eval'd its input. Measured: with
# `: $(( p ))` inserted into the parse path, it stayed green across the whole static+unit tier.
#
# So there are two groups now, and the split is the point.
INJECT='$('"'"'touch '"$CANARY"''"'"')'
rm -f "$CANARY"

# GROUP 1 -- the long payloads. Kept, because they do test something real: that the length caps
# hold and reject before anything else looks at the bytes. They cannot test execution, and the
# name now says which of the two it is rather than claiming the stronger one.
run_case "cs193v-portwatch 1" "BEGIN 1" "3000:$INJECT" "END"
run_case "cs193v-portwatch 1" "BEGIN 1" "$INJECT:lo" "END"
run_case "cs193v-portwatch 1" "BEGIN $INJECT" "END"
run_case "cs193v-portwatch 1" "a[\$(touch $CANARY)]"
run_case "cs193v-portwatch 1" "BEGIN 1" "3000:lo\`touch $CANARY\`" "END"
assert_no_file "fuzz:an-over-long-record-is-rejected-before-anything-evaluates" "$CANARY"

# GROUP 2 -- payloads that FIT, so they reach the code this property is actually about.
#
# Three facts, all measured on bash 3.2.57 while fixing this, because the note above is right in
# substance and easy to read too loosely:
#
#   * A redirection with no command still runs. `>c` creates the file `c` in the current
#     directory, and it is the shortest useful payload there is.
#   * A BARE `$(...)` is INERT as an arithmetic operand. Bash does not command-substitute a
#     variable's VALUE, it parses it, and `$(>c)` is answered with "syntax error: operand
#     expected". What executes under arithmetic is a value shaped like an ARRAY SUBSCRIPT,
#     because bash evaluates a subscript arithmetically and expands it on the way.
#   * ...and under `set -u`, which this suite and the launcher both run under, even that only
#     fires if the array name is ALREADY DECLARED. `a[$(>x)]` with `a` unset dies on "a: unbound
#     variable" first, and `c[$(>x)]` where c holds a non-numeric string dies on the recursive
#     lookup of that string. So `set -u` plus a parse path with no arrays in it is a real second
#     line of defence, and supervisor:no-array-subscripts-in-the-parse-path is what keeps it.
#
# Hence two short payloads, aimed at the two mutation shapes that would defeat different
# defences: `$(>c):lo` (8 chars) is what an eval-shaped mutation executes, and `c[`>k`]:lo`
# (exactly 10, which is why the class is `lo` -- the shortest the allowlist admits) is what an
# arithmetic-shaped one executes. Run from inside $WORK so the relative names land there.
#
# BEGIN cannot be covered this way, and that is a limit rather than an omission: `BEGIN ` is six
# of its nine characters. The BEGIN line is covered by the count validator and by group 1.
rm -f "$WORK/c" "$WORK/k"
( cd "$WORK" || exit 1
  run_case "cs193v-portwatch 1" "BEGIN 1" '$(>c):lo'   "END"   # eval-shaped, PORT field
  run_case "cs193v-portwatch 1" "BEGIN 1" '1:$(>c)'    "END"   # eval-shaped, CLASS field
  run_case "cs193v-portwatch 1" "BEGIN 1" 'c[`>k`]:lo' "END"   # arithmetic-shaped, PORT field
) >/dev/null 2>&1
assert_no_file "fuzz:nothing-is-executed" "$WORK/c"
assert_no_file "fuzz:nothing-is-executed-by-a-subscript" "$WORK/k"

# AND A POSITIVE CONTROL, for the reason 27-installer-windows.sh's win-hijack:* has one: the
# absence of a file is also what a harness that died on its first line produces, so a green
# assert_no_file means nothing until the detector is known to be live. This declares the array
# the bullet above says is required and then feeds it the same shape, so the canary MUST appear.
# If this ever fails, every assert_no_file above is vacuous and should be treated as unproven.
( cd "$WORK" || exit 1
  # shellcheck disable=SC2034   # read only by the arithmetic below
  declare -a canary_arr=(0)
  inj='canary_arr[$(>positive)]'
  : $(( inj )) 2>/dev/null || true )
assert_file "fuzz:the-canary-mechanism-really-fires" "$WORK/positive"

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
# 3 exactly three outcomes  (0, 1 or 2 -- never a bash error status; no read is lost here, so
#                            the fourth, 3, cannot occur. The last section covers it.)
# 4 clean stderr            (no "integer expected", no "value too great for base", no "unbound")
# 5 accepted ports are sound
# 6 bounded                 (nothing here should be slow; the tier budget catches it)
#
# Property 4 has teeth: the overflow case leaked `[: ...: integer expected` to stderr during
# design and fell through, which is exactly the shape "never fail silently" forbids.
BAD_RC=''; BAD_ERR=''; BAD_PORT=''; N=0
check_run() {                         # check_run LABEL
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
    # COUNTED LAST, for hostile_fatal's reason: a case that unwound part-way through is not a case.
    N=$(( N + 1 ))
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
# AND ASSERTED, for the reason the hostile corpus's count is (below): an arithmetic error in either
# loop abandons the rest of that loop, and every property above then holds over the cases that did
# run. Measured: one in (a)'s eighth case left 408 cases and this suite green (#506).
assert_eq "fuzz:every-generated-case-ran" "800" "$N"

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
# parse is unaffected by the last one -- otherwise one bad frame poisons the session. (The resync
# after a TIMED-OUT READ is a different thing, and is not a fatal; see the last section.)
run_case "$H" "BEGIN 1" "0x1f:lo" "END"
run_case "$H" "BEGIN 1" "3000:lo" "END"
assert_eq "fuzz:a-fresh-parse-is-not-poisoned" " 3000:lo" "$RUN_PORTS"

# ─── a read that timed out, and the resync after it  (#340) ────────────────────
# A `read -t` whose deadline lands part-way through a line has already consumed the front of it,
# and the rest then arrives as a line of its own: `EGIN 1` from `BEGIN 1`, which ended the
# supervisor, or `8343:lo` from `28343:lo`, which is somebody else's port. dynports_read now tells
# the parser after every timeout (dynports_lost), and the parser skips to the next line that starts
# a tick -- `BEGIN ` or `WARN ` -- or an `ERR `, then parses that line exactly as strictly as ever.
#
# @LOST IN A TRANSCRIPT IS dynports_read's TIMEOUT ARM, and the line after it is whatever survived
# the tear. 12-run-timeout.sh makes real torn reads on whatever bash runs it; here the parser is
# driven with what they produce, which is what lets a fuzz reach every cut of every line.
if command -v dynports_lost >/dev/null 2>&1; then
    pass "resync:the-loss-hook-exists"
else
    fail "resync:the-loss-hook-exists" \
"dynports_lost is not defined in files/cs193v-ui.sh, so every resync case below drives nothing."
fi

# run_case plus @LOST, with sup_loop's bookkeeping: a WARN and a resync's report are each taken
# and cleared after every line, as sup_loop does. RUN_RCS is the SEQUENCE of return codes, with L
# for a loss, because "strictness came back" is a property of the sequence and not of the last rc.
#   -> RUN_RC RUN_RCS RUN_FRAMES RUN_N RUN_WARNS RUN_WARN RUN_RESYNCS RUN_ERR
run_lost() {
    local l
    dynports_reset
    DYNPORTS_RESYNCED=''
    RUN_RC=0; RUN_RCS=''; RUN_FRAMES=''; RUN_N=0; RUN_WARNS=0; RUN_WARN=''; RUN_RESYNCS=''
    { for l in "$@"; do
        if [ "$l" = @LOST ]; then dynports_lost; RUN_RCS="$RUN_RCS L"; continue; fi
        RUN_N=$(( RUN_N + 1 ))
        dynports_line "$l"; RUN_RC=$?; RUN_RCS="$RUN_RCS $RUN_RC"
        [ -n "${DYNPORTS_WARN:-}" ] && { RUN_WARNS=$(( RUN_WARNS + 1 )); RUN_WARN="$DYNPORTS_WARN"; DYNPORTS_WARN=''; }
        [ -n "${DYNPORTS_RESYNCED:-}" ] && { RUN_RESYNCS="$RUN_RESYNCS $DYNPORTS_RESYNCED"; DYNPORTS_RESYNCED=''; }
        case "$RUN_RC" in
            0|3) ;;
            1) RUN_FRAMES="${RUN_FRAMES}[${DYNPORTS_FRAME:-}]" ;;
            *) break ;;
        esac
      done; } 2>"$ERRF"
    RUN_ERR="$(<"$ERRF")"
}

# The WSL lid close (a torn BEGIN), and the 3.2 race's wrong port (a torn record).
run_lost "$H" "BEGIN 1" "28343:lo" "END" @LOST "EGIN 1" "28343:lo" "END" "BEGIN 1" "28343:lo" "END"
assert_eq "resync:a-torn-BEGIN-is-skipped-to-the-next-frame" "[28343:lo][28343:lo]|1|" "$RUN_FRAMES|$RUN_RC|$RUN_ERR"
run_lost "$H" "BEGIN 1" "28343:lo" "END" "BEGIN 1" @LOST "8343:lo" "END" "BEGIN 1" "28343:lo" "END"
assert_eq "resync:a-torn-record-is-never-a-port" "[28343:lo][28343:lo]" "$RUN_FRAMES"
run_lost "$H" "BEGIN 2" "3000:lo" @LOST "8343:lo" "END" "BEGIN 1" "5173:lo" "END"
assert_eq "resync:the-frame-in-progress-is-dropped" "[5173:lo]" "$RUN_FRAMES"

# THE BOUND, ON BOTH SIDES, AS A LITERAL. 130 is the most a valid stream can put between a timeout
# and the next line that starts a tick: a torn `BEGIN 128`'s remainder, 128 records and END. The
# first case reaches it and must be accepted; the second is the 131st line and must be fatal --
# asserted as 130, not as "fatal eventually", so a looser bound is a red and not a pass.
set -- "$H" "BEGIN 0" "END" @LOST "EGIN $DYNPORTS_MAX"
i=0; while [ "$i" -lt "$DYNPORTS_MAX" ]; do set -- "$@" "$(( 2000 + i )):lo"; i=$(( i + 1 )); done
run_lost "$@" "END" "WARN too-many-listeners 200" "BEGIN 1" "3000:lo" "END"
assert_eq "resync:the-largest-legitimate-skip-fits-the-bound" "[][3000:lo]|1| 130" "$RUN_FRAMES|$RUN_RC|$RUN_RESYNCS"
set -- "$H" "BEGIN 0" "END" @LOST
i=0; while [ "$i" -lt 1000 ]; do set -- "$@" "3000:lo"; i=$(( i + 1 )); done
run_lost "$@"
assert_eq "resync:the-131st-skipped-line-is-fatal" \
          "2|130|no frame began within 130 lines of a timed-out read: 3000:lo" \
          "$RUN_RC|$(( RUN_N - 4 ))|${DYNPORTS_FATAL:-}"

# THE LINE THAT ENDS IT IS PARSED STRICTLY, asserted at that line and by its reason, with a valid
# frame after it so that a lax exit cannot be rescued by a later check.
for spec in "count-1x|BEGIN 1x|non-decimal count: 1x" "count-129|BEGIN 129|count over 128" \
            "count-empty|BEGIN |non-decimal count: ''" "count-01|BEGIN 01|non-canonical count: 01" \
            "WARN-over-64|WARN too-many-listeners 2000000000000000000000000000000000000000000|WARN line too long"; do
    tag=${spec%%|*}; rest=${spec#*|}; b=${rest%%|*}; want=${rest#*|}
    run_lost "$H" "BEGIN 0" "END" @LOST "junk" "$b" "BEGIN 1" "3000:lo" "END"
    assert_eq "resync:the-exit-line-is-strict:$tag" " 0 0 1 L 3 2|$want" "$RUN_RCS|${DYNPORTS_FATAL:-}"
done
# ...AND STRICTNESS COMES BACK AFTER IT, whichever line ended it. A resync that never ended would
# skip junk between frames for the rest of the session and pass every case above.
run_lost "$H" "BEGIN 0" "END" @LOST "junk" "BEGIN 0" "END" "junk"
assert_eq "resync:strictness-returns-after-a-BEGIN" " 0 0 1 L 3 0 1 2|line outside a frame: junk" "$RUN_RCS|${DYNPORTS_FATAL:-}"
run_lost "$H" "BEGIN 0" "END" @LOST "junk" "WARN too-many-listeners 200" "junk"
assert_eq "resync:strictness-returns-after-a-WARN" " 0 0 1 L 3 0 2|line outside a frame: junk" "$RUN_RCS|${DYNPORTS_FATAL:-}"
run_lost "$H" "BEGIN 0" "END" @LOST "junk" "ERR cannot-open-tick-fifo"
assert_eq "resync:an-ERR-ends-it-as-the-watcher-stopping" "2|the watcher stopped: cannot-open-tick-fifo" "$RUN_RC|${DYNPORTS_FATAL:-}"

# A CLEAN TIMEOUT LOSES NOTHING. The watcher sends a WARN BEFORE the frame it describes, so the
# timeout before a >128-listener tick resumes at the WARN: it is honoured, and the resync reports
# that it skipped nothing -- which is what lets sup_loop log a skip only when there was one.
run_lost "$H" "BEGIN 0" "END" @LOST "WARN too-many-listeners 200" "BEGIN 0" "END"
assert_eq "resync:a-WARN-after-a-clean-timeout-is-honoured" '[][]| 0 0 1 L 0 0 1|1|too-many-listeners\ 200| 0|' \
          "$RUN_FRAMES|$RUN_RCS|$RUN_WARNS|$RUN_WARN|$RUN_RESYNCS|$RUN_ERR"

# THE HANDSHAKE STAYS STRICT. Guards, green before #340 and after it: a timeout before the
# handshake is a slow `podman exec` and changes nothing, and the version check is never skipped.
run_lost @LOST "$H" "BEGIN 1" "3000:lo" "END"
assert_eq "handshake:a-timeout-before-it-changes-nothing" "[3000:lo]" "$RUN_FRAMES"
run_lost @LOST "s193v-portwatch 1" "BEGIN 1" "3000:lo" "END"
assert_eq "handshake:a-torn-handshake-is-fatal" "2|bad handshake: s193v-portwatch\ 1" "$RUN_RC|${DYNPORTS_FATAL:-}"
run_lost @LOST "cs193v-portwatch 2" "BEGIN 1" "3000:lo" "END"
assert_eq "handshake:a-timeout-does-not-skip-the-version-check" "2" "$RUN_RC"
run_lost @LOST "BEGIN 1" "3000:lo" "END"
assert_eq "handshake:a-timeout-does-not-admit-a-frame-before-it" "2" "$RUN_RC"

run_lost "$H" "BEGIN 0" "END" @LOST "junk" "28343:lo"
assert_eq "resync:a-skipped-line-returns-3" " 0 0 1 L 3 3" "$RUN_RCS"
# THE BUDGET IS PER LOSS: two tears in a row may legitimately skip up to twice the bound.
set -- "$H" "BEGIN 0" "END" @LOST
i=0; while [ "$i" -lt 100 ]; do set -- "$@" "3000:lo"; i=$(( i + 1 )); done
set -- "$@" @LOST
i=0; while [ "$i" -lt 100 ]; do set -- "$@" "3000:lo"; i=$(( i + 1 )); done
run_lost "$@" "BEGIN 1" "5173:lo" "END"
assert_eq "resync:each-loss-gets-a-fresh-budget" "[][5173:lo]|1" "$RUN_FRAMES|$RUN_RC"
# A torn BEGIN (3 skipped), a torn record (2) and a clean timeout (0): what sup_loop logs, or not.
run_lost "$H" "BEGIN 0" "END" @LOST "EGIN 1" "28343:lo" "END" "BEGIN 1" @LOST "8343:lo" "END" "BEGIN 0" "END" @LOST "BEGIN 0" "END"
assert_eq "resync:each-resync-reports-what-it-skipped" " 3 2 0" "$RUN_RESYNCS"

# ─── the property: one or two losses anywhere, any cut, and only whole frames ──
# A CUT is how many bytes of that line the timed-out read took. 0 is a clean timeout before the
# line; its length leaves only the newline; length + 1 loses the newline too, which bash 3.2's
# SIGALRM can do by landing after the delimiter is read. A second loss may tear what the first
# left of the same line.
#
# THE ORACLE: a frame is accepted iff no loss falls in [its BEGIN, its END], a cut-0 loss on its
# BEGIN counting as before it; a WARN is honoured iff no loss took bytes from it.
BAD=''; BADRC=''; BADERR=''; BADWARN=''; NL=0; N2=0; NWHOLE=0
i=0
while [ "$i" -lt 400 ]; do
    L=("$H"); FB=(); FE=(); FR=(); WI=(); nf=0; nw=0
    lcg 4; k=$(( R + 2 )); j=0
    while [ "$j" -lt "$k" ]; do
        lcg 5; [ "$R" = 0 ] && { WI[$nw]=${#L[@]}; nw=$(( nw + 1 )); L+=("WARN too-many-listeners 200"); }
        lcg 4; nr=$R
        FB[$nf]=${#L[@]}; L+=("BEGIN $nr"); s=''; r=0
        while [ "$r" -lt "$nr" ]; do
            lcg 64000; p=$(( R + 1024 )); lcg 5; set -- $CLASSES; shift "$R"
            # A 5-DIGIT loalt IS "record too long" (#505), which is not this section's to find.
            [ "$1" = loalt ] && p=$(( p % 9000 + 1000 ))
            L+=("$p:$1"); s="$s $p:$1"; r=$(( r + 1 ))
        done
        FE[$nf]=${#L[@]}; L+=("END"); FR[$nf]="[${s# }]"
        nf=$(( nf + 1 )); j=$(( j + 1 ))
    done
    n=${#L[@]}
    lcg $(( n - 1 )); t1=$(( R + 1 )); lcg $(( ${#L[$t1]} + 2 )); b1=$R
    losses="$t1:$b1"
    lcg 7
    if [ "$R" -lt 4 ]; then
        lcg $(( n - t1 )); t2=$(( R + t1 )); lcg $(( ${#L[$t2]} + 2 )); b2=$R
        if [ "$t2" -gt "$t1" ]; then losses="$losses $t2:$b2"; N2=$(( N2 + 1 ))
        elif [ "$b1" -le "${#L[$t1]}" ]; then [ "$b2" -ge "$b1" ] || b2=$b1; losses="$losses $t2:$b2"; N2=$(( N2 + 1 ))
        fi
    fi
    want=''; f=0
    while [ "$f" -lt "$nf" ]; do
        ok=1
        for x in $losses; do
            t=${x%%:*}; b=${x#*:}
            if [ "$t" -lt "${FB[$f]}" ] || [ "$t" -gt "${FE[$f]}" ] || { [ "$t" -eq "${FB[$f]}" ] && [ "$b" -eq 0 ]; }; then :; else ok=''; fi
        done
        [ -n "$ok" ] && want="$want${FR[$f]}"
        f=$(( f + 1 ))
    done
    wantw=0; w=0
    while [ "$w" -lt "$nw" ]; do
        ok=1
        for x in $losses; do [ "${x%%:*}" -eq "${WI[$w]}" ] && [ "${x#*:}" -gt 0 ] && ok=''; done
        [ -n "$ok" ] && wantw=$(( wantw + 1 ))
        w=$(( w + 1 ))
    done
    set --; li=0
    while [ "$li" -lt "$n" ]; do
        bl=-1
        for x in $losses; do
            [ "${x%%:*}" -eq "$li" ] && { set -- "$@" @LOST; [ "${x#*:}" -gt "$bl" ] && bl=${x#*:}; }
        done
        if [ "$bl" -lt 0 ]; then set -- "$@" "${L[$li]}"
        elif [ "$bl" -le "${#L[$li]}" ]; then set -- "$@" "${L[$li]:$bl}"
        else NWHOLE=$(( NWHOLE + 1 ))
        fi
        li=$(( li + 1 ))
    done
    run_lost "$@"
    [ "$RUN_FRAMES" = "$want" ] || BAD="${BAD:-case $i (losses $losses): want $want got $RUN_FRAMES}"
    case "$RUN_RC" in 0|1|3) ;; *) BADRC="${BADRC:-case $i (losses $losses) rc=$RUN_RC ${DYNPORTS_FATAL:-}}" ;; esac
    [ -z "$RUN_ERR" ] || BADERR="${BADERR:-case $i: $RUN_ERR}"
    [ "$RUN_WARNS" = "$wantw" ] || BADWARN="${BADWARN:-case $i (losses $losses): want $wantw WARNs got $RUN_WARNS}"
    NL=$(( NL + 1 ))                  # COUNTED LAST, for hostile_fatal's reason
    i=$(( i + 1 ))
done
assert_eq "resync:fuzz:only-whole-frames-are-accepted" "" "$BAD"
assert_eq "resync:fuzz:a-loss-is-never-fatal" "" "$BADRC"
assert_eq "resync:fuzz:stderr-stays-clean" "" "$BADERR"
assert_eq "resync:fuzz:every-intact-WARN-is-honoured" "" "$BADWARN"
assert_eq "resync:fuzz:every-case-ran" "400" "$NL"
record "resync:fuzz:cases-run" "$NL ($N2 with two losses, $NWHOLE whole lines lost, seed $SEED)"

# ─── ...and random bytes after a loss: property 4, clean stderr, on the resync path
BADERR=''; NR=0
i=0
while [ "$i" -lt 300 ]; do
    set -- "$H" "BEGIN 0" "END" @LOST
    lcg 8; m=$(( R + 1 )); j=0
    while [ "$j" -lt "$m" ]; do
        lcg 20; len=$R; s=''; q=0
        while [ "$q" -lt "$len" ]; do lcg 95; s="$s${CHARS:$R:1}"; q=$(( q + 1 )); done
        lcg 4
        case "$R" in 0) s="BEGIN $s" ;; 1) s="WARN $s" ;; esac
        set -- "$@" "$s"; j=$(( j + 1 ))
    done
    run_lost "$@"
    [ -z "$RUN_ERR" ] || BADERR="${BADERR:-random#$i: $RUN_ERR}"
    NR=$(( NR + 1 ))                  # COUNTED LAST, as above
    i=$(( i + 1 ))
done
assert_eq "resync:random:stderr-stays-clean" "" "$BADERR"
assert_eq "resync:random:every-case-ran" "300" "$NR"
record "resync:random:cases-run" "$NR (seed $SEED)"
