#!/usr/bin/env bash
#
# Cut a release: write the version, hash what ships, and compile every digest into the files a
# student downloads. Then stop.
#
#     .private/release.sh --patch        # 1.2.3 -> 1.2.4
#     .private/release.sh --minor        # 1.2.3 -> 1.3.0
#     .private/release.sh --major        # 1.2.3 -> 2.0.0
#
# WHAT THIS EXISTS FOR (#232, #299). install-cs193v.sh pins a TAG and refuses a payload whose
# content does not hash to PAYLOAD_SHA256; install-cs193v-windows.cmd pins the same tag and
# refuses a stage two whose bytes do not hash to STAGE2_SHA256; install-cs193v.ps1 pins the same
# tag again and refuses a .cmd whose bytes do not hash to CmdSha256. Numbers in four files that
# all have to agree with each other and with what GitHub will serve. Computing them by hand is
# the kind of task that works four times and then ships a release nobody can install.
#
# THE ORDER BELOW IS A DEPENDENCY CHAIN AND NOT A SEQUENCE OF CONVENIENCE. Each file is rewritten
# only after the file it pins has been staged and hashed:
#
#     VERSION -> payload manifest -> .sh -> staged .sh blob -> .cmd -> staged .cmd blob -> .ps1
#
# It stays acyclic because none of the three published files is inside the tree the manifest
# describes -- .gitattributes export-ignores all of .private -- so writing a digest into one of
# them cannot change PAYLOAD_SHA256 behind us.
#
# IT WRITES FILES AND STOPS. No commit, no tag, no push, no upload -- it prints those as commands
# instead. Writing is reversible, the rest is progressively less so, and uploading is
# outward-facing; there is also a release gate to run in between, which a script that pushed
# would have skipped past. See "Cutting a release" in .private/README.md.
#
# NO EXPLICIT VERSION ARGUMENT, and no --dry-run. `--major` from 1.9.3 gives 2.0.0, so a typed
# version buys nothing and reintroduces the typo class. A dry run does not survive the question
# "what would it do?" either: every refusal below runs before anything is written, so a run that
# fails is already side-effect-free, and --dev-manifest-hash answers "what would the payload hash
# to" on its own.
#
# THE FIRST RELEASE WAS SEEDED BY HAND, following these same steps in this same order, because
# bump-flags-only means there is no path to 0.0.0 through this script.
#
# MUST STAY BASH 3.2 COMPATIBLE -- a release is cut on a staff Mac. See lib/assert.sh for why.

set -u

DIR0="$(cd -- "$(dirname -- "$0")" && pwd -P)"
REPO0="$(cd -- "$DIR0/.." && pwd -P)"
BOOT="$DIR0/install-cs193v.sh"
CMD="$DIR0/install-cs193v-windows.cmd"
PS1="$DIR0/install-cs193v.ps1"
VERSION_FILE="$DIR0/VERSION"

# ONE FUNCTION OUT OF THE HARNESS AND NOT THE HARNESS, the same import make-tarball.sh makes. It
# is `git archive` of the working tree, so what gets hashed is what export-ignore will really
# ship, and it pins core.autocrlf -- see its header for why that is a fail-closed hazard here.
#
# AND $REPO IS SET BEFORE IT IS SOURCED, WHICH IS NOT DECORATION. The module prefers a caller's
# $REPO so that the test harness can point the staging at a synthetic repository; lib/assert.sh
# EXPORTS that variable, so a release.sh started from a suite inherits the checkout's path in its
# environment and would have hashed the real tree while claiming to describe the copy it was run
# in. Measured: 23-release.sh's symlink and empty-export cases both reported a successful release
# whose payload digest was the outer repository's. Saying which repository this is, out loud, is
# the fix -- and it is also just true.
REPO="$REPO0"; export REPO
# shellcheck source=lib/export-tree.sh
. "$DIR0/lib/export-tree.sh" || {
    printf 'release.sh: cannot read %s\n' "$DIR0/lib/export-tree.sh" >&2; exit 1; }

die() { printf '\nrelease.sh: %s\n\n' "$*" >&2; exit 1; }
say() { printf '  %s\n' "$*"; }

# ─── the hasher ────────────────────────────────────────────────────────────────
# THE SAME THREE PROBED ARMS install-cs193v.sh AND install-utils.sh CARRY, and the same reasons:
# no sha256sum on macOS 14 or earlier, shasum is a perl script Apple has warned about, openssl is
# LibreSSL and survives both. Fed on stdin so no path reaches the tool, because a path can contain
# hex and openssl prints it.
sha_stdin() {                         # sha_stdin < FILE -> 64 lower-case hex digits, or nothing
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum            | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256        | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 | awk '{print $NF}'
    fi
}

# ─── rewriting a constant, and checking that it happened ───────────────────────
# A sed WHOSE PATTERN STOPS MATCHING IS A SILENT NO-OP, and this project has already paid for that
# shape twice: seven harness sites that repointed a download by rewriting `^TARBALL=.*` (#280), and
# a `sed //d` whose addresses stopped matching in 10-static.sh. Here the cost would be a release
# published with last release's digest in it, which refuses every install.
#
# SO EVERY EDIT IS VERIFIED BY READING THE VALUE BACK, not by trusting sed's exit status -- sed
# exits 0 having changed nothing at all.
#
# NOT `sed -i`. GNU wants `-i`, BSD wants `-i ''`, and this runs on both.
#
# THE PATTERN STOPS AT THE CLOSING QUOTE, which is what preserves the .cmd's CRLF: the carriage
# return sits after it, outside the match, so it survives untouched. A `.*` to end-of-line would
# eat it and cmd.exe's label scanner would then fail by byte offset.
rewrite_one() {                       # rewrite_one FILE PREFIX SUFFIX VALUE READBACK_RE
    local file="$1" prefix="$2" suffix="$3" value="$4" re="$5" tmp got
    tmp="$(mktemp "${TMPDIR:-/tmp}/cs193v-rel.XXXXXX")" || die "could not create a temp file"
    sed "s|^${prefix}[^\"]*${suffix}|${prefix}${value}${suffix}|" "$file" > "$tmp" \
        || { rm -f "$tmp"; die "sed failed on $file"; }
    cat "$tmp" > "$file" || { rm -f "$tmp"; die "could not write $file"; }
    rm -f "$tmp"
    got="$(sed -n "s|^${re}|\1|p" "$file" | head -1)"
    [ "$got" = "$value" ] || die "rewriting $(basename "$file") did not take: wanted '$value', file says '$got'
  The pattern '^${prefix}' matched nothing, or matched something else. Nothing was published."
}

# ─── what was asked for ────────────────────────────────────────────────────────
BUMP=''
case "${1:-}" in
    --major|--minor|--patch) BUMP="${1#--}" ;;
    -h|--help) sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    '') die "say which part to bump: --major, --minor or --patch" ;;
    *)  die "unexpected argument: $1" ;;
esac
[ -z "${2:-}" ] || die "unexpected argument: $2"

# ─── every refusal, before anything is written ─────────────────────────────────
# IN ONE BLOCK AND AHEAD OF EVERY WRITE, which is what makes --dry-run unnecessary: a run that
# refuses has changed nothing, so there is no half-cut release to unpick.
cd "$REPO0" || die "cannot cd to $REPO0"

command -v git >/dev/null 2>&1 || die "git is not on PATH"
[ -n "$(printf '' | sha_stdin)" ] || die "no sha256 tool: install coreutils, or check that shasum or openssl is on PATH"

[ -r "$VERSION_FILE" ] || die ".private/VERSION is missing. It ships, so a release cannot be cut
  without it -- and the first one had to be written and committed by hand."
# TRACKED, AND THIS IS THE REFUSAL THAT LETS export_tree STAY IN ITS `git add -u` MODE. That mode
# stages modifications to files git already knows about and silently ignores anything new, so an
# untracked VERSION would be absent from the manifest and present in the commit -- and every
# install would then refuse. Checking it here is narrower than widening the staging.
git ls-files --error-unmatch "$VERSION_FILE" >/dev/null 2>&1 \
    || die ".private/VERSION is not tracked by git. `git add` it and commit it first: the export
  stages tracked modifications only, so an untracked VERSION would be left out of the hash."

old_version="$(cat "$VERSION_FILE")"
printf '%s' "$old_version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || die ".private/VERSION does not hold three numbers: '$old_version'"

old_tag="$(sed -n 's/^REPO_TAG="\([^"]*\)".*/\1/p' "$BOOT" | head -1)"
[ "$old_tag" = "release-$old_version" ] || die "install-cs193v.sh and .private/VERSION disagree on
  entry: REPO_TAG is '$old_tag' and VERSION says '$old_version'. Somebody edited one by hand;
  fix that before cutting a release on top of it."

# A DIRTY TREE, INCLUDING UNTRACKED FILES. --porcelain lists those as `??`, and they matter as
# much as modifications do: the manifest describes what is about to be COMMITTED, and a file that
# is not going to be in the commit must not be in the hash -- nor the other way round.
#
# AFTER THE VERSION CHECKS ABOVE, AND THAT ORDER IS A FIX RATHER THAN A PREFERENCE. This check is
# the general one: an untracked .private/VERSION is ALSO a dirty tree, so with the two the other
# way round the specific refusal above could never fire and its message -- which says to `git add`
# the file -- was unreachable. Found by driving it: 23-release.sh's
# release:an-untracked-version-is-refused got the generic wording instead.
dirty="$(git status --porcelain 2>/dev/null)"
[ -z "$dirty" ] || die "the working tree is not clean, and the manifest has to describe a tree
  somebody can fetch. Commit or stash first:

$(printf '%s\n' "$dirty" | sed 's/^/      /')"

# A CR IN THE BOOTSTRAP. .gitattributes gives this file `text eol=lf` so that a CHECKOUT is LF on
# every platform, which is what makes the blob raw.githubusercontent.com serves predictable. That
# attribute cannot fix an EDITOR: a TA whose editor saved CRLF has a CRLF working copy and an LF
# blob, and it is the working copy that gets hashed below. One grep closes it.
! grep -q "$(printf '\r')" "$BOOT" || die "install-cs193v.sh contains a carriage return.
  Save it with LF line endings -- raw.githubusercontent.com serves the blob git stored, which
  will be LF, so a CRLF working copy would publish a digest no Windows student can match."

# ─── and the Windows bootstrap, which has two of the same guards and deliberately not the third
#
# THE .ps1 IS THE ONLY FILE PUBLISHED FROM THIS TREE THAT NOTHING HASHES. Students paste its
# address and `iex` runs whatever comes back, so a defect in its BYTES is not caught anywhere
# downstream -- the digest chain starts one level below it. These two refusals are the whole of
# the machine-checkable part; MANUAL.md carries the rest.
[ -r "$PS1" ] || die "the Windows bootstrap is missing: $PS1"

# A BYTE-ORDER MARK, WHICH IS A PUBLISHED-BYTES DEFECT AND NOT A TIDINESS ONE. Measured on
# Windows PowerShell 5.1.26100.9444: a leading UTF-8 BOM makes `iex` fail to PARSE, so the
# one-liner dies on line one for every Windows student at once, with nothing on screen but a
# parse error. Git has no attribute that can prevent one, so this and 25-installer.sh are it.
[ "$(head -c 3 "$PS1" | od -An -tx1 | tr -d ' \n')" != "efbbbf" ] \
    || die "install-cs193v.ps1 starts with a UTF-8 byte-order mark.
  Save it without one -- iex refuses to parse a file that begins with a BOM, so the one-liner
  would fail on its first line for every Windows student."

# NON-ASCII, for the other half of the same problem: Invoke-RestMethod on 5.1 decodes a response
# whose Content-Type carries no charset as ISO-8859-1, so anything above 0x7F arrives as a
# different character than was written. ASCII is the one encoding under which the course
# website's server configuration cannot matter.
! LC_ALL=C grep -q '[^ -~	]' "$PS1" || die "install-cs193v.ps1 contains a non-ASCII byte.
  Invoke-RestMethod decodes a charset-less response as ISO-8859-1, so the bytes a student runs
  would not be the bytes written here."

# THERE IS DELIBERATELY NO CARRIAGE-RETURN REFUSAL FOR THIS FILE, which is the one place it
# differs from install-cs193v.sh above, and it is worth saying so here because the obvious move
# is to add one for symmetry. Measured on the same host: `iex` parses the bootstrap identically
# with LF and with CRLF endings, inside its script block and outside it, and nothing hashes the
# file -- so the rule would pin a property no one can observe. The .sh needs it because its blob
# digest is published; the .cmd needs CRLF because cmd.exe's label scanner does.

# ─── the version, computed rather than typed ───────────────────────────────────
o_major="${old_version%%.*}"
o_rest="${old_version#*.}"
o_minor="${o_rest%%.*}"
o_patch="${o_rest#*.}"
case "$BUMP" in
    major) new_version="$((o_major + 1)).0.0" ;;
    minor) new_version="$o_major.$((o_minor + 1)).0" ;;
    patch) new_version="$o_major.$o_minor.$((o_patch + 1))" ;;
esac
new_tag="release-$new_version"

# THE TAG THIS RUN IS ABOUT TO CREATE, not the one REPO_TAG already names. Stated because the
# other reading makes the refusal unsatisfiable forever: after release-0.0.0 is tagged, REPO_TAG
# always names a tag that exists.
git rev-parse -q --verify "refs/tags/$new_tag" >/dev/null 2>&1 \
    && die "$new_tag already exists locally. Delete it, or bump a different part."
[ -z "$(git ls-remote --tags origin "refs/tags/$new_tag" 2>/dev/null)" ] \
    || die "$new_tag already exists on origin. A published tag is not ours to move."

# ─── what would ship, checked before it is described ──────────────────────────
# THE SAME PREDICATE install-cs193v.sh ENFORCES AT INSTALL TIME AND 11-export.sh AT DEVELOPMENT
# TIME, at the third of the three moments it matters: before a digest for it is published. The
# manifest format has one line per entry and cannot represent a symlink or a newline in a path, so
# a tree holding either cannot be described at all -- and a symlink would ship OUTSIDE the
# verified content, which is the one that matters.
probe="$(mktemp -d "${TMPDIR:-/tmp}/cs193v-relprobe.XXXXXX")" || die "could not create a temp dir"
export_tree "$probe" || { rm -rf "$probe"; die "git archive of the working tree failed"; }
n_files="$( (cd "$probe" && find . -type f | grep -c '') )"
odd="$( (cd "$probe" && find . ! -type f ! -type d -print | sed 's|^\./||') )"
nl='
'
badname="$( (cd "$probe" && find . -name "*$nl*" -print) )"
rm -rf "$probe"
# AN IMPLAUSIBLY SMALL EXPORT SET, following 11-export.sh's own size guard: every comparison below
# is satisfied by an empty tree in one direction or another, and a .gitattributes mistake that
# excluded everything would otherwise publish the digest of almost nothing.
[ "$n_files" -gt 10 ] || die "the export set holds only $n_files files, which cannot be right.
  Check .gitattributes before publishing a digest for it."
[ -z "$odd" ] || die "what would ship contains something that is not a file or a directory:

$(printf '%s\n' "$odd" | sed 's/^/      /')

  The manifest covers files and directories. A symlink would travel outside it."
[ -z "$badname" ] || die "a path in what would ship contains a newline, which the manifest format
  cannot represent."

# ─── and now the writes, in the one order that works ──────────────────────────
say "$old_version -> $new_version  ($new_tag)"

# 1. VERSION FIRST, BECAUSE IT SHIPS. It is in the exported set, so the manifest below has to be
#    computed with the new number already in place.
printf '%s\n' "$new_version" > "$VERSION_FILE" || die "could not write $VERSION_FILE"
say "wrote .private/VERSION"

# 2. THE MANIFEST, THROUGH THE BOOTSTRAP'S OWN VERB. One implementation of the format, so there is
#    no second one to drift from -- and if there were two and they disagreed by a byte, every
#    install would refuse.
work="$(mktemp -d "${TMPDIR:-/tmp}/cs193v-release.XXXXXX")" || die "could not create a temp dir"
export_tree "$work/tree" || { rm -rf "$work"; die "git archive of the working tree failed"; }
payload="$(bash "$BOOT" --dev-manifest-hash "$work/tree")" \
    || { rm -rf "$work"; die "the payload manifest could not be computed"; }
rm -rf "$work"
printf '%s' "$payload" | grep -qE '^[0-9a-f]{64}$' \
    || die "the payload manifest did not come back as a digest: '$payload'"
say "payload manifest  $payload"

# 3. THE .sh, AND IT IS SAFE TO EDIT IT AFTER HASHING THE PAYLOAD *BECAUSE IT IS export-ignored*.
#    That is the invariant the whole one-commit design rests on: this file is not in the tree it
#    describes, so writing a digest into it cannot change the digest. 11-export.sh asserts the
#    export-ignore half.
rewrite_one "$BOOT" 'REPO_TAG="'        '"' "$new_tag"  'REPO_TAG="\([^"]*\)".*'
rewrite_one "$BOOT" 'PAYLOAD_SHA256="'  '"' "$payload"  'PAYLOAD_SHA256="\([^"]*\)".*'
say "wrote install-cs193v.sh"

# 4. THE STAGED BLOB, NOT THE WORKING COPY. `git add` applies the clean filter, and .gitattributes
#    gives this file `text eol=lf` -- so the blob is exactly the bytes
#    raw.githubusercontent.com will serve, which is what the .cmd has to expect. Hashing the file
#    on disk would publish a CRLF digest from a Windows checkout. The CR refusal above is the
#    other half of the same guard.
git add -- "$BOOT" || die "could not stage install-cs193v.sh"
stage2="$(git cat-file blob ":.private/install-cs193v.sh" | sha_stdin)"
printf '%s' "$stage2" | grep -qE '^[0-9a-f]{64}$' \
    || die "the stage-two digest did not come back as a digest: '$stage2'"
say "stage two digest  $stage2"

# 5. THEN THE .cmd, which depends on the digest step 4 just computed.
rewrite_one "$CMD" 'set "REPO_TAG='       '"' "$new_tag" 'set "REPO_TAG=\([^"]*\)".*'
rewrite_one "$CMD" 'set "STAGE2_SHA256='  '"' "$stage2"  'set "STAGE2_SHA256=\([^"]*\)".*'
say "wrote install-cs193v-windows.cmd"

# 6. THE .cmd's OWN BLOB DIGEST, BY THE SAME IDIOM AS STEP 4 AND FOR THE SAME REASON (#299).
#    The Windows bootstrap fetches the .cmd from raw.githubusercontent.com, which serves the
#    stored git OBJECT and honours no attribute -- so what a student receives is the blob, and
#    the blob is what has to be pinned.
#
#    `git cat-file blob` AND NOT `sha_stdin < "$CMD"`, AND THE DIFFERENCE IS THE WHOLE POINT.
#    .gitattributes gives the .cmd `text eol=crlf`, so the blob is LF and every checkout is
#    CRLF -- two different files with two different digests. Reading the object database asks
#    git what it stored and is therefore insensitive to the platform the release is cut on; the
#    working copy on a staff Mac and on a TA's Windows box would give different answers, and one
#    of them would be a number no student could ever match. This is also why the bootstrap
#    converts LF to CRLF after it verifies: it checks the bytes GitHub sent, then makes them into
#    the file cmd.exe needs.
#
#    STAGED FIRST, because `git add` is what applies the clean filter that produces those bytes.
git add -- "$CMD" || die "could not stage install-cs193v-windows.cmd"
cmdsha="$(git cat-file blob ":.private/install-cs193v-windows.cmd" | sha_stdin)"
printf '%s' "$cmdsha" | grep -qE '^[0-9a-f]{64}$' \
    || die "the Windows installer digest did not come back as a digest: '$cmdsha'"
say "windows .cmd digest  $cmdsha"

# 7. AND THE BOOTSTRAP LAST, because it is now the only file that depends on another file's
#    digest -- one more link of the chain step 5 is the middle of.
#
#    THE `$` NEEDS NO ESCAPING AND IS LEFT ALONE ON PURPOSE. rewrite_one uses its PREFIX as both
#    the search pattern and the replacement text, so a backslash added to satisfy the pattern
#    would land in the file. In a POSIX basic regular expression `$` is an anchor only as the
#    LAST character, and here it is the second, so it is already literal in both roles. Verified
#    on GNU and BSD sed. The read-back is a pattern only, so it escapes its own.
rewrite_one "$PS1" '$RepoTag   = "'  '"' "$new_tag" '\$RepoTag   = "\([^"]*\)".*'
rewrite_one "$PS1" '$CmdSha256 = "'  '"' "$cmdsha"  '\$CmdSha256 = "\([^"]*\)".*'
say "wrote install-cs193v.ps1"

printf '
  Nothing has been committed, tagged, pushed or uploaded. Next, in this order:

      git commit -a -m "Release %s"
      git tag %s
      git push origin main %s
      .private/tests/run-tests.sh --release

  Then upload these to the course website. The first two are named for the release
  and carry their digests beside them, so a student can check what they downloaded:

      install-cs193v-%s.sh   %s
      install-cs193v-windows-%s.cmd   %s

  And the Windows one-liner, which is OVERWRITTEN IN PLACE at a stable address --
  it is the one file students never download, so a version in its name would be a
  version somebody has to type:

      install-cs193v.ps1   %s

  Forgetting that last upload is the quiet failure of this feature: every new
  Windows student silently installs the PREVIOUS release, which is not a broken
  install, just an old one, so nothing complains.

  --release is not optional: it is the only thing that checks the digests above
  against what GitHub actually serves. Run it after the push, not before.
' "$new_version" "$new_tag" "$new_tag" \
  "$new_version" "$(sha_stdin < "$BOOT")" \
  "$new_version" "$(sha_stdin < "$CMD")" \
  "$(sha_stdin < "$PS1")"
