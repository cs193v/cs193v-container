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
# A literal tab, so _emit can append an optional fourth field without paying a `printf`
# subshell on every one of the eleven hundred assertions in a run.
A_TAB=$(printf '\t')

# The file every assertion appends to. run-tests.sh sets it; if a test file is run
# directly (which is supported, and useful while writing one) fall back to a temp file.
if [ -z "${CS193V_RESULTS:-}" ]; then
    CS193V_RESULTS="$(mktemp "${TMPDIR:-/tmp}/cs193v-results.XXXXXX")"
    export CS193V_RESULTS
    CS193V_STANDALONE=1
fi
: "${CS193V_SUITE:=$(basename "${0:-suite}")}"

# A FAILED WRITE HERE IS FATAL, and that is the whole point of the check. This file is the ONLY
# thing run-tests.sh counts -- never the screen -- so a printf that fails and is ignored drops a
# result while the terminal still says PASS. It drops FAIL as readily as PASS, so a run that
# filled the disk reports `0 fail` and exits 0 having lost real failures.
#
# MEASURED, not imagined (#76): /tmp here is a 3.7 GB tmpfs, the suites had leaked 2.9 GB of
# repo copies into it, and an image-tier run started printing `write error: Disk quota exceeded`
# between PASS lines and had to be discarded because nobody could tell which of its results had
# survived. Same family as #34, #46 and #73: a number that looks measured and is not.
#
# `exit` really does end the suite: no assertion in this suite is called from a subshell -- every
# pass/fail is a statement, and the $( ) around them are values being handed IN. run-tests.sh
# turns the non-zero exit into a failed run, so this cannot be swallowed by `|| true`.
# THE VALUE IS A FOURTH FIELD when there is one, which today means every `record`. It used to be
# dropped, so a diff of two runs' results could not see a record go from "46 of 46" to nothing --
# and that is precisely how #34 and #46 lied, with a number that looked measured and was not.
# run-tests.sh's count() anchors on `^STATUS\t`, so nothing downstream notices.
_emit() {                             # _emit STATUS NAME [VALUE]
    printf '%s\t%s\t%s\n' "$1" "$CS193V_SUITE" "$2${3+$A_TAB$3}" >> "$CS193V_RESULTS" && return 0
    printf '\n%sFATAL%s  cannot append to $CS193V_RESULTS (%s): results are being LOST.\n' \
           "$A_RED" "$A_OFF" "$CS193V_RESULTS" >&2
    printf '        %s\n' \
           "run-tests.sh counts that file rather than the screen, so this run cannot be" \
           "summarised -- a dropped FAIL would be reported as a pass. Check free space on" \
           "that filesystem." >&2
    exit 97
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
# FLATTENED ONCE, for the file and the screen alike: the results file is one line per result and
# every consumer of it splits on tabs, so a newline or a tab inside a recorded value would forge
# a second result out of nothing.
record() {
    local v
    v="$(printf '%s' "${2:-}" | do_tr '\n\t' '  ')"
    _emit REC "$1" "$v"
    printf '  %sREC %s  %s = %s\n' "$A_DIM" "$A_OFF" "$1" "$v"
}

# ─── a checker that COULD NOT RUN ──────────────────────────────────────────────
# THE VACUOUS-GREEN THIS FILE HARD-FAILS ON, arriving through the checkers rather than through an
# assertion. box_problems and render_pty below both pipe their input through `python3 -c`, and
# both are read by assertions whose HAPPY answer is the empty string -- `assert_eq NAME ""
# "$(... | box_problems)"` and `assert_not_contains NAME needle "$(... | render_pty)"`. An
# interpreter that dies prints nothing, and nothing is the happy answer.
#
# MEASURED, NOT IMAGINED (#79). A fake python3 that printed a traceback and exited 1 left 26
# assertions in the cheap lane passing with no checker having run: ten box_problems sites, ten
# render_pty-fed negatives, and six more behind the two catalogue width lints, spread across
# 20-messages.sh, 30-launcher-shim.sh and 35-setup-git-shim.sh. `require_cmd python3` guarded
# three of those sites and caught none of it, because the sabotaged interpreter EXISTS and
# `command -v` asks nothing else.
#
# SO THE FAILURE TRAVELS IN THE VALUE, not in a marker file. The two shim suites, which hold most
# of the twenty-six, define no $TMP and run under `set -u`, so a marker written to "$TMP/..." would abort
# the very `$( )` it was meant to protect and pass vacuously again. A sentinel in the value
# survives `$( )`, survives a pipe from one checker into another, and reaches the negative
# assertions -- which is the half no happy-side sentinel can reach.
#
# It is this project's own doctrine (10-static.sh: "EVERY DERIVED CHECK ANSWERS WITH A SENTINEL
# WHEN IT IS HAPPY") read from the failing side.
CHECKER_DIED='CS193V-CHECKER-DID-NOT-RUN'

# ALWAYS EXITS 0, deliberately: the caller is a `$( )` whose value is about to be asserted on, and
# the assertion is what should do the failing. Naming the command matters as much as the status --
# `render_pty_mid | render_pty` is two checkers in one substitution.
run_checker() {                       # run_checker CMD [ARGS...]
    local rc
    "$@"
    rc=$?
    [ "$rc" -eq 0 ] || printf '%s (exit %s from: %s)\n' "$CHECKER_DIED" "$rc" "$1"
    return 0
}

# The first line of every assertion that compares strings, so no call site has to remember. It
# covers the negative forms too, which are the ones that cannot be fixed any other way: there is
# no happy-side sentinel that satisfies "the output does not contain X".
#
# IT REPORTS THE MARKER LINE, NOT THE WHOLE VALUE. The value that carries the sentinel is often a
# whole pty transcript -- sg_run poisons $SG_OUT with it when a conversation diverges, so that the
# assertions downstream of a run that stopped early fail loudly instead of passing vacuously on a
# short one. There are about a hundred of those in 35-setup-git-shim.sh, and printing 12KB into
# each of their detail lines buries the one line that says what actually went wrong. The sentinel
# and whatever the checker said beside it are the whole of the diagnosis; the transcript is already
# the subject of every other assertion in the case.
_checker_ok() {                       # _checker_ok NAME [VALUE...]  -> 1, and FAILs, if one died
    local v why
    for v in "${2-}" "${3-}"; do
        case "$v" in
            *"$CHECKER_DIED"*)
                why="$(printf '%s' "$v" | grep -F "$CHECKER_DIED" | head -3)"
                fail "$1" "$why"; return 1 ;;
        esac
    done
    return 0
}

# ─── assertions ────────────────────────────────────────────────────────────────
assert_eq() {                         # assert_eq NAME EXPECTED ACTUAL
    _checker_ok "$1" "$2" "$3" || return 0
    if [ "$2" = "$3" ]; then pass "$1"
    else fail "$1" "expected: $2
actual:   $3"; fi
}

assert_ne() {                         # assert_ne NAME NOT_EXPECTED ACTUAL
    _checker_ok "$1" "$2" "$3" || return 0
    if [ "$2" != "$3" ]; then pass "$1"
    else fail "$1" "expected anything but: $2"; fi
}

# Literal substring, not a pattern — the thing being searched for is usually a path or a
# flag full of regex metacharacters.
assert_contains() {                   # assert_contains NAME NEEDLE HAYSTACK
    _checker_ok "$1" "$2" "$3" || return 0
    case "$3" in
        *"$2"*) pass "$1" ;;
        *) fail "$1" "expected to contain: $2
actual:                $3" ;;
    esac
}

assert_not_contains() {               # assert_not_contains NAME NEEDLE HAYSTACK
    _checker_ok "$1" "$2" "$3" || return 0
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
        | do_tr '\n' ' ' \
        | sed -e 's/[┃┏┓┗┛━]//g' -e 's/[[:space:]][[:space:]]*/ /g'
}

assert_says() {                       # assert_says NAME PHRASE TEXT
    _checker_ok "$1" "$2" "$3" || return 0
    local hay; hay="$(_flatten "$3")"
    case "$hay" in
        *"$2"*) pass "$1" ;;
        *) fail "$1" "expected the output to say: $2
flattened output:          $hay" ;;
    esac
}

assert_says_not() {                   # assert_says_not NAME PHRASE TEXT
    _checker_ok "$1" "$2" "$3" || return 0
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
#
# THE FILE IS A PARAMETER, defaulting to the launcher's catalogue, because there are two of them
# now: the container cannot see messages.txt, so setup-git carries its own at
# files/setup-git-messages.txt. Both once defined a key called err.needs-a-terminal, with
# different prose and for different reasons, and this function silently read the launcher's — a
# suite failing on prose it never asked about. 10-static.sh now forbids a key from appearing in
# both files, and this takes an argument; either alone would have been enough, and both is right,
# because the argument is what makes an assertion say which catalogue it means.
msg_text() {                          # msg_text KEY [FILE] -> its literal prose, one flattened line
    local t
    # COLUMN-0 HASHES ARE STAFF NOTES AND ARE NOT PROSE, exactly as msg() decides at runtime
    # (#221 gave it that rule; keys:no-empty-bodies in 20-messages.sh is built on it). This
    # helper did not follow, and the gap was invisible for as long as no commented key was
    # asserted by name: a note above the text was folded INTO the needle, so assert_says_key
    # searched the output for a paragraph of staff prose and reported the message missing from a
    # launcher that had printed it perfectly. Measured on status.stopping the moment #220 put a
    # note on it. Student-facing text that must start with a hash is written with a leading
    # space, which is the same escape hatch msg() offers.
    t="$(awk -v k="[[$1]]" '
        $0 == k { found = 1; next }
        /^\[\[.*\]\]$/ { if (found) exit }
        found && /^#/ { next }
        found { print }
    ' "${2:-$PRIVATE/messages.txt}")"
    # Trimmed at both ends: flattening a block that ends in a newline leaves a trailing space,
    # and a needle whose last character is a space would not match a phrase at the end of a line.
    t="$(_flatten "${t%%\{\{*}")"
    t="${t# }"
    printf '%s' "${t% }"
}

# An unknown or all-placeholder key FAILS rather than passing vacuously, which is the trap the
# negative form would otherwise set: assert_says_not with an empty needle passes every time.
assert_says_key() {                   # assert_says_key NAME KEY TEXT [FILE]
    local phrase; phrase="$(msg_text "$2" "${4-}")"
    case "$phrase" in
        ''|' ') fail "$1" "no literal prose for message key: $2" ; return 0 ;;
    esac
    assert_says "$1" "$phrase" "$3"
}
assert_says_not_key() {               # assert_says_not_key NAME KEY TEXT [FILE]
    local phrase; phrase="$(msg_text "$2" "${4-}")"
    case "$phrase" in
        ''|' ') fail "$1" "no literal prose for message key: $2" ; return 0 ;;
    esac
    assert_says_not "$1" "$phrase" "$3"
}

assert_match() {                      # assert_match NAME ERE ACTUAL
    _checker_ok "$1" "$2" "$3" || return 0
    if printf '%s\n' "$3" | grep -qE "$2"; then pass "$1"
    else fail "$1" "expected to match: /$2/
actual:             $3"; fi
}

assert_not_match() {                  # assert_not_match NAME ERE ACTUAL
    _checker_ok "$1" "$2" "$3" || return 0
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

# 125, 126 AND 127 ARE NOT A FAILURE. They are the command never having happened: podman
# refusing before it started a container, a file that is not executable, a binary that is not
# installed. Six `podman run --rm` sites in 50-image.sh are assert_fails, so a podman that could
# not start the throwaway made every one of them green with no container created -- and `srv_up`
# in 70-sighup.sh is a bare curl, which exits 127 if curl is missing. Three more assert_fails exec
# into the container and assert on the INNER command's exit 1 (80-launcher-live.sh:580 and :607,
# 90-setup-git-github.sh:256); a real inner failure is 1 on both clients, MEASURED, so an absent
# container or an unreachable podman is exactly the 125 the band keeps out of them.
#
# THE BAND IS NOT THE WHOLE GUARD AT THOSE THREE, and it is worth saying which half it is. It
# covers the 125s -- no such container, podman unreachable. It does NOT cover a container that is
# merely STOPPED, because that refusal is 255 from a local client and sails straight through;
# hold_container is what covers that, and 80-launcher-live.sh:548-551 is where it says so.
#
# MEASURED before narrowing the band, because the point is to keep the refusals this suite
# deliberately provokes: `podman run` on a missing image is 125 on either client. A refusal that
# IS the thing under test cannot come through here at all -- see assert_fail_saying below (#149).
assert_fail() {                       # assert_fail NAME CMD...  (must exit non-zero, having RUN)
    local n="$1"; shift
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        fail "$n" "expected failure but it succeeded: $*
$out"
    elif [ "$rc" -ge 125 ] && [ "$rc" -le 127 ]; then
        fail "$n" "exit $rc means the command could not be RUN, which is not the failure this
asserts: $*
$out"
    else pass "$n"; fi
}

# A FAILURE THAT HAS TO BE THE RIGHT FAILURE -- for the one kind of assertion the band above
# cannot carry: a podman refusal that IS the thing under test (#149).
#
# `podman exec` into a stopped container answers with the CLIENT's exit code, not the container's.
# MEASURED on both floors this course supports and the two above them, in this suite's own nesting
# fixtures, against a genuinely exited container:
#
#     podman   local client   remote client
#      4.9.3        255            125          MIN_PODMAN_LINUX
#      5.7.0        255            125          MIN_PODMAN_MACOS
#      5.8.4        255            125
#      6.0.2        255            125
#
# ...with `can only create exec sessions on running containers: container state improper`
# byte-identical in all eight cells, and unchanged under five locales -- podman is a Go binary with
# hardcoded error strings. So the axis is remote-vs-local, not macOS-vs-Linux and not version: a
# Linux developer on a remote socket sees the same 125.
#
# WHY THE PHRASE AND NOT THE DIGIT. On a remote client the digit cannot answer at all -- the
# refusal under test, `podman run` on a missing image, an absent container, and a podman that
# cannot be reached are ALL 125. Same shape as state()'s second question in the launcher
# (ERRORS.md D13): the first question cannot break the tie and this one can.
#
# PIN THE MOST SPECIFIC PHRASE. `container state improper` is ErrCtrStateInvalid's shared text --
# `podman kill` and `podman pause` on the same container emit it under different prefixes -- so
# matching that half, or an alternation of the two, would accept a refusal that is not the one
# asserted.
#
# NOT assert_says, DELIBERATELY. _flatten exists for box art, which podman errors do not have, and
# folding $rc into the haystack to get it into the diagnostic would let a phrase match the prefix
# rather than the output. The case below keeps the haystack exactly as the command emitted it.
assert_fail_saying() {                # assert_fail_saying NAME PHRASE CMD...
    local n="$1" want="$2"; shift 2
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        fail "$n" "expected it to fail saying: $want
but it succeeded: $*
$out"
        return 0
    fi
    case "$out" in
        *"$want"*) pass "$n" ;;
        *) fail "$n" "exit $rc, but it does not say: $want
so it failed for some other reason than the one asserted: $*
$out" ;;
    esac
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
    run_checker python3 -c '
import sys
# DECODED THE WAY render_pty decodes, and for the same reason: this reads a pty transcript, a
# stray byte in one is ordinary, and `sys.stdin.read()` raised UnicodeDecodeError on it -- which
# left the caller holding the empty string and passing.
lines = sys.stdin.buffer.read().decode("utf-8", "replace").splitlines()
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
# Replays the six things this launcher actually emits: \r (column 0), \n (new line), ESC[K
# (erase to end of line), ESC[J (erase to end of SCREEN) and ESC[nA / ESC[nB (cursor up and
# down). Other CSI sequences are colour and are dropped.
#
# THE CURSOR MOVES ARE NOT OPTIONAL TO MODEL, and getting this wrong fails in the reassuring
# direction. The progress meter is a two-row block that redraws by stepping back up to its
# first row, so a replayer that dropped ESC[1A -- as this one did while the meter was one
# line -- would replay every frame as a fresh pair of rows and then report a screen full of
# bars that no student ever saw. Every screen assertion in 30-launcher-shim.sh would go on
# passing against it.
#
# ESC[J IS THE SAME HAZARD IN THE SAME DIRECTION. It is how the build's output box is taken off
# the screen -- on success, on failure, and whenever a resize makes the block shorter -- so a
# replayer that dropped it would keep every row the launcher had just erased and report a screen
# with a box on it that a student never sees. An assertion that the box is GONE by the end would
# fail loudly, which is the good case; one that counts the boxes on screen would simply lie.
#
# So rows stay ADDRESSABLE rather than append-only: the cursor is (row, col), and writing to
# a row that has already been written overwrites it, which is what a terminal does.
render_pty() {                        # raw transcript on stdin -> one repr()'d line per row
    run_checker python3 -c '
import re, sys
raw = sys.stdin.buffer.read().decode("utf-8", "replace")
# Mark the sequences with meaning so they survive colour-stripping, then drop the rest. The
# count in ESC[nA defaults to 1 when omitted, which is the form the meter emits.
raw = raw.replace("\x1b[K", "\x00")
raw = re.sub(r"\x1b\[([0-9]*)A", lambda m: "\x01" * max(1, int(m.group(1) or 1)), raw)
raw = re.sub(r"\x1b\[([0-9]*)B", lambda m: "\x02" * max(1, int(m.group(1) or 1)), raw)
# ESC[J and ESC[0J are the same thing, erase-to-end-of-screen, and the launcher emits the short
# form. The other parameters (1J, 2J) are not emitted and deliberately fall through to be
# dropped, so that a future one cannot be silently modelled as the wrong thing.
raw = re.sub(r"\x1b\[0?J", "\x03", raw)
# The `?` is for PRIVATE-MODE sequences, and it is load-bearing: the meter hides the cursor
# with ESC[?25l and restores it with ESC[?25h, and without `?` in this class neither matches --
# so both would survive into the "rendered screen" as literal garbage and break assertions
# about rows the student sees as clean. Same failure shape as the cursor moves above.
raw = re.sub(r"\x1b\[[?0-9;]*[A-Za-z]", "", raw)
rows, row, col = [[]], 0, 0
def at(r):
    while len(rows) <= r: rows.append([])
    return rows[r]
for ch in raw:
    if ch == "\n":
        # Column 0 as well as the next row: the pty is in cooked mode, so ONLCR turns this
        # into CRLF on the way out. The launcher pairs it with \r anyway.
        row += 1; col = 0; at(row)
    elif ch == "\r":
        col = 0
    elif ch == "\x01":                 # ESC[nA -- up, never past the top of the transcript
        row = max(0, row - 1)
    elif ch == "\x02":                 # ESC[nB -- down
        row += 1; at(row)
    elif ch == "\x00":                 # ESC[K -- erase from the cursor to end of line
        del at(row)[col:]
    elif ch == "\x03":                 # ESC[J -- erase from the cursor to end of screen
        del at(row)[col:]
        del rows[row + 1:]
    else:
        cur = at(row)
        while len(cur) < col: cur.append(" ")
        if col < len(cur): cur[col] = ch
        else: cur.append(ch)
        col += 1
for r in rows:
    print("".join(r).rstrip())
'
}

# ─── machine-global podman state, narrowed to this run (#199) ──────────────────
# `podman images` and `podman volume ls` answer for the whole COMPUTER, and several people
# develop this container on one machine (CLAUDE.md). CS193V_INSTANCE suffixes the container
# name, the dev image tag and the seven volumes; it cannot suffix the list. So the install
# tier's host canaries used to cksum a 66-row listing spread across nine instances, and a
# colleague's `./cs193v --rebuild` landing inside the 575 s fedora-e2e window reddened a case
# that behaved perfectly (#199). Same bug as #74, one resource over: an assertion's verdict
# may not depend on another checkout's activity.
#
# HERE RATHER THAN IN lib/sandbox.sh, although only the install tier reads them: they are pure
# text filters, and this is where the other pure checkers live (box_problems, render_pty). It
# is also what lets 14-test-harness.sh test them against synthetic rows in the unit tier, with
# no podman and no second developer -- which is the whole point, since a filter that quietly
# dropped everything would leave the canaries passing forever.
#
# THE INSTANCE IS AN ARGUMENT, defaulting to the environment. The suites call it bare; the
# self-test forces it, because with CS193V_INSTANCE unset -- a TA's machine -- a test written
# against whatever the environment holds would hold while saying nothing (16-args-parse.sh:328).

# Rows of `{{.Repository}}:{{.Tag}} {{.ID}} {{index .Labels "cs193v.test"}}` on stdin.
host_image_rows() {                   # host_image_rows [INSTANCE] -> the rows that could be ours
    local inst="${1-${CS193V_INSTANCE:-}}"
    awk -v inst="$inst" -v name="cs193v${inst:+-$inst}" '
        { ref = $1; owner = $3
          tag = ref; sub(/^.*:/, "", tag)

          # NO REPOSITORY AND NO TAG: a dangling layer, which every concurrent build and every
          # `podman image prune` on this machine adds or removes. There is nothing in it to
          # attribute to anybody. A row that is merely UNTAGGED is kept, deliberately -- a
          # digest-pinned FROM records no tag, so repo:<none> is how a base image pulled onto
          # the HOST would arrive, and that is a leak worth catching.
          if (ref == "<none>:<none>") next

          # A FIXTURE IMAGE LABELLED FOR ANOTHER INSTANCE, whatever it is tagged. fixture_build
          # stamps cs193v.test=$NAME on every one (lib/sandbox.sh), so this needs no guess about
          # how a colleague spells their instance -- and, the half a tag test cannot do, a stray
          # tag of OURS that merely looks like a colleague carries no such label and stays.
          if (owner != "" && owner != name) next

          # Dev images carry cs193v.buildhash and no test label, so they are placed by tag.
          # EXACT EQUALITY, NOT A PREFIX: local-htiek and local-htiek-dev3 are both real
          # instances, and a prefix test adopts one as the other.
          if (ref ~ /^localhost\/cs193v:local-/ && tag != "local-" inst) next

          # $0, not "$1 $2": the label field is part of the row, so a fixture image that changed
          # hands would show up, and reprinting two fields would silently normalise it away.
          # The trailing space podman leaves where the label is empty is stripped, so the rows a
          # failure names are the rows 14-test-harness.sh tests against.
          sub(/[[:space:]]+$/, ""); print }'
}

# Volume names on stdin. Volumes cannot be labelled -- the launcher creates them implicitly with
# `-v name:path`, so there is no flag of ours to hang one on, the same constraint
# 80-launcher-live.sh records for its stray check. The seven names are known, so the instance is
# whatever sits between the family prefix and one of them; a family name with no instance in it
# (the bare cs193v-claude the launcher makes with no instance set) is the LEAK target and stays.
host_volume_rows() {                  # host_volume_rows [INSTANCE] -> the names that could be ours
    local inst="${1-${CS193V_INSTANCE:-}}"
    awk -v inst="$inst" -v v7='claude|claude-json|codex|gh|git|playwright|vercel' '
        { mid = $0
          if (match(mid, "^cs193v-.+-(" v7 ")$")) {
              sub(/^cs193v-/, "", mid)
              sub("-(" v7 ")$", "", mid)
              if (mid != inst) next
          }
          print }'
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

# python3 GETS ITS OWN DOOR, and require_cmd is deliberately left exactly as it is: it is shared
# with podman, shellcheck, curl and script, and a smoke test for those belongs at their own doors.
#
# WHY A SMOKE TEST AT ALL. run_checker catches the interpreter that DIES; nothing in a `command
# -v` catches the one that answers every program with the wrong thing, and #79's sabotage run
# found its 26 vacuous passes with an interpreter that existed. Comparing output is the only
# question a poisoned interpreter cannot pass, because it exits 0.
#
# CALL IT ABOVE THE FIRST PRODUCER, not beside the assertion that reads one: 20-messages.sh
# called `require_cmd python3` 172 lines below the catalogue width lint that already needed it.
require_python3() {
    require_cmd python3 "Run: sudo apt install -y python3"
    [ "$(python3 -c 'print(1)' 2>/dev/null)" = 1 ] && return 0
    fail "require:python3" "python3 is on \$PATH but does not run a program:
\`python3 -c 'print(1)'\` printed something other than 1.
Every box-art and pty-replay check here is measured with it, and several read the empty string as
their happy answer -- so carrying on would pass them without measuring anything."
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

# ─── the tunnel, and the ports it is carrying right now ────────────────────────
# THERE IS NO LIST TO READ ANY MORE, and that is the change this whole layer absorbed. Ports are
# not declared anywhere: the launcher's supervisor watches what the container is listening on and
# opens the matching host port as it appears. So the question "is the tunnel working" stopped
# having a config-derived answer -- there is no expected COUNT, because the right number of
# forwards is itself runtime state.
#
# WHICH MEANS A SUITE MUST ESTABLISH THE CONDITION IT TESTS RATHER THAN READ IT. `fwd_init` used
# to expand $CS193V_PORTS and hard-fail if it named fewer than two ports; its replacement is
# `dyn_ports`, which BINDS ports inside the container and hard-fails if the tunnel does not carry
# them. A fixture, not a reader -- and strictly stronger, because the old check could pass on a
# well-formed list while nothing was forwarded at all.
#
# WHAT STAYED is the identity half (issue #46): `cs193v --dev-tunnel` still prints the paths that
# name THIS instance's tunnel, because "is this listener mine" has no other cheap answer and a
# colleague's checkout is otherwise indistinguishable.
#
# LAZY AND CACHED. The cheap lane (static, unit, shim) sources this file too and must not pay a
# launcher fork it never uses -- the same cost concern as #57, one layer out.
FWD_CTL='' FWD_PIDFILE='' FWD_BUILDLOG='' FWD_SUPPID='' FWD_SUPLOG='' FWD_READY=''
fwd_init() {
    [ -n "$FWD_READY" ] && return 0
    FWD_READY=1
    local out
    out="$("$REPO/cs193v" --dev-tunnel 2>/dev/null)" || true
    FWD_CTL="$(printf '%s\n' "$out"     | awk -F'\t' '$1 == "ctl"  { print $2 }')"
    FWD_PIDFILE="$(printf '%s\n' "$out" | awk -F'\t' '$1 == "pid"  { print $2 }')"
    # NOT a tunnel file, and read from the same seam for the same reason: it is keyed by TUNNEL_ID,
    # so only the launcher can name this instance's build log. 00-release-gates.sh globbed TMPDIR
    # for the newest cs193v-build-*.log instead, and diffed a colleague's build against our
    # Containerfile whenever theirs finished last (#74).
    FWD_BUILDLOG="$(printf '%s\n' "$out" | awk -F'\t' '$1 == "buildlog" { print $2 }')"
    FWD_SUPPID="$(printf '%s\n' "$out"   | awk -F'\t' '$1 == "suppid" { print $2 }')"
    FWD_SUPLOG="$(printf '%s\n' "$out"   | awk -F'\t' '$1 == "suplog" { print $2 }')"
    export FWD_CTL FWD_PIDFILE FWD_BUILDLOG FWD_SUPPID FWD_SUPLOG
}

# ─── establishing a forwarded port ─────────────────────────────────────────────
# A PORT NOTHING HAS SPOKEN FOR, picked from 1024-32767. Two exclusions, and the second is easy to
# miss: below 1024 an unprivileged bind is EPERM on both sides, and INSIDE ip_local_port_range a
# bind can lose a race with an outbound socket that already holds the number -- `ss -Hltn` cannot
# see those, because they are ESTABLISHED rather than LISTEN, so the port looks free and then is
# not. Nothing listens in the ephemeral range in practice, which is exactly why the flake is rare
# enough to be mystifying. Purely a test concern: the classifier forwards ephemeral ports fine,
# and shortlink deliberately uses them.
dyn_free_port() {                     # dyn_free_port [AVOID...] -> one port, or nothing
    local lo hi p elo avoid=" $* "
    lo=1024; hi=32767
    if [ -r /proc/sys/net/ipv4/ip_local_port_range ]; then
        read -r elo _ < /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || elo=32768
        [ "${elo:-32768}" -gt 1024 ] && hi=$((elo - 1))
    fi
    # TWO PASSES, STARTING HIGH. Scanning up from 1024 handed out 1024, 1025, 1026 -- legal, and a
    # bad neighbour: those are where a developer's own odds and ends sit, and a test port that
    # looks like a system port is one nobody can identify in an `ss` dump at three in the morning.
    # 20000+ is empty in practice and unmistakably ours. The low range stays as a fallback so a
    # busy machine degrades rather than failing to find anything.
    #
    # AND THIS IS NOW THE MULTI-DEVELOPER STORY, which used to need a declared band per checkout:
    # if another instance is already using a port, something is LISTENING on it, so the scan steps
    # over it. Two suites running side by side pick disjoint ports without being told to.
    for lo in 20000 1024; do
        p="$lo"
        while [ "$p" -le "$hi" ]; do
            case "$avoid" in *" $p "*) p=$((p + 1)); continue ;; esac
            if ! do_listeners 2>/dev/null | grep -qE "[:.]$p	"; then
                printf '%s' "$p"; return 0
            fi
            p=$((p + 1))
        done
    done
    return 1
}

# Start a listener on the container's OWN loopback and leave it running. 127.0.0.1 and not
# 0.0.0.0: the tunnel's far end is the container's IPv4 loopback, and `lo` is the class the
# supervisor forwards, so this is what a student's dev server looks like to it.
dyn_serve() {                         # dyn_serve PORT
    podman exec -d "$NAME" python3 -m http.server "$1" --bind 127.0.0.1 >/dev/null 2>&1
}
dyn_serve_stop() { container_pkill "http.server" >/dev/null 2>&1 || true; }

# Is OUR master holding this host port?
dyn_is_forwarded() { fwd_owned_ports | grep -qx "$1"; }

# THE FIXTURE. Bind N ports inside the container, wait for the tunnel to carry them, and leave
# them in $DYN_PORTS. This is what replaced reading a declared list, and the hard-fail is the same
# project decision as require_image and the old require:ports: a suite that quietly carried on
# with no forwarded port would test nothing and say so nowhere -- the failure 1937a30 (#79) was
# about.
#
# A STATEMENT, AND THE PORTS COME BACK IN A VARIABLE. That is not a style choice: it is what the
# `exit` below depends on, and the reason it is spelled this way is #164. The one call site used
# to be `DYN2="$(dyn_ports 2)"`, so the exit ended the SUBSHELL, 60-container.sh carried on past
# a tunnel carrying nothing, and it recorded `PASS ports:a-port-bound-inside-reaches-the-host`
# and `PASS ports:no-forward-is-lan-exposed` -- the security property, filtering on an empty pid
# that matched nothing. fail's detail goes to stdout, so the `$( )` swallowed the two commands
# that fix a dead tunnel as well and flattened them into a REC line.
#
# So there is deliberately NOTHING ON STDOUT to substitute: a fixture with no value cannot be
# wrapped in a `$( )` that looks like it works. 10-static.sh's
# harness:no-exiting-helper-runs-in-a-subshell keeps every other call site honest, and
# lib/assert.sh:57-58 is the invariant both of them serve.
DYN_PORTS=''
dyn_ports() {                         # dyn_ports [N] -> $DYN_PORTS, N forwarded ports, spaced
    local want="${1:-1}" got='' p i=0
    [ -n "$DYN_PORTS" ] && return 0
    fwd_init
    while [ "$i" -lt "$want" ]; do
        p="$(dyn_free_port $got)" || break
        dyn_serve "$p"
        got="$got $p"
        i=$((i + 1))
    done
    got="${got# }"
    for p in $got; do
        wait_until 30 dyn_is_forwarded "$p" && continue
        fail "require:dynports" "bound 127.0.0.1:$p inside the container, and the tunnel never
carried it to this host. Every port assertion in this suite establishes its ports this way, so
there is nothing left to test.
  the tunnel holds: $(fwd_owned_ports | do_tr '\n' ' ')
  the container says:
$(podman exec "$NAME" cat /tmp/cs193v/ports 2>&1 | sed 's/^/    /')
Check:  ./cs193v doctor
        ./cs193v --reset-tunnel"
        exit 1
    done
    DYN_PORTS="$got"
    export DYN_PORTS
}

# A host port that nothing is listening on RIGHT NOW. Two suites need one and neither can name it:
# 60-container.sh probes "a port nothing is bound to inside is refused", and 80-launcher-live.sh
# asks the tunnel for a forward it must decline and then asserts nothing is listening.
#
# THE HARD PART OF THIS USED TO BE THE OTHER INSTANCE, and dynamic forwarding dissolved it. The old
# version had to exclude our own declared set AND hope a colleague's tunnel was not carrying the
# number, because a port ANOTHER instance forwards answers from the host and comes back 200 with
# nothing wrong here -- an uncomputable exclusion, since it depended on a list this checkout could
# not see. Now a port another instance forwards is a port something is LISTENING on, so the one
# check below covers both cases and covers them exactly.
#
# Ports, not one port, because a caller may need two distinct ones. Returns fewer than asked if the
# pool runs dry; every caller checks and says so rather than testing nothing.
free_unforwarded_ports() {            # free_unforwarded_ports N -> up to N ports, space separated
    local want="${1:-1}" out='' n=0 p
    while [ "$n" -lt "$want" ]; do
        p="$(dyn_free_port $out)" || break
        out="$out $p"
        n=$((n + 1))
    done
    printf '%s' "${out# }"
}

# WHICH ssh MASTER IS OURS, and this is the other half of #46. count_forwards used to count any
# listener on the default ports with no notion of an owner, and require_tunnel greenlit the whole
# container tier the moment that count reached 46 -- so with a colleague's checkout holding the
# default list and the instance under test forwarding on 13000+, four assertions passed and
# `sighup:forwards-while-a-session-is-open` recorded "46 of 46" while this instance held none of
# them. Same shape as #34: a port assertion passing without this run having bound anything.
#
# THE IDENTITY TEST IS THE LAUNCHER'S OWN, copied rather than approximated: tunnel_kill_pid kills
# the pid in the pidfile only if our control socket is on its command line, because pids are
# reused and that file outlives the process it names. Nothing else distinguishes our master from
# another checkout's -- both are `ssh` run by this user with 46 -L flags.
#
# THE PIDFILE RATHER THAN `cs193v doctor`, which also knows: doctor costs a `podman info`, 536-1222
# ms of it (ERRORS.md D11). It is also strictly more capable -- doctor's line is gated on
# tunnel_alive, so it goes quiet exactly when a master is wedged, which is the case two live-tier
# assertions deliberately create.
#
# WHAT THIS ANSWERS, AND WHAT IT DOES NOT (#159). "Which master does the launcher think it owns" is
# the right question for the things that KILL one -- release_tunnel, the two `kill -STOP` wedges,
# require_tunnel -- because you may not signal a pid you merely inferred. It is the WRONG question
# for a measurement taken AFTER a teardown, because `tunnel_down` ends by deleting the very file it
# reads (cs193v:2113). Measuring is fwd_master_pids' job, below.
tunnel_owner_pid() {                  # -> the pid the LAUNCHER records as its master, or nothing
    fwd_init
    fwd_require_ctl
    local pid
    pid="$(cat "$FWD_PIDFILE" 2>/dev/null)"
    case "${pid:-}" in ''|*[!0-9]*) return 0 ;; esac
    case "$(ps -p "$pid" -wwo args= 2>/dev/null)" in
        *"$FWD_CTL"*) printf '%s' "$pid" ;;
    esac
}

# AN UNIDENTIFIABLE TUNNEL IS FATAL, NEVER EMPTY, and the two readers above and below need it for
# opposite reasons. `case ... in *""*)` matches EVERY argv, so an empty needle makes the pidfile
# reader believe any live pid it finds; `index($0, "")` matches every LINE, so it makes the process
# scanner claim strangers -- or, taken as the launcher's own `awk 'NR == 1'`, exactly pid 1, which
# holds no loopback listener and so answers a silent ZERO. Measured, both directions. fwd_init
# cannot be relied on to have succeeded: it sets FWD_READY before the launcher call and swallows
# the rc, so one failed `--dev-tunnel` caches empty paths for the whole suite process. Same
# discipline as do_listeners' missing backend: refuse to answer rather than answer wrongly.
fwd_require_ctl() {
    [ -n "$FWD_CTL" ] || _pt_fatal dev-tunnel \
        'cs193v --dev-tunnel named no control socket, so no listener can be identified as ours'
}

# IS OUR SUPERVISOR RUNNING? Same identity discipline as tunnel_owner_pid and for the same reason:
# the pidfile outlives the process it names and pids are reused, so the pid is only believed when
# the process wearing it is still running this launcher's supervisor verb.
sup_owner_alive() {
    fwd_init
    local pid
    pid="$(cat "$FWD_SUPPID" 2>/dev/null)"
    case "${pid:-}" in ''|*[!0-9]*) return 1 ;; esac
    case "$(ps -p "$pid" -wwo args= 2>/dev/null)" in *--dev-supervise*) return 0 ;; esac
    return 1
}

# WHICH OF OUR MASTERS EXIST, asked of the process table rather than the pidfile (#159).
#
# THE PIDFILE IS THE WRONG SUBJECT FOR THIS QUESTION, and it took three goes to see it. Read that
# way, "have the forwards been released" answered 0 -- and therefore TRUE -- once `tunnel_down`
# reached its final `rm -f "$TUNNEL_CTL" "$TUNNEL_PID"` (cs193v:2113), whatever was still bound.
# Six assertions poll that predicate, and one of them, sighup:closing-the-window-releases-the-
# forwarded-ports, was being read as the discriminator between #140 and #150 while it was
# incapable of failing. Measured with a live master holding 127.0.0.1:49954: pidfile present -> 1,
# pidfile removed -> 0 and `wait_until 30 no_forwards` passing in 0 s with the port still in
# do_listeners. Read that way it also answered 0 for an EMPTY pidfile, a DEAD pid and a REUSED
# pid -- four ways to say "released" without looking.
#
# THE SCAN IS THE LAUNCHER'S OWN, copied rather than approximated, exactly as the identity test
# above is: tunnel_record_pid finds its master with `ps -Ao pid=,args= | grep -F "$TUNNEL_CTL"`
# (cs193v:1725), under a comment calling that "THE IDENTITY TEST tunnel_kill_pid ALREADY TRUSTS".
# A colleague's checkout hashes a different TUNNEL_ID and so a different control socket, which is
# what keeps #46 fixed; harness:count_forwards-ignores-another-checkouts-tunnel is its fixture.
#
# -ww IS LOAD-BEARING, NOT TIDINESS. procps truncates a PIPED `ps -o args=` to $COLUMNS -- 80 by
# default -- and drops the ctl path off the end of the line. Measured, procps-ng 4.0.6:
#   COLUMNS=80 ps -Ao pid=,args= -> 0 hits        ps -Awwo pid=,args= -> 3 hits
# macOS BSD ps does not truncate at any width (530 bytes of real ssh argv verified), so this is
# invisible from a Mac and would have reintroduced the silent zero on Linux -- the fix reproducing
# the bug. The same two characters are owed at cs193v:1725, :1981, :2034 and :2079, where the
# launcher can otherwise fail to find, and therefore fail to KILL, its own wedged master.
#
# THE NEEDLE TRAVELS IN THE ENVIRONMENT, not in argv, so this pipeline cannot match itself and
# needs no equivalent of the launcher's `grep -v ' grep '`.
fwd_master_pids() {                   # -> every live pid whose argv names OUR control socket
    fwd_init
    fwd_require_ctl
    # AND A ps THAT LISTED NOTHING IS FATAL TOO, for the reason this whole function exists: an
    # empty answer here is indistinguishable from "no master of ours is running", which is the
    # happy answer. `ps` is not a tool that can be missing the way `ss` was, so this is insurance
    # rather than a scenario -- but an unguarded silent zero is what #159 was.
    ps -Awwo pid=,args= 2>/dev/null \
        | FWD_CTL="$FWD_CTL" do_awk 'BEGIN { c = ENVIRON["FWD_CTL"] }
                                     index($0, c) { print $1 }
                                     END { if (NR == 0) exit 3 }' \
      || _pt_fatal ps 'ps -A listed no processes, so no tunnel of ours can be identified'
}

# Every host port one of OUR masters is listening on, one per line. `ss -ltnp` and `lsof` yield the
# listening pid for this user's own sockets, which is what makes the ownership filter possible at
# all -- ports:one-ssh-process-carries-them-all has relied on that since the tunnel landed.
#
# NO EXPECTED SET TO MATCH AGAINST, so the address pattern is the invariant instead: every forward
# this launcher makes binds 127.0.0.1 and nothing else, which is the security property three
# assertions rest on. A master listening anywhere else shows up here rather than being filtered out
# of view, which is the right way round -- 60-container.sh:150 inverts this filter deliberately.
fwd_owned_ports() {
    local pids
    pids="$(fwd_master_pids)"
    # No process of ours exists, so it holds no ports. A zero DERIVED from a measurement, unlike
    # the zero this returned when it could not work out whom to ask.
    [ -n "$pids" ] || return 0
    # do_listeners, not ss: macOS has neither ss nor any netstat that can report a pid, and the
    # old `ss ... 2>/dev/null` yielded EMPTY there -- so count_forwards was 0, no_forwards() was
    # unconditionally TRUE, and every "the forwards were released" assertion passed having
    # measured nothing. A missing backend is now fatal rather than silent. Its format is
    # ADDR:PORT<TAB>pid=NNN; see lib/portable.sh.
    #
    # AN AWK SET, and `p != ""` is not belt-and-braces. do_listeners emits `pid=` with an EMPTY
    # field for a socket owned by another account (portable.sh:151), and a substring membership
    # test -- index(" $pids ", " " p " ") -- matches the empty string against it and so reports
    # ANOTHER USER'S loopback listeners as forwards of ours. Measured.
    do_listeners | FWD_PIDS="$pids" do_awk -F'\t' '
        BEGIN { n = split(ENVIRON["FWD_PIDS"], a, "\n")
                for (i = 1; i <= n; i++) if (a[i] != "") ours[a[i]] }
        $1 ~ /^127[.]0[.]0[.]1:[0-9]+$/ {
            p = $2; sub(/^pid=/, "", p)
            if (p != "" && (p in ours)) { sub(/.*:/, "", $1); print $1 }
        }' | LC_ALL=C sort -u
}

# grep -c prints 0 AND exits 1 on no match, the trap documented for it elsewhere in this file.
count_forwards() {
    local n
    n="$(fwd_owned_ports | grep -c '[0-9]')" || true
    printf '%s' "${n:-0}"
}

# "The ports have gone back", as a predicate rather than a sample, because ssh does not unbind
# instantly and a bare check right after a teardown is a flake that reads as a leak. Lives here
# beside the port list for the same reason that does: #41 made every teardown release the
# forwards, so three suites were about to define this, and two of them already had.
#
# It now means OUR tunnel holds none, which is the question every caller was actually asking. Read
# the old way, `live:a-finished-session-releases-the-ports` failed on a neighbour's ssh process.
no_forwards() { [ "$(count_forwards)" = 0 ]; }

# Who is listening on a port, named as specifically as the kernel will let us. It used to be fed by
# fwd_missing_ports -- "the ports we expect that our master is not holding" -- which no longer
# means anything, because nothing is expected: a port is forwarded when something inside the
# container is listening on it and not otherwise. Callers name the port they care about instead. `ss -ltnp` shows a pid only for this user's own sockets, so "no pid visible" is itself
# informative: it means another account on this machine, not another checkout of ours.
fwd_squatters() {                     # fwd_squatters PORT...  -> one line per port
    local n=0 p line pid who
    for p in "$@"; do
        line="$(do_listeners | do_awk -F'\t' -v a=":$p\$" '$1 ~ a { print; exit }')"
        if [ -z "$line" ]; then
            who='nothing is listening on it -- our own tunnel never bound it'
        else
            pid="$(printf '%s' "$line" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p')"
            if [ -n "$pid" ]; then
                # The -i path names the CHECKOUT that owns it, which is exactly what CLAUDE.md
                # tells a human to go and read off this line by hand. Taken as the word after the
                # FIRST -i, not with a `.*-i ` sed: the tunnel's own ProxyCommand ends in
                # `sshd -i -f <config>`, so a greedy match reports "-f" and names nothing.
                who="$(ps -p "$pid" -wwo args= 2>/dev/null \
                       | do_tr ' ' '\n' | awk '$0 == "-i" { getline; print; exit }')"
                who="pid $pid  ${who:-$(ps -p "$pid" -o comm= 2>/dev/null)}"
            else
                who="another user's process (no pid visible to us)"
            fi
        fi
        printf '  %-6s %s\n' "$p" "$who"
        n=$((n + 1))
    done
}

# The container tier reaches the container's own loopback THROUGH the tunnel, so it needs its
# forwards up before it asserts anything about ports.
#
# It cannot assume they are: 80-launcher-live.sh now releases the tunnel when it finishes, on
# purpose, so that a completed run does not sit on ports another developer's run needs. The
# cost of that is exactly here -- a second run arrives with the container still up and no
# tunnel -- and paying it with the launcher's own verb is better than leaving a developer to
# discover it from a wall of red port assertions.
#
# WHAT IT CHECKS CHANGED WITH THE MECHANISM. It used to compare a live count against $FWD_N, a
# config-derived expected value -- so a broken tunnel was a numeric mismatch with a specific
# message. There is no expected count now: zero forwards is the CORRECT state for a container
# with nothing listening in it. So the two things that must be true are that our master is alive
# and that a supervisor is driving it; whether any given port is carried is established per-suite
# by dyn_ports, which hard-fails on its own.
#
# HARD-FAILS if they still do not come up, by the same project decision as require_image: a green
# run must mean the whole thing really ran.
require_tunnel() {
    fwd_init
    tunnel_ready() { [ -n "$(tunnel_owner_pid)" ] && sup_owner_alive; }
    tunnel_ready && return 0
    # The container has to be up first, or --reset-tunnel correctly declines with
    # warn.tunnel-reset-not-running and this fails with a message about port squatting that names
    # entirely the wrong cause. Since #41 a stopped container is the NORMAL resting state, so
    # this is the common path here rather than an edge case. See hold_container.
    hold_container
    ( cd "$REPO" && printf 'exit\n' | do_timeout 90 ./cs193v --reset-tunnel ) >/dev/null 2>&1 || true
    tunnel_ready && return 0
    local mpid; mpid="$(tunnel_owner_pid)"
    fail "require:tunnel" "this instance has no working tunnel, and --reset-tunnel did not fix it.
  ssh master:  ${mpid:-none of ours is running}
  supervisor:  $(sup_owner_alive && echo running || echo 'not running')
Without both, no port bound inside the container becomes reachable from this host, so every port
assertion below would be measuring nothing.
Check:  ./cs193v doctor
        $FWD_SUPLOG"
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
export CS193V_TITLE CS193V_WELCOME

# ─── userland portability ──────────────────────────────────────────────────────
# UNCONDITIONALLY, unlike the strings file above: that one is a convenience and degrades to a
# weaker assertion if absent, whereas every tier here calls do_tr, do_timeout or do_stat and a
# missing portable.sh would be `command not found` in the middle of a suite rather than a
# diagnosis. See that file's header for why PATH is not simply changed instead.
# shellcheck source=portable.sh
. "$TESTS_DIR/lib/portable.sh"

# ─── definitions more than one place needs ─────────────────────────────────────
# NOT guarded with `[ -r ] &&` the way the strings above are, and the difference is deliberate:
# a missing strings file costs three assertions their needle, while a missing shared.sh leaves
# msg_of and carve_func undefined -- and 20-messages.sh, 30-launcher-shim.sh, 10-static.sh and
# 25-installer.sh each build assertions on one of them. Sourced unconditionally so the failure
# is a loud one here rather than a `set -u` abort three files away with nothing saying which
# file was absent.
# shellcheck source=shared.sh
. "$TESTS_DIR/lib/shared.sh" || {
    printf 'assert.sh: cannot read %s\n' "$TESTS_DIR/lib/shared.sh" >&2
    exit 1
}

# ─── OUR OWN THROWAWAY CONTAINERS ──────────────────────────────────────────────
# `podman run --rm` with no --name gets a podman-generated one (`nervous_bohr`), and a generated
# name is indistinguishable from a colleague's. 80-launcher-live.sh counted every container on the
# machine that was not named cs193v-something as a stray of OURS, so a neighbouring checkout
# running the image tier reddened seven live assertions at once -- four idempotency counts, two
# leak counts and cleanup:no-stray-containers (#74). Parallel development on one machine is the
# documented workflow (CLAUDE.md), so the suite has to be able to ignore work that is not its own.
#
# THE LABEL IS THE DISCRIMINATOR, because it is the one thing about a generated container we
# control. It carries $NAME rather than a bare marker, so two instances on one machine can tell
# their throwaways apart as well -- which is what lets the stray check stay a LEAK check instead of
# becoming a machine-wide sweep: a throwaway of ours that outlived its --rm still shows up.
#
# A VARIABLE, NOT A FUNCTION, and that is not a preference. Most of the call sites are a
# `podman run` written inside an `sh -c "..."` string for assert_ok, where a bash function would
# not exist -- but $VT_RUN expands before sh is ever started. 10-static.sh enforces that every
# `podman run` in the suites that drive real podman goes through it, because one written without
# the label would reopen the hole invisibly: the container lives for seconds and only ever reddens
# somebody else's run.
VT_LABEL="cs193v.test=$NAME"
VT_RUN="podman run --label $VT_LABEL"
export VT_LABEL VT_RUN

# In-container and throwaway-container runners, matching VERIFICATION.md's E() and R().
E() { podman exec "$NAME" sh -c "$1" 2>&1; }
# $VT_RUN unquoted, deliberately: it is a command PREFIX and has to word-split.
R() { $VT_RUN --rm --entrypoint sh "${TEST_IMAGE:-$TEST_IMAGE_DEFAULT}" -c "$1" 2>&1; }
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

# ─── what a student actually unpacks ───────────────────────────────────────────
# export_tree DST      -> the file set a student downloads, materialised at DST.
# would_ship_paths     -> the same, plus untracked files, as a sorted list of names.
#
# THIS IS `git archive`, NOT A COPY WITH EXCLUSIONS, and that is the whole point. GitHub builds
# its tarballs with `git archive`, which honours .gitattributes' export-ignore -- so the only
# fixture that cannot disagree with what a student receives is one git builds. The hand-written
# exclusion list this replaced had already drifted: it carried CLAUDE.md, which is export-ignored
# and has never been in the archive, and nothing noticed (#115).
#
# It also subsumes three things that list did by hand. .git, projects/* and .config/tunnel-* are
# all git-IGNORED, so the archive omits them by construction and the "exclude the directory, put
# its one tracked file back" dance goes away with them.
#
# FROM THE WORKING TREE, NOT HEAD. `git archive HEAD` would test committed code, so a red-first
# loop -- edit the launcher, run the suite, watch it fail -- would silently run the OLD launcher
# until you committed. Verified: an UNCOMMITTED .gitattributes edit is honoured here.
#
# ─── the two modes, and why they share one function ───────────────────────────
#
# `add -u` is the FIXTURE. An untracked file never reaches GitHub's archive, so putting one in a
# fixture would make it lie about what ships. Seeded from the REAL index rather than HEAD so a
# file you have `git add`ed is included.
#
# `add -A` is the GATE's second opinion: the same tree with untracked files folded in, i.e. what
# would ship if everything visible were committed. 11-export.sh subtracts the first from the
# second, and the difference is exactly the set of untracked paths that WOULD reach a student.
#
# ONE FUNCTION, TWO MODES, rather than two functions: the git plumbing below has three separate
# ways to be silently wrong (see the list) and two copies of it would eventually disagree about
# one of them -- which would make the gate's subtraction report a difference that is an artefact
# of the staging rather than a fact about the tree.
#
# THE SEED IS THE SAME FOR BOTH, deliberately, and that is why the gate checks ONE direction.
# With a HEAD seed for `add -A` the subtraction could invert -- a force-added ignored file is in
# the index but invisible to `add -A` -- so there would be a second, exotic difference to explain.
# Seeding both from the real index makes that direction structurally empty, so an assertion on it
# could not fail and has no business existing (#79).
#
# Four things that are easy to get wrong here, each measured rather than reasoned about:
#
#   * PIPEFAIL IS LOAD-BEARING. A failing `git archive` piped into `tar xf -` leaves rc 0 and an
#     empty destination -- measured, and the same trap install-cs193v.sh:1063 documents for its
#     own download. In a subshell, so it stays local to this one pipeline.
#   * `cd "$REPO"` FIRST, then use --git-path's answer verbatim. It is relative to the current
#     directory in an ordinary checkout (.git/index) and ABSOLUTE inside a linked worktree
#     (/.../.git/worktrees/NAME/index) -- both measured -- so "$REPO/$(...)" is wrong in a
#     worktree. The alternates path is made absolute for the same reason.
#   * THE ALTERNATES PATH IS READ BEFORE GIT_OBJECT_DIRECTORY IS EXPORTED. `--git-path objects`
#     answers with GIT_OBJECT_DIRECTORY when it is set, so asking afterwards would point the
#     alternates at themselves and lose every object the repo already has.
#   * ANYTHING THAT READS THE REAL INDEX must run with GIT_INDEX_FILE unset, or it reads the
#     empty temp one and the archive comes out empty. Copying the index file rather than
#     rebuilding it with plumbing avoids that class entirely.
#
# core.excludesFile=/dev/null on the `add -A` arm: it is the only arm that consults ignore rules
# for untracked paths, and a developer's GLOBAL excludes would otherwise shrink the gate's second
# opinion and make it more permissive on their machine than on anyone else's.
#
# The temp index and object store are a throwaway directory, so nothing here writes to the
# developer's repository -- verified: .git/objects and .git/index are byte-unchanged, and the new
# blobs land in $work/odb. It is named with the suite's pid and swept by shim_sweep_stale,
# because a trap does not run when the process is KILLED and that is ordinary here.
_stage_tree() {                       # _stage_tree u|A DST -> 0 on success
    local mode="$1" d="$2" work rc=0
    work="$(mktemp -d "${TMPDIR:-/tmp}/cs193v-exp.$$.XXXXXX")" || return 1
    mkdir -p "$d" "$work/odb" || { rm -rf "$work"; return 1; }
    (
        cd "$REPO" || exit 1
        alt="$(git rev-parse --git-path objects)" || exit 1
        case "$alt" in /*) ;; *) alt="$(pwd -P)/$alt" ;; esac
        cp "$(git rev-parse --git-path index)" "$work/index" || exit 1
        export GIT_INDEX_FILE="$work/index" \
               GIT_OBJECT_DIRECTORY="$work/odb" \
               GIT_ALTERNATE_OBJECT_DIRECTORIES="$alt"
        case "$mode" in
            u) git add -u || exit 1 ;;
            A) git -c core.excludesFile=/dev/null add -A . || exit 1 ;;
            *) exit 1 ;;
        esac
        tree="$(git write-tree)" || exit 1
        set -o pipefail
        git archive "$tree" | ( cd "$d" && tar xf - )
    ) || rc=1
    rm -rf "$work"
    return "$rc"
}

# The listing form, so an assertion can be an equality on names rather than a walk of a
# materialised copy. Same staging, so a listing and a fixture can never disagree.
_stage_paths() {                      # _stage_paths u|A -> one path per line, LC_ALL=C sorted
    local d rc=0
    d="$(mktemp -d "${TMPDIR:-/tmp}/cs193v-exp.$$.XXXXXX")" || return 1
    _stage_tree "$1" "$d" || rc=1
    [ "$rc" = 0 ] && ( cd "$d" && find . -type f | sed 's|^\./||' | LC_ALL=C sort )
    rm -rf "$d"
    return "$rc"
}

export_tree()      { _stage_tree  u "$1"; }
would_ship_paths() { _stage_paths A; }

# THE THREE FIXTURE-MAKING CALL SITES all use export_tree: repo_copy in lib/podman-shim.sh, the
# fake GitHub archive in 25-installer.sh, and the §2.7 second-copy group in 80-launcher-live.sh.
# They used to share a hand-written tar exclusion list, and the reason it is gone is worth
# keeping: it existed to leave out .git, .private/tests, the developer's own 57 MB projects/
# (#76) and the five .config/tunnel-* private keys -- and `git archive` leaves out all of them
# by construction, because every one is either untracked, git-ignored or export-ignored. The
# tunnel keys mattered most: tunnel_keys() guards each keygen with `[ -f ] ||`, so a copy
# arriving with a private key means the launcher's first-run keygen never runs in any test.

# What an EARLIER, KILLED run left in a scratch directory. Called at suite START as well as from
# an EXIT trap, for the reason 60-container.sh gives for its own two-ended cleanup (#34): a trap
# does not run when the process is killed, and a killed suite is ordinary here -- Ctrl+C, a
# --tier run cut short, run-tests.sh's own kill_tree.
#
# BY PID, NOT BY AGE, and that is the load-bearing part. This directory is SHARED: /tmp is one
# filesystem, CS193V_INSTANCE does not namespace it, and #76 was measured on a machine with two
# checkouts of this repo on it -- so another run of these same suites can have its own working
# directories sitting here right now. A blanket glob would delete one out from under it. Every
# name carries the pid of the suite that made it, so "is that suite still alive" is the whole
# test. A recycled pid leaves one directory behind, which the next sweep gets.
#
# TWO THINGS ARE DELIBERATELY LEFT ALONE. Another developer's directories, since `kill -0` cannot
# answer for a pid that is not ours; and a name with no pid in it, because there is nothing in it
# to ask a question of and a wrong guess deletes a running suite's scratch.
sweep_stale_tmpdirs() {               # sweep_stale_tmpdirs DIR PREFIX... -> how many it removed
    local dir="$1" p d base pid n=0
    shift
    for p in "$@"; do
        for d in "$dir/$p".*; do
            [ -d "$d" ] && [ -O "$d" ] || continue
            base="${d##*/}"; base="${base#*.}"; pid="${base%%.*}"
            case "$pid" in ''|*[!0-9]*) continue ;; esac
            kill -0 "$pid" 2>/dev/null && continue
            rm -rf "$d" 2>/dev/null && n=$((n + 1))
        done
    done
    printf '%s' "$n"
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

# ─── zombies, and whose they are ────────────────────────────────────────────────
# A ZOMBIE IS ITS PARENT'S BUSINESS, and that is the whole rule. The container holds three
# classes and only the ppid tells them apart:
#
#   ppid 1    PID 1's own. The reaping files/entrypoint.sh promises, and the only class a
#             `pid1:` assertion may count.
#   ppid >1   a live parent that is not PID 1 -- sshd's privsep monitor holds one for the
#             tunnel's whole life, and a payload shell holds its background children until it
#             exits. A process is reparented to PID 1 only when its parent DIES, so nothing
#             PID 1 could do would collect these. Neither could catatonit.
#   ppid 0    the parent is outside this PID namespace, i.e. conmon. EVERY `podman exec`
#             payload is one of these for the moment between _exit() and the host's wait(),
#             including the ones this suite is making while it looks.
#
# THIS REPLACES A `comm != "sshd"` EXCLUSION, which was a NAME standing in for the ppid rule
# and covered only the one member of the middle class anybody had met (#102). Under it a
# healthy container failed whenever the sample landed on somebody else's transient, which is a
# coin flip rather than a verdict -- and every process is a zombie for the interval between
# _exit() and its parent's wait(), so there is no sampling rate at which that stops.
#
# ONE `ps`, FILTERED ON THE HOST. #102's record and its assertion were two separate `podman
# exec`s that disagreed, so the number in the results described a different instant from the
# number in the failure and neither was legible. Everything below reads this one function.
zombie_inventory() {                  # one line per zombie: PPID PID COMM
    podman exec "$NAME" ps -eo ppid,pid,stat,comm --no-headers 2>/dev/null \
        | awk '$3 ~ /Z/ { print $1, $2, $4 }'
}

# `grep -c` prints 0 AND exits 1 when nothing matches, the trap documented all over this file.
count_pid1_zombies() {                # -> how many zombies PID 1 is answerable for
    local n
    n="$(zombie_inventory | awk '$1 == 1' | grep -c .)" || true
    printf '%s' "${n:-0}"
}

# WAITING FOR AN ABSENCE, WHICH wait_until OTHERWISE FORBIDS -- see its "WHAT IT MUST NOT BE
# USED FOR". That rule guards proofs that something HAPPENED, and neither predicate here is
# one: a leak is by definition a zombie that does NOT clear, so "already none" is the correct
# answer and there is nothing an early return could skip. What proves that reaping happens is
# positive, and it lives in 60-container.sh on orphans that suite makes and can name.
no_pid1_zombies() { [ "$(count_pid1_zombies)" = 0 ]; }

# Every zombie that was not already there. THE BASELINE IS WHAT MAKES THIS USABLE WHILE A
# TUNNEL IS UP: sshd's unreapable one is in it by pid, so it cannot be mistaken for something
# the caller caused, and no name has to be spelled out to excuse it.
zombie_pids() { zombie_inventory | awk '{ print $2 }' | LC_ALL=C sort -n; }
zombies_outside_baseline() {          # zombies_outside_baseline PID...  -> the newcomers
    local keep=" $* "
    zombie_inventory | while read -r zppid zpid zcomm; do
        case "$keep" in *" $zpid "*) continue ;; esac
        printf '%s %s %s\n' "$zppid" "$zpid" "$zcomm"
    done
}
no_new_zombies() { [ -z "$(zombies_outside_baseline "$@")" ]; }

# ─── orphans with names, for testing the reaper ─────────────────────────────────
# THE POINT IS OWNERSHIP. A count of the container's zombies asks about the tunnel, the port
# supervisor and this suite's own execs as much as about PID 1. Making the orphans means every
# check that follows names its own subject and cannot be perturbed by anything else.
#
# THE PAYLOAD SHELL IS THE PARENT, and that is the synchronisation. `podman exec` returns only
# once it has exited, so by the time this returns the kernel has already reparented every
# `sleep` onto PID 1 -- there is no window to poll for and no duration to guess at.
#
# EACH SLEEP GETS ITS OWN /dev/null. They would otherwise inherit the exec's stdout and hold
# that pipe open for the whole duration, which is the failure cs193v-portwatch's "no `sleep`
# fallback" note describes: the reader sees silence rather than EOF.
CS193V_ORPHAN_SLEEP=1793              # unmistakable in a `ps`, and narrow enough to pkill for
make_orphans() {                      # make_orphans N -> N pids, space separated
    podman exec "$NAME" sh -c \
        "i=0; while [ \$i -lt $1 ]; do sleep $CS193V_ORPHAN_SLEEP >/dev/null 2>&1 & \
         printf '%s ' \$!; i=\$((i + 1)); done" 2>/dev/null
}

# A comma list for `ps -p`, built with an UNQUOTED expansion so word splitting collapses the
# trailing space make_orphans leaves: `ps -p 1,2,` is an error.
# shellcheck disable=SC2086
_orphan_csv() { echo $1 | do_tr ' ' ','; }

orphan_ppids() {                      # orphan_ppids "PID PID ..." -> one ppid per line
    [ -n "${1:-}" ] || return 0
    podman exec "$NAME" ps -o ppid= -p "$(_orphan_csv "$1")" 2>/dev/null | do_tr -d ' '
}

# `ps -p` LISTS A ZOMBIE, which is what makes this mean "reaped" rather than "exited": an
# unreaped zombie stays in the table for the container's whole life, so these pids leaving it
# cannot happen any other way.
#
# AN EMPTY LIST IS NOT "GONE". `ps -p ""` prints nothing, and a caller whose make_orphans
# returned nothing would otherwise read that as success -- vacuous green through the one gap
# an absence check has.
orphans_gone() {                      # orphans_gone "PID PID ..."
    [ -n "${1:-}" ] || return 1
    [ -z "$(podman exec "$NAME" ps -o pid= -p "$(_orphan_csv "$1")" 2>/dev/null)" ]
}

# The process half of clean_vt_fixtures, and it exists for the same reason: an EXIT trap does
# not run on KILL, so a killed run leaves its servers listening and only start-up cleanup can
# get rid of them. What that costs is worse than a stray process -- a leftover listener on a
# forwarded port answers the NEXT run's request, so `ports:...-reach-a-loopback-bound-server`
# passed with nothing bound to loopback and `ports:not-reachable-from-the-LAN` passed with
# nothing exposed to the LAN (#34).
#
# One marker per thing the suites start, and every pattern is NARROW on purpose: a developer's own
# dev server in their own container is not this suite's to kill. `http.server ... --bind 127.0.0.1`
# is the exact form dyn_serve starts and nothing else does -- it used to be narrowed by naming the
# single port the suites shared, which no longer exists now that ports are established per run
# rather than declared. A student running `python3 -m http.server 3000` by hand has no --bind flag
# and is left alone.
#
# A no-op when the container is not running: podman exec fails, pkill matches nothing and
# container_pkill returns immediately. That is what lets 80-launcher-live.sh call it before
# the launcher has created anything.
clean_vt_processes() {
    fwd_init
    container_pkill cs193v-portprobe
    container_pkill inotifywait
    container_pkill shortlink
    container_pkill "http.server .*--bind 127.0.0.1"
    # make_orphans' sleeps, which the reaper checks kill themselves in the happy case. The
    # duration is the marker: nothing else in this project or a student's work sleeps 1793 s.
    container_pkill "sleep $CS193V_ORPHAN_SLEEP"
}

# How many of them a previous run left behind. Recorded rather than swept silently, so a run
# that was killed leaves a trace in the results instead of being invisible. Counts PROCESSES,
# not probes: one abandoned probe accounts for two, its `sh -c` wrapper and the python inside.
# shortlink is in the pattern for the same reason: it detaches on purpose, so a suite that failed
# between starting one and killing it leaves a forwarded port held for fifteen minutes, and that
# is exactly the kind of leftover the next run must not measure instead of its own.
#
# `pgrep -c` prints 0 AND exits 1 when nothing matches, the same trap run-tests.sh documents
# for `grep -c`, so take its output and ignore its status.
count_vt_processes() {
    local n
    fwd_init
    n="$(podman exec "$NAME" pgrep -cf "cs193v-portprobe|inotifywait|shortlink|http\.server .*--bind 127[.]0[.]0[.]1|sleep $CS193V_ORPHAN_SLEEP" 2>/dev/null | head -1)"
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
