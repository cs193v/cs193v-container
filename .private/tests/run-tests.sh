#!/usr/bin/env bash
#
# CS193V container test runner.
#
#   tests/run-tests.sh                    everything except the release gates
#   tests/run-tests.sh --tier static      one tier (comma-separated for several)
#   tests/run-tests.sh -k ports           only suites whose filename matches
#   tests/run-tests.sh --release          the "not shippable yet" gates
#   tests/run-tests.sh --list             what exists, and in which tier
#
# MUST STAY BASH 3.2 COMPATIBLE — see tests/lib/assert.sh for why.
#
# Tiers, cheapest first. Each suite declares its own with a `# TIER:` line, so adding a
# suite needs no edit here.
#
#   static     no podman, no image, no network. Milliseconds.
#   unit       language-level unit tests (files/ports).
#   shim       the launcher's state machine against a fake podman on PATH. No containers.
#   image      assertions about the built image, via throwaway containers.
#   container  assertions about a live cs193v container: flags, kernel, ports, files.
#   live       the launcher driving real podman: idempotency, drift, cleanup.
#   release    release gates — NOT run by default. These fail until the repo is
#              shippable, which is a standing state of affairs, not a regression.
#
# image/container/live HARD-FAIL rather than skip when their prerequisite is missing, by
# project decision: a green run must mean the whole thing really ran.

set -u

DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"

DEFAULT_TIERS="static unit shim image container live"
TIERS=""
FILTER=""

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

# ─── discover ──────────────────────────────────────────────────────────────────
SUITES=""
for f in "$DIR"/[0-9][0-9]-*.sh "$DIR"/[0-9][0-9]-*.py; do
    [ -f "$f" ] || continue
    SUITES="$SUITES $f"
done

if [ "$LIST_ONLY" = yes ]; then
    printf '%stier       suite%s\n' "$C_BOLD" "$C_OFF"
    for f in $SUITES; do printf '%-10s %s\n' "$(tier_of "$f")" "$(basename "$f")"; done
    exit 0
fi

# ─── run ───────────────────────────────────────────────────────────────────────
RESULTS="$(mktemp "${TMPDIR:-/tmp}/cs193v-run.XXXXXX")"
export CS193V_RESULTS="$RESULTS"
trap 'rm -f "$RESULTS"' EXIT

printf '%sCS193V container tests%s  %s(tiers: %s)%s\n' "$C_BOLD" "$C_OFF" "$C_DIM" "$TIERS" "$C_OFF"
printf '%s\n' "-------------------------------------------------------------------"

RAN=0
for f in $SUITES; do
    base="$(basename "$f")"
    tier="$(tier_of "$f")"
    wanted "$tier" || continue
    if [ -n "$FILTER" ]; then
        case "$base" in *"$FILTER"*) : ;; *) continue ;; esac
    fi
    RAN=$((RAN + 1))
    printf '\n%s%s%s %s[%s]%s\n' "$C_BOLD" "$base" "$C_OFF" "$C_DIM" "$tier" "$C_OFF"
    CS193V_SUITE="$base"; export CS193V_SUITE
    case "$f" in
        *.py) python3 "$f" || true ;;
        *)    bash "$f" || true ;;
    esac
done

if [ "$RAN" -eq 0 ]; then
    printf '\n%sno suites matched%s (tiers: %s, filter: %s)\n' "$C_YEL" "$C_OFF" "$TIERS" "${FILTER:-none}" >&2
    exit 2
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

[ "$F" -eq 0 ]
