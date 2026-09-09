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
# `^TARBALL=.*` with sed -- lib/sandbox.sh, 25-installer.sh and 10-static.sh -- and one of them
# asserts the rewrite preserves this file's line numbering. A function that composed the URL
# instead would leave every one of them matching nothing, silently, and the cheap test lane
# would go back to making live requests to GitHub.
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
# curl AND NOTHING ELSE, for now. A wget arm is coming, because curl is absent from the Ubuntu
# DESKTOP image -- the 24.04 and 26.04 manifests both carry wget and libcurl4t64 and no curl --
# but an arm no test can reach is the "path that rots" this project has refused twice, so it
# lands with the fixture that exercises it rather than ahead of it.
find_download_tool() {
    command -v curl >/dev/null 2>&1 && { printf 'curl'; return 0; }
    return 1
}

TOOL="$(find_download_tool)" || refuse "  This needs curl to download the course files, and cannot find it.

  Install it and run this again:

      Debian, Ubuntu, Mint, Pop!_OS:  sudo apt install curl ca-certificates
      Fedora:                         sudo dnf install curl

  ca-certificates matters as much as curl does: without it the download fails
  with a certificate error that reads like a network problem."

# ─── fetch, check, hand over ───────────────────────────────────────────────────
# A PREDICTABLE PREFIX, so that a run killed part-way leaves something a later sweep can
# recognise. The trap removes the tree on every path that returns -- and deliberately does NOT
# fire on the hand-over below, because `exec` replaces this process and takes its traps with
# it. course-install.sh owns the tree from that point and removes it itself.
BOOT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cs193v-install.XXXXXX")" \
    || refuse "  Could not create a temporary directory. Is the disk full?"
trap 'rm -rf "$BOOT_TMP"' EXIT

printf '\n  Getting the course files...\n'
"$TOOL" -fsSL --retry 10 --retry-delay 3 -o "$BOOT_TMP/course.tar.gz" "$(tarball_url)" \
    || refuse "  Could not download the course files from:

      $TARBALL

  This is usually a network problem. If it says something about certificates,
  install ca-certificates and try again. It is safe to run this script again."

# --strip-components=1 because GitHub wraps the archive in a <repo>-<branch>/ directory.
tar xzf "$BOOT_TMP/course.tar.gz" --strip-components=1 -C "$BOOT_TMP" \
    || refuse "  The course files downloaded but could not be unpacked.
  That usually means the transfer was cut short. It is safe to run this script again."

# THE CHECK THAT NEITHER EXIT STATUS CAN MAKE. `curl -f` catches a 404 and a cut-off transfer,
# and tar catches a truncated archive -- but a captive portal answering 200 with its own login
# page is a well-formed reply, and an archive can extract cleanly having written only some of
# what it should. So the pieces the hand-over depends on are checked by name.
for f in .private/course-install.sh .private/files/cs193v-ui.sh; do
    [ -s "$BOOT_TMP/$f" ] || refuse "  The course files arrived but $f is missing or empty.

  That means the transfer was cut short, or something answered for it -- a hotel
  or campus wifi login page, for instance. It is safe to run this script again."
done

# THE TRACE FLAG DOES NOT SURVIVE exec, measured -- so pass it on when the harness asked for a
# trace. CS193V_COVERAGE is the harness's own gate and is already in this environment;
# BASH_XTRACEFD and PS4 cross the exec by themselves, because both are exported.
#
# AND STDIN IS PASSED STRAIGHT THROUGH, deliberately. An earlier draft redirected it from
# /dev/null here, on the reasoning that `curl | bash` is not a shipped path so nothing downstream
# reads stdin. That was wrong twice over: the redirect applies to EVERY invocation, not just
# piped ones, and the installer proper reads stdin constantly -- menu() takes arrow keys and
# choose_dir() reads a typed path. Measured: with the redirect in place every pty-driven case
# saw "(not a terminal; choosing ...)" and the consent menu took its safe default, so a student
# could not have answered a single question.
xt=''
[ -n "${CS193V_COVERAGE:-}" ] && xt=-x
# shellcheck disable=SC2086   # deliberately word-split: an empty $xt must vanish, not become ''
exec bash $xt "$BOOT_TMP/.private/course-install.sh" "$BOOTSTRAP_PROTOCOL" "$BOOT_TMP"

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
