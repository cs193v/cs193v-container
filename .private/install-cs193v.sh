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
# long download instead of babysitting prompts.

set -u

# ═══════════════════════════════════════════════════════════════════════════════
#  THINGS THE COURSE STAFF EDIT
#
#  This script cannot use messages.txt for its early output, because messages.txt does
#  not exist until the download step succeeds. So the wording lives here instead,
#  gathered in one place. Everything below this block is logic.
# ═══════════════════════════════════════════════════════════════════════════════

REPO_OWNER="CHANGEME"                     # e.g. htiek
REPO_NAME="cs193v"                        # the public course container repo
REPO_BRANCH="main"

MIN_PODMAN="5.7.0"
PODMAN_MACOS_VERSION="6.0.2"              # bump when you re-test; used only on macOS

DEFAULT_DIR="$HOME/cs193v"
WSL_DISTRO="CS193V"

# How much RAM to hand the macOS virtual machine: a share of the Mac's RAM, never so
# much that macOS itself is starved, and capped because a VM does not benefit from more.
MAC_VM_SHARE_PCT=75
MAC_VM_LEAVE_GB=4
MAC_VM_MAX_GB=16
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

TARBALL="https://github.com/$REPO_OWNER/$REPO_NAME/archive/refs/heads/$REPO_BRANCH.tar.gz"

say_welcome() {
cat <<'EOF'

  CS193V setup
  ────────────
  This will set up the course container on your computer. It takes a while, mostly
  downloading. You can leave it running unattended once you have answered the
  questions at the start.

EOF
}

say_intel_mac() {
cat <<'EOF'

  ┏━━ STOP ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
  ┃
  ┃  This Mac has an Intel processor.
  ┃
  ┃  The course container needs a Mac with Apple Silicon (M1 or newer),
  ┃  or a Windows or Linux computer.
  ┃
  ┃  Please contact course staff BEFORE the first lab and we will sort
  ┃  out an alternative for you. This is not something you can fix, and
  ┃  it is not your fault — please do not spend time troubleshooting it.
  ┃
  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛

EOF
}

say_done() {
cat <<EOF

  ────────────────────────────────────────────────────────────────────
  Setup finished.

  To start working:

      cd $DIR
      ./cs193v

  Put your projects in $DIR/projects — inside the container they appear
  at ~/projects.

  Useful later:
      ./cs193v doctor     a report to paste if you ask staff for help
      ./cs193v ports      why can't my browser see my server?
  ────────────────────────────────────────────────────────────────────

EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Logic below here
# ═══════════════════════════════════════════════════════════════════════════════

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$(printf '\033[1;91m'); C_DIM=$(printf '\033[2m')
    C_CYAN=$(printf '\033[1;36m'); C_GRN=$(printf '\033[1;32m'); C_OFF=$(printf '\033[0m')
else
    C_RED=''; C_DIM=''; C_CYAN=''; C_GRN=''; C_OFF=''
fi
ESC=$(printf '\033')

step()  { printf '  %s%s%s\n' "$C_CYAN" "$*" "$C_OFF"; }
ok()    { printf '    %s✓%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
skip()  { printf '    %s· %s (already done)%s\n' "$C_DIM" "$*" "$C_OFF"; }
note()  { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }

die() {
    printf '\n  %s┏━━ STOP ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓%s\n' "$C_RED" "$C_OFF" >&2
    while IFS= read -r l; do printf '  %s┃%s %s\n' "$C_RED" "$C_OFF" "$l" >&2; done <<EOF
$*
EOF
    printf '  %s┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛%s\n' "$C_RED" "$C_OFF" >&2
    printf '\n  Nothing further has been changed. Please send all of the text above to\n' >&2
    printf '  course staff — that is exactly what we need to help.\n\n' >&2
    exit 1
}

# ─── arrow-key menu (never [y/N]) ──────────────────────────────────────────────
MENU_CHOICE=0
menu() {
    local def="$1"; shift
    local opts n sel i key rest
    opts=( "$@" ); n=${#opts[@]}; sel="$def"
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        MENU_CHOICE="$def"; printf '    (not a terminal; choosing "%s")\n' "${opts[$def]}"; return 0
    fi
    while :; do
        i=0
        while [ "$i" -lt "$n" ]; do
            if [ "$i" -eq "$sel" ]; then printf '    %s▸ %s%s\n' "$C_CYAN" "${opts[$i]}" "$C_OFF"
            else printf '      %s\n' "${opts[$i]}"; fi
            i=$((i + 1))
        done
        printf '\n    %s(up and down arrows, then Enter)%s' "$C_DIM" "$C_OFF"
        IFS= read -rsn1 key
        if [ "$key" = "$ESC" ]; then IFS= read -rsn2 rest; key="$key$rest"; fi
        printf '\r%s[K' "$ESC"; printf '%s[%dA%s[J' "$ESC" "$((n + 1))" "$ESC"
        case "$key" in
            "${ESC}[A"|k|K) sel=$(( (sel + n - 1) % n )) ;;
            "${ESC}[B"|j|J) sel=$(( (sel + 1) % n )) ;;
            ''|"$(printf '\n')") break ;;
            [1-9]) if [ "$key" -le "$n" ]; then sel=$((key - 1)); break; fi ;;
        esac
    done
    printf '    %s▸ %s%s\n\n' "$C_CYAN" "${opts[$sel]}" "$C_OFF"
    MENU_CHOICE="$sel"
}

# ─── helpers ───────────────────────────────────────────────────────────────────
version_lt() {
    awk -v a="$1" -v b="$2" 'BEGIN{
        na=split(a,A,"."); nb=split(b,B,".")
        for(i=1;i<=3;i++){x=(i<=na?A[i]+0:0); y=(i<=nb?B[i]+0:0)
            if(x<y){print "yes";exit} if(x>y){print "no";exit}}
        print "no"}'
}

platform() {
    case "$(uname -s)" in
        Darwin) printf 'macos' ;;
        Linux)  if grep -qi microsoft /proc/version 2>/dev/null; then printf 'wsl'
                else printf 'linux'; fi ;;
        *)      die "This script supports macOS, Ubuntu and the WSL CS193V environment.
Your system reports: $(uname -s)" ;;
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

PLAT="$(platform)"
DIR=""
DO_PODMAN_INSTALL=no
DO_SSH_INSTALL=no
DO_MACHINE_INIT=no
DO_MACHINE_RESIZE=no
DO_WSLCONF=no
DO_SUBUID=no

survey() {
    step "Looking at your computer"

    if [ "$PLAT" = macos ] && [ "$(uname -m)" != arm64 ]; then
        say_intel_mac; exit 1
    fi
    ok "$PLAT on $(uname -m)"

    if command -v podman >/dev/null 2>&1; then
        local v; v="$(podman --version 2>/dev/null | awk '{print $NF}')"
        if [ "$(version_lt "${v:-0}" "$MIN_PODMAN")" = yes ]; then
            die "Podman $v is installed, but the course needs $MIN_PODMAN or newer.

Please upgrade podman and run this again:
  Ubuntu / WSL :  sudo apt update && sudo apt install --only-upgrade podman
  macOS        :  open Podman Desktop and let it update itself"
        fi
        ok "podman $v"
    else
        DO_PODMAN_INSTALL=yes
        case "$PLAT" in
            macos) need "Install Podman" \
                        "Podman runs the course container. On a Mac it installs system-wide, so macOS will ask for your password once." ;;
            *)     need "Install podman (and uidmap)" \
                        "Podman runs the course container. Installing software needs your password." ;;
        esac
    fi

    # The ssh CLIENT, not a server. cs193v runs it on this computer to carry the course ports
    # into the container's own loopback; nothing listens for incoming ssh anywhere.
    if command -v ssh >/dev/null 2>&1 && command -v ssh-keygen >/dev/null 2>&1; then
        ok "ssh"
    elif [ "$PLAT" = macos ]; then
        # Every supported macOS ships openssh-client, so this means something unusual about
        # the machine, and guessing at a fix would be worse than saying so.
        die "ssh is missing from this Mac, which should not be possible.
Please contact course staff rather than working around it."
    else
        DO_SSH_INSTALL=yes
        need "Install openssh-client" \
             "cs193v uses ssh on your own computer to connect your browser to servers you run inside the container. Without it the container still works, but nothing in it would be reachable at http://localhost. Installing software needs your password."
    fi

    if [ "$PLAT" = macos ]; then
        if podman machine list --format '{{.Name}}' 2>/dev/null | grep -q .; then
            local vm_mb; vm_mb="$(podman machine inspect --format '{{.Resources.Memory}}' 2>/dev/null | head -1)"
            local want_mb; want_mb="$(mac_vm_target_mb)"
            if [ -n "$vm_mb" ] && [ "$vm_mb" -lt "$(( want_mb * 80 / 100 ))" ]; then
                DO_MACHINE_RESIZE=yes
                need "Give podman's virtual machine more memory (${vm_mb} MB -> ${want_mb} MB)" \
                     "On a Mac, containers run inside a small Linux virtual machine. Podman gives it a fixed amount of memory that does not scale with your Mac, and the default is too small for this course. This changes a virtual machine that already exists on your computer."
            else
                skip "podman virtual machine is a reasonable size"
            fi
        else
            DO_MACHINE_INIT=yes
            ok "podman virtual machine will be created (nothing exists yet)"
        fi
    fi

    if [ "$PLAT" = wsl ]; then
        if [ -f /etc/wsl.conf ] && grep -q '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true' /etc/wsl.conf; then
            skip "systemd is enabled in this WSL environment"
        elif [ -f /etc/wsl.conf ]; then
            DO_WSLCONF=yes
            need "Turn on systemd in this Linux environment" \
                 "Without it, the limit on how much memory the container may use is not actually enforced. /etc/wsl.conf already exists, so this changes a file that is already here."
        else
            DO_WSLCONF=yes
            ok "systemd will be enabled (creating /etc/wsl.conf)"
        fi
    fi

    if [ "$PLAT" != macos ]; then
        if grep -q "^$(id -un):" /etc/subuid 2>/dev/null; then
            skip "your account has the ID range podman needs"
        else
            DO_SUBUID=yes
            need "Give your account a \"subuid range\"" \
                 "Podman uses a block of spare ID numbers to keep the container separated from the rest of your computer. Your account does not have one. This changes a system-wide file and needs your password."
        fi
    fi
}

mac_vm_target_mb() {
    local host_gb share leave
    host_gb=$(( $(host_ram_mb) / 1024 ))
    share=$(( host_gb * MAC_VM_SHARE_PCT / 100 ))
    leave=$(( host_gb - MAC_VM_LEAVE_GB ))
    [ "$share" -gt "$leave" ] && share="$leave"
    [ "$share" -gt "$MAC_VM_MAX_GB" ] && share="$MAC_VM_MAX_GB"
    [ "$share" -lt "$MAC_VM_MIN_GB" ] && share="$MAC_VM_MIN_GB"
    printf '%d' $(( share * 1024 ))
}

ask_consent() {
    if [ "${#NEEDS[@]}" -eq 0 ]; then
        step "Nothing on your computer needs to change"
        return 0
    fi
    printf '\n'
    step "Before continuing, this needs your permission for ${#NEEDS[@]} thing(s)"
    printf '\n'
    local i=0
    while [ "$i" -lt "${#NEEDS[@]}" ]; do
        printf '    %d. %s\n' "$((i + 1))" "${NEEDS[$i]}"
        printf '%s\n' "${NEEDS_WHY[$i]}" | fold -s -w 66 | sed 's/^/       /'
        printf '\n'
        i=$((i + 1))
    done
    menu 0 "Stop, do not change anything" "Go ahead"
    if [ "$MENU_CHOICE" -ne 1 ]; then
        printf '\n  Nothing was changed.\n\n'
        printf '  If you would rather not make these changes, that is fine — please\n'
        printf '  contact course staff and we will work out another way.\n\n'
        exit 0
    fi
}

# ─── steps ─────────────────────────────────────────────────────────────────────
choose_dir() {
    step "Where should the course files go?"
    if [ -n "${CS193V_DIR:-}" ]; then
        DIR="$CS193V_DIR"; ok "$DIR (from CS193V_DIR)"; return
    fi
    if [ ! -t 0 ]; then DIR="$DEFAULT_DIR"; ok "$DIR"; return; fi
    printf '\n'
    menu 0 "$DEFAULT_DIR   (recommended)" "Somewhere else — let me type a path"
    if [ "$MENU_CHOICE" -eq 0 ]; then
        DIR="$DEFAULT_DIR"
    else
        printf '    path: '; IFS= read -r DIR
        case "$DIR" in
            '')  DIR="$DEFAULT_DIR" ;;
            "~"/*) DIR="$HOME/${DIR#~/}" ;;
        esac
    fi
    ok "$DIR"
}

# Installs podman and, on apt platforms, the ssh CLIENT alongside it.
#
# openssh-client belongs here rather than in an error message the launcher prints: it is a
# machine prerequisite exactly like podman and uidmap, and this script is what provisions the
# machine. cs193v uses it to forward the course ports from the student's loopback into the
# container's, so without it the container works but nothing in it is reachable from a
# browser. Macs ship it, and it is not apt-installable there, so DO_SSH_INSTALL is only ever
# set on linux/wsl.
#
# The two are gated INDEPENDENTLY. A machine that already has podman but no ssh is a real
# case — a minimal WSL distro is the likely one — and folding ssh into the podman flag would
# skip it there for no reason.
install_podman() {
    if [ "$DO_PODMAN_INSTALL" = no ] && [ "$DO_SSH_INSTALL" = no ]; then
        skip "podman and openssh-client"; return
    fi
    local pkgs=""
    [ "$DO_PODMAN_INSTALL" = yes ] && pkgs="podman uidmap"
    [ "$DO_SSH_INSTALL" = yes ]    && pkgs="$pkgs openssh-client"
    step "Installing ${pkgs:-podman}"
    case "$PLAT" in
        linux|wsl)
            sudo apt-get update || die "apt-get update failed."
            # shellcheck disable=SC2086
            sudo apt-get install -y $pkgs || die "Could not install $pkgs."
            ;;
        macos)
            local arch pkg url
            arch="$(uname -m)"
            pkg="$(mktemp "${TMPDIR:-/tmp}/podman.XXXXXX").pkg"
            url="https://github.com/containers/podman/releases/download/v${PODMAN_MACOS_VERSION}/podman-installer-macos-${arch}.pkg"
            note "downloading $url"
            if ! curl -fsSL --retry 5 -o "$pkg" "$url"; then
                die "Could not download the podman installer.

You can install Podman Desktop by hand instead — https://podman-desktop.io/downloads/macos
— and then run this script again. It will pick up from here."
            fi
            note "macOS will now ask for your password, to install podman system-wide"
            sudo installer -pkg "$pkg" -target / || die "The podman installer did not finish."
            rm -f "$pkg"
            export PATH="/opt/podman/bin:/usr/local/bin:$PATH"
            ;;
    esac
    command -v podman >/dev/null 2>&1 || die "podman still is not on your PATH after installing.
Try opening a new terminal window and running this script again."
    ok "podman $(podman --version | awk '{print $NF}')"
    if [ "$DO_SSH_INSTALL" = yes ]; then
        command -v ssh >/dev/null 2>&1 || die "ssh still is not on your PATH after installing.
Try opening a new terminal window and running this script again."
        ok "ssh installed"
    fi
}

setup_wslconf() {
    [ "$DO_WSLCONF" = yes ] || return 0
    step "Turning on systemd"
    if [ -f /etc/wsl.conf ] && grep -q '^[[:space:]]*\[boot\]' /etc/wsl.conf; then
        sudo sed -i 's/^[[:space:]]*\[boot\][[:space:]]*$/[boot]\nsystemd=true/' /etc/wsl.conf
    else
        printf '[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf >/dev/null
    fi
    ok "/etc/wsl.conf updated"
    note "This takes effect after Windows restarts this Linux environment."
    note "From Windows PowerShell:  wsl --terminate $WSL_DISTRO"
}

setup_subuid() {
    [ "$DO_SUBUID" = yes ] || return 0
    step "Setting up your account's ID range"
    local u; u="$(id -un)"
    sudo usermod --add-subuids 200000-265535 --add-subgids 200000-265535 "$u" \
        || die "Could not add a subuid range for $u.

Please send this to course staff along with:
    id
    cat /etc/subuid /etc/subgid"
    ok "subuid range added for $u"
}

setup_machine() {
    [ "$PLAT" = macos ] || return 0
    local want; want="$(mac_vm_target_mb)"
    if [ "$DO_MACHINE_INIT" = yes ]; then
        step "Creating podman's virtual machine (${want} MB, ${MAC_VM_DISK_GB} GB disk)"
        podman machine init --memory "$want" --disk-size "$MAC_VM_DISK_GB" --now \
            || die "Could not create the podman virtual machine."
        ok "created and started"
    elif [ "$DO_MACHINE_RESIZE" = yes ]; then
        step "Resizing podman's virtual machine to ${want} MB"
        podman machine stop >/dev/null 2>&1
        podman machine set --memory "$want" || die "Could not resize the podman virtual machine."
        grow_machine_disk
        podman machine start || die "Could not restart the podman virtual machine."
        ok "resized and restarted"
    else
        podman machine start >/dev/null 2>&1 || true
        skip "podman virtual machine"
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
    note "Growing the virtual machine's disk from ${have} GB to ${MAC_VM_DISK_GB} GB,"
    note "which the container build needs. This does not use the space up front."
    podman machine set --disk-size "$MAC_VM_DISK_GB" \
        || note "Could not grow it; continuing. If the build runs out of space, tell course staff."
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

fetch_files() {
    step "Getting the course files"
    mkdir -p "$DIR" || die "Could not create $DIR"
    # Overwrites the course files and leaves projects/ and local.args alone, so this is
    # also how updates arrive.
    #
    # Two independent guards, because a dropped connection on dorm wifi is the single most
    # likely thing to go wrong here and a half-installed course directory is worse than an
    # obvious failure.
    #
    #   pipefail (in a subshell, so it stays local to this one pipeline) makes curl's
    #   failure authoritative instead of relying on tar to notice it. GNU tar does exit 2
    #   on a truncated or empty stream, but that is a property of one tar, not of the
    #   construct — macOS ships a different tar entirely, and "the last command in the pipe
    #   will spot the upstream error" is not something to build on.
    #
    #   The sentinel check below is what catches the case neither status can: an archive
    #   that is well-formed but incomplete extracts cleanly and tar exits 0.
    if ! ( set -o pipefail
           curl -fsSL --retry 10 --retry-delay 3 "$TARBALL" \
             | tar xz --strip-components=1 -C "$DIR" ); then
        die "Could not download the course files from:
    $TARBALL

This is usually a network problem. It is safe to run this script again."
    fi
    # Belt and braces: tar can still exit 0 having written only some entries, so check that
    # the files everything downstream depends on actually arrived.
    for f in cs193v .config/container.args .private/messages.txt .private/Containerfile; do
        [ -s "$DIR/$f" ] || die "The download finished but $f is missing or empty.
That means the transfer was cut short. It is safe to run this script again."
    done
    chmod +x "$DIR/cs193v" || die "Could not make $DIR/cs193v executable."
    mkdir -p "$DIR/projects" "$DIR/.config"
    ok "$DIR"
}

write_local_args() {
    step "Working out how much memory the container may use"
    local total_b total_mb reserve_mb cap_mb
    if ! total_b="$(podman info --format '{{.Host.MemTotal}}' 2>/dev/null)"; then
        die "Could not ask podman how much memory is available.
On a Mac, try:  podman machine start"
    fi
    total_mb=$(( total_b / 1048576 ))

    # The reserve is what actually matters, not a percentage: whatever hosts the
    # container needs a working floor. A VM running nothing but podman needs little; a
    # Linux laptop has the student's whole desktop on the same RAM.
    case "$PLAT" in
        macos|wsl) reserve_mb=$(( total_mb / 10 )); [ "$reserve_mb" -lt 768 ] && reserve_mb=768 ;;
        *)         reserve_mb=$(( total_mb * 35 / 100 )); [ "$reserve_mb" -lt 3072 ] && reserve_mb=3072 ;;
    esac
    cap_mb=$(( total_mb - reserve_mb ))

    {
        printf '# Written by install-cs193v.sh — machine-specific, and git-ignored.\n'
        printf '# Re-run the installer to recompute it; there is no separate command.\n#\n'
        printf '# podman reported %s MB available; reserving %s MB for %s.\n' \
               "$total_mb" "$reserve_mb" \
               "$( [ "$PLAT" = linux ] && printf 'your desktop' || printf 'the virtual machine' )"
    } > "$DIR/.config/local.args"

    if [ "$cap_mb" -lt 1536 ]; then
        printf '# No memory cap set: only %s MB was available, and a cap that low\n' "$cap_mb" >> "$DIR/.config/local.args"
        printf '# would break ordinary work more often than it would help.\n' >> "$DIR/.config/local.args"
        note "Only ${cap_mb} MB would be available to the container — not setting a limit."
        note "Tell course staff if builds fail; this machine is tight on memory."
    else
        printf -- '--memory=%sm\n' "$cap_mb" >> "$DIR/.config/local.args"
        printf -- '-e CS193V_MEMORY_MB=%s\n' "$cap_mb" >> "$DIR/.config/local.args"
        ok "container may use up to ${cap_mb} MB (of ${total_mb} MB)"
    fi
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
    step "Building the course container"
    note "This is the big one, and it is the slow part of this script: it downloads and"
    note "assembles the whole course environment. Leave it running."
    note "It is safe to run this script again — podman keeps every step that finished."
    "$DIR/cs193v" --build || exit 1
    ok "built"
}

# Enough room to BUILD, which is a different question from enough room to run, and the
# threshold is measured rather than guessed. Going from nothing to a running container on a
# clean machine: 224 s, 4.1 GB of transient peak, and 4.3 GB still gone at the end — for an
# image whose reported size is 2.2 GB.
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
        note "Only about ${free_gb} GB is free where podman stores containers."
        note "Setting up needs about 8 GB free. If it stops part-way, free up space"
        note "and re-run this script — it will pick up where it stopped."
    else
        ok "${free_gb} GB free for the container"
    fi
}

smoke_test() {
    step "Checking that it works"
    "$DIR/cs193v" --dev-print-command >/dev/null || die "The launcher could not build a podman command.
Send course staff the output of:  $DIR/cs193v --dev-print-command"
    ok "launcher reads its configuration"
    # That the IMAGE EXISTS, which nothing else here checks. Without this the script can
    # print "Setup finished" over an installation with no runnable container in it --
    # the same shape of failure as ERRORS.md A6, where a truncated download passed.
    if ! podman image exists "$(image_ref)"; then
        die "The course container was not built, but setup did not stop.

Please send this to course staff, along with the output of:
    $DIR/cs193v doctor"
    fi
    ok "course container is present"
    if "$DIR/cs193v" doctor >/dev/null 2>&1; then ok "doctor runs"; else note "doctor reported problems — run: $DIR/cs193v doctor"; fi
}

# Whatever the launcher will actually run: the pin from container.args if staff have set
# one, otherwise the locally built tag. Must stay in step with the launcher's LOCAL_IMAGE
# and its resolve_image; 25-installer.sh asserts they agree.
image_ref() {
    local img
    img="$(sed 's/#.*//' "$DIR/.config/container.args" | awk -F= '/^IMAGE=/{print $2}' | tr -d ' ')"
    printf '%s' "${img:-localhost/cs193v:local}"
}

# ─── main ──────────────────────────────────────────────────────────────────────
say_welcome
survey
choose_dir
ask_consent
install_podman
setup_subuid
setup_wslconf
setup_machine
fetch_files
write_local_args
check_disk
build_image
smoke_test
say_done
