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

REPO_OWNER="cs193v"
REPO_NAME="cs193v-container"
REPO_BRANCH="main"

# ─── the oldest podman the course works with, per platform ─────────────────────
#
# TWO FLOORS, NOT ONE, and the asymmetry is the point. On LINUX the floor decides which distros
# a student can use, because a distro ships whatever podman it ships: 4.9.0 admits Ubuntu 24.04
# LTS (4.9.3) and everything built on it -- Linux Mint 22.x, Pop!_OS 24.04 -- plus Debian 13
# stable (5.4.2), Ubuntu 25.04/25.10 and Fedora 42/43 from GA media. Measured rather than
# assumed: podman 4.9.3, 5.4.2 and 5.7.0 each ran the whole install and built the entire course
# image, with inner stores within 22 KB of each other (26-installer-sandbox.sh, oldest-supported).
#
# ON A MAC THE FLOOR DECIDES NOTHING ABOUT DISTROS, so it buys nothing to lower it, and lowering
# it would cost something real: `podman machine` was rewritten completely in podman 5.0, and this
# script leans on it hard -- machine init --memory --disk-size --now, machine set --memory,
# machine set --disk-size, machine inspect --format {{.Resources.*}}. None of that is reachable
# by any test we can run, because macOS is not container-testable. When podman is ABSENT on a Mac
# this script installs PODMAN_MACOS_VERSION below, so the floor only ever applies to a Mac that
# already had one -- and for that Mac, refusing with clear instructions beats proceeding into an
# implementation nobody has exercised.
#
# So the two move on their own schedules. tests/25-installer.sh asserts that each floor agrees
# with the launcher's copy of it, and that the macOS floor is never below the Linux one.
MIN_PODMAN_LINUX="4.9.0"
MIN_PODMAN_MACOS="5.7.0"
PODMAN_MACOS_VERSION="6.0.2"              # bump when you re-test; used only on macOS
                                          # -- and when you do, check the .pkg still declares
                                          # PODMAN_PKG_ID below in its PackageInfo.

# ─── where podman is when it is not on PATH ────────────────────────────────────
# ISSUE #121, whose mechanism is written up in full beside the launcher's copy of this. In
# brief: the macOS .pkg announces its binaries with one line in /etc/paths.d, nothing reads
# /etc/paths.d but path_helper, and path_helper runs from /etc/zprofile -- so THIS SCRIPT'S OWN
# TERMINAL cannot see podman after installing it, and neither can the ./cs193v the student runs
# next. THAT HALF IS THE LAUNCHER'S TO FIX and it does; what is fixed here is this script's own
# two needs -- finding a podman it installed a moment ago, and not offering to install one that
# is already there but invisible.
#
# DUPLICATED VERBATIM FROM cs193v, the way version_lt and box() are: this script is curl-piped
# and standalone, so it cannot source anything. 25-installer.sh diffs the two copies, for the
# reason it asserts the podman floors agree -- this script runs FIRST and the launcher runs
# LAST, so a disagreement between them IS issue #121 over again.
PODMAN_PKG_ID="com.redhat.podman"
# Which directory the repair had to add. Empty means PATH was already right; survey() reports it.
PODMAN_PATH_ADDED=""

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

# Drawn by box() rather than typed out. Hand-drawn, this was the one STOP box in either
# script whose art had drifted — a column narrower than the one die() drew — and the
# missing right edge is why that was invisible for so long (issue #21).
say_intel_mac() {
    printf '\n'
    box STOP "$C_RED" '  ' <<'EOF'

This Mac has an Intel processor.

The course container needs a Mac with Apple Silicon (M1 or newer),
or a Windows or Linux computer.

Please contact course staff BEFORE the first lab and we will sort
out an alternative for you. This is not something you can fix, and
it is not your fault — please do not spend time troubleshooting it.

EOF
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
    box STOP "$C_RED" '  ' <<EOF

This computer is running ${1:-a Linux we do not recognise}.

The course container works on Ubuntu and Debian, on Fedora, on
a Mac with Apple Silicon, and on Windows through WSL. It very
likely works here too -- but this script installs software for
you, and it does not know the right way to do that on this
system.

Please contact course staff. Setting this up with you by hand
is quick, and we would rather do that than have this script
guess and change something it should not.

EOF
    printf '\n'
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

  Closing the terminal window stops the container and anything running
  in it. Your files are on your own computer, so they are always safe.

  Useful later:
      ./cs193v doctor     a report to paste if you ask staff for help
      ./cs193v --stop     stop it if a window was closed unexpectedly
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

# The STOP box, in display columns, corners included. See the launcher: this block, and
# box() below it, are duplicated VERBATIM from cs193v the way version_lt already is —
# this script is curl-piped and standalone, so it cannot source anything. 20-messages.sh
# diffs the two copies and renders both.
BOX_W=71

# Draws the STOP box around whatever it is given on stdin. $1 is a left indent.
#
# Duplicated verbatim in install-cs193v.sh, the way version_lt already is: the installer is
# curl-piped and standalone, so it cannot source anything from here. 20-messages.sh renders
# BOTH copies and asserts the same shape of both.
#
# awk, and LC_ALL=C awk in particular, because the padding has to be measured in DISPLAY
# COLUMNS and every other way of doing that is wrong somewhere we ship:
#
#   * bash's ${#s} counts characters only in a UTF-8 locale and BYTES in the C locale, so
#     a student with LC_ALL=C would see every line containing — or § padded two columns
#     short. Measured: 32 vs 34 for the same string.
#   * awk's own length() is not multibyte-aware in mawk (Ubuntu's default), which scores
#     the ━ border at 3× and is exactly how an earlier width check passed vacuously.
#
# Stripping UTF-8 continuation bytes (0x80-0xBF) and counting what is left turns a byte
# count into a character count with no locale involved at all. Verified identical under
# gawk, mawk and busybox awk. Everything the box ever contains is a narrow character;
# nothing here would survive CJK, and nothing routes CJK to it.
box() {
    LC_ALL=C awk -v w="$BOX_W" -v title="${1:-STOP}" -v red="${2-$C_RED}" \
                 -v ind="${3:-}" -v off="$C_OFF" '
        function dw(s,  t) { t = s; gsub(/[\200-\277]/, "", t); return length(t) }
        # The first n display columns of s, kept whole: a multibyte character is never
        # sliced down the middle, which is what a byte-wise substr would do.
        function dsub(s, n,  i, c, out, cnt) {
            out = ""; cnt = 0
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c ~ /[\200-\277]/) { out = out c; continue }
                if (cnt >= n) break
                cnt++; out = out c
            }
            return out
        }
        function rule(n,  s) { s = ""; while (n-- > 0) s = s "━"; return s }
        function row(text,  pad, n) {
            pad = ""; n = lim - dw(text)
            while (n-- > 0) pad = pad " "
            printf "%s%s┃%s %s%s %s┃%s\n", ind, red, off, text, pad, red, off
        }
        # Wrap rather than spill. err.create-failed interpolates raw podman output, which is
        # written to no width at all and cannot be hand-wrapped in messages.txt -- only here.
        # A line that already fits is emitted untouched, so the hand-chosen line breaks in
        # messages.txt survive exactly as written.
        function put(text,  lead, rest, chunk, k, brk) {
            # Continuation lines keep the original indent, so a wrapped "    cs193v doctor"
            # stays visibly one item rather than starting a new column.
            lead = text; sub(/[^ ].*$/, "", lead)
            if (dw(lead) >= lim) lead = ""
            rest = text
            while (dw(rest) > lim) {
                chunk = dsub(rest, lim)
                brk = 0
                for (k = length(chunk); k > length(lead); k--)
                    if (substr(chunk, k, 1) == " ") { brk = k; break }
                if (brk > 0) {
                    row(substr(chunk, 1, brk - 1))
                    rest = lead substr(rest, brk + 1)
                } else {
                    # No space to break at: a container id, a URL or a deep path. Broken
                    # hard, because the alternative is breaching the wall we just drew.
                    row(chunk)
                    rest = lead substr(rest, length(chunk) + 1)
                }
            }
            if (dw(rest) > dw(lead) || dw(text) <= lim) row(rest)
        }
        # "┏━━ " is four columns and " " plus "┓" is two, so the rule takes what a title of
        # this width leaves. Measured with dw() like everything else, so a title is free to
        # contain whatever the messages do.
        BEGIN {
            lim = w - 4
            # Built rather than passed in, so this function stays copy-pasteable into
            # install-cs193v.sh with nothing else to keep in step. See the note above.
            esc = sprintf("%c", 27)
            printf "%s%s┏━━ %s %s┓%s\n", ind, red, title, rule(w - 6 - dw(title)), off
        }
        # A tab has no defined width inside a box, and podman emits them. So do COLOUR
        # SEQUENCES and CARRIAGE RETURNS, and those two are worse than untidy, because this box
        # interpolates raw podman output verbatim -- err.build-failed carries the tail of
        # $BUILD_LOG, and err.create-failed the whole of a failure:
        #
        #   * dw() measures a colour sequence as the columns its BYTES would occupy, so a line
        #     carrying one comes out 11 columns short and takes the right wall in with it;
        #   * a \r sends the rest of the row back to column 0 on the way to the terminal, over
        #     the wall this has already drawn.
        #
        # Found by feeding a realistic build log to it rather than by reading one: apt, npm and
        # the Playwright download all emit both, and neither can appear in messages.txt where
        # somebody might have noticed it.
        {
            t = $0
            gsub(esc "\\[[0-9;?]*[A-Za-z]", "", t)
            gsub(esc ".", "", t)
            # Only the last segment of a self-overwriting line was ever on a screen.
            n = split(t, seg, "\r")
            if (n > 1) { t = ""; for (i = n; i >= 1; i--) if (seg[i] != "") { t = seg[i]; break } }
            gsub(/\t/, " ", t)
            put(t)
        }
        END { printf "%s%s┗%s┛%s\n", ind, red, rule(w - 2), off }
    '
}

die() {
    printf '\n' >&2
    printf '%s\n' "$*" | box STOP "$C_RED" '  ' >&2
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

# Byte-identical to the launcher's copy -- see PODMAN_PKG_ID above, and do not "tidy" one of
# them. 25-installer.sh :: probe:the-two-copies-are-byte-identical carves both and diffs them.
ensure_podman_path() {
    command -v podman >/dev/null 2>&1 && return 0
    [ "$(platform)" = macos ] || return 1
    command -v pkgutil >/dev/null 2>&1 || return 1
    local loc rel d
    loc="$(pkgutil --pkg-info "$PODMAN_PKG_ID" 2>/dev/null | awk '/^location:/{print $2}')"
    [ -n "$loc" ] || return 1
    rel="$(pkgutil --only-files --files "$PODMAN_PKG_ID" 2>/dev/null \
           | grep -E '(^|/)podman$' | head -1)"
    [ -n "$rel" ] || return 1
    # The payload path's directory, and the volume-relative case where there isn't one. Spelled
    # as a case rather than ${rel%/*}, which returns its input unchanged when there is no slash
    # and would compose a directory one level too deep.
    case "$rel" in
        */*) d="/$loc/${rel%/*}" ;;
        *)   d="/$loc" ;;
    esac
    # -f AS WELL AS -x, because `[ -x somedir ]` is TRUE for a directory (measured on bash
    # 3.2.57), so -x alone would accept a receipt naming a directory called podman. -x as well
    # as -f, because a half-extracted .pkg leaves a mode-644 binary that PATH cannot run.
    [ -f "$d/podman" ] && [ -x "$d/podman" ] || return 1
    export PATH="$PATH:$d"
    PODMAN_PATH_ADDED="$d"
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

# `|| exit 1`, and it is load-bearing. platform() ends in a die() for an OS this script does
# not support, and die() exits -- but a command substitution is a SUBSHELL, so that exit
# ended the subshell and nothing else: the STOP box was printed, PLAT was set to the empty
# string, and the script carried on to install as though this were Linux, having just told
# the student "Nothing further has been changed". Exit status propagates out of an
# assignment, so this is the whole fix.
PLAT="$(platform)" || exit 1
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

survey() {
    step "Looking at your computer"

    if [ "$PLAT" = macos ] && [ "$(uname -m)" != arm64 ]; then
        say_intel_mac; exit 1
    fi
    ok "$PLAT on $(uname -m)"

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
        note "podman is installed in $PODMAN_PATH_ADDED, which this terminal's PATH"
        note "does not name yet. That is normal on a Mac, and cs193v handles it."
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
                    /opt/homebrew/*) how="You installed it with Homebrew, so:

    brew uninstall podman" ;;
                    *)               how="It came from a package installer, at
${where:-/opt/podman/bin/podman}. Remove it with:

    sudo rm -rf /opt/podman
    sudo rm -f /usr/local/bin/podman

If you also have Podman Desktop, drag that to the Trash too." ;;
                esac
                die "Podman $v is on this Mac; the course needs
$MIN_PODMAN or newer.

The simplest fix is to remove the podman you have and run this
script again -- it installs a version the course is tested
against.

$how

WORTH KNOWING FIRST: if you have used podman on this Mac for
anything else, removing it can lose the virtual machine it kept
your containers in. If that matters, talk to course staff first."
            fi
            # THE COMMAND COMES FROM THE TABLE, so there is one source for it and a family added
            # later cannot be told to run apt. On Debian this renders exactly the string it always
            # did, which is what keeps 25-installer.sh's podman-old:says-how-to-upgrade green.
            die "Podman $v is installed; the course needs $MIN_PODMAN
or newer.

Please upgrade podman and run this again:

    $PM_UPGRADE

If that says podman is already the newest version, your Linux
release is older than the course supports. Send course staff
the output of:  podman --version"
        fi
        ok "podman $v"
    else
        DO_PODMAN_INSTALL=yes
        case "$PLAT" in
            macos) need "Install Podman" \
                        "Podman runs the course container. On a Mac it installs system-wide, so macOS will ask for your password once." ;;
            *)     need "Install $PKG_PODMAN${PKG_UIDMAP:+ (and $PKG_UIDMAP)}" \
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
        need "Install $PKG_SSH" \
             "cs193v uses ssh on your own computer to connect your browser to servers you run inside the container. Without it the container still works, but nothing in it would be reachable at http://localhost. Installing software needs your password."
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
        ok "curl"
    elif [ "$PLAT" = macos ]; then
        # Every supported macOS ships /usr/bin/curl, so this is the ssh case again -- something
        # unusual about the machine, and guessing at a fix would be worse than saying so.
        die "curl is missing from this Mac, which should not be possible.
Please contact course staff rather than working around it."
    else
        DO_CURL_INSTALL=yes
        need "Install $PKG_CURL" \
             "This script downloads the course files with curl. The Ubuntu desktop install does not include it — the WSL environment does — so it has to be installed here. Installing software needs your password."
    fi

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
            ok "uidmap"
        else
            # AN IMPOSSIBLE STATE ON SOME FAMILIES, refused rather than half-handled. PKG_UIDMAP
            # is empty wherever the setuid helpers are not a separable package -- on Fedora they
            # come with shadow-utils, which also owns usermod, so a machine cannot have podman and
            # lack them. If it somehow does, there is no package to name: the consent line would
            # read "Install " and the install would ask for nothing. Same treatment as the missing
            # ssh on a Mac below -- say so and stop, rather than guess.
            if [ -z "$PKG_UIDMAP" ]; then
                die "newuidmap and newgidmap are missing, which should not be possible on this
system -- they are part of the same package as usermod.

Please contact course staff rather than working around it."
            fi
            DO_UIDMAP_INSTALL=yes
            # ONE ITEM PER APT CALL. When podman is being installed, its own consent item already
            # says "(and uidmap)" and its package list already carries it, so a second item here
            # would describe one change twice.
            if [ "$DO_PODMAN_INSTALL" = no ]; then
                need "Install $PKG_UIDMAP" \
                     "Podman needs two small helper programs, newuidmap and newgidmap, to keep the container separated from the rest of your computer. Podman is on this computer but they are not. Installing software needs your password."
            fi
        fi
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
                 "Podman needs it to manage the container's resources at all. /etc/wsl.conf already exists, so this changes a file that is already here."
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
    local host_gb share
    host_gb=$(( $(host_ram_mb) / 1024 ))
    share=$(( host_gb * MAC_VM_SHARE_PCT / 100 ))
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
        skip "podman, uidmap, ssh and curl"; return
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
    step "Installing ${pkgs:-podman}"
    case "$PLAT" in
        linux|wsl)
            # ONE REFRESH STEP, AND ONLY WHERE THERE IS ONE. apt needs its index refreshed
            # before installing or it can 404 on a version the mirror has moved past; dnf
            # refreshes its own metadata when stale, so PM_REFRESH is empty there and this line
            # does nothing. Not a special case for Fedora -- an absent step rather than a
            # different one.
            # shellcheck disable=SC2086   # deliberately word-split: PM_REFRESH is a command line
            [ -n "$PM_REFRESH" ] && { sudo $PM_REFRESH || die "$PM_REFRESH failed."; }
            # shellcheck disable=SC2086   # deliberately word-split: both are lists of words
            sudo $PM_INSTALL $pkgs || die "Could not install $pkgs."
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
    command -v podman >/dev/null 2>&1 || die "podman was installed, but this script cannot run it.

Please send this to course staff. The podman installer may have
changed where it puts things, in which case the course files need
a one-line update."
    ok "podman $(podman --version | awk '{print $NF}')"
    if [ "$DO_SSH_INSTALL" = yes ]; then
        command -v ssh >/dev/null 2>&1 || die "ssh still is not on your PATH after installing.
Try opening a new terminal window and running this script again."
        ok "ssh installed"
    fi
    # ASKED FOR AGAIN AFTER INSTALLING, per prerequisite, for the reason the podman check above
    # gives: apt can exit 0 having put something somewhere this shell's PATH does not look, and
    # the next step to notice would be a download that fails like a network problem.
    if [ "$DO_CURL_INSTALL" = yes ]; then
        command -v curl >/dev/null 2>&1 || die "curl still is not on your PATH after installing.
Try opening a new terminal window and running this script again."
        ok "curl installed"
    fi
    if [ "$DO_UIDMAP_INSTALL" = yes ]; then
        command -v newuidmap >/dev/null 2>&1 || die "newuidmap still is not on your PATH after installing.
Try opening a new terminal window and running this script again."
        ok "uidmap installed"
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
    # Overwrites the course files and leaves projects/ alone, so this is also how updates
    # arrive.
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
    step "Checking that podman is working"
    if ! podman info --format '{{.Host.Arch}}' >/dev/null 2>&1; then
        die "Podman is installed but is not answering.
On a Mac, try:  podman machine start"
    fi
    ok "podman is working"
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
    # --rebuild, which reads oddly for a first install and is right anyway: it is the launcher's
    # only container-creating verb, and with no image on the machine yet its first act is to
    # build one. There is deliberately no separate --build to call -- one verb means the path a
    # student takes on day one cannot drift from the one staff run every day.
    #
    # Nothing here needs a terminal: --rebuild prompts for nothing, which is what lets this run
    # under `curl | bash` and under the test suite alike.
    "$DIR/cs193v" --rebuild || exit 1
    ok "built"
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
    #
    # The tag is spelled out rather than derived. It used to be read out of container.args,
    # because a pin there could name a registry image instead -- there is no pin any more and
    # the launcher's IMAGE is a constant, so parsing anything would be parsing to find out
    # what is written here. Deliberately unsuffixed: CS193V_INSTANCE is a staff development
    # tool and the installer never runs under one (see CLAUDE.md).
    if ! podman image exists localhost/cs193v:local; then
        die "The course container was not built, but setup did not stop.

Please send this to course staff, along with the output of:
    $DIR/cs193v doctor"
    fi
    ok "course container is present"
    if "$DIR/cs193v" doctor >/dev/null 2>&1; then ok "doctor runs"; else note "doctor reported problems — run: $DIR/cs193v doctor"; fi
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
check_podman
check_disk
build_image
smoke_test
say_done

# ─── the last line, and why the Windows installer needs one ────────────────────
# install-cs193v-windows.cmd downloads this script into the CS193V environment and greps it for
# the token below BEFORE running it. `curl -f` catches a 404 and a cut-off transfer; what it
# cannot catch is a captive portal answering 200 with its own login page, and it is bash that
# would then run the HTML. The token being LAST is what makes finding it prove that the whole
# file arrived, so this is an identity check and a completeness check at once.
#
# KEEP IT LAST, and keep it the only occurrence in this file. 25-installer.sh asserts both, and
# 00-release-gates.sh fetches the published URL and looks for it there.
# CS193V-INSTALLER-COMPLETE
