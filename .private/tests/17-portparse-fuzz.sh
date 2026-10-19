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
#
# EXACTLY WHAT THE WATCHER WRITES, AND NOTHING ELSE (#505). Every generated-input property here
# used to be a "must not" -- nothing executed, no stray status, no unsound port -- and a parser that
# refused a frame satisfied all of them. So the gate refused `54321:loalt`, a record the watcher
# sends for any server on another 127.x address, while this suite generated that record in 101 of
# its 800 cases and stayed green: a refusal was always an allowed outcome. The generated section
# now asks the converse too, through the same read sup_loop uses. Each case's outcome -- the frames
# applied, the warnings surfaced, and the line it died on -- must equal what an independent grammar
# of the watcher's output says, and for a case built to be legal, what the generator built.

set -u
. "$(dirname -- "$0")/lib/assert.sh"

cd "$REPO" || exit 1

# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=.private/files/cs193v-ui.sh
. "$PRIVATE/files/cs193v-ui.sh"

# ─── the contract under test ───────────────────────────────────────────────────
# dynports_reset              start a fresh parse
# dynports_read SECS          0 = a line in $DYNPORTS_LINE, 1 = timeout, 2 = the stream ended
# dynports_line LINE          0 = consumed, 1 = frame complete, 2 = fatal
#                             on 0: $DYNPORTS_WARN may hold a warning the line carried
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

# THE WATCHER'S OWN HANDSHAKE AND CAP, read from cs193v-portwatch rather than from the gate, so the
# grammar and the generators below follow PW_PROTO and PW_MAX without borrowing the gate's idea of
# them; 10-static.sh holds each equal to the gate's, and the pair to each other. The line limit is
# this suite's own literal for the same reason.
H="$(sed -n "s/^PW_PROTO='\(.*\)'$/\1/p" "$PRIVATE/files/cs193v-portwatch")"
FZ_MAX="$(sed -n 's/^PW_MAX=\([0-9][0-9]*\)$/\1/p' "$PRIVATE/files/cs193v-portwatch")"
if [ -z "$H" ] || [ -z "$FZ_MAX" ]; then
    fail "fuzz:the-watchers-handshake-and-cap-were-read" \
         "no PW_PROTO='...' or no PW_MAX=N line in cs193v-portwatch (got '$H' and '$FZ_MAX')"
    exit 1
fi
pass "fuzz:the-watchers-handshake-and-cap-were-read"
FZ_LINE_MAX=64

fz_fill() {                           # fz_fill STR N -> FZ_F, STR N times (counted, not measured)
    local n=0
    FZ_F=''
    while [ "$n" -lt "$2" ]; do FZ_F="$FZ_F$1"; n=$(( n + 1 )); done
}

# ─── drive one transcript through the read and the parse ───────────────────────
# As sup_loop does: dynports_read, then dynports_line on what it read, until a fatal or the end.
# Builtins only, one file per case, no fork -- 1600 cases cost seconds, not minutes. EVERY case in
# this suite comes through here, the hand-built ones by run_case and the generated ones by the loop
# that judges them, so none of them skips the read the supervisor's lines arrive through.
fz_drive() {                          # stdin = one case -> FZ_OUT; RUN_RC, RUN_PORTS for check_run
    local k=0
    dynports_reset
    FZ_OUT=''; RUN_RC=0; RUN_PORTS=''
    while :; do
        dynports_read 1
        case "$?" in
            0) ;;
            1) FZ_OUT="${FZ_OUT}T"; return 0 ;;
            *) FZ_OUT="${FZ_OUT}E"; return 0 ;;
        esac
        k=$(( k + 1 ))
        dynports_line "$DYNPORTS_LINE"
        RUN_RC=$?
        case "$RUN_RC" in
            0) ;;
            1) FZ_OUT="${FZ_OUT}[$DYNPORTS_FRAME]"; RUN_PORTS="$RUN_PORTS $DYNPORTS_FRAME" ;;
            2) FZ_OUT="${FZ_OUT}F@$k"; return 0 ;;
            *) FZ_OUT="$FZ_OUT?$RUN_RC"; return 0 ;;
        esac
        if [ -n "${DYNPORTS_WARN:-}" ]; then FZ_OUT="$FZ_OUT{$DYNPORTS_WARN}"; DYNPORTS_WARN=''; fi
    done
}
run_case() {                          # run_case LINE... -- each LINE and a newline, driven
    printf '%s\n' "$@" > "$WORK/case"
    { fz_drive; } < "$WORK/case" 2>/dev/null
}

# ─── property 1: nothing is ever executed ──────────────────────────────────────
# The strongest one. $(( )), (( )), [[ -eq ]], ${v:x:y} and ${a[x]} all EXECUTE command
# substitutions found in their operands -- measured -- so a parser that reaches any of them with
# unvalidated input is a shell injection. `case` is the only construct that evaluates nothing,
# which is why it has to come first in the parser.
#
# THE PAYLOADS HAVE TO FIT THE PARSER'S OWN LENGTH CAPS, and until the #155 audit they did not.
# A canary path is long, so all five were 123-126 characters -- while dynports_line rejected a
# record over 10 characters and a BEGIN line over 9 (it now rejects any line of 64 or more). Every
# one of them therefore died at the length check and never reached the port parser, the class
# allowlist, or any arithmetic. The
# assertion was checking that a 125-character string is rejected by a 10-character cap, and it
# would have passed just as happily against a parser that eval'd its input. Measured: with
# `: $(( p ))` inserted into the parse path, it stayed green across the whole static+unit tier.
#
# So there are two groups now, and the split is the point.
INJECT='$('"'"'touch '"$CANARY"''"'"')'
rm -f "$CANARY"

# GROUP 1 -- the long payloads. Kept, because they do test something real: that the line-length
# rule holds and rejects before anything else looks at the bytes. They cannot test execution, and the
# name now says which of the two it is rather than claiming the stronger one. So what it asserts is
# the reason each was refused, and each carries FZ_LINE_MAX characters of padding. Unpadded, their
# length was the canary path's: with TMPDIR unset on Linux they came to 41-47 characters, the class
# and count checks refused them, and the rule this group is about was never reached.
fz_fill x "$FZ_LINE_MAX"; PAD="$FZ_F"; G1=''
g1_case() { run_case "$@"; G1="$G1|${DYNPORTS_FATAL:-}"; }
g1_case "$H" "BEGIN 1" "3000:$INJECT$PAD" "END"
g1_case "$H" "BEGIN 1" "$INJECT$PAD:lo" "END"
g1_case "$H" "BEGIN $INJECT$PAD" "END"
g1_case "$H" "a[\$(touch $CANARY)]$PAD"
g1_case "$H" "BEGIN 1" "3000:lo\`touch $CANARY\`$PAD" "END"
assert_eq "fuzz:an-over-long-record-is-rejected-before-anything-evaluates" \
          "|line too long|line too long|line too long|line too long|line too long" "$G1"

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
# Hence short payloads, aimed at the two mutation shapes that would defeat different defences:
# `$(>c)` is what an eval-shaped mutation executes, and `c[`>k`]` is what an arithmetic-shaped one
# executes. Run from inside $WORK so the relative names land there.
#
# THEY USED TO BE SIZED TO A 10-CHARACTER RECORD CAP, and the BEGIN line could not be covered at all,
# `BEGIN ` being six of its nine characters. #505 deleted both caps: the record cap could only repeat
# bounds dynports_port and the class allowlist already set, and it fell a character behind them. So
# the only limit a payload has to fit now is the 64-character line, and every field that reaches a
# comparison or arithmetic gets one: the record's port and class, the BEGIN count, and the WARN
# listener count.
rm -f "$WORK/c" "$WORK/k"
( cd "$WORK" || exit 1
  run_case "$H" "BEGIN 1" '$(>c):lo'   "END"   # eval-shaped, PORT field
  run_case "$H" "BEGIN 1" '1:$(>c)'    "END"   # eval-shaped, CLASS field
  run_case "$H" "BEGIN 1" 'c[`>k`]:lo' "END"   # arithmetic-shaped, PORT field
  run_case "$H" 'BEGIN $(>c)'   "END"          # eval-shaped, BEGIN count
  run_case "$H" 'BEGIN c[`>k`]' "END"          # arithmetic-shaped, BEGIN count
  run_case "$H" 'WARN too-many-listeners $(>c)'   "BEGIN $FZ_MAX"   # eval-shaped
  run_case "$H" 'WARN too-many-listeners c[`>k`]' "BEGIN $FZ_MAX"   # arithmetic
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
run_case "$H" "BEGIN 3" "3000:lo" "5173:any" "9000:v6lo" "END"
assert_eq "fuzz:a-valid-frame-is-accepted" " 3000:lo 5173:any 9000:v6lo" "$RUN_PORTS"
assert_eq "fuzz:a-valid-frame-returns-1"   "1" "$RUN_RC"
run_case "$H" "BEGIN 0" "END"
assert_eq "fuzz:an-empty-frame-is-accepted" "1" "$RUN_RC"
# The boundaries are valid, not hostile: 1 and 65535 are real ports and must survive the gate.
run_case "$H" "BEGIN 2" "1:lo" "65535:eth" "END"
assert_eq "fuzz:boundary-ports-are-accepted" " 1:lo 65535:eth" "$RUN_PORTS"
# Nor are ascending ports that share digits refused: the gate's order check must compare ports as
# numbers, and as strings 13000 would come before 3000.
run_case "$H" "BEGIN 3" "300:lo" "3000:lo" "13000:lo" "END"
assert_eq "fuzz:ascending-ports-that-share-digits-are-accepted" " 300:lo 3000:lo 13000:lo" "$RUN_PORTS"

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
hostile_fatal "bad-handshake"       "cs193v-portwatch 2" "BEGIN 0" "END"
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
hostile_fatal "count-over-cap"       "$H" "BEGIN $(( FZ_MAX + 1 ))" "END"
hostile_fatal "count-nondecimal"     "$H" "BEGIN xx" "END"
hostile_fatal "nested-begin"         "$H" "BEGIN 1" "BEGIN 1" "END"
hostile_fatal "end-without-begin"    "$H" "END"
hostile_fatal "record-outside-frame" "$H" "3000:lo"
hostile_fatal "trailing-space"       "$H" "BEGIN 1" "3000:lo " "END"
hostile_fatal "leading-space"        "$H" "BEGIN 1" " 3000:lo" "END"
hostile_fatal "carriage-return"      "$H" "BEGIN 1" "$(printf '3000\r'):lo" "END"
hostile_fatal "unknown-line-type"    "$H" "BEGIN 1" "MAYBE 3" "END"
# A RECORD TOO LONG meets the one line rule now, not a record cap (#505), and has to say so: the class
# allowlist refuses this record too, so the reason is the only proof the rule is what fired.
fz_fill o $(( FZ_LINE_MAX - 7 ))
hostile_fatal "record-too-long"      "$H" "BEGIN 1" "3000:lo$FZ_F" "END"
assert_eq "fuzz:a-record-too-long-is-refused-for-its-length" "line too long" "${DYNPORTS_FATAL:-}"
# A PORT TWICE IN ONE FRAME. The watcher merges by port, so only a broken one sends this, and the
# supervisor would publish the repeat -- a second refusal for the port, which the state file's
# writer now refuses (#406), so every publish after it would fail and the file go stale. Fatal
# here instead, like any other frame the watcher cannot have meant. Once with one class twice,
# once with two, so a check that compared whole records would still let the second through.
hostile_fatal "repeated-port"        "$H" "BEGIN 2" "21500:v6lo" "21500:v6lo" "END"
hostile_fatal "repeated-port-two-classes" "$H" "BEGIN 2" "3000:lo" "3000:any" "END"
# OUT OF ORDER. The watcher sorts every frame ascending (pw_scan_text), so a frame that is not is a
# frame it did not write (#505). The second is the positive control above, reversed.
hostile_fatal "descending-ports"     "$H" "BEGIN 2" "5173:lo" "3000:lo" "END"
hostile_fatal "shared-digits-descending" "$H" "BEGIN 3" "13000:lo" "3000:lo" "300:lo" "END"
# A WARN THE WATCHER WOULD NOT SEND. It sends exactly one, `too-many-listeners N`, only when N is
# over the cap, only between frames, and always straight before the BEGIN of the capped frame.
W="WARN too-many-listeners $(( FZ_MAX + 72 ))"
hostile_fatal "warn-inside-a-frame"  "$H" "BEGIN 1" "$W" "3000:lo" "END"
hostile_fatal "warn-then-a-short-begin" "$H" "$W" "BEGIN 1" "3000:lo" "END"
hostile_fatal "warn-then-end"        "$H" "$W" "END"
hostile_fatal "warn-twice"           "$H" "$W" "$W" "BEGIN $FZ_MAX"
hostile_fatal "warn-count-at-the-cap" "$H" "WARN too-many-listeners $FZ_MAX" "BEGIN $FZ_MAX"
hostile_fatal "warn-count-octal"     "$H" "WARN too-many-listeners 0$(( FZ_MAX + 72 ))" "BEGIN $FZ_MAX"
hostile_fatal "warn-count-over-a-port" "$H" "WARN too-many-listeners 65536" "BEGIN $FZ_MAX"
hostile_fatal "warn-count-exponent"  "$H" "WARN too-many-listeners 2e3" "BEGIN $FZ_MAX"
hostile_fatal "warn-unknown"         "$H" "WARN slow-scan 3" "BEGIN 0" "END"
hostile_fatal "warn-trailing-space"  "$H" "$W " "BEGIN $FZ_MAX"
# FZ_LINE_MAX characters: one more than any line the read can take whole (dynports_read).
fz_fill x $(( FZ_LINE_MAX - 5 ))
hostile_fatal "warn-line-too-long"   "$H" "WARN $FZ_F" "BEGIN 0" "END"

# ─── generated input: the outcome is exactly the grammar's ─────────────────────
# Every case below is a byte string, driven through dynports_read and dynports_line the way
# sup_loop drives them, and judged two ways.
#
# THE "MUST NOT" PROPERTIES, on every case:
# 2 always terminates       (the suite's own timeout catches a hang)
# 3 exactly three outcomes  (0, 1 or 2 -- never a bash error status)
# 4 clean stderr            (no "integer expected", no "value too great for base", no "unbound")
# 5 accepted ports are sound
# 6 bounded                 (nothing here should be slow; the tier budget catches it)
#
# Property 4 has teeth: the overflow case leaked `[: ...: integer expected` to stderr during
# design and fell through, which is exactly the shape "never fail silently" forbids.
#
# AND THE "MUST", which is #505's: the gate's outcome equals what an awk grammar of the watcher's
# output says, case by case. An outcome is the frames applied, `[...]`, the warnings surfaced,
# `{...}`, and how it ended: `F@k` for a fatal on line k, `E` for the stream ending. The line number
# is load-bearing -- without it a gate that let one line through and died on the next would read
# the same as one that died on time, which is what a 64-character line did before #505.
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

# THE CASES, each with a tag naming its generator and, when the generator built it to be legal,
# the outcome the generator expects. Nothing is driven until all of them exist.
FZ_T=(); FZ_TAG=(); FZ_NAME=(); FZ_WANT=()
fz_add() {                            # fz_add TAG NAME TEXT [WANT]
    local i=${#FZ_T[@]} ids="FZ_IDS_$1"
    FZ_TAG[i]="$1"; FZ_NAME[i]="$2"; FZ_T[i]="$3"; FZ_WANT[i]="${4-}"
    # And in FZ_IDS_<TAG>, so a check over one generator visits its cases and not all of them.
    printf -v "$ids" '%s %d' "${!ids-}" "$i"
}
fz_lines() {                          # fz_lines TAG NAME LINE... -> a case: each LINE and a newline
    local tag="$1" name="$2" t='' l; shift 2
    for l in "$@"; do t="$t$l"$'\n'; done
    fz_add "$tag" "$name" "$t"
}
# ASCENDING, as the watcher sends records, so a case is refused for what it was built to test and not
# for an order the watcher never produces. One copy, for every generator that builds records; it
# draws nothing, so no stream moves for it.
fz_insert() {                         # fz_insert REC -> FZ_RS, REC put in place by port (after any equal)
    local k=${#FZ_RS[@]}
    while [ "$k" -gt 0 ] && [ "${FZ_RS[k-1]%%:*}" -gt "${1%%:*}" ]; do
        FZ_RS[k]="${FZ_RS[k-1]}"; k=$(( k - 1 ))
    done
    FZ_RS[k]="$1"
}

# (a) random bytes. The odd ones again behind a real handshake, so they reach the states after it;
# no extra draw, so the stream is the one this generator always made.
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
    fz_lines random "random#$i" ${lines[@]+"${lines[@]}"}
    [ "$(( i % 2 ))" -eq 1 ] && fz_lines random "random#$i+handshake" "$H" ${lines[@]+"${lines[@]}"}
    i=$(( i + 1 ))
done

# (b) mutated valid transcripts -- byte flips, deletions, duplications, truncation
i=0
while [ "$i" -lt 400 ]; do
    lcg 4; np=$(( R + 1 )); j=0; FZ_RS=()
    while [ "$j" -lt "$np" ]; do
        lcg 64000; port=$(( R + 1024 ))
        lcg 5
        # shellcheck disable=SC2086   # deliberately word-split: it is a list of class names
        set -- $CLASSES; shift $R 2>/dev/null || set -- lo
        fz_insert "$port:${1:-lo}"; j=$(( j + 1 ))
    done
    lines=("$H" "BEGIN $np" ${FZ_RS[@]+"${FZ_RS[@]}"} "END")
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
    fz_lines mutant "mutant#$i" ${lines[@]+"${lines[@]}"}
    i=$(( i + 1 ))
done

# THE GENERATORS BELOW DRAW FROM A STREAM OF THEIR OWN, so adding one never changes what (a) and (b)
# make. High bits, because a power-of-two LCG's low bits repeat with short periods.
# RESEEDED PER GENERATOR, too, so a change to one -- a draw added, a branch removed -- moves only its
# own cases and counts. Shared, the stream once let a generator that stopped making warnings keep
# the total the same: the generators after it drew differently and made up the difference.
lcgh_seed() { LCGH=$(( (SEED ^ 0x5EED) + $1 )); }
lcgh() {                              # lcgh N -> $R in [0,N)
    LCGH=$(( (LCGH * 1103515245 + 12345) & 0x7FFFFFFF ))
    R=$(( (LCGH >> 8) % $1 ))
}
lcgh_seed 0
fz_digits() {                         # fz_digits LO -> FZ_P in [LO,65535], its digit count uniform
    local lo="$1" d a b
    lcgh $(( 6 - ${#lo} )); d=$(( ${#lo} + R ))
    a=1; while [ "${#a}" -lt "$d" ]; do a=$(( a * 10 )); done
    b=$(( a * 10 - 1 )); [ "$b" -le 65535 ] || b=65535
    [ "$a" -ge "$lo" ] || a=$lo
    lcgh $(( b - a + 1 )); FZ_P=$(( a + R ))
}
fz_class() {                          # fz_class -> FZ_C, a class
    lcgh 5
    # shellcheck disable=SC2086   # deliberately word-split: it is a list of class names
    set -- $CLASSES; shift "$R"; FZ_C="$1"
}
fz_small() {                          # fz_small N -> FZ_RS, up to N records, ascending (a port drawn twice is kept once)
    local n=0 p
    FZ_RS=()
    while [ "$n" -lt "$1" ]; do
        n=$(( n + 1 ))
        fz_digits 1; p=$FZ_P
        case " ${FZ_RS[*]+"${FZ_RS[*]}"} " in *" $p:"*) continue ;; esac
        fz_class
        fz_insert "$p:$FZ_C"
    done
}
# THE WIDEST STEP IS THE CAP'S, not a literal: FZ_MAX steps of up to it, from a start below what they
# leave, end at 65534 at most. 511 at a cap of 128 -- the literal this replaced, which at a cap of 256
# ran most of its widest-step frames past 65535, so a raised cap failed fuzz:valid for the generator's
# fault.
FZ_STEP=$(( 65534 / FZ_MAX ))
fz_full() {                           # fz_full -> FZ_RS, FZ_MAX records ascending, steps of 1..G
    local g p n=0
    lcgh 4; case "$R" in 0) g=1 ;; 1) g=8 ;; 2) g=64 ;; *) g=$FZ_STEP ;; esac
    [ "$g" -le "$FZ_STEP" ] || g=$FZ_STEP
    lcgh $(( 65535 - FZ_MAX * g )); p=$R
    FZ_RS=()
    while [ "$n" -lt "$FZ_MAX" ]; do
        lcgh "$g"; p=$(( p + 1 + R )); fz_class
        FZ_RS[n]="$p:$FZ_C"; n=$(( n + 1 ))
    done
}

# A TRANSCRIPT BUILT TO BE LEGAL, and beside it the outcome each line produces once it is read: a
# frame at its END, a warning at its WARN. So a case cut at any byte still knows its own outcome --
# every event whose line ended inside the cut, then E -- with no grammar involved.
fz_start() { FZ_B=''; FZ_EVS=(); FZ_EOS=(); fz_put "$H"; }
fz_put() {                            # fz_put LINE [EVENT]
    FZ_B="$FZ_B$1"$'\n'
    if [ -n "${2-}" ]; then FZ_EVS[${#FZ_EVS[@]}]="$2"; FZ_EOS[${#FZ_EOS[@]}]=${#FZ_B}; fi
}
fz_frame() {                          # fz_frame REC... -- BEGIN, the records, END
    local IFS=' ' recs=''
    fz_put "BEGIN $#"
    # One printf for the records rather than a fz_put each: full frames are most of what (c) and (d)
    # build, and records carry no event.
    [ "$#" -eq 0 ] || { printf -v recs '%s\n' "$@"; FZ_B="$FZ_B$recs"; }
    fz_put END "[$*]"
}
fz_warn() { fz_put "WARN too-many-listeners $1" "{too-many-listeners $1}"; }   # fz_warn N
fz_legal() {                          # fz_legal TAG NAME [CUT] -- the transcript so far, first CUT bytes
    local cut="${3:-${#FZ_B}}" i=0 w=''
    while [ "$i" -lt "${#FZ_EVS[@]}" ] && [ "${FZ_EOS[i]}" -le "$cut" ]; do
        w="$w${FZ_EVS[i]}"; i=$(( i + 1 ))
    done
    fz_add "$1" "$2" "${FZ_B:0:cut}" "${w}E"
}

# (c) THE EXTREMES, fixed: the largest legal shapes, built from FZ_MAX so they follow the cap.
FZ_LOALT=(); p=$(( 65536 - FZ_MAX ))
while [ "$p" -le 65535 ]; do FZ_LOALT[${#FZ_LOALT[@]}]="$p:loalt"; p=$(( p + 1 )); done
fz_start; fz_frame ${FZ_LOALT[@]+"${FZ_LOALT[@]}"}
fz_legal extreme "a-full-frame-of-five-digit-loalt"        # #505 itself
fz_start
for c in $CLASSES; do fz_frame "65535:$c"; done
fz_legal extreme "the-longest-record-of-every-class"
fz_start; fz_frame; fz_frame "65535:lo"; fz_frame "1:lo"
fz_legal extreme "a-frame-may-start-below-where-the-last-ended"
fz_start; fz_warn $(( FZ_MAX + 1 ))
fz_frame ${FZ_LOALT[@]+"${FZ_LOALT[@]}"}
fz_legal extreme "the-fewest-listeners-that-warn"
fz_start; fz_warn 65535
fz_frame ${FZ_LOALT[@]+"${FZ_LOALT[@]}"}
fz_legal extreme "the-most-listeners-that-warn"
# Ports of every digit count in one full frame: k + 1 keeps them strictly ascending, and the k^4
# term carries the last one to 65535 exactly.
rs=(); k=0
# shellcheck disable=SC2086   # deliberately word-split: it is a list of class names
set -- $CLASSES
while [ "$k" -lt "$FZ_MAX" ]; do
    p=$(( k + 1 + k * k * k * k * (65535 - FZ_MAX) / ((FZ_MAX - 1) * (FZ_MAX - 1) * (FZ_MAX - 1) * (FZ_MAX - 1)) ))
    c=$(( k % $# + 1 ))
    rs[k]="$p:${!c}"; k=$(( k + 1 ))
done
fz_start; fz_frame ${rs[@]+"${rs[@]}"}
fz_legal extreme "a-full-frame-of-every-digit-count-and-class"
# The stream ending early is the watcher dying, which it can do anywhere: nothing partial applies.
fz_start; fz_frame; fz_put "BEGIN 2"; fz_put "3000:lo"
fz_legal extreme "a-partial-frame-at-the-end"
fz_start; fz_frame "3000:lo"
fz_legal extreme "an-unterminated-END" $(( ${#FZ_B} - 1 ))

# (d) LEGAL TRANSCRIPTS, random: one to three frames, a full one now and then -- half of those
# behind a WARN -- ports of every digit count, and one case in four cut at a random byte.
lcgh_seed 1
i=0
while [ "$i" -lt 200 ]; do
    fz_start
    lcgh 3; nf=$(( R + 1 )); f=0
    while [ "$f" -lt "$nf" ]; do
        lcgh 20
        if [ "$R" -eq 0 ]; then
            lcgh 2
            if [ "$R" -eq 0 ]; then
                fz_digits $(( FZ_MAX + 1 ))
                fz_warn "$FZ_P"
            fi
            fz_full
        else
            lcgh 7; fz_small "$R"
        fi
        fz_frame ${FZ_RS[@]+"${FZ_RS[@]}"}
        f=$(( f + 1 ))
    done
    lcgh 4
    if [ "$R" -eq 0 ]; then lcgh $(( ${#FZ_B} + 1 )); fz_legal valid "valid#$i" "$R"
    else fz_legal valid "valid#$i"; fi
    i=$(( i + 1 ))
done

# (e) THE REAL WATCHER'S CAPPED FRAME. Nothing had ever put more than PW_MAX listeners in front of
# pw_watch, so its WARN path had never met the gate -- and under a gate that takes exactly what the
# watcher writes, that path is a shape forwarding depends on. Its scan is fed a /proc table of
# PW_MAX + 72 listeners (200, at a cap of 128) on distinct five-digit ports in draw order, every class
# among them; pw_emit stops it after the first frame. Sourced in a subshell, so its globals stay there. The frame it should send
# is worked out here, by sort(1), and not by asking the watcher.
FZ_HDR='  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode'
FZ_V4="$FZ_HDR"; FZ_V6="$FZ_HDR"; FZ_SEEN=' '; FZ_RECS=''; n=0; FZ_LISTENERS=$(( FZ_MAX + 72 ))
lcgh_seed 2
while [ "$n" -lt "$FZ_LISTENERS" ]; do
    lcgh 55536; p=$(( 10000 + R ))
    case "$FZ_SEEN" in *" $p "*) continue ;; esac
    FZ_SEEN="$FZ_SEEN$p "
    case "$(( n % 5 ))" in
        0) a=0100007F; c=lo ;;
        1) a=00000000; c=any ;;
        2) a=0200007F; c=loalt ;;
        3) a=0101A8C0; c=eth ;;
        *) a=00000000000000000000000001000000; c=v6lo ;;
    esac
    printf -v row '%4s: %s:%04X %s 0A 00000000:00000000 00:00000000 00000000  1000        0 0 1 0000 0 0 0 0 0' \
        "$n" "$a" "$p" "${a//?/0}:0000"
    if [ "$c" = v6lo ]; then FZ_V6="$FZ_V6"$'\n'"$row"; else FZ_V4="$FZ_V4"$'\n'"$row"; fi
    FZ_RECS="$FZ_RECS$p:$c"$'\n'
    n=$(( n + 1 ))
done
FZ_EXPECT="$(printf '%s' "$FZ_RECS" | LC_ALL=C sort -t: -k1,1n | head -n "$FZ_MAX" | do_tr '\n' ' ')"
rm -rf "$WORK/pw"
(
    # shellcheck disable=SC2034   # read by the source guard at the bottom of cs193v-portwatch
    CS193V_PORTWATCH_SOURCED=1
    # shellcheck source=.private/files/cs193v-portwatch
    . "$PRIVATE/files/cs193v-portwatch"
    PW_STATE_DIR="$WORK/pw"
    # shellcheck disable=SC2034   # read by the sourced cs193v-portwatch
    PW_STATE="$PW_STATE_DIR/ports"
    pw_scan_now() { pw_scan_text "$FZ_V4" "$FZ_V6"; }
    pw_emit() { printf '%s\n' "$1"; [ "$1" != END ] || exit 0; }
    pw_watch 1
) > "$WORK/watch" 2>/dev/null
fz_add watcher "the-real-watchers-capped-frame" "$(<"$WORK/watch")"$'\n' \
       "{too-many-listeners $FZ_LISTENERS}[${FZ_EXPECT% }]E"

# (f) TARGETED MUTANTS: a short legal transcript, broken once in a way aimed at a rule the gate must
# hold. Some of them stay legal -- a WARN at the very end is a watcher that died after it -- and the
# grammar is what says which.
FZ_W1="WARN too-many-listeners $(( FZ_MAX + 1 ))"
FZ_NEXT=( "BEGIN $(( FZ_MAX + 1 ))" "BEGIN $(( FZ_MAX - 1 ))" "BEGIN 0" "BEGIN 0$FZ_MAX" "BEGIN 1"
          "BEGIN $FZ_MAX" "END" "3000:lo" "$FZ_W1" )
FZ_BADN=( "$FZ_MAX" "$(( FZ_MAX - 1 ))" 0 1 "0$(( FZ_MAX + 72 ))" "+$(( FZ_MAX + 72 ))"
          "$(( FZ_MAX + 72 )) " " $(( FZ_MAX + 72 ))" 65536 99999 100000 2e3 ""
          "$(( FZ_MAX + 1 ))" 65535 )
FZ_BADW=( "WARN too-many-listener 200" "WARN Too-many-listeners 200" "WARN  too-many-listeners 200"
          "WARN too-many-listeners" "WARN too-many-listeners " "WARN slow-scan 3"
          "WARN too-many-listeners 200 300" "WARN too-many-listeners"$'\t'"200" "WARN" "WARN "
          "warn too-many-listeners 200" "WARN too-many-listeners 200"$'\r' )
FZ_NEAR=( LO "lo " " lo" $'lo\r' loalt2 loal "" Lo ANY v6 v6lo6 eth0 "lo:lo" )
FZ_INS=( "ERR deliberate" END "$H" "" "BEGIN 0" "$FZ_W1" "3000:lo" )
# EVERY LISTED NEAR MISS ONCE, first, and in a fixed place: drawn at random, a list of fifteen
# counts left N = PW_MAX undrawn often enough that a gate taking it stayed green here.
for v in ${FZ_NEXT[@]+"${FZ_NEXT[@]}"}; do
    fz_lines targeted "after-warn:$v" "$H" "$FZ_W1" "$v" "3000:lo" "5173:any"
done
for v in ${FZ_BADN[@]+"${FZ_BADN[@]}"}; do
    fz_lines targeted "warn-count:$v" "$H" "WARN too-many-listeners $v" "BEGIN $FZ_MAX" "3000:lo"
done
for v in ${FZ_BADW[@]+"${FZ_BADW[@]}"}; do
    fz_lines targeted "warn-words:$v" "$H" "$v" "BEGIN $FZ_MAX" "3000:lo"
done
for v in ${FZ_NEAR[@]+"${FZ_NEAR[@]}"}; do
    fz_lines targeted "class:$v" "$H" "BEGIN 2" "3000:lo" "5173:$v" "END"
done
lines=( "$H" "BEGIN 2" "3000:lo" "5173:any" "END" )
for v in ${FZ_INS[@]+"${FZ_INS[@]}"}; do
    j=1
    while [ "$j" -le "${#lines[@]}" ]; do
        fz_lines targeted "insert@$j:$v" "${lines[@]:0:j}" "$v" ${lines[@]+"${lines[@]:j}"}
        j=$(( j + 1 ))
    done
done
lcgh_seed 3
i=0
while [ "$i" -lt 300 ]; do
    lcgh 4; fz_small $(( R + 2 )); nr=${#FZ_RS[@]}
    lines=( "$H" "BEGIN $nr" ${FZ_RS[@]+"${FZ_RS[@]}"} END )
    lcgh 13; kind=$R
    [ "$nr" -lt 2 ] && { [ "$kind" -eq 0 ] || [ "$kind" -eq 2 ]; } && kind=8
    case "$kind" in
        0)  # two adjacent records swapped
            lcgh $(( nr - 1 )); j=$(( R + 2 ))
            v="${lines[j]}"; lines[j]="${lines[j+1]}"; lines[j+1]="$v" ;;
        1)  # a record repeated, and the count raised to match
            lcgh "$nr"; j=$(( R + 2 ))
            lines=( "${lines[@]:0:j+1}" "${lines[j]}" "${lines[@]:j+1}" ); lines[1]="BEGIN $(( nr + 1 ))" ;;
        2)  # a record after the first, its port no higher than the one before
            lcgh $(( nr - 1 )); j=$(( R + 3 )); p="${lines[j-1]%%:*}"; lcgh 3
            lines[j]="$(( p - R )):${lines[j]#*:}" ;;
        3)  # a legal WARN, anywhere after the handshake
            lcgh "${#lines[@]}"; j=$(( R + 1 ))
            lines=( "${lines[@]:0:j}" "$FZ_W1" "${lines[@]:j}" ) ;;
        4)  # a legal WARN, and something other than its BEGIN after it
            lcgh "${#FZ_NEXT[@]}"
            lines=( "$H" "$FZ_W1" "${FZ_NEXT[R]}" ${FZ_RS[@]+"${FZ_RS[@]}"} ) ;;
        5)  # a WARN whose count is wrong
            lcgh "${#FZ_BADN[@]}"
            lines=( "$H" "WARN too-many-listeners ${FZ_BADN[R]}" "BEGIN $FZ_MAX" ${FZ_RS[@]+"${FZ_RS[@]}"} ) ;;
        6)  # a WARN whose words are wrong
            lcgh "${#FZ_BADW[@]}"
            lines=( "$H" "${FZ_BADW[R]}" "BEGIN $FZ_MAX" ${FZ_RS[@]+"${FZ_RS[@]}"} ) ;;
        7)  # a record whose class is nearly one
            lcgh "$nr"; j=$(( R + 2 )); lcgh "${#FZ_NEAR[@]}"
            lines[j]="${lines[j]%%:*}:${FZ_NEAR[R]}" ;;
        8)  # the count one off, either way
            lcgh 2; lines[1]="BEGIN $(( nr + 1 - 2 * R ))" ;;
        9)  # a line inserted
            lcgh "${#lines[@]}"; j=$(( R + 1 )); lcgh "${#FZ_INS[@]}"
            lines=( "${lines[@]:0:j}" "${FZ_INS[R]}" "${lines[@]:j}" ) ;;
        10) # a line deleted
            lcgh "${#lines[@]}"; j=$R
            lines=( ${lines[@]+"${lines[@]:0:j}"} ${lines[@]+"${lines[@]:j+1}"} ) ;;
        11) # a record's port spelled some other way
            lcgh "$nr"; j=$(( R + 2 )); p="${lines[j]%%:*}"; lcgh 4
            case "$R" in 0) v="0$p" ;; 1) v="+$p" ;; 2) v="$p.0" ;; *) v=$(( p + 65536 )) ;; esac
            lines[j]="$v:${lines[j]#*:}" ;;
        *)  ;;  # 12: the final newline dropped, below
    esac
    fz_lines targeted "targeted#$i/$kind" ${lines[@]+"${lines[@]}"}
    if [ "$kind" -eq 12 ]; then j=$(( ${#FZ_T[@]} - 1 )); FZ_T[j]="${FZ_T[j]%$'\n'}"; fi
    i=$(( i + 1 ))
done

# (g) LINE LENGTHS AROUND THE READ'S LIMIT. dynports_read takes at most 64 bytes at a time, so a
# line of 64 or more comes back as its first 64 with the rest still in the pipe -- once read as a
# line of its own (#505). Each shape from two under the limit to twice it: a WARN between frames and
# inside one, a zero-padded record, a padded handshake. Then the shapes whose tail is a line the
# watcher does write, and unterminated tails either side of the limit, in ASCII and in multibyte
# text: the gate counts bytes whatever the locale, as the grammar does. All sized from FZ_LINE_MAX,
# so the limit cannot move without them.
for d in -2 -1 0 1 6 63 64; do
    len=$(( FZ_LINE_MAX + d ))
    fz_fill x $(( len - 5 ))
    fz_lines length "warn-$len-between-frames" "$H" "WARN $FZ_F" "BEGIN 0" "END"
    fz_lines length "warn-$len-inside-a-frame" "$H" "BEGIN 1" "WARN $FZ_F" "3000:lo" "END"
    fz_fill 0 $(( len - 7 ))
    fz_lines length "padded-record-$len" "$H" "BEGIN 1" "${FZ_F}3000:lo" "END"
    fz_fill ' ' $(( len - ${#H} ))
    fz_lines length "padded-handshake-$len" "$H$FZ_F" "BEGIN 0" "END"
done
fz_fill x $(( FZ_LINE_MAX - 5 ))
fz_lines length "split:a-record"           "$H" "BEGIN 1" "WARN ${FZ_F}3000:lo" "END"
fz_lines length "split:a-short-record"     "$H" "BEGIN 1" "WARN ${FZ_F}1:lo" "END"
fz_lines length "split:a-five-digit-loalt" "$H" "BEGIN 1" "WARN ${FZ_F}65535:loalt" "END"
fz_lines length "split:END"                "$H" "BEGIN 0" "WARN ${FZ_F}END"
fz_lines length "split:BEGIN"              "$H" "WARN ${FZ_F}BEGIN 0" "END"
for d in -2 -1 0 1; do
    len=$(( FZ_LINE_MAX + d ))
    fz_fill x "$len"
    fz_add length "unterminated-tail-$len" "$H"$'\n'"BEGIN 0"$'\n'"END"$'\n'"$FZ_F"
done
for d in -1 0 1; do
    n=$(( FZ_LINE_MAX / 2 + d ))
    fz_fill $'\303\251' "$n"
    fz_add length "multibyte:unterminated-$(( 2 * n ))-bytes" "$H"$'\n'"BEGIN 0"$'\n'"END"$'\n'"$FZ_F"
done
n=$(( (FZ_LINE_MAX + 6) / 2 )); fz_fill $'\303\251' "$n"
fz_lines length "multibyte:$(( 2 * n ))-bytes-$n-characters" "$H" "$FZ_F" "BEGIN 0" "END"
n=$(( FZ_LINE_MAX / 2 - 1 )); fz_fill $'\303\251' "$n"
fz_lines length "multibyte:$(( 2 * n + 2 ))-bytes-$(( n + 2 ))-characters" "$H" "BEGIN 1" "${FZ_F}xx" "3000:lo" "END"

# ─── drive every generated case, and judge what it did ─────────────────────────
# From inside a directory of its own, so anything a case managed to run would land there and not in
# the checkout.
FZ_GATE=()
mkdir -p "$WORK/run"
cd "$WORK/run" || exit 1
i=0
while [ "$i" -lt "${#FZ_T[@]}" ]; do
    printf '%s' "${FZ_T[i]}" > "$WORK/case"
    { fz_drive; } < "$WORK/case" 2>"$ERRF"
    # Read only when there is something to read: `$(<f)` is still a subshell, and a fork per case
    # was most of this loop's cost.
    if [ -s "$ERRF" ]; then RUN_ERR="$(<"$ERRF")"; else RUN_ERR=''; fi
    FZ_GATE[i]="$FZ_OUT"
    check_run "${FZ_NAME[i]}"
    i=$(( i + 1 ))
done
cd "$REPO" || exit 1

assert_eq "fuzz:only-three-outcomes-ever" "" "$BAD_RC"
assert_eq "fuzz:stderr-stays-clean"       "" "$BAD_ERR"
assert_eq "fuzz:accepted-ports-are-sound" "" "$BAD_PORT"
record "fuzz:cases-run" "$N (seed $SEED)"

# ─── the grammar: what the watcher writes, from the format, not from the gate ──
# One awk process for every case, each handed over after a \036 that no case contains, as
# 18-portwatch-fuzz.sh's state-file grammar does. LC_ALL=C so it measures bytes. The watcher writes
# its handshake; then, per frame, `BEGIN n` with n canonical and at most MAX, n records of a canonical
# port 1-65535 and a class, strictly ascending, and END; before a frame, when there are more than MAX
# listeners, `WARN too-many-listeners N` with N canonical and over MAX, and only then, and the frame
# after it is then exactly MAX. ERR is the watcher stopping, so it is fatal like anything else the
# grammar does not take. A line of LINEMAX bytes or more is fatal where it starts, terminated or
# not, since the read hands back that many and judges them. A shorter unterminated tail is never
# read as a line, and a frame without its END is never applied.
FZ_GRAMMAR='
    BEGIN { RS = "\036"; n = split(CLASSES, W, " "); for (i = 1; i <= n; i++) class[W[i]] = 1 }
    function isport(p) { return p ~ /^[1-9][0-9]*$/ && length(p) <= 5 && p + 0 <= 65535 }
    function iscount(c) { return c ~ /^(0|[1-9][0-9]*)$/ && length(c) <= length(MAX) && c + 0 <= MAX + 0 }
    function judge(t,   out, n, L, i, line, st, want, seen, last, frame, c, p, k) {
        n = split(t, L, "\n"); st = "handshake"; out = ""
        for (i = 1; i < n; i++) {
            line = L[i]
            if (length(line) >= LINEMAX + 0) return out "F@" i
            if (st == "handshake") {
                if (line != PROTO) return out "F@" i
                st = "outside"
            } else if (st == "inside") {
                if (line == "END" && seen == want) { out = out "[" frame "]"; st = "outside"; continue }
                c = index(line, ":")
                if (c == 0 || seen >= want) return out "F@" i
                p = substr(line, 1, c - 1); k = substr(line, c + 1)
                if (!isport(p) || p + 0 <= last || !(k in class)) return out "F@" i
                frame = frame (seen ? " " : "") line; seen++; last = p + 0
            } else {
                k = substr(line, 7)
                if (substr(line, 1, 6) == "BEGIN " && iscount(k) && (st == "outside" || k + 0 == MAX + 0)) {
                    want = k + 0; seen = 0; last = 0; frame = ""; st = "inside"; continue
                }
                k = substr(line, 25)
                if (st == "outside" && substr(line, 1, 24) == "WARN too-many-listeners " && isport(k) && k + 0 > MAX + 0) {
                    out = out "{too-many-listeners " k "}"; st = "warned"; continue
                }
                return out "F@" i
            }
        }
        if (n > 0 && length(L[n]) >= LINEMAX + 0) return out "F@" n
        return out "E"
    }
    { print judge($0) }
'
printf '%s\036' ${FZ_T[@]+"${FZ_T[@]}"} \
    | LC_ALL=C do_awk -v MAX="$FZ_MAX" -v LINEMAX="$FZ_LINE_MAX" -v PROTO="$H" -v CLASSES="$CLASSES" \
                      "$FZ_GRAMMAR" > "$WORK/oracle"
FZ_ORACLE=()
while IFS= read -r l; do FZ_ORACLE[${#FZ_ORACLE[@]}]="$l"; done < "$WORK/oracle"
assert_eq "fuzz:every-generated-case-was-driven-and-judged" \
          "${#FZ_T[@]} ${#FZ_T[@]}" "${#FZ_GATE[@]} ${#FZ_ORACLE[@]}"

# Where two of GATE, ORACLE and WANT differ over one generator's cases: how many, and the first
# five, each case shown with %q so every byte shows.
fz_agree() {                          # fz_agree NAME TAG A B
    local i n=0 nd=0 a b q diff='' ids="FZ_IDS_$2"
    for i in ${!ids-}; do
        n=$(( n + 1 ))
        a="FZ_$3[$i]"; a="${!a-<none>}"
        b="FZ_$4[$i]"; b="${!b-<none>}"
        if [ "$a" != "$b" ]; then
            nd=$(( nd + 1 ))
            if [ "$nd" -le 5 ]; then
                printf -v q '%q' "${FZ_T[i]:0:300}"
                diff="$diff
  ${FZ_NAME[i]}: $3 ${a:0:300} against $4 ${b:0:300}
    case: $q"
            fi
        fi
    done
    if [ "$n" -gt 0 ] && [ "$nd" -eq 0 ]; then
        pass "$1"
    else
        fail "$1" "$nd of $n $2 cases disagree, $3 against $4; the first:$diff"
    fi
}

# THE LEGAL CASES FIRST, against what their generator built: a gate, or a grammar, that refuses the
# watcher's own output would make every comparison after them meaningless, and agreeing with each
# other about that would still pass.
for i in ${FZ_IDS_extreme-}; do
    assert_eq "fuzz:extreme:${FZ_NAME[i]}" "${FZ_WANT[i]}" "${FZ_GATE[i]}"
done
for i in ${FZ_IDS_watcher-}; do
    assert_eq "fuzz:watcher:the-real-watchers-capped-frame-is-applied" "${FZ_WANT[i]}" "${FZ_GATE[i]}"
done
fz_agree "fuzz:valid:the-gate-applies-what-the-watcher-wrote" valid GATE WANT
fz_agree "fuzz:valid:the-grammar-agrees-with-the-generator"   valid ORACLE WANT

# THE IFF: on every generator's cases, the gate does exactly what the grammar does.
fz_agree "fuzz:iff:random-bytes"           random   GATE ORACLE
fz_agree "fuzz:iff:mutated-transcripts"    mutant   GATE ORACLE
fz_agree "fuzz:iff:extremes"               extreme  GATE ORACLE
fz_agree "fuzz:iff:legal-transcripts"      valid    GATE ORACLE
fz_agree "fuzz:iff:the-real-watcher"       watcher  GATE ORACLE
fz_agree "fuzz:iff:targeted-mutants"       targeted GATE ORACLE
fz_agree "fuzz:iff:line-length-boundaries" length   GATE ORACLE

# LITERAL COUNTS, so a generator that quietly stops making cases, or a grammar that stops taking
# any, cannot leave the comparisons above agreeing about nothing.
FZ_WHOLE=0; FZ_REFUSED=0
i=0
while [ "$i" -lt "${#FZ_ORACLE[@]}" ]; do
    case "${FZ_ORACLE[i]}" in
        *F@*) [ "${FZ_TAG[i]-}" = targeted ] && FZ_REFUSED=$(( FZ_REFUSED + 1 )) ;;
        *)    FZ_WHOLE=$(( FZ_WHOLE + 1 )) ;;
    esac
    i=$(( i + 1 ))
done
# Counted by awk, not by `${o//[!]]/}`: on bash 3.2 that pattern took half a minute over these
# outcomes, a full frame's being a kilobyte and a half.
read -r FZ_FRAMES FZ_WARNS < <(do_awk '{ f += gsub(/]/, ""); w += gsub(/}/, "") } END { print f + 0, w + 0 }' "$WORK/oracle")
assert_eq "fuzz:cases-generated"                    "1635" "${#FZ_T[@]}"
assert_eq "fuzz:cases-the-grammar-takes-whole"      "272" "$FZ_WHOLE"
assert_eq "fuzz:frames-the-grammar-applies"         "395" "$FZ_FRAMES"
assert_eq "fuzz:warnings-the-grammar-surfaces"      "54" "$FZ_WARNS"
assert_eq "fuzz:targeted-mutants-the-grammar-refuses" "348" "$FZ_REFUSED"

# ─── a line the read cannot take whole says so ─────────────────────────────────
# The iff cannot see this rule: under a gate that takes only what the watcher writes, the first 64
# characters of a long line are refused anyway, and on the same line. What the rule buys is the
# reason, and that the tail is never read -- so it is asserted on the reason. A line one under the
# limit is read whole and judged on what it says; one at it and one past it are not read whole, and
# say that. So does one at the limit in bytes and well under it in characters: the gate counts bytes
# in any locale, where under a multibyte one it once took that line for an unknown warning.
fz_says() {                           # fz_says TEXT -> FZ_SAYS: the outcome, and the reason up to its colon
    printf '%s' "$1" > "$WORK/case"
    { fz_drive; } < "$WORK/case" 2>/dev/null
    FZ_SAYS="$FZ_OUT ${DYNPORTS_FATAL%%:*}"
}
fz_fill x $(( FZ_LINE_MAX - 6 )); fz_says "$H"$'\n'"WARN $FZ_F"$'\n'; under="$FZ_SAYS"
fz_fill x $(( FZ_LINE_MAX - 5 )); fz_says "$H"$'\n'"WARN $FZ_F"$'\n'; at="$FZ_SAYS"
fz_fill x $(( FZ_LINE_MAX + 1 )); fz_says "$H"$'\n'"WARN $FZ_F"$'\n'; over="$FZ_SAYS"
fz_fill $'\303\251' $(( (FZ_LINE_MAX - 6) / 2 )); fz_says "$H"$'\n'"WARN x$FZ_F"$'\n'; bytes="$FZ_SAYS"
assert_eq "fuzz:a-line-the-read-cannot-take-whole-says-so" \
          "F@2 unknown warning|F@2 line too long|F@2 line too long|F@2 line too long" \
          "$under|$at|$over|$bytes"

# ─── the count cap follows DYNPORTS_MAX ────────────────────────────────────────
# It used to be a literal three digits, beside a nine-character BEGIN line cap: right for `BEGIN 128`
# and for nothing larger. Raise the cap and both would refuse the frames it allows -- #505's shape,
# one constant over. So the cap is raised here, in a subshell, and the largest frame it allows must
# still be taken.
FZ_CAP="$(
    # shellcheck disable=SC2034   # read by dynports_line, sourced from cs193v-ui.sh
    DYNPORTS_MAX=1000
    dynports_reset
    dynports_line "$H"; a=$?
    dynports_line "WARN too-many-listeners 1001"; b=$?
    dynports_line "BEGIN 1000"; c=$?
    printf '%s %s %s%s' "$a" "$b" "$c" "${DYNPORTS_FATAL:+ ($DYNPORTS_FATAL)}"
)"
assert_eq "fuzz:the-count-cap-follows-DYNPORTS_MAX" "0 0 0" "$FZ_CAP"

# ─── every hostile case actually RAN ───────────────────────────────────────────
# NOT BOOKKEEPING. A bash arithmetic error -- $(( 08 )) with no 10# prefix, say -- does not
# return a status: it unwinds the ENTIRE function call stack to top level, so hostile_fatal's
# check never executes and the assertion silently disappears. Measured. The suite then reports
# "0 fail" while two cases did not run, which is precisely the failure this project forbids.
#
# A LITERAL, deliberately, in the same spirit as ports:count-is-47 in 10-static.sh: add a case
# and you are made to come and look at this line.
assert_eq "fuzz:every-hostile-case-ran" "49" "$HOSTILE_RAN"

# ─── a malformed frame must not corrupt the next parse ─────────────────────────
# Halting, not resyncing: after a fatal the supervisor stops. What must hold is that a FRESH
# parse is unaffected by the last one -- otherwise one bad frame poisons the session.
run_case "$H" "BEGIN 1" "0x1f:lo" "END"
run_case "$H" "BEGIN 1" "3000:lo" "END"
assert_eq "fuzz:a-fresh-parse-is-not-poisoned" " 3000:lo" "$RUN_PORTS"
# AND A RESET LEAVES NO PARSE STATE BEHIND, the last port the order check compared against included.
# Nothing reads that port before a BEGIN sets it today, which is exactly why a reset that forgot it
# would go unnoticed until something did.
run_case "$H" "BEGIN 2" "3000:lo" "5000:lo"
dynports_reset
assert_eq "fuzz:a-reset-leaves-no-parse-state" "handshake 0 0 0 []" \
          "$DYNPORTS_STATE $DYNPORTS_N $DYNPORTS_SEEN $DYNPORTS_LAST [$DYNPORTS_FRAME]"
