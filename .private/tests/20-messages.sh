#!/usr/bin/env bash
# TIER: static
#
# The message catalogue. Every student-facing string the launcher prints lives in
# messages.txt, which makes wording editable without touching logic — and makes a
# mis-keyed or mis-rendered message a silent failure at exactly the moment a student is
# already stuck. These are the invariants that keep that honest.
#
# msg() is extracted from the launcher and sourced, rather than reimplemented, so these
# test the real substitution code. The extraction is itself asserted, so a refactor that
# moves the function fails loudly instead of quietly testing nothing.

set -u
. "$(dirname -- "$0")/lib/assert.sh"
. "$(dirname -- "$0")/lib/podman-shim.sh"

cd "$REPO" || exit 1

TMP="$(new_tmpdir)"
trap 'rm -rf "$TMP"; shim_cleanup' EXIT

# ─── extract msg() so it can be unit-tested ────────────────────────────────────
sed -n '/^msg() {$/,/^}$/p' cs193v > "$TMP/msg.sh"
if [ "$(wc -l < "$TMP/msg.sh" | tr -d ' ')" -gt 5 ]; then
    pass "msg:extractable-for-unit-test"
else
    fail "msg:extractable-for-unit-test" \
         "could not extract msg() from cs193v — has it been renamed or reformatted?"
    exit 1
fi
MESSAGES="$PRIVATE/messages.txt"
# shellcheck disable=SC1090
. "$TMP/msg.sh"

# ─── key reconciliation ────────────────────────────────────────────────────────
# LC_ALL=C throughout: under en_US.UTF-8, sort and comm disagree about how to order
# punctuation and comm aborts with "file 1 is not in sorted order" — which VERIFICATION.md
# §A.1 does today, so its cross-reference has never actually run.
grep -oE '^\[\[[a-z0-9._-]+\]\]' $PRIVATE/messages.txt | tr -d '[]' | LC_ALL=C sort -u > "$TMP/defined"
grep -ohE 'msg +[a-z0-9._-]+' cs193v $PRIVATE/install-cs193v.sh | awk '{print $2}' \
    | LC_ALL=C sort -u > "$TMP/used"

orphans="$(LC_ALL=C comm -23 "$TMP/defined" "$TMP/used" | tr '\n' ' ')"
missing="$(LC_ALL=C comm -13 "$TMP/defined" "$TMP/used" | tr '\n' ' ')"
assert_eq "keys:no-orphans" "" "$(printf '%s' "$orphans" | sed 's/ *$//')"
assert_eq "keys:none-missing" "" "$(printf '%s' "$missing" | sed 's/ *$//')"

dupes="$(grep -oE '^\[\[[a-z0-9._-]+\]\]' $PRIVATE/messages.txt | LC_ALL=C sort | uniq -d | tr '\n' ' ')"
assert_eq "keys:no-duplicates" "" "$(printf '%s' "$dupes" | sed 's/ *$//')"

# A key defined with an empty body makes msg() return "(missing message: k)" at runtime,
# which reaches the student verbatim.
empty="$(awk '/^\[\[/{if (key && !body) printf "%s ", key; key=$0; body=0; next}
              /[^[:space:]]/{body=1} END{if (key && !body) printf "%s ", key}' $PRIVATE/messages.txt)"
assert_eq "keys:no-empty-bodies" "" "$(printf '%s' "$empty" | sed 's/ *$//')"

# ─── placeholder coverage, both directions ─────────────────────────────────────
# A {{NAME}} nobody supplies reaches the student as literal braces. An argument nobody
# uses is dead weight that signals the message was meant to say something it does not.
python3 - "$REPO" "$PRIVATE" <<'PY' > "$TMP/ph"
import re, sys, os
repo, private = sys.argv[1], sys.argv[2]
msgs = open(os.path.join(private, "messages.txt")).read()

bodies = {}
key = None
for line in msgs.splitlines():
    m = re.match(r"^\[\[([a-z0-9._-]+)\]\]$", line)
    if m:
        key = m.group(1); bodies[key] = []
    elif key:
        bodies[key].append(line)
bodies = {k: "\n".join(v) for k, v in bodies.items()}

# Every `msg <key> NAME=... NAME=...` call site, across both scripts.
calls = {}
for name, root in (("cs193v", repo), ("install-cs193v.sh", private)):
    for line in open(os.path.join(root, name)):
        for m in re.finditer(r'\bmsg\s+([a-z0-9._-]+)((?:\s+[A-Z_]+=(?:"[^"]*"|\S+))*)', line):
            k = m.group(1)
            calls.setdefault(k, set()).update(re.findall(r'([A-Z_]+)=', m.group(2) or ""))

unsupplied, unused = [], []
for k, body in bodies.items():
    needed = set(re.findall(r"\{\{([A-Z_]+)\}\}", body))
    given = calls.get(k, set())
    for p in sorted(needed - given):
        unsupplied.append("%s needs {{%s}} but no call site supplies it" % (k, p))
    for p in sorted(given - needed):
        unused.append("%s is passed %s= but has no {{%s}}" % (k, p, p))
print("UNSUPPLIED:" + "; ".join(unsupplied))
print("UNUSED:" + "; ".join(unused))
PY
assert_eq "placeholders:all-supplied" "UNSUPPLIED:" "$(grep '^UNSUPPLIED:' "$TMP/ph")"
assert_eq "placeholders:none-dead"    "UNUSED:"     "$(grep '^UNUSED:' "$TMP/ph")"

# ─── msg() substitution behaviour ──────────────────────────────────────────────
# The bug this catches: sed's replacement text cannot contain a newline, so a multi-line
# value made msg() emit "sed: unterminated `s' command" and then return NOTHING — so
# die() drew an empty red STOP box. err.create-failed and err.pull-failed both pass raw
# podman output, which is always multi-line. This is the error a stuck student is most
# likely to see.
multi='Error: preparing container failed
level=error msg="cannot set up pasta"
Error: netavark: unable to bind'
out="$(msg err.create-failed OUT="$multi" 2>&1)"
assert_contains "msg:multiline-keeps-first-line"  "Error: preparing container failed" "$out"
assert_contains "msg:multiline-keeps-middle-line" "cannot set up pasta"               "$out"
assert_contains "msg:multiline-keeps-last-line"   "netavark: unable to bind"          "$out"
assert_says "msg:multiline-keeps-surrounding-prose" "cs193v doctor"               "$out"
assert_not_contains "msg:multiline-no-sed-error"  "unterminated"                      "$out"
assert_not_contains "msg:multiline-substitutes"   "{{OUT}}"                           "$out"

# Metacharacters must survive literally. `&` is the trap: bash 5.2+ expands & in the
# replacement of ${var//pat/rep} to the matched text (sed semantics) while bash 3.2 takes
# it literally — so the obvious fix would corrupt this string on Linux and not on macOS.
nasty='trouble with A&B and a|pipe and a\backslash and /slash and {{OUT}} literal'
out="$(msg err.pull-failed OUT="$nasty" 2>&1)"
assert_contains "msg:ampersand-is-literal"  "A&B"          "$out"
assert_contains "msg:pipe-is-literal"       "a|pipe"       "$out"
assert_contains "msg:backslash-is-literal"  'a\backslash'  "$out"
assert_contains "msg:slash-is-literal"      "/slash"       "$out"
# A value that itself contains {{OUT}} must not be re-substituted into a loop.
assert_contains "msg:no-recursive-substitution" "{{OUT}} literal" "$out"

# Multiple distinct placeholders in one message.
out="$(msg err.other-directory INUSE="/a/one" YOURS="/b/two" 2>&1)"
assert_contains "msg:two-placeholders-first"  "/a/one" "$out"
assert_contains "msg:two-placeholders-second" "/b/two" "$out"
assert_not_contains "msg:two-placeholders-clean" "{{" "$out"

# A path containing spaces, which a Mac student's "My Course" directory will produce.
out="$(msg err.no-workspace DIR="/Users/me/My Course/cs193v/projects" 2>&1)"
assert_contains "msg:value-with-spaces" "/Users/me/My Course/cs193v/projects" "$out"

# An empty value must not leave the placeholder visible.
out="$(msg err.no-workspace DIR="" 2>&1)"
assert_not_contains "msg:empty-value-substitutes" "{{DIR}}" "$out"

assert_fail "msg:unknown-key-fails" msg no.such.key
assert_contains "msg:unknown-key-says-so" "missing message" "$(msg no.such.key 2>&1)"

# ─── every message fits the STOP box ───────────────────────────────────────────
# die() draws a fixed-width box and does not wrap, so a body line wider than the box
# overflows past the border on every error. The width is read from the launcher rather
# than hardcoded, so widening the box is a legitimate way to make this pass.
#
# Widths MUST be measured in display columns, not bytes. Ubuntu's awk is mawk, which is
# not multibyte-aware: `length()` on the box border returns 207 rather than 69, because
# every ━ is three bytes. An earlier version of this check used awk and passed vacuously.
# The box borders and the messages both contain plenty of non-ASCII, so python3 does the
# measuring.
require_cmd python3
python3 - "$REPO" "$PRIVATE" <<'PY' > "$TMP/width"
import re, sys, os
repo, private = sys.argv[1], sys.argv[2]
launcher = open(os.path.join(repo, "cs193v")).read()

# The bottom border: ┗ + N×━ + ┛. Body lines are printed as "┃ " + text + pad + " ┃", so
# for the text to stay inside the box: 4 + len(text) <= len(border).
#
# It was `box - 2` while die() drew no right border at all (issue #21), which is how a
# one-sided box passed this lint for as long as it existed: the check enforced the very
# geometry that was the bug. die() now wraps anything longer than the limit rather than
# spilling, so an overflow here is no longer a broken box — but a message that has to be
# machine-wrapped is one nobody chose the line breaks for, and these are the strings a
# stuck student reads. Keep them hand-wrapped.
#
# Read from the launcher's BOX_W rather than by measuring a border literal: die() now
# generates its borders from that number, so there is no longer a hand-typed ┗━━┛ to
# measure — which is the point of it. The literal is still accepted as a fallback so this
# lint does not quietly go vacuous if the box is ever drawn by hand again.
m = re.search(r"^BOX_W=(\d+)", launcher, re.M)
if m:
    box = int(m.group(1))
else:
    m = re.search(r"┗━+┛", launcher)
    if not m:
        print("BOX:none"); sys.exit(0)
    box = len(m.group(0))
print("BOX:%d" % box)
limit = box - 4

# Only messages routed through die() are boxed. status.*, prompt.*, opt.*, warn.* and
# help.usage are printed plainly by info/warn/printf and are under no such constraint, so
# holding them to the box width would be a made-up rule.
boxed = set()
for name, root in (("cs193v", repo), ("install-cs193v.sh", private)):
    for line in open(os.path.join(root, name)):
        boxed.update(re.findall(r'die\s+"\$\(msg\s+([a-z0-9._-]+)', line))
print("BOXED:%s" % ",".join(sorted(boxed)))

key = None
for line in open(os.path.join(private, "messages.txt")).read().splitlines():
    km = re.match(r"^\[\[([a-z0-9._-]+)\]\]$", line)
    if km:
        key = km.group(1); continue
    if not key or len(line) <= limit:
        continue
    if key in boxed:
        print("LONG:%s: %d cols (limit %d): %s" % (key, len(line), limit, line))
    elif len(line) > 80:
        # Not a failure — nothing draws a border around these. Recorded because an
        # 80-column terminal still soft-wraps them, which is a wording call, not a bug.
        print("WIDE:%s: %d cols" % (key, len(line)))
PY
BOXW="$(sed -n 's/^BOX:\(.*\)/\1/p' "$TMP/width")"
if [ "$BOXW" != none ] && [ "${BOXW:-0}" -gt 20 ]; then
    pass "box:width-detected"
    record "box:width" "$BOXW columns, so message lines may be up to $((BOXW - 4))"
else
    fail "box:width-detected" "could not read the STOP box width from cs193v"
fi

record "box:messages-drawn-in-a-box" \
       "$(sed -n 's/^BOXED://p' "$TMP/width" | tr ',' ' ')"

long="$(grep '^LONG:' "$TMP/width" | sed 's/^LONG://')"
if [ -z "$long" ]; then
    pass "box:no-message-line-overflows"
else
    fail "box:no-message-line-overflows" "$(printf '%s\n' "$long" | head -14)
$(printf '%s\n' "$long" | wc -l | tr -d ' ') line(s) overflow the box"
fi

wide="$(grep -c '^WIDE:' "$TMP/width")" || true
record "box:unboxed-lines-over-80-cols" "${wide:-0} (informational; these are not boxed)"

# ─── the STOP box is a closed rectangle ────────────────────────────────────────
# Issue #21: die() drew ┏━━ STOP ━━┓ and ┗━━┛ with corners on both ends, then every body
# line as "┃ text" and nothing else — a box with a left wall, a lid and a floor, and no
# right wall. It had been that way in both scripts since they were written.
#
# Nothing caught it, and the two checks that look like they should have are worth naming,
# because both were the kind that can only ever pass:
#
#   * the width lint above computed its limit as `box - 2`, i.e. "┃ " and no closing
#     border. It encoded the bug as the specification.
#   * "die:all-lines-inside-the-box" counts lines with `grep -c '┃'`, which counts LINES
#     CONTAINING the character, never how many are on one. One wall scores exactly the
#     same as two.
#
# So this asserts the shape directly: same display width on every line of the box, corners
# in the four corners, and a right wall on every body line in between.
#
# Widths in DISPLAY COLUMNS via python3, for the reason recorded above the width lint —
# mawk's length() would score the border at 3× and pass vacuously.
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

# There must be exactly one place that draws it. Before the fix there were four — die() in
# each script, plus the Intel-Mac refusal typed out as a heredoc, plus the launcher's own
# banner — and the two in install-cs193v.sh had already drifted a column apart from each
# other. Nobody could see that, because a box with no right edge has no width to disagree
# about. Box art typed out by hand anywhere but inside box() is that bug growing back.
for boxsrc in "launcher:$REPO/cs193v" "installer:$PRIVATE/install-cs193v.sh"; do
    who="${boxsrc%%:*}"; f="${boxsrc#*:}"
    # box() builds its borders inside an awk printf; anything else is hand-drawn art.
    hand="$(grep -n '[┏┗┃]' "$f" | grep -v printf || true)"
    assert_eq "box:$who-draws-the-box-in-one-place" "" "$hand"
done

# The two copies of box() must not drift. install-cs193v.sh is curl-piped and standalone,
# so it cannot source the launcher's copy — the same situation version_lt is in, and this
# is the same check that keeps version_lt honest.
for f in "$REPO/cs193v" "$PRIVATE/install-cs193v.sh"; do
    sed -n '/^box() {$/,/^}$/p' "$f" > "$TMP/box.$(basename "$f")"
done
if [ "$(wc -l < "$TMP/box.cs193v" | tr -d ' ')" -gt 20 ]; then
    pass "box:extractable"
else
    fail "box:extractable" "could not extract box() from cs193v"
fi
assert_eq "box:both-copies-identical" "" \
          "$(diff "$TMP/box.cs193v" "$TMP/box.install-cs193v.sh" 2>&1)"
assert_eq "box:both-widths-identical" \
          "$(grep -c '^BOX_W=71$' "$REPO/cs193v")" \
          "$(grep -c '^BOX_W=71$' "$PRIVATE/install-cs193v.sh")"

# ─── die() renders a real multi-line failure end to end ────────────────────────
# Not a unit test of msg(): this drives the actual launcher against a podman that fails
# the way podman fails, and asserts the student sees the diagnosis rather than a blank box.
shim_new
shim_set state absent
shim_set run_rc 1
shim_set run_err 'Error: preparing container failed
level=error msg="cannot set up pasta: Operation not permitted"
Error: netavark: iptables chain creation failed'
COPY="$(repo_copy)"
LAUNCHER_DIR="$COPY"
out="$(launcher)"
assert_contains "die:banner-drawn"          "STOP"                              "$out"
assert_contains "die:shows-podman-line-1"   "preparing container failed"        "$out"
assert_contains "die:shows-podman-line-2"   "cannot set up pasta"               "$out"
assert_contains "die:shows-podman-line-3"   "iptables chain creation failed"    "$out"
assert_says "die:shows-next-step"       "cs193v doctor"                     "$out"
assert_not_contains "die:no-sed-error"      "unterminated"                      "$out"
# Every line of the message must be inside the box, not spilling out beneath it.
body_lines="$(printf '%s\n' "$out" | grep -c '┃' || true)"
if [ "${body_lines:-0}" -ge 8 ]; then
    pass "die:all-lines-inside-the-box"
else
    fail "die:all-lines-inside-the-box" "only $body_lines boxed lines:
$out"
fi
assert_eq "die:exits-nonzero" "1" "$(launcher_rc)"

# The same output, checked for shape rather than for content. This is the assertion issue
# #21 was reported against: the student's real error, drawn as a real box.
probs="$(printf '%s\n' "$out" | box_problems)"
if [ -z "$probs" ]; then
    pass "die:box-is-closed"
else
    fail "die:box-is-closed" "$probs"
fi

# A line too long to fit must WRAP inside the box, not push the right wall out past it or
# spill into the terminal. This is not hypothetical tidiness: err.create-failed and
# err.pull-failed interpolate raw podman output, which is written to no width at all, and
# a single `Error: ... /very/long/path ...` line is the common shape. Nothing in
# messages.txt can be hand-wrapped to fix that — only die() can.
shim_new
shim_set state absent
shim_set run_rc 1
shim_set run_err 'Error: OCI runtime error: crun: cannot setup network namespace for container 9f2c1b7e4a3d: /run/user/1000/netns/netns-8c4e is not a valid mount point and the rootless network setup helper exited 1'
out="$(launcher)"
probs="$(printf '%s\n' "$out" | box_problems)"
if [ -z "$probs" ]; then
    pass "die:long-line-wraps-inside-the-box"
else
    fail "die:long-line-wraps-inside-the-box" "$probs"
fi
# Wrapped, not truncated: the tail of that line is the part naming what actually failed.
assert_says "die:long-line-keeps-its-head" "OCI runtime error: crun: cannot setup" "$out"
assert_says "die:long-line-keeps-its-tail" "network setup helper exited 1"         "$out"

# A word longer than the box has nowhere to break. It still must not breach the wall — a
# container id or a deep path arrives in podman output as one unbroken token.
shim_new
shim_set state absent
shim_set run_rc 1
shim_set run_err "Error: statfs /home/student/projects/$(printf 'a%.0s' $(seq 1 90))/x: no such file"
out="$(launcher)"
probs="$(printf '%s\n' "$out" | box_problems)"
if [ -z "$probs" ]; then
    pass "die:unbreakable-word-stays-inside-the-box"
else
    fail "die:unbreakable-word-stays-inside-the-box" "$probs"
fi

# ─── the installer draws the same box ──────────────────────────────────────────
# install-cs193v.sh has its own die(), its own copy of the box art, and no shared library
# with the launcher to keep them honest — and it is the student's FIRST contact with the
# course, so a broken box there is the first thing they ever see of it. Extracted and run
# for real rather than pattern-matched, the same way this suite treats msg().
{
    printf 'BOX_W=71\nC_RED=""\nC_OFF=""\n'
    cat "$TMP/box.install-cs193v.sh"
    sed -n '/^die() {$/,/^}$/p'           "$PRIVATE/install-cs193v.sh"
    sed -n '/^say_intel_mac() {$/,/^}$/p' "$PRIVATE/install-cs193v.sh"
} > "$TMP/idie.sh"

if [ "$(grep -c '^die() {$' "$TMP/idie.sh")" = 1 ] &&
   [ "$(grep -c '^say_intel_mac() {$' "$TMP/idie.sh")" = 1 ]; then
    pass "installer:box-users-extractable"
else
    fail "installer:box-users-extractable" \
         "could not extract die() and say_intel_mac() from install-cs193v.sh"
fi

out="$(bash -c '. "$1"; die "$2"' _ "$TMP/idie.sh" \
       'podman could not be installed.

The package manager returned:
Error: Unable to locate package podman-is-not-a-real-package-name-here' 2>&1)"
probs="$(printf '%s\n' "$out" | box_problems)"
if [ -z "$probs" ]; then
    pass "installer:die-box-is-closed"
else
    fail "installer:die-box-is-closed" "$probs"
fi
assert_says "installer:die-shows-the-diagnosis" "Unable to locate package" "$out"

# The Intel-Mac refusal. It is reached before anything is installed, by a student whose
# machine will never run this course — so it is the only thing they ever see the setup
# print, and it is worth it being a box rather than three walls.
out="$(bash -c '. "$1"; say_intel_mac' _ "$TMP/idie.sh" 2>&1)"
probs="$(printf '%s\n' "$out" | box_problems)"
if [ -z "$probs" ]; then
    pass "installer:intel-mac-box-is-closed"
else
    fail "installer:intel-mac-box-is-closed" "$probs"
fi
assert_says "installer:intel-mac-says-why" "This Mac has an Intel processor." "$out"
assert_says "installer:intel-mac-says-what-next" "contact course staff BEFORE the first lab" "$out"
