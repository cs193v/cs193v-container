# shellcheck shell=bash
#
# CS193V test assertions.
#
# MUST STAY BASH 3.2 COMPATIBLE — the TAs run this on Macs to settle VERIFICATION.md
# §5.2/§5.3, and macOS ships bash 3.2. Same ban list as the scripts under test:
# no associative arrays, no mapfile/readarray, no ${var,,}, no `read -t 0.5`, no |&.
#
# Results are appended to $CS193V_RESULTS as tab-separated lines rather than kept in
# shell variables, because every test file runs as its own process — a counter in a
# variable would not survive back to run-tests.sh.
#
# Each assertion prints its own line as it happens, so a hanging suite still shows you
# how far it got. run-tests.sh only aggregates.

# ─── output ────────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    A_GRN=$(printf '\033[32m'); A_RED=$(printf '\033[1;31m')
    A_YEL=$(printf '\033[33m'); A_DIM=$(printf '\033[2m'); A_OFF=$(printf '\033[0m')
else
    A_GRN=''; A_RED=''; A_YEL=''; A_DIM=''; A_OFF=''
fi

# The file every assertion appends to. run-tests.sh sets it; if a test file is run
# directly (which is supported, and useful while writing one) fall back to a temp file.
if [ -z "${CS193V_RESULTS:-}" ]; then
    CS193V_RESULTS="$(mktemp "${TMPDIR:-/tmp}/cs193v-results.XXXXXX")"
    export CS193V_RESULTS
    CS193V_STANDALONE=1
fi
: "${CS193V_SUITE:=$(basename "${0:-suite}")}"

_emit() {                             # _emit STATUS NAME
    printf '%s\t%s\t%s\n' "$1" "$CS193V_SUITE" "$2" >> "$CS193V_RESULTS"
}

# Detail lines go to stdout only. Keeping them out of the results file is what lets the
# file stay line-per-result even when podman's output is fifteen lines long.
_detail() {
    [ -n "${1:-}" ] || return 0
    printf '%s\n' "$1" | while IFS= read -r _dl; do
        printf '        %s%s%s\n' "$A_DIM" "$_dl" "$A_OFF"
    done
}

pass() { _emit PASS "$1"; printf '  %sPASS%s  %s\n' "$A_GRN" "$A_OFF" "$1"; }
fail() { _emit FAIL "$1"; printf '  %sFAIL%s  %s\n' "$A_RED" "$A_OFF" "$1"; _detail "${2:-}"; }
skip() { _emit SKIP "$1"; printf '  %sSKIP%s  %s %s\n' "$A_YEL" "$A_OFF" "$1" "${2:+($2)}"; }

# For VERIFICATION.md's "record, do not assert" items — genuinely platform-dependent
# values that a human needs to read, but which no fixed expectation would survive.
record() {
    _emit REC "$1"
    printf '  %sREC %s  %s = %s\n' "$A_DIM" "$A_OFF" "$1" "$(printf '%s' "${2:-}" | tr '\n' ' ')"
}

# ─── assertions ────────────────────────────────────────────────────────────────
assert_eq() {                         # assert_eq NAME EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then pass "$1"
    else fail "$1" "expected: $2
actual:   $3"; fi
}

assert_ne() {                         # assert_ne NAME NOT_EXPECTED ACTUAL
    if [ "$2" != "$3" ]; then pass "$1"
    else fail "$1" "expected anything but: $2"; fi
}

# Literal substring, not a pattern — the thing being searched for is usually a path or a
# flag full of regex metacharacters.
assert_contains() {                   # assert_contains NAME NEEDLE HAYSTACK
    case "$3" in
        *"$2"*) pass "$1" ;;
        *) fail "$1" "expected to contain: $2
actual:                $3" ;;
    esac
}

assert_not_contains() {               # assert_not_contains NAME NEEDLE HAYSTACK
    case "$3" in
        *"$2"*) fail "$1" "expected NOT to contain: $2
actual:                    $3" ;;
        *) pass "$1" ;;
    esac
}

# Prose assertions must survive re-wrapping. messages.txt is hard-wrapped to the STOP box
# width, so a phrase like "different folder" can land with the line break in the middle of
# it — and die() prefixes every line with ┃. Flatten the box art and collapse whitespace
# before matching, so a test asserts on what the student reads rather than on where the
# line happens to break.
_flatten() {
    printf '%s' "$1" \
        | tr '\n' ' ' \
        | sed -e 's/[┃┏┓┗┛━]//g' -e 's/[[:space:]][[:space:]]*/ /g'
}

assert_says() {                       # assert_says NAME PHRASE TEXT
    local hay; hay="$(_flatten "$3")"
    case "$hay" in
        *"$2"*) pass "$1" ;;
        *) fail "$1" "expected the output to say: $2
flattened output:          $hay" ;;
    esac
}

assert_says_not() {                   # assert_says_not NAME PHRASE TEXT
    local hay; hay="$(_flatten "$3")"
    case "$hay" in
        *"$2"*) fail "$1" "expected the output NOT to say: $2
flattened output:              $hay" ;;
        *) pass "$1" ;;
    esac
}

assert_match() {                      # assert_match NAME ERE ACTUAL
    if printf '%s\n' "$3" | grep -qE "$2"; then pass "$1"
    else fail "$1" "expected to match: /$2/
actual:             $3"; fi
}

assert_not_match() {                  # assert_not_match NAME ERE ACTUAL
    if printf '%s\n' "$3" | grep -qE "$2"; then
        fail "$1" "expected NOT to match: /$2/
actual:                 $3"
    else pass "$1"; fi
}

assert_ok() {                         # assert_ok NAME CMD...
    local n="$1"; shift
    local out
    if out="$("$@" 2>&1)"; then pass "$n"
    else fail "$n" "command failed: $*
$out"; fi
}

assert_fail() {                       # assert_fail NAME CMD...   (must exit non-zero)
    local n="$1"; shift
    local out
    if out="$("$@" 2>&1)"; then fail "$n" "expected failure but it succeeded: $*
$out"
    else pass "$n"; fi
}

assert_exit() {                       # assert_exit NAME WANT_RC CMD...
    local n="$1" want="$2"; shift 2
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if [ "$rc" -eq "$want" ]; then pass "$n"
    else fail "$n" "expected exit $want, got $rc, from: $*
$out"; fi
}

assert_file() {   [ -f "$2" ] && pass "$1" || fail "$1" "not a file: $2"; }
assert_no_file() { [ -e "$2" ] && fail "$1" "exists but should not: $2" || pass "$1"; }
assert_exec()  {  [ -x "$2" ] && pass "$1" || fail "$1" "not executable: $2"; }

# ─── requirements ──────────────────────────────────────────────────────────────
# By project decision these HARD-FAIL rather than skip: a green run must mean the whole
# thing was exercised, not that half of it quietly opted out. The message names the exact
# command to fix it.
require_cmd() {                       # require_cmd CMD [HINT]
    command -v "$1" >/dev/null 2>&1 && return 0
    fail "require:$1" "$1 is not installed.${2:+ $2}"
    exit 1
}

require_podman() {
    require_cmd podman "Run: sudo apt install -y podman passt uidmap crun"
}

require_image() {                     # require_image  -> exports TEST_IMAGE
    require_podman
    TEST_IMAGE="${CS193V_TEST_IMAGE:-localhost/cs193v:dev}"
    export TEST_IMAGE
    if ! podman image exists "$TEST_IMAGE" 2>/dev/null; then
        fail "require:image" "The image $TEST_IMAGE does not exist.
Build it first:  ./cs193v --dev-build
(or point CS193V_TEST_IMAGE at a published image)"
        exit 1
    fi
}

require_running() {                   # require_running  -> the cs193v container is up
    require_podman
    if [ "$(podman inspect cs193v --format '{{.State.Status}}' 2>/dev/null)" != running ]; then
        fail "require:running" "The cs193v container is not running.
Start it first:  ./cs193v --rebuild"
        exit 1
    fi
}

# ─── helpers shared by suites ──────────────────────────────────────────────────
# Repo root, resolved from this file so suites work from any working directory.
_assert_self="${BASH_SOURCE[0]:-$0}"
TESTS_DIR="$(cd -- "$(dirname -- "$_assert_self")/.." && pwd -P)"
REPO="$(cd -- "$TESTS_DIR/.." && pwd -P)"
export TESTS_DIR REPO

# In-container and throwaway-container runners, matching VERIFICATION.md's E() and R().
E() { podman exec cs193v sh -c "$1" 2>&1; }
R() { podman run --rm --entrypoint sh "${TEST_IMAGE:-localhost/cs193v:dev}" -c "$1" 2>&1; }
I() { podman inspect cs193v --format "$1" 2>&1; }

# A scratch directory per suite, cleaned up on exit.
new_tmpdir() {
    local d
    d="$(mktemp -d "${TMPDIR:-/tmp}/cs193v-t.XXXXXX")"
    printf '%s' "$d"
}

# Print the summary when a suite is run directly rather than through run-tests.sh.
# grep -c prints 0 and exits 1 on no match, so take its output and ignore its status.
_count() {
    local n
    n="$(grep -c "^$1" "$CS193V_RESULTS" 2>/dev/null)" || true
    printf '%s' "${n:-0}"
}
if [ -n "${CS193V_STANDALONE:-}" ]; then
    trap '
        printf "\n  %s standalone: %s pass, %s fail, %s skip\n" \
            "$CS193V_SUITE" "$(_count PASS)" "$(_count FAIL)" "$(_count SKIP)"
        rm -f "$CS193V_RESULTS"
    ' EXIT
fi
