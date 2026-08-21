#!/usr/bin/env bash
# TIER: coverage
#
# Did the suite actually execute every line of install-cs193v.sh that it claims to?
#
# THE MATRIX IN THE PLAN WAS WRITTEN BY READING, and a design document cannot notice a branch
# somebody adds next month. This is the part that keeps it true: every installer run records
# which of its lines executed, and this suite unions them and compares against the file.
#
# WHY IT IS HERE AND NOT IN 10-static.sh, which is where a static-looking check belongs:
# 10-static.sh is the FIRST suite in the cheap lane and both producers run strictly later, so
# a gate there would compute its verdict from nothing, or from a previous run's leftovers.
# Either is the defect VERIFICATION.md §A.15 exists to find. The pure repo-vs-repo half of the
# gate -- that the traced line numbers mean anything at all -- does live in 10-static.sh.
#
# It runs LAST in the podman lane, which is the longer of the two, so the cheap lane's producer
# has finished by the time it starts. That is a property of how long the lanes take, not a
# guarantee, so a missing producer is a NAMED SKIP rather than a smaller union reported as if
# it were the whole picture.

set -u
. "$(dirname -- "$0")/lib/assert.sh"

INST="$PRIVATE/install-cs193v.sh"
ALLOW="$TESTS_DIR/fixtures/coverage-allowlist"

if [ -z "${CS193V_RUN_DIR:-}" ]; then
    skip "coverage:no-run-directory" "run through run-tests.sh; there is nowhere to read traces from"
    exit 0
fi

TRACES="$CS193V_RUN_DIR/trace"
# THE PRODUCERS THIS GATE EXPECTS, by name. Unioning whatever happens to be present is how a
# lenient gate reports a percentage that looks like a measurement, so absence is announced.
# THE PRODUCERS, AND WHICH OF THEM SPOKE. The host cases trace on every run -- cheap, about
# 2x on a suite that takes seconds. The container cases only trace under CS193V_COVERAGE=1,
# because measured at 10x they took the install tier from 6.4 s to 69 s and blew a ceiling.
#
# So a default run legitimately has a PARTIAL union, and the number is labelled as such rather
# than presented as the whole picture. That is the difference between a gate that reports less
# than it could and one that reports a percentage that looks like a measurement and is not.
WANT_PRODUCERS="25-installer.sh 26-installer-sandbox.sh"
missing=''; heard=''
for prod in $WANT_PRODUCERS; do
    # NON-EMPTY, not merely present. sb_collect_trace creates the file whether or not the
    # container traced anything, so an existence test called a silent producer "heard from"
    # and reported union-is-complete=yes on a run where the container half never traced.
    if [ -n "$(find "$TRACES" -name "$prod.*" -size +0 2>/dev/null | head -1)" ]; then
        heard="$heard $prod"
    else missing="$missing $prod"; fi
done
record "coverage:producers-heard-from" "$(printf '%s' "$heard" | sed 's/^ //')"
record "coverage:producers-silent"     "$(printf '%s' "${missing:-none}" | sed 's/^ //')"
if [ -z "$heard" ]; then
    skip "coverage:nothing-to-score" "no producer traced; run the shim tier through run-tests.sh"
    exit 0
fi
COMPLETE=yes; [ -n "$missing" ] && COMPLETE=no
record "coverage:union-is-complete" "$COMPLETE"
# THE HOLE THAT USED TO BE HERE IS GONE, and it is worth saying so rather than deleting the note:
# the apt case was excluded from tracing because `bash -x` hung it at the consent menu, so
# install_podman's real apt arms always read as unreached. That was never about tracing. Ubuntu's
# sudo defaults use_pty ON, the in-container `script` stopped draining its pty master once sudo
# ran, and output past the kernel's buffer blocked in write() forever -- tracing merely multiplied
# output enough to cross it every time. The tty now comes from `podman run -t`, conmon drains it,
# and every case is traceable. lib/sandbox.sh records the bisection.
record "coverage:known-untraced-case" "none -- the apt case's bash -x hang was the pty transport, since replaced"

# ─── what ran ──────────────────────────────────────────────────────────────────
SEEN="$CS193V_RUN_DIR/seen.lines"
# shellcheck disable=SC2086
sed -n 's/^+\([0-9]\{1,\}\) .*/\1/p' $TRACES/* 2>/dev/null | sort -un > "$SEEN"
seen_n="$(grep -c . "$SEEN" || true)"
if [ "${seen_n:-0}" -gt 0 ]; then pass "coverage:the-traces-were-really-read"
else fail "coverage:the-traces-were-really-read" "no line numbers in $TRACES"; exit 1; fi

# ─── what could run ────────────────────────────────────────────────────────────
# A CONSERVATIVE DENOMINATOR, and deliberately approximate: non-blank, not a comment, and not a
# bare block terminator. It will count a few lines bash never traces as its own statement, so
# the percentage is a floor rather than a score -- which is the right direction for a gate to
# be wrong in, and why the number is RECORDED rather than asserted against a threshold.
EXEC="$CS193V_RUN_DIR/exec.lines"
grep -n '' "$INST" \
  | sed -n 's/^\([0-9]\{1,\}\):[[:space:]]*\([^[:space:]].*\)$/\1 \2/p' \
  | grep -vE ' (#|fi$|esac$|done$|else$|\}$|\{$|then$|do$)' \
  | awk '{print $1}' | sort -un > "$EXEC"
exec_n="$(grep -c . "$EXEC" || true)"
if [ "${exec_n:-0}" -gt 100 ]; then pass "coverage:the-denominator-is-plausible"
else fail "coverage:the-denominator-is-plausible" "only ${exec_n:-0} executable lines found in $INST"; exit 1; fi

# ─── the allowlist, and what it is allowed to excuse ───────────────────────────
if [ -s "$ALLOW" ]; then pass "coverage:allowlist-exists"
else fail "coverage:allowlist-exists" "$ALLOW is missing or empty"; exit 1; fi
ALLOWED="$CS193V_RUN_DIR/allowed.lines"
sed -e 's/#.*//' -e 's/[[:space:]].*$//' "$ALLOW" | grep -E '^[0-9]+$' | sort -un > "$ALLOWED"
allow_n="$(grep -c . "$ALLOWED" || true)"
if [ "${allow_n:-0}" -gt 0 ]; then pass "coverage:allowlist-parses-to-line-numbers"
else fail "coverage:allowlist-parses-to-line-numbers" "no line numbers parsed out of $ALLOW"; fi
# Every excused line must still BE a line, or the allowlist is excusing nothing and quietly
# shrinking as the file moves under it.
lastline="$(grep -c '' "$INST")"
bad="$(awk -v n="$lastline" '$1 > n' "$ALLOWED" | tr '\n' ' ')"
assert_eq "coverage:every-allowlisted-line-exists" "" "$(printf '%s' "$bad" | sed 's/ *$//')"

# ─── the verdict, recorded first ───────────────────────────────────────────────
MISSED="$CS193V_RUN_DIR/missed.lines"
grep -vxF -f "$SEEN" "$EXEC" | grep -vxF -f "$ALLOWED" > "$MISSED" || true
missed_n="$(grep -c . "$MISSED" || true)"
# THE PERCENTAGE IS OF THE DENOMINATOR, not of everything traced. bash traces lines the
# conservative rule above deliberately excludes -- `then`, `do`, loop headers -- so the raw
# count of traced lines exceeds the executable set and dividing by it reported a number that
# was neither coverage nor anything else. Intersect first.
HIT="$CS193V_RUN_DIR/hit.lines"
grep -xF -f "$SEEN" "$EXEC" > "$HIT" || true
hit_n="$(grep -c . "$HIT" || true)"
pct=$(( (hit_n * 100) / exec_n ))

record "coverage:executable-lines"      "$exec_n"
record "coverage:lines-executed"        "$hit_n"
record "coverage:lines-traced-in-total" "$seen_n"
record "coverage:percent-executed"      "$pct"
record "coverage:allowlisted"           "$allow_n"
record "coverage:unreached-and-unexcused" "$missed_n"
record "coverage:where-to-look"         "$MISSED"
# NOT YET AN ASSERTION, and doubly so while the union can be partial: with CS193V_COVERAGE
# unset the container producers are silent, so `missed` includes branches that ARE tested and
# simply were not traced. Asserting on that would be measuring the flag, not the installer.
# Landing as a number first is deliberate: the matrix was written by
# reading, so the first real measurement is expected to disagree with it, and turning that
# disagreement straight into a red run would only teach people to raise the threshold. One full
# cycle of reading this number, then it becomes `assert_eq ... "" "$missed"`.
if [ "$missed_n" -gt 0 ]; then
    printf '  %sunreached, unexcused installer lines (%s):%s\n' "$A_DIM" "$missed_n" "$A_OFF"
    tr '\n' ' ' < "$MISSED" | fold -s -w 68 | sed 's/^/      /'
    printf '\n'
fi
