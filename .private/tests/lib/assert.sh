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
# launcher's IMAGE is. Unset -> plain "cs193v", byte-identical to before.
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

# Assert on a message by KEY rather than by quoting its prose. A test that hardcodes what a
# message says fails the day somebody rewords messages.txt — punishing the wrong change, and
# teaching the next person that editing student-facing text breaks the suite.
#
# The block parser is msg()'s own, copied rather than approximated, so a test and the launcher
# cannot disagree about where a message ends. Flattened for the same reason assert_says flattens
# its haystack, and because assert_says flattens only that side.
#
# TRUNCATED AT THE FIRST {{PLACEHOLDER}}: the rest is filled in at runtime, so only the literal
# prefix is a phrase the student is guaranteed to read. warn.tunnel-failed interpolates {{LOG}}
# and {{OUT}}, which is most of its tail.
msg_text() {                          # msg_text KEY -> its literal prose, one flattened line
    local t
    t="$(awk -v k="[[$1]]" '
        $0 == k { found = 1; next }
        /^\[\[.*\]\]$/ { if (found) exit }
        found { print }
    ' "$PRIVATE/messages.txt")"
    # Trimmed at both ends: flattening a block that ends in a newline leaves a trailing space,
    # and a needle whose last character is a space would not match a phrase at the end of a line.
    t="$(_flatten "${t%%\{\{*}")"
    t="${t# }"
    printf '%s' "${t% }"
}

# An unknown or all-placeholder key FAILS rather than passing vacuously, which is the trap the
# negative form would otherwise set: assert_says_not with an empty needle passes every time.
assert_says_key() {                   # assert_says_key NAME KEY TEXT
    local phrase; phrase="$(msg_text "$2")"
    case "$phrase" in
        ''|' ') fail "$1" "no literal prose for message key: $2" ; return 0 ;;
    esac
    assert_says "$1" "$phrase" "$3"
}
assert_says_not_key() {               # assert_says_not_key NAME KEY TEXT
    local phrase; phrase="$(msg_text "$2")"
    case "$phrase" in
        ''|' ') fail "$1" "no literal prose for message key: $2" ; return 0 ;;
    esac
    assert_says_not "$1" "$phrase" "$3"
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
Build it first:  ./cs193v --rebuild
(or point CS193V_TEST_IMAGE at another image)"
        exit 1
    fi
}

# ─── the 46 forwarded host ports ───────────────────────────────────────────────
# The port list spelled out ONCE. It was in three places, and a fourth was about to be added
# for require_tunnel below -- which is exactly the drift the launcher's own single CS193V_PORTS
# declaration exists to avoid.
CS193V_FWD_RE='^127\.0\.0\.1:(300[0-9]|417[3-6]|517[3-9]|61(7[3-9]|8[0-2])|800[0-9]|808[0-4])$'
# grep -c prints 0 AND exits 1 on no match, the trap documented for it elsewhere in this file.
count_forwards() {
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -cE "$CS193V_FWD_RE" || true
}

# "The ports have gone back", as a predicate rather than a sample, because ssh does not unbind
# instantly and a bare check right after a teardown is a flake that reads as a leak. Lives here
# beside the port list for the same reason that does: #41 made every teardown release the
# forwards, so three suites were about to define this, and two of them already had.
no_forwards() { [ "$(count_forwards)" = 0 ]; }

# The container tier reaches the container's own loopback THROUGH the tunnel, so it needs the
# 46 forwards up before it asserts anything about ports.
#
# It cannot assume they are: 80-launcher-live.sh now releases the tunnel when it finishes, on
# purpose, so that a completed run does not sit on 46 ports another developer's run needs. The
# cost of that is exactly here -- a second run arrives with the container still up and no
# tunnel -- and paying it with the launcher's own verb is better than leaving a developer to
# discover it from a wall of red port assertions.
#
# HARD-FAILS if they still do not come up, by the same project decision as require_image: a
# green run must mean the whole thing really ran. The message names the likeliest cause,
# because it is one nobody can deduce from the assertion that would otherwise fail.
require_tunnel() {
    [ "$(count_forwards)" = 46 ] && return 0
    # The container has to be up first, or --reset-tunnel correctly declines with
    # warn.tunnel-reset-not-running and this fails with a message about port squatting that names
    # entirely the wrong cause. Since #41 a stopped container is the NORMAL resting state, so
    # this is the common path here rather than an edge case. See hold_container.
    hold_container
    ( cd "$REPO" && printf 'exit\n' | timeout 90 ./cs193v --reset-tunnel ) >/dev/null 2>&1 || true
    [ "$(count_forwards)" = 46 ] && return 0
    fail "require:tunnel" "only $(count_forwards) of the 46 forwarded ports are up, and
--reset-tunnel did not fix it. Another cs193v instance on this machine is probably holding
them: CS193V_INSTANCE does not namespace the port list, so the first instance to start wins.
Check:  ./cs193v doctor        (the 'tunnel ports' line names what is missing)
        ss -ltnp | grep :3000  (the ssh -i path names the checkout that owns them)"
    exit 1
}

# Hold the container up for a suite to test against.
#
# THIS EXISTS BECAUSE OF #41, and it is the one place the suite has to step outside the student
# path. Every ordinary way of finishing with the container now stops it -- closing the terminal,
# and every maintenance verb -- so `./cs193v --rebuild` no longer leaves anything running and
# the old advice in require_running's failure message had become impossible to follow.
#
# `podman start` rather than a launcher verb, deliberately: there is no student-facing way to
# say "run with nobody attached", because that state is exactly what #41 abolished, and adding a
# verb for it would put a hole in the invariant purely to serve the tests. Driving raw podman is
# honest about being a test fixture, and the suite already does it throughout -- E/I/R, and the
# drift group's own stop/start pair.
#
# The tunnel comes back via --reset-tunnel, which is exempt from the session refusal for exactly
# the reason it is used here: its whole purpose is fixing the tunnel while a session is live.
hold_container() {
    [ "$(podman inspect "$NAME" --format '{{.State.Status}}' 2>/dev/null)" = running ] && return 0
    podman start "$NAME" >/dev/null 2>&1 || return 1
    wait_until 15 sh -c "[ \"\$(podman inspect $NAME --format '{{.State.Status}}' 2>/dev/null)\" = running ]"
}

# The other half of hold_container, and just as necessary. Put the container back to stopped, which
# since #41 is the precondition for RUNNING THE LAUNCHER AT ALL.
#
# The two pull in opposite directions and a suite needs both, which is the part that is easy to get
# wrong: a suite must raise the container to `podman exec` into it, and must lower it again before
# `./cs193v` or any maintenance verb, because those refuse while a session is live. Skipping this is
# not a hang or an error -- the verb prints err.session-in-use and exits 1, so an idempotency test
# quietly becomes a test of twenty refusals and still counts as having run. That is exactly what it
# did the first time this was written, and it is why both helpers say so here.
release_container() {
    case "$(podman inspect "$NAME" --format '{{.State.Status}}' 2>/dev/null)" in
        running) : ;;
        *) return 0 ;;
    esac
    podman stop -t 3 -i "$NAME" >/dev/null 2>&1 || true
    wait_until 20 sh -c "[ \"\$(podman inspect $NAME --format '{{.State.Status}}' 2>/dev/null)\" != running ]"
}

require_running() {                   # require_running  -> the container under test is up
    require_podman
    hold_container
    if [ "$(podman inspect "$NAME" --format '{{.State.Status}}' 2>/dev/null)" != running ]; then
        fail "require:running" "The $NAME container is not running, and podman start could not
raise it. Create one first:  ./cs193v --rebuild
That no longer LEAVES it running -- since #41 a container only stays up while a terminal window
is open on it -- so the suite starts it itself. If this failed, the container does not exist."
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

# ─── waiting for something, rather than waiting a while ────────────────────────
# Three loops in this suite were already hand-rolled versions of this — container_pkill just
# below, probe_start in 60-container.sh, and the http.server poll in 80-launcher-live.sh —
# which is the usual sign that the shape belongs in one place.
#
# THE CEILING IS NOT THE COST. It is only reached when the thing never happens, which is when
# the assertion that follows was going to fail anyway. So a ceiling here is set generously
# larger than the fixed sleep it replaces: more patient than the old wait on a slow machine,
# and near-free on a fast one. And this never replaces an assertion — every call site still
# asserts afterwards, so a wait that times out reports the same failure it always did, just
# later. Nothing here can turn a red check green.
#
# WHAT IT MUST NOT BE USED FOR: proving that nothing happened. Polling for an absence returns
# the instant the thing is absent, which for something that was never present is immediately —
# so a check that a stray key changed nothing, or that a killed server stayed dead, keeps its
# fixed sleep. Those are marked at their call sites.
#
# CMD is run directly rather than eval'd, so anything with a pipe in it wants a shell function.
# 20 Hz because that is what container_pkill already polls at and its teardown is measured at
# 0.35 s; a slower tick would make the commonest wait here worse than it is today.
wait_until() {                        # wait_until SECS CMD [ARGS...]  -> 0 as soon as CMD succeeds
    local limit="$1"; shift
    local i=0 max=$((limit * 20))
    while [ "$i" -lt "$max" ]; do
        "$@" && return 0
        sleep 0.05
        i=$((i + 1))
    done
    return 1
}

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

# ─── the processes the suites start inside the container ────────────────────────
# NEVER ASK pgrep A QUESTION THROUGH E(). E() wraps its argument in `sh -c "$1"`, so that
# shell's own command line contains the pattern and `pgrep -f` matches the shell -- the check
# then answers "a process is running" with nothing running at all. Measured:
#
#     $ podman exec cs193v sh -c 'pgrep -f "http.server 3000" >/dev/null && echo yes || echo no'
#     yes                                     # with no server anywhere, and curl saying 000
#
# 70-sighup.sh asked exactly that way, which made its whole alive= column unconditionally
# "yes" and two assertions unconditionally green (#34). Exec pgrep DIRECTLY instead: it
# excludes its own pid, and passing the pattern as one argv word leaves no shell to match.
container_pgrep() {                   # container_pgrep PATTERN -> 0 if anything matches
    podman exec "$NAME" pgrep -f "$1" >/dev/null 2>&1
}

# Kill and then WAIT, rather than kill and hope. The suites bind the same ports over and over,
# and a bind issued while the previous holder is still dying fails -- which used to be silent
# and is now an assertion, so sampling the teardown would turn a real pass into a flake. Same
# reasoning as #32: wait for the thing to be gone instead of guessing how long it takes.
# Measured at 0.35 s here, against the 1-2 s the sleeps it replaces guessed at.
_container_gone() { ! container_pgrep "$1"; }
container_pkill() {                   # container_pkill PATTERN -> returns when nothing matches
    podman exec "$NAME" pkill -f "$1" >/dev/null 2>&1 || true
    # 10 s and still there: return 1 and let the caller's assertion say so.
    wait_until 10 _container_gone "$1"
}

# The process half of clean_vt_fixtures, and it exists for the same reason: an EXIT trap does
# not run on KILL, so a killed run leaves its servers listening and only start-up cleanup can
# get rid of them. What that costs is worse than a stray process -- a leftover listener on a
# forwarded port answers the NEXT run's request, so `ports:...-reach-a-loopback-bound-server`
# passed with nothing bound to loopback and `ports:not-reachable-from-the-LAN` passed with
# nothing exposed to the LAN (#34).
#
# One marker per thing the suites start, and every pattern is NARROW on purpose: a developer's
# own dev server in their own container is not this suite's to kill. `http.server 3000` is the
# port 70-sighup.sh and 80-launcher-live.sh both use, not http.server in general.
#
# A no-op when the container is not running: podman exec fails, pkill matches nothing and
# container_pkill returns immediately. That is what lets 80-launcher-live.sh call it before
# the launcher has created anything.
clean_vt_processes() {
    container_pkill cs193v-portprobe
    container_pkill inotifywait
    container_pkill 'http.server 3000'
}

# How many of them a previous run left behind. Recorded rather than swept silently, so a run
# that was killed leaves a trace in the results instead of being invisible. Counts PROCESSES,
# not probes: one abandoned probe accounts for two, its `sh -c` wrapper and the python inside.
#
# `pgrep -c` prints 0 AND exits 1 when nothing matches, the same trap run-tests.sh documents
# for `grep -c`, so take its output and ignore its status.
count_vt_processes() {
    local n
    n="$(podman exec "$NAME" pgrep -cf 'cs193v-portprobe|inotifywait|http\.server 3000' 2>/dev/null | head -1)"
    printf '%s' "${n:-0}"
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
