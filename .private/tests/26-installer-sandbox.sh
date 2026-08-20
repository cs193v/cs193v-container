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
SB_CASES="subuid"
trap 'sandbox_cleanup; rm -rf "$SB_TMP"' EXIT
record "sandbox:leftover-dirs-from-an-earlier-run" "$(shim_sweep_stale)"

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
