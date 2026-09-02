# shellcheck shell=bash
#
# CS193V test-side definitions that more than one place needs.
#
# WHY THIS FILE EXISTS. Every entry below was, or was about to become, the same fact written
# down twice -- and this project has already paid for that shape three times (version_lt and
# box() duplicated into the installer, the package names duplicated between a consent string
# and an install list, and the fd below). files/cs193v-ui.sh is the model: one sourced
# definition of a shared thing, with the reasoning kept next to it.
#
# BUT cs193v-ui.sh IS THE WRONG HOME FOR ANY OF IT. That file ships INTO the image, at
# /etc/cs193v/ui.sh, because setup-git sources it there. Nothing here is wanted inside the
# container: the trace fd is a property of the test harness, carve_func exists to read scripts
# that only exist in a checkout, and msg_of reads .private/messages.txt from the host tree. A
# test-only fact in a shipped file is a fact a student's container carries for no reason.
#
# MUST STAY BASH 3.2 COMPATIBLE, and unlike most of the suite that is ENFORCED here:
# 10-static.sh's bash32:tests-are-bash32-safe names this file explicitly. It has to, because
# that list names lib files one at a time and its glob is `tests/*.sh` -- TOP LEVEL ONLY. A
# file added under lib/ without being named there is silently exempt from the very ban list
# it is required to obey, which is the failure mode worth more than the rule.

# ─── the file descriptor the harness traces installer runs on ──────────────────
#
# THE RULE: this must never be an fd the launcher uses. Not a preference -- it is the whole
# reason this constant is a constant rather than a literal repeated at five call sites.
#
# WHAT GOES WRONG WHEN IT COLLIDES, measured rather than imagined. The harness exports
# BASH_XTRACEFD to divert `bash -x` output away from the transcript it is capturing. Exported
# means EVERY DESCENDANT inherits it, including programs the launcher runs. run_timeout in
# cs193v-ui.sh owns fd 9 for its own death-certificate fifo and deliberately CLOSES it for the
# command it runs (`9>&-`, and its comment explains why: conmon would otherwise hold the pipe
# open and turn an EOF into a hang). So a child arrives with BASH_XTRACEFD naming an fd that is
# closed under it -- and bash, which validates the variable at startup, writes
#
#     /bin/sh: BASH_XTRACEFD: 9: invalid value for trace file descriptor
#
# to stderr. run_timeout captures stderr into RT_OUT, and the launcher then read a podman
# version out of RT_OUT, so a diagnostic became part of a version number and a current podman
# was refused as too old.
#
# WHY THAT WAS INVISIBLE FOR SO LONG: it needs /bin/sh to BE bash. On Debian and Ubuntu /bin/sh
# is dash, which ignores BASH_XTRACEFD entirely and says nothing. On Fedora, and on macOS,
# /bin/sh is bash. The bug was latent on the machines this was developed on, not absent.
#
# THREE FIXES THAT DO NOT WORK, so they are not tried again:
#   * naming a shell. Bash emits the diagnostic whether it was invoked as `bash` or as `sh`;
#     only the message prefix changes. Only dash is silent, and dash is not on Fedora and does
#     not ship on macOS.
#   * unsetting it in the child. Bash validates the variable at startup, BEFORE the first line
#     of the script runs, so `unset BASH_XTRACEFD` on line 1 is already too late.
#   * not exporting it (`BASH_XTRACEFD=N; set -x; . script`). This does contain the leak, but
#     sourcing adds a level of trace nesting -- `++1` instead of `+1` -- and
#     95-installer-coverage.sh reads line numbers with `sed -n 's/^+\([0-9]\{1,\}\) .*/\1/p'`,
#     anchored to a SINGLE `+`. It would have silently zeroed the coverage gate.
#
# So the fd moves instead, and 10-static.sh asserts the two sets stay disjoint.
#
# WHY 8. fds 0-2 are the standard three, run-tests.sh holds the real stdout and stderr on 3 and 4
# (`exec 3>&1 4>&2`) and every suite runs inside that, and 9 is run_timeout's. 5 through 8 are
# untouched anywhere in cs193v, files/ or tests/; 8 is the top of that range and so the furthest
# from the next fd anybody is likely to reach for by hand.
#
# THE CONTAINER-SIDE COPIES ARE NOT THIS VARIABLE. lib/sandbox.sh writes its guest scripts from
# QUOTED heredocs (<<'RUN', <<'NEST') and lib/sandbox-guest.sh is copied into the fixture
# verbatim, both deliberately, so nothing on the host expands inside them. They spell the number
# out, and 10-static.sh's trace-fd:container-side-copies-agree asserts they still say what this
# says -- the same answer this project already gives for version_lt, box() and the two podman
# floors: assert the agreement rather than pretend there is one copy.
CS193V_TRACE_FD=8
export CS193V_TRACE_FD

# ─── the SELinux label every bind mount needs ──────────────────────────────────
#
# WHAT BREAKS WITHOUT IT. Fedora ships SELinux enforcing. A host directory bind-mounted into a
# container keeps its host label -- podman's own manual says so: "By default, Podman does not
# change the labels set by the OS" -- and a temp dir under $HOME is cache_home_t, which
# container_t may neither execute nor read. So the fixture containers could not run the script
# the suite had just written for them:
#
#     exec container process `/work/run.sh`: Permission denied
#
# MEASURED, both halves, on this machine: exec is refused, and so is a plain `cat` of a mounted
# FILE -- which is the quieter of the two, because a test that reads an empty string usually
# reports a missing feature rather than a missing permission. That is exactly how it surfaced:
# 66 assertions in 26-installer-sandbox.sh blamed the installer, and
# 50-image.sh's codex:the-managed-policy-is-really-read reported that /etc/codex was not being
# read, when the truth was that the file behind it could not be opened.
#
# `,z` NOT `,Z`. Both relabel; the difference is that Z assigns a PRIVATE label per container and
# z a shared one. $SB_WORK is mounted into more than one container -- the tier A run and the
# nested cases -- and podman's manual names that as z's case exactly ("two or more containers
# share the volume content"). Z would hand the second container a label the first cannot use.
#
# CONDITIONAL, AND THAT IS THE POINT. Relabelling MODIFIES THE HOST FILESYSTEM (podman's manual
# carries that as a warning), so it is not something to do unasked on a machine that has no
# SELinux to satisfy. Off SELinux this expands to nothing and every mount is byte-identical to
# what it was, which is the property that matters: this has to fix Fedora WITHOUT changing what
# Ubuntu, Debian, WSL or macOS do. Relying on podman to ignore a `,z` it cannot act on would be
# the same fix resting on an assumption instead of a measurement.
#
# THE `selinuxenabled` DOOR, rather than testing for /sys/fs/selinux: that directory is visible
# INSIDE a container on an SELinux host (measured -- the ubuntu fixture can see this machine's),
# so it answers a question about the kernel rather than about the policy. `command -v` first,
# because libselinux-utils is not installed on a stock Ubuntu and an absent tool means no SELinux
# to satisfy.
#
# EVERY bind mount carries it, not only the ones that were seen to fail: 10-static.sh's
# selinux:every-bind-mount-carries-the-label asserts that, because a mount written without it
# fails only on SELinux hosts and only sometimes -- which is the shape of bug that gets committed.
VT_MOUNT_Z=''
if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
    VT_MOUNT_Z=',z'
fi
export VT_MOUNT_Z

# ─── reading one function out of a script that cannot be sourced ───────────────
#
# install-cs193v.sh SOURCES NOTHING AND CANNOT BE SOURCED, by design rather than by accident:
# a student downloads that one file, checks the SHA-256 published next to it, and runs it, and
# its own header says why it cannot even use messages.txt ("messages.txt does not exist until
# the download step succeeds"). So there is no shared file the installer and a test can both
# read a table out of. The only way for a test to check the installer's own values without
# writing a second copy of them is to carve the function out and source the carving.
#
# THE IDIOM IS NOT NEW HERE -- 25-installer.sh has done exactly this for version_lt since it
# was written. It is lifted into a function because it was about to be spelled out a fourth
# time, and because the pattern has a quirk that is easy to get wrong once and never notice:
#
# THE PATTERN IS /^name()/, NOT /^name() {$/. The launcher's copies carry a trailing comment on
# the same line as the brace (`version_lt() {   # version_lt A B -> ...`), so anchoring to the
# brace matches in the installer and silently matches NOTHING in cs193v-ui.sh -- which produces
# an empty carving, and an empty carving sourced is a test that asserts nothing and passes.
# Hence the `[ -s ]`: an empty result is a failure of the carve, not a value.
carve_func() {                        # carve_func FILE NAME DEST -> 0 if DEST got a function
    sed -n "/^$2()/,/^}\$/p" "$1" > "$3"
    [ -s "$3" ]
}

# ─── the launcher's own words ──────────────────────────────────────────────────
#
# Student-facing prose lives in .private/messages.txt so it can be reworded without touching
# logic. A test that spells a message out instead of reading it turns every rewording into a
# red assertion that is not a regression -- and the usual answer to that is to weaken the
# assertion, which is how a suite stops being worth reading. assert.sh already makes this
# argument for the three strings it takes from files/cs193v-strings.sh; this is the same move
# for all of messages.txt, through the launcher's real msg() rather than a reimplementation of
# its {{NAME}} substitution.
#
# A SUBSHELL, deliberately. cs193v-ui.sh defines box(), die(), menu(), run_timeout() and forty
# other names; a suite that wanted one message should not acquire all of them, and MESSAGES has
# to be set for msg() to read anything. Nothing leaks out but the text.
msg_of() {                            # msg_of KEY [NAME=VALUE...] -> the message, expanded
    (
        # SC2034 disabled HERE rather than for the whole file list: msg() reads $MESSAGES out of
        # the file sourced on the next line, which shellcheck cannot see without -x -- the same
        # blindness shellcheck:ui and shellcheck:setup-git-tests answer with --exclude=SC2034.
        # Excluding it for all of shellcheck:tests would stop catching genuinely dead variables
        # in run-tests.sh and 10-static.sh, which is too much to give up for one line.
        # shellcheck disable=SC2034
        MESSAGES="$PRIVATE/messages.txt"
        # shellcheck source=../../files/cs193v-ui.sh
        . "$PRIVATE/files/cs193v-ui.sh"
        msg "$@"
    )
}
