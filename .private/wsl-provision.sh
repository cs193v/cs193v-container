#!/usr/bin/env bash
#
# CS193V setup — preparing a brand-new CS193V WSL instance, as root, so that the student's own
# install needs no password (#217).
#
# NOT THE FILE A STUDENT DOWNLOADS, and not the installer either. install-cs193v.sh is what a
# student downloads; it fetches this tree, and execs THIS file instead of course-install.sh when
# CS193V_PROVISION is set in the environment. Only install-cs193v-windows.cmd sets it, and only
# for the instance it created seconds earlier.
#
# ─── what this is for ─────────────────────────────────────────────────────────
#
# The Windows installer used to create the CS193V environment by launching it, which fires
# Ubuntu's first-run setup: a student picked a username and a password, answered a question about
# usage statistics, and had to type `exit` to get back to the installer. Three questions and one
# instruction, none of which taught anybody anything. With --no-launch and this file, none of
# them happen.
#
# Which leaves the account, and the reason there are two passes rather than one. The install
# needs root -- on Ubuntu it installs podman and uidmap -- and an account created without a
# password cannot use sudo: sudo does not fail fast on a locked password, it PROMPTS, and then
# rejects whatever is typed. So a student would have met a password prompt they could not
# possibly answer, at the longest and latest step. Instead this pass does everything that needs
# root, out of the installer's own table of steps, and the student's pass then does the rest with
# no sudo at all.
#
# ─── the two rules this file follows, and the one it is exempt from ───────────
#
# course-install.sh promises never to change something that was already on your computer without
# asking. This file changes /etc/passwd, /etc/wsl.conf and the package set of a whole operating
# system without asking anybody anything -- and that is inside the rule rather than an exception
# to it, because the operating system in question was created by install-cs193v-windows.cmd about
# a minute earlier and nothing else has ever run in it. The .cmd makes the same argument where it
# installs curl. What would breach the rule is running here at all in an instance somebody else
# made, which is why stage 1 refuses an environment that already has an account, and why
# provision_account below refuses one too.
#
# IT RUNS NOTHING STUDENT-SUPPLIED, and keeps itself short for that reason. Stage 1 runs as
# Administrator, so the `wsl -d ... -e` calls it makes -- including the one that starts this file
# -- get the ELEVATED DrvFs mount of C:. Root in WSL is not Administrator on Windows (as root,
# `ls "/mnt/c/System Volume Information"` is refused, because DrvFs access is mediated by the
# launching process's Windows token) but that mount namespace question is open, recorded under
# #155, and the honest answer to an open question about privilege is to do less in it.
#
# MUST STAY BASH 3.2 COMPATIBLE — macOS ships bash 3.2. Nothing here will ever run on a Mac, but
# 10-static.sh holds every shipped script to one dialect and one exception is how a file drifts.

set -u

# ─── the constants stage 1 shares with this file ───────────────────────────────
# THE NAME IS FIXED, AND IT IS THE CONTAINER'S OWN (ERRORS.md A1, .private/Containerfile). The
# same word inside the container and outside it means the path a student is handed --
# \wsl.localhost\CS193V\home\student\cs193v\projects -- can be written down concretely instead
# of with a placeholder they have to substitute. install-cs193v-windows.cmd carries its own copy
# as LINUX_USER, and 25-installer.sh fails if the two disagree.
WSL_USER="student"

# WHERE THE OOBE CONFIGURATION GOES. Ubuntu wires its first-run setup up through
# /etc/wsl-distribution.conf's [oobe] command; moving the file aside makes a bare launch print
# nothing at all while still completing WSL's handshake, after which the service stops setting a
# default uid of its own and /etc/wsl.conf decides. Kept beside the original rather than deleted:
# it is reversible, and it is self-documenting to the next person reading /etc.
OOBE_CONF="/etc/wsl-distribution.conf"
OOBE_CONF_MOVED="/etc/wsl-distribution.conf.cs193v"

# THE GROUPS ARE UPSTREAM'S, VERBATIM. This is DEFAULT_GROUPS from Canonical's wsl-setup, which
# is what would have created this account had the OOBE run. All five are in base-passwd, so they
# exist in any Ubuntu rootfs -- nothing here has to create a group. `sudo` among them is not a
# contradiction with the locked password below: it is what makes `wsl -u root` unnecessary the day
# staff decide to set a password, and leaving it out would be a difference from upstream with no
# reason behind it.
NEW_USER_GROUPS="adm,cdrom,sudo,dip,plugdev"

# ─── the handover from the bootstrap ───────────────────────────────────────────
# THE SAME TWO ARGUMENTS course-install.sh TAKES, and the same floor check, because the bootstrap
# has one exec line for both targets and a second contract would be a second thing to get wrong.
BOOTSTRAP_PROTOCOL_WANTED=1
BOOT_PROTOCOL="${1:-}"
BOOT_TMP="${2:-}"
MESSAGES="$BOOT_TMP/.private/course-install-messages.txt"

if [ -z "$BOOT_PROTOCOL" ] || [ -z "$BOOT_TMP" ]; then
    printf '\n  This is not meant to be run directly.\n\n' >&2
    printf '  It is run for you by install-cs193v-windows.cmd, inside the CS193V\n' >&2
    printf '  environment it creates.\n\n' >&2
    exit 1
fi
if [ "$BOOT_PROTOCOL" -lt "$BOOTSTRAP_PROTOCOL_WANTED" ] 2>/dev/null; then
    printf '\n  The installer you ran is from an older version of the course.\n\n' >&2
    printf '  Download it again and re-run it:\n' >&2
    printf '    https://github.com/%s/%s\n\n' "cs193v" "cs193v-container" >&2
    exit 1
fi

# ─── the shared code, in the same order course-install.sh sources it ───────────
# install-utils.sh FIRST, because boot_cleanup is in it and the exit trap cannot be armed until
# the function it names exists. A missing one leaves the temp tree behind deliberately: the
# `rm -rf` is guarded by boot_tmp_is_ours, and the guard is in the file that just turned out to
# be unreadable.
UTILS="$BOOT_TMP/.private/install-utils.sh"
if [ ! -r "$UTILS" ]; then
    printf 'wsl-provision: cannot read %s\n' "$UTILS" >&2
    printf 'The download is incomplete. Please run install-cs193v.sh again.\n' >&2
    exit 1
fi
# shellcheck source-path=SCRIPTDIR
# shellcheck source=install-utils.sh
. "$UTILS"
trap boot_cleanup EXIT

UI="$BOOT_TMP/.private/files/cs193v-ui.sh"
if [ ! -r "$UI" ]; then
    printf 'wsl-provision: cannot read %s\n' "$UI" >&2
    printf 'The download is incomplete. Please run install-cs193v.sh again.\n' >&2
    exit 1
fi
# shellcheck source-path=SCRIPTDIR
# shellcheck source=files/cs193v-ui.sh
. "$UI"

# The same four knobs course-install.sh sets, so that a refusal from this pass looks exactly like
# a refusal from the pass a student sees a minute later. Nothing about the box or the step list
# should tell them which half of the installer they are looking at.
NOTE_INDENT='    '
MENU_INDENT='    '
MENU_HINT="$(msg menu.hint)"
DIE_INDENT='  '
DIE_TRAILER="$(msg die.trailer)"

step()  { printf '  %s%s%s\n' "$C_CYAN" "$*" "$C_OFF"; }
ok()    { printf '    %s✓%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
skip()  { printf '    %s· %s %s%s\n' "$C_DIM" "$*" "$(msg skip.suffix)" "$C_OFF"; }

# ═══════════════════════════════════════════════════════════════════════════════
#  The steps
# ═══════════════════════════════════════════════════════════════════════════════

# ─── 1. refuse anything that is not the situation this file was written for ────
# THREE QUESTIONS, ASKED BEFORE ANYTHING IS CHANGED. Is this WSL, am I root, and does sudo work?
#
# THE SUDO ONE LOOKS REDUNDANT AND IS NOT. Every privileged call in the installer goes through
# `sudo`, including the ones this pass makes as root, because that single name is what lets the
# test suite replace privilege with a recorder that never execs (install-utils.sh says more).
# As root it is a no-op -- measured on Ubuntu 26.04 with sudo-rs 0.2.13: `sudo -n true` exits 0
# and /etc/sudoers carries Ubuntu's stock `root ALL=(ALL:ALL) ALL`. The two ways that could stop
# being true are an image with no sudo at all and a hardened sudoers that does not list root, and
# both of them are better as a refusal here than as a failure four steps down with an account
# already created.
provision_guards() {
    local p; p="$(platform)"
    [ "$p" = wsl ] || die "$(msg err.prov-not-wsl "PLAT=$p")"
    [ "$(id -u)" = 0 ] || die "$(msg err.prov-not-root "USER=$(id -un)")"
    sudo -n true 2>/dev/null || die "$(msg err.prov-no-sudo)"
}

# ─── 2. the first-run setup, off before there is an account gap to fall into ───
# `mv`, NOT `truncate -s 0`, and the difference matters. truncate CREATES the file if it is absent
# and exits 0, so the day Canonical moves the OOBE configuration somewhere else, truncate would
# silently succeed while leaving the first-run setup armed -- and a student would meet it, in a
# Start Menu window, in the middle of an install. `mv` fails loudly instead, which is why the
# else arm below is a refusal rather than a shrug.
#
# ALREADY MOVED IS A SKIP, and that is what makes a resumed run work: stage 1 moves this file
# immediately after --install, before it downloads anything, so by the time this pass runs it is
# normally already done. Doing it here as well covers the run that died in between.
provision_oobe_off() {
    if [ -f "$OOBE_CONF" ]; then
        sudo mv "$OOBE_CONF" "$OOBE_CONF_MOVED" || die "$(msg err.prov-oobe-move "FILE=$OOBE_CONF")"
        ok "$(msg prov.ok.oobe-off)"
    elif [ -f "$OOBE_CONF_MOVED" ]; then
        skip "$(msg prov.skip.oobe-off)"
    else
        die "$(msg err.prov-oobe-missing "FILE=$OOBE_CONF")"
    fi
}

# ─── 3. the account ───────────────────────────────────────────────────────────
# NO PASSWORD IS SET, AND NOTHING LATER SETS ONE. useradd writes `!` to /etc/shadow, so the
# account is locked: no student is ever asked to invent a Linux password, and `sudo` cannot work
# for them -- which is exactly why this pass exists. A NOPASSWD sudoers drop-in was measured and
# rejected (#217): the container is the sandbox, and this instance is the sandbox's HOST with the
# whole of C: attached, so root here could rewrite /etc, the podman configuration and the systemd
# units. Staff and students reach root with `wsl -d CS193V -u root`, and a password can be granted
# later with `wsl -d CS193V -u root -e passwd student` if one is ever wanted.
#
# NO --uid 1000. ERRORS.md A1 is this repo being bitten by `useradd: UID 1000 is not unique` when
# a base image shipped its own uid-1000 account, and .config/container.args reads the host uid
# from getuid() at launch, so pinning the number buys nothing and can only fail.
#
# THE FOREIGN-ACCOUNT REFUSAL IS THE SECOND OF TWO. Stage 1 probes for an account before it runs
# this file at all, and refuses an environment that has one that is not ours -- because that is
# somebody's work, most likely a CS193V made by last quarter's installer, and creating a second
# account there would change their default user and their home directory silently. This copy of
# the refusal is what stops the same thing happening to anyone who runs this file by hand.
provision_account() {
    if getent passwd "$WSL_USER" >/dev/null 2>&1; then
        skip "$(msg prov.skip.account "USER=$WSL_USER")"
        return 0
    fi
    local other
    other="$(awk -F: '$3 >= 1000 && $3 < 65000 { print $1; exit }' /etc/passwd)"
    [ -n "$other" ] && die "$(msg err.prov-foreign-account "USER=$other" "WANT=$WSL_USER")"
    sudo useradd --create-home --shell /bin/bash --groups "$NEW_USER_GROUPS" "$WSL_USER" \
        || die "$(msg err.prov-useradd "USER=$WSL_USER")"
    ok "$(msg prov.ok.account "USER=$WSL_USER")"
}

# ─── 4. which account WSL starts you in ───────────────────────────────────────
# /etc/wsl.conf's `[user] default=` RATHER THAN THE REGISTRY, and that is a decision. WSL keeps a
# DefaultUid per distribution in the Windows registry, and `wsl --manage X --set-default-user`
# writes it -- but the guest's own wsl.conf overrides it (measured both ways), it travels with an
# --export/--import, and it needs no new verb on the Windows side. Stage 1 stays a file that
# creates an environment and hands over.
#
# AND IT IS MANDATORY, NOT OPTIONAL, because of step 2. Once /etc/wsl-distribution.conf is gone,
# WSL's OOBE handshake has no defaultUid to adopt and leaves DefaultUid at 0 -- so without this
# stanza a student would land as root, and the install would go into /root.
#
# WRITTEN AFTER THE ACCOUNT EXISTS. The one genuinely bad middle state here is a wsl.conf naming
# a user who is not in /etc/passwd, so the order of steps 3 and 4 is load-bearing.
provision_default_user() {
    if [ -f /etc/wsl.conf ] && grep -q "^[[:space:]]*default[[:space:]]*=[[:space:]]*${WSL_USER}[[:space:]]*$" /etc/wsl.conf; then
        skip "$(msg prov.skip.default-user "USER=$WSL_USER")"
        return 0
    fi
    # A [user] STANZA THAT NAMES SOMEBODY ELSE IS A REFUSAL. On the path this file is written for
    # there is no [user] stanza at all -- the image ships [boot] and nothing else -- so anything
    # here is a decision somebody made, and overwriting it would be the one thing an installer
    # must not do to a machine it did not create.
    if [ -f /etc/wsl.conf ] && grep -q '^[[:space:]]*default[[:space:]]*=' /etc/wsl.conf; then
        die "$(msg err.prov-default-user-taken "WANT=$WSL_USER")"
    fi
    printf '\n[user]\ndefault=%s\n' "$WSL_USER" | sudo tee -a /etc/wsl.conf >/dev/null \
        || die "$(msg err.prov-wslconf "USER=$WSL_USER")"
    ok "$(msg prov.ok.default-user "USER=$WSL_USER")"
}

# ─── 5. everything that needs root, out of the installer's own list ───────────
# THE LIST IS NOT HERE, AND THAT IS THE POINT (#217). ROOT_STEPS lives in install-utils.sh beside
# the functions it names, and course-install.sh calls those same functions for a student on a Mac
# or a Linux box. This loop names none of them: if it did, a step added to the installer would
# have to be remembered here too, and the day somebody forgot, a student would meet a sudo prompt
# on an account with no password -- the one failure this whole arrangement exists to prevent.
# 10-static.sh asserts that this loop stays a loop.
#
# WHAT TO INSTALL IS PROBED, NOT ASSUMED. The Ubuntu WSL image ships curl and ssh but no podman
# and no uidmap, so this normally resolves to two packages -- but which two comes from the table,
# and whether each is needed comes from asking this machine the same questions survey() asks a
# student's. An image that stops shipping curl is then absorbed rather than discovered later, by
# a student, as a download that failed.
#
# ca-certificates RIDES WITH curl, exactly as install_podman does it: without it curl exits 60
# and an SSL failure reads as a network problem.
provision_root_steps() {
    PKGS=""
    command -v podman    >/dev/null 2>&1 || PKGS="$PKGS $PKG_PODMAN"
    command -v newuidmap >/dev/null 2>&1 || PKGS="$PKGS $PKG_UIDMAP"
    command -v ssh       >/dev/null 2>&1 || PKGS="$PKGS $PKG_SSH"
    command -v curl      >/dev/null 2>&1 || PKGS="$PKGS ${PKG_CURL}${PKG_CA:+ $PKG_CA}"
    PKGS="$(printf '%s' "$PKGS" | sed 's/^ *//;s/  */ /g')"
    if [ -n "$PKGS" ]; then
        step "$(msg step.installing "PKGS=$PKGS")"
    else
        skip "$(msg prov.skip.packages)"
    fi
    TARGET_USER="$WSL_USER"
    local s
    for s in $ROOT_STEPS; do
        "root_step_$s"
    done
    # ASKED AGAIN AFTERWARDS, because a package manager exiting 0 is not the same claim as "the
    # program is on the PATH now" -- the standard install-cs193v-windows.cmd sets for itself
    # where it re-probes curl after apt. Without this, a student's pass would be the first thing
    # to notice, and it would notice as a podman that cannot start a container.
    command -v podman    >/dev/null 2>&1 || die "$(msg err.prov-no-podman)"
    command -v newuidmap >/dev/null 2>&1 || die "$(msg err.prov-no-uidmap)"
    ok "$(msg prov.ok.root-steps)"
}

# ─── main ─────────────────────────────────────────────────────────────────────
# NO CONSENT SCREEN AND NO MENU, and nothing here reads stdin: this pass runs in a window nobody
# is watching, between two things stage 1 printed. See the rule block in the header for why that
# is inside course-install.sh's promise rather than an exception to it.
step "$(msg prov.step.preparing)"
provision_guards
provision_oobe_off
provision_account
provision_default_user
provision_root_steps
