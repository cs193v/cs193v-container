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
# course files, check they arrived, and hand over to course-install.sh inside them. Every
# question you are asked, every package that gets installed and every word you read after
# the next few lines comes from that file, not this one.
#
# WHY IT IS SPLIT THIS WAY. The installer used to be one file, and carried its own copy of
# the course's box-drawing, menus, version comparison and podman-finding code -- because a
# file downloaded on its own has nothing to source. Downloading first means there is
# something to source, so there is now one copy of each instead of two.
#
# WHAT THE PUBLISHED SHA-256 COVERS, stated plainly rather than implied: this file. It is
# the coordinates and the download, which is the part that decides WHICH code runs. The code
# it fetches is the course repository, which is also where ./cs193v and the container recipe
# come from -- so the repository is the trust root either way. See .private/README.md.
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
# TARBALL IS A LITERAL ASSIGNMENT ON ONE LINE, and that is load-bearing rather than a style
# choice. Six places in the test suite repoint the download at a local tarball by rewriting
# `^TARBALL=.*` with sed -- lib/sandbox.sh and 25-installer.sh. A function that composed the URL
# instead would leave every one of them matching nothing, silently, and the cheap test lane would
# go back to making live requests to GitHub.
#
# tarball_url() reads it so that there is exactly one expression to change if the course ever
# pins a commit rather than following a branch. See the issue filed against #221.
REPO_OWNER="cs193v"
REPO_NAME="cs193v-container"
REPO_BRANCH="main"
TARBALL="https://github.com/$REPO_OWNER/$REPO_NAME/archive/refs/heads/$REPO_BRANCH.tar.gz"
tarball_url() { printf '%s\n' "$TARBALL"; }

# ─── the handover contract ─────────────────────────────────────────────────────
# Bumped only when the arguments below change meaning. course-install.sh refuses anything
# lower and says to download this file again -- which is the one thing that goes wrong when a
# student has last quarter's copy sitting in Downloads.
BOOTSTRAP_PROTOCOL=1

# ─── refusals ──────────────────────────────────────────────────────────────────
# PLAIN printf, AND THERE IS NO CATALOGUE IN THIS FILE. Everything this script can refuse
# happens before the course files exist, so there is nothing to read prose out of and nothing
# to draw a box with. That is also the lint boundary: 10-static.sh's text116 rules hold
# course-install.sh to the catalogue and deliberately do not look at this file.
refuse() { printf '\n%s\n\n' "$*" >&2; exit 1; }

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

printf '\n  Getting the course files...\n'
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

      $TARBALL

  Your network is probably fine. What is usually missing is the list of
  certificate authorities, which is a package your system may not have:

      Debian, Ubuntu, Mint, Pop!_OS:  sudo apt install ca-certificates
      Fedora:                         sudo dnf install ca-certificates

  Install it and run this script again." ;;
    esac
    refuse "  Could not download the course files from:

      $TARBALL

  This is usually a network problem. It is safe to run this script again."
fi

# --strip-components=1 because GitHub wraps the archive in a <repo>-<branch>/ directory.
tar xzf "$BOOT_TMP/course.tar.gz" --strip-components=1 -C "$BOOT_TMP" \
    || refuse "  The course files downloaded but could not be unpacked.
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
# NOT AN ARGUMENT, because this file has never parsed any: the other two external switches are
# CS193V_DIR and CS193V_WINDOWS, both read by course-install.sh and neither by this file, and the
# .cmd already knows how to pass a variable (`wsl -e env VAR=value prog args`, which it does for
# DEBIAN_FRONTEND). CS193V_WINDOWS (#218) marks the pass as the one the Windows installer
# launched, which is the whole of what decides which sign-off a student reads at the end.
TARGET=.private/course-install.sh
[ -n "${CS193V_PROVISION:-}" ] && TARGET=.private/wsl-provision.sh

# THE CHECK THAT NEITHER EXIT STATUS CAN MAKE. `curl -f` catches a 404 and a cut-off transfer,
# and tar catches a truncated archive -- but a captive portal answering 200 with its own login
# page is a well-formed reply, and an archive can extract cleanly having written only some of
# what it should. So the pieces the hand-over depends on are checked by name.
#
# $TARGET IS LAST, AND THAT IS THE ORDER RATHER THAN AN AFTERTHOUGHT. In the ordinary case it is
# already the first name in the list, so the message a student sees for a half-arrived archive
# still names course-install.sh; on the root pass it adds the one extra file that run needs.
# course-install.sh stays named unconditionally because boot_cleanup's guard looks for it before
# it will remove anything.
for f in .private/course-install.sh .private/install-utils.sh .private/course-install-messages.txt .private/files/cs193v-ui.sh "$TARGET"; do
    [ -s "$BOOT_TMP/$f" ] || refuse "  The course files arrived but $f is missing or empty.

  That means the transfer was cut short, or something answered for it -- a hotel
  or campus wifi login page, for instance. It is safe to run this script again."
done

# AND STDIN IS PASSED STRAIGHT THROUGH, deliberately. An earlier draft redirected it from
# /dev/null here, on the reasoning that `curl | bash` is not a shipped path so nothing downstream
# reads stdin. That was wrong twice over: the redirect applies to EVERY invocation, not just
# piped ones, and the installer proper reads stdin constantly -- menu() takes arrow keys and
# choose_dir() reads a typed path. Measured: with the redirect in place every pty-driven case
# saw "(not a terminal; choosing ...)" and the consent menu took its safe default, so a student
# could not have answered a single question.
exec bash "$BOOT_TMP/$TARGET" "$BOOTSTRAP_PROTOCOL" "$BOOT_TMP"

# ─── the last line, and why the Windows installer needs one ────────────────────
# install-cs193v-windows.cmd downloads this script into the CS193V environment and greps it for
# the token below BEFORE running it. `curl -f` catches a 404 and a cut-off transfer; what it
# cannot catch is a captive portal answering 200 with its own login page, and it is bash that
# would then run the HTML. The token being LAST is what makes finding it prove that the whole
# file arrived, so this is an identity check and a completeness check at once.
#
# IT PROVES THIS FILE ARRIVED WHOLE, which is all the .cmd needs: this file then checks the
# tree it downloads by name, so each layer verifies what it hands on. course-install.sh
# deliberately has no token of its own -- a truncated archive fails tar, and a missing member
# fails the check above.
#
# KEEP IT LAST, and keep it the only occurrence in this file. 25-installer.sh asserts both, and
# 00-release-gates.sh fetches the published URL and looks for it there.
# CS193V-INSTALLER-COMPLETE
