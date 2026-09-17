#!/usr/bin/env bash
# TIER: unit
#
# .private/release.sh, driven against a throwaway repository. No podman, no network (#232).
#
# WHY A THROWAWAY REPO AND NOT THIS ONE. release.sh REWRITES TRACKED FILES -- the version, the tag
# and two digests, in three files -- and stages one of them. Driving it against the checkout would
# leave a developer's tree carrying a release they did not cut, which is the one thing a test may
# never do. So every case runs in a copy with its own .git, built from the working tree so that
# what is tested is the script as it stands rather than as it was committed.
#
# NO ORIGIN IN THE COPY, DELIBERATELY. `git ls-remote --tags origin` fails there, which release.sh
# reads as "not published" -- the same answer it gets from an unreachable network, and the reason
# this suite needs none.
#
# WHAT IS WORTH TESTING HERE IS THE REFUSALS. The happy path is one case, because everything it
# produces is checked again by the assertions the release itself has to satisfy: pin:* in
# 10-static.sh reads the constants back, and --release compares them against what GitHub serves.
# The refusals are the opposite -- each one exists because publishing past it would be expensive
# and hard to undo, and none of them is reachable any other way.

set -u
. "$(dirname -- "$0")/lib/assert.sh"

cd "$REPO" || exit 1

require_cmd git "release.sh refuses a dirty tree and stages a file, so its cases need a real repo"

TMP="$(new_tmpdir)"
trap 'rm -rf "$TMP"' EXIT
CASE="$TMP/repo"

# BUILT ONCE AND RESET PER CASE, because copying the tree is the expensive part and `git checkout`
# plus `git clean` puts it back exactly. projects/ is excluded for the reason lib/assert.sh gives
# about a developer's own 57 MB of it; .git is excluded because the copy gets one of its own.
gitq() { git -C "$CASE" -c user.name=t -c user.email=t@example.invalid "$@"; }
build_case() {
    rm -rf "$CASE"; mkdir -p "$CASE"
    ( cd "$REPO" && tar -c --exclude=.git --exclude=projects . ) | ( cd "$CASE" && tar -x )
    gitq init -q .
    gitq add -A . >/dev/null 2>&1
    gitq commit -qm seed >/dev/null 2>&1
}
# BACK TO THE SEED COMMIT, NOT TO HEAD, AND NOT `checkout -- .`. Three separate things went wrong
# here in one run, each of which left a later case failing on the wrong refusal:
#
#   * `checkout -- .` restores only what the INDEX lists, so after a case ran `git rm --cached`
#     the file stayed deleted and the next case wrote it back as UNTRACKED.
#   * `reset --hard HEAD` restores whatever the last case COMMITTED. Several of them commit, so
#     HEAD is not the tree this suite started from -- a case that committed 9.9.9 left the next
#     one reading 9.9.9 and refusing for a reason it was not testing.
#   * tags survive both, so a case that created release-0.0.1 left it lying in front of every
#     case after it.
#
# So: reset to the recorded seed, clean, and drop every release tag. Worth the three lines --
# every one of those failures LOOKED like a defect in release.sh.
reset_case() {
    gitq reset -q --hard "$SEED" 2>/dev/null
    gitq clean -qfd 2>/dev/null
    for t in $(gitq tag -l 'release-*' 2>/dev/null); do
        gitq tag -d "$t" >/dev/null 2>&1
    done
}
rel() {                               # rel ARGS... -> combined output; status in $TMP/rc
    # SNAPSHOTTED FIRST, so assert_unwritten below compares against what the CASE arranged rather
    # than against a literal. The version-skew case writes 9.9.9 into VERSION on purpose, and a
    # check that expected 0.0.0 would call that a write by release.sh.
    cat "$CASE/.private/VERSION" > "$TMP/version.before" 2>/dev/null || : > "$TMP/version.before"
    sget REPO_TAG > "$TMP/tag.before"
    ( cd "$CASE" && .private/release.sh "$@" 2>&1 )
    printf '%s' "$?" > "$TMP/rc"
}
rel_rc() { cat "$TMP/rc"; }
cget() {                              # cget NAME -> the .cmd's value for it
    sed 's/\r$//' "$CASE/.private/install-cs193v-windows.cmd" \
        | sed -n "s/^set \"$1=\(.*\)\"\$/\1/p" | head -1
}
sget() {                              # sget NAME -> the .sh's value for it
    sed -n "s/^$1=\"\([^\"]*\)\".*/\1/p" "$CASE/.private/install-cs193v.sh" | head -1
}

# ─── and the promise every refusal makes ───────────────────────────────────────
# NOTHING IS WRITTEN BEFORE A REFUSAL, which is the whole reason release.sh has no --dry-run: a
# run that refuses is already side-effect-free, so there is no half-cut release to unpick. That is
# a claim about ORDER, and order is what an exit status cannot see.
#
# WRITTEN AFTER A MUTATION TEST FOUND THE GAP. Inverting the symlink refusal left
# release:a-symlink-in-the-export-is-refused green: with that check gone, the BOOTSTRAP refused
# the same tree one step later, when the manifest could not be computed -- by which point
# .private/VERSION had already been rewritten. The rc was still 1, so an rc-only assertion could
# not tell the two apart, and the case that was supposed to be about release.sh's guard was
# passing on somebody else's.
assert_unwritten() {                  # assert_unwritten NAME
    if [ "$(cat "$CASE/.private/VERSION" 2>/dev/null)" = "$(cat "$TMP/version.before")" ] \
       && [ "$(sget REPO_TAG)" = "$(cat "$TMP/tag.before")" ]; then
        pass "$1"
    else
        fail "$1" "a refusal changed the tree. VERSION was \
'$(cat "$TMP/version.before")' and is now '$(cat "$CASE/.private/VERSION" 2>/dev/null)';
REPO_TAG was '$(cat "$TMP/tag.before")' and is now '$(sget REPO_TAG)'.
Every refusal must run before anything is written."
    fi
}

build_case
SEED="$(gitq rev-parse HEAD 2>/dev/null)"
if [ -n "$SEED" ]; then
    pass "release:the-throwaway-repo-was-built"
else
    fail "release:the-throwaway-repo-was-built" "could not build a git repo from the working tree"
    exit 1
fi

# ─── the argument surface ──────────────────────────────────────────────────────
out="$(rel)"
assert_eq   "release:no-flag-is-refused" "1" "$(rel_rc)"
assert_says "release:no-flag-says-which-flags" "--major, --minor or --patch" "$out"
out="$(rel --oops)"
assert_eq   "release:an-unknown-flag-is-refused" "1" "$(rel_rc)"
out="$(rel --patch --minor)"
assert_eq   "release:a-second-argument-is-refused" "1" "$(rel_rc)"

# ─── the happy path, and then every number checked independently ───────────────
# THE ONE CASE THAT WRITES. Everything it produced is recomputed below from the tree it left
# behind, rather than compared against what the script printed -- a script that printed one digest
# and wrote another would pass any assertion made on its output alone.
reset_case
out="$(rel --patch)"
assert_eq   "release:a-clean-tree-cuts-a-release" "0" "$(rel_rc)"
assert_says "release:it-names-the-new-version" "0.0.0 -> 0.0.1" "$out"
assert_says "release:it-says-nothing-was-committed" "Nothing has been committed" "$out"
assert_says "release:it-prints-the-commit-command" "git commit -a" "$out"
assert_says "release:it-prints-the-tag-command" "git tag release-0.0.1" "$out"
assert_says "release:it-insists-on-the-release-gates" "run-tests.sh --release" "$out"
assert_says "release:it-names-both-files-for-the-website" "install-cs193v-windows-0.0.1.cmd" "$out"
assert_eq   "release:the-version-file-was-written" "0.0.1" "$(cat "$CASE/.private/VERSION")"
assert_eq   "release:the-sh-names-the-new-tag"  "release-0.0.1" "$(sget REPO_TAG)"
assert_eq   "release:the-cmd-names-the-new-tag" "release-0.0.1" "$(cget REPO_TAG)"
# RECOMPUTED, NOT READ BACK. The payload digest has to equal what the bootstrap makes of the
# tree the release describes, and the stage-two digest has to equal the STAGED BLOB -- not the
# working copy, because the blob is what raw.githubusercontent.com serves.
# REPO="$CASE" SPELLED OUT, for the reason release.sh now spells it out too: lib/assert.sh
# EXPORTS $REPO, and export-tree.sh prefers a caller's -- so an inner shell that said nothing
# would stage the real checkout and this assertion would compare the copy's constant against the
# outer repository's manifest. It failed exactly that way once.
rm -rf "$TMP/tree"; mkdir -p "$TMP/tree"
( cd "$CASE" && REPO="$CASE" bash -c '. .private/lib/export-tree.sh && export_tree "$1"' _ "$TMP/tree" )
assert_eq "release:the-payload-digest-is-the-manifest-of-what-ships" \
          "$(bash "$CASE/.private/install-cs193v.sh" --dev-manifest-hash "$TMP/tree")" \
          "$(sget PAYLOAD_SHA256)"
assert_eq "release:the-stage2-digest-is-the-staged-blob" \
          "$(gitq cat-file blob :.private/install-cs193v.sh | do_sha256 | awk '{print $1}')" \
          "$(cget STAGE2_SHA256)"
# AND THE .cmd IS STILL CRLF, which is not a tidiness check: cmd.exe's label scanner assumes a
# two-byte terminator, so a rewrite that ate one carriage return makes `goto` fail by byte offset.
# A `.*` to end-of-line in either sed would have done exactly that.
assert_eq "release:the-cmd-keeps-its-crlf" \
          "$(grep -c '' "$CASE/.private/install-cs193v-windows.cmd")" \
          "$(grep -c $'\r$' "$CASE/.private/install-cs193v-windows.cmd")"

# ─── and every refusal, each of which exists because publishing past it is costly ──
reset_case
printf 'stray\n' >> "$CASE/cs193v"
out="$(rel --patch)"
assert_eq   "release:a-modified-tree-is-refused" "1" "$(rel_rc)"
assert_unwritten "release:a-modified-tree-writes-nothing"
assert_says "release:that-refusal-names-the-file" "cs193v" "$out"

# AN UNTRACKED FILE COUNTS AS DIRTY, and that is the half worth its own case: the manifest
# describes what is about to be COMMITTED, so a file nobody has `git add`ed must not be hashed
# into it -- and `git status --porcelain` is what sees those, as `??`.
reset_case
printf 'x\n' > "$CASE/.private/files/stray-new-file"
out="$(rel --patch)"
assert_eq   "release:an-untracked-file-is-refused" "1" "$(rel_rc)"
assert_unwritten "release:an-untracked-file-writes-nothing"
assert_says "release:that-refusal-mentions-the-tree" "working tree is not clean" "$out"

reset_case
gitq rm -q --cached .private/VERSION >/dev/null 2>&1
out="$(rel --patch)"
assert_eq   "release:an-untracked-version-is-refused" "1" "$(rel_rc)"
assert_unwritten "release:an-untracked-version-writes-nothing"
assert_says "release:that-refusal-says-to-add-it" "not tracked by git" "$out"

reset_case
printf 'one point two\n' > "$CASE/.private/VERSION"
gitq commit -qam version >/dev/null 2>&1
out="$(rel --patch)"
assert_eq   "release:a-malformed-version-is-refused" "1" "$(rel_rc)"
assert_says "release:that-refusal-quotes-what-it-read" "one point two" "$out"

reset_case
printf '9.9.9\n' > "$CASE/.private/VERSION"
gitq commit -qam skew >/dev/null 2>&1
out="$(rel --patch)"
assert_eq   "release:a-tag-that-disagrees-with-version-is-refused" "1" "$(rel_rc)"
assert_unwritten "release:a-version-skew-writes-nothing"
assert_says "release:that-refusal-shows-both" "disagree" "$out"

reset_case
gitq tag release-0.0.1
out="$(rel --patch)"
assert_eq   "release:an-existing-tag-is-refused" "1" "$(rel_rc)"
assert_unwritten "release:an-existing-tag-writes-nothing"
assert_says "release:that-refusal-names-the-tag" "release-0.0.1 already exists" "$out"

# A CR IN THE BOOTSTRAP. The .gitattributes rule makes a CHECKOUT LF everywhere; it cannot fix an
# editor that saved CRLF, and it is the working copy that gets hashed. Publishing past this gives
# every Windows student a digest they cannot match.
reset_case
printf 'x\r\n' >> "$CASE/.private/install-cs193v.sh"
gitq commit -qam crlf >/dev/null 2>&1
out="$(rel --patch)"
assert_eq   "release:a-carriage-return-in-the-bootstrap-is-refused" "1" "$(rel_rc)"
assert_unwritten "release:a-carriage-return-writes-nothing"
assert_says "release:that-refusal-explains-the-blob" "raw.githubusercontent.com" "$out"

# A SYMLINK IN WHAT WOULD SHIP. `find -type f` skips one, so it would travel OUTSIDE the verified
# content -- the whole reason the manifest refuses rather than describes it.
reset_case
ln -s /etc/passwd "$CASE/.private/files/link-to-somewhere"
gitq add -A . >/dev/null 2>&1
gitq commit -qam symlink >/dev/null 2>&1
out="$(rel --patch)"
assert_eq   "release:a-symlink-in-the-export-is-refused" "1" "$(rel_rc)"
assert_unwritten "release:a-symlink-writes-nothing"
assert_says "release:that-refusal-names-the-symlink" "link-to-somewhere" "$out"

# AN EXPORT SET THAT CANNOT BE RIGHT, following 11-export.sh's own size guard: a .gitattributes
# mistake that excluded everything would otherwise publish the digest of almost nothing, and every
# comparison downstream is satisfied by an empty tree in one direction or the other.
reset_case
printf '* export-ignore\n' > "$CASE/.gitattributes"
gitq commit -qam ignore-everything >/dev/null 2>&1
out="$(rel --patch)"
assert_eq   "release:an-empty-export-is-refused" "1" "$(rel_rc)"
assert_unwritten "release:an-empty-export-writes-nothing"
assert_says "release:that-refusal-points-at-gitattributes" ".gitattributes" "$out"

# A HASHER THAT CANNOT ANSWER. Not "no hasher on the machine" -- `command -v` would still find a
# real one behind a shim -- but the observable that matters: the arm runs and produces nothing, so
# every digest below it would be the empty string, and an empty PAYLOAD_SHA256 would compare equal
# to an empty computed value and pass forever. That is the trap
# pkgsha:the-pin-is-not-the-empty-file-digest exists for, one file up.
reset_case
mkdir -p "$TMP/nohash"
for t in sha256sum shasum openssl; do
    printf '#!/bin/sh\nexit 1\n' > "$TMP/nohash/$t"
    chmod +x "$TMP/nohash/$t"
done
out="$( cd "$CASE" && PATH="$TMP/nohash:$PATH" .private/release.sh --patch 2>&1 )"
assert_eq   "release:a-hasher-that-answers-nothing-is-refused" "1" \
            "$( cd "$CASE" && PATH="$TMP/nohash:$PATH" .private/release.sh --patch >/dev/null 2>&1; printf '%s' "$?" )"
assert_says "release:that-refusal-names-the-tools" "shasum or openssl" "$out"
