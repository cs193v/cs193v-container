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

# ─── the instance under test ───────────────────────────────────────────────────
# Mirrors ./cs193v's CS193V_INSTANCE suffix, so a developer with their own instance runs
# this suite against THEIR container instead of a colleague's. Every suite refers to
# "$NAME" rather than a literal, and the image default is suffixed the same way the
# launcher's LOCAL_IMAGE is. Unset -> plain "cs193v", byte-identical to before.
NAME="cs193v${CS193V_INSTANCE:+-$CS193V_INSTANCE}"
# The dev image tag, suffixed the same way. Defined once here because three places used to
# spell the default out, and a suffixed instance would have missed whichever one drifted.
TEST_IMAGE_DEFAULT="localhost/cs193v:local${CS193V_INSTANCE:+-$CS193V_INSTANCE}"
export NAME TEST_IMAGE_DEFAULT

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

# ─── box art ───────────────────────────────────────────────────────────────────
# Shared because two suites draw conclusions from it now: 20-messages.sh renders die() and
# the installer's boxes, and 30-launcher-shim.sh renders the build's success box -- the
# first box in this project that is not an error. See issue #21 for what it is checking and
# why neither of the checks that came before it could.
box_problems() {                      # box art on stdin -> one line per structural problem
    python3 -c '
import sys
lines = sys.stdin.read().splitlines()
# The box is everything from the lid to the floor. Leading indentation is part of it: the
# installer indents its box by two columns and the launcher does not, and a body line that
# disagrees with its own lid about that is just as broken as a missing wall.
top = next((i for i, l in enumerate(lines) if "┏" in l), None)
bot = next((i for i, l in enumerate(lines) if "┗" in l), None)
if top is None or bot is None or bot <= top:
    print("no complete box found in the output"); sys.exit(0)
box = lines[top:bot + 1]
w = len(box[0])
for n, l in enumerate(box):
    want = ("┏", "┓") if n == 0 else \
           ("┗", "┛") if n == len(box) - 1 else ("┃", "┃")
    ind = len(l) - len(l.lstrip(" "))
    ind0 = len(box[0]) - len(box[0].lstrip(" "))
    s = l.strip()
    if len(l) != w:
        print("line %d is %d columns, the lid is %d: %r" % (n, len(l), w, l))
    if ind != ind0:
        print("line %d is indented %d columns, the lid is %d: %r" % (n, ind, ind0, l))
    if not s.startswith(want[0]):
        print("line %d has no left border: %r" % (n, l))
    if not s.endswith(want[1]):
        print("line %d has no right border: %r" % (n, l))
'
}

# ─── replaying a terminal ──────────────────────────────────────────────────────
# A pty transcript is not what the student SEES -- it is the byte stream that produced it.
# Anything drawn with \r overwrites what came before on that line, so "the bar appears 23
# times" and "the bar appears once, updated 23 times" are the same bytes and completely
# different screens. Assertions about a redrawn display have to be made against the screen.
#
# Replays the three things this launcher actually emits: \r (column 0), \n (new line) and
# ESC[K (erase to end of line). Other CSI sequences are colour and are dropped.
render_pty() {                        # raw transcript on stdin -> one repr()'d line per row
    python3 -c '
import re, sys
raw = sys.stdin.buffer.read().decode("utf-8", "replace")
# Mark ESC[K so it survives colour-stripping, then drop every other CSI sequence.
raw = raw.replace("\x1b[K", "\x00")
raw = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", raw)
rows, cur, col = [], [], 0
for ch in raw:
    if ch == "\n":
        rows.append("".join(cur)); cur, col = [], 0
    elif ch == "\r":
        col = 0
    elif ch == "\x00":                 # ESC[K -- erase from the cursor to end of line
        del cur[col:]
    else:
        while len(cur) < col: cur.append(" ")
        if col < len(cur): cur[col] = ch
        else: cur.append(ch)
        col += 1
rows.append("".join(cur))
for r in rows:
    print(r.rstrip())
'
}

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
    TEST_IMAGE="${CS193V_TEST_IMAGE:-$TEST_IMAGE_DEFAULT}"
    export TEST_IMAGE
    if ! podman image exists "$TEST_IMAGE" 2>/dev/null; then
        fail "require:image" "The image $TEST_IMAGE does not exist.
Build it first:  ./cs193v --build
(or point CS193V_TEST_IMAGE at another image)"
        exit 1
    fi
}

require_running() {                   # require_running  -> the container under test is up
    require_podman
    if [ "$(podman inspect "$NAME" --format '{{.State.Status}}' 2>/dev/null)" != running ]; then
        fail "require:running" "The $NAME container is not running.
Start it first:  ./cs193v --rebuild"
        exit 1
    fi
}

# ─── helpers shared by suites ──────────────────────────────────────────────────
# Repo root, resolved from this file so suites work from any working directory.
_assert_self="${BASH_SOURCE[0]:-$0}"
TESTS_DIR="$(cd -- "$(dirname -- "$_assert_self")/.." && pwd -P)"
# The suite lives at .private/tests, so the repo root is TWO levels up, not one. $PRIVATE is
# where every build and maintenance file now lives; $REPO holds only what a student uses.
PRIVATE="$(cd -- "$TESTS_DIR/.." && pwd -P)"
REPO="$(cd -- "$PRIVATE/.." && pwd -P)"
export TESTS_DIR PRIVATE REPO

# ─── the strings the container prints ──────────────────────────────────────────
# Sourced from the SAME file the image installs at /etc/cs193v/strings.sh, so a test never
# repeats a string that a script also spells out. Rewording the greeting used to turn three
# tests red across three tiers, none of them a real regression — and the usual answer to
# that is to weaken the assertion, which is how a suite stops being worth reading.
#
# A deleted or blanked string still fails, which is the part worth keeping: these assert
# `$CS193V_WELCOME` appears, not that "some greeting" appears.
#
# Read on the HOST, straight out of .private/files/ — no container needed, so the static
# tier can use them too. That is why the file has no logic in it.
# shellcheck source=../../files/cs193v-strings.sh
[ -r "$PRIVATE/files/cs193v-strings.sh" ] && . "$PRIVATE/files/cs193v-strings.sh"
export CS193V_TITLE CS193V_WELCOME CS193V_GOODBYE

# In-container and throwaway-container runners, matching VERIFICATION.md's E() and R().
E() { podman exec "$NAME" sh -c "$1" 2>&1; }
R() { podman run --rm --entrypoint sh "${TEST_IMAGE:-$TEST_IMAGE_DEFAULT}" -c "$1" 2>&1; }
I() { podman inspect "$NAME" --format "$1" 2>&1; }

# A scratch directory per suite, cleaned up on exit.
new_tmpdir() {
    local d
    d="$(mktemp -d "${TMPDIR:-/tmp}/cs193v-t.XXXXXX")"
    printf '%s' "$d"
}

# Every fixture a suite leaves in the student's projects/ is named .vt-something, so one
# glob finds the lot. Call this at suite START as well as from the EXIT trap.
#
# Both, not either. A trap does not run when the process is KILLED -- measured: bash runs an
# EXIT trap on INT, TERM and HUP, and not on KILL -- so a run torn down outright leaves its
# fixtures behind, and start-up cleanup is the only kind that survives that. The failure it
# prevents is not a missing file but a lying assertion: `>` truncates an existing file and
# keeps its mode, so a leftover .vt-c made 60-container.sh report the PREVIOUS run's
# permissions as if the container had just written them (issue #30).
#
# Only the .vt- prefix is ever removed. Nothing else in projects/ is this suite's to delete.
clean_vt_fixtures() { rm -rf "$REPO"/projects/.vt-* 2>/dev/null || true; }

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
