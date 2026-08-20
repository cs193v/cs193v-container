#!/usr/bin/env bash
#
# CS193V container test runner.
#
#   tests/run-tests.sh                    everything except the release gates
#   tests/run-tests.sh --tier static      one tier (comma-separated for several)
#   tests/run-tests.sh -k tmux            only suites whose filename matches
#   tests/run-tests.sh --release          the "not shippable yet" gates
#   tests/run-tests.sh --serial           one suite at a time, in file order
#   tests/run-tests.sh --list             what exists, in which tier, and in which lane
#
# MUST STAY BASH 3.2 COMPATIBLE — see tests/lib/assert.sh for why.
#
# Tiers, cheapest first. Each suite declares its own with a `# TIER:` line, so adding a
# suite needs no edit here.
#
#   static     no podman, no image, no network. Milliseconds.
#   unit       language-level unit tests (the Containerfile parser).
#   shim       the launcher's state machine against a fake podman on PATH. No containers.
#   install    install-cs193v.sh against machines that really lack podman, ssh or a subuid
#              range, in throwaway containers. Seconds, and cached after the first build.
#   image      assertions about the built image, via throwaway containers.
#   container  assertions about a live cs193v container: flags, kernel, ports, files.
#   live       the launcher driving real podman: idempotency, drift, cleanup.
#   release    release gates — NOT run by default. These fail until the repo is
#              shippable, which is a standing state of affairs, not a regression.
#   github     setup-git against the real GitHub API — NOT run by default, and skipped even
#              when asked for unless CS193V_GH_TEST_TOKEN is set. It needs a real credential
#              and it writes to a repository the whole class can see.
#
# image/container/live HARD-FAIL rather than skip when their prerequisite is missing, by
# project decision: a green run must mean the whole thing really ran.
#
# ─── the two lanes ─────────────────────────────────────────────────────────────
# The tiers split cleanly by what they contend for, and the two halves share nothing:
#
#   cheap    static, unit, shim        a fake podman on PATH. No container, no ports.
#   podman   install, image, container, live
#                                       one container, one tunnel, the forwarded ports.
#            install is in this lane because an unrecognised tier lands here, which is the
#            right default -- but it shares nothing with the others, so it is a candidate
#            for a third lane once its cost is worth splitting.
#
# So they run at the same time. IMAGE, CONTAINER AND LIVE MUST STAY IN ONE LANE, and in file
# order: they share the container, and CS193V_INSTANCE does not namespace the forwarded
# host ports (see CLAUDE.md), so a second lane touching real podman would fight the first for
# them and produce failures that look exactly like real regressions. The cheap lane cannot:
# its launcher runs from a throwaway copy of the repo, and TUNNEL_ID is a hash of the
# launcher's own directory, so it could not reach the real tunnel's control socket if it tried.
#
# The podman lane runs in the FOREGROUND and streams live — it is the longer of the two and
# where the interesting failures are. The cheap lane runs in the background into its own log,
# printed in one block when it finishes, and dumped as far as it got if the run is interrupted.
# That last part is not a nicety: assert.sh prints per assertion, rather than summarising,
# specifically so that a hanging suite still shows you how far it got.

set -u

DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"

DEFAULT_TIERS="static unit shim install image container live"
TIERS=""
FILTER=""
PARALLEL=yes

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_BOLD=$(printf '\033[1m'); C_GRN=$(printf '\033[32m'); C_RED=$(printf '\033[1;31m')
    C_YEL=$(printf '\033[33m'); C_DIM=$(printf '\033[2m'); C_OFF=$(printf '\033[0m')
else
    C_BOLD=''; C_GRN=''; C_RED=''; C_YEL=''; C_DIM=''; C_OFF=''
fi

usage() {
    sed -n '3,30p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
    exit "${1:-0}"
}

LIST_ONLY=no
while [ "$#" -gt 0 ]; do
    case "$1" in
        --tier)    shift; TIERS="$(printf '%s' "${1:-}" | tr ',' ' ')" ;;
        --tier=*)  TIERS="$(printf '%s' "${1#--tier=}" | tr ',' ' ')" ;;
        --release) TIERS="release" ;;
        --all)     TIERS="$DEFAULT_TIERS release" ;;
        -k)        shift; FILTER="${1:-}" ;;
        -k*)       FILTER="${1#-k}" ;;
        --serial)  PARALLEL=no ;;
        --list)    LIST_ONLY=yes ;;
        -h|--help) usage 0 ;;
        *)         printf 'unknown option: %s\n\n' "$1" >&2; usage 2 ;;
    esac
    shift
done
[ -n "$TIERS" ] || TIERS="$DEFAULT_TIERS"

tier_of() {                           # tier_of FILE -> the declared tier, or 'static'
    local t
    t="$(sed -n 's/^#[[:space:]]*TIER:[[:space:]]*\([a-z]*\).*/\1/p' "$1" | head -1)"
    printf '%s' "${t:-static}"
}

wanted() {                            # wanted TIER -> 0 if it is in $TIERS
    local t
    for t in $TIERS; do [ "$t" = "$1" ] && return 0; done
    return 1
}

# Anything not named here is podman, on purpose: an unrecognised tier is serialised with the
# real container rather than run beside it, so a suite added later is slow by default and
# never wrong by default. (`release` lands there and that is correct — it greps podman for
# published images.)
lane_of() {                           # lane_of TIER -> cheap | podman
    case "$1" in
        static|unit|shim) printf 'cheap' ;;
        *)                printf 'podman' ;;
    esac
}

# ─── discover ──────────────────────────────────────────────────────────────────
SUITES=""
for f in "$DIR"/[0-9][0-9]-*.sh; do
    [ -f "$f" ] || continue
    SUITES="$SUITES $f"
done

if [ "$LIST_ONLY" = yes ]; then
    printf '%slane    tier       suite%s\n' "$C_BOLD" "$C_OFF"
    for f in $SUITES; do
        t="$(tier_of "$f")"
        printf '%-7s %-10s %s\n' "$(lane_of "$t")" "$t" "$(basename "$f")"
    done
    exit 0
fi

# ─── run ───────────────────────────────────────────────────────────────────────
WALL_T0=$SECONDS
RESULTS="$(mktemp "${TMPDIR:-/tmp}/cs193v-run.XXXXXX")"
export CS193V_RESULTS="$RESULTS"
TIMINGS="$(mktemp "${TMPDIR:-/tmp}/cs193v-time.XXXXXX")"
# Suites that exited without finishing, one per line. A FILE rather than a variable because the
# cheap lane runs inside a subshell, so a counter set there would never come back — the same
# thing that made repo_copy leak (#76).
CRASHES="$(mktemp "${TMPDIR:-/tmp}/cs193v-crash.XXXXXX")"
CHEAPLOG=""
CHEAP_PID=""
CHEAP_FLUSHED=no

# Print the background lane's output, wherever we got to. Called once on the normal path and
# again from the trap, so it has to be idempotent — and called from the trap AT ALL because an
# interrupted run must still show what that lane had managed, rather than throwing it away.
flush_cheap() {
    [ "$CHEAP_FLUSHED" = no ] || return 0
    [ -n "$CHEAPLOG" ] && [ -s "$CHEAPLOG" ] || return 0
    CHEAP_FLUSHED=yes
    printf '\n%s─── the no-podman lane, which ran alongside the above ───%s\n' "$C_DIM" "$C_OFF"
    cat "$CHEAPLOG"
}

# Kill a background lane and everything under it. `kill $CHEAP_PID` on its own reaches only
# the subshell: bash gives a background job no process group of its own without job control,
# so there is no group to signal, and the suite the subshell was running is simply orphaned.
# Measured — a Ctrl+C'd run left 30-launcher-shim.sh going after the runner had exited, which
# for the podman lane would mean a suite still driving the container nobody is watching.
# Children first, so nothing is reparented and missed. pgrep -P is on macOS too.
kill_tree() {                         # kill_tree PID
    local kid
    for kid in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$kid"; done
    kill "$1" 2>/dev/null
    return 0
}

cleanup() {
    [ -n "$CHEAP_PID" ] && kill_tree "$CHEAP_PID"
    flush_cheap
    rm -f "$RESULTS" "$TIMINGS" "$CRASHES"
    [ -n "$CHEAPLOG" ] && rm -f "$CHEAPLOG"
    return 0
}
trap 'cleanup' EXIT
# INT and TERM as well as EXIT: bash runs an EXIT trap on both, but only after the handler for
# them returns, and without an explicit exit the script would carry on running suites after a
# Ctrl+C. 130 is the conventional status for SIGINT.
trap 'cleanup; exit 130' INT TERM

# ─── the clock ─────────────────────────────────────────────────────────────────
# `date +%N` is GNU-only — on a TA's Mac it prints a literal "N", so anything built on it
# reports garbage on exactly the platform VERIFICATION.md §5.2/§5.3 cares about. bash's own
# `time` keyword with TIMEFORMAT is millisecond-resolution, costs no subprocess, and has been
# in bash since long before 3.2.
#
# fd 3 and 4 are the real stdout and stderr. run_suite writes the suite's own output there,
# so the command substitution that captures time's report captures ONLY that report — the
# assertions still stream to the terminal as they happen, which is the property assert.sh is
# built around ("a hanging suite still shows you how far it got").
TIMEFORMAT='%3R'
exec 3>&1 4>&2

# A SUITE THAT DIES IS RECORDED, not shrugged off. This used to end in `|| true` and the whole
# verdict rested on the FAIL count in $RESULTS, so a suite that exited half way through — a
# `set -u` slip, a kill, or _emit finding the results file unwritable — cost the run its results
# and nothing else: the summary counted what had survived and reported `0 fail` (#76).
run_suite() {                         # run_suite FILE  — output goes to the real terminal
    bash "$1" 1>&3 2>&4 || printf '%s\t%s\n' "$?" "$(basename "$1")" >> "$CRASHES"
    return 0
}

run_lane() {                          # run_lane FILE...  — sequential, in the order given
    local f base tier elapsed
    for f in "$@"; do
        base="$(basename "$f")"
        tier="$(tier_of "$f")"
        printf '\n%s%s%s %s[%s]%s\n' "$C_BOLD" "$base" "$C_OFF" "$C_DIM" "$tier" "$C_OFF"
        CS193V_SUITE="$base"; export CS193V_SUITE
        elapsed="$( { time run_suite "$f"; } 2>&1 )"
        printf '%s\t%s\n' "$elapsed" "$base" >> "$TIMINGS"
        printf '  %s%ss%s\n' "$C_DIM" "$elapsed" "$C_OFF"
    done
}

# ─── select, and sort into lanes ───────────────────────────────────────────────
CHEAP=""
PODMAN=""
RAN=0
for f in $SUITES; do
    base="$(basename "$f")"
    tier="$(tier_of "$f")"
    wanted "$tier" || continue
    if [ -n "$FILTER" ]; then
        case "$base" in *"$FILTER"*) : ;; *) continue ;; esac
    fi
    RAN=$((RAN + 1))
    if [ "$(lane_of "$tier")" = cheap ]; then CHEAP="$CHEAP $f"; else PODMAN="$PODMAN $f"; fi
done

if [ "$RAN" -eq 0 ]; then
    printf '\n%sno suites matched%s (tiers: %s, filter: %s)\n' "$C_YEL" "$C_OFF" "$TIERS" "${FILTER:-none}" >&2
    exit 2
fi

# Two lanes only when there is something in both. A `-k` or `--tier` run that lands entirely
# in one lane gets no lane machinery and no buffering — which is most single-suite runs, and
# the case where seeing the output live matters most.
LANES=one
[ "$PARALLEL" = yes ] && [ -n "$CHEAP" ] && [ -n "$PODMAN" ] && LANES=two

printf '%sCS193V container tests%s  %s(tiers: %s)%s\n' "$C_BOLD" "$C_OFF" "$C_DIM" "$TIERS" "$C_OFF"
[ "$LANES" = two ] && printf '%stwo lanes: the podman tiers below, and static/unit/shim alongside them%s\n' \
                             "$C_DIM" "$C_OFF"
printf '%s\n' "-------------------------------------------------------------------"

if [ "$LANES" = two ]; then
    CHEAPLOG="$(mktemp "${TMPDIR:-/tmp}/cs193v-lane.XXXXXX")"
    # Everything the lane emits goes to its log, fd 3 and 4 included — those are where
    # run_suite sends each suite's own output, and in this lane the log IS the terminal.
    # shellcheck disable=SC2086
    ( exec >"$CHEAPLOG" 2>&1 3>&1 4>&1; run_lane $CHEAP ) &
    CHEAP_PID=$!
    # shellcheck disable=SC2086
    run_lane $PODMAN
    wait "$CHEAP_PID" 2>/dev/null || true
    CHEAP_PID=""
    flush_cheap
else
    # shellcheck disable=SC2086
    run_lane $CHEAP $PODMAN
fi

# ─── summarise ─────────────────────────────────────────────────────────────────
# grep -c prints 0 AND exits 1 when nothing matches, so `|| echo 0` would emit "0\n0".
# Take grep's output and ignore its status instead.
count() {
    local n
    n="$(grep -c "^$1	" "$RESULTS" 2>/dev/null)" || true
    printf '%s' "${n:-0}"
}
P="$(count PASS)"; F="$(count FAIL)"; S="$(count SKIP)"; R="$(count REC)"

printf '\n%s\n' "-------------------------------------------------------------------"

# Where the time went, slowest first. Printed above the counts rather than below them,
# because the counts are the verdict and should be the last thing on the screen.
# bash has no float arithmetic, so the sort and the total are one awk rather than a loop.
if [ "$RAN" -gt 1 ]; then
    sort -rn "$TIMINGS" | awk -v dim="$C_DIM" -v off="$C_OFF" '
        { total += $1; printf "  %s%8.1fs  %s%s\n", dim, $1, $2, off }
        END { printf "  %s%8.1fs  suite time, added up%s\n", dim, total, off }'
    # Wall clock separately, and it is the number that matters: with two lanes it is less than
    # the sum above, and how much less is the whole point of running them.
    printf '  %s%8ss  wall clock%s\n\n' "$C_DIM" "$((SECONDS - WALL_T0))" "$C_OFF"
fi

# Printed BEFORE the counts, because a suite that died makes the counts an undercount and the
# reader needs to know that before reading them. rc 97 is _emit's: see lib/assert.sh.
if [ -s "$CRASHES" ]; then
    printf '%sSUITES THAT DIED%s\n' "$C_RED" "$C_OFF"
    while IFS="	" read -r rc suite; do
        printf '  %s  exited %s without finishing\n' "$suite" "$rc"
        # 97 is _emit's, and it means the counts below are an undercount of a run that had
        # already stopped recording — a different thing from a suite that merely fell over.
        [ "$rc" = 97 ] && printf '  %s\n' \
            "      its results file could not be written, so results were LOST and every" \
            "      count below is an undercount"
    done < "$CRASHES"
    printf '\n'
fi

if [ "$F" -gt 0 ]; then
    printf '%sFAILURES%s\n' "$C_RED" "$C_OFF"
    grep "^FAIL	" "$RESULTS" | while IFS="	" read -r _st suite name; do
        printf '  %s  %s\n' "$suite" "$name"
    done
    printf '\n'
fi
printf '%s%s pass%s   ' "$C_GRN" "$P" "$C_OFF"
[ "$F" -gt 0 ] && printf '%s%s fail%s   ' "$C_RED" "$F" "$C_OFF" || printf '0 fail   '
printf '%s%s skip   %s recorded%s\n' "$C_DIM" "$S" "$R" "$C_OFF"

# A dead suite fails the run even with no FAIL line to its name: the point of the count is that
# it can be trusted, and it cannot be when a suite stopped early.
[ "$F" -eq 0 ] && [ ! -s "$CRASHES" ]
