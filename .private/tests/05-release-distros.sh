#!/usr/bin/env bash
# TIER: release
#
# The distro support issue #94 asks for, as a gate. NOT part of the default run.
#
#     tests/run-tests.sh --release
#
# THESE FAIL TODAY BY DESIGN, which is the whole reason they are here rather than in the install
# tier. 26-installer-sandbox.sh asserts what the installer DOES on a non-apt machine -- it dies in
# install_podman with "apt-get update failed" -- and those assertions are green, because a
# permanently-red assertion in the everyday suite teaches people to ignore the suite.
# 00-release-gates.sh's header says it best: they are "the placeholders that must be filled in
# before students touch this".
#
# So the split is: the install tier records the defect, and this records the requirement. When
# #94 is fixed, these turn green and the install-tier cases turn red -- and BOTH of those are
# correct, because the install tier's job is to describe current behaviour.
#
# WHAT THESE GATES DELIBERATELY DO NOT COVER, so nobody reads more into a green run than is
# there:
#
#   * That the package manager SUCCEEDS. Every case here runs with --network=none (sandbox_run
#     always does), so a real `dnf install` cannot reach Fedora's repositories. Proving the
#     install completes needs the file:// offline repository Containerfile.machine builds for
#     apt, and no Fedora case wants one yet.
#   * That the podman it installs WORKS. That needs a nested podman, which needs the five
#     adaptations in Containerfile.debian-nested. A Fedora equivalent is worth building when
#     there is an installer that can reach it.
#   * Anything about a real Fedora KERNEL -- SELinux enforcing, systemd cgroup delegation. A
#     Fedora container on an Ubuntu host has Fedora's userland and this host's kernel. See
#     MANUAL.md; that gap is not closable here at all.
#
# MECHANISM-FREE ON PURPOSE. The gates say what must stop happening, not how. A gate asserting
# `dnf` by name would pin one implementation of the fix -- and the installer might reasonably
# key on os-release ID_LIKE, or dispatch on whichever manager is on PATH, and either should
# satisfy this.

set -u
. "$(dirname -- "$0")/lib/assert.sh"
. "$(dirname -- "$0")/lib/podman-shim.sh"
. "$(dirname -- "$0")/lib/sandbox.sh"

require_podman

SB_TMP="$(new_tmpdir)"
# Read by sandbox_cleanup in lib/sandbox.sh, which shellcheck cannot see from here.
# shellcheck disable=SC2034
SB_CASES="rel-fedora"
trap 'sandbox_cleanup; rm -rf "$SB_TMP"' EXIT

sb_work_init
fixture_build fedora || exit 1

# ─── Fedora ────────────────────────────────────────────────────────────────────
sb_machine base=fedora
out="$(sandbox_run rel-fedora '2' -e CS193V_DIR=/home/student/cs193v)"

# THE REQUIREMENT, stated as the thing that must stop happening. installer:591 runs
# `sudo apt-get update` unconditionally on linux and wsl; on Fedora that is
# "sudo: apt-get: command not found", which the installer reports as "apt-get update failed" --
# a message that reads like a network problem to anybody who has not seen this issue.
assert_says_not "release:fedora-does-not-die-in-apt-get" "apt-get update failed" "$out"

# AND THE PACKAGE NAMES, which are a second defect inside the first and would survive a fix that
# only dispatched the command. `uidmap` is a Debian package; on Fedora the same binaries come
# from shadow-utils, so a fix that ran `dnf install podman uidmap` would fail on the name alone.
# Asserted against the CONSENT TEXT as well as the install step, because the consent text is what
# a student reads before agreeing to it.
assert_says_not "release:fedora-does-not-name-the-debian-uidmap-package" \
                "Install podman (and uidmap)" "$out"
assert_says_not "release:fedora-does-not-ask-its-package-manager-for-uidmap" \
                "Installing podman uidmap" "$out"

# ...and it must still get as far as trying, which is what stops the three above from passing on a
# run that fell over earlier for an unrelated reason -- a fixture that failed to boot would
# satisfy every assert_says_not in this file. This one is GREEN today and must stay green.
assert_says "release:fedora-still-reaches-the-install-step" "permission for 1 thing" "$out"

record "release:fedora-installer-rc" \
       "$(printf '%s' "$out" | sed -n 's/.*===INSTALLER-RC=\([0-9]*\)===.*/\1/p' | head -1)"
sandbox_reap
