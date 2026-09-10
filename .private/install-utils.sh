#!/usr/bin/env bash
#
# CS193V setup — the facts and the privileged steps, shared by the two halves of the installer.
#
# NOT A SCRIPT. It is sourced, never run, and it defines functions and constants and nothing
# else: no top-level work, no output, no exit trap. 10-static.sh asserts as much.
#
# WHO SOURCES IT, AND WHY IT HAD TO EXIST (#217). Since #221 there are two scripts inside the
# tarball rather than one: course-install.sh, which a student watches, and wsl-provision.sh, which
# runs as root inside a freshly created CS193V WSL instance and prepares it so that the student's
# half needs no password. Both need the same three answers -- which distro this is, what it calls
# the packages, and how the privileged edits are made -- and the whole point of the root pass is
# that its list of privileged steps cannot drift from the list the student half would otherwise
# have run with sudo. One copy is the only way to have that.
#
# NOT files/cs193v-ui.sh, deliberately, though that is the other shared file. Everything under
# files/ is COPYied into the image and hashed into cs193v.buildhash, so a package table living
# there would prompt every student to rebuild the container whenever a package name changed --
# for a table the container has no reader for. This file ships in the tarball (see .gitattributes)
# and stays out of the build context.
#
# MUST STAY BASH 3.2 COMPATIBLE — macOS ships bash 3.2. No associative arrays, no mapfile,
# no ${var,,}, no fractional `read -t`.
#
# IT MAY PRINT PROSE, and only because both consumers point MESSAGES at the same catalogue
# (course-install-messages.txt). 10-static.sh forbids a key in two catalogues, so a file read by
# two scripts with two catalogues could not have worded its own refusals; this one can.

# ─── which family of Linux this is, and what it calls things ───────────────────
#
# PARSED, NOT SOURCED, and that is a deliberate refusal to use the obvious one-liner.
# `. /etc/os-release` would let that file set ANY variable in the caller -- $DIR, $PLAT, $PATH --
# and the caller runs sudo. It is shell syntax by specification, which is exactly what makes
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

# ─── one table, read by the consent screen, the install AND the root pass ──────
#
# THE POINT IS THAT THERE IS ONE COPY. Before this, every package name appeared twice: once in a
# need() string on the consent screen and again in install_podman's package list. Two places, one
# name, nothing checking they agreed -- and a fix for one family that missed the other would have
# shown a student "Install openssh-client" and then installed something else. #217 adds a third
# reader in a second file, which is what moved the table out of course-install.sh and in here.
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
# THE PROGRESS BLOCK'S THREE COLUMNS (#219), in this table for the reason the package names are:
# the phase count, the reader that advances it and the environment the install needs are all
# per-family, and a fix for one family that missed the other is what this table exists to
# prevent. PM_ENV is empty on Fedora -- dnf has no debconf to silence.
PM_ENV=""; PM_PHASES=0; PM_READER=""
PKG_PODMAN=""; PKG_UIDMAP=""; PKG_SSH=""; PKG_CURL=""; PKG_CA=""
distro_packages() {                   # distro_packages FAMILY -> sets the PM_/PKG_ globals
    case "$1" in
        debian) PM_REFRESH="apt-get update"; PM_INSTALL="apt-get install -y"
                PM_UPGRADE="sudo apt update && sudo apt install --only-upgrade podman"
                # FOUR PHASES, because apt-get install goes over the whole package set three
                # times -- download, unpack, configure -- and the refresh above is a fourth.
                #
                # DEBIAN_FRONTEND, because the block owns the terminal: the animator overdraws
                # anything else within 100 ms, so a debconf question behind it would be a prompt
                # a student could neither see nor answer. That was survivable while apt's own
                # output was on the screen; it is not now.
                PM_ENV="DEBIAN_FRONTEND=noninteractive"; PM_PHASES=4; PM_READER=apt_phases
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
                # TWO PHASES, and that is rpm rather than something left out: dnf downloads and
                # then runs a transaction, with no unpack/configure split in its output to see.
                # The same shape as PM_REFRESH being empty here -- an absent phase rather than a
                # different one.
                PM_ENV=""; PM_PHASES=2; PM_READER=dnf_phases
                PKG_PODMAN="podman"; PKG_UIDMAP=""
                PKG_SSH="openssh-clients"; PKG_CURL="curl"; PKG_CA="" ;;
    esac
}

# ─── the progress block, and why it is in THIS file  (#219) ───────────────────
# BECAUSE root_step_packages IS, and that is the whole of the reason. The block goes around the
# package manager, the package manager is a root step, and root steps live here since #217 so
# that the student pass and the WSL root pass cannot run different ones. A wrapper in
# course-install.sh would be a function install-utils.sh called and wsl-provision.sh did not
# have.
#
# NOT files/cs193v-ui.sh EITHER, for that file's own stated reason: everything under files/ is
# COPYied into the image and hashed into cs193v.buildhash, so a host-side tweak here would prompt
# every student to rebuild a container that has no reader for any of it. What IS in cs193v-ui.sh
# is the renderer -- meter_* -- which this file drives and does not duplicate.
#
# IT IS STILL "FUNCTIONS AND CONSTANTS AND NOTHING ELSE", which this file's header requires: the
# four assignments below are constants, and nothing here runs, prints or traps at source time.

# ─── the progress block, for the steps that take minutes  (#219) ───────────────
# WHAT THIS IS NOT: a second renderer. cs193v-ui.sh's meter_* draws the block and the launcher's
# build_progress feeds it podman's STEP lines; this is the same renderer with a second reader,
# which is the arrangement that file's header describes -- it draws, and the consumer decides
# what it says. Nothing below moves a cursor or prints a glyph.
#
# AND NOT A SECOND WRITER EITHER, which is the part worth guarding. The state file the animator
# reads has one shell writer, meter_label, and setup_say_phase calls it rather than reproducing
# build_progress's awk state(). A reader that only has to notice one line shape per phase does
# not need awk: it reads a few hundred lines rather than the thousands a build prints, and it
# verifies nothing against them. What that buys is greppable `case` patterns instead of regexes
# inside a single-quoted awk program, and a four-field record with no new author.
#
# THE READER CANNOT STALL THE BOX, because the box tails $SETUP_LOG -- which tee writes -- so the
# reader is not in its path at all. Same decoupling the launcher relies on.
#
# THE LOG OUTLIVES THE RUN, like the launcher's $BUILD_LOG and for its reason: with the output no
# longer on the screen it is the thing to ask a student for, and the refusals name it.
SETUP_LOG="${TMPDIR:-/tmp}/cs193v-setup-$$.log"
# The staff escape hatch, shared with the launcher's build meter. cs193v carries the argument for
# there being one switch rather than two.
SETUP_RAW="${CS193V_SETUP_RAW_LOG:-}"
# How many phases the running step has, and which one it has reached. setup_phase runs inside
# setup_run's pipeline, so its increments belong to a subshell and never come back here -- which
# costs nothing, because the animator reads the state FILE and meter_stop falls back to it for
# the caption.
SETUP_TOTAL=0
SETUP_PHASE=0

setup_meter_start() {                 # setup_meter_start TOTAL LABEL
    SETUP_TOTAL="$1"
    SETUP_PHASE=1
    [ -z "$SETUP_RAW" ] || return 0
    # Keyed off this script's own pid, which is what cs193v-ui.sh says the installer does; the
    # launcher keys its own off TUNNEL_ID so two of them cannot redraw each other's bar.
    METER_STATE="${TMPDIR:-/tmp}/cs193v-setup-meter-$$"
    # TRUNCATED, not appended across steps. Three steps share this path, and a box that opened on
    # the tail of the previous one would spend its first second showing a student the end of
    # something that had already finished -- which is why build_image clears $BUILD_LOG too.
    : > "$SETUP_LOG"
    meter_start "$SETUP_TOTAL" "$2" "$SETUP_LOG"
    # THE OPENING CAPTION GOES THROUGH THE SAME PLACE AS EVERY OTHER ONE, which on a terminal
    # rewrites the record meter_start has just written -- identical values, so a no-op -- and off
    # one prints the line meter_start could not. Without it a piped transcript begins at phase
    # TWO, and piped is the form staff are sent.
    setup_say_phase 0 "$2"
}

# setup_phase INDEX LABEL -- the INDEXth of SETUP_TOTAL phases is now starting.
#
# THE BAR SHOWS PHASES COMPLETED, so it is empty while the first one runs and full only when
# setup_meter_stop says so. The alternative -- cur being the phase that is RUNNING -- fills the
# bar to 4/4 during configure, which is the longest of apt's three passes, and ERRORS.md B18
# records what a completed-looking bar over a minute of work reads like.
#
# FORWARD ONLY, and that guard is what makes a caption a phase rather than a per-package
# flicker: every anchor these readers match occurs once per PACKAGE.
setup_phase() {                       # setup_phase INDEX LABEL
    [ "$1" -gt "$SETUP_PHASE" ] || return 0
    SETUP_PHASE="$1"
    setup_say_phase "$(( $1 - 1 ))" "$2"
}

# ONE PLACE THAT SAYS A CAPTION, so the terminal form and the piped one cannot drift -- which is
# the drift the launcher lives with, where build_progress renders a bar on a tty and one plain
# line per step in a pipe from two arms of the same awk.
#
# \r CANNOT OVERDRAW A LOG FILE, which is why the piped arm is one line per phase rather than a
# frame: ten frames a second of it is what a student would be asked to send to staff.
setup_say_phase() {                   # setup_say_phase CUR LABEL
    if [ -n "$METER_PID" ]; then
        meter_label "$1" "$SETUP_TOTAL" "$2"
    else
        printf '    %s\n' "$2"
    fi
}

# setup_run READER CMD... -> the COMMAND's status
#
# PIPESTATUS, because a pipeline's status is its last stage's -- the reader, which always
# succeeds. Without it a failed apt would be indistinguishable from a successful one, and the
# installer would carry on to `command -v podman` and refuse there, one step past the truth.
#
# 2>&1 IS NOT OPTIONAL. apt writes its W: and E: lines to stderr, and a stream that skipped this
# pipe would land on the terminal the animator is redrawing ten times a second -- so the symptom
# is not a lost line but a smeared block.
setup_run() {                         # setup_run READER CMD...
    local reader="$1"; shift
    if [ -n "$SETUP_RAW" ]; then
        "$@" 2>&1 | tee -a "$SETUP_LOG"
        return "${PIPESTATUS[0]}"
    fi
    "$@" 2>&1 | tee -a "$SETUP_LOG" | "$reader"
    return "${PIPESTATUS[0]}"
}

# A phase with nothing inside it to detect, so its reader only has to empty the pipe.
#
# NOT AN OPTIMISATION -- `apt-get update` prints `Get:` lines of its own, and handing those to
# apt_phases would open the download phase before any package had been downloaded.
setup_drain() {
    cat >/dev/null
}

# setup_meter_stop ok|bad
#
# CUR AND TOT ONLY, never a caption: setup_phase's last write is in the state file, and
# meter_stop reads it from there -- the one place that knows which phase the run really reached.
setup_meter_stop() {                  # setup_meter_stop ok|bad
    [ -z "$SETUP_RAW" ] || return 0
    meter_stop "$1" "$SETUP_TOTAL" "$SETUP_TOTAL"
}

# The last lines the command printed, for a refusal that can no longer point at the screen --
# ERRORS.md B17 is what happens when one does. The tail rather than the whole log: the last lines
# are the ones that name the failure, and box() wraps rather than spills.
setup_tail() {                        # setup_tail -> the last 12 lines of the log
    tail -n 12 "$SETUP_LOG" 2>/dev/null
}

# ─── THE STEPS THAT NEED ROOT, and the registry that says which those are ──────
#
# ONE LIST, TWO CALLERS, AND THAT IS THE POINT OF THIS FILE (#217). course-install.sh runs these
# through sudo, announcing each one first, because it is a student's own machine. wsl-provision.sh
# runs the same three as root inside the CS193V instance, so that the student's account can keep a
# locked password and never be asked for one. If the two lists could differ, the root pass would
# one day miss a step and the student pass would meet a sudo prompt it cannot answer -- which is
# the single failure this whole arrangement exists to make impossible. So the root pass iterates
# ROOT_STEPS rather than naming steps, and 10-static.sh asserts that every name here has a
# function, that the root pass names none of them individually, and that course-install.sh calls
# each one exactly once.
#
# EVERY STEP IS A NO-OP WHEN ITS WORK IS ALREADY DONE, and that is a hard requirement rather than
# tidiness. The root pass has no consent screen to gate them with -- course-install.sh's DO_*
# flags exist to word the consent items, not to protect the steps -- and it runs again on every
# re-run of the Windows installer, including one resuming a run that was killed half-way. Measured
# cost of getting this wrong: the wslconf sed against the Ubuntu-26.04 WSL image, which already
# ships [boot] systemd=true, appends a SECOND systemd=true on every pass, and usermod
# --add-subuids against a useradd-created account adds a second id range to /etc/subuid.
#
# `sudo` IS KEPT ON EVERY CALL, INCLUDING IN THE ROOT PASS, where it is a no-op indirection.
# Measured in the instance the installer actually targets (Ubuntu 26.04, sudo-rs 0.2.13): root's
# `sudo -n true` exits 0, `sudo -n id -un` prints root, and /etc/sudoers carries Ubuntu's stock
# `root ALL=(ALL:ALL) ALL`. There is deliberately no euid branch here, and that is worth more than
# the two characters it saves: 10-static.sh's claim that the shim tier is STRUCTURALLY unable to
# change a developer's machine rests on every privileged call going through one name, which
# lib/sudo-fake replaces with a recorder that never execs. An `as_root` running commands directly
# when euid was 0 would have put a hole in that. wsl-provision.sh checks `sudo -n true` up front,
# so the two ways this can fail -- no sudo, or a sudoers that does not list root -- are a refusal
# before anything is changed rather than a failure half-way down.
ROOT_STEPS="packages subuid wslconf"

# The block handed to usermod. One literal, because 25-installer.sh reads it out of this file and
# asserts the installer asked root for exactly the range it names.
SUBUID_RANGE="200000-265535"

# Set by the caller before the steps run. Declared here because both callers read them under
# `set -u`, where a step expecting a global the caller forgot is a hard error rather than a silent
# skip -- which is the right direction for something that runs as root.
PKGS=""                               # what to install; empty means nothing is missing
TARGET_USER=""                        # whose /etc/subuid range this is

# THE EMPTY LIST IS THE GATE. course-install.sh reaches this having assembled $PKGS from its DO_*
# flags, so an empty one means the consent screen offered nothing to install; wsl-provision.sh
# reaches it having probed the instance, so an empty one means the image already has everything.
# Either way there is nothing to ask a package manager, and asking anyway would cost an apt-get
# update -- a slow network round trip -- on every re-run of an installer that promises re-running
# it is safe.
# The passes each package manager makes over the package set, one anchor apiece, matched as a
# PREFIX because these are lines apt and dnf begin at column 0.
#
# APT MAKES THREE. `apt-get install` downloads the whole set, then unpacks the whole set, then
# configures the whole set, so `Get:`, `Unpacking ` and `Setting up ` are three disjoint
# stretches rather than three lines per package. `Processing triggers for ...` belongs to the
# configure pass and needs no anchor of its own.
#
# A DEAD ANCHOR LEAVES THE CAPTION STALE, NEVER WRONG, and it has to stay that way round: these
# names are side text, and the one thing a caption must not be able to do is stop an install.
# The everyday version of that is a warm cache -- apt prints no `Get:` line when the .debs are
# already there, so the bar simply steps twice at once.
#
# LABELS RESOLVED ONCE, above the loop rather than inside the case: these patterns match once per
# PACKAGE, so a $(msg ...) in an arm would be a hundred forks over a run.
apt_phases() {
    local line l_download l_unpack l_configure
    l_download="$(msg meter.pm-downloading)"
    l_unpack="$(msg meter.pm-unpacking)"
    l_configure="$(msg meter.pm-configuring)"
    while IFS= read -r line; do
        case "$line" in
            Get:*)          setup_phase 2 "$l_download" ;;
            Unpacking\ *)   setup_phase 3 "$l_unpack" ;;
            Setting\ up\ *) setup_phase 4 "$l_configure" ;;
        esac
    done
}

# DNF MAKES TWO, and its second anchor is `Running transaction` rather than a per-package line
# because that is the one string dnf4 and dnf5 agree on: dnf4 prints `Installing : pkg  n/m` and
# dnf5 prints `[n/m] Installing pkg`, so keying on either would be a per-Fedora-version parse.
# `Running transaction check` and `Running transaction test` match this prefix too and land after
# the download, so the caption is early by a second rather than wrong.
dnf_phases() {
    local line l_download l_installing
    l_download="$(msg meter.pm-downloading)"
    l_installing="$(msg meter.pm-installing)"
    while IFS= read -r line; do
        case "$line" in
            Downloading\ Packages*) setup_phase 1 "$l_download" ;;
            Running\ transaction*)  setup_phase 2 "$l_installing" ;;
        esac
    done
}

root_step_packages() {
    [ -n "$PKGS" ] || return 0
    # ONE REFRESH STEP, AND ONLY WHERE THERE IS ONE. apt needs its index refreshed before
    # installing or it can 404 on a version the mirror has moved past; dnf refreshes its own
    # metadata when stale, so PM_REFRESH is empty there and this branch takes its other arm. Not
    # a special case for Fedora -- an absent PHASE rather than a different one, which is also why
    # the two arms open the block on different captions.
    if [ -n "$PM_REFRESH" ]; then
        setup_meter_start "$PM_PHASES" "$(msg meter.pm-refreshing)"
        # shellcheck disable=SC2086   # deliberately word-split: PM_REFRESH is a command line
        if ! setup_run setup_drain sudo $PM_REFRESH; then
            setup_meter_stop bad
            # ON ONE LINE, and it has to be: text116's literal rule is line-oriented, so a $(...)
            # split across a continuation is unclosed on both halves and the words inside a
            # perfectly clean msg() call read to it as prose.
            die "$(msg err.refresh-failed "CMD=$PM_REFRESH" "OUT=$(setup_tail)" "LOG=$SETUP_LOG")"
        fi
    else
        setup_meter_start "$PM_PHASES" "$(msg meter.pm-downloading)"
    fi
    # shellcheck disable=SC2086   # deliberately word-split: an env prefix and two lists of words
    if ! setup_run "$PM_READER" sudo $PM_ENV $PM_INSTALL $PKGS; then
        setup_meter_stop bad
        die "$(msg err.install-failed "PKGS=$PKGS" "OUT=$(setup_tail)" "LOG=$SETUP_LOG")"
    fi
    setup_meter_stop ok
}

# THE SAME QUESTION survey() ASKS, asked again here because the root pass has no survey. `useradd`
# has populated /etc/subuid for a new account since shadow 4.11.1-3, so on the Windows path this
# normally skips -- and it is written as a skip rather than assumed, because that is image
# behaviour a Canonical rebuild could change, and absorbing such a change is the whole reason the
# root pass runs the installer's own steps instead of a hand-written list of apt calls.
root_step_subuid() {
    grep -q "^$TARGET_USER:" /etc/subuid 2>/dev/null && return 0
    sudo usermod --add-subuids "$SUBUID_RANGE" --add-subgids "$SUBUID_RANGE" "$TARGET_USER" \
        || die "$(msg err.subuid-failed "USER=$TARGET_USER")"
}

# ─── what /etc/wsl.conf says about systemd ─────────────────────────────────────
# The systemd line in the [boot] section, or nothing, and the one question anybody asks about
# it. THREE CALLERS: course-install.sh's survey uses both -- once for its skip and once for its
# refusal -- and root_step_wslconf below uses them to check that its write actually landed.
#
# SCOPED TO [boot] BECAUSE [boot] IS THE ONLY SECTION EITHER SCRIPT WRITES. The greps these
# replace read the whole file, so a `systemd=` under [automount] answered a question about
# [boot] -- and WSL, which reads its settings per section, did not agree. That made survey skip a
# machine on which systemd was never enabled and tell nobody, which is #228's defect pointing the
# other way: two readers of one file, disagreeing, with ok() believing whichever answered first.
#
# THE LINE, NOT A YES-OR-NO, because survey's refusal has to quote what it found. The predicate is
# then a question about that line rather than a second pass over the file.
wsl_boot_systemd() {                  # wsl_boot_systemd FILE -> the [boot] systemd line, or empty
    [ -f "$1" ] || return 0
    awk '/^[[:space:]]*\[/ { boot = ($0 ~ /^[[:space:]]*\[boot\]/); next }
         boot && /^[[:space:]]*systemd[[:space:]]*=/ { print; exit }' "$1"
}

wsl_systemd_is_on() {                 # wsl_systemd_is_on LINE -- that line turns systemd on
    printf '%s\n' "$1" | grep -q '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true'
}

# THE WSL IMAGE ALREADY SHIPS `[boot] systemd=true`, so this skips on the Windows path too. The
# sed arm exists for a /etc/wsl.conf carrying a [boot] stanza without it; the tee arm for a file
# with no [boot] stanza, and for no file at all.
#
# NEITHER WRITE WAS CHECKED, AND ok() CLAIMED BOTH (#228). The student was handed a `wsl
# --terminate` instruction for a setting that was never written, and met podman's failure later
# with no thread leading back to here. So both arms `|| die`, and then the FILE settles it: a
# write can exit 0 having stored nothing -- measured, a /etc/wsl.conf symlinked to /dev/null takes
# tee's 0 and keeps none of it -- which is the same reason err.podman-unrunnable exists.
#
# WHICH FAILURES ARE LEFT FOR THE TWO `|| die`s IS NARROWER THAN IT LOOKS, since #226: on the
# student's path ask_password primes sudo with `sudo -v` before any step runs, so "sudo refused"
# is a refusal three steps upstream of here rather than a write that fails. What reaches these two
# is a write root itself cannot make -- a /etc/wsl.conf that is a directory, a sudoers permitting
# some commands and not others -- and the read-back below catches the same failures a step later
# with less to say about them. 26-installer-sandbox.sh drives the tee arm (`--wslconf dir`) and
# records at the sed arm why this tier cannot arrange that one.
#
# A [boot] SECTION THAT SETS systemd TO SOMETHING ELSE NEVER REACHES HERE. On the student's path
# survey refuses it before consent is asked, quoting the line (say_wsl_systemd_off); on the
# Windows path the instance is a minute old and ships `[boot] systemd=true`, so the skip above
# fires. Worth naming because the sed is additive and would otherwise write systemd=true above a
# systemd=false, leaving a file whose two lines disagree.
root_step_wslconf() {
    wsl_systemd_is_on "$(wsl_boot_systemd /etc/wsl.conf)" && return 0
    if [ -f /etc/wsl.conf ] && grep -q '^[[:space:]]*\[boot\]' /etc/wsl.conf; then
        # ADDITIVE, AND WHOLE-LINE. The substitution this replaces rewrote the header itself, so
        # it required [boot] ALONE on the line and did nothing at all -- silently, exit 0 -- to
        # "[boot]  # note", which the grep just above accepts. Measured on a real WSL distro: a
        # header with a trailing comment still turns systemd on, so the file was right and the sed
        # was wrong. This leaves the student's line byte for byte, indentation included, and puts
        # systemd=true on the next one.
        sudo sed -i '0,/^[[:space:]]*\[boot\]/s/^\([[:space:]]*\[boot\].*\)$/\1\nsystemd=true/' \
            /etc/wsl.conf || die "$(msg err.wslconf-update)"
    else
        printf '[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf >/dev/null \
            || die "$(msg err.wslconf-create)"
    fi
    wsl_systemd_is_on "$(wsl_boot_systemd /etc/wsl.conf)" || die "$(msg err.wslconf-unchanged)"
}

# ─── the temp tree the bootstrap hands over ────────────────────────────────────
# WHOEVER THE BOOTSTRAP EXECS OWNS IT, and that is either of the two scripts, so the guard lives
# here rather than in one of them. install-cs193v.sh sets `trap ... EXIT` over the tree, which
# covers every way IT can fail -- but the hand-over is `exec`, and exec REPLACES the process and
# discards its traps. Measured. Without a trap on this side, every install anyone ever ran would
# leave a full unpacked copy of the course repository in /tmp.
#
# THE GUARD IS NOT DEFENSIVE PROGRAMMING. $BOOT_TMP arrives as an ARGUMENT, in scripts that go on
# to run `sudo $PM_INSTALL`, and the command it reaches is `rm -rf`. So the path has to earn it: a
# directory, named the way the bootstrap names one, under the temp directory, and holding the tree
# the bootstrap unpacked. `$2=/` fails the basename test, since ${x##*/} of `/` is empty.
#
# AN INTERRUPTED RUN STILL LEAVES ONE, and that is ordinary rather than a hole -- a trap does not
# run when the process is KILLED. The bootstrap's fixed `cs193v-install.` prefix is what lets a
# later sweep recognise one; lib/assert.sh's sweep_stale_tmpdirs records the doctrine.
boot_tmp_is_ours() {
    case "${BOOT_TMP##*/}" in cs193v-install.??????) ;; *) return 1 ;; esac
    case "$BOOT_TMP" in "${TMPDIR:-/tmp}"/*|/tmp/*) ;; *) return 1 ;; esac
    [ -d "$BOOT_TMP" ] && [ -f "$BOOT_TMP/.private/course-install.sh" ]
}
boot_cleanup() {
    # THE CURSOR FIRST, and the order is the launcher's for the launcher's reason: meter_start
    # hides it, so a Ctrl-C between there and setup_meter_stop would leave a student typing blind
    # in that terminal afterwards. Removing a directory can wait; a hidden cursor cannot.
    #
    # GUARDED, because both consumers arm this trap ABOVE the line that sources cs193v-ui.sh --
    # they have to, since an unreadable ui.sh is one of the ways either can exit and the tree
    # still has to go. On that one path meter_cleanup does not exist yet, and there is no meter.
    command -v meter_cleanup >/dev/null 2>&1 && meter_cleanup
    boot_tmp_is_ours && rm -rf "$BOOT_TMP"
}
