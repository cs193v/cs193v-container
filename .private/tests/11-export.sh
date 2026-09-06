#!/usr/bin/env bash
# TIER: static
#
# WHAT A STUDENT ACTUALLY DOWNLOADS (#115).
#
# This repo IS the ~/cs193v layout: install-cs193v.sh fetches GitHub's branch tarball and
# untars it into the course directory. GitHub builds that tarball with `git archive`, which
# honours .gitattributes' export-ignore -- so .gitattributes is the ONLY thing deciding what a
# student receives, and nothing here used to check it. The file set had grown to 108 files
# including the whole of this test suite, four staff-only documents and both installers.
#
# WHY THIS IS IN THE STATIC TIER AND NOT THE RELEASE TIER. The release tier is opt-in
# (--release/--all), so a staff document added mid-quarter would ship to every student while a
# normal green run said nothing. The one check that genuinely needs the network -- does GitHub
# really honour export-ignore -- is in 00-release-gates.sh, where the other live calls are.
#
# EVERY ASSERTION HERE IS OVER THE STAGED WORKING TREE, not HEAD, so editing .gitattributes
# turns this red or green immediately rather than after a commit. See export_tree in
# lib/assert.sh for how that is done without writing to the developer's repository.

set -u
. "$(dirname -- "$0")/lib/assert.sh"

cd "$REPO" || exit 1

require_cmd git "the student's file set is built with git archive, the way GitHub builds it"

TMP="$(new_tmpdir)"
trap 'rm -rf "$TMP"' EXIT

# ─── stage it once ─────────────────────────────────────────────────────────────
# MATERIALISED RATHER THAN LISTED, because the size assertion below needs the bytes and a second
# staging would be a second chance to disagree with the first.
TREE="$TMP/tree"
if export_tree "$TREE"; then
    pass "export:staging-succeeds"
else
    fail "export:staging-succeeds" "export_tree could not build the student tree"
    exit 1
fi
( cd "$TREE" && find . -type f | sed 's|^\./||' | LC_ALL=C sort ) > "$TMP/paths"

# A ZERO IS A FAILURE, NOT A PASS. Every equality below would be satisfied by an empty listing
# in one direction or another, so the count is asserted before anything reads it -- the same
# reason 14-test-harness.sh:104-111 refuses a zero from `du`.
n_paths="$(grep -c '' "$TMP/paths" | do_tr -d ' ')"
if [ "${n_paths:-0}" -gt 10 ]; then
    pass "export:staging-produced-a-tree"
else
    fail "export:staging-produced-a-tree" "the staged tree holds ${n_paths:-no} files"
    exit 1
fi
record "export:file-count" "$n_paths"

# ─── 1. the whole listing, as one equality ─────────────────────────────────────
# .private/files/ IS EXCLUDED FROM THIS LINE and covered by §3 instead. Everything under files/
# ships by definition -- it is the only COPY in the Containerfile and build_hash hashes the whole
# tree -- so listing its 24 names here would mean editing this suite every time somebody adds an
# image file, for an edit that carries no decision. What is left is the five paths where adding
# or removing one IS a decision.
want=".config/container.args .private/Containerfile .private/messages.txt cs193v projects/.gitkeep"
got="$(grep -v '^\.private/files/' "$TMP/paths" | do_tr '\n' ' ' | sed 's/ *$//')"
assert_eq "export:is-the-student-tree-and-nothing-more" "$want" "$got"

# ─── 2. what the installer itself insists on ───────────────────────────────────
# READ OUT OF THE INSTALLER rather than repeated here: fetch_files checks these four after
# untarring and dies naming the missing one, so they are its own definition of a usable
# download. A copy of the list here could drift from the list that actually gates an install.
sentinels="$(sed -n 's/^ *for f in \(cs193v .*\); do$/\1/p' "$PRIVATE/install-cs193v.sh" | head -1)"
n_sent="$(printf '%s\n' $sentinels | grep -c '' | do_tr -d ' ')"
assert_eq "export:installer-sentinel-list-was-parsed" "4" "$n_sent"
missing=''
for f in $sentinels; do
    grep -qx "$f" "$TMP/paths" || missing="$missing $f"
done
assert_eq "export:installer-sentinels-survive" "" "$(printf '%s' "$missing" | sed 's/^ *//')"

# ─── 3. everything the image is built from ─────────────────────────────────────
# Containerfile:590 `COPY files/ /tmp/cs193v-files/` is the only COPY, and build_hash hashes
# Containerfile plus every file under files/ BY NAME AND CONTENT on every launch. So a partial
# export is two failures at once: a build that cannot install what it needs, and a staleness
# fingerprint that disagrees with staff's.
#
# THIS IS THE ASSERTION THAT CATCHES THE .gitattributes MISTAKE. The allowlist needs BOTH
# `/.private/files -export-ignore` and `/.private/files/** -export-ignore`; with either one alone
# -- measured -- the archive contains NO files/ at all, which means no files/cs193v-ui.sh, which
# means ./cs193v exits 1 at line 145 on every invocation including --help.
absent=''
for f in $(git ls-files '.private/files/*'); do
    grep -qx "$f" "$TMP/paths" || absent="$absent $f"
done
assert_eq "export:every-COPY-input-survives" "" "$(printf '%s' "$absent" | sed 's/^ *//')"

# ─── 4. and the reasons, so a failure explains itself ──────────────────────────
# §1 already fails if any of these appear, but it fails as a diff. These name the mistake.
assert_eq "export:no-test-suite"  "" "$(grep '^\.private/tests/' "$TMP/paths" | do_tr '\n' ' ' | sed 's/ *$//')"
assert_eq "export:no-installers"  "" "$(grep 'install-cs193v'    "$TMP/paths" | do_tr '\n' ' ' | sed 's/ *$//')"
# agent-notes.md is the one .md that ships: Containerfile:803 installs it as
# /etc/cs193v/agent-notes.md and /etc/claude-code/CLAUDE.md is a symlink to it, so both agents
# read the same text. Every other .md in this repo is written for staff.
assert_eq "export:no-staff-docs" "" \
          "$(grep '\.md$' "$TMP/paths" | grep -v '^\.private/files/agent-notes\.md$' \
             | do_tr '\n' ' ' | sed 's/ *$//')"

# ─── 4b. the size, not just the names ──────────────────────────────────────────
# The listing above is the leak we know about; this is the one that catches whatever lands in
# the course directory next -- 14-test-harness.sh:104-111 makes the same argument for its own
# copy. A zero is a failure rather than a pass, because that is what `du` on a missing directory
# reports.
#
# WHAT THE CEILING IS AND IS NOT FOR, because 636 KB against 1 MB is not a lot of room. It is
# for a BULK leak: the test tree alone is 2.2 MB, so re-shipping it breaches this by more than
# double. It would NOT catch the four staff documents coming back -- they are about 200 KB
# together -- and it does not need to, because §1 and §4 name that class directly. Raise it if
# files/ genuinely grows; do not raise it to make a surprise go away without reading §1 first.
size_kb="$(du -sk "$TREE" 2>/dev/null | awk '{print $1}')"
if [ -n "${size_kb:-}" ] && [ "$size_kb" -gt 0 ] && [ "$size_kb" -lt 1024 ]; then
    pass "export:is-small"
else
    fail "export:is-small" "du reports ${size_kb:-nothing} KB for the student tree"
fi
record "export:size-kb" "${size_kb:-nothing}"

# ─── 5. no message names a file the student does not have ──────────────────────
# THE CHECK THAT WOULD HAVE CAUGHT #115's OWN COLLATERAL BY ITSELF. err.no-subuid used to tell a
# student to run `bash .private/install-cs193v.sh`, and that was the only .private/ path in the
# whole catalogue -- so export-ignoring the installer would have left a message pointing at a
# file that is not there, with nothing to notice.
#
# SELF-TESTED, because it has nothing to find. After #115 the catalogue names no repo-relative
# path at all, so the audit passes without measuring anything unless the extractor is shown to
# work -- which is the shape issue #79 swept the suite for. The planted case runs first.
messages_absent_paths() {             # messages_absent_paths FILE LIST -> one line per bad path
    local f="$1" list="$2" p
    for p in $(grep -oE '\.(private|config)/[A-Za-z0-9._/-]+' "$f" | LC_ALL=C sort -u); do
        grep -qx "$p" "$list" || printf 'names a path absent from the archive: %s\n' "$p"
    done
}
# A slash is required after the directory name, which is what keeps this off the prose at
# messages.txt:320 ("the .config folder next to this script") -- verified, it does not match.
printf 'Run the course installer again:\n\n    bash .private/tests/nope.sh\n' > "$TMP/planted"
assert_says "export:path-audit-finds-a-planted-path" ".private/tests/nope.sh" \
            "$(run_checker messages_absent_paths "$TMP/planted" "$TMP/paths")"
assert_eq   "export:messages-name-no-absent-path" "" \
            "$(run_checker messages_absent_paths "$PRIVATE/messages.txt" "$TMP/paths")"

# ─── 6. nothing untracked would reach a student ────────────────────────────────
# The fixture is built with `add -u`, so an untracked file can never enter it and can never make
# it lie. The cost is that a file you have created but not `git add`ed is INVISIBLE to every
# fixture in the suite -- silently, which is the one foot-gun that staging choice buys. This is
# what makes it loud instead.
#
# `add -A` is the second opinion: the same tree with untracked files folded in. The difference is
# exactly the set of paths that are in your working tree AND would reach a student AND are not in
# git. Deriving the scope this way rather than naming "the directories that ship" means it tracks
# .gitattributes automatically -- scratch under .private/ is already swallowed by the allowlist,
# so it is correctly silent about it.
#
# ONE DIRECTION ONLY, and see _stage_tree's header for why the other one cannot fire.
#
# LC_ALL=C ON comm AS WELL AS ON sort. Under en_US.UTF-8 comm and sort disagree about how to order
# punctuation, and comm then mis-pairs silently and reports differences that are not there --
# measured while writing this, on this listing.
would_ship_paths > "$TMP/would-ship" || true
untracked="$(LC_ALL=C comm -13 "$TMP/paths" "$TMP/would-ship" | do_tr '\n' ' ' | sed 's/ *$//')"
if [ -z "$untracked" ]; then
    pass "export:no-untracked-would-ship"
else
    fail "export:no-untracked-would-ship" \
         "these are in your working tree and WOULD reach a student, but are not in git -- so they
are not in any fixture either. \`git add\` them, or add them to .gitignore:
    $untracked"
fi
