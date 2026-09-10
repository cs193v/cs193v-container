# shellcheck shell=bash
#
# CS193V test-side definitions that more than one place needs.
#
# WHY THIS FILE EXISTS. Every entry below was, or was about to become, the same fact written
# down twice -- and this project has already paid for that shape twice (version_lt and box()
# duplicated into the installer, and the package names duplicated between a consent string and
# an install list). files/cs193v-ui.sh is the model: one sourced definition of a shared thing,
# with the reasoning kept next to it.
#
# BUT cs193v-ui.sh IS THE WRONG HOME FOR ANY OF IT. That file ships INTO the image, at
# /etc/cs193v/ui.sh, because setup-git sources it there. Nothing here is wanted inside the
# container: carve_func exists to read scripts that only exist in a checkout, and msg_of
# reads .private/messages.txt from the host tree. A test-only fact in a shipped file is a
# fact a student's container carries for no reason.
#
# MUST STAY BASH 3.2 COMPATIBLE, and unlike most of the suite that is ENFORCED:
# 10-static.sh's bash32:tests-are-bash32-safe scans this file, along with everything else the
# host runs out of tests/.
#
# THIS PARAGRAPH USED TO BE A WARNING and it is worth recording why it no longer needs to be. It
# said that the ban list NAMED lib files one at a time, so "a file added under lib/ without being
# named there is silently exempt from the very ban list it is required to obey, which is the
# failure mode worth more than the rule". That failure mode was real -- it is what #115 and #125
# each paid for once, and #158 measured it across the whole tree: seventeen shell files that no
# lint reached. What replaced the naming is one list derived from the tree
# (10-static.sh's $testfiles), shared by the linter, the parse gate, the bash-4 ban and the exec
# check, so a file added under lib/ tomorrow is covered by all four without being remembered.

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
# ─── ONE DOOR, TWO CONSUMERS (#119) -- AND THEN TWO DOORS (#163) ───────────────
#
# The answer was hoisted here because a SECOND thing needed it: machine_flags turns the SELinux
# label off for the fixtures that run a podman inside themselves. #119 decided that arm must be
# decided the same way this mount label is -- two copies of one probe being this file's whole
# subject -- and warned that the failure would be the quiet kind, a machine where the mount is
# relabelled and the flag is withheld, or the reverse.
#
# THAT WARNING CAME TRUE AND THE RULE DID NOT SURVIVE IT. #163 is below: with a remote podman the
# two consumers are asking about two different machines, so they now have two doors. Read this
# paragraph as the history of the coupling, not as the rule in force.
#
# THE PROBE ITSELF IS UNCHANGED, deliberately, so no host's answer moves. A tri-state
# (enforcing / permissive / none) was written and dropped: `getenforce` would answer it, and the
# case that motivated it -- a machine that is enforcing but has no `selinuxenabled` -- DOES NOT
# EXIST. Fedora's selinux-policy-targeted depends on policycoreutils, which depends on
# libselinux-utils, which owns BOTH binaries; a host that can be enforcing has both or neither.
# So the refinement bought precision in a dimension with no hosts in it.
#
# AND THE /sys/fs/selinux DOOR STAYS REJECTED, for the reason above -- with one measurement worth
# recording against the day somebody re-proposes it. Inside a container that directory is not
# merely visible, it is visible AND EMPTY: podman does not mount selinuxfs there unless
# --security-opt label=nested is passed, which podman-run(1) states as "without nested, containers
# view SELinux as disabled, even when it is enabled on the host". So the objection above is right
# about the directory existing and the emptiness would in fact distinguish host from container.
# It is still not worth having: it would make this door disagree with `selinuxenabled` on hosts
# where the tool is absent, and switch on an unasked recursive host relabel there.
# ─── AND THE MACHINE THAT RUNS THE CONTAINERS IS NOT ALWAYS THIS ONE (#163) ────
#
# `selinuxenabled` answers for the machine the suite runs ON, and on macOS and Windows that is
# not the machine the containers run on: podman is a client there and the containers live in a
# Fedora VM. So the door said "no SELinux" about a laptop while every fixture ran on an enforcing
# Fedora 44 host -- machine_flags withheld `label=disable`, the nested fixture ran as container_t,
# and #119's two symptoms came back verbatim. Measured on macOS 15 / podman 5: `command -v
# selinuxenabled` finds nothing, `podman info` reports SELinuxEnabled true and Fedora 44.
#
# That is the "quiet kind" of failure the paragraph above predicts, arriving by a route it did not
# anticipate: not two consumers disagreeing, but the probe and the container host on opposite
# sides of a VM boundary.
#
# ONLY OFF LINUX, and both halves of that gate are load-bearing. Correctness: on native Linux --
# WSL included, where uname says Linux and podman really is local -- the client and the container
# host are one machine, so the probe above is already authoritative, and the paragraph above
# argues a host that CAN be enforcing always ships the tool. Cost: `podman info` measures 0.23 s,
# lib/assert.sh sources this file, and every suite sources lib/assert.sh -- so asking
# unconditionally would bill the whole cheap lane for an answer it already had.
#
# EVERY INPUT IS AN EXTERNAL COMMAND, which is why this is `uname -s` and not bash's own $OSTYPE:
# it keeps the whole door decidable by PATH, which is what lets 14-test-harness.sh run both
# answers on any machine.
#
# SO THE ONE DOOR BECOMES TWO, and the paragraph above is now the reason rather than the rule:
# its two consumers ask genuinely different questions the moment a VM sits between them.
#
#   vt_selinux    does the machine the CONTAINERS run on enforce? -> the label flag on a fixture.
#   VT_MOUNT_Z    can THESE HOST PATHS be relabelled? -> the `,z` on a bind mount.
#
# On macOS the bind sources are macOS paths arriving over virtiofs, which have no per-file labels
# to set, so `,z` stays off there and every one of its ~15 sites is byte-identical to before. That
# is the conservative half AND the correct one: the suite already passes on macOS with `,z` off.
#
# AND THE PODMAN HALF IS LAZY, which is not a nicety -- an eager probe is measurably wrong twice
# over. It bills the cheap lane 0.23 s per suite for an answer it never reads; and worse, several
# suites audit the EXACT LIST of podman commands a fixture issues against a recording fake, so a
# probe at source time inserts `info --format ...` into somebody else's evidence. Measured: it
# broke four ceiling:* assertions in 14-test-harness.sh, whose expected value is a podman
# command log. So the answer is computed when it is first READ and memoised in $VT_SELINUX.
#
# MEMOISED ON `+set`, NOT on emptiness: empty is a real answer here, and re-probing every read
# would put the fork back. It also means a caller may pre-set $VT_SELINUX to force the arm --
# which is exactly how 14-test-harness.sh's flags:* block reaches both branches on any machine.
#
# A STOPPED podman machine answers nothing, and that is deliberately not special-cased: the
# fallback is the behaviour this file had before, and a run whose containers cannot start is
# about to say so loudly on its own.
VT_SELINUX_LOCAL=''
if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
    VT_SELINUX_LOCAL=yes
fi
VT_MOUNT_Z=''
# AN `if`, NOT `&&`, so this file ENDS on the export and returns 0. `.` propagates the last
# command's status, and a bare `[ -n "$VT_SELINUX_LOCAL" ] && ...` returns 1 off SELinux -- which
# is every machine this suite is usually developed on, and would sink any caller under `set -e`.
if [ -n "$VT_SELINUX_LOCAL" ]; then VT_MOUNT_Z=',z'; fi

vt_selinux() {                        # -> 'yes' if the machine the CONTAINERS run on enforces
    if [ -z "${VT_SELINUX+set}" ]; then
        VT_SELINUX="$VT_SELINUX_LOCAL"
        if [ -z "$VT_SELINUX" ] && [ "$(uname -s 2>/dev/null)" != Linux ] &&
           [ "$(podman info --format '{{.Host.Security.SELinuxEnabled}}' 2>/dev/null)" = true ]
        then
            VT_SELINUX=yes
        fi
    fi
    printf '%s' "$VT_SELINUX"
}
export VT_SELINUX_LOCAL VT_MOUNT_Z

# ─── reading one function out of a script that cannot be sourced ───────────────
#
# install-cs193v.sh SOURCES NOTHING AND CANNOT BE SOURCED, by design rather than by accident:
# a student downloads that one file, checks the SHA-256 published next to it, and runs it. So
# there is no shared file the bootstrap and a test can both read a table out of, and the only
# way for a test to check its own values without writing a second copy of them is to carve the
# function out and source the carving.
#
# THAT IS NOW TRUE OF THE BOOTSTRAP ALONE (#221). The sentence used to carry a second clause --
# that the installer could not even use messages.txt, because it does not exist until the
# download succeeds -- and that clause is gone: the download is the FIRST thing now, so
# course-install.sh sources cs193v-ui.sh and reads course-install-messages.txt out of the tree
# it was fetched with. Anything in the installer PROPER can therefore be tested by pointing
# MESSAGES at the real catalogue instead of carving, which is what 20-messages.sh's itext:* and
# 25-installer.sh's check-disk:* now do. Carving is for the ~150-line bootstrap.
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
        # SC2034 disabled HERE rather than for a whole file list: msg() reads $MESSAGES out of
        # the file sourced on the next line, which shellcheck cannot see without -x -- the same
        # blindness shellcheck:ui answers with --exclude=SC2034 on the product side.
        #
        # THIS LINE IS NOW THE WHOLE TREE'S IDIOM, and #158 is why. There used to be nine
        # test-side lists, three of them excluding SC2034 for every file they named; there is now
        # one shellcheck:tests over a list derived from the tree, with no --exclude at all, and
        # every excuse sits in the file it excuses the way this one does. The argument that made
        # that worth doing is the one this comment was already making: a blanket exclusion "would
        # stop catching genuinely dead variables in run-tests.sh and 10-static.sh". Measured when
        # the seventeen unlinted files were finally covered -- it turned up one, 50-image.sh's
        # GESTURE_TOKENS, and #164 had just deleted two more of exactly that shape by hand.
        # shellcheck disable=SC2034
        MESSAGES="$PRIVATE/messages.txt"
        # shellcheck source=../../files/cs193v-ui.sh
        . "$PRIVATE/files/cs193v-ui.sh"
        msg "$@"
    )
}
