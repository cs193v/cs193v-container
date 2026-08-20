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
SB_CASES="subuid wsl"
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
