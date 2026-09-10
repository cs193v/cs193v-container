#!/usr/bin/env bash
#
# CS193V setup, the part that does the work — macOS, Ubuntu, and the WSL CS193V environment.
#
# NOT THE FILE A STUDENT DOWNLOADS. install-cs193v.sh is: it finds a download tool, fetches
# this tree from GitHub, checks the pieces arrived and execs this script with two arguments.
# So this file may source what it downloaded, and the copies of box(), die(), menu(),
# version_lt() and ensure_podman_path() it used to carry are gone (#221).
#
# It ships in the student tarball because it has to be downloaded before it can run; see
# .gitattributes, where it is one of the named exceptions to the .private/ deny rule.
#
# IT IS SAFE TO RUN THE INSTALLER AGAIN. Every step checks whether it is already done, so if
# your wifi drops or you run out of disk part-way through, fix the problem and re-run.
# "Re-run the installer" is also the standard answer when something is broken later.
#
# MUST STAY BASH 3.2 COMPATIBLE — macOS ships bash 3.2. No associative arrays, no
# mapfile, no ${var,,}, no fractional `read -t`.
#
# ─── Two rules this script follows, deliberately ───────────────────────────────
#
#  1. It freely sets up things it created itself. It NEVER changes something that was
#     already on your computer without asking first, explaining what it wants to change
#     and why.
#  2. Anything needing your password is announced before it happens, with the reason.
#
# All the consent questions are asked ONCE, up front, so you can walk away during the
# long build instead of babysitting prompts.

set -u

# ═══════════════════════════════════════════════════════════════════════════════
#  THE SETTINGS COURSE STAFF EDIT
#
#  THE WORDS ARE NOT HERE ANY MORE. Every student-facing string this script prints is in
#  THE TEXT STUDENTS SEE at the foot of the file, reached by `msg <key>` -- one block of prose
#  with no shell syntax in it (issue #116). What is left here is the settings: which podman
#  version to install on a Mac, and how much of a Mac podman's virtual machine gets.
#
#  WHERE THE COURSE FILES COME FROM IS NOT HERE any more -- REPO_OWNER, REPO_NAME,
#  REPO_BRANCH and TARBALL live in install-cs193v.sh, which is the file that does the
#  downloading and the file staff publish. The podman floors moved too, into
#  files/cs193v-ui.sh, so that this script and the launcher read one pair rather than two.
# ═══════════════════════════════════════════════════════════════════════════════

PODMAN_MACOS_VERSION="6.0.2"              # bump when you re-test; used only on macOS
                                          # -- and when you do, check the .pkg still declares
                                          # PODMAN_PKG_ID (now in files/cs193v-ui.sh) in its PackageInfo.

DEFAULT_DIR="$HOME/cs193v"
WSL_DISTRO="CS193V"

# How much RAM to hand the macOS virtual machine. podman's own default is 2048 MB, which is
# too small to build this image, so the size is chosen here rather than left to it.
#
# THE POLICY IS WSL2's, deliberately, because Windows answers the same question for the same
# kind of guest: half the host, capped at 8 GB. Borrowed rather than invented, so the number
# has a reference point outside this project rather than being one person's taste.
#
# WHY A CEILING AT ALL, since two tempting reasons are both false and were measured to be.
# It is NOT that a big VM costs the host that memory up front: on an 8 GB Mac with a 4 GiB
# machine running a container, krunkit's RSS was 0.89 GB, so libkrun demand-pages. And it is
# NOT that the figure is unrevisable: `podman machine set --memory` works on libkrun -- 4096 ->
# 4608 -> 4096, applied and reverted, on podman 6.0.2 -- whatever podman-machine-set(1) says
# about QEMU.
#
# It is that this workload does not benefit from more. The image is 2.48 GB and a cold build
# is 242 s; nothing here scales with a bigger VM, so the ceiling costs a student nothing they
# would have used, and a smaller ceiling leaves more of a laptop for the laptop. Raising it
# for a machine that really needs more is one `machine set --memory` away.
#
# The floor is ours: 4 GB is the smallest VM this build has been seen to work in (ERRORS.md's
# rig had 3.4 GB).
MAC_VM_SHARE_PCT=50
MAC_VM_MAX_GB=8
MAC_VM_MIN_GB=4

# And how much DISK to give it. Sized for a build rather than a download: a measured cold
# build peaks at 4.5 GB of disk to produce a 2.2 GB image (see ERRORS.md B5), and a quarter
# of student projects and node_modules goes on top of that. Set explicitly rather than left to
# podman's default, which is not something this script should silently depend on when the
# machine is now a build host and not just a run host.
#
# Costs nothing up front — the disk image is sparse, so this is a ceiling, not an
# allocation. `podman machine set --disk-size` can only GROW a disk, which is why the
# resize path below checks before asking.
MAC_VM_DISK_GB=64

say_welcome() {
    printf '\n'
    msg welcome
    printf '\n'
}

# Drawn by box() rather than typed out. Hand-drawn, this was the one STOP box in either
# script whose art had drifted — a column narrower than the one die() drew — and the
# missing right edge is why that was invisible for so long (issue #21).
say_intel_mac() {
    printf '\n'
    { printf '\n'; msg err.intel-mac; printf '\n'; } | box STOP "$C_RED" '  '
    printf '\n'
}

# The same shape as say_intel_mac above, and for the same reason: a machine this script cannot
# support is told so at the "Looking at your computer" step, before it has asked permission for
# anything. Asking to install things we have no way to install would be worse than refusing.
#
# NAMED FROM PRETTY_NAME rather than from a list of distros we know about. That is what keeps this
# to one branch: there is no `case` enumerating Arch, NixOS, openSUSE and Alpine, so nothing has to
# be added here when the next one turns up -- os-release supplies the name and the box reads
# correctly for any of them.
#
# WHY ARCH IS HERE and not in the install path: Arch is a rolling release, so pacman can only
# resolve a new package against its sync database, and if that database is ahead of what is
# installed -- which the ArchWiki notes happens whenever a `pacman -Syu` dies after its `-Sy` half
# succeeded -- installing one package upgrades some libraries and not others. That is the "partial
# upgrade" Arch does not support. It is guardable (refuse unless `pacman -Qu` is empty), but on a
# rolling system that usually means refusing anyway, and an Arch user is better served by a
# conversation than by a script guessing. .private/README.md records the full analysis.
say_unsupported_distro() {            # say_unsupported_distro PRETTY_NAME
    printf '\n'
    { printf '\n'
      msg err.unsupported-distro "PRETTY_NAME=${1:-a Linux we do not recognise}"
      printf '\n'; } | box STOP "$C_RED" '  '
    printf '\n'
}

say_done() {
    printf '\n'
    msg finished "DIR=$DIR"
    printf '\n'
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Logic below here
# ═══════════════════════════════════════════════════════════════════════════════

step()  { printf '  %s%s%s\n' "$C_CYAN" "$*" "$C_OFF"; }
ok()    { printf '    %s✓%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
skip()  { printf '    %s· %s %s%s\n' "$C_DIM" "$*" "$(msg skip.suffix)" "$C_OFF"; }

# ─── the text catalogue ────────────────────────────────────────────────────────
# msg <key> [NAME=value ...] -- one entry out of THE TEXT STUDENTS SEE at the foot of this
# file. This is files/cs193v-ui.sh's msg() reading a heredoc instead of a file, and it is a
# fifth deliberate duplication alongside box(), version_lt, menu and ensure_podman_path, for
# the same reason all four exist: this script can source nothing.
#
# THE CATALOGUE IS A FUNCTION, NOT A VARIABLE, and that is not a style preference. The obvious
# `TEXT=$(cat <<'EOF' ... EOF\n)` does not parse: inside a command substitution bash lexes for
# the closing paren before the heredoc is recognised, so the first apostrophe in the prose --
# "the virtual machine's disk" -- opens a quote that never closes. Measured on this machine,
# and it fails at `bash -n`, so it could never have shipped; it is written down because the
# variable form is what anybody would reach for first.
#
# A `#` AT COLUMN 0 INSIDE THE CATALOGUE IS DROPPED, which msg() has no need to do and this
# does. Much of what makes those messages right is the note explaining why they say what they
# say -- see the Mac old-podman refusal -- and without this rule every one of those notes would
# have had to stay behind in the logic, next to a call site that no longer holds the words.

# note() prints exactly one line, so a multi-line advisory is one catalogue entry piped here
# rather than two or three consecutive note calls with the words split across them.
notes() { local l; while IFS= read -r l; do note "$l"; done; }

# ─── helpers ───────────────────────────────────────────────────────────────────
# ─── which family of Linux this is, and what it calls things ───────────────────
#
# PARSED, NOT SOURCED, and that is a deliberate refusal to use the obvious one-liner.
# `. /etc/os-release` would let that file set ANY variable in this script -- $DIR, $PLAT, $PATH --
# and this script runs sudo. It is shell syntax by specification, which is exactly what makes
# sourcing it the wrong tool.
os_release_field() {                  # os_release_field NAME -> its value, unquoted
    sed -n "s/^$1=//p" /etc/os-release 2>/dev/null | head -1 | tr -d '"' | tr -d "'"
}

# ID FIRST, THEN EACH WORD OF ID_LIKE, which is what makes the derivatives free: Linux Mint says
# ID_LIKE=ubuntu, Pop!_OS says "ubuntu debian", Nobara and Bazzite say fedora, Rocky and AlmaLinux
# say "rhel centos fedora". None of them needs naming here.
#
# `rhel` and `centos` are patterns on the fedora arm rather than an arm of their own -- RHEL itself
# is ID=rhel ID_LIKE=fedora and would match anyway, so they are belt-and-braces for a rebuild that
# omits ID_LIKE, not a second code path.
#
# EVERYTHING ELSE IS `unsupported`, INCLUDING ARCH, and survey() refuses it by name. There is no
# list of unsupported distros to keep up to date; see say_unsupported_distro.
distro_family() {                     # distro_family -> debian | fedora | unsupported
    local id like w
    id="$(os_release_field ID)"
    like="$(os_release_field ID_LIKE)"
    # shellcheck disable=SC2086   # deliberately word-split: ID_LIKE is a space-separated list
    for w in $id $like; do
        case "$w" in
            debian|ubuntu)      printf 'debian'; return 0 ;;
            fedora|rhel|centos) printf 'fedora'; return 0 ;;
        esac
    done
    printf 'unsupported'
}

# ─── one table, read by BOTH the consent screen and the install ────────────────
#
# THE POINT IS THAT THERE IS ONE COPY. Before this, every package name appeared twice: once in a
# need() string on the consent screen and again in install_podman's package list. Two places, one
# name, nothing checking they agreed -- and a fix for one family that missed the other would have
# shown a student "Install openssh-client" and then installed something else.
#
# EMPTY IS MEANINGFUL, and only Debian fills these two in:
#   PKG_UIDMAP  the setuid helpers are a RECOMMENDS of podman on Debian, so apt may not pull them
#               and they have to be asked for by name. On Fedora they are in shadow-utils, which
#               also owns usermod and cannot be absent.
#   PKG_CA      ca-certificates is a Recommends there too (installer notes elsewhere that without
#               it curl exits 60 and reads as a network problem). On Fedora it is a dependency of
#               curl and arrives with it.
# So on Fedora both are empty, which is also why the consent text has to tolerate emptiness -- see
# the ${PKG_UIDMAP:+...} expansions in survey().
DISTRO=""
PM_REFRESH=""; PM_INSTALL=""; PM_UPGRADE=""
PKG_PODMAN=""; PKG_UIDMAP=""; PKG_SSH=""; PKG_CURL=""; PKG_CA=""
distro_packages() {                   # distro_packages FAMILY -> sets the PM_/PKG_ globals
    case "$1" in
        debian) PM_REFRESH="apt-get update"; PM_INSTALL="apt-get install -y"
                PM_UPGRADE="sudo apt update && sudo apt install --only-upgrade podman"
                PKG_PODMAN="podman"; PKG_UIDMAP="uidmap"
                PKG_SSH="openssh-client"; PKG_CURL="curl"; PKG_CA="ca-certificates" ;;
        # NO REFRESH STEP, and that is dnf being simpler rather than something omitted: dnf
        # refreshes its own metadata when stale, so there is no `apt-get update` equivalent to get
        # wrong. Measured: `dnf install -y curl` on an already-installed package exits 0 with
        # "Nothing to do.", and `dnf install -y podman <bogus-name>` exits 1 having installed
        # NOTHING -- the transaction is atomic, so a package name we get wrong fails loudly rather
        # than half-installing.
        fedora) PM_REFRESH=""; PM_INSTALL="dnf install -y"
                PM_UPGRADE="sudo dnf upgrade podman"
                PKG_PODMAN="podman"; PKG_UIDMAP=""
                PKG_SSH="openssh-clients"; PKG_CURL="curl"; PKG_CA="" ;;
    esac
}

host_ram_mb() {
    case "$(platform)" in
        macos) printf '%s' "$(( $(sysctl -n hw.memsize) / 1048576 ))" ;;
        *)     awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo ;;
    esac
}

# ─── consent survey ────────────────────────────────────────────────────────────
# Each entry that lands in NEEDS[] is something already on this computer that we would
# have to change, or something that needs the student's password. Nothing is done until
# they say yes.
NEEDS=()
NEEDS_WHY=()
need() { NEEDS[${#NEEDS[@]}]="$1"; NEEDS_WHY[${#NEEDS_WHY[@]}]="$2"; }


survey() {
    step "$(msg step.survey)"

    if [ "$PLAT" = macos ] && [ "$(uname -m)" != arm64 ]; then
        say_intel_mac; exit 1
    fi
    ok "$(msg ok.platform "PLAT=$PLAT" "ARCH=$(uname -m)")"

    # THE SECOND UNSUPPORTED-MACHINE REFUSAL, beside the Intel Mac one above and for the same
    # reason: stop at "Looking at your computer", before ask_consent has offered to change
    # anything. distro_family() returns `unsupported` for everything that is not Debian- or
    # Fedora-family, so Arch, NixOS, openSUSE and Alpine all arrive here without being named
    # anywhere in this script.
    if [ "$PLAT" != macos ] && [ "$DISTRO" = unsupported ]; then
        say_unsupported_distro "$(os_release_field PRETTY_NAME)"; exit 1
    fi

    # ISSUE #121, AND THE SECOND BUG IT CAUSED. Without this, a student re-running this script
    # in the window that ran it the first time is seen as having NO podman -- so it re-downloads
    # 75 MB, asks for the password again, and re-runs `sudo installer`, whose preinstall does
    # `rm -rf /opt/podman` and takes the virtual machine and every container in it. All to
    # reinstall what is already sitting there.
    #
    # IT ALSO CHANGES A REFUSAL, and the next reader will ask, so: a Mac carrying a podman OLDER
    # than MIN_PODMAN_MACOS in a directory PATH does not name is now refused below, where before
    # it was invisible and got silently replaced. That is not a regression. The same refusal
    # already fired for that student in any login shell; what this removes is a refusal that
    # depended on which KIND of shell they happened to type in, which is not a property anybody
    # can report or act on.
    ensure_podman_path
    if [ -n "$PODMAN_PATH_ADDED" ]; then
        msg note.podman-path "DIR=$PODMAN_PATH_ADDED" | notes
    fi
    if command -v podman >/dev/null 2>&1; then
        local v; v="$(podman --version 2>/dev/null | awk '{print $NF}')"
        if [ "$(version_lt "${v:-0}" "$MIN_PODMAN")" = yes ]; then
            # ─── platform-specific, because the right answer differs completely ────────
            #
            # ON LINUX the answer is upgrade: apt has a newer podman or it does not, and if it
            # does not the student is on a release older than the floor admits, which is a
            # conversation with staff rather than a command.
            #
            # ON A MAC the answer is UNINSTALL, and the old message got this wrong in a way worth
            # spelling out. It said "open Podman Desktop and let it update itself" -- but THIS
            # SCRIPT does not install Podman Desktop. It installs the .pkg from podman's GitHub
            # releases into /opt/podman (install_podman below). So a student who ran this script a
            # year ago and now has an old podman was being told to open an application they have
            # never had. Homebrew users likewise.
            #
            # AND UNINSTALL IS BETTER THAN UPGRADE HERE even when Podman Desktop IS present:
            # re-running this script installs PODMAN_MACOS_VERSION, which is the one version the
            # macOS path is tested against, rather than whatever Podman Desktop ships this week.
            #
            # WHICH uninstall depends on how it got there, and `command -v podman` says. Only two
            # cases are possible on a machine this script supports, because Intel Macs are refused
            # outright above: /opt/podman/bin (the .pkg, ours or Podman Desktop's) and
            # /opt/homebrew/bin (Homebrew).
            #
            # NOTHING IS DONE FOR THEM, deliberately. Removing somebody's podman can destroy a
            # `podman machine` VM and every container in it, and this script's whole contract is
            # that it changes nothing without asking (ask_consent). A destructive step the student
            # takes knowingly is right; one this script takes on their behalf, while reporting a
            # version problem, is not.
            if [ "$PLAT" = macos ]; then
                local where how
                where="$(command -v podman 2>/dev/null)"
                case "$where" in
                    /opt/homebrew/*) how="$(msg err.podman-old-mac.how-homebrew)" ;;
                    *)               how="$(msg err.podman-old-mac.how-pkg \
                                            "WHERE=${where:-/opt/podman/bin/podman}")" ;;
                esac
                die "$(msg err.podman-old-mac "V=$v" "MIN=$MIN_PODMAN" "HOW=$how")"
            fi
            # THE COMMAND COMES FROM THE TABLE, so there is one source for it and a family added
            # later cannot be told to run apt. On Debian this renders exactly the string it always
            # did, which is what keeps 25-installer.sh's podman-old:says-how-to-upgrade green.
            die "$(msg err.podman-old-linux "V=$v" "MIN=$MIN_PODMAN" "UPGRADE=$PM_UPGRADE")"
        fi
        ok "$(msg ok.podman "V=$v")"
    else
        DO_PODMAN_INSTALL=yes
        case "$PLAT" in
            macos) need "$(msg need.podman-mac)" "$(msg need.podman-mac.why)" ;;
            *)     need "$(msg need.podman-linux \
                            "PKGS=$PKG_PODMAN${PKG_UIDMAP:+ $(msg need.podman-linux.and "PKG=$PKG_UIDMAP")}")" \
                        "$(msg need.podman-linux.why)" ;;
        esac
    fi

    # The ssh CLIENT, not a server. cs193v runs it on this computer to carry the course ports
    # into the container's own loopback; nothing listens for incoming ssh anywhere.
    if command -v ssh >/dev/null 2>&1 && command -v ssh-keygen >/dev/null 2>&1; then
        ok "$(msg ok.ssh)"
    elif [ "$PLAT" = macos ]; then
        # Every supported macOS ships openssh-client, so this means something unusual about
        # the machine, and guessing at a fix would be worse than saying so.
        die "$(msg err.ssh-missing-mac)"
    else
        DO_SSH_INSTALL=yes
        need "$(msg need.ssh "PKG=$PKG_SSH")" "$(msg need.ssh.why)"
    fi

    # THE DOWNLOAD TOOL, and the one thing this script assumed it could run and could not. curl
    # ships with macOS and is in the Ubuntu WSL image, but it is NOT in the Ubuntu DESKTOP image:
    # the 26.04 and 24.04 manifests both carry wget and libcurl4t64 and no curl. So fetch_files'
    # unguarded curl failed for an entire platform, and told the student "This is usually a
    # network problem" about a machine that had no curl -- after consent, apt and usermod had
    # already run.
    #
    # THE WINDOWS PATH ALREADY SOLVED ITS HALF, and this is the other half rather than a second
    # copy of it. install-cs193v-windows.cmd installs curl inside the CS193V environment before
    # this script exists, because it needs curl to DOWNLOAD it -- so on that path the probe below
    # finds curl and says so. Nothing does that for a student on an Ubuntu desktop, which is the
    # gap this closes.
    #
    # A PREREQUISITE, NOT A FALLBACK. A wget path would double the one pipeline whose
    # pipefail-and-sentinel reasoning is load-bearing, and it would never run on a Mac or on a
    # staff machine, which is the definition of a path that rots. Installing it costs the student
    # nothing extra either: podman and uidmap are absent from that same desktop image, so apt is
    # already running and the password has already been asked for.
    if command -v curl >/dev/null 2>&1; then
        ok "$(msg ok.curl)"
    elif [ "$PLAT" = macos ]; then
        # Every supported macOS ships /usr/bin/curl, so this is the ssh case again -- something
        # unusual about the machine, and guessing at a fix would be worse than saying so.
        die "$(msg err.curl-missing-mac)"
    else
        DO_CURL_INSTALL=yes
        need "$(msg need.curl "PKG=$PKG_CURL")" "$(msg need.curl.why)"
    fi
    # THIS ITEM IS REACHED BY A MACHINE THAT ALREADY DOWNLOADED SUCCESSFULLY, which is the part
    # worth stating: since #221 install-cs193v.sh needs curl OR wget before it can fetch anything,
    # so anyone arriving here has one of the two. A stock Ubuntu Desktop arrives with wget and no
    # curl, and this is where it is offered the curl it is still missing.
    #
    # SO THE REASON CHANGED WITHOUT THE CODE CHANGING. curl is no longer needed to fetch the
    # course files -- that already happened, possibly by wget -- but it is still needed for its
    # own sake: install_podman's macOS arm fetches the .pkg with it, and the launcher uses it
    # afterwards. need.curl.why says that rather than claiming this script does the downloading.
    # 26-installer-sandbox.sh's sb-wget is the case that comes through here.

    # THE SETUID HELPERS, PROBED SEPARATELY FROM PODMAN, which is the entire point. uidmap is
    # already in the package list, but only in the arm that installs podman (install_podman
    # below) -- and on Ubuntu uidmap is a RECOMMENDS of podman rather than a Depends, so the two
    # really do come apart: --no-install-recommends, a podman installed by hand, an image built
    # with recommends off. On a machine like that nothing installed them and nothing noticed.
    #
    # NOT THE SAME QUESTION AS THE SUBUID RANGE BELOW. That is /etc/subuid, the block of id
    # numbers; these are the setuid programs that consume it, and a machine can have either
    # without the other. Without them podman answers everything with `exec: "newuidmap":
    # executable file not found`, and this script stops later in check_podman -- with a message
    # suggesting `podman machine start`, which is a Mac command. Caught here so the diagnosis
    # names the missing package instead.
    if [ "$PLAT" != macos ]; then
        if command -v newuidmap >/dev/null 2>&1 && command -v newgidmap >/dev/null 2>&1; then
            ok "$(msg ok.uidmap)"
        else
            # AN IMPOSSIBLE STATE ON SOME FAMILIES, refused rather than half-handled. PKG_UIDMAP
            # is empty wherever the setuid helpers are not a separable package -- on Fedora they
            # come with shadow-utils, which also owns usermod, so a machine cannot have podman and
            # lack them. If it somehow does, there is no package to name: the consent line would
            # read "Install " and the install would ask for nothing. Same treatment as the missing
            # ssh on a Mac below -- say so and stop, rather than guess.
            if [ -z "$PKG_UIDMAP" ]; then
                die "$(msg err.uidmap-missing)"
            fi
            DO_UIDMAP_INSTALL=yes
            # ONE ITEM PER APT CALL. When podman is being installed, its own consent item already
            # says "(and uidmap)" and its package list already carries it, so a second item here
            # would describe one change twice.
            if [ "$DO_PODMAN_INSTALL" = no ]; then
                need "$(msg need.uidmap "PKG=$PKG_UIDMAP")" "$(msg need.uidmap.why)"
            fi
        fi
    fi

    if [ "$PLAT" = macos ]; then
        if podman machine list --format '{{.Name}}' 2>/dev/null | grep -q .; then
            local vm_mb; vm_mb="$(podman machine inspect --format '{{.Resources.Memory}}' 2>/dev/null | head -1)"
            local want_mb; want_mb="$(mac_vm_target_mb)"
            if [ -n "$vm_mb" ] && [ "$vm_mb" -lt "$(( want_mb * 80 / 100 ))" ]; then
                DO_MACHINE_RESIZE=yes
                need "$(msg need.vm-memory "HAVE=$vm_mb" "WANT=$want_mb")" \
                     "$(msg need.vm-memory.why)"
            else
                skip "$(msg skip.vm-size)"
            fi
        else
            DO_MACHINE_INIT=yes
            ok "$(msg ok.vm-will-be-created)"
        fi
    fi

    if [ "$PLAT" = wsl ]; then
        if [ -f /etc/wsl.conf ] && grep -q '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true' /etc/wsl.conf; then
            skip "$(msg skip.wsl-systemd)"
        elif [ -f /etc/wsl.conf ]; then
            DO_WSLCONF=yes
            need "$(msg need.wslconf)" "$(msg need.wslconf.why)"
        else
            DO_WSLCONF=yes
            ok "$(msg ok.wsl-systemd-planned)"
        fi
    fi

    if [ "$PLAT" != macos ]; then
        if grep -q "^$(id -un):" /etc/subuid 2>/dev/null; then
            skip "$(msg skip.subuid)"
        else
            DO_SUBUID=yes
            need "$(msg need.subuid)" "$(msg need.subuid.why)"
        fi
    fi
}

mac_vm_target_mb() {
    local host_gb share
    host_gb=$(( $(host_ram_mb) / 1024 ))
    share=$(( host_gb * MAC_VM_SHARE_PCT / 100 ))
    [ "$share" -gt "$MAC_VM_MAX_GB" ] && share="$MAC_VM_MAX_GB"
    [ "$share" -lt "$MAC_VM_MIN_GB" ] && share="$MAC_VM_MIN_GB"
    printf '%d' $(( share * 1024 ))
}

ask_consent() {
    if [ "${#NEEDS[@]}" -eq 0 ]; then
        step "$(msg step.nothing-to-change)"
        return 0
    fi
    printf '\n'
    step "$(msg step.consent "N=${#NEEDS[@]}")"
    printf '\n'
    local i=0
    while [ "$i" -lt "${#NEEDS[@]}" ]; do
        printf '    %d. %s\n' "$((i + 1))" "${NEEDS[$i]}"
        printf '%s\n' "${NEEDS_WHY[$i]}" | fold -s -w 66 | sed 's/^/       /'
        printf '\n'
        i=$((i + 1))
    done
    menu 0 "$(msg menu.consent.stop)" "$(msg menu.consent.go)"
    if [ "$MENU_CHOICE" -ne 1 ]; then
        printf '\n'
        msg consent.declined
        printf '\n'
        exit 0
    fi
}

# ─── steps ─────────────────────────────────────────────────────────────────────
choose_dir() {
    step "$(msg step.choose-dir)"
    if [ -n "${CS193V_DIR:-}" ]; then
        DIR="$CS193V_DIR"; ok "$(msg ok.dir-from-env "DIR=$DIR")"; return
    fi
    if [ ! -t 0 ]; then DIR="$DEFAULT_DIR"; ok "$DIR"; return; fi
    printf '\n'
    menu 0 "$(msg menu.dir.default "DEFAULT=$DEFAULT_DIR")" "$(msg menu.dir.other)"
    if [ "$MENU_CHOICE" -eq 0 ]; then
        DIR="$DEFAULT_DIR"
    else
        printf '    %s ' "$(msg prompt.path)"; IFS= read -r DIR
        case "$DIR" in
            '')  DIR="$DEFAULT_DIR" ;;
            # ${DIR#"~"/} WITH THE TILDE QUOTED. The pattern half of a #-expansion is
            # tilde-EXPANDED, so the unquoted form asked to strip a literal "/home/you/"
            # from a string beginning "~/" -- which matches nothing, strips nothing, and
            # built $HOME/~/whatever: the course installed into a directory named "~"
            # inside the student's home. The case pattern above was always right; only the
            # strip was wrong, which is why it looked correct.
            "~"/*) DIR="$HOME/${DIR#"~"/}" ;;
        esac
    fi
    ok "$DIR"
}

# Installs podman and, on apt platforms, whichever of the ssh client, curl and the uidmap
# helpers this machine turns out to be missing.
#
# openssh-client belongs here rather than in an error message the launcher prints: it is a
# machine prerequisite exactly like podman and uidmap, and this script is what provisions the
# machine. cs193v uses it to forward the course ports from the student's loopback into the
# container's, so without it the container works but nothing in it is reachable from a
# browser. Macs ship it, and it is not apt-installable there, so DO_SSH_INSTALL is only ever
# set on linux/wsl.
#
# curl is here for the same reason and on the same terms: this script cannot fetch the course
# files without it, the Ubuntu desktop image does not have it, and macOS and the WSL image both
# do -- so DO_CURL_INSTALL, like DO_SSH_INSTALL, is only ever set on linux/wsl.
#
# ALL FOUR ARE GATED INDEPENDENTLY, and each of the three extras exists because folding it into
# podman's flag skipped it on a machine that really needed it. A machine with podman and no ssh
# is a real case (a minimal WSL distro); a machine with podman and no curl is a real case (any
# Ubuntu desktop where podman was installed by hand); and a machine with podman and no
# newuidmap is a real case, because apt lists uidmap as a RECOMMENDS of podman rather than a
# Depends. uidmap is the one that has to be asked for twice over -- once as part of podman's own
# package list, once on its own -- which is why the two arms below look asymmetric.
install_podman() {
    if [ "$DO_PODMAN_INSTALL" = no ] && [ "$DO_SSH_INSTALL" = no ] \
       && [ "$DO_CURL_INSTALL" = no ] && [ "$DO_UIDMAP_INSTALL" = no ]; then
        skip "$(msg skip.prereqs)"; return
    fi
    # ${pkgs:+$pkgs } RATHER THAN "$pkgs name", so an empty list does not open with a space.
    # It never showed while the only way in was a machine missing podman as well: `Installing
    # podman uidmap openssh-client` reads the same either way. A machine missing nothing but
    # curl printed `Installing  curl`, with two spaces, the first time one existed.
    local pkgs=""
    [ "$DO_PODMAN_INSTALL" = yes ] && pkgs="$PKG_PODMAN${PKG_UIDMAP:+ $PKG_UIDMAP}"
    [ "$DO_SSH_INSTALL" = yes ]    && pkgs="${pkgs:+$pkgs }$PKG_SSH"
    # ca-certificates WITH IT, for the reason install-cs193v-windows.cmd gives where it installs
    # the same pair: without them curl exits 60, and an SSL failure reads as a network problem
    # just like a missing curl did. Present in every image we checked, so this is usually a no-op
    # -- but a machine minimal enough to lack curl is exactly the one that might lack these too.
    [ "$DO_CURL_INSTALL" = yes ]   && pkgs="${pkgs:+$pkgs }$PKG_CURL${PKG_CA:+ $PKG_CA}"
    # ONLY WHEN PODMAN IS NOT ALREADY BRINGING IT, or apt would be handed the same name twice.
    [ "$DO_PODMAN_INSTALL" = no ] && [ "$DO_UIDMAP_INSTALL" = yes ] && pkgs="${pkgs:+$pkgs }$PKG_UIDMAP"
    step "$(msg step.installing "PKGS=${pkgs:-podman}")"
    case "$PLAT" in
        linux|wsl)
            # ONE REFRESH STEP, AND ONLY WHERE THERE IS ONE. apt needs its index refreshed
            # before installing or it can 404 on a version the mirror has moved past; dnf
            # refreshes its own metadata when stale, so PM_REFRESH is empty there and this line
            # does nothing. Not a special case for Fedora -- an absent step rather than a
            # different one.
            # shellcheck disable=SC2086   # deliberately word-split: PM_REFRESH is a command line
    [ -n "$PM_REFRESH" ] && { sudo $PM_REFRESH || die "$(msg err.refresh-failed "CMD=$PM_REFRESH")"; }
            # shellcheck disable=SC2086   # deliberately word-split: both are lists of words
            sudo $PM_INSTALL $pkgs || die "$(msg err.install-failed "PKGS=$pkgs")"
            ;;
        macos)
            local arch pkg url
            arch="$(uname -m)"
            pkg="$(mktemp "${TMPDIR:-/tmp}/podman.XXXXXX").pkg"
            url="https://github.com/containers/podman/releases/download/v${PODMAN_MACOS_VERSION}/podman-installer-macos-${arch}.pkg"
            note "$(msg note.downloading "URL=$url")"
            if ! curl -fsSL --retry 5 -o "$pkg" "$url"; then
                die "$(msg err.podman-download)"
            fi
            note "$(msg note.password)"
            sudo installer -pkg "$pkg" -target / || die "$(msg err.podman-installer)"
            rm -f "$pkg"
            # NOT `export PATH="/opt/podman/bin:/usr/local/bin:$PATH"`. Where the .pkg puts
            # things is now asked of the receipt it just wrote rather than assumed here, so this
            # script and the launcher cannot disagree about it -- which was #121's mechanism.
            #
            # THE ONE ORDERING ASSUMPTION IN THE CHANGE: `installer -pkg` must have registered
            # its receipt by the time it returns. It has on every Mac this was tried on, and it
            # is what pkgutil reads. No fixture can stand in for it, so it is a by-hand check in
            # tests/MANUAL.md rather than an assertion here.
            ensure_podman_path
            ;;
    esac
    # NOT "try opening a new terminal window" any more, which is what the other three below
    # still say. For podman on a Mac that advice is now known-insufficient: a non-login shell
    # never runs /etc/zprofile, so it never reads /etc/paths.d, so a new window fixes this for
    # some students and not others (issue #121). Reaching here means the receipt did not answer
    # either, which is a changed .pkg rather than anything the student can do.
    command -v podman >/dev/null 2>&1 || die "$(msg err.podman-unrunnable)"
    ok "$(msg ok.podman-version "V=$(podman --version | awk '{print $NF}')")"
    if [ "$DO_SSH_INSTALL" = yes ]; then
        command -v ssh >/dev/null 2>&1 || die "$(msg err.ssh-not-on-path)"
        ok "$(msg ok.ssh-installed)"
    fi
    # ASKED FOR AGAIN AFTER INSTALLING, per prerequisite, for the reason the podman check above
    # gives: apt can exit 0 having put something somewhere this shell's PATH does not look, and
    # the next step to notice would be a download that fails like a network problem.
    if [ "$DO_CURL_INSTALL" = yes ]; then
        command -v curl >/dev/null 2>&1 || die "$(msg err.curl-not-on-path)"
        ok "$(msg ok.curl-installed)"
    fi
    if [ "$DO_UIDMAP_INSTALL" = yes ]; then
        command -v newuidmap >/dev/null 2>&1 || die "$(msg err.uidmap-not-on-path)"
        ok "$(msg ok.uidmap-installed)"
    fi
}

setup_wslconf() {
    [ "$DO_WSLCONF" = yes ] || return 0
    step "$(msg step.wslconf)"
    if [ -f /etc/wsl.conf ] && grep -q '^[[:space:]]*\[boot\]' /etc/wsl.conf; then
        sudo sed -i 's/^[[:space:]]*\[boot\][[:space:]]*$/[boot]\nsystemd=true/' /etc/wsl.conf
    else
        printf '[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf >/dev/null
    fi
    ok "$(msg ok.wslconf)"
    msg note.wslconf-restart "DISTRO=$WSL_DISTRO" | notes
}

setup_subuid() {
    [ "$DO_SUBUID" = yes ] || return 0
    step "$(msg step.subuid)"
    local u; u="$(id -un)"
    sudo usermod --add-subuids 200000-265535 --add-subgids 200000-265535 "$u" \
        || die "$(msg err.subuid-failed "USER=$u")"
    ok "$(msg ok.subuid "USER=$u")"
}

setup_machine() {
    [ "$PLAT" = macos ] || return 0
    local want; want="$(mac_vm_target_mb)"
    if [ "$DO_MACHINE_INIT" = yes ]; then
        step "$(msg step.machine-create "WANT=$want" "DISK=$MAC_VM_DISK_GB")"
        podman machine init --memory "$want" --disk-size "$MAC_VM_DISK_GB" --now \
            || die "$(msg err.machine-create)"
        ok "$(msg ok.machine-created)"
    elif [ "$DO_MACHINE_RESIZE" = yes ]; then
        step "$(msg step.machine-resize "WANT=$want")"
        podman machine stop >/dev/null 2>&1
        podman machine set --memory "$want" || die "$(msg err.machine-resize)"
        grow_machine_disk
        podman machine start || die "$(msg err.machine-restart)"
        ok "$(msg ok.machine-resized)"
    else
        podman machine start >/dev/null 2>&1 || true
        skip "$(msg skip.machine)"
        grow_machine_disk_when_stopped
    fi
}

# A machine that predates this script — or one created before the container was something
# students build rather than download — can have a disk too small to build in. Growing it
# is safe and reversible in the only direction that matters: podman refuses to SHRINK a
# machine disk, so this only ever asks when the current size is smaller, and treats a
# refusal as non-fatal because a too-small disk fails later with a message that names it.
#
# `.Resources.DiskSize` is in GB while `.Resources.Memory` two functions up is in MB — an
# inconsistency in podman's own output, not a typo here. If that ever changed to bytes the
# comparison would simply always be satisfied and this would quietly stop growing anything,
# which is the harmless direction for it to fail in.
grow_machine_disk() {
    local have
    have="$(podman machine inspect --format '{{.Resources.DiskSize}}' 2>/dev/null | head -1)"
    case "$have" in ''|*[!0-9]*) return 0 ;; esac
    [ "$have" -ge "$MAC_VM_DISK_GB" ] && return 0
    msg note.growing-disk "HAVE=$have" "WANT=$MAC_VM_DISK_GB" | notes
    podman machine set --disk-size "$MAC_VM_DISK_GB" \
        || note "$(msg note.grow-failed)"
}

# The same, for the path where nothing else needed the machine stopped. `podman machine
# set` requires a stopped machine, so this stops it only if there is actually work to do.
grow_machine_disk_when_stopped() {
    local have
    have="$(podman machine inspect --format '{{.Resources.DiskSize}}' 2>/dev/null | head -1)"
    case "$have" in ''|*[!0-9]*) return 0 ;; esac
    [ "$have" -ge "$MAC_VM_DISK_GB" ] && return 0
    podman machine stop >/dev/null 2>&1
    grow_machine_disk
    podman machine start >/dev/null 2>&1 || true
}

# The course files are already downloaded -- the bootstrap fetched them before this script
# existed. What is left is putting them where the student asked for them, which is why this is
# `install_files` and not `fetch_files` any more (#221).
#
# tar AGAIN RATHER THAN A COPY, and the reason is the semantics rather than the cost: extracting
# over the top overwrites the course files and leaves projects/ alone, so this is also how
# updates arrive. A `mv` would refuse an existing $DIR and would take projects/ with it.
#
# STILL AFTER THE MACHINE WORK, deliberately. The student's tree is created only once podman is
# installed and working, so a run that fails earlier leaves no half-installed course directory
# -- which is what sb-fed:no-course-tree and sb-arch:no-course-tree assert.
#
# THE SENTINEL CHECK STAYS, and it is not redundant with the bootstrap's. That one proved the
# ARCHIVE arrived whole; this one proves the extraction landed, which is a different failure:
# tar can exit 0 having written only some entries, and $DIR can be out of space or unwritable.
# chmod below catches only the launcher.
install_files() {
    step "$(msg step.fetch)"
    mkdir -p "$DIR" || die "$(msg err.mkdir-failed "DIR=$DIR")"
    tar xzf "$BOOT_TARBALL" --strip-components=1 -C "$DIR" \
        || die "$(msg err.unpack-failed "DIR=$DIR")"
    for f in cs193v .config/container.args .private/messages.txt .private/Containerfile; do
        [ -s "$DIR/$f" ] || die "$(msg err.unpack-incomplete "FILE=$f")"
    done
    chmod +x "$DIR/cs193v" || die "$(msg err.chmod-failed "DIR=$DIR")"
    mkdir -p "$DIR/projects" "$DIR/.config"
    ok "$DIR"
}

# INSTALLED IS NOT THE SAME AS WORKING, and the difference is worth a step of its own.
# `podman --version` never touches the runtime, so it answers happily from a podman that
# cannot create a user namespace: a missing uidmap, a restrictive AppArmor profile, a nosuid
# mount, or a Mac whose virtual machine is not running. `podman info` is the cheapest question
# that needs the runtime, so all of those surface here, with a message that names the fix.
#
# BEFORE build_image, so the diagnosis arrives ahead of the long step rather than out of the
# launcher part-way through a build a student has already waited on.
#
# `{{.Host.Arch}}` rather than a field podman grew recently: a Go template naming a missing
# STRUCT field fails the whole call, so a field that has always existed keeps this a test of
# the runtime rather than of the podman version.
check_podman() {
    step "$(msg step.check-podman)"
    if ! podman info --format '{{.Host.Arch}}' >/dev/null 2>&1; then
        die "$(msg err.podman-mute)"
    fi
    ok "$(msg ok.podman-working)"
}

# Build the course container, rather than download one.
#
# There is no registry and no published image: the Containerfile that arrived with the
# course files IS the distribution, and every student assembles it here. Delegated to the
# launcher rather than calling `podman build` directly, so the command a student runs on
# day one is the same code path staff exercise daily -- including its retry, its
# out-of-disk message and the recipe label the launcher later checks for staleness.
#
# The launcher prints its own progress and draws its own STOP box on failure, so this
# adds neither.
build_image() {
    step "$(msg step.build)"
    msg note.build-slow | notes
    # --rebuild, which reads oddly for a first install and is right anyway: it is the launcher's
    # only container-creating verb, and with no image on the machine yet its first act is to
    # build one. There is deliberately no separate --build to call -- one verb means the path a
    # student takes on day one cannot drift from the one staff run every day.
    #
    # Nothing here needs a terminal: --rebuild prompts for nothing, which is what lets this run
    # under `curl | bash` and under the test suite alike.
    "$DIR/cs193v" --rebuild || exit 1
    ok "$(msg ok.built)"
}

# Enough room to BUILD, which is a different question from enough room to run, and the
# threshold is measured rather than guessed. Going from nothing to a running container on a
# clean machine: 224 s, 4.1 GB of transient peak, and 4.3 GB still gone at the end — for an
# image whose reported size is 2.2 GB.
#
# THOSE FIGURES PREDATE CODEX, which took the image to 2.48 GB (2,477,510,743 bytes, from
# 2,165,835,982) and a cold build to 242 s, both measured on the development machine. The peak and
# retained numbers are deliberately NOT adjusted: they were measured from nothing on a CLEAN graph
# root, a rebuild in place does not reproduce that, and scaling them by the image delta would be
# arithmetic dressed as measurement. The 8 GB floor below was chosen with roughly 3.7 GB of
# headroom over the 4.3 GB it cites, so ~312 MB more image does not exhaust it — but a genuine
# re-measurement needs a clean machine and is worth doing before the quarter.
#
# TWO costs, and the second is the one that surprises. The build peaks above its own result
# because at each step's commit the same bytes exist in the layers already written, in the
# working container, and in the new layer being computed from it; the in-step cleanups that
# keep the final image small (`rm -rf /var/lib/apt/lists/*`, `npm cache clean --force`) add
# to the peak precisely because those bytes are fetched, unpacked and discarded without ever
# reaching a layer. Then CREATING the container costs roughly the image's size AGAIN:
# --userns=keep-id makes podman write an ID-mapped copy of every layer (ERRORS.md D-series).
# That second cost lands after the build, which is why retained (4.3 GB) exceeds peak (4.1).
#
# 8 GB rather than the 4.3 GB actually consumed, because a later REBUILD transiently holds
# the old image and its ID-mapped copy alongside the new ones — measured to fail with
# "no space left on device" at container-create time with 7.8 GB free.
#
# Do NOT size this from `podman system df` or from an image's reported size. Both are
# logical figures: they said 2.2 GB where the store on disk held 6.7 GB. Checked before the
# long step rather than after it, because the alternative is telling a student they are out
# of disk part-way through a build they have already waited out.
#
# Advisory: it warns and continues rather than refusing. podman's figures are for the
# graph root's own filesystem -- inside the virtual machine on macOS and WSL -- and a
# wrong guess must not block an install that would have worked.
check_disk() {
    local out alloc used free_gb
    out="$(podman info --format '{{.Store.GraphRootAllocated}} {{.Store.GraphRootUsed}}' 2>/dev/null)" || return 0
    alloc="${out%% *}"; used="${out##* }"
    case "$alloc" in ''|*[!0-9]*) return 0 ;; esac
    case "$used"  in ''|*[!0-9]*) return 0 ;; esac
    [ "$alloc" -gt 0 ] || return 0
    free_gb=$(( (alloc - used) / 1073741824 ))
    if [ "$free_gb" -lt 8 ]; then
        msg note.low-disk "FREE=$free_gb" | notes
    else
        ok "$(msg ok.disk-free "FREE=$free_gb")"
    fi
}

smoke_test() {
    step "$(msg step.smoke)"
    "$DIR/cs193v" --dev-print-command >/dev/null || die "$(msg err.launcher-config "DIR=$DIR")"
    ok "$(msg ok.launcher-config)"
    # That the IMAGE EXISTS, which nothing else here checks. Without this the script can
    # print "Setup finished" over an installation with no runnable container in it --
    # the same shape of failure as ERRORS.md A6, where a truncated download passed.
    #
    # The tag is spelled out rather than derived. It used to be read out of container.args,
    # because a pin there could name a registry image instead -- there is no pin any more and
    # the launcher's IMAGE is a constant, so parsing anything would be parsing to find out
    # what is written here. Deliberately unsuffixed: CS193V_INSTANCE is a staff development
    # tool and the installer never runs under one (see CLAUDE.md).
    if ! podman image exists localhost/cs193v:local; then
        die "$(msg err.image-missing-after-build "DIR=$DIR")"
    fi
    ok "$(msg ok.container-present)"
    if "$DIR/cs193v" doctor >/dev/null 2>&1; then ok "$(msg ok.doctor-runs)"
    else note "$(msg note.doctor-problems "DIR=$DIR")"; fi
}

# ═══════════════════════════════════════════════════════════════════════════════
#  THE TEXT STUDENTS SEE
#
#  Every word this script prints, in one place so it can be re-tuned without reading a line of
#  logic. install-cs193v-windows.cmd has had this shape from the start -- its ten refusals are
#  echo-only blocks in one tail section, reached by name -- and issue #116 is this file catching
#  up with it.
#
#  EDIT FREELY. Nothing above depends on the phrasing, only on the keys. 20-messages.sh checks
#  that the keys and the calls still agree, so a renamed key fails and a reworded message does
#  not, which is the distinction worth having.
#
#  Each block starts with [[key]] on its own line and runs to the next [[key]].
#  {{PLACEHOLDER}} is filled in at runtime. A line starting with # at column 0 is a note to
#  staff and is never printed -- indent a line a student has to see.
#
#  THE ORDER IS THE ORDER A STUDENT MEETS THEM, which is how the .cmd's tail is arranged too.
#
#  WIDTHS MATTER IN TWO PLACES, and nowhere else. Anything reaching die() or one of the STOP
#  boxes is wrapped by box() at 67 columns, so hand-chosen line breaks survive as written and
#  an over-long line re-wraps rather than breaching the wall. Every need.*.why is folded to 66
#  columns by ask_consent, so those are written as one long line on purpose. The rest prints
#  exactly as it is written here.
#
#  House style, worth keeping: say what happened, say what to do, and never make a student
#  guess whether something is their mistake or ours.
# ═══════════════════════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════════════════════
#  THE HANDOVER FROM THE BOOTSTRAP  (#221)
#
#  install-cs193v.sh is the file a student downloads. It finds a download tool, fetches this
#  tree, checks the pieces arrived, and execs this script. Everything from here on can source
#  what it downloaded, which is why the copies of box(), die(), menu(), version_lt() and
#  ensure_podman_path() that used to live in this file are gone.
#
#  TWO ARGUMENTS, and no more, because the coverage door has to be able to fabricate them:
#  95-installer-coverage.sh traces this file directly rather than through the exec, so a wide
#  handover would be a wide surface for the door's copy of it to drift against.
# ═══════════════════════════════════════════════════════════════════════════════

BOOTSTRAP_PROTOCOL_WANTED=1
BOOT_PROTOCOL="${1:-}"
BOOT_TMP="${2:-}"
# THE TARBALL IS AT A FIXED NAME INSIDE IT, which is what keeps the handover to two arguments.
BOOT_TARBALL="$BOOT_TMP/course.tar.gz"
# AND THE PROSE, OUT OF THE SAME TREE. Every student-facing string this script prints comes from
# here, read by cs193v-ui.sh's msg() -- the same reader the launcher uses against its own
# catalogue, which is what let this file delete its near-identical copy of it.
#
# SET BEFORE ANYTHING CAN REFUSE. msg() with no readable file prints "(catalogue missing: ...)",
# and that would be what a student saw INSTEAD of every refusal below, including the
# unsupported-OS one -- so this assignment has to be above the resolved-state block rather than
# beside the other paths. 20-messages.sh's die:* cases render a real refusal end to end, which is
# what would catch it being moved back down.
#
# shellcheck disable=SC2034   # read by msg(), which lives in the sourced cs193v-ui.sh
MESSAGES="$BOOT_TMP/.private/course-install-messages.txt"

# A FLOOR, NOT AN EQUALITY, and the difference from cs193v-portwatch's handshake is worth
# naming: that one compares a fixed string because both ends ship in the same tarball, and this
# one cannot -- the bootstrap is published on the course website and can be older than the tree
# it fetched. So a student running last quarter's download gets a sentence rather than a
# mystery. Bumped only when the two lines above change meaning.
if [ -z "$BOOT_PROTOCOL" ] || [ -z "$BOOT_TMP" ]; then
    printf '\n  This is not meant to be run directly.\n\n' >&2
    printf '  Run install-cs193v.sh instead -- it fetches the course files that this\n' >&2
    printf '  script needs, then starts it.\n\n' >&2
    exit 1
fi
if [ "$BOOT_PROTOCOL" -lt "$BOOTSTRAP_PROTOCOL_WANTED" ] 2>/dev/null; then
    printf '\n  The installer you ran is from an older version of the course.\n\n' >&2
    printf '  Download it again and re-run it:\n' >&2
    printf '    https://github.com/%s/%s\n\n' "cs193v" "cs193v-container" >&2
    exit 1
fi

# ─── and this script now owns the temp tree ────────────────────────────────────
# THE BOOTSTRAP CANNOT REMOVE IT, and that is not an oversight in either file. It sets
# `trap ... EXIT` over the tree, which covers every way it can fail -- but the hand-over is
# `exec`, and exec REPLACES the process and discards its traps. Measured. So from this line on
# the tree is this script's, and without the trap below every install anyone ever ran would
# leave a full unpacked copy of the course repository in /tmp. That was live for one commit;
# install:the-bootstrap-temp-tree-is-removed and half-tree:leaves-no-temp-tree-behind are what
# keep it from coming back, one per side of the hand-over.
#
# THE GUARD IS NOT DEFENSIVE PROGRAMMING. $BOOT_TMP arrives as an ARGUMENT, in the file that
# goes on to run `sudo $PM_INSTALL`, and the command it reaches is `rm -rf`. So the path has to
# earn it: a directory, named the way the bootstrap names one, under the temp directory, and
# holding the tree the bootstrap unpacked. `$2=/` fails the basename test, since ${x##*/} of
# `/` is empty.
#
# AN INTERRUPTED RUN STILL LEAVES ONE, and that is ordinary rather than a hole -- a trap does
# not run when the process is KILLED. The bootstrap's fixed `cs193v-install.` prefix is what
# lets a later sweep recognise one; lib/assert.sh's sweep_stale_tmpdirs records the doctrine.
#
# ONE EXIT TRAP, because cs193v-ui.sh forbids setting one and every consumer owns its own. #219
# adds the meter's state file to this same handler rather than a second trap.
boot_tmp_is_ours() {
    case "${BOOT_TMP##*/}" in cs193v-install.??????) ;; *) return 1 ;; esac
    case "$BOOT_TMP" in "${TMPDIR:-/tmp}"/*|/tmp/*) ;; *) return 1 ;; esac
    [ -d "$BOOT_TMP" ] && [ -f "$BOOT_TMP/.private/course-install.sh" ]
}
boot_cleanup() { boot_tmp_is_ours && rm -rf "$BOOT_TMP"; }
trap boot_cleanup EXIT

# ─── the shared presentation layer ─────────────────────────────────────────────
# The same file the launcher sources, out of the tree the bootstrap just unpacked. A missing one
# gets a plain printf rather than a box, for the reason cs193v gives where it does the same: a
# script with no box() cannot draw the box that would report the problem.
UI="$BOOT_TMP/.private/files/cs193v-ui.sh"
if [ ! -r "$UI" ]; then
    printf 'course-install: cannot read %s\n' "$UI" >&2
    printf 'The download is incomplete. Please run install-cs193v.sh again.\n' >&2
    exit 1
fi
# shellcheck source-path=SCRIPTDIR
# shellcheck source=files/cs193v-ui.sh
. "$UI"

# ─── and the four knobs that make it draw the way this script draws ────────────
# Everything here prints inside an indented step list, so notes, menus and STOP boxes sit two
# columns deeper than the launcher's, and a refusal signs off by naming staff. Those were the
# three reasons this file used to carry its own note(), die() and menu().
NOTE_INDENT='    '
MENU_INDENT='    '
MENU_HINT="$(msg menu.hint)"
DIE_INDENT='  '
DIE_TRAILER="$(msg die.trailer)"

# platform() comes from the shared file and prints `other` for an OS it does not know, because
# the launcher wants to report one rather than refuse it. This script refuses, and the refusal
# has to happen where the words are.
#
# THE `|| exit 1` BELOW IS STILL LOAD-BEARING for the same reason it always was: the die() in
# here runs inside a command substitution, which is a subshell, so its exit ends the subshell
# and nothing else.
platform_or_die() {
    local p; p="$(platform)"
    [ "$p" = other ] && die "$(msg err.unsupported-os "OS=$(uname -s)")"
    printf '%s' "$p"
}

# ─── the state the whole flow reads, resolved once ─────────────────────────────
# BELOW THE HAND-OVER BLOCK, and the constraint is now harder than the one it replaces. It used
# to be "below the catalogue", because the catalogue was a function in this file and platform()'s
# refusal could not be worded before text_catalogue() was defined. Moving the prose into
# course-install-messages.txt dissolves that and puts something stricter in its place: MESSAGES
# must already POINT AT the catalogue when the line below runs, or msg() has no file to read and
# every refusal in this script -- the unsupported-OS one included -- degrades to
# "(catalogue missing: ...)". The hand-over block sets it, which is why that block is above this
# one and not merely earlier for tidiness.
#
# These lines run where the interpreter meets them; everything else in this script is a function
# definition, so this block is the only thing the ordering constrains.
#
# `|| exit 1`, and it is load-bearing. platform() ends in a die() for an OS this script does
# not support, and die() exits -- but a command substitution is a SUBSHELL, so that exit
# ended the subshell and nothing else: the STOP box was printed, PLAT was set to the empty
# string, and the script carried on to install as though this were Linux, having just told
# the student "Nothing further has been changed". Exit status propagates out of an
# assignment, so this is the whole fix.
PLAT="$(platform_or_die)" || exit 1
# RESOLVED HERE, not at the top, because it depends on PLAT -- and PLAT cannot be known until
# platform() has run and had its chance to refuse an unsupported OS. Everything downstream reads
# MIN_PODMAN and does not care which floor it came from.
if [ "$PLAT" = macos ]; then
    MIN_PODMAN="$MIN_PODMAN_MACOS"
else
    MIN_PODMAN="$MIN_PODMAN_LINUX"
    # THE SAME SEAM, for the same reason: this depends on PLAT, and macOS has no /etc/os-release to
    # read. survey() is what refuses an unsupported family -- see say_unsupported_distro.
    DISTRO="$(distro_family)"
    distro_packages "$DISTRO"
fi
DIR=""
DO_PODMAN_INSTALL=no
DO_SSH_INSTALL=no
DO_CURL_INSTALL=no
DO_UIDMAP_INSTALL=no
DO_MACHINE_INIT=no
DO_MACHINE_RESIZE=no
DO_WSLCONF=no
DO_SUBUID=no

# ─── main ──────────────────────────────────────────────────────────────────────
say_welcome
survey
choose_dir
ask_consent
install_podman
setup_subuid
setup_wslconf
setup_machine
install_files
check_podman
check_disk
build_image
smoke_test
say_done

