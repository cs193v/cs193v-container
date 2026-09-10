#!/usr/bin/env bash
# TIER: static
#
# The message catalogue. Every student-facing string the launcher prints lives in
# messages.txt, which makes wording editable without touching logic — and makes a
# mis-keyed or mis-rendered message a silent failure at exactly the moment a student is
# already stuck. These are the invariants that keep that honest.
#
# msg() is extracted from cs193v-ui.sh and sourced, rather than reimplemented, so these
# test the real substitution code. The extraction is itself asserted, so a refactor that
# moves the function fails loudly instead of quietly testing nothing — which is exactly what
# it did when msg(), box() and the rest moved out of the launcher into the shared helper.

set -u
. "$(dirname -- "$0")/lib/assert.sh"
. "$(dirname -- "$0")/lib/podman-shim.sh"

cd "$REPO" || exit 1

# ABOVE EVERY PRODUCER, which is the whole point of where this line sits. Four checks below
# measure display columns with python3 -- the catalogue width lint at the top, the box width
# lint, setup-git's boxed messages and box_problems -- and this used to be `require_cmd python3`
# 172 lines below the first of them, so a broken interpreter was found only after the earliest
# check that needed it had already answered. See require_python3 in lib/assert.sh for why
# `command -v` is not the question.
require_python3

TMP="$(new_tmpdir)"
trap 'rm -rf "$TMP"; shim_cleanup' EXIT
# ...and at START as well, because that trap cannot run if the suite is KILLED, which is
# ordinary here. See sweep_stale_tmpdirs in lib/assert.sh for the rest of the reasoning.
record "shim:leftover-dirs-from-an-earlier-run" "$(shim_sweep_stale)"

# ─── extract msg() so it can be unit-tested ────────────────────────────────────
UI="$PRIVATE/files/cs193v-ui.sh"
sed -n '/^msg() {$/,/^}$/p' "$UI" > "$TMP/msg.sh"
if [ "$(wc -l < "$TMP/msg.sh" | do_tr -d ' ')" -gt 5 ]; then
    pass "msg:extractable-for-unit-test"
else
    fail "msg:extractable-for-unit-test" \
         "could not extract msg() from cs193v-ui.sh — has it been renamed or reformatted?"
    exit 1
fi
# Read by msg() in the carving sourced on the next line, exactly as lib/shared.sh:196-207 sets
# it for msg_of -- and disabled here for the reason that comment gives rather than for the file.
# shellcheck disable=SC2034
MESSAGES="$PRIVATE/messages.txt"
# shellcheck disable=SC1090
. "$TMP/msg.sh"

# ─── key reconciliation ────────────────────────────────────────────────────────
# LC_ALL=C throughout: under en_US.UTF-8, sort and comm disagree about how to order
# punctuation and comm aborts with "file 1 is not in sorted order" — which VERIFICATION.md
# §A.1 does today, so its cross-reference has never actually run.
grep -oE '^\[\[[a-z0-9._-]+\]\]' $PRIVATE/messages.txt | do_tr -d '[]' | LC_ALL=C sort -u > "$TMP/defined"
# THE LAUNCHER ALONE (#221). This reconciles msg keys against messages.txt, and the only
# other file that reads that catalogue is gone: install-cs193v.sh is the bootstrap now and has
# no catalogue at all, while course-install.sh reads its OWN via txt() -- which is why the
# accessor must not be renamed msg, and why feeding this its keys would report every one of
# them as missing from a catalogue they were never in. itext:* below is their reconciliation.
grep -ohE 'msg +[a-z0-9._-]+' cs193v | awk '{print $2}' \
    | LC_ALL=C sort -u > "$TMP/used"

orphans="$(LC_ALL=C comm -23 "$TMP/defined" "$TMP/used" | do_tr '\n' ' ')"
missing="$(LC_ALL=C comm -13 "$TMP/defined" "$TMP/used" | do_tr '\n' ' ')"
assert_eq "keys:no-orphans" "" "$(printf '%s' "$orphans" | sed 's/ *$//')"
assert_eq "keys:none-missing" "" "$(printf '%s' "$missing" | sed 's/ *$//')"

dupes="$(grep -oE '^\[\[[a-z0-9._-]+\]\]' $PRIVATE/messages.txt | LC_ALL=C sort | uniq -d | do_tr '\n' ' ')"
assert_eq "keys:no-duplicates" "" "$(printf '%s' "$dupes" | sed 's/ *$//')"

# A key defined with an empty body makes msg() return "(missing message: k)" at runtime,
# which reaches the student verbatim.
empty="$(awk '/^\[\[/{if (key && !body) printf "%s ", key; key=$0; body=0; next}
              # A NOTE-ONLY BODY IS EMPTY (#221): msg() drops column-0 hashes now, so a key
              # whose body is nothing but staff notes renders as "(missing message: k)".
              /^#/{next}
              /[^[:space:]]/{body=1} END{if (key && !body) printf "%s ", key}' $PRIVATE/messages.txt)"
assert_eq "keys:no-empty-bodies" "" "$(printf '%s' "$empty" | sed 's/ *$//')"

# ─── the installer's own catalogue ─────────────────────────────────────────────
# ISSUE #116, FINISHED BY #221. The installer's prose used to live INSIDE the script, in a heredoc
# at the foot of the file reached by a txt() that was a near-copy of msg() -- because the
# installer sourced nothing and no catalogue existed until the download succeeded. Downloading
# first removed both halves of that: the prose is course-install-messages.txt, and the reader is
# the same msg() the launcher and setup-git use, with MESSAGES pointing at a different file.
#
# SO THIS BLOCK GOT SMALLER RATHER THAN MOVING. There is no heredoc to carve, no second accessor
# to extract, and the runtime checks below drive THE reader rather than a copy of it -- which is
# the point: a txt() that had drifted from msg() would have passed its own tests.
INST="$PRIVATE/course-install.sh"
ICAT="$PRIVATE/course-install-messages.txt"
assert_file "itext:the-catalogue-is-there" "$ICAT"

grep -oE '^\[\[[a-z0-9._-]+\]\]' "$ICAT" | do_tr -d '[]' \
    | LC_ALL=C sort -u > "$TMP/idefined"
# EVERY CALL FORM, and the nested one is why this is a grep for the word rather than a match on
# the line: need's label composes `$(msg need.podman-linux.and ...)` INSIDE another msg call, so
# a one-per-line pattern would never see the inner key.
#
# THE LEADING [^A-Za-z0-9_.] IS NOT DECORATION. A bare `msg +` also matches prose like
# "messages.txt for its early output" -- which registered `for` as a key in use and turned a
# reconciliation red for a sentence. Whole-line comments go first for the same class of reason:
# prose about the catalogue is not a call into it.
sed 's/^[[:space:]]*#.*//' "$INST" \
    | grep -ohE '[^A-Za-z0-9_.]msg +[a-z0-9._-]+' | awk '{print $NF}' \
    | LC_ALL=C sort -u > "$TMP/iused"

iorphans="$(LC_ALL=C comm -23 "$TMP/idefined" "$TMP/iused" | do_tr '\n' ' ')"
imissing="$(LC_ALL=C comm -13 "$TMP/idefined" "$TMP/iused" | do_tr '\n' ' ')"
assert_eq "itext:no-orphans"   "" "$(printf '%s' "$iorphans" | sed 's/ *$//')"
assert_eq "itext:none-missing" "" "$(printf '%s' "$imissing" | sed 's/ *$//')"

idupes="$(grep -oE '^\[\[[a-z0-9._-]+\]\]' "$ICAT" | LC_ALL=C sort | uniq -d | do_tr '\n' ' ')"
assert_eq "itext:no-duplicates" "" "$(printf '%s' "$idupes" | sed 's/ *$//')"

iempty="$(awk '/^\[\[/{if (key && !body) printf "%s ", key; key=$0; body=0; next}
               /^#/{next} /[^[:space:]]/{body=1} END{if (key && !body) printf "%s ", key}' "$ICAT")"
assert_eq "itext:no-empty-bodies" "" "$(printf '%s' "$iempty" | sed 's/ *$//')"

# A MISSING KEY MUST BE LOUD. msg() is what die() reaches for, so a typo'd key that returned
# nothing would draw an EMPTY red STOP box at the moment a student most needs the diagnosis --
# ERRORS.md records exactly that failure. Run for real, against the real file.
#
# THROUGH THE CARVED msg() ABOVE, with MESSAGES repointed in a subshell so this file's own
# launcher-facing MESSAGES is untouched. One reader, two catalogues, which is what the split
# bought and what these four cases now demonstrate rather than assume.
imsg() { bash -c 'MESSAGES="$2"; . "$1"; shift 2; msg "$@"' _ "$TMP/msg.sh" "$ICAT" "$@" 2>&1; }
imiss="$(imsg no.such.key)"
assert_says "itext:a-missing-key-says-which"  "no.such.key" "$imiss"
assert_fail "itext:a-missing-key-is-an-error" \
            bash -c 'MESSAGES="$2"; . "$1"; msg no.such.key >/dev/null 2>&1' _ "$TMP/msg.sh" "$ICAT"
# ...and a real one renders, or the check above would pass against a msg() that always failed.
assert_says "itext:a-real-key-renders" "is not answering" "$(imsg err.podman-mute)"
# Placeholders really substitute, including into a multi-line value -- err.podman-old-mac
# interpolates {{HOW}}, which is itself two catalogue entries deep.
isub="$(imsg err.subuid-failed "USER=someone")"
assert_says     "itext:a-placeholder-is-filled-in"  "for someone." "$isub"
assert_says_not "itext:no-placeholder-is-left-over" "{{" "$isub"
# AND THE STAFF-NOTE RULE HOLDS ON THIS FILE TOO, which matters more here than anywhere: the
# installer's notes were comments in a shell heredoc and are now column-0 hashes in a catalogue,
# so a reader that printed them would put maintainer prose in front of a student mid-install.
assert_says_not "itext:a-column-0-hash-is-not-printed" "#" "$(imsg welcome)"

# ─── the container's own catalogue ─────────────────────────────────────────────
# setup-git-messages.txt is the same format read by the same msg(), and gets the same three
# invariants — but it is a SEPARATE FILE because the container cannot see messages.txt, and
# 10-static.sh asserts that container-side prose stays out of it.
SGM="$PRIVATE/files/setup-git-messages.txt"
SGS="$PRIVATE/files/setup-git"
grep -oE '^\[\[[a-z0-9._-]+\]\]' "$SGM" | do_tr -d '[]' | LC_ALL=C sort -u > "$TMP/sg_defined"
assert_ne "sgkeys:catalogue-found" "" "$(cat "$TMP/sg_defined")"

# ORPHANS ARE FOUND BY SEARCHING FOR THE KEY, not by matching a call form, and that difference
# matters here where it did not for the launcher. setup-git reaches its messages four ways —
# `msg k`, `render k`, `say k`, and `say "$SG_FAIL_KEY"` with the key assigned three lines
# earlier as a bare argument to probe_row. A grep for `msg +k` would call err.push, err.issues
# and err.prs orphans and be wrong about all three, and the natural response to that would be to
# weaken the check.
: > "$TMP/sg_orphans"
while IFS= read -r k; do
    # Bounded on both sides, because err.clone is a prefix of err.clone-wrong-owner and an
    # unbounded match would let a deleted key pass on the strength of its longer neighbour.
    grep -qE "(^|[^a-z0-9._-])$(printf '%s' "$k" | sed 's/\./\\./g')([^a-z0-9._-]|$)" "$SGS" \
        || printf '%s ' "$k" >> "$TMP/sg_orphans"
done < "$TMP/sg_defined"
assert_eq "sgkeys:no-orphans" "" "$(sed 's/ *$//' "$TMP/sg_orphans")"

# The other direction still needs the call forms: a key that is *asked for* and not defined
# renders "(missing message: k)" into the middle of a screen.
#
# COMMENTS ARE DROPPED FIRST, and the call has to be in command position. Without either, this
# suite's own prose supplies the counter-example: "GitHub will not say who it belongs to" makes a
# key called `who`, and the check then fails on a comment.
grep -v '^[[:space:]]*#' "$SGS" \
    | grep -ohE '(^|[;&|(]|\$\()[[:space:]]*(msg|render|say) +[a-z0-9._-]+' \
    | awk '{print $NF}' | LC_ALL=C sort -u > "$TMP/sg_used"
assert_eq "sgkeys:none-missing" "" \
          "$(LC_ALL=C comm -13 "$TMP/sg_defined" "$TMP/sg_used" | do_tr '\n' ' ' | sed 's/ *$//')"

sgdupes="$(grep -oE '^\[\[[a-z0-9._-]+\]\]' "$SGM" | LC_ALL=C sort | uniq -d | do_tr '\n' ' ')"
assert_eq "sgkeys:no-duplicates" "" "$(printf '%s' "$sgdupes" | sed 's/ *$//')"

sgempty="$(awk '/^\[\[/{if (key && !body) printf "%s ", key; key=$0; body=0; next}
                /^#/{next}
                /[^[:space:]]/{body=1} END{if (key && !body) printf "%s ", key}' "$SGM")"
assert_eq "sgkeys:no-empty-bodies" "" "$(printf '%s' "$sgempty" | sed 's/ *$//')"

# ─── the keys the pty driver waits on (#206) ───────────────────────────────────
# fixtures/setup-git-flows.txt names, for every keystroke, the catalogue key of the screen that
# keystroke answers, and lib/setup-git-shim.sh resolves it through msg_text before a step is sent.
# TWO WAYS THAT CAN GO WRONG SILENTLY, and both are cheaper to catch here than at 3am in a suite
# that has started timing out.
SGFLOWS="$TESTS_DIR/fixtures/setup-git-flows.txt"
assert_file "sgflow:the-fixture-is-there" "$SGFLOWS"
grep -oE '^(line|secret|menu|\?menu)[[:space:]]+[a-z0-9._ -]+' "$SGFLOWS" \
    | sed -E 's/^(line|secret|menu|\?menu)[[:space:]]+//' | do_tr ' ' '\n' \
    | grep -E '^[a-z]' | LC_ALL=C sort -u > "$TMP/sg_gatekeys"
assert_ne "sgflow:the-fixture-names-keys" "" "$(cat "$TMP/sg_gatekeys")"

# A RENAMED KEY IS A GATE THAT CAN NEVER OPEN. It does not fail where the rename happened; it
# fails as a step deadline in whichever case reaches that screen first.
assert_eq "sgflow:every-gate-key-exists" "" \
          "$(LC_ALL=C comm -13 "$TMP/sg_defined" "$TMP/sg_gatekeys" | do_tr '\n' ' ' | sed 's/ *$//')"

# AND A PLACEHOLDER-LED KEY IS A NEEDLE THAT MATCHES ALMOST ANYTHING. msg_text (lib/assert.sh:242)
# truncates at the first {{ }}, so `confirm.entered` resolves to "You entered " and
# `token.more-characters` to "...". Ten keys in this catalogue are cut short that way, and they are
# exactly the ones somebody annotating the checkpoint or the account screen would reach for first.
#
# THE UNIT IS THE STEP, NOT THE KEY, and getting that wrong is instructive. `prompt.retry` is
# "Try again:" -- ten characters, and setup-git prints it from THREE different loops
# (files/setup-git:553, 555, 584, 666), so on its own it cannot say which one the child is in. The
# fixture never uses it on its own: every retry step names the COMPLAINT beside it
# (`err.sunetid-invalid prompt.retry`), which is unique and is what the case is about anyway. So
# what has to hold is that no step is gated on weak needles ALONE.
#
# ELEVEN CHARACTERS is the threshold because the shortest needle the fixture leans on is
# `Your token:`. That one is safe only because a step matches against output produced since the
# PREVIOUS step, so read_secret's 94 tally redraws sit behind the cursor rather than in front of it.
: > "$TMP/sg_weaksteps"
grep -nE '^(line|secret|menu)[[:space:]]' "$SGFLOWS" | while IFS= read -r row; do
    lineno="${row%%:*}"
    keys="$(printf '%s' "${row#*:}" | sed -E 's/^(line|secret|menu)[[:space:]]+//; s/->.*//')"
    best=0
    for k in $keys; do
        case "$k" in [a-z]*) ;; *) continue ;; esac
        n="$(msg_text "$k" "$SGM" | do_tr -d '*' | do_tr -d '\n' | wc -c | do_tr -d ' ')"
        [ "$n" -gt "$best" ] && best="$n"
    done
    [ "$best" -ge 11 ] || printf 'line %s(%s) ' "$lineno" "$best" >> "$TMP/sg_weaksteps"
done
assert_eq "sgflow:no-step-is-gated-on-weak-needles-alone" "" \
          "$(sed 's/ *$//' "$TMP/sg_weaksteps" 2>/dev/null)"

# ─── the container's prose fits an 80-column terminal ──────────────────────────
# WHY 76 AND NOT 80. render() indents every line by two columns, and a line that reaches the
# right edge SOFT-wraps rather than being refused — so it costs a second row, invisibly, in a
# file whose author was looking at a 120-column window. That is the whole of issue #58's
# symptom: the catalogue was hard-wrapped at 94, every paragraph line took two rows on the
# 80-column terminal MANUAL.md says to test in, and the token screen came to 53 rows against the
# 23 the container's tmux leaves visible. 76 + 2 = 78 keeps two columns in hand.
#
# {{ORG}} AND {{EXPIRY}} ARE SUBSTITUTED, from setup-git's own defaults rather than from a copy
# here, because "cs193v-students" is eight columns longer than the placeholder it replaces and a
# line that fits in the file can overflow on a student's screen. {{ID}}, {{EMAIL}} and {{SANDBOX}}
# are substituted for the same reason and at their widest, an eight-character SUNetID being the
# longest Stanford issues.
#
# {{URL}} IS SUBSTITUTED TOO, AND USED TO BE EXEMPT. The exemption was honest while it lasted --
# the prefilled link was 157 characters of GitHub's making and could not be wrapped without
# breaking it -- but it exempted the one line on this screen whose wrapping actually costs a
# student a token, which is issue #67. `shortlink` is what closed it: setup-git now hands the
# student a local redirect instead, so the line is lintable like every other.
#
# THE VALUE IS THE WORST CASE, not whatever a run would really produce, because the port is
# chosen at runtime and this suite has no container: the widest port shortlink can bind (65535)
# and the longest slug anything mints (`magic-token-link`, setup-git's). A caller that grows a
# longer slug than that has to come back here, which is the point.
# THROUGH run_checker, like every other producer feeding an empty-is-happy assertion. This is
# one of the five #79's differential still found vacuous after the shared checkers were fixed:
# require_python3 at the top of this file covers the interpreter being broken when the suite
# STARTS, and nothing covered this program dying on its own. The heredoc is stdin, which the
# wrapper passes straight through.
sgwide="$(run_checker python3 - "$SGM" "$SGS" <<'WIDE'
import re, sys
cat, script = sys.argv[1], sys.argv[2]
src = open(script).read()
def default(var, fallback):
    m = re.search(r'^%s="\$\{%s:-([^}]*)\}"' % (var, var), src, re.M)
    return m.group(1) if m else fallback
org = default("CS193V_GH_ORG", "cs193v-students")
prefix = default("CS193V_GH_SANDBOX_PREFIX", "sandbox-")
subs = {"ORG": org,
        "EXPIRY": default("CS193V_TOKEN_EXPIRY", "2026-12-31"),
        "URL": "http://localhost:65535/magic-token-link",
        # WORST CASES, NOT EXAMPLES, and all three are eight characters of SUNetID: the ID itself,
        # the address derived from it, and the repository named after it (issue #92). err.clone
        # carries the last, and measuring that line at the width of the PLACEHOLDER scores it 21
        # columns short -- which is exactly how a line goes out two columns too wide.
        "ID": "x" * 8,
        "EMAIL": "x" * 8 + "@stanford.edu",
        "SANDBOX": "%s/%s%s" % (org, prefix, "x" * 8)}
key = None
for n, line in enumerate(open(cat).read().splitlines(), 1):
    m = re.match(r"^\[\[([a-z0-9._-]+)\]\]$", line)
    if m:
        key = m.group(1); continue
    if key is None:
        continue
    text = line.replace("*", "")
    for k, v in subs.items():
        text = text.replace("{{%s}}" % k, v)
    if len(text) > 76:
        print("%s (line %d): %d columns" % (key, n, len(text)))
WIDE
)"
assert_eq "sgkeys:every-line-fits-an-80-column-terminal" "" "$sgwide"

# EMPHASIS DOES NOT SURVIVE A LINE BREAK, and rewrapping is exactly when somebody splits one.
# emph_stream closes an unpaired *asterisk* at end of line, so `titled *New` / `fine-grained
# token*.` renders the first half plain and the second half's full stop in cyan — inside out,
# and invisible to every assertion in this suite, which strips the markup before comparing.
# Introduced twice while rewrapping this file for issue #58, which is the argument for the check.
sgodd="$(awk '/^\[\[[a-z0-9._-]+\]\]$/ { key = $0; next }
              key != "" { n = gsub(/\*/, "*"); if (n % 2) printf "%s line %d; ", key, NR }' "$SGM")"
assert_eq "sgkeys:emphasis-is-paired-on-every-line" "" "$(printf '%s' "$sgodd" | sed 's/; *$//')"


# ─── placeholder coverage, both directions ─────────────────────────────────────
# A {{NAME}} nobody supplies reaches the student as literal braces. An argument nobody
# uses is dead weight that signals the message was meant to say something it does not.
#
# BOTH CATALOGUES, and the second one was unchecked in either direction until issue #58 moved a
# placeholder: token.prefill carried {{EXPIRY}} for the four checks that issue deleted, and a
# token.prefill that lost its {{URL}} instead would hand every student instructions with no link
# in them. The container's catalogue is reached four ways rather than one — `msg`, `render`,
# `say`, and `say "$SG_FAIL_KEY"` — so the call form matched here is the alternation, the same
# widening the orphan check above needed.
python3 - "$REPO" "$PRIVATE" <<'PY' > "$TMP/ph"
import re, sys, os
repo, private = sys.argv[1], sys.argv[2]

# THREE CATALOGUES, ONE PER CONSUMER, and the first entry used to be wrong in a way that read as
# coverage: it paired course-install.sh with the LAUNCHER's messages.txt, so every installer key
# was checked against a file it was never in. The installer said `txt` and this pattern matches
# `msg`, so the arm contributed no call sites at all and the mistake was invisible -- a vacuous
# arm rather than a red one. Since #221 the installer has its own catalogue and reads it with the
# same msg(), so it gets an entry of its own and the pairing is now checkable.
CATALOGUES = (
    (os.path.join(private, "messages.txt"),
     (os.path.join(repo, "cs193v"),),
     r'\bmsg\s+'),
    (os.path.join(private, "course-install-messages.txt"),
     (os.path.join(private, "course-install.sh"),),
     r'\bmsg\s+'),
    (os.path.join(private, "files", "setup-git-messages.txt"),
     (os.path.join(private, "files", "setup-git"),),
     r'\b(?:msg|render|say)\s+'),
)

def joined_lines(path):               # the file as bash reads it: continuations spliced
    out, acc = [], ""
    for line in open(path):
        line = line.rstrip("\n")
        if line.endswith("\\"):
            acc += line[:-1]
            continue
        out.append(acc + line)
        acc = ""
    if acc:
        out.append(acc)
    return out

unsupplied, unused = [], []
for catalogue, scripts, callform in CATALOGUES:
    bodies = {}
    key = None
    for line in open(catalogue).read().splitlines():
        m = re.match(r"^\[\[([a-z0-9._-]+)\]\]$", line)
        if m:
            key = m.group(1); bodies[key] = []
        elif key:
            # A COLUMN-0 HASH IS A STAFF NOTE AND IS NEVER PRINTED, so a {{NAME}} inside one is
            # not a placeholder anybody has to supply. msg() drops these lines; this has to drop
            # them too or it reports a note's own example as an unsupplied placeholder. Found the
            # moment course-install-messages.txt became a real file: its note beside
            # need.podman-mac.why explains what {{PKGS}} is, and that read as a requirement.
            if line.startswith("#"):
                continue
            bodies[key].append(line)
    bodies = {k: "\n".join(v) for k, v in bodies.items()}

    # Every call site, with the NAME=value arguments it passes.
    #
    # THE ARGUMENTS ARE READ TO END OF LINE rather than matched one at a time, because an
    # argument can contain a nested command substitution with its own quoted string inside it —
    # `say github.checkpoint "EMAIL_ENC=$(email_encoded "$SG_EMAIL")" "ORG=$ORG"` — and a
    # per-argument pattern stops at the first space inside that and never sees ORG. It reported
    # the message as missing a placeholder nobody had failed to supply.
    #
    # A KEY NAMED BY A VARIABLE supplies its arguments to whatever key it turns out to be:
    # `say "$SG_FAIL_KEY" "ORG=$ORG"` is how err.clone, err.push, err.issues and err.prs are
    # reached, the key having been chosen three lines earlier by probe_row. Those arguments are
    # pooled and credited to any key that has no direct call site of its own, and the dead-weight
    # check is skipped for exactly those keys — an indirect site says nothing about which of the
    # four its arguments were meant for.
    # A CALL MAY SPAN TWO LINES, so continuations are joined before anything is matched. Reading
    # to end of line is what makes the nested-substitution case above work, and it is also what
    # makes a `say` broken across a backslash invisible: the arguments on the second line are not
    # on the line the key is on. That reported github.checkpoint as missing {{ORG}} when the call
    # right there supplies it — a false alarm, which is the kind of failure that gets a check
    # weakened rather than fixed.
    # ─── which call does a NAME= belong to ────────────────────────────────────
    # TO THE INNERMOST CALL THAT ENCLOSES IT, and this replaced "everything to end of line".
    # That older rule was deliberate -- an argument can hold a nested command substitution with
    # its own quoted string, `"EMAIL_ENC=$(email_encoded "$SG_EMAIL")"`, and a per-argument
    # pattern stops at the space inside it -- but it over-attributes in two ways that only
    # showed up once the installer's catalogue got an entry of its own:
    #
    #   A NESTED CALL'S ARGUMENTS were credited to the OUTER key as well as the inner one.
    #   need.podman-linux composes need.podman-linux.and inside its own PKGS= argument, so the
    #   outer key was reported as "passed PKG= but has no {{PKG}}" -- true of the outer, and
    #   entirely the inner call's business.
    #
    #   ANYTHING AFTER THE CALL ON THE SAME LINE was swept in too, including plain shell.
    #   `printf '    %s ' "$(msg prompt.path)"; IFS= read -r DIR` credited prompt.path with an
    #   IFS placeholder, which is a shell assignment and not an argument to anything.
    #
    # So each call gets the region from its key to the close of the `$(` it sits in -- which
    # still contains nested substitutions, keeping the case the old rule was written for -- and
    # every NAME= is assigned to the LAST call whose region still contains it, i.e. the innermost.
    # A NAME= inside no call's region belongs to nobody, which is the shell-assignment case.
    def arg_regions(line):           # -> [(key, start, end)] innermost-last within a line
        out = []
        for m in re.finditer(callform + r'([a-z0-9._-]+)', line):
            i, depth, close = m.start(), 0, len(line)
            # the `$(` this call sits inside, if any
            open_at = line.rfind("$(", 0, i)
            if open_at != -1:
                depth = 0
                for j in range(open_at + 1, len(line)):
                    if line[j] == "(":
                        depth += 1
                    elif line[j] == ")":
                        depth -= 1
                        if depth == 0:
                            close = j
                            break
            out.append((m.group(1), m.end(), close))
        return out

    calls, indirect = {}, set()
    for path in scripts:
        for line in joined_lines(path):
            if line.lstrip().startswith("#"):
                continue
            for m in re.finditer(callform + r'"?\$', line):
                indirect.update(re.findall(r'\b([A-Z_]+)=', line[m.end():]))
            regions = arg_regions(line)
            for k, _, _ in regions:
                calls.setdefault(k, set())
            for a in re.finditer(r'\b([A-Z_]+)=', line):
                owner = None
                for k, lo, hi in regions:
                    if lo <= a.start() < hi:
                        owner = k          # later entries are nested deeper; innermost wins
                if owner is not None:
                    calls[owner].add(a.group(1))

    who = os.path.basename(catalogue)
    for k, body in bodies.items():
        needed = set(re.findall(r"\{\{([A-Z_]+)\}\}", body))
        direct = k in calls
        given = calls.get(k, indirect)
        for p in sorted(needed - given):
            unsupplied.append("%s: %s needs {{%s}} but no call site supplies it" % (who, k, p))
        if direct:
            for p in sorted(given - needed):
                unused.append("%s: %s is passed %s= but has no {{%s}}" % (who, k, p, p))
print("UNSUPPLIED:" + "; ".join(unsupplied))
print("UNUSED:" + "; ".join(unused))
PY
assert_eq "placeholders:all-supplied" "UNSUPPLIED:" "$(grep '^UNSUPPLIED:' "$TMP/ph")"
assert_eq "placeholders:none-dead"    "UNUSED:"     "$(grep '^UNUSED:' "$TMP/ph")"

# ─── msg() substitution behaviour ──────────────────────────────────────────────
# The bug this catches: sed's replacement text cannot contain a newline, so a multi-line
# value made msg() emit "sed: unterminated `s' command" and then return NOTHING — so
# die() drew an empty red STOP box. err.create-failed passes raw podman output, which is
# always multi-line. This is the error a stuck student is most likely to see.
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
#
# err.create-failed again, because it is now the only message that interpolates raw podman
# output: err.pull-failed went with the pull path. Two messages used to share this duty and
# each was exercised once; one message exercised twice covers the same substitution code.
nasty='trouble with A&B and a|pipe and a\backslash and /slash and {{OUT}} literal'
out="$(msg err.create-failed OUT="$nasty" 2>&1)"
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

# ─── the staff-note rule msg() learned from txt()  (#221) ──────────────────────
# A `#` AT COLUMN 0 INSIDE A BODY IS A NOTE TO STAFF AND IS NEVER PRINTED. install-cs193v.sh's
# txt() has done this since #116, and it is the one thing txt() did that msg() did not; the
# split gives msg() the installer's catalogue to read, so it has to do it too.
#
# INDENTED IS DIFFERENT, deliberately, and that is the whole of the rule: a student-facing line
# beginning with a hash is written with a leading space. Both halves are asserted, because a
# rule that dropped every hash would silently eat prose.
msgtmp="$TMP/msg-hash.txt"
{ printf '[[hash.note]]\n'
  printf '  visible before\n'
  printf '# INVISIBLE staff note\n'
  printf '  visible after\n'
  printf '[[hash.indented]]\n'
  printf '   # an indented hash is prose\n'
  printf '[[hash.only]]\n'
  printf '# nothing but a note\n'
} > "$msgtmp"
out="$(MESSAGES="$msgtmp" msg hash.note)"
assert_contains     "msg:a-staff-note-keeps-the-prose-before" "visible before" "$out"
assert_contains     "msg:a-staff-note-keeps-the-prose-after"  "visible after"  "$out"
assert_not_contains "msg:a-column-0-hash-is-a-staff-note"     "INVISIBLE"      "$out"
assert_contains     "msg:an-indented-hash-still-prints"       "an indented hash is prose" \
                    "$(MESSAGES="$msgtmp" msg hash.indented)"
# AND A BODY THAT IS NOTHING BUT NOTES READS AS MISSING, which is why the reconciliation below
# has to count it as empty: it renders as "(missing message: k)" in front of a student.
assert_contains "msg:a-body-of-only-notes-reads-as-missing" "missing message" \
                "$(MESSAGES="$msgtmp" msg hash.only 2>&1)"

# ─── the presentation knobs  (#221) ───────────────────────────────────────────
# THE WHOLE SHARED FILE, not just the msg() carving above: these exercise note(), die()
# and menu(), and sourcing this file is inert by contract (see its header), which is the
# only reason it is safe to pull in beside a suite that has an EXIT trap of its own.
# shellcheck disable=SC1090
. "$UI"
# The installer draws inside an indented step list, so its note/die/menu sit two columns
# deeper and its die() carries a sign-off. Those were three hand-maintained differences
# between two copies of the same functions; they are three variables now, and the defaults
# are exactly what the launcher and setup-git printed before.
# SC2034 ON EVERY KNOB ASSIGNMENT BELOW: each is read by note(), die() or menu() in the
# file sourced above, which shellcheck does not follow from here. Named rather than
# blanket-disabled, so a genuinely unused variable in this suite still gets flagged.
# shellcheck disable=SC2034
# NO OVERRIDE HERE, deliberately: this asserts the value cs193v-ui.sh ships, so setting it
# first would test the assignment in this file instead. Mutation-tested -- changing the
# default in the shared file turns this red.
assert_eq "knob:note-defaults-to-no-indent" "plain" "$(note plain)"
# shellcheck disable=SC2034
assert_eq "knob:note-honours-NOTE_INDENT"   "    plain" "$(NOTE_INDENT='    '; note plain)"
# die() exits, so it is driven in a subshell and its box is read back.
# shellcheck disable=SC2034
# AGAIN NO OVERRIDE: the shipped defaults are what is under test.
dout="$( (die 'a refusal') 2>&1 )"
assert_contains     "knob:die-draws-its-box"          "a refusal"      "$dout"
# THE BOX IS THE LAST THING, which is a stronger claim than "one particular sentence is
# absent" -- mutation-tested: setting the default to any trailer at all turns this red.
assert_eq "knob:die-trailer-defaults-empty" "yes" "$(printf %s "$dout" | grep -v '^[[:space:]]*$' | tail -1 | grep -qF '┗' && echo yes || echo no)"
# shellcheck disable=SC2034
dout="$( (DIE_INDENT='  '; DIE_TRAILER='please ask course staff'; die 'a refusal') 2>&1 )"
assert_contains "knob:die-honours-DIE_TRAILER" "please ask course staff" "$dout"
assert_eq "knob:die-honours-DIE_INDENT" "yes" \
          "$(printf '%s\n' "$dout" | awk '/┏/{print (/^  ┏/) ? "yes" : "no"; exit}')"
# menu()'s non-tty arm is the one reachable without a pty, and it carries the same indent.
# THE HINT ONLY PRINTS ON THE TTY PATH, which needs a pty this suite does not have -- so
# the DECLARED VALUE is asserted instead, the way box:ui-declares-the-same-width pins
# BOX_W. The behavioural half lives in 25-installer.sh, which drives menu through a pty.
assert_eq "knob:menu-hint-declares-the-arrow-key-sentence" \
          "(use the up and down arrow keys, then press Enter)" "$MENU_HINT"
assert_eq "knob:menu-defaults-to-two-columns" '  (not a terminal; choosing "go")' \
          "$(menu 0 go stop </dev/null)"
# shellcheck disable=SC2034
assert_eq "knob:menu-honours-MENU_INDENT" "    (not a terminal; choosing \"go\")" \
          "$(MENU_INDENT='    '; menu 0 go stop </dev/null)"

# ─── every message fits the STOP box ───────────────────────────────────────────
# die() draws a fixed-width box and does not wrap, so a body line wider than the box
# overflows past the border on every error. The width is read from cs193v-ui.sh, where
# box() now lives, rather than hardcoded — so widening the box is a legitimate way to make
# this pass.
#
# Widths MUST be measured in display columns, not bytes. Ubuntu's awk is mawk, which is
# not multibyte-aware: `length()` on the box border returns 207 rather than 69, because
# every ━ is three bytes. An earlier version of this check used awk and passed vacuously.
# The box borders and the messages both contain plenty of non-ASCII, so python3 does the
# measuring. require_python3 is at the top of the file, above the first check that needs it.
python3 - "$REPO" "$PRIVATE" <<'PY' > "$TMP/width"
import re, sys, os
repo, private = sys.argv[1], sys.argv[2]
ui = open(os.path.join(private, "files", "cs193v-ui.sh")).read()

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
# Read from cs193v-ui.sh's BOX_W rather than by measuring a border literal: die() now
# generates its borders from that number, so there is no longer a hand-typed ┗━━┛ to
# measure — which is the point of it. The literal is still accepted as a fallback so this
# lint does not quietly go vacuous if the box is ever drawn by hand again.
m = re.search(r"^BOX_W=(\d+)", ui, re.M)
if m:
    box = int(m.group(1))
else:
    m = re.search(r"┗━+┛", ui)
    if not m:
        print("BOX:none"); sys.exit(0)
    box = len(m.group(0))
print("BOX:%d" % box)
limit = box - 4

# Only messages that end up INSIDE a box are held to the box width. The rest of status.*,
# prompt.*, opt.*, warn.* and help.usage are printed plainly by info/warn/printf and are
# under no such constraint, so holding them to it would be a made-up rule.
#
# TWO ROUTES INTO A BOX, not one. `die "$(msg k)"` was the only one until the build grew a
# success box (issue #22), which reaches it as `msg k | celebrate`. Matching only the die
# form left the new message unlinted, and it went in three columns too wide and wrapped
# mid-sentence -- "Run the following command to enter the / development environment:" --
# which is precisely what this lint exists to prevent. Any new way of reaching box() needs
# a pattern here.
# ─── one catalogue at a time, with the script that reads it ───────────────────
# PAIRED, NOT POOLED, and this arm was VACUOUS until #221. course-install.sh has been in the
# scan list for a while, but the installer's accessor was `txt` and this pattern matches `msg`,
# so it contributed no keys at all -- and the loop below only ever measured messages.txt, so the
# installer's boxed prose was unmeasured from both ends at once. Now the installer reads its own
# catalogue with msg(), so each catalogue is measured against the keys the script that reads it
# actually boxes.
#
# PER-CATALOGUE RATHER THAN ONE SET, even though 10-static.sh now forbids the two files sharing
# a key name: pooling would mean a key boxed by one script silently imposes the box width on a
# same-named key in the other, which is the coupling that rule exists to prevent.
PAIRS = (
    (os.path.join(private, "messages.txt"), (os.path.join(repo, "cs193v"),)),
    (os.path.join(private, "course-install-messages.txt"),
     (os.path.join(private, "course-install.sh"),)),
)

all_boxed = set()
for catalogue, scripts in PAIRS:
    boxed = set()
    for path in scripts:
        for line in open(path):
            boxed.update(re.findall(r'die\s+"\$\(msg\s+([a-z0-9._-]+)', line))
            boxed.update(re.findall(r'msg\s+([a-z0-9._-]+)\s*\|\s*(?:celebrate|box)\b', line))
    all_boxed |= boxed

    key = None
    for line in open(catalogue).read().splitlines():
        km = re.match(r"^\[\[([a-z0-9._-]+)\]\]$", line)
        if km:
            key = km.group(1); continue
        # A COLUMN-0 HASH IS A STAFF NOTE AND IS NEVER PRINTED, so its width is nobody's
        # business. msg() drops these; measuring them would hold maintainer prose to a box a
        # student never sees it in -- and the installer's catalogue is mostly notes.
        if line.startswith("#"):
            continue
        if not key or len(line) <= limit:
            continue
        if key in boxed:
            print("LONG:%s: %d cols (limit %d): %s" % (key, len(line), limit, line))
        elif len(line) > 80:
            # Not a failure — nothing draws a border around these. Recorded because an
            # 80-column terminal still soft-wraps them, which is a wording call, not a bug.
            print("WIDE:%s: %d cols" % (key, len(line)))
print("BOXED:%s" % ",".join(sorted(all_boxed)))
# THE LAST LINE THIS PROGRAM PRINTS, and it is the only thing standing between the three checks
# below and a vacuous green. Every one of them reads this file for a line that is there only when
# something is WRONG -- `grep '^LONG:'`, `grep -c '^WIDE:'` -- so a lint that stopped early leaves
# the happy answer behind. Measured (#79): a `raise SystemExit` injected immediately after the
# BOXED line above left box:no-message-line-overflows passing and the whole suite reporting 0
# fail, with not one catalogue line having been measured.
#
# No interpreter poison can forge it either, which is why it is this rather than a marker file:
# an interpreter that prints something else prints something that is not WIDTHS-OK.
print("WIDTHS-OK")
PY
assert_contains "box:the-width-lint-ran-to-completion" "WIDTHS-OK" "$(cat "$TMP/width")"
BOXW="$(sed -n 's/^BOX:\(.*\)/\1/p' "$TMP/width")"
if [ "$BOXW" != none ] && [ "${BOXW:-0}" -gt 20 ]; then
    pass "box:width-detected"
    record "box:width" "$BOXW columns, so message lines may be up to $((BOXW - 4))"
else
    fail "box:width-detected" "could not read the STOP box width from cs193v"
fi

record "box:messages-drawn-in-a-box" \
       "$(sed -n 's/^BOXED://p' "$TMP/width" | do_tr ',' ' ')"

# ─── setup-git's boxed messages ────────────────────────────────────────────────
# NO EMPHASIS MARKUP IN ANYTHING THAT GOES IN A BOX. setup-git renders *asterisks* as colour AFTER
# box() has counted the columns, so a boxed message carrying a pair would come out two columns
# narrow with the right wall bent in. Which messages those are is DERIVED from the script rather
# than listed here, so a new one routed into the box is covered the day it is written.
#
# Down here rather than beside the other sgkeys checks because the width half needs $BOXW, which is
# read out of the helper just above.
#
# THREE FORMS, AND TWO PASSES OVER THE FILE. `box ... msg K` and `msg K | box` were the only ways in
# until issue #54 gave the staff box a message with ARGUMENTS -- `msg K "CMD=..." | box "$(msg
# title.error)"` -- which neither pattern matches, so the new key would have gone in unlinted. The
# third form cannot simply join the alternation: one match per position means the longest of them
# would swallow `... | box "$(msg title.error)"` whole and drop title.error from the set. Two
# independent greps let one line answer to both.
for k in $( { grep -oE '(celebrate|box) [^|]*msg [a-z0-9._-]+' "$SGS"
              grep -oE 'msg [a-z0-9._-]+[^|]*\|[[:space:]]*(celebrate|box)' "$SGS"; } \
            | grep -oE 'msg [a-z0-9._-]+' | awk '{print $2}' | LC_ALL=C sort -u); do
    body="$(sed -n "/^\[\[$k\]\]$/,/^\[\[/p" "$SGM" | grep -v '^\[\[')"
    assert_ne "sgkeys:$k-was-found" "" "$body"
    assert_not_contains "sgkeys:$k-has-no-markup" "*" "$body"
    # And it has to FIT, for the same reason every boxed message in messages.txt does: box() wraps
    # rather than spills, so an over-wide line is not a broken box any more — it is a line whose
    # breaks nobody chose, in the message a stuck student is reading. Measured in display columns
    # by python3, because mawk would score a — at 3× and pass vacuously.
    # run_checker for the reason the catalogue lint above carries it: `assert_eq NAME ""` is
    # satisfied by a checker that printed nothing at all. These four were the rest of #79's
    # residue.
    wide="$(printf '%s\n' "$body" | run_checker python3 -c '
import sys
lim = int(sys.argv[1]) - 4
for line in sys.stdin.read().splitlines():
    if len(line) > lim:
        print("%d columns: %s" % (len(line), line))
' "$BOXW")"
    assert_eq "sgkeys:$k-fits-the-box" "" "$wide"
done

long="$(grep '^LONG:' "$TMP/width" | sed 's/^LONG://')"
if [ -z "$long" ]; then
    pass "box:no-message-line-overflows"
else
    fail "box:no-message-line-overflows" "$(printf '%s\n' "$long" | head -14)
$(printf '%s\n' "$long" | wc -l | do_tr -d ' ') line(s) overflow the box"
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
# mawk's length() would score the border at 3× and pass vacuously. The checker itself is
# box_problems() in lib/assert.sh, shared since the build's success box gave a second suite
# a box to check, and it answers with $CHECKER_DIED rather than with silence when it cannot run.

# There must be exactly one place that draws it. Before the fix there were four — die() in
# each script, plus the Intel-Mac refusal typed out as a heredoc, plus the launcher's own
# banner — and the two in install-cs193v.sh had already drifted a column apart from each
# other. Nobody could see that, because a box with no right edge has no width to disagree
# about. Box art typed out by hand anywhere but inside box() is that bug growing back.
#
# EVERY SCRIPT THAT DRAWS ONE IS LISTED, and adding a script means adding it here: box() lives
# in cs193v-ui.sh now, so the launcher and setup-git both reach the real one and neither has
# any business containing box art at all. The launcher still passes because its remaining
# glyphs are inside meter_tail_box's printf, which is the live box the build draws.
for boxsrc in "ui:$PRIVATE/files/cs193v-ui.sh" \
              "launcher:$REPO/cs193v" \
              "setup-git:$PRIVATE/files/setup-git" \
              "course-install:$PRIVATE/course-install.sh"; do
    who="${boxsrc%%:*}"; f="${boxsrc#*:}"
    # box() builds its borders inside an awk printf; anything else is hand-drawn art.
    #
    # Comments are exempt. The geometry needs explaining somewhere, and explaining it means
    # naming the characters -- "┏━━ is four columns" is documentation, not a second box. The
    # first version of this check had no such exemption and failed on its own comment.
    hand="$(grep -n '[┏┗┃]' "$f" | grep -v printf | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
    assert_eq "box:$who-draws-the-box-in-one-place" "" "$hand"
done

# ONE COPY OF box() SINCE #221, so there is nothing left to diff. The check that lived here
# compared cs193v-ui.sh's copy against install-cs193v.sh's, because a file downloaded on its own
# can source nothing; the installer downloads before it draws now, so course-install.sh sources
# the real one. box:course-install-draws-the-box-in-one-place above is what remains, and it is the
# assertion that would catch a copy coming back.
sed -n '/^box() {$/,/^}$/p' "$PRIVATE/files/cs193v-ui.sh" > "$TMP/box.cs193v-ui.sh"
if [ "$(wc -l < "$TMP/box.cs193v-ui.sh" | do_tr -d ' ')" -gt 20 ]; then
    pass "box:extractable"
else
    fail "box:extractable" "could not extract box() from cs193v-ui.sh"
fi
# ONE APIECE, not "the two counts agree". This compared `grep -c '^BOX_W=71$'` in one file
# against the same count in the other, and 0 == 0 is agreement: measured (#79), renaming BOX_W in
# BOTH files leaves this passing. What each side has to do is declare the width, so that is what
# is asked -- of each of them, separately.
# ONE FILE DECLARES IT NOW, and the assertion is still "declares it" rather than "the counts
# agree", for the reason #79 measured: 0 == 0 is agreement, so renaming BOX_W in both files left
# the old form passing.
assert_eq "box:ui-declares-the-width" "1" \
          "$(grep -c '^BOX_W=71$' "$PRIVATE/files/cs193v-ui.sh")"
# AND NOBODY ELSE DECLARES ONE, which is the half that catches a copy coming back rather than a
# rename going wrong.
assert_eq "box:course-install-declares-no-width" "0" \
          "$(grep -c '^BOX_W=' "$PRIVATE/course-install.sh")"
# And the launcher must not have kept a copy of its own on the way out, which a botched
# extraction would leave behind: two definitions in one file, the second silently winning.
assert_eq "box:launcher-has-no-copy" "0" "$(grep -c '^box() {$' "$REPO/cs193v")"

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
# Read by launcher() in lib/podman-shim.sh:93, which runs "${LAUNCHER_DIR:-$REPO}/cs193v".
# shellcheck disable=SC2034
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
# spill into the terminal. This is not hypothetical tidiness: err.create-failed
# interpolates raw podman output, which is written to no width at all, and
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

# ─── the installer proper draws the same box ───────────────────────────────────
# It is the student's FIRST contact with the course, so a broken box there is the first thing
# they ever see of it. Run for real rather than pattern-matched, the same way this suite treats
# msg().
#
# THE SHAPE CHANGED WITH #221 AND THE TEST IS STRONGER FOR IT. There used to be a second copy
# of box() and die() in the installer, and this harness assembled that copy; now it sources the
# SAME cs193v-ui.sh the launcher does and sets the same four knobs course-install.sh sets. So
# what this exercises is no longer "the other copy still works" but "the shared box, drawn at
# the installer's indent, with the installer's sign-off, still closes" -- which is the thing a
# student actually sees.
#
# AND THE CATALOGUE COMES AS A FILE NOW, not as a carved function. die()'s sign-off and the whole
# of the Intel-Mac refusal are entries in it, so the harness has to be able to READ it -- but
# since #221 that means pointing MESSAGES at course-install-messages.txt, exactly as
# course-install.sh does. There is no txt() and no text_catalogue() left to carve: cs193v-ui.sh's
# msg() is the reader, and it arrives with `cat "$UI"` above.
#
# WHICH MAKES THIS HARNESS A CLOSER MODEL OF THE REAL THING than the one it replaces. It used to
# assemble a private copy of the accessor AND a private copy of the prose; now the only thing it
# supplies that the product does not is NO_COLOR and the value of MESSAGES.
{
    printf 'NO_COLOR=1\n'
    printf 'MESSAGES="%s"\n' "$PRIVATE/course-install-messages.txt"
    cat "$UI"
    sed -n '/^say_intel_mac() {$/,/^}$/p'  "$PRIVATE/course-install.sh"
    # the four knobs, exactly as course-install.sh sets them after sourcing
    printf 'NOTE_INDENT="    "\nMENU_INDENT="    "\nDIE_INDENT="  "\n'
    printf 'DIE_TRAILER="$(msg die.trailer)"\n'
} > "$TMP/idie.sh"

if [ "$(grep -c '^die() {$' "$TMP/idie.sh")" = 1 ] &&
   [ "$(grep -c '^say_intel_mac() {$' "$TMP/idie.sh")" = 1 ] &&
   [ "$(grep -c '^msg() {$' "$TMP/idie.sh")" = 1 ] &&
   [ "$(grep -c '^MESSAGES=' "$TMP/idie.sh")" = 1 ]; then
    pass "installer:box-users-extractable"
else
    fail "installer:box-users-extractable" \
         "could not assemble cs193v-ui.sh with say_intel_mac() and the installer's catalogue"
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
