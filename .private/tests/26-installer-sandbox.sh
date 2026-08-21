#!/usr/bin/env bash
# TIER: install
#
# install-cs193v.sh against machines that really have the properties it tests for, in
# throwaway containers. The other half of 25-installer.sh, which reaches every DECISION the
# installer takes and no EFFECT it has -- see lib/sandbox.sh for why the split is where it is.
#
# Nothing here touches this machine: no writable mount, no podman socket, --network=none,
# and every container is removed the moment its diff is taken.

set -u
. "$(dirname -- "$0")/lib/assert.sh"
. "$(dirname -- "$0")/lib/podman-shim.sh"
. "$(dirname -- "$0")/lib/sandbox.sh"

require_podman

SB_TMP="$(new_tmpdir)"
SB_CASES="subuid wsl podman-old no-podman nested"
trap 'sandbox_cleanup; rm -rf "$SB_TMP"' EXIT
record "sandbox:leftover-dirs-from-an-earlier-run" "$(shim_sweep_stale)"
record "sandbox:leftover-containers-from-an-earlier-run" "$(sandbox_sweep_stale)"

sb_work_init
fixture_build subuid || exit 1

# ─── the subuid range, added for real ──────────────────────────────────────────
# TWO MENUS, SO TWO KEYSTROKES. CS193V_DIR is deliberately not set, so choose_dir prompts
# first (its default is $HOME/cs193v, which here is /home/student/cs193v) and ask_consent
# prompts second. Digits, not arrows: menu()'s `[1-9]` arm selects and breaks in one key, so
# "1" takes choose_dir's default and "2" is consent's "Go ahead".
#
# The count has to be exact. A pty never delivers EOF (ERRORS.md B13), so a spare "\n" is
# read by the NEXT menu as Enter -- which on the consent menu means the default, which means
# declining -- and a missing key makes this hang until sandbox_run's timeout.
out="$(sandbox_run subuid '12')"
record "subuid:transcript-bytes" "$(printf '%s' "$out" | wc -c | tr -d ' ')"

assert_says "sb-subuid:only-the-subuid-needs-permission" "permission for 1 thing" "$out"
assert_says "sb-subuid:names-what-it-wants"              'Give your account a "subuid range"' "$out"
assert_says "sb-subuid:reports-success"                  "subuid range added for student" "$out"
assert_says "sb-subuid:finishes"                         "Setup finished" "$out"
assert_says "sb-subuid:exited-0"                         "===INSTALLER-RC=0===" "$out"

# THE EFFECT, read out of the container itself. `podman diff` can only say that /etc/subuid
# was opened for write; the claim under test is what ended up in it, and a wrong range is a
# silent failure much later, inside podman.
assert_eq "sb-subuid:etc-subuid-has-the-range" "student:200000:65536" \
          "$(sb_section "$out" ETC-SUBUID)"
assert_eq "sb-subuid:etc-subgid-has-the-range" "student:200000:65536" \
          "$(sb_section "$out" ETC-SUBGID)"

# ...AND NOTHING ELSE, which is the half no prose assertion can reach. The expected set is
# checked in at fixtures/expected-system-paths.subuid and asserted in BOTH directions, so an
# installer that grows a host write reddens here, and one that stops making a change it used
# to make reddens too. Twelve lines, deliberately short enough to read rather than skim.
assert_says "sb-subuid:diff-shows-etc-subuid" '/etc/subuid' "$(sandbox_diff)"
assert_system_diff subuid /home/student/cs193v
sandbox_reap

# ─── /etc/wsl.conf, all four states, with no Windows anywhere ──────────────────
# platform() decides WSL by `grep -qi microsoft /proc/version` and setup_wslconf's effect is
# two file writes, so one bind mount makes the entire arm executable here. Verified rather
# than assumed: podman will bind a file over /proc/version, and the survey then reports
# "wsl on x86_64".
#
# FOUR STATES, NOT THREE, and the fourth is the point: survey looks for `systemd=true`
# (installer:398) while setup_wslconf looks for `[boot]` (installer:534), so a file that has
# [boot] and not systemd=true is the only input that reaches the `sed` at installer:535 --
# and nothing had ever reached it.
fixture_build wsl || exit 1

wsl_run() {                           # wsl_run STATE KEYS -> transcript
    sandbox_run wsl "$2" -e "SB_WSLCONF=$1" -e CS193V_DIR=/home/student/cs193v \
                -v "$SB_WORK/proc-version:/proc/version:ro"
}

# The bind mount is what everything below rests on, so it is asserted on its own terms first.
out="$(wsl_run absent '')"
assert_says "sb-wsl:detected-as-wsl-on-linux" "wsl on x86_64" "$out"

# No wsl.conf at all: announced with ok(), not need(), so this one needs no permission -- the
# only host-changing step in the whole installer that does not ask.
assert_says "sb-wsl-absent:needs-no-permission" "Nothing on your computer needs to change" "$out"
assert_says "sb-wsl-absent:says-it-will-create-it" "systemd will be enabled" "$out"
assert_eq   "sb-wsl-absent:writes-both-lines" "[boot]
systemd=true" "$(sb_section "$out" WSL-CONF)"
assert_says "sb-wsl-absent:names-the-restart-command" "wsl --terminate CS193V" "$out"
assert_system_diff wsl /home/student/cs193v wsl-absent
sandbox_reap

# A wsl.conf with no [boot] section: appended to, and the existing content must survive.
out="$(wsl_run noboot '2')"
assert_says "sb-wsl-noboot:asks-permission"  "permission for 1 thing" "$out"
assert_says "sb-wsl-noboot:says-the-file-exists" "already exists" "$out"
assert_eq   "sb-wsl-noboot:appends-and-keeps-what-was-there" "[automount]
enabled=true
[boot]
systemd=true" "$(sb_section "$out" WSL-CONF)"
sandbox_reap

# [boot] present without systemd=true -- the sed arm, which nothing reached before. It must
# rewrite the section in place rather than appending a SECOND [boot], which is what an append
# would do here and what WSL would then read inconsistently.
out="$(wsl_run boot '2')"
assert_eq "sb-wsl-boot:rewrites-the-section-in-place" "[boot]
systemd=true" "$(sb_section "$out" WSL-CONF)"
assert_eq "sb-wsl-boot:did-not-add-a-second-boot-section" "1" \
          "$(sb_section "$out" WSL-CONF | grep -c '^\[boot\]$')"
sandbox_reap

# Already on: skipped, and nothing touched.
out="$(wsl_run systemd '')"
assert_says "sb-wsl-systemd:skips"           "systemd is enabled" "$out"
assert_says_not "sb-wsl-systemd:asks-nothing" "permission for" "$out"
assert_eq "sb-wsl-systemd:leaves-the-file-alone" "[boot]
systemd=true" "$(sb_section "$out" WSL-CONF)"
sandbox_reap

# ─── a podman that is really too old ───────────────────────────────────────────
# ubuntu:24.04 ships podman 4.9.3 against MIN_PODMAN=5.7.0, so the refusal comes off a real
# `podman --version` rather than a string a fake was told to print. 25-installer.sh already
# covers the branch that way; what this adds is that the PARSE holds -- survey reads the
# version with `awk '{print $NF}'`, and a change in podman's own output format would slip
# straight past a fake printing what the test expects.
#
# NO KEYSTROKES: survey dies before choose_dir, so no menu is ever drawn.
fixture_build podman-old || exit 1
out="$(sandbox_run podman-old '' -e CS193V_DIR=/home/student/cs193v)"
record "sb-old:the-version-24.04-actually-ships" "$(sb_section "$out" PODMAN-AFTER)"
assert_says "sb-old:refused"                 "needs 5.7.0 or newer" "$out"
assert_says "sb-old:names-what-it-found"     "Podman 4.9.3"         "$out"
assert_says "sb-old:says-how-to-upgrade"     "only-upgrade podman"  "$out"
assert_says "sb-old:exits-nonzero"           "===INSTALLER-RC=1===" "$out"
assert_says_not "sb-old:does-not-claim-success" "Setup finished"    "$out"
# The version really came from a binary, not from a fake: podman is present in this fixture
# and reports it. If Ubuntu ever raises 24.04's podman past the floor, `sb-old:refused` above
# fails loudly and the record says why -- which is the behaviour wanted, not a nuisance.
assert_says "sb-old:the-version-is-a-real-binary-s" "podman version 4.9.3" \
            "$(sb_section "$out" PODMAN-AFTER)"
# Refusing must cost nothing at all -- not a package, not a directory.
assert_eq "sb-old:installed-nothing" "" "$(sb_section "$out" DPKG-ADDED)"
# ...which the exact-set audit says in both directions. Worth having here more than anywhere:
# a refusal that quietly left something behind is the failure nobody would look for.
assert_system_diff podman-old /home/student/cs193v
sandbox_reap

# ─── apt really installing podman, with the network off ────────────────────────
# The three branches no PATH shim can decide, because they are properties of the machine:
# podman absent, ssh absent, and what `apt-get install` then does about it. Taking the fake
# podman off PATH only exposes the real /usr/bin/podman, so 25-installer.sh cannot reach any
# of them -- see the note where it declines to try.
#
# Offline: the fixture carries a file:// apt repository holding the download-only closure of
# the three packages, and the network sources are gone, so `apt-get update` succeeds against
# the local repo and the install comes out of it. --network=none is still in force.
#
# TWO consent items -- podman+uidmap and openssh-client, gated independently on purpose
# (installer:486-488) -- and one menu, because CS193V_DIR is set. So one keystroke.
fixture_build no-podman || exit 1
out="$(sandbox_run no-podman '2' -e CS193V_DIR=/home/student/cs193v)"
assert_says "sb-apt:asks-for-both-independently" "permission for 2 thing" "$out"
assert_says "sb-apt:names-podman-and-uidmap"     "Install podman (and uidmap)" "$out"
assert_says "sb-apt:names-openssh-client"        "Install openssh-client" "$out"
assert_says "sb-apt:says-what-it-is-installing"  "Installing podman uidmap openssh-client" "$out"

# THE EFFECT. podman was absent before -- the consent item above only exists when it is --
# and it is present after, which the two together can only both satisfy if apt really worked.
assert_says "sb-apt:podman-is-installed-afterwards" "podman version" \
            "$(sb_section "$out" PODMAN-AFTER)"
assert_eq   "sb-apt:ssh-is-installed-afterwards" "present" "$(sb_section "$out" SSH-AFTER)"
assert_says "sb-apt:the-post-install-check-passed" "podman 5.7.0" "$out"

# Asserted in PACKAGES, not paths: the path-level diff here is several hundred lines of /usr
# and /var/lib/dpkg, which is the wrong unit for the claim and too long to be read by anyone.
added="$(sb_section "$out" DPKG-ADDED)"
if [ -n "$added" ]; then pass "sb-apt:the-package-list-was-really-read"
else fail "sb-apt:the-package-list-was-really-read" "dpkg reported no new packages"; fi
for pkg in podman uidmap openssh-client; do
    assert_says "sb-apt:installed-$pkg" "$pkg" "$added"
done
record "sb-apt:packages-added" "$(printf '%s' "$added" | grep -c . ) packages"

# WHERE THIS RUN STOPS, recorded rather than asserted green. podman is real now, so
# build_image hands off to the launcher, which asks a real podman to build inside a container
# -- podman-in-podman, which this tier deliberately does not set up. That is increment C's
# job and it is env-gated. Everything above happens before it.
record "sb-apt:installer-rc" "$(printf '%s' "$out" | sed -n 's/.*===INSTALLER-RC=\([0-9]*\)===.*/\1/p' | head -1)"
sandbox_reap

# ─── nested: the launcher really building, inside a container ───────────────────
# The one case that needs podman-in-podman, so the one case that is opt-in. Everything above
# runs on every full run; this does not, because it builds fixture images and drives a real
# nested podman. The build itself is gated again below -- these prerequisites take seconds.
#
# THE SKIP IS ANNOUNCED, not silent. VERIFICATION.md §A.15 records that a gate outside the
# default run is the same defect as an assertion that never executed, so the way to have both
# is a skip that names the variable and shows up in the results.
if [ "${CS193V_INSTALL_NESTED:-}" != 1 ]; then
    skip "nested:the-prerequisites" "set CS193V_INSTALL_NESTED=1 -- seconds; the build itself is a second gate"
else
fixture_build nested || exit 1

# ─── the prerequisites, before anything rests on them ──────────────────────────
np="$(nest_probe)"
record "nest:podman-inside" "$(nest_get "$np" PODMAN_VERSION)"
record "nest:cgroups"       "$(nest_get "$np" CGROUP)"

# THE STAMP FIRST. Every measurement below is taken through a container boundary, and if the
# boundary is not there they all come out green about the HOST instead. A build-time id baked
# into the image is the one answer no host-side execution can forge.
assert_match "nest:the-probe-ran-inside-the-fixture" '^nested-fixture-[0-9]+$' \
             "$(nest_get "$np" FIXTURE_ID)"
assert_eq "nest:runs-as-the-unprivileged-student" "2:student" "$(nest_get "$np" ID)"

# A nested user namespace really was created, and it is not the host's.
assert_match "nest:nested-userns-created" '^user:\[[0-9]+\]$' "$(nest_get "$np" INNER_USERNS)"
assert_ne   "nest:that-userns-is-not-the-host-s" "$(readlink /proc/self/ns/user)" \
            "$(nest_get "$np" INNER_USERNS)"
# 32768 pre-seeded ids plus the user's own. The range has to lie INSIDE the outer container's
# 1..65536 window -- the installer's own 200000-265535 is entirely outside it -- so this
# number is the one that says the pre-seeded range is what got mapped.
assert_eq "nest:the-preseeded-range-is-what-got-mapped" "65535" "$(nest_get "$np" MAPPED_IDS)"
assert_eq "nest:subuid-range-is-inside-the-outer-window" "student:3:65534" \
          "$(nest_get "$np" SUBUID)"
# ...and it has to COVER gid 65534, because apt's sandbox user drops to nogroup and calls
# setgroups(). An unmapped gid there kills the course build three steps in.
# THE COUNT, not the span, and the difference is what a whole afternoon turned on. Mapping
# container gid 65534 needs at least 65534 ids in the range; a range of 55536 ids whose numbers
# happen to include the value 65534 does NOT map it, and the course build dies at apt three
# steps in with "Failed to setgroups". Computed from the range so a future narrowing reddens
# here rather than in a four-minute build.
nsub="$(nest_get "$np" SUBUID)"
ncount="$(printf '%s' "$nsub" | cut -d: -f3)"
if [ -n "$ncount" ] && [ "$ncount" -ge 65534 ]; then
    pass "nest:the-range-maps-nogroup-65534"
else
    fail "nest:the-range-maps-nogroup-65534" "range '$nsub' has ${ncount:-no} ids; gid 65534 needs 65534"
fi

# SYS_ADMIN is the difference, measured both ways. Without it newuidmap cannot write uid_map,
# so the probe reports an error instead of a namespace -- which is what makes the fixture's
# one privilege departure a tested fact rather than a comment.
assert_eq "nest:setuid-is-live-and-the-rootfs-is-not-nosuid" "overlay suid-ok" \
          "$(nest_get "$np" ROOTFS)"
nn="$(nest_probe_nocap)"
assert_says_not "nest:without-SYS_ADMIN-there-is-no-namespace" 'user:[' \
                "$(nest_get "$nn" INNER_USERNS)"
assert_says "nest:without-SYS_ADMIN-newuidmap-is-what-fails" 'newuidmap' \
            "$(nest_get "$nn" INNER_USERNS)"
assert_match "nest:the-nocap-probe-also-really-ran" '^nested-fixture-[0-9]+$' \
             "$(nest_get "$nn" FIXTURE_ID)"

# The second departure, with its own control. Without the unmask the outer container's /proc/sys
# is read-only, so crun cannot set ping_group_range and the inner network never comes up --
# which is a different failure from the SYS_ADMIN one and has to be told apart from it.
assert_eq "nest:proc-sys-is-unmasked-with-the-flag" "not-masked" "$(nest_get "$np" PROC_SYS)"
nu="$(nest_probe_nounmask)"
assert_eq "nest:without-the-unmask-proc-sys-is-masked" "masked-ro" "$(nest_get "$nu" PROC_SYS)"
assert_match "nest:the-nounmask-probe-also-really-ran" '^nested-fixture-[0-9]+$' \
             "$(nest_get "$nu" FIXTURE_ID)"
# ...and that control must still create its namespace, or it would be failing for the OTHER
# reason and proving nothing about the unmask.
assert_match "nest:the-nounmask-control-isolates-one-flag" '^user:\[[0-9]+\]$' \
             "$(nest_get "$nu" INNER_USERNS)"

# The devices, and that fuse-overlayfs can really mount rather than merely being installed.
assert_eq "nest:dev-fuse-is-present"   "char-device" "$(nest_get "$np" DEVFUSE)"
assert_eq "nest:dev-net-tun-is-present" "char-device" "$(nest_get "$np" DEVNETTUN)"
assert_eq "nest:fuse-overlayfs-can-mount" "fuse.fuse-overlayfs" "$(nest_get "$np" FUSE_MOUNT)"
# Recorded, not asserted: podman accepts the systemd cgroup manager here even with no session,
# so "cgroupfs is required" is not something this probe showed. The config is still right --
# SESSION proves there is no session to use -- but the claim would be bigger than the evidence.
assert_eq "nest:there-is-no-systemd-user-session" "no-bus unset" "$(nest_get "$np" SESSION)"
record "nest:store" "$(nest_get "$np" STORE)"

# ─── and now the build, for real ───────────────────────────────────────────────
# A SECOND GATE, because the two answer different questions and cost wildly different amounts.
# Everything above proves nesting works here and pins what it costs, in seconds. This assembles
# the whole 25-step course image inside the fixture: measured at 6.2 GB of inner store, 8 GB of
# host disk while it runs, and several minutes.
#
# IT WORKS, and every step of getting there was an artefact of the extra nesting level rather
# than a defect in the installer or the launcher -- podman's masked /proc, a missing passt, a
# subuid range that could not map nogroup, and overlay-on-overlay corrupting a symlink replace.
# The host control matters most: the identical package list installs cleanly unnested, so the
# Containerfile was never at fault.
if [ "${CS193V_INSTALL_NESTED_BUILD:-}" != 1 ]; then
    skip "nested:the-course-build" "set CS193V_INSTALL_NESTED_BUILD=1 -- a real 25-step build, ~6GB and several minutes"
else
# THE HOST CANARY, taken around it. Everything else here is measured through a container
# boundary; this is the assertion that the boundary held. Paired with the inner store growing,
# because "nothing changed anywhere" is exactly what a case that ran nothing would report --
# the vacuous pass 25-installer.sh:7-13 records for A.12's own idempotency check.
imgs_before="$(podman images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | LC_ALL=C sort | cksum)"
vols_before="$(podman volume ls --format '{{.Name}}' | LC_ALL=C sort | cksum)"
subuid_before="$(cksum < /etc/subuid)"

out="$(nest_build)"
record "nest:inner-store-bytes" "$(sb_section "$out" INNER-STORE-BYTES)"
record "nest:inner-caps"        "$(sb_section "$out" INNER-CAPS)"

assert_says "nest:the-installer-finished"   "Setup finished"       "$out"
assert_says "nest:it-exited-0"              "===INSTALLER-RC=0===" "$out"
assert_eq   "nest:the-course-image-was-really-built" "yes" "$(sb_section "$out" IMAGE-EXISTS)"
# PAIRED, because `doctor` returned ok on a run with no image and no container at all -- it
# does not fail on an unbuilt installation, so on its own this assertion says less than its
# name claims.
assert_eq   "nest:doctor-runs-in-there"     "ok"   "$(sb_section "$out" DOCTOR)"
assert_eq   "nest:and-there-was-something-for-doctor-to-look-at" "yes" \
            "$(sb_section "$out" IMAGE-EXISTS)"
# The inner store really grew, which is what stops the three canaries below from passing on a
# run that did nothing at all.
istore="$(sb_section "$out" INNER-STORE-BYTES)"
if [ -n "$istore" ] && [ "$istore" -gt 1000000000 ]; then pass "nest:the-inner-store-really-grew"
else fail "nest:the-inner-store-really-grew" "inner graph root is ${istore:-empty} bytes"; fi

# THE BOUNDARY THIS FIXTURE SITS ON THE WRONG SIDE OF. The outer container has SYS_ADMIN; the
# course container must not, and its flags come from $DIR/.config/container.args, which this
# fixture never edits. Nowhere else in the suite is that separation meaningful -- 60-container.sh
# asserts no-SYS_ADMIN too, but always where nothing nearby had it.
assert_says_not "nest:SYS_ADMIN-did-not-reach-the-course-container" "SYS_ADMIN" \
                "$(sb_section "$out" INNER-CAPS)"
assert_says "nest:the-inner-caps-were-really-read" "cap_" "$(sb_section "$out" INNER-CAPS)"

assert_eq "nest:host-image-list-untouched"  "$imgs_before" \
          "$(podman images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | LC_ALL=C sort | cksum)"
assert_eq "nest:host-volume-list-untouched" "$vols_before" \
          "$(podman volume ls --format '{{.Name}}' | LC_ALL=C sort | cksum)"
assert_eq "nest:host-subuid-untouched" "$subuid_before" "$(cksum < /etc/subuid)"
sandbox_reap
fi
fi
