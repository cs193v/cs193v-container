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
SB_CASES="subuid wsl podman-old no-podman"
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
