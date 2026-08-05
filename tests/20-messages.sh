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
MESSAGES="$REPO/messages.txt"
# shellcheck disable=SC1090
. "$TMP/msg.sh"

# ─── key reconciliation ────────────────────────────────────────────────────────
# LC_ALL=C throughout: under en_US.UTF-8, sort and comm disagree about how to order
# punctuation and comm aborts with "file 1 is not in sorted order" — which VERIFICATION.md
# §A.1 does today, so its cross-reference has never actually run.
grep -oE '^\[\[[a-z0-9._-]+\]\]' messages.txt | tr -d '[]' | LC_ALL=C sort -u > "$TMP/defined"
grep -ohE 'msg +[a-z0-9._-]+' cs193v install-cs193v.sh | awk '{print $2}' \
    | LC_ALL=C sort -u > "$TMP/used"

orphans="$(LC_ALL=C comm -23 "$TMP/defined" "$TMP/used" | tr '\n' ' ')"
missing="$(LC_ALL=C comm -13 "$TMP/defined" "$TMP/used" | tr '\n' ' ')"
assert_eq "keys:no-orphans" "" "$(printf '%s' "$orphans" | sed 's/ *$//')"
assert_eq "keys:none-missing" "" "$(printf '%s' "$missing" | sed 's/ *$//')"

dupes="$(grep -oE '^\[\[[a-z0-9._-]+\]\]' messages.txt | LC_ALL=C sort | uniq -d | tr '\n' ' ')"
assert_eq "keys:no-duplicates" "" "$(printf '%s' "$dupes" | sed 's/ *$//')"

# A key defined with an empty body makes msg() return "(missing message: k)" at runtime,
# which reaches the student verbatim.
empty="$(awk '/^\[\[/{if (key && !body) printf "%s ", key; key=$0; body=0; next}
              /[^[:space:]]/{body=1} END{if (key && !body) printf "%s ", key}' messages.txt)"
assert_eq "keys:no-empty-bodies" "" "$(printf '%s' "$empty" | sed 's/ *$//')"

# ─── placeholder coverage, both directions ─────────────────────────────────────
# A {{NAME}} nobody supplies reaches the student as literal braces. An argument nobody
# uses is dead weight that signals the message was meant to say something it does not.
python3 - "$REPO" <<'PY' > "$TMP/ph"
import re, sys, os
repo = sys.argv[1]
msgs = open(os.path.join(repo, "messages.txt")).read()

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
for name in ("cs193v", "install-cs193v.sh"):
    for line in open(os.path.join(repo, name)):
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
python3 - "$REPO" <<'PY' > "$TMP/width"
import re, sys, os
repo = sys.argv[1]
launcher = open(os.path.join(repo, "cs193v")).read()

# The bottom border: ┗ + N×━ + ┛. Body lines are printed as "┃ " + text, so for the text
# to stay inside the box: 2 + len(text) <= len(border).
m = re.search(r"┗━+┛", launcher)
if not m:
    print("BOX:none"); sys.exit(0)
box = len(m.group(0))
print("BOX:%d" % box)
limit = box - 2

# Only messages routed through die() are boxed. status.*, prompt.*, opt.*, warn.* and
# help.usage are printed plainly by info/warn/printf and are under no such constraint, so
# holding them to the box width would be a made-up rule.
boxed = set()
for name in ("cs193v", "install-cs193v.sh"):
    for line in open(os.path.join(repo, name)):
        boxed.update(re.findall(r'die\s+"\$\(msg\s+([a-z0-9._-]+)', line))
print("BOXED:%s" % ",".join(sorted(boxed)))

key = None
for line in open(os.path.join(repo, "messages.txt")).read().splitlines():
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
    record "box:width" "$BOXW columns, so message lines may be up to $((BOXW - 2))"
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
