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
#   coverage   did the suite really execute every line of install-cs193v.sh it claims to?
#              Reads the traces the installer runs leave in $CS193V_RUN_DIR, so it has to run
#              after them -- which is why it is numbered last rather than living in 10-static.
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
# ARCHITECTURE IS THE ONE EXCEPTION to that, and it is not an erosion of it: a missing dependency
# is something the operator can install, an instruction set is not. The wine fixture and the Arch
# fixture SKIP on arm64 rather than failing -- see lib/wine.sh and 26-installer-sandbox.sh.
#
# ─── exit codes ────────────────────────────────────────────────────────────────
#   0   green
#   1   a test failed, or a suite died
#   2   you asked for something that does not exist (bad option, no suite matched)
#  78   THIS MACHINE CANNOT RUN THE TESTS -- the preflight refused. EX_CONFIG from sysexits.h,
#       chosen over an arbitrary number because a CI author can look it up (#124)
#  97   results were lost mid-run: see _emit in lib/assert.sh
# 130   interrupted
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

DEFAULT_TIERS="static unit shim install image container live coverage"
TIERS=""
FILTER=""
PARALLEL=yes

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_BOLD=$(printf '\033[1m'); C_GRN=$(printf '\033[32m'); C_RED=$(printf '\033[1;31m')
    C_YEL=$(printf '\033[33m'); C_DIM=$(printf '\033[2m'); C_OFF=$(printf '\033[0m')
else
    C_BOLD=''; C_GRN=''; C_RED=''; C_YEL=''; C_DIM=''; C_OFF=''
fi

# SOURCED HERE, above the option loop, and NOT beside the gate call below. The loop uses do_tr to
# split `--tier a,b,c`, and those are the only wrapped-tool calls anywhere above the gate -- so
# placing this line at the gate would leave them unable to reach it. Sourcing and calling are
# independent: this file is inert at source time by its own rule, so it loads early and the GATE
# still runs where it has to.
#
# Two consequences worth knowing. `-h` and `--list` exit from inside that same loop, so they now
# pay the capability probes -- two or three `command -v` calls, and _pt_pick can neither print nor
# exit. And run-tests.sh now depends on lib/portable.sh staying inert, which is a stated rule that
# nothing enforces.
# shellcheck source=lib/portable.sh
. "$DIR/lib/portable.sh"

usage() {
    sed -n '3,30p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
    exit "${1:-0}"
}

LIST_ONLY=no
while [ "$#" -gt 0 ]; do
    case "$1" in
        --tier)    shift; TIERS="$(printf '%s' "${1:-}" | do_tr ',' ' ')" ;;
        --tier=*)  TIERS="$(printf '%s' "${1#--tier=}" | do_tr ',' ' ')" ;;
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

# ─── the preflight, and why it is not a test (#124) ───────────────────────────
# PLACED HERE FOR EVERYTHING IT GETS FOR FREE. Nothing has forked yet, so this runs once in the
# parent on the real terminal with the colours above already set. It is above the tier and lane
# selection, so it is unconditional by construction. And it is above CS193V_RUN_DIR, the mkdir,
# the traps and the results file below -- so a refusal LEAVES NO RUN DIRECTORY AND NO RESULTS
# FILE, which is the cleanest available proof that it is not a test.
#
# `-h` and `--list` exit above it and stay ungated, deliberately: they answer questions about the
# repo, not about the machine, and a machine that fails the gate must still be able to read the
# help that explains the gate.
#
# NOT A TEST, and that is the whole point. It records no PASS/FAIL/SKIP, adds nothing to the
# tally, and is not a suite that died. A missing dependency does not mean an assertion was wrong,
# it means the suite cannot ask its questions -- so it aborts with a diagnosis and exit 78 rather
# than contributing to a 344-line failure list in which "your machine is wrong" and "the code is
# wrong" look identical.
preflight() {
    local missing name why mac deb plat pkgs fix seen=''
    missing="$(pt_missing)" && ! pt_bash_too_old && return 0

    printf '\n%sTHIS MACHINE CANNOT RUN THE TEST SUITE%s%*s(#124)\n\n' \
           "$C_RED$C_BOLD" "$C_OFF" 32 ''
    if pt_bash_too_old; then
        printf '  %-12s %s\n' bash "reports ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}, and 3.2 or newer is needed"
        printf '  %-12s %s\n\n' '' 'This is a FLOOR and never a ceiling -- see the note above.'
    fi

    # COLLECTED, then printed once. A fresh machine is missing several things at once, and a gate
    # that makes you fix them one run at a time is worse than the disease.
    case "$(uname -s)" in Darwin) plat=mac ;; *) plat=deb ;; esac
    pkgs=''
    while IFS='|' read -r name why mac deb; do
        [ -n "${name:-}" ] || continue
        case "$plat" in mac) fix="$mac" ;; *) fix="$deb" ;; esac
        printf '  %-12s %s\n' "$name" 'is missing, or is not the build this suite needs'
        printf '  %-12s why  %s\n' '' "$why"
        case "$fix" in
            '('*) printf '  %-12s note %s\n\n' '' "$fix" ;;
            *)    case "$plat" in
                      mac) printf '  %-12s fix  brew install %s\n\n' '' "$fix" ;;
                      *)   printf '  %-12s fix  sudo apt install -y %s\n\n' '' "$fix" ;;
                  esac
                  # De-duplicated with the no-associative-array idiom this project uses
                  # elsewhere, because one package satisfies several rows.
                  case " $seen " in *" $fix "*) ;; *) seen="$seen $fix"; pkgs="$pkgs $fix" ;; esac ;;
        esac
    done <<PREFLIGHT_EOF
$missing
PREFLIGHT_EOF

    [ -z "$pkgs" ] || case "$plat" in
        mac) printf '  all of them:  brew install%s\n\n' "$pkgs" ;;
        *)   printf '  all of them:  sudo apt install -y%s\n\n' "$pkgs" ;;
    esac
    printf 'Nothing was run and nothing was recorded: this is not a test failure, it is a\n'
    printf 'machine that cannot ask the question.\n\n'
    exit 78
}
preflight

# ─── run ───────────────────────────────────────────────────────────────────────
WALL_T0=$SECONDS
# ONE DIRECTORY PER RUN, AND IT IS KEPT. These files used to be loose mktemps deleted by the
# cleanup trap, so a run that hung and was killed destroyed the only evidence of where it got
# to -- which is the opposite of what assert.sh prints per assertion for. Named by pid so the
# sweep below can tell a finished run's leftovers from a concurrent run's live ones, the same
# reasoning lib/assert.sh gives for sweeping scratch directories by pid rather than by age.
#
# Exported, because it is also the channel a suite can leave artefacts in for a later suite to
# read -- which is what a coverage gate spanning both lanes needs and had nowhere to put.
CS193V_RUN_DIR="${TMPDIR:-/tmp}/cs193v-runlog.$$"
mkdir -p "$CS193V_RUN_DIR"
export CS193V_RUN_DIR
# An earlier run's directory, only if the process that made it is gone.
for _d in "${TMPDIR:-/tmp}"/cs193v-runlog.*; do
    [ -d "$_d" ] || continue
    _p="${_d##*.}"
    case "$_p" in ''|*[!0-9]*) continue ;; esac
    [ "$_p" = "$$" ] && continue
    kill -0 "$_p" 2>/dev/null && continue
    rm -rf "$_d" 2>/dev/null || true
done
RESULTS="$CS193V_RUN_DIR/results.tsv"; : > "$RESULTS"
export CS193V_RESULTS="$RESULTS"
TIMINGS="$CS193V_RUN_DIR/timings.tsv"; : > "$TIMINGS"
# Suites that exited without finishing, one per line. A FILE rather than a variable because the
# cheap lane runs inside a subshell, so a counter set there would never come back — the same
# thing that made repo_copy leak (#76).
CRASHES="$CS193V_RUN_DIR/crashes.tsv"; : > "$CRASHES"
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
    # DELIBERATELY NOT REMOVED. The run directory is the record of what happened, and it is
    # most wanted exactly when the run did not finish. Its path is printed below; the next run
    # sweeps it once this pid is gone.
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
    CHEAPLOG="$CS193V_RUN_DIR/cheap-lane.log"; : > "$CHEAPLOG"
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
# Where the record of this run is, said on every run rather than only on a bad one -- a path
# you only learn about when things went wrong is a path you have to go looking for at the worst
# moment. Holds results.tsv, timings.tsv, crashes.tsv and the no-podman lane's full output.
printf '%slog: %s%s\n' "$C_DIM" "$CS193V_RUN_DIR" "$C_OFF"

# A dead suite fails the run even with no FAIL line to its name: the point of the count is that
# it can be trusted, and it cannot be when a suite stopped early.
[ "$F" -eq 0 ] && [ ! -s "$CRASHES" ]
