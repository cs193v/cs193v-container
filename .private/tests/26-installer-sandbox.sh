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
# LABELS, not machines. Every case below runs on ONE image and says what it took away; these are
# just the container names to sweep on the way out.
SB_CASES="apt cannot-answer wsl-absent wsl-noboot wsl-boot wsl-systemd podman-old debian fedora arch nested"
trap 'sandbox_cleanup; rm -rf "$SB_TMP"' EXIT
record "sandbox:leftover-dirs-from-an-earlier-run" "$(shim_sweep_stale)"
record "sandbox:leftover-containers-from-an-earlier-run" "$(sandbox_sweep_stale)"

sb_work_init
fixture_build machine || exit 1

# ─── apt really installing podman, with the network off ────────────────────────
# THE MACHINE IS DESCRIBED, NOT NAMED, and that is the change this suite exists to make. What
# this case is about is "podman and ssh are absent", so that is what it says -- rather than a
# fixture called `no-podman` that also happened to lack SYS_ADMIN and therefore also stood for
# "podman is installed but cannot run". Those are two scenarios and they now have two cases.
#
# The two branches no PATH shim can decide, because they are properties of the machine: podman
# absent and ssh absent. Taking the fake podman off PATH only exposes the real /usr/bin/podman,
# so 25-installer.sh cannot reach either.
#
# REMOVED FOR REAL, then reinstalled OFFLINE from the machine's baked-in file:// repository.
# --network=none is still in force, and lib/sandbox-guest.sh records why concealment would not
# do: apt would say "already the newest version" and the path under test would never run.
#
# TWO consent items -- podman+uidmap and openssh-client, gated independently on purpose
# (installer:562) -- and one menu, because CS193V_DIR is set. So one keystroke.
sb_machine no-prereqs=podman,ssh
# SB_PROBE_PODMAN only here: this is the one non-building case that installs podman, so it is
# the only one where "did the thing apt installed actually work" is worth the store that asking
# it creates.
out="$(sandbox_run apt '2' -e CS193V_DIR=/home/student/cs193v -e SB_PROBE_PODMAN=1)"
record "apt:transcript-bytes" "$(printf '%s' "$out" | wc -c | tr -d ' ')"
assert_says "sb-apt:the-machine-was-really-arranged" "prereqs=podman,ssh" "$(sb_section "$out" ARRANGED)"
assert_says "sb-apt:asks-for-both-independently" "permission for 2 thing" "$out"
assert_says "sb-apt:names-podman-and-uidmap"     "Install podman (and uidmap)" "$out"
assert_says "sb-apt:names-openssh-client"        "Install openssh-client" "$out"
assert_says "sb-apt:says-what-it-is-installing"  "Installing podman uidmap openssh-client" "$out"

# THE EFFECT. podman was absent before -- the consent item above only exists when it is -- and
# it is present after, which the two together can only both satisfy if apt really worked.
assert_says "sb-apt:podman-is-installed-afterwards" "podman version" \
            "$(sb_section "$out" PODMAN-AFTER)"
assert_eq   "sb-apt:ssh-is-installed-afterwards" "present" "$(sb_section "$out" SSH-AFTER)"
assert_says "sb-apt:the-post-install-check-passed" "podman 5.7.0" "$out"

# INSTALLED IS NOT THE SAME AS WORKING, and this is now asserted rather than recorded. The old
# fixture could only record what its podman said, because it lacked the capability to run one;
# this machine has everything, so the podman apt installed really answers -- which is what makes
# the --no-caps=sysadmin case below a deliberate DIFFERENTIAL rather than an environmental limit
# dressed up as a property.
mem="$(sb_section "$out" PODMAN-WORKS)"
assert_match "sb-apt:the-podman-apt-installed-really-works" '^[0-9]{6,}$' "$mem"

# Asserted in PACKAGES, not paths: the path-level diff here is several hundred lines of /usr
# and /var/lib/dpkg, which is the wrong unit for the claim and too long to be read by anyone.
added="$(sb_section "$out" DPKG-ADDED)"
if [ -n "$added" ]; then pass "sb-apt:the-package-list-was-really-read"
else fail "sb-apt:the-package-list-was-really-read" "dpkg reported no new packages"; fi
for pkg in podman uidmap openssh-client; do
    assert_says "sb-apt:installed-$pkg" "$pkg" "$added"
done
record "sb-apt:packages-added" "$(printf '%s' "$added" | grep -c . ) packages"
# WHERE THIS RUN STOPS, recorded rather than asserted green: podman works now, so build_image
# hands off to the launcher, which needs the network this case does not have. The end-to-end
# case below is the one that gives it a network.
record "sb-apt:installer-rc" "$(printf '%s' "$out" | sed -n 's/.*===INSTALLER-RC=\([0-9]*\)===.*/\1/p' | head -1)"
sandbox_reap

# ─── podman installed, and unable to run ───────────────────────────────────────
# THE FAILURE FROM THE BUG REPORT, asked for on purpose. It used to be an accident: the
# no-podman fixture lacked SYS_ADMIN, so the podman it installed could not create a user
# namespace, and the run stopped at write_local_args. That was recorded as an environmental
# limit -- and then assertions were written treating it as a property, and a claim was made that
# the branch was "only reachable there". It was reachable in the shim tier all along.
#
# What makes it worth a case here is the DIFFERENTIAL: the case above is the same machine with
# the capability, and its podman answers with a real number. So this one is measuring the
# capability rather than measuring the fixture's limits.
#
# It is also a real student failure. Ubuntu ships kernel.apparmor_restrict_unprivileged_userns=1
# and relies on newuidmap being setuid-root; a restrictive profile, a nosuid mount or a missing
# uidmap all give a student the same observable.
sb_machine no-prereqs=podman no-caps=sysadmin
out="$(sandbox_run cannot-answer '2' -e CS193V_DIR=/home/student/cs193v -e SB_PROBE_PODMAN=1)"
assert_says "sb-noans:apt-still-installed-it" "podman version" "$(sb_section "$out" PODMAN-AFTER)"
assert_says "sb-noans:but-it-cannot-answer" "newuidmap" "$(sb_section "$out" PODMAN-WORKS)"
assert_says "sb-noans:the-installer-says-so" "Could not ask podman how much memory" "$out"
assert_says "sb-noans:exits-nonzero"         "===INSTALLER-RC=1===" "$out"
assert_says_not "sb-noans:does-not-claim-success" "Setup finished" "$out"
# ...and it got far enough to have done the install first, which is what tells this apart from
# a run that failed before reaching the question.
assert_says "sb-noans:it-had-already-installed-podman" "Installing podman uidmap" "$out"
sandbox_reap

# ─── curl absent, which is a stock Ubuntu Desktop ──────────────────────────────
# THE PLATFORM DIFFERENCE NO TEST COULD SEE, and the fixtures are why: both of them installed
# curl, so the machine every case ran on was not the machine a student has. curl is NOT in the
# Ubuntu desktop image -- the 26.04 and 24.04 manifests carry wget and libcurl4t64 and no curl
# -- while the WSL image and macOS both ship it. So fetch_files' unguarded curl (installer:736)
# failed for a whole platform, and said "This is usually a network problem" about a machine that
# simply had no curl, after consent, apt and usermod had already run.
#
# ONE CONSENT ITEM, which is the shape worth a case of its own: podman and ssh are present, so
# curl is the ONLY reason apt runs at all. The both-missing shape is the apt case above.
sb_machine no-prereqs=curl
out="$(sandbox_run curl '2' -e CS193V_DIR=/home/student/cs193v)"
assert_says "sb-curl:the-machine-was-really-arranged" "prereqs=curl" "$(sb_section "$out" ARRANGED)"
assert_says "sb-curl:asks-for-one-thing"         "permission for 1 thing" "$out"
assert_says "sb-curl:names-curl"                 "Install curl" "$out"
assert_says "sb-curl:says-what-it-is-installing" "Installing curl" "$out"
added="$(sb_section "$out" DPKG-ADDED)"
assert_says "sb-curl:installed-curl" "curl" "$added"
# THE NEGATIVE IS HALF THE CLAIM. Without it this case could be passing on a machine that
# lacked podman too, i.e. a second copy of the apt case wearing a different name.
assert_says_not "sb-curl:did-not-reinstall-podman" "podman" "$added"
# THE EFFECT, and the one assertion here that could not pass before: the tarball is fetched
# with the curl this run installed. `dir-only` is the failure -- fetch_files creates $DIR
# (installer:719) before curl runs, so the directory exists either way and only the launcher
# inside it distinguishes a download that happened from one that died.
assert_eq "sb-curl:the-course-files-arrived" "launcher-is-executable" "$(sb_section "$out" COURSE-DIR)"
# WHERE THIS RUN STOPS, recorded not asserted, for the apt case's reason: the download works
# now, so build_image hands off to the launcher, which wants the network this case has not got.
record "sb-curl:installer-rc" "$(printf '%s' "$out" | sed -n 's/.*===INSTALLER-RC=\([0-9]*\)===.*/\1/p' | head -1)"
sandbox_reap

# ─── podman installed, its setuid helpers not ──────────────────────────────────
# THE THIRD CAUSE OF THE OBSERVABLE THE CASE ABOVE MEASURES, and the only one of the three the
# installer can do anything about. lib/sandbox.sh names them where MACHINE_CAP_NAMES is defined:
# a restrictive apparmor profile, a nosuid mount, or a missing uidmap all hand a student a podman
# that cannot create a user namespace, and the run dead-ends at write_local_args (installer:757).
#
# uidmap is a RECOMMENDS of podman rather than a Depends, so the two come apart on a real machine
# -- `--no-install-recommends`, a hand-rolled podman, an image built with recommends off. And the
# installer's uidmap only ever rode along with podman's own install (installer:579), so on this
# machine it did nothing whatsoever: it skipped, then hit the dead end.
sb_machine no-prereqs=uidmap
out="$(sandbox_run uidmap '2' -e CS193V_DIR=/home/student/cs193v -e SB_PROBE_PODMAN=1)"
assert_says "sb-uidmap:the-machine-was-really-arranged" "prereqs=uidmap" "$(sb_section "$out" ARRANGED)"
assert_says "sb-uidmap:asks-for-one-thing"         "permission for 1 thing" "$out"
assert_says "sb-uidmap:names-uidmap"               "Install uidmap" "$out"
assert_says "sb-uidmap:says-what-it-is-installing" "Installing uidmap" "$out"
added="$(sb_section "$out" DPKG-ADDED)"
assert_says "sb-uidmap:installed-uidmap" "uidmap" "$added"
# PODMAN WAS NEVER GONE, which is the difference between this case and the apt one, and the whole
# reason the installer's podman-gated uidmap could not save it.
assert_says_not "sb-uidmap:did-not-reinstall-podman" "podman" "$added"
# INSTALLED IS NOT WORKING, and here that is the entire claim: before the helpers came back this
# machine's podman answered with the newuidmap failure the case above asserts, and after them it
# answers a real number. SB_PROBE_PODMAN earns its store for the apt case's reason -- the probe IS
# the assertion -- and this case takes no path-level audit for that store to disturb.
assert_match "sb-uidmap:podman-answers-once-the-helpers-are-back" '^[0-9]{6,}$' \
             "$(sb_section "$out" PODMAN-WORKS)"
record "sb-uidmap:installer-rc" "$(printf '%s' "$out" | sed -n 's/.*===INSTALLER-RC=\([0-9]*\)===.*/\1/p' | head -1)"
sandbox_reap

# ─── /etc/wsl.conf, all four states, with no Windows anywhere ──────────────────
# platform() decides WSL by `grep -qi microsoft /proc/version` and setup_wslconf's effect is
# two file writes, so one bind mount makes the entire arm executable here. Verified rather
# than assumed: podman will bind a file over /proc/version, and the survey then reports
# "wsl on x86_64".
#
# FOUR STATES, NOT THREE, and the fourth is the point: survey looks for `systemd=true`
# (installer:463) while setup_wslconf looks for `[boot]` (installer:639), so a file that has
# [boot] and not systemd=true is the only input that reaches the `sed` at installer:640 --
# and nothing had ever reached it.
#
# --fake-podman, NAMED. These four used to be fast because their fixture baked in
# lib/podman-fake, which the machine name said nothing about. This case is about /etc/wsl.conf;
# building a real image would take minutes and prove nothing extra, so the fake is asked for
# out loud.
wsl_run() {                           # wsl_run STATE KEYS -> transcript
    sb_machine platform=wsl fake-podman=yes
    sandbox_run "wsl-$1" "$2" -e "SB_WSLCONF=$1" -e CS193V_DIR=/home/student/cs193v
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
# ubuntu:22.04 ships podman 3.4.4 against MIN_PODMAN_LINUX=4.9.0, so the refusal comes off a real
# `podman --version` rather than a string a fake was told to print. 25-installer.sh already
# covers the branch that way; what this adds is that the PARSE holds -- survey reads the
# version with `awk '{print $NF}'`, and a change in podman's own output format would slip
# straight past a fake printing what the test expects.
#
# NO KEYSTROKES: survey dies before choose_dir, so no menu is ever drawn.
fixture_build podman-old || exit 1
# THE ONE MACHINE THAT IS NOT THE MACHINE, stated rather than forced. A VERSION cannot be
# produced by subtracting from a 26.04 base -- 26.04's archive has no podman 3.4.4 to install --
# so this stays a second small image, and `base=` is how a case asks for it. Neither axis
# applies: its whole job is one refusal in the survey, which needs no capability and no repo.
sb_machine base=podman-old
out="$(sandbox_run podman-old '' -e CS193V_DIR=/home/student/cs193v)"
record "sb-old:the-version-22.04-actually-ships" "$(sb_section "$out" PODMAN-AFTER)"
assert_says "sb-old:refused"                 "needs 4.9.0 or newer" "$out"
assert_says "sb-old:names-what-it-found"     "Podman 3.4.4"         "$out"
assert_says "sb-old:says-how-to-upgrade"     "only-upgrade podman"  "$out"
assert_says "sb-old:exits-nonzero"           "===INSTALLER-RC=1===" "$out"
assert_says_not "sb-old:does-not-claim-success" "Setup finished"    "$out"
# The version really came from a binary, not from a fake: podman is present in this fixture
# and reports it. If Ubuntu ever raises 22.04's podman past the floor, `sb-old:refused` above
# fails loudly and the record says why -- which is the behaviour wanted, not a nuisance.
assert_says "sb-old:the-version-is-a-real-binary-s" "podman version 3.4.4" \
            "$(sb_section "$out" PODMAN-AFTER)"
# Refusing must cost nothing at all -- not a package, not a directory.
assert_eq "sb-old:installed-nothing" "" "$(sb_section "$out" DPKG-ADDED)"
# ...which the exact-set audit says in both directions. Worth having here more than anywhere:
# a refusal that quietly left something behind is the failure nobody would look for.
assert_system_diff podman-old /home/student/cs193v
sandbox_reap

# ─── Debian stable, which the floor used to turn away and now does not ─────────
# THE CASE THAT INVERTED, and the inversion is the change. While MIN_PODMAN was 5.7.0 this case
# asserted a REFUSAL: Debian 13 (trixie, current stable) ships podman 5.4.2, and the survey died
# before apt was ever reached. #94 is about package managers, and apt is already the right answer
# on Debian -- so the largest excluded population was being excluded by a NUMBER rather than by
# the defect the issue describes. That is what made the floor worth measuring.
#
# It was measured, and 5.4.2 builds the entire course image (see oldest-supported below, which
# does the same on 4.9.3). So MIN_PODMAN_LINUX is 4.9.0 and this machine is SUPPORTED. What the
# case asserts now is that the survey accepts it and the install carries on -- which also covers
# Mint, Pop!_OS, elementary, Zorin, Kali, Raspberry Pi OS and the non-Ubuntu WSL distros, all of
# which are Debian underneath.
#
# NO KEYSTROKES, and that is itself an assertion. This fixture has podman, ssh, curl, uidmap and a
# subuid range, so there is nothing for ask_consent to ask about and no menu is drawn. A machine
# that needs nothing is the shape a supported machine has.
#
# WHERE IT STOPS is write_local_args, and that is a property of Tier A rather than of Debian: no
# nesting flags, so the podman it just accepted cannot create a user namespace and cannot answer
# `podman info`. Same dead end the cannot-answer case asserts deliberately. The end-to-end proof
# for Debian is the nested build in oldest-supported; here the claim is only that the survey no
# longer refuses it.
fixture_build debian || exit 1
sb_machine base=debian
out="$(sandbox_run debian '' -e CS193V_DIR=/home/student/cs193v)"
record "sb-deb:the-version-debian-13-actually-ships" "$(sb_section "$out" PODMAN-AFTER)"
assert_says "sb-deb:accepted"                  "podman 5.4.2" "$out"
assert_says_not "sb-deb:not-refused-any-more"  "or newer"     "$out"
assert_says "sb-deb:needs-nothing-installed"   "Nothing on your computer needs to change" "$out"
assert_says_not "sb-deb:asks-no-permission"    "permission for" "$out"
# IT GOT THE COURSE FILES, which is further than this machine had ever got: fetch_files runs after
# consent and before write_local_args, so `launcher-is-executable` can only be true on a run that
# passed the survey.
assert_eq "sb-deb:the-course-files-arrived" "launcher-is-executable" \
          "$(sb_section "$out" COURSE-DIR)"
# ...and then stops for the Tier A reason, not a Debian one. Asserted rather than recorded, because
# a run that got FURTHER would mean this fixture had grown nesting flags nobody declared.
assert_says "sb-deb:stops-where-tier-a-always-stops" "Could not ask podman how much memory" "$out"
record "sb-deb:installer-rc" "$(printf '%s' "$out" | sed -n 's/.*===INSTALLER-RC=\([0-9]*\)===.*/\1/p' | head -1)"
# NO EXACT-SET AUDIT, deliberately, and lib/sandbox.sh gives the reason where SB_PROBE_PODMAN is
# defined: any podman command that touches the runtime creates a store, an events log and lock
# files whose exact set differs between runs. This case reaches `podman info`, so an audit here
# would chase new paths every run. The refusal cases keep theirs, because a refusal touches nothing.
sandbox_reap

# ─── Fedora: the machine #94 is actually about ─────────────────────────────────
# THE DEFECT, EXECUTED. Everything up to install_podman works on Fedora -- platform() reports
# linux, the survey finds podman missing and asks permission for exactly one thing -- and then
# install_podman runs `sudo apt-get update` (installer:591) on a machine that has never had apt.
#
# THIS CASE ASSERTS TODAY'S BEHAVIOUR AND IS GREEN, which is deliberate and worth being explicit
# about. A permanently-red assertion in this tier would fail every run and teach people to ignore
# the suite; 00-release-gates.sh is where "must work before students touch this" lives, and the
# gate that demands a COMPLETED install on Fedora belongs there. What belongs here is the record
# of exactly how the installer fails today, so that a fix has something to move.
#
# WHAT MAKES IT MORE THAN "IT FAILED": the two package names. The consent text says
# "Install podman (and uidmap)" and the step says "Installing podman uidmap" -- and `uidmap` is a
# Debian package name that does not exist on Fedora, where the same binaries come from
# shadow-utils. So the transcript already contains two distinct things a fix has to change, and
# pinning both means a partial fix cannot look complete.
#
# ONE CONSENT ITEM, AND THE BASE IMAGE IS WHY. fedora:43 ships bash, sudo, curl, dnf, newuidmap,
# newgidmap and usermod; the fixture adds openssh-clients and a subuid range. So podman is the
# only thing missing, which keeps the transcript about the package manager rather than about a
# machine that happened to be bare. Containerfile.fedora records the measurements.
fixture_build fedora || exit 1
sb_machine base=fedora
out="$(sandbox_run fedora '2' -e CS193V_DIR=/home/student/cs193v)"
assert_says "sb-fed:detected-as-plain-linux"       "linux on x86_64" "$out"
assert_says "sb-fed:asks-for-one-thing"            "permission for 1 thing" "$out"
# The Debian package name, on a machine that has no such package. Asserted as the CURRENT
# behaviour; the release gate is what says it must change.
assert_says "sb-fed:names-the-debian-package-in-its-consent-text" "Install podman (and uidmap)" "$out"
assert_says "sb-fed:and-again-in-the-install-step"  "Installing podman uidmap" "$out"
# THE DEFECT ITSELF, in the installer's own words. Recorded alongside is what the shell actually
# said, because "apt-get update failed" on a machine with no apt reads as a network problem to
# anybody who has not seen this issue.
assert_says "sb-fed:dies-in-apt-get"               "apt-get update failed" "$out"
record "sb-fed:what-the-shell-said" \
       "$(printf '%s' "$out" | grep -iE 'apt-get.*(not found|No such file)' | head -1)"
assert_says "sb-fed:exits-nonzero"                 "===INSTALLER-RC=1===" "$out"
assert_says_not "sb-fed:does-not-claim-success"     "Setup finished" "$out"
# IT GOT PAST CONSENT, which is what tells this apart from a run that fell over earlier for some
# unrelated reason. Without it the case could pass on a fixture that was simply broken.
assert_says "sb-fed:it-had-consent-before-it-failed" "Installing podman uidmap" "$out"
# ...and nothing was installed, because nothing could be. dnf is the query here, not dpkg.
assert_eq "sb-fed:installed-nothing" "" "$(sb_section "$out" DPKG-ADDED)"
sandbox_reap

# ─── Arch: the same defect, plus the one machine with no subuid range ──────────
# THE SECOND RED DISTRO, and it is not a copy of the Fedora case. Two things are true here and on
# no other base:
#
# THE PACKAGE NAMES ARE A THIRD SPELLING, and that is what it adds. Debian wants openssh-client,
# Fedora openssh-clients, Arch openssh -- and `uidmap`, which the consent text names, exists on
# none of Fedora or Arch, where the same binaries come from shadow-utils and shadow. A fix that
# only dispatched the right COMMAND would still fail on the names, and three families is the
# smallest set that makes that a pattern rather than a coincidence.
#
# THE FIXTURE'S OTHER PREMISE WAS FALSE, and Containerfile.arch records it: Arch was supposed to
# leave /etc/subuid empty, making this the one case that reaches setup_subuid. Measured, it does
# not -- useradd creates a range, so an empty one is a legacy account rather than an Arch trait,
# and --no-prereqs=subuid is already the knob for that. So this case asserts the survey SKIPS the
# subuid check, which is what a normal Arch machine does.
#
# GREEN, LIKE THE FEDORA CASE, and for the same reason: this records what the installer does today
# so a fix has something to move. 05-release-distros.sh holds the requirement.
fixture_build arch || exit 1
sb_machine base=arch
out="$(sandbox_run arch '2' -e CS193V_DIR=/home/student/cs193v)"
assert_says "sb-arch:detected-as-plain-linux" "linux on x86_64" "$out"
assert_says "sb-arch:asks-for-one-thing"      "permission for 1 thing" "$out"
assert_says "sb-arch:names-podman-and-the-debian-uidmap" "Install podman (and uidmap)" "$out"
# THE SUBUID CHECK IS SKIPPED, because useradd gave this account a range. Asserted rather than
# assumed, because the fixture was built believing the opposite.
assert_says "sb-arch:the-account-already-has-a-range" "has the ID range podman needs" "$out"
# THE DEFECT, in the installer's own words, with what the shell actually said recorded beside it --
# "apt-get update failed" reads as a network problem to anyone who has not seen this issue.
assert_says "sb-arch:dies-in-apt-get" "apt-get update failed" "$out"
record "sb-arch:what-the-shell-said" \
       "$(printf '%s' "$out" | grep -iE 'apt-get.*(not found|No such file)' | head -1)"
assert_says "sb-arch:exits-nonzero"            "===INSTALLER-RC=1===" "$out"
assert_says_not "sb-arch:does-not-claim-success" "Setup finished" "$out"
# IT GOT PAST CONSENT, which tells this apart from a run that fell over earlier for an unrelated
# reason -- without it the case could pass on a fixture that simply failed to boot.
assert_says "sb-arch:it-had-consent-before-it-failed" "Installing podman uidmap" "$out"
# ...and the range useradd made is untouched, which is the other half of the skip: nothing was
# offered, so nothing was changed.
assert_eq "sb-arch:the-useradd-range-is-untouched" "student:100000:65536" \
          "$(sb_section "$out" ETC-SUBUID)"
assert_eq "sb-arch:installed-nothing" "" "$(sb_section "$out" DPKG-ADDED)"
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
fixture_build machine || exit 1   # already built above; a cached no-op, kept so this block reads on its own

# ─── the prerequisites, before anything rests on them ──────────────────────────
np="$(nest_probe)"
record "nest:podman-inside" "$(nest_get "$np" PODMAN_VERSION)"
record "nest:cgroups"       "$(nest_get "$np" CGROUP)"

# THE STAMP FIRST. Every measurement below is taken through a container boundary, and if the
# boundary is not there they all come out green about the HOST instead. A build-time id baked
# into the image is the one answer no host-side execution can forge.
assert_match "nest:the-probe-ran-inside-the-fixture" '^machine-fixture-[0-9]+$' \
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
assert_match "nest:the-nocap-probe-also-really-ran" '^machine-fixture-[0-9]+$' \
             "$(nest_get "$nn" FIXTURE_ID)"

# The second departure, with its own control. Without the unmask the outer container's /proc/sys
# is read-only, so crun cannot set ping_group_range and the inner network never comes up --
# which is a different failure from the SYS_ADMIN one and has to be told apart from it.
assert_eq "nest:proc-sys-is-unmasked-with-the-flag" "not-masked" "$(nest_get "$np" PROC_SYS)"
nu="$(nest_probe_nounmask)"
assert_eq "nest:without-the-unmask-proc-sys-is-masked" "masked-ro" "$(nest_get "$nu" PROC_SYS)"
assert_match "nest:the-nounmask-probe-also-really-ran" '^machine-fixture-[0-9]+$' \
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
# A DISK PRECONDITION, because this is the one case here that can hurt the machine rather than
# just fail. Measured: 6.2 GB of inner store and about 8 GB of host disk while it runs, all
# reclaimed on reap. Eleven checkouts share this filesystem, and #76 records what a full one
# does -- $CS193V_RESULTS became unwritable and the run reported "0 fail" having lost its
# results. So it refuses rather than risks it, and says the number either way.
sb_free_gb="$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')"
record "nest:free-disk-gb-before" "${sb_free_gb:-unknown}"
if [ -z "$sb_free_gb" ] || [ "$sb_free_gb" -lt 15 ]; then
    skip "nested:the-course-build" "only ${sb_free_gb:-?}GB free; this build wants ~8GB and a margin"
else

imgs_before="$(podman images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | LC_ALL=C sort | cksum)"
vols_before="$(podman volume ls --format '{{.Name}}' | LC_ALL=C sort | cksum)"
subuid_before="$(cksum < /etc/subuid)"

# ─── THE CASE THAT DID NOT EXIST: no podman, install succeeds, image builds ─────
# nest_build takes the prereq list, so this is the whole point of one machine with everything
# on it: apt installs podman for real, the installer then asks THAT podman for MemTotal and gets
# an answer, writes the args, and the launcher assembles the course image with it. Before this,
# `no-podman` proved apt installs podman and `nested` proved the build works, and nothing joined
# them -- so the one path every student actually takes was the one path nothing ran.
out="$(nest_build podman,ssh "2")"
assert_says "nest:the-machine-was-really-arranged" "prereqs=podman,ssh" "$(sb_section "$out" ARRANGED)"
assert_says "nest:apt-really-put-podman-back" "install ok installed" "$(sb_section "$out" DPKG-PODMAN)"
assert_says "nest:it-installed-before-it-built" "Installing podman uidmap openssh-client" "$out"
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
# AN EXACT VALUE, which proves the field was read AND that nothing leaked, in one assertion.
# The first attempt paired the SYS_ADMIN check with `assert_says cap_` as its positive token --
# and that can never match, because the course container has NO capabilities at all: podman
# reports the empty set as "[]". So the "proof it was read" was looking for something that
# cannot be there, and only a real run showed it. `[]` is both halves: an empty value or
# NO-CONTAINER fails it, and so would any capability, SYS_ADMIN included.
ncaps="$(sb_section "$out" INNER-CAPS)"
assert_eq "nest:the-course-container-has-no-capabilities-at-all" "[]" "$ncaps"
# Named separately because it is the property the fixture's own privilege makes worth stating:
# the outer container has SYS_ADMIN and this one must never see it.
assert_says_not "nest:SYS_ADMIN-did-not-reach-the-course-container" "SYS_ADMIN" "$ncaps"

assert_eq "nest:host-image-list-untouched"  "$imgs_before" \
          "$(podman images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | LC_ALL=C sort | cksum)"
assert_eq "nest:host-volume-list-untouched" "$vols_before" \
          "$(podman volume ls --format '{{.Name}}' | LC_ALL=C sort | cksum)"
assert_eq "nest:host-subuid-untouched" "$subuid_before" "$(cksum < /etc/subuid)"
sandbox_reap
# ...and the space really came back, which is the half a precondition cannot promise.
record "nest:free-disk-gb-after" "$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')"
fi
fi
fi

# ─── the oldest podman the floor admits, built end to end ──────────────────────
# THE FLOOR'S OWN REGRESSION CHECK. MIN_PODMAN_LINUX is 4.9.0, and the reason it is that low is
# that Ubuntu 24.04 LTS ships podman 4.9.3 -- along with Linux Mint 22.x and Pop!_OS 24.04, so
# three of the most common desktop Linuxes ride on that one version. The floor was set from
# measurement: 4.9.3, 5.4.2 and 5.7.0 each ran the whole install and built the entire 25-step
# course image, with inner stores within 22 KB of one another.
#
# THIS IS THE HALF THAT HAS TO KEEP BEING TRUE. A floor is a promise about the oldest thing that
# works, and nothing else in the suite would notice if a Containerfile change or a new launcher
# flag quietly needed podman 5.x. So this builds the course image on a real 4.9.3, with the real
# installer and no floors patched -- the version is admitted now, so nothing needs lowering.
#
# ASSERTED, not recorded, and that changed with the floor. While 4.9.3 was below the floor this was
# an exploratory measurement whose answer nobody knew, and recording was right. Now it is a
# supported configuration, and a supported configuration that stops working should turn the suite
# red.
if [ "${CS193V_INSTALL_NESTED:-}" != 1 ]; then
    skip "oldest-supported:the-prerequisites" "set CS193V_INSTALL_NESTED=1 -- seconds; the build itself is a second gate"
else
fixture_build podman-old-nested || exit 1
osp="$(nest_probe podman-old-nested)"
record "oldest-supported:podman-inside" "$(nest_get "$osp" PODMAN_VERSION)"
record "oldest-supported:store"         "$(nest_get "$osp" STORE)"
assert_match "oldest-supported:the-probe-ran-inside-the-2204-fixture" '^podman-old-nested-fixture-[0-9]+$' \
             "$(nest_get "$osp" FIXTURE_ID)"
# THE VERSION IS THE WHOLE POINT of this fixture, so it is pinned. If Ubuntu ever backports a newer
# podman to 24.04 this fails and says so, rather than quietly testing something else.
assert_says  "oldest-supported:the-podman-inside-is-4.9.3" "4.9.3" "$(nest_get "$osp" PODMAN_VERSION)"
assert_match "oldest-supported:4.9.3-creates-a-nested-userns" '^user:\[[0-9]+\]$' \
             "$(nest_get "$osp" INNER_USERNS)"
# The packaging claim, on Ubuntu's shadow as well as Debian's: setuid newuidmap does not survive
# nesting, so SYS_ADMIN is required here and its absence fails in one specific way.
ospn="$(nest_probe_nocap podman-old-nested)"
assert_says_not "oldest-supported:without-SYS_ADMIN-there-is-no-namespace" 'user:[' \
                "$(nest_get "$ospn" INNER_USERNS)"
assert_says "oldest-supported:newuidmap-is-what-fails" 'newuidmap' "$(nest_get "$ospn" INNER_USERNS)"

if [ "${CS193V_MINPODMAN_BUILD:-}" != 1 ]; then
    skip "oldest-supported:the-build" "set CS193V_MINPODMAN_BUILD=1 -- a real 25-step build on podman 4.9.3, ~6GB and several minutes"
else
osp_free="$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')"
record "oldest-supported:free-disk-gb-before" "${osp_free:-unknown}"
if [ -z "$osp_free" ] || [ "$osp_free" -lt 15 ]; then
    skip "oldest-supported:the-build" "only ${osp_free:-?}GB free; this build wants ~8GB and a margin"
else
osp_imgs="$(podman images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | LC_ALL=C sort | cksum)"
# THE REAL INSTALLER, unpatched, which is what makes this a regression check rather than a
# measurement -- and is itself an assertion that 4.9.3 is admitted by the shipped floors.
out="$(nest_build "" "" podman-old-nested)"
assert_says "oldest-supported:the-real-installer-is-what-ran" "/work/installer.sh" \
            "$(sb_section "$out" INSTALLER-USED)"
assert_says_not "oldest-supported:no-version-refusal-anywhere" "or newer" "$out"
record "oldest-supported:installer-rc"      "$(printf '%s' "$out" | sed -n 's/.*===INSTALLER-RC=\([0-9]*\)===.*/\1/p' | head -1)"
record "oldest-supported:inner-store-bytes" "$(sb_section "$out" INNER-STORE-BYTES)"
assert_says "oldest-supported:4.9.3-finished-the-install"  "Setup finished"       "$out"
assert_says "oldest-supported:4.9.3-exited-0"             "===INSTALLER-RC=0===" "$out"
assert_eq   "oldest-supported:4.9.3-built-the-course-image" "yes" "$(sb_section "$out" IMAGE-EXISTS)"
# PAIRED WITH THE IMAGE, because doctor returns ok on an installation with no image at all --
# measured, on a run where nothing had been built and doctor said ok anyway.
assert_eq   "oldest-supported:doctor-runs-on-4.9.3"        "ok"  "$(sb_section "$out" DOCTOR)"
osp_store="$(sb_section "$out" INNER-STORE-BYTES)"
if [ -n "$osp_store" ] && [ "$osp_store" -gt 1000000000 ]; then pass "oldest-supported:the-inner-store-really-grew"
else fail "oldest-supported:the-inner-store-really-grew" "inner graph root is ${osp_store:-empty} bytes"; fi
record "oldest-supported:build-log-tail" "$(sb_section "$out" BUILD-LOG | tail -6 | tr '\n' '|')"
assert_eq "oldest-supported:host-image-list-untouched" "$osp_imgs" \
          "$(podman images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | LC_ALL=C sort | cksum)"
sandbox_reap
record "oldest-supported:free-disk-gb-after" "$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')"

# ─── and what happens when the two declarations disagree ───────────────────────
# TWO DECLARATIONS, ONE NUMBER, AND NOTHING BEHAVIOURAL CHECKED THAT THEY MATCH.
# MIN_PODMAN_LINUX lives in install-cs193v.sh and again in cs193v, because the installer is
# curl-piped and cannot source the launcher. 25-installer.sh checks the two statically; this is
# what a student SEES when they drift.
#
# sb_work_skew raises the LAUNCHER's floor to 5.7.0 and leaves the installer's at 4.9.0, on a
# machine with 4.9.3. So the installer accepts, and the launcher does not.
#
# THE SHAPE IS THE POINT: survey passes, the course files download, the memory cap is computed, the
# disk is confirmed -- and only then does build_image hand off to a launcher that refuses. Every
# reassuring step first, the refusal last, on a machine the installer just declared fit. A student
# would read that as the install breaking at the very end.
#
# CHEAP, because it dies before building anything.
sb_work_skew || { fail "floor-skew:the-skew-could-be-built" "sb_work_skew failed"; exit 1; }
pass "floor-skew:the-skew-could-be-built"
out="$(nest_build "" "" podman-old-nested /work/installer-skew.sh)"
assert_says "floor-skew:the-skewed-copy-is-what-ran" "installer-skew.sh" \
            "$(sb_section "$out" INSTALLER-USED)"
assert_says "floor-skew:the-installer-accepted-4.9.3"   "podman 4.9.3" "$out"
assert_says "floor-skew:it-got-all-the-way-to-the-build" "Building the course container" "$out"
# ...and then the launcher refused, in the launcher's own words (messages.txt err.podman-too-old).
assert_says "floor-skew:but-the-launcher-refuses"  "we need:" "$out"
assert_says "floor-skew:exits-nonzero"             "===INSTALLER-RC=1===" "$out"
assert_eq   "floor-skew:and-nothing-was-built" "no" "$(sb_section "$out" IMAGE-EXISTS)"
sandbox_reap
fi
fi
fi

# ─── SYS_ADMIN is Debian-family packaging, not the price of nesting ────────────
# MEASURED, AND ACTED ON. Every nested base used to be handed --cap-add=SYS_ADMIN with a comment
# saying nesting costs one. It does not: Debian's shadow is compiled without sys/capability.h, so
# newuidmap carries only a setuid bit -- which does not preserve CAP_SETUID inside an unprivileged
# nested user namespace -- while Fedora's shadow-utils ships FILE CAPABILITIES, which do survive.
#
# Visible in one `ls` across the Tier A fixtures, which is what prompted the experiment:
#
#   fedora:43     -rwxr-xr-x  /usr/bin/newuidmap   <- no setuid bit at all
#   debian:13     -rwsr-xr-x  /usr/bin/newuidmap
#   ubuntu:24.04  -rwsr-xr-x  /usr/bin/newuidmap
#
# So MACHINE_SYSADMIN_BASES grants it to the two Debian-family bases and NOT to fedora-nested, and
# these assertions are what keep that split honest. It is no longer a differential in the
# nest_probe_nocap sense -- fedora-nested has no SYS_ADMIN to remove -- and that is the point: its
# DEFAULT flag set is the claim, and the Ubuntu control is what makes the contrast a measurement
# rather than an assumption.
#
# ONE TRAP THIS RESTS ON: the Fedora base image LOSES those capabilities (RHBZ 1995337), so a stock
# fedora:43 has neither a setuid bit nor caps -- strictly worse than Debian.
# Containerfile.fedora-nested restores them with `rpm --setcaps shadow-utils`, exactly as
# quay.io/podman/stable does, and asserts at BUILD time that they are present. Without that line
# this case would grant no capability to a base that could not nest, and fail in a way that looks
# like the harness rather than the image.
if [ "${CS193V_INSTALL_NESTED:-}" != 1 ]; then
    skip "fedora-caps:the-packaging-claim" "set CS193V_INSTALL_NESTED=1 -- seconds"
else
fixture_build fedora-nested || exit 1

# THE FLAG SET ITSELF, before anything runs on it. This is the assertion that the narrowing
# actually took: machine_flags must hand this base the devices and the unmask and no capability.
machine_flags '' linux no fedora-nested
fcaps="$(printf '%s ' ${MACHINE_FLAGS[@]+"${MACHINE_FLAGS[@]}"})"
record "fedora-caps:the-flags-fedora-gets" "$fcaps"
assert_says_not "fedora-caps:fedora-is-given-no-capability" "cap-add" "$fcaps"
assert_says     "fedora-caps:but-still-gets-dev-fuse"       "/dev/fuse" "$fcaps"
machine_flags '' linux no podman-old-nested
ucaps="$(printf '%s ' ${MACHINE_FLAGS[@]+"${MACHINE_FLAGS[@]}"})"
record "fedora-caps:the-flags-ubuntu-gets" "$ucaps"
assert_says "fedora-caps:ubuntu-still-is-given-one" "cap-add" "$ucaps"

# AND IT REALLY NESTS ON THAT REDUCED SET, which is the whole claim.
fnp="$(nest_probe fedora-nested)"
record "fedora-caps:podman-inside" "$(nest_get "$fnp" PODMAN_VERSION)"
assert_match "fedora-caps:the-probe-ran-inside-the-fedora-fixture" '^fedora-nested-fixture-[0-9]+$' \
             "$(nest_get "$fnp" FIXTURE_ID)"
assert_match "fedora-caps:fedora-nests-with-no-SYS_ADMIN-at-all" '^user:\[[0-9]+\]$' \
             "$(nest_get "$fnp" INNER_USERNS)"
assert_ne "fedora-caps:that-userns-is-not-the-host-s" "$(readlink /proc/self/ns/user)" \
          "$(nest_get "$fnp" INNER_USERNS)"

# THE CONTROL, and without it the line above is just a fact about Fedora rather than a comparison.
# podman-old-nested is Ubuntu 24.04 with a setuid newuidmap; denied the same capability, it cannot
# create a namespace at all, and says exactly why.
uctl="$(nest_probe_nocap podman-old-nested)"
record "fedora-caps:ubuntu-control-WITHOUT-sys-admin" "$(nest_get "$uctl" INNER_USERNS)"
assert_says_not "fedora-caps:ubuntu-cannot-do-what-fedora-just-did" 'user:[' \
                "$(nest_get "$uctl" INNER_USERNS)"
assert_says "fedora-caps:and-newuidmap-is-what-fails-there" 'newuidmap' \
            "$(nest_get "$uctl" INNER_USERNS)"
fi
