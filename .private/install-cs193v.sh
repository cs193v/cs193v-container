#!/usr/bin/env bash
#
# CS193V setup — macOS, Ubuntu, and the WSL CS193V environment on Windows.
#
# Download this file, read it, then run it:
#
#     bash install-cs193v.sh
#
# Its SHA-256 is published next to the download link. Verify it first if you like:
#
#     shasum -a 256 install-cs193v.sh
#
# IT IS SAFE TO RUN THIS AGAIN. Every step checks whether it is already done, so if
# your wifi drops or you run out of disk part-way through, fix the problem and re-run.
# "Re-run the installer" is also the standard answer when something is broken later.
#
# ─── What this file is, and what it is not  (#221) ─────────────────────────────
#
# THIS IS THE BOOTSTRAP. It does four things: find a program that can download, fetch the
# course files, CHECK THEY ARE THE ONES THIS FILE EXPECTS, and hand over to course-install.sh
# inside them. Every question you are asked, every package that gets installed and every word you
# read after the next few lines comes from that file, not this one.
#
# THE THIRD ONE CHANGED WITH #232, and the wording used to be "check they arrived". Arriving is
# what curl and tar can tell you; being OURS is what the manifest below tells you, and that is a
# different claim -- a hotel wifi login page arrives perfectly.
#
# WHY IT IS SPLIT THIS WAY. The installer used to be one file, and carried its own copy of
# the course's box-drawing, menus, version comparison and podman-finding code -- because a
# file downloaded on its own has nothing to source. Downloading first means there is
# something to source, so there is now one copy of each instead of two.
#
# WHAT THE PUBLISHED SHA-256 COVERS, stated plainly rather than implied: this file -- and since
# #232 this file covers everything else. It carries the tag the course files are fetched from AND
# the digest their content must hash to, so checking this one number is checking the lot. If you
# do not check it, what you are trusting is the course website and TLS. See .private/README.md.
#
# YOUR COPY MAY HAVE A VERSION IN ITS NAME -- install-cs193v-1.2.0.sh, or whatever your browser
# called it -- because each release is published under its own name. The digest beside the
# download link is the one for that file.
#
# MUST STAY BASH 3.2 COMPATIBLE — macOS ships bash 3.2. No associative arrays, no
# mapfile, no ${var,,}, no fractional `read -t`.
#
# IT SOURCES NOTHING AND EVALS NOTHING. 10-static.sh asserts both, because that is the
# property that makes this file readable in one sitting.

set -u

# ─── where the course files come from ──────────────────────────────────────────
# THREE CONSTANTS AND ONE URL, and install-cs193v-windows.cmd composes the same URL out of its
# own copy of the three; 25-installer.sh fails if the two files disagree.
#
# A TAG, NOT A BRANCH (#232), AND THAT IS THE WHOLE POINT OF THIS FILE'S EXISTENCE. refs/heads/main
# moves on every push, so what a student installed depended on when they ran this -- and a
# compromised repository reached them with sudo, because course-install.sh runs the package install
# as root. archive/<tag>.tar.gz names a fixed tree, and PAYLOAD_SHA256 below is what makes that
# claim checkable on the student's own machine rather than trusted.
#
# WHY A TAG AND NOT A COMMIT SHA, since the SHA is the stronger name: a commit cannot contain its
# own hash, so pinning a SHA means the bootstrap that names release N is a CHILD of the commit it
# names -- three commits and an off-by-one-release trap. A ref can be created AFTER the object it
# names, so a tag lets one commit carry the tag name and the digests that describe it. The pin is
# not what makes the payload trustworthy here; the manifest is, and it does not care how the tree
# was addressed. See .private/README.md's "Cutting a release".
#
# TARBALL IS A LITERAL ASSIGNMENT ON ONE LINE, and the reason changed twice. It used to be
# load-bearing because seven places in the test suite repointed the download by rewriting
# `^TARBALL=.*` with sed; CS193V_TARBALL (#280) replaced every one of them. Now it is
# .private/release.sh that rewrites REPO_TAG, with sed anchored at `^REPO_TAG=`, so the constant
# stays one literal on one line for the same reason it always did -- a composed URL would leave
# the rewrite matching nothing, silently.
#
# CS193V_TARBALL IS A STAFF SWITCH AND NOT A SECURITY BOUNDARY, which is worth saying plainly
# because it can be mistaken for one. Anyone who can set a variable in your shell can also edit
# the script you are about to run; what a commit pin defends against is a compromised
# REPOSITORY, and nothing here weakens that. This exists so that testing a change means pointing
# at the change, and the banner below exists so a puzzling transcript says which copy ran.
#
# RESOLVED ONCE, ABOVE ALL THREE READERS. tarball_url() is not the only thing that reads the
# source -- the two refusals below name it in their prose -- so an override applied at the fetch
# alone would make a failed local run print the GitHub URL it never touched.
REPO_OWNER="cs193v"
REPO_NAME="cs193v-container"
REPO_TAG="release-0.0.0"
TARBALL="https://github.com/$REPO_OWNER/$REPO_NAME/archive/$REPO_TAG.tar.gz"
COURSE_SRC="${CS193V_TARBALL:-$TARBALL}"
tarball_url() { printf '%s\n' "$COURSE_SRC"; }

# ─── what the course files have to hash to ─────────────────────────────────────
# THE ONE THING ON THIS PAGE THAT IS CHECKED RATHER THAN TRUSTED (#232). The tag above says WHICH
# tree to fetch; this says what that tree must contain, and it is verified on the student's own
# machine. So the trust root is the course website and TLS -- the place this file came from -- and
# not codeload. That is a different and stronger claim than a pin alone can make.
#
# A MANIFEST, NOT THE ARCHIVE'S BYTES, and that distinction is the whole design. GitHub does not
# guarantee the bytes of an auto-generated archive: the 2023-01-30 compression change broke
# Homebrew, Bazel, Spack and Go modules, and `git archive` stamps every member's mtime from the
# commit date. Measured: the same tree served under two refs differs in bytes, 555,816 against
# 555,476, because the embedded directory name differs. A hash over extracted CONTENT has none of
# those degrees of freedom.
#
# .private/release.sh COMPUTES THIS WITH THIS FILE'S OWN CODE, through --dev-manifest-hash below,
# so there is exactly one implementation of the format and no second one to drift from. Rewritten
# by sed anchored at `^PAYLOAD_SHA256=`, which is why it is one literal on one line.
PAYLOAD_SHA256="48d27b5d3fabf919326b7e9ca9b0eefb41bec34a72a59c3670fa77bbc597ef0c"
# AND ONE WAY TO SUPPLY A DIFFERENT EXPECTATION, FOR STAFF. Consulted ONLY beside CS193V_TARBALL:
# alone it could do nothing but make a genuine release fail against a value nobody published, and
# the banner below says so rather than leaving that to guesswork. With both set, a by-hand run --
# and the test suite -- can drive the REFUSAL, which is otherwise unreachable without serving bad
# bytes at the published URL.
PAYLOAD_WANT="${CS193V_PAYLOAD_SHA256:-$PAYLOAD_SHA256}"

# ─── hashing, in the one shape this project has already argued out ─────────────
# COPIED FROM install-utils.sh's pkg_sha256, DELIBERATELY, and this is the third copy of a hasher
# in the tree after the launcher's sha_stdin and that one. The bootstrap sources nothing --
# 10-static.sh asserts it, and that property is what makes this file readable in one sitting -- so
# the alternative to a copy is no check at all. #283 already recorded the argument for a second
# copy on purpose; this is the same argument.
#
# THREE ARMS AND NO uname, WHICH KEEPS THIS FILE'S OTHER BAN INTACT: it must not learn what OS it
# is on, because the code that answers that question lives in the files it has not downloaded yet.
# `command -v` asks the only question that matters anyway.
#
#   sha256sum  coreutils, so every Linux -- and macOS 15+, where /sbin/sha256sum arrived. NOT on
#              macOS 14 or earlier, and course-install.sh sets no macOS floor, so it cannot be the
#              only branch.
#   shasum     on every Mac there has ever been -- but it is `#!/usr/bin/perl`, and Apple's
#              standing notice is that future macOS will not include the scripting runtimes.
#   openssl    /usr/bin/openssl is LibreSSL, in the base system since High Sierra and not a
#              scripting runtime, so it is the one that survives that removal.
#
# STDIN, NEVER A PATH ARGUMENT, and that is measured rather than tidy: `openssl dgst -sha256 /p`
# prints `SHA256(/p)= hex`, and a path can itself contain hex -- so anything hunting for hex in
# that line can pick the wrong token. Fed on stdin, openssl prints no path at all.
#
# $1 FOR TWO OF THEM AND $NF FOR THE THIRD, WHICH IS NOT A TYPO. coreutils prints `hex  -`;
# LibreSSL on stdin prints bare hex; OpenSSL 3 prints `SHA2-256(stdin)= hex` and OpenSSL 1
# `(stdin)= hex`. So $1 is right for the first two and would return the literal `(stdin)=` for the
# third. Tidying these onto one normaliser is the change not to make.
sha_stdin() {                         # sha_stdin < FILE -> 64 lower-case hex digits, or nothing
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum            | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256        | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 | awk '{print $NF}'
    fi
}

# ─── the manifest, and the format is a published contract ──────────────────────
# EVERY ENTRY, TYPED. One line per entry, `LC_ALL=C sort`ed, hashed as text:
#
#     d  <path>
#     f  <sha256>  <path>
#
# Two spaces after the type, two between the digest and the path, paths relative to the extraction
# root with no leading `./`, and the text ENDS WITH A NEWLINE -- the classic off-by-one-byte, so it
# is written down. Because `d` sorts before `f`, directories come first; that falls out of the sort
# rather than being arranged, and nothing depends on it.
#
# DIRECTORIES ARE IN IT even though git cannot store an empty one, so today every directory line is
# derivable from the file lines beside it. That redundancy is free and cannot drift, and it is what
# makes a directory arriving that should not have a detectable event rather than a silent one.
#
# MODES, mtimes AND OWNERSHIP ARE NOT IN IT, and that is the one exclusion. `tar x` as an ordinary
# user applies the caller's UMASK and the two tars differ in their defaults, so a mode-inclusive
# manifest would refuse a student's install for no reason but their shell configuration. The only
# mode anything depends on is the launcher's +x, and course-install.sh chmods it unconditionally
# after extraction -- so that is covered, just not covered here. Do not "fix" this by adding modes.
#
# ANYTHING THAT IS NOT A REGULAR FILE OR A DIRECTORY IS REFUSED, rather than described. A symlink
# is the case that matters: `find -type f` would skip it, so it would ship OUTSIDE the verified
# content -- and the exported set has none, so one appearing is either a mistake or an attack. A
# newline in a path is refused because a line-oriented format cannot represent it unambiguously and
# the sort would be wrong as well. 11-export.sh refuses both at development time and release.sh
# before publishing; this is the same predicate at install time, on a tarball nobody here built.
#
# IT IS AN AUTHENTICITY CHECK ON WHAT LANDED, NOT CONTAINMENT DURING EXTRACTION. A tarball that
# wrote outside this directory has already written by the time any of this runs; what stops that is
# tar's own path handling and the fresh mktemp root, not the manifest. Worth knowing before anyone
# reads more into it than it says.
#
# NO `find -printf`: it is GNU-only and this runs on macOS. One pass per type instead.
manifest_hash() {                     # manifest_hash DIR -> the digest, or nothing + why on stderr
    _mh_nl='
'
    ( cd "$1" 2>/dev/null || { printf 'cannot read %s\n' "$1" >&2; exit 1; }
      if [ -n "$(find . ! -type f ! -type d -print 2>/dev/null | sed 1q)" ]; then
          printf 'the course files contain something that is not a file or a directory\n' >&2
          exit 1
      fi
      if [ -n "$(find . -name "*$_mh_nl*" -print 2>/dev/null | sed 1q)" ]; then
          printf 'a course file name contains a newline\n' >&2
          exit 1
      fi
      # NO WORD-SPLITTING ANYWHERE IN HERE. Spaces in paths are legal and must survive untouched;
      # the text is only ever hashed, never re-parsed, so nothing downstream has to take it apart.
      _mh_text="$(
        { find . -type d -print | sed -e 's|^\./||' -e '/^\.$/d' | while IFS= read -r _mh_p; do
              printf 'd  %s\n' "$_mh_p"
          done
          find . -type f -print | sed 's|^\./||' | while IFS= read -r _mh_p; do
              printf 'f  %s  %s\n' "$(sha_stdin < "$_mh_p")" "$_mh_p"
          done
        } | LC_ALL=C sort
      )"
      # AN EMPTY MANIFEST IS A REFUSAL, NOT A DIGEST. Hashing nothing yields e3b0c442..., a real
      # 64-hex value that would compare equal to a pin filled in from a failed release -- the same
      # trap pkgsha:the-pin-is-not-the-empty-file-digest exists for one file up.
      if [ -z "$_mh_text" ]; then
          printf 'the course files are empty\n' >&2
          exit 1
      fi
      # THE TRAILING NEWLINE IS PART OF THE TEXT, and printf is what puts it back: the command
      # substitution above strips it, so hashing $_mh_text bare would hash one byte less than the
      # format specifies and nothing would ever agree with release.sh.
      printf '%s\n' "$_mh_text" | sha_stdin
    )
}

# ─── and where a newer release would announce itself  (#282) ───────────────────
# HANDED DOWN RATHER THAN RE-DERIVED, because course-install.sh deliberately does not know where
# the course files come from: its own header says the coordinates live here, and a second copy of
# them would be a second thing to forget at release time. So this composes the URL and passes it,
# and the installer proper fetches it without knowing what a repository is.
#
# WHY THAT CHECK EXISTS AT ALL. Before the pin, "re-run the installer" delivered whatever was on
# main -- so a student who never heard a fix was published got it anyway, which is what this
# file's own header promises. Under a tag, re-running a stale copy re-installs the identical
# broken tree and the report is indistinguishable from a fresh install. Nothing on the machine can
# see that: the recipe, the launcher and the installer all arrived together and agree with each
# other perfectly.
TAGS_URL="https://github.com/$REPO_OWNER/$REPO_NAME/tags.atom"

# ─── refusals ──────────────────────────────────────────────────────────────────
# PLAIN printf, AND THERE IS NO CATALOGUE IN THIS FILE. Everything this script can refuse
# happens before the course files exist, so there is nothing to read prose out of and nothing
# to draw a box with. That is also the lint boundary: 10-static.sh's text116 rules hold
# course-install.sh to the catalogue and deliberately do not look at this file.
refuse() { printf '\n%s\n\n' "$*" >&2; exit 1; }

# ─── one argument, and it is not part of an install  (#232) ────────────────────
# NOT AN ARGUMENT USED TO BE THE CLAIM, and this file had never parsed one. .private/release.sh
# needs the manifest that the block above defines, and the alternative to a verb here is a second
# implementation of the format in the release script -- two copies which, if they disagree by one
# byte, refuse every install. This project's answer to that shape is a --dev- verb: cs193v carries
# six, files/setup-git carries one, and the launcher records the reasoning beside verb_args as
# "A VERB RATHER THAN A SOURCED FUNCTION". This file cannot offer a sourced function anyway; it
# sources nothing and nothing may source it.
#
# DISPATCHED HERE, WHICH IS BEFORE THE FIRST THING THAT CAN REFUSE. The TOOL= line below exits on
# a machine with no curl and no wget, and hashing a directory needs neither -- so a verb placed
# after it would fail for a reason that has nothing to do with what it was asked. It is also
# before the temp directory and the EXIT trap, so this path creates nothing and removes nothing.
#
# ONE LINE ON STDOUT AND NOTHING ELSE, so `$(...)` around it yields a digest -- the property
# 13-term-class.sh records for --dev-term-class. Diagnostics go to stderr for the same reason.
#
# AND AN UNKNOWN ARGUMENT IS NOW A REFUSAL. Before this block `bash install-cs193v.sh --oops`
# silently ignored it and installed; make-tarball.sh already had the right shape.
# ─── and everything below here runs only if ALL of it arrived  (#297) ─────────
# ONE BRACE, AND IT IS THE WHOLE REASON `curl -fsSL URL | bash` IS SAFE TO PUBLISH. bash reads a
# piped script off the pipe and executes each complete statement as it arrives, so a transfer
# that stops half way used to run everything it had received and then exit 0 -- measured: a cut
# at 24000 bytes created the temp tree, printed "Getting the course files...", and reported
# success. On the wifi this file's own refusals are written about, that is a half-done install
# that says nothing.
#
# A compound command has to be PARSED IN FULL before any of it runs, so a stream that stops
# early is a syntax error and NOTHING here executes. Measured at every cut point above.
#
# THE CONSTANTS STAY ABOVE IT on purpose: release.sh rewrites `^REPO_TAG=` and
# `^PAYLOAD_SHA256=` anchored at column 0, and three suites read them the same way. Nothing
# above this line has a side effect, so nothing is lost by leaving it out here.
#
# A BRACE AND NOT `main() { ... }; main "$@"`, which is the usual spelling of this. They protect
# identically; the brace needs no re-indentation, so the body below is untouched and every
# column-anchored pattern in the suite still matches it. bootstrap:the-body-is-guarded holds the
# position, because a `{` that drifted below the first side effect would look exactly like this
# one and protect nothing.
{
case "${1:-}" in
    --dev-manifest-hash)
        [ -n "${2:-}" ] || { printf 'install-cs193v.sh: --dev-manifest-hash needs a directory\n' >&2; exit 2; }
        manifest_hash "$2" || exit 1
        exit 0 ;;
    '') ;;
    *)  printf 'install-cs193v.sh: unexpected argument: %s\n' "$1" >&2; exit 2 ;;
esac

# ─── something that can download ───────────────────────────────────────────────
# EITHER TOOL, AND NEITHER IS A FALLBACK. curl is absent from the Ubuntu DESKTOP image -- the
# 24.04 and 26.04 manifests both carry wget and libcurl4t64 and no curl -- while macOS and the
# WSL image ship curl and no wget. So the two together cover every supported platform and
# neither one covers it alone. curl is tried first only because it is what the majority of
# machines have; nothing downstream cares which answered.
#
# THE ARM IS TESTED, which is the condition this project put on having it at all: an unexercised
# fallback is "a path that rots", and that objection is what kept the installer curl-only through
# two earlier attempts. sb-wget installs end to end through this arm on a machine with wget and
# no curl, and sb-nodl removes both and asserts the refusal below.
find_download_tool() {
    command -v curl >/dev/null 2>&1 && { printf 'curl'; return 0; }
    command -v wget >/dev/null 2>&1 && { printf 'wget'; return 0; }
    return 1
}

# ONE PLACE THAT KNOWS THE FLAGS, because the two tools disagree about every one of them and a
# second call site would get the mapping subtly wrong. curl -f fails on a 404 (wget does that by
# default), -sS is quiet-but-say-why (-nv), -L follows redirects (wget follows by default), and
# --retry/--retry-delay are --tries/--waitretry. -o is -O.
download_to() {                       # download_to DEST URL -> the tool's own exit status
    case "$TOOL" in
        curl) curl -fsSL --retry 10 --retry-delay 3 -o "$1" "$2" ;;
        wget) wget -nv --tries=10 --waitretry=3 -O "$1" "$2" ;;
    esac
}

# IT NAMES BOTH PACKAGE MANAGERS RATHER THAN DETECTING ONE, and that is a decision rather than
# laziness: working out which a machine has means reading /etc/os-release, and the one piece of
# code that does that -- distro_family/distro_packages -- lives in the course files, which is
# precisely what has not been downloaded yet. The bootstrap must not grow a fourth answer to
# "what distro is this", so it prints both and lets the student pick the line that is theirs.
TOOL="$(find_download_tool)" || refuse "  This needs curl or wget to download the course files, and cannot find either.

  Install one and run this again:

      Debian, Ubuntu, Mint, Pop!_OS:  sudo apt install curl ca-certificates
      Fedora:                         sudo dnf install curl

  ca-certificates matters as much as the downloader does: without it the download
  fails with a certificate error that reads like a network problem."

# ─── fetch, check, hand over ───────────────────────────────────────────────────
# A PREDICTABLE PREFIX, so that a run killed part-way leaves something a later sweep can
# recognise. The trap removes the tree on every path that returns -- and deliberately does NOT
# fire on the hand-over below, because `exec` replaces this process and takes its traps with
# it. course-install.sh owns the tree from that point and removes it itself.
BOOT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cs193v-install.XXXXXX")" \
    || refuse "  Could not create a temporary directory. Is the disk full?"
trap 'rm -rf "$BOOT_TMP"' EXIT

# AND THE COURSE FILES GO IN A SUBDIRECTORY OF IT, WHICH IS NOT TIDINESS (#232). The archive is
# downloaded to $BOOT_TMP/course.tar.gz and course-install.sh reads it back from that fixed name
# to unpack the student's own copy -- so if the tree were extracted over $BOOT_TMP, the manifest
# walk would find the .tar.gz sitting in its own root and hash it. Those are precisely the
# auto-generated archive bytes the manifest exists to avoid depending on, and the payload digest
# would then change with GitHub's compression settings. One directory keeps the two apart.
BOOT_TREE="$BOOT_TMP/tree"
mkdir -p "$BOOT_TREE" || refuse "  Could not create a temporary directory. Is the disk full?"

# WHICH SOURCE, AND ONLY WHEN IT IS NOT THE PUBLISHED ONE. Plain printf beside the refusals:
# there is no catalogue in this file, and nothing has been downloaded yet to read one out of. It
# is loud on purpose. The point of a switch somebody else can set is that the transcript of a
# surprising install can be read back to it, so this has to survive being screenshotted.
[ -n "${CS193V_TARBALL:-}" ] && printf '
  *** CS193V_TARBALL is set, so the course files are NOT being downloaded. ***
  *** Using: %s
  *** Unset CS193V_TARBALL to install the published copy.                  ***
' "$COURSE_SRC"

printf '\n  Getting the course files...\n'
# TWO ARMS, AND THE BARE-PATH ONE IS NOT A CONVENIENCE. wget has no file:// scheme -- measured,
# GNU wget 1.21.4 given file:///tmp/x.txt exits 1 having written nothing -- and this script picks
# between curl and wget without caring which answered. So a local tarball named as a file:// URL
# works on a Mac and fails on the Ubuntu desktop image, whereas a bare path behaves identically
# under both, which is what a by-hand test wants. Anything carrying a scheme goes to the
# downloader untouched, file:// included; that is then curl's to answer for, and is the arm the
# test suite drives to keep the download path itself exercised.
case "$COURSE_SRC" in
  *://*)
    # THE EXIT STATUS IS KEPT, because one value of it has its own answer. Both tools have a
    # dedicated code for "the certificate could not be verified" -- curl 60, wget 5 -- and that is
    # the one genuinely new way this can fail since the download moved ahead of everything else:
    # install_podman used to install ca-certificates beside curl, and nothing installs it before the
    # download any more. Left undiagnosed it reads as a network problem, which is the single most
    # misleading thing this script could say about a machine whose network is fine.
    if ! download_to "$BOOT_TMP/course.tar.gz" "$(tarball_url)"; then
        dl_rc=$?
        case "$TOOL:$dl_rc" in
            curl:60|wget:5)
                refuse "  Could not verify the security certificate for:

      $COURSE_SRC

  Your network is probably fine. What is usually missing is the list of
  certificate authorities, which is a package your system may not have:

      Debian, Ubuntu, Mint, Pop!_OS:  sudo apt install ca-certificates
      Fedora:                         sudo dnf install ca-certificates

  Install it and run this script again." ;;
        esac
        refuse "  Could not download the course files from:

      $COURSE_SRC

  This is usually a network problem. It is safe to run this script again."
    fi ;;
  *)
    # A COPY, AND A REFUSAL THAT DOES NOT SAY "NETWORK". Nothing was downloaded on this arm, so
    # the download wording would send a staff member to look at the wrong thing entirely.
    cp "$COURSE_SRC" "$BOOT_TMP/course.tar.gz" || refuse "  Could not read the course files at:

      $COURSE_SRC

  CS193V_TARBALL is set, so nothing was downloaded. Check that path, or unset
  CS193V_TARBALL to install the published copy instead." ;;
esac

# --strip-components=1 because GitHub wraps the archive in a <repo>-<ref>/ directory -- so the
# component this drops is `cs193v-container-release-0.0.0`, and it changes with every release.
# "ARRIVED" RATHER THAN "DOWNLOADED", because since #280 they may not have been: a bare
# CS193V_TARBALL is copied, and a staff member with a half-written local tarball should not be
# told to look at their network.
tar xzf "$BOOT_TMP/course.tar.gz" --strip-components=1 -C "$BOOT_TREE" \
    || refuse "  The course files arrived but could not be unpacked.
  That usually means the transfer was cut short. It is safe to run this script again."

# ─── which of the two installers this hands over to ────────────────────────────
# ONE ENVIRONMENT VARIABLE, SET BY install-cs193v-windows.cmd AND BY NOTHING ELSE (#217). The
# Windows installer runs this file twice inside the CS193V WSL instance it has just created: once
# as root with CS193V_PROVISION=1, which creates the student's account and performs every step
# that needs root, and once as that student, which is the install a student on a Mac or a Linux
# machine sees. The second run finds nothing left needing a password, which is the whole point --
# the account is created with a locked one.
#
# CHOSEN HERE RATHER THAN INSIDE course-install.sh, deliberately. The root pass is a different,
# much shorter script, and keeping the choice in the file that does the downloading means the
# code that runs as root is named in the file a student reads and checks a SHA-256 against.
#
# NOT AN ARGUMENT, because this file has never parsed any, and the .cmd already knows how to pass
# a variable (`wsl -e env VAR=value prog args`, which it does for DEBIAN_FRONTEND). CS193V_WINDOWS
# (#218) marks the pass as the one the Windows installer launched, which is the whole of what
# decides which sign-off a student reads at the end; it and CS193V_DIR are read by
# course-install.sh and not here. THIS FILE READS FOUR VARIABLES AND ONE ARGUMENT: TMPDIR,
# CS193V_PROVISION, CS193V_TARBALL (#280) and CS193V_PAYLOAD_SHA256 (#232), plus the
# --dev-manifest-hash verb above. 10-static.sh asserts both lists, so a fifth variable or a second
# verb is a deliberate edit in two places rather than something that arrives unremarked.
TARGET=.private/course-install.sh
[ -n "${CS193V_PROVISION:-}" ] && TARGET=.private/wsl-provision.sh

# ─── and now the check that no exit status can make ────────────────────────────
# THREE THINGS HAVE TO BE TRUE, AND THIS IS THE THIRD: something downloaded, tar unpacked it, and
# the content is the release. `curl -f` catches a 404 and a cut-off transfer and tar catches a
# truncated archive, but a captive portal answering 200 with its own login page is a well-formed
# reply -- and until #232 nothing at all caught a tree that arrived whole and was not ours.
#
# THIS REPLACED A FIVE-NAME PRESENCE CHECK, and the manifest subsumes it: a tree whose digest
# matches holds every one of those files, with the right bytes, and holds nothing else. What is
# left below is one name, for the staff path where the digest is reported rather than enforced.
#
# WHAT THE THREE STATES DO, because the middle one is the reason the other two are testable:
#
#   no overrides                      compare against PAYLOAD_SHA256 and REFUSE on mismatch
#   CS193V_TARBALL                    compute and REPORT; a local tarball will never hash to a
#                                     published constant, so comparing would fire on every run
#   CS193V_TARBALL + ..._SHA256       compare against the supplied value and REFUSE on mismatch
#
# The third is what makes the refusal reachable offline: without it, the only way to see this
# branch would be to serve bad bytes at the published URL.
#
# BOTH DIGESTS IN THE MESSAGE, and that is what makes a screenshot diagnosable. A cut-short
# transfer and a mis-cut release land here identically, and only the numbers tell staff which one
# they are looking at -- one is fixed by re-running and the other only by a new release.
payload_got="$(manifest_hash "$BOOT_TREE")" || refuse "  The course files arrived but could not be checked.

  It is safe to run this script again. If this keeps happening, tell course staff."

if [ -n "${CS193V_TARBALL:-}" ] && [ -z "${CS193V_PAYLOAD_SHA256:-}" ]; then
    printf '
  *** CS193V_TARBALL is set, so the course files are NOT being checked.       ***
  *** Their manifest hashes to: %s
  *** Set CS193V_PAYLOAD_SHA256 to that value to have it enforced.            ***
' "$payload_got"
elif [ "$payload_got" != "$PAYLOAD_WANT" ]; then
    refuse "  The course files that arrived are not the ones this installer expects.

      expected: $PAYLOAD_WANT
      received: $payload_got

  That usually means the transfer was cut short, or that something answered for
  it -- a hotel or campus wifi login page, for instance. It is safe to run this
  script again. If this keeps happening, tell course staff."
fi

# AND ONE NAME, FOR THE PATH THE DIGEST IS NOT ENFORCED ON. With CS193V_TARBALL set and no
# expectation supplied the block above only reports, so this is what still refuses a half-written
# local tarball -- and it gives a message naming the file, where a digest can only say the bytes
# differ. make-tarball.sh replicates the same check for the same reason.
#
# $TARGET AND NOT A LIST. The five names this used to walk are all inside the manifest, so on the
# student's path they cannot be missing once the digest matched; what is left is the one file this
# script is about to hand control to. In the ordinary case that is course-install.sh, which is
# also the file boot_cleanup's guard looks for before it will remove anything.
[ -s "$BOOT_TREE/$TARGET" ] || refuse "  The course files arrived but $TARGET is missing or empty.

  That means the transfer was cut short, or something answered for it -- a hotel
  or campus wifi login page, for instance. It is safe to run this script again."

# AND STDIN IS PASSED STRAIGHT THROUGH, deliberately. An earlier draft redirected it from
# /dev/null here, on the reasoning that nothing downstream reads stdin. That was wrong twice
# over: the redirect applies to EVERY invocation, not just piped ones, and the installer proper
# reads stdin constantly -- menu() takes arrow keys and choose_dir() reads a typed path.
# Measured: with the redirect in place every pty-driven case saw "(not a terminal; choosing
# ...)" and the consent menu took its safe default, so a student could not have answered a
# single question.
#
# ─── ...UNLESS THERE IS NOTHING TO PASS, WHICH IS WHAT `| bash` LEAVES  (#297) ───
# UNDER A PIPE, BASH'"'"'S OWN STDIN *IS* THIS SCRIPT. So fd 0 is a pipe for the whole run while
# stdout and the controlling terminal are still the student'"'"'s -- #297'"'"'s screenshot shows exactly
# that, in colour, with the box drawn. Everything downstream that asks a question reads fd 0:
# menu() falls back to its safe default ("stop, change nothing") whenever stdin is not a
# terminal, choose_dir() stops asking, and survey() refuses outright with err.sudo-no-terminal
# because it cannot see anywhere to type a password. So the pipe reached the student as a red
# STOP box on a machine that had a perfectly good terminal two file descriptors away.
#
# /dev/tty IS THAT TERMINAL, and it is still open to us: it is the CONTROLLING terminal, which a
# pipe on fd 0 says nothing about. Measured under a pty -- piped, `[ -t 0 ]` is false and
# /dev/tty opens; with no controlling terminal at all it does not, and the refusal above is
# still what happens, correctly.
#
# THE REDIRECT RIDES ON THE HAND-OVER AND IS NEVER A STATEMENT OF ITS OWN. A bare
# `exec </dev/tty` here would HANG, measured: bash would go on reading the rest of THIS script
# from the terminal it just attached. A redirect on a function call applies to the body, and the
# exec inside inherits it, so the argument list stays in one copy.
# bootstrap:reattaches-only-at-the-hand-over is what keeps that true.
#
# THE PROBE IS A SUBSHELL, NOT `exec 3</dev/tty`. A failed exec redirection can end a
# non-interactive shell, and its error is emitted BEFORE a trailing `2>/dev/null` on the same
# line applies -- so the obvious spelling leaks "/dev/tty: Device not configured" to exactly the
# student who has no terminal to read it on. `( : </dev/tty )` cannot exit this shell, leaves no
# descriptor open, and is silent.
hand_over() { exec bash "$BOOT_TREE/$TARGET" "$BOOT_TMP" "$REPO_TAG" "$TAGS_URL"; }

if [ ! -t 0 ] && ( : </dev/tty ) 2>/dev/null; then
    hand_over </dev/tty
fi
hand_over
}
