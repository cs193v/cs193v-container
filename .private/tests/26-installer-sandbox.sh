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
# Read by sandbox_cleanup in lib/sandbox.sh:1314 (`for c in $SB_CASES`), which the trap below
# calls -- so the sweep and this list are the same fact, named once.
# shellcheck disable=SC2034
SB_CASES="apt wsl-provision cannot-answer subuid-no subuid-yes sudo-absent sudo-deny sudo-password wsl-absent wsl-absent-password wsl-noboot wsl-boot wsl-systemd podman-old debian fedora arch nested"
trap 'sandbox_cleanup; rm -rf "$SB_TMP"' EXIT
record "sandbox:leftover-dirs-from-an-earlier-run" "$(shim_sweep_stale)"
record "sandbox:leftover-containers-from-an-earlier-run" "$(sandbox_sweep_stale)"

# ─── the survey's first line, checked against the machine rather than a constant ───────────
# install-cs193v.sh:492 prints `ok "$PLAT on $(uname -m)"`, so the property worth asserting is
# that BOTH HALVES ARE TRUE -- not that this fixture's base image happens to be amd64. Three
# cases used to hardcode x86_64, and that made them pass or fail on a fact about their PIN
# rather than about the installer: sb-fed passed because fedora was pinned to a
# per-architecture amd64 leg, while sb-wsl failed because `machine` was pinned to a manifest
# list and so built native arm64. Both pins now name manifest lists, so every fixture is
# native and the expected arch is whatever the fixture reports.
#
# THE EMPTY-ARCH GUARD IS THE WHOLE REASON THIS IS A FUNCTION. Without it, a missing or renamed
# ===ARCH=== section would reduce the needle to "wsl on ", which every WSL transcript already
# contains -- so the assertion would pass forever having measured nothing. That is the shape
# assert_system_diff guards against with the-diff-was-really-read, for the same reason.
#
# ─── AND THE INPUT, NOT ONLY THE VERDICT (#152) ────────────────────────────────
#
# THE HALF THAT WAS MISSING, and it is the same vacuity one paragraph up wearing a different
# costume. platform() is `grep -qi microsoft /proc/version`, and a container shares the host's
# kernel -- so before #152 the linux arm read the HOST's /proc/version and the platform axis meant
# whatever the developer's machine meant. On a WSL host that is red in one direction and VACUOUS in
# the other: sb-fed and sb-arch detected as wsl, while sb-wsl passed whether or not its bind mount
# worked, because the host's own string already says microsoft.
#
# SO THE INPUT IS ASSERTED FIRST, BY EQUALITY. Against the file sb_work_init wrote, so the string
# lives in one place; and by equality rather than "does it say microsoft", because that weaker
# check is precisely the one a WSL host satisfies for free. The fixture's builder field
# (cs193v-fixture@sandbox) is one no kernel can carry, so this passes only when podman really
# bound the file -- which restores the ability to fail that the wsl case's guard is here for.
assert_survey_platform() {            # assert_survey_platform NAME PLAT TRANSCRIPT
    local a; a="$(sb_section "$3" ARCH)"
    if [ -n "$a" ]; then pass "${1%%:*}:the-arch-was-reported"
    else fail "${1%%:*}:the-arch-was-reported" "no ===ARCH=== section, so '$2 on ...' would be vacuous"; return; fi
    assert_eq "${1%%:*}:the-fixture-supplied-its-own-proc-version" \
              "$(cat "$SB_WORK/proc-version.$2" 2>/dev/null)" "$(sb_section "$3" PROC-VERSION)"
    assert_says "$1" "$2 on $a" "$3"
}

# `|| exit 1`, LIKE fixture_build BELOW IT. sb_work_init can now refuse -- it checks that the
# /proc/version strings it just wrote are not this host's -- and a refusal that only set a status
# nobody read would leave every case below running against a half-built $SB_WORK.
sb_work_init || exit 1
fixture_build machine || exit 1

# ─── a ceiling that fires announces itself, on the real pipeline (#130) ────────
#
# WHAT THIS COSTS AND WHY IT IS NOT BEHIND A GATE. Every other case that drives nest_build is
# gated behind CS193V_INSTALL_NESTED_BUILD because it assembles the 25-step course image -- 6.2 GB
# of inner store and several minutes. This one substitutes an installer that prints and then
# sleeps, so it costs a container start and the ceiling it is asserting about. That is the whole
# point: the machinery that explains a killed build was covered by nothing at all, and a check
# which only runs when somebody opts into a six-minute build is a check that runs when the build
# is already the thing going wrong.
#
# THE CEILING IS LOWERED, NOT THE ONLY THING TESTED. 14-test-harness.sh drives sb_ceiling_note's
# arms directly, because which rc a ceiling produces is the HOST's answer and a real run here can
# only ever show one of them. What this case adds is the half a unit test cannot reach: that the
# real pipeline's $? really is the ceiling's, through the pty, the printf on stdin and the
# TTY-warning filter.
#
# ITS OWN RESULTS FILE AND ITS OWN STDERR. nest_build's whole job here is to FAIL, so the failure
# has to land somewhere this suite is not counting -- and its screen line has to be caught rather
# than printed, or a green run shows a red FAIL that appears in no summary.
sb_work_hang || { fail "ceiling-live:the-hanging-installer-could-be-built" "sb_work_hang failed"; exit 1; }
ceil_tsv="$SB_TMP/ceiling.tsv"; : > "$ceil_tsv"
ceil_t0=$SECONDS
ceil_out="$(CS193V_RESULTS="$ceil_tsv" CS193V_NEST_CAP=10 \
            nest_build ceiling-live "" "7" machine /work/installer-hang.sh 2>"$SB_TMP/ceiling.err")"
record "ceiling-live:seconds" "$((SECONDS - ceil_t0))"
# THE POSITIVE TOKEN FIRST, and it is load-bearing rather than decorative. nest-run.sh arranges
# the machine before it runs the installer, so a cap below what `sandbox arrange` costs would kill
# the run before the installer existed -- and every assertion below would still pass, about a
# ceiling that fired for the wrong reason. This is the installer's own first line.
assert_says "ceiling-live:the-run-really-got-as-far-as-the-installer" \
            "pretending to build the course image" "$ceil_out"
# THE KEYSTROKE ARGUMENT, WHICH MOVED. It is argument 3 now that the label is argument 1, and
# getting that wrong is silent: the installer is fed nothing, menu()'s `read` waits on a pty that
# never delivers EOF, and the run burns its ceiling looking precisely like the hang this case is
# about. The four gated call sites all pass keys and none of them can be run without a 6 GB build,
# so this is where that argument is checked.
assert_says "ceiling-live:the-keystrokes-reached-the-installer" "keystroke=[7]" "$ceil_out"
# THE DEFECT ITSELF: $? was never read, so this was the previous sandbox_run's status or nothing.
assert_eq   "ceiling-live:the-real-pipeline-reports-its-real-rc" "255" "$(sandbox_rc)"
assert_says "ceiling-live:podman-killed-it-and-the-transcript-says-so" \
            "===SANDBOX-TIMEOUT=== podman killed the container at its 10s ceiling" "$ceil_out"
# APPENDED to what the run managed to print, not written over it -- asserted here as well as in
# the unit cases, because this is the transcript that came through a real pty.
assert_says "ceiling-live:the-marker-did-not-replace-the-transcript" \
            "===INSTALLER-USED=== /work/installer-hang.sh" "$ceil_out"
# THE HALF #130 IS ACTUALLY ABOUT: "nothing in the results says the container was killed". A
# marker in a transcript reaches whoever reads the transcript to the end; this reaches the summary.
assert_eq "ceiling-live:the-ceiling-is-a-named-result" \
          "FAIL ceiling-live:the-run-stayed-inside-its-ceiling" \
          "$(awk -F'\t' '{ print $1, $3 }' "$ceil_tsv" | do_tr '\n' ' ' | sed 's/ *$//')"
# THE ESCAPES COME OFF FIRST (#179), and this is the one assertion in the tree that still needed it.
# This suite is TIER: install, so run_suite hands it fd 3 on the real terminal (run-tests.sh:379-382)
# -- `[ -t 1 ]` is true, lib/assert.sh:28 turns colour on, and fail() writes `FAIL` + A_OFF + two
# spaces, so the two spaces this needle wants are on the far side of an escape. That made this line
# GREEN piped and RED on a terminal, which is the worst way round: every redirected run agrees it is
# fine and only somebody watching sees it break. strip_ansi is what nest_build already does to the
# transcript (lib/sandbox.sh:1088); the stderr half of the very same call never got it.
assert_contains "ceiling-live:and-it-is-said-on-the-screen-too" \
                "FAIL  ceiling-live:the-run-stayed-inside-its-ceiling" \
                "$(strip_ansi < "$SB_TMP/ceiling.err")"
# NOTHING LEFT RUNNING. conmon stops the container at its own ceiling, so the 255 arm has nothing
# to remove and deliberately removes nothing -- but "stopped" is the claim, and an audit of the
# ceiling that did not check it would miss the leak the 137 arm exists for.
# PAIRED, because "no container is running under that name" is exactly what a case that never
# started one would report -- the vacuous pass lib/assert.sh hard-fails on elsewhere. The first
# half says a container really was created; the second says it is not still going.
assert_eq "ceiling-live:there-really-was-a-container" "$(sb_name)" \
          "$(podman ps -a --filter "name=$(sb_name)" --format '{{.Names}}')"
assert_eq "ceiling-live:and-it-is-not-still-running" "" \
          "$(podman ps --filter "name=$(sb_name)" --format '{{.Names}}')"
sandbox_reap

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
record "apt:transcript-bytes" "$(printf '%s' "$out" | wc -c | do_tr -d ' ')"
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
arch="$(sb_section "$out" PODMAN-WORKS)"
assert_match "sb-apt:the-podman-apt-installed-really-works" '^(arm64|amd64|aarch64|x86_64)$' "$arch"

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
# namespace, and the run stopped at check_podman. That was recorded as an environmental
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
assert_says "sb-noans:the-installer-says-so" "Podman is installed but is not answering" "$out"
assert_says "sb-noans:exits-nonzero"         "===INSTALLER-RC=1===" "$out"
assert_says_not "sb-noans:does-not-claim-success" "Setup finished" "$out"
# ...and it got far enough to have done the install first, which is what tells this apart from
# a run that failed before reaching the question.
assert_says "sb-noans:it-had-already-installed-podman" "Installing podman uidmap" "$out"
sandbox_reap

# ─── curl absent, which is a stock Ubuntu Desktop ──────────────────────────────
# THE PLATFORM DIFFERENCE NO TEST COULD SEE, and the fixtures were why: both of them installed
# curl, so the machine every case ran on was not the machine a student has. curl is NOT in the
# Ubuntu desktop image -- the 26.04 and 24.04 manifests carry wget and libcurl4t64 and no curl --
# while the WSL image and macOS ship it.
#
# IT IS THE FIRST QUESTION NOW, not a late one. Before #221 this machine got as far as consent,
# apt and usermod and then failed in fetch_files with "this is usually a network problem". After
# the split the download happens before any course code can run, so the same machine is decided
# in the bootstrap's first ten lines -- and the wget arm is what decides it in the student's
# favour rather than refusing a supported platform.
#
# THROUGH A REAL LISTENER, because wget has no file:// scheme -- measured: GNU wget 1.21.4 exits
# 1 on one and writes nothing. So this case, alone among the fixtures, fetches over loopback from
# the perl origin run.sh starts. ===HTTP-ORIGIN=== is asserted before anything else, because an
# origin that never bound makes the download fail and the installer refuse, which looks like
# half a dozen other refusals.
sb_machine no-prereqs=curl
out="$(sandbox_run wget '2' -e CS193V_DIR=/home/student/cs193v \
                            -e SB_INSTALLER=/work/installer-http.sh -e SB_HTTP_ORIGIN=1)"
assert_says "sb-wget:the-machine-was-really-arranged" "prereqs=curl" "$(sb_section "$out" ARRANGED)"
assert_eq   "sb-wget:the-origin-was-listening" "listening" "$(sb_section "$out" HTTP-ORIGIN)"
# FLATTENED, NOT THROUGH sb_section, and the reason generalises to any marker printed before the
# installer runs. The keys this case feeds are ECHOED by the pty, and the echo lands on whichever
# early line is being written when it flushes -- measured here as a literal
# `2===INSTALLER-USED===` on line 2. sb_section anchors on /^===NAME===$/, so a marker wearing an
# echoed keystroke matches nothing and the section reads EMPTY rather than wrong, which is the
# worse failure: an assert_says on an empty haystack simply fails, and an assert_says_not would
# have passed. The tail-block markers are far past the echo and are safe; this one is not, so it
# is read the way sb-ceiling reads the same marker -- as marker-and-value in one flattened string.
assert_says "sb-wget:the-http-copy-is-what-ran" \
            "===INSTALLER-USED=== /work/installer-http.sh" "$out"
# THE ARM ITSELF. curl is gone and the tree still arrived, which no curl-only bootstrap could
# manage -- it would have refused before survey. `dir-only` would be the interesting failure.
assert_eq "sb-wget:the-course-files-arrived" "launcher-is-executable" "$(sb_section "$out" COURSE-DIR)"
# AND THEN THE INSTALLER PROPER ASKS FOR curl ANYWAY, which is not redundancy: the bootstrap
# needed A downloader and found one, while install_podman's macOS arm and the launcher both want
# curl specifically. This is the consent item that was unreachable for as long as a curl-less
# machine could not get past the bootstrap at all.
assert_says "sb-wget:asks-for-one-thing"         "permission for 1 thing" "$out"
assert_says "sb-wget:names-curl"                 "Install curl" "$out"
assert_says "sb-wget:says-what-it-is-installing" "Installing curl" "$out"
added="$(sb_section "$out" DPKG-ADDED)"
assert_says "sb-wget:installed-curl" "curl" "$added"
# THE NEGATIVE IS HALF THE CLAIM. Without it this case could be passing on a machine that lacked
# podman too, i.e. a second copy of the apt case wearing a different name.
assert_says_not "sb-wget:did-not-reinstall-podman" "podman" "$added"
assert_eq "sb-wget:left-no-temp-tree" "absent" "$(sb_section "$out" BOOT-TMP)"
# WHERE THIS RUN STOPS, recorded not asserted, for the apt case's reason: the download works, so
# build_image hands off to the launcher, which wants the network this case has not got.
record "sb-wget:installer-rc" "$(printf '%s' "$out" | sed -n 's/.*===INSTALLER-RC=\([0-9]*\)===.*/\1/p' | head -1)"
sandbox_reap

# ─── and the machine with neither, which is a minimal Debian ───────────────────
# THE ONLY CASE ANYWHERE THAT REACHES find_download_tool's FAILURE ARM. Both tools are taken
# away, so the bootstrap cannot fetch anything and has to say so -- before survey, before
# consent, and before anything is touched, because there is nothing yet to touch it with.
#
# IT IS A REAL MACHINE, not a synthetic one: debian:13 ships no curl, no wget and no
# ca-certificates. Rare in this course's audience, which is why the answer is a clear sentence
# rather than an install path.
sb_machine no-prereqs=curl,wget
out="$(sandbox_run nodl '2' -e CS193V_DIR=/home/student/cs193v)"
assert_says "sb-nodl:the-machine-was-really-arranged" "prereqs=curl,wget" "$(sb_section "$out" ARRANGED)"
# ANCHORED ON THE SENTENCE, not on the word "curl" or "wget": ===ARRANGED=== says
# `prereqs=curl,wget`, so either bare needle passes on this case's own arrangement echo with no
# refusal in the transcript at all. Checked, and it did, for one commit.
assert_says "sb-nodl:refuses-for-want-of-a-downloader" "cannot find either" "$out"
assert_says "sb-nodl:names-both-tools"    "curl or wget" "$out"
assert_says "sb-nodl:names-the-apt-command" "apt install curl ca-certificates" "$out"
assert_says "sb-nodl:names-the-dnf-command" "dnf install curl" "$out"
assert_says "sb-nodl:exits-nonzero"         "===INSTALLER-RC=1===" "$out"
assert_says_not "sb-nodl:does-not-claim-success" "Setup finished" "$out"
# IT REFUSES BEFORE IT ASKS FOR ANYTHING, which is the property the ordering is for: nothing is
# installed and no permission is sought, because there is nothing to ask on behalf of yet.
assert_eq "sb-nodl:installed-nothing" "" "$(sb_section "$out" DPKG-ADDED)"
assert_says_not "sb-nodl:asks-no-permission" "needs your permission" "$out"
assert_eq "sb-nodl:no-course-tree"    "absent" "$(sb_section "$out" COURSE-DIR)"
assert_eq "sb-nodl:left-no-temp-tree" "absent" "$(sb_section "$out" BOOT-TMP)"
sandbox_reap

# ─── podman installed, its setuid helpers not ──────────────────────────────────
# THE THIRD CAUSE OF THE OBSERVABLE THE CASE ABOVE MEASURES, and the only one of the three the
# installer can do anything about. lib/sandbox.sh names them where MACHINE_CAP_NAMES is defined:
# a restrictive apparmor profile, a nosuid mount, or a missing uidmap all hand a student a podman
# that cannot create a user namespace, and the run dead-ends at check_podman.
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
# answers its own arch. SB_PROBE_PODMAN earns its store for the apt case's reason -- the probe IS
# the assertion -- and this case takes no path-level audit for that store to disturb.
assert_match "sb-uidmap:podman-answers-once-the-helpers-are-back" '^(arm64|amd64|aarch64|x86_64)$' \
             "$(sb_section "$out" PODMAN-WORKS)"
record "sb-uidmap:installer-rc" "$(printf '%s' "$out" | sed -n 's/.*===INSTALLER-RC=\([0-9]*\)===.*/\1/p' | head -1)"
sandbox_reap

# ─── setup_subuid, on an account that predates /etc/subuid ─────────────────────
# THE ONE BRANCH THE FIXTURES COULD NOT REACH BEFORE. Every base here ships a subuid range --
# `useradd` has populated one since shadow 4.11.1-3, which is what the Arch fixture disproved the
# hard way (.private/README.md) -- so an EMPTY range is a property of an account that predates the
# file rather than of any distro. `--no-prereqs=subuid` is the knob for exactly that state, and
# until now nothing drove it.
#
# WHY THESE MOVED HERE FROM 25-installer.sh. They were written against a synthetic root in the
# shim tier, which works on Linux and cannot work on a Mac: platform() reads the real `uname -s`,
# so the installer takes its macOS arm and DO_SUBUID is never set. Eleven assertions therefore
# measured nothing on half the machines this project is developed on. Here the arm under test is
# genuinely Linux and nothing is faked.
#
# AND IT IS A STRONGER TEST, not merely a portable one. The shim could only assert the COMMAND
# STRING a fake sudo recorded. This fixture gives student real passwordless sudo
# (Containerfile.machine:87), so `usermod` really runs as root and the resulting /etc/subuid is
# readable -- the range itself becomes assertable for the first time.
#
# WHERE IT STOPS, and why that is correct rather than a gap: setup_subuid writes 200000-265535
# (installer:653), which is entirely OUTSIDE this outer container's 1..65536 userns window, so
# podman cannot work here afterwards while it would on a student's machine. lib/sandbox-guest.sh
# states that outright. So no case below claims the install SUCCEEDED -- they claim the range was
# asked for and written, which is a different thing and the thing these tests were always about.
fixture_build machine || exit 1

# (1) CONSENT REFUSED. Something has to NEED consent or there is no prompt to test, and an empty
# subuid range is the one need that does not require taking podman away too.
#
# `1` IS SENT, RATHER THAN RELYING ON THE NON-TTY DEFAULT, and the difference is worth stating
# because the shim-tier original did the opposite. ask_consent calls
# `menu 0 "Stop, do not change anything" "Go ahead"`, so with no tty menu() picks index 0 and
# declines -- which is what 25-installer.sh asserts. That cannot be reproduced here: sandbox_run
# uses `podman run -it`, and measured, an EMPTY key string makes menu() block until the
# container hits its 60s ceiling (===SANDBOX-TIMEOUT===) rather than reading EOF. So this case
# tests what DECLINING DOES, and the safe-default-without-a-tty property stays in the shim tier
# where it belongs -- it is a property of menu(), not of the Linux arm.
sb_machine no-prereqs=subuid
out="$(sandbox_run subuid-no '1' -e CS193V_DIR=/home/student/cs193v)"
record "sb-consent:the-range-it-started-with" "$(sb_section "$out" ETC-SUBUID)"
assert_says "sb-consent:names-what-it-wants" "subuid range" "$out"
assert_says "sb-consent:explains-why"        "needs your password" "$out"
assert_says "sb-consent:declining-says-nothing-changed" "Nothing was changed" "$out"
assert_says "sb-consent:offers-a-way-forward" "contact course staff" "$out"
# A refusal must leave no course files on the machine. IT NO LONGER SKIPS THE DOWNLOAD, and the
# assertion that used to say so is retired rather than reworded, because it asserted the opposite
# of the design (#221): the bootstrap fetches the tree BEFORE this script exists to ask anything,
# which is the entire reason the installer has one copy of box(), die() and menu() instead of two.
# So the transcript now DOES say "Getting the course files" on a run that changes nothing.
#
# WHAT SURVIVES IS THE PROPERTY THAT WAS ALWAYS THE POINT -- nothing of the course is left on a
# machine whose owner said no -- and it is now two claims rather than one, because there are two
# places files can be: the student's tree, and the bootstrap's temp tree. The second is new with
# the split and is the one that was leaking.
assert_eq   "sb-consent:declining-creates-no-directory" "absent" "$(sb_section "$out" COURSE-DIR)"
assert_eq   "sb-consent:declining-leaves-no-temp-tree"  "absent" "$(sb_section "$out" BOOT-TMP)"
sandbox_reap

# (2) CONSENT GIVEN, and the range really written. `2` is the accept key, the same one the wsl
# cases above use.
sb_machine no-prereqs=subuid
out="$(sandbox_run subuid-yes '2' -e CS193V_DIR=/home/student/cs193v)"
assert_says "sb-subuid:step-announced"  "Setting up your account's ID range" "$out"
assert_says "sb-subuid:reports-success" "subuid range added for student" "$out"
# THE FILE, not the announcement -- this is what the shim tier could never check.
assert_eq   "sb-subuid:the-range-really-landed" "student:200000:65536" "$(sb_section "$out" ETC-SUBUID)"
assert_eq   "sb-subuid:and-the-matching-subgid" "student:200000:65536" "$(sb_section "$out" ETC-SUBGID)"
record "sb-subuid:installer-rc" "$(printf '%s' "$out" | sed -n 's/.*===INSTALLER-RC=\([0-9]*\)===.*/\1/p' | head -1)"
sandbox_reap


# ─── THE TWO PASSES, IN ONE CONTAINER: the Windows path end to end  (#217) ─────
#
# WHAT THIS CASE IS AND WHY IT HAS TO BE ONE CASE. On Windows the installer runs twice inside a
# brand-new CS193V WSL instance: wsl-provision.sh as root, which creates the student's account
# with a LOCKED password and does every step that needs privilege, and then course-install.sh as
# that student, which must need none. Split across two cases neither half would prove anything --
# the interesting claim is that the SECOND pass finds nothing left to do, and that is a fact about
# what the first one wrote.
#
# THE FIXTURE IS THE MACHINE AS THE .cmd FINDS IT: base=wsl-fresh is root with no human account at
# all, which is what `wsl --install --no-launch` leaves behind. Nothing else here can stand in for
# it -- every other base starts as a student on a machine that is already theirs.
#
# --user 0, PASSED THROUGH TO podman, because the uid comes from the image and this fixture has no
# USER line for exactly that reason. sandbox_run forwards its trailing arguments verbatim.
#
# fake-podman=yes, and NOT no-prereqs=podman: those two are refused together, and this case does
# not need a real one. What the packages step does when something IS missing is already covered by
# sb-apt and sb-uidmap, through the same root_step_packages this pass calls -- one function, two
# arms. What is only true here is the account, the wsl.conf stanza and the second pass.
fixture_build wsl-fresh || exit 1
sb_machine base=wsl-fresh platform=wsl fake-podman=yes
out="$(sandbox_run wsl-provision '' --user 0 \
        -e CS193V_PROVISION=1 -e SB_SECOND_PASS=student -e CS193V_DIR=/home/student/cs193v)"

# THE ROOT PASS FIRST, and its own exit code, because everything below is only meaningful if it
# finished. Recorded as well as asserted: a nonzero here is the whole story of the case.
record "sb-prov:root-pass-rc" "$(printf '%s' "$out" | sed -n 's/.*===INSTALLER-RC=\([0-9]*\)===.*/\1/p' | head -1)"
assert_eq "sb-prov:the-root-pass-succeeds" "0" \
          "$(printf '%s' "$out" | sed -n 's/.*===INSTALLER-RC=\([0-9]*\)===.*/\1/p' | head -1)"
assert_says "sb-prov:says-what-it-is-doing" "Preparing this environment" "$out"

# THE ACCOUNT REALLY EXISTS, and it is the only human account in there. Read out of /etc/passwd
# rather than from anything the script printed -- an installer that says it created an account and
# did not is exactly the failure this arm is for.
assert_eq "sb-prov:creates-the-student-account" "student:1000" "$(sb_section "$out" PASSWD)"
assert_says "sb-prov:says-it-created-it" "Created the student account" "$out"

# AND ITS PASSWORD IS LOCKED, which is the property the whole two-pass design rests on: nothing
# ever asks a student for a Linux password because there is none to ask for.
assert_contains "sb-prov:the-account-has-no-password" "student:locked" "$(sb_section "$out" SHADOW)"

# /etc/wsl.conf GAINS THE [user] STANZA AND KEEPS THE [boot] ONE. Asserted as the file's whole
# contents rather than as a grep, because the failure mode of a step that acts unconditionally is
# a SECOND systemd=true line -- measured against the real image, which already ships it -- and a
# grep for the setting passes happily on a file with two of them.
assert_eq "sb-prov:records-the-default-user" "[boot]
systemd=true

[user]
default=student" "$(sb_section "$out" WSL-CONF)"

# THE FIRST-RUN QUESTIONS ARE OFF: the configuration Ubuntu wires its OOBE up through has been
# moved aside, and moved rather than emptied -- an emptied one would still be there.
assert_eq "sb-prov:switches-the-first-run-setup-off" "/etc/wsl-distribution.conf.cs193v" \
          "$(sb_section "$out" OOBE-CONF)"
assert_says "sb-prov:says-the-questions-are-off" "first-run questions are switched off" "$out"
# LINGERING IS SKIPPED HERE, AND THE SKIP IS THE ASSERTION. `wsl -e` creates no login session, so
# the student's systemd user manager never starts and podman falls back to cgroupfs -- which
# killed a real container build at step 3 of 25 before the root pass learned to enable lingering
# (wsl-provision.sh carries the measurement). A container is not a WSL instance and runs no
# systemd, so the step reports that rather than pretending to have done something; the enable arm
# is a by-hand check in VERIFICATION.md §1.8, which is where a claim about systemd belongs.
assert_says "sb-prov:says-why-lingering-is-moot-here" "does not run systemd" "$out"

# THE SUBUID RANGE, which useradd writes for a new account on Debian-family shadow (4.11.1-3+) --
# so the step SKIPS, and the range is there anyway. The claim is the range, not who wrote it: what
# podman needs is a block of ids, and what must not happen is two blocks.
assert_eq "sb-prov:the-account-has-one-subuid-range" "1" \
          "$(sb_section "$out" ETC-SUBUID | grep -c '^student:')"
assert_eq "sb-prov:and-one-subgid-range" "1" \
          "$(sb_section "$out" ETC-SUBGID | grep -c '^student:')"

# ─── and now the pass a student watches, in the environment the first one made ─
#
# NOTHING LEFT TO CHANGE is the assertion. survey() asks the same questions it asks on a Mac, and
# on a provisioned instance every one of them answers yes -- so NEEDS is empty, the consent menu
# never appears, and no privileged call is reached. That is what makes a locked password safe.
assert_eq "sb-prov:the-student-pass-succeeds" "0" \
          "$(printf '%s' "$out" | sed -n 's/.*===SECOND-PASS-RC=\([0-9]*\)===.*/\1/p' | head -1)"
assert_says "sb-prov:the-student-pass-ran-as-the-student" "===SECOND-PASS-AS=student===" "$out"
assert_says "sb-prov:has-nothing-to-change" "Nothing on your computer needs to change" "$out"
assert_says "sb-prov:finds-the-prereqs-done" "podman, uidmap, ssh and curl" "$out"
assert_says "sb-prov:finds-the-subuid-range-done" "your account has the ID range podman needs" "$out"
assert_says "sb-prov:finds-systemd-already-on" "systemd is enabled in this WSL environment" "$out"
assert_says "sb-prov:finishes"  "Setup finished" "$out"

# AND IT ASKED FOR NO PASSWORD. There is no sudo recorder in this tier -- sudo here is REAL, which
# is what makes the root pass's effects real -- so the claim is made the way the installer itself
# makes it: every privileged step reported as already satisfied, and a transcript with no password
# prompt in it. A pass that reached sudo on this account would print one and then fail.
assert_says_not "sb-prov:never-asks-for-a-password" "password for" "$out"
assert_says_not "sb-prov:asks-no-consent-question" "needs your permission" "$out"
sandbox_reap

# ─── the password: what happens when the machine cannot supply one  (#226) ─────
# THE FIXTURES ALL SHIP `student ALL=(ALL) NOPASSWD:ALL`, so until sudo= existed every case in
# this file watched an installer on a machine whose sudo never asks for anything. These four ask
# for the other three policies, and they are the only cases here that can reach the survey's
# sudo arms or ask_password's prompt at all.
#
# no-prereqs=subuid IS THE CHEAPEST WAY IN. Something has to need root or the gate returns
# early, and the subuid range is the one root-requiring step that needs no package manager --
# so fake-podman=yes is honest here and takes the ceiling from 300 s to 60 s. What the case is
# about is sudo, not podman.

# ── no sudo on the machine: refused at the survey, before consent ──
sb_machine no-prereqs=subuid fake-podman=yes sudo=absent
out="$(sandbox_run sudo-absent '' -e CS193V_DIR=/home/student/cs193v)"
# THE GATE. Every assertion below is about a machine with no sudo, so this says it really is
# one -- sudo_state ASKS the machine rather than echoing back what was requested.
assert_eq "sb-sudo-absent:the-machine-really-has-no-sudo" "absent" "$(sb_section "$out" SUDO)"
assert_says_key "sb-sudo-absent:says-why" err.no-sudo "$out" \
                "$PRIVATE/course-install-messages.txt"
assert_says "sb-sudo-absent:names-what-wanted-root" "- Give your account" "$out"
assert_says "sb-sudo-absent:points-at-course-staff" "contact course staff" "$out"
assert_says "sb-sudo-absent:exits-nonzero" "===INSTALLER-RC=1===" "$out"
assert_says_not "sb-sudo-absent:does-not-claim-success" "Setup finished" "$out"
# REFUSED BEFORE THE BARGAIN, which is what putting this in survey buys: a machine that cannot
# produce the password is never offered a deal it could not keep.
assert_says_not "sb-sudo-absent:asks-no-permission" "needs your permission" "$out"
assert_eq "sb-sudo-absent:the-range-is-untouched" "" "$(sb_section "$out" ETC-SUBUID)"
assert_eq "sb-sudo-absent:no-course-tree" "absent" "$(sb_section "$out" COURSE-DIR)"
assert_eq "sb-sudo-absent:left-no-temp-tree" "absent" "$(sb_section "$out" BOOT-TMP)"
sandbox_reap

# ── sudo exists, this account may not use it: refused after consent, before the step ──
# A DIFFERENT TRANSCRIPT FROM absent, above the same outcome, and that is the distinction
# survey deliberately does NOT try to make: `sudo -n true` fails identically for "needs a
# password" and "not allowed", so this one is left to ask_password, which asks and reports.
sb_machine no-prereqs=subuid fake-podman=yes sudo=deny
out="$(sandbox_run sudo-deny '2' -e CS193V_DIR=/home/student/cs193v)"
assert_eq "sb-sudo-deny:the-machine-really-denies-sudo" "deny" "$(sb_section "$out" SUDO)"
assert_says_key "sb-sudo-deny:announced-before-it-is-asked" note.password-why "$out" \
                "$PRIVATE/course-install-messages.txt"
assert_says_key "sb-sudo-deny:says-why-it-failed" err.sudo-refused "$out" \
                "$PRIVATE/course-install-messages.txt"
assert_says "sb-sudo-deny:exits-nonzero" "===INSTALLER-RC=1===" "$out"
assert_says_not "sb-sudo-deny:does-not-claim-success" "Setup finished" "$out"
# THE EFFECT, which is the half no shim can check: usermod never ran, so the range is still
# absent on a real /etc.
assert_eq "sb-sudo-deny:the-range-is-untouched" "" "$(sb_section "$out" ETC-SUBUID)"
assert_says_not "sb-sudo-deny:does-not-claim-the-range" "subuid range added" "$out"
sandbox_reap

# ── a real password prompt, arriving exactly where it was announced ────────────
# THE ONLY CASE ANYWHERE THAT DRIVES A REAL sudo PASSWORD PROMPT. apply_sudo sets the account's
# password and drops NOPASSWD, so sudo behaves the way a student's does -- and what that buys is
# the ORDER, measured rather than reasoned about: the heading and its note come out before the
# prompt, and the prompt happens once rather than once per privileged step. That is the claim
# #226 makes about rule 2 and the claim #223 asks for, and no fake sudo can make it.
#
# THE PASSWORD IS NOT SUPPLIED, AND IT CANNOT BE. sudo flushes the terminal's input queue before
# it reads a password -- TCSAFLUSH when it turns echo off -- which is a deliberate defence
# against exactly what this harness does: keystrokes written ahead of the prompt are DISCARDED.
# Measured: `2hunter2\n` got the menu answered, the prompt printed, and then the container sat
# to its 60 s ceiling with the password already gone. Nothing in this suite can type after a
# prompt it has not read, so this case asserts everything up to and including the prompt, and
# what happens when a correct one is typed is tests/MANUAL.md :: §1.5b.
#
# WHICH MAKES THE REFUSAL THE OTHER HALF OF THE ASSERTION, and a real one: unanswered, sudo
# fails, and the installer must refuse with nothing done rather than carry on.
sb_machine no-prereqs=subuid fake-podman=yes sudo=password:hunter2
out="$(sandbox_run sudo-password '2' -e CS193V_DIR=/home/student/cs193v)"
assert_eq "sb-sudo-password:the-machine-really-wants-a-password" "password:hunter2" \
          "$(sb_section "$out" SUDO)"
assert_says_key "sb-sudo-password:announced" step.password "$out" \
                "$PRIVATE/course-install-messages.txt"
assert_says_key "sb-sudo-password:the-note-explains-why" note.password-why "$out" \
                "$PRIVATE/course-install-messages.txt"
# A REAL PROMPT, FROM A REAL sudo, and exactly one of them. `[sudo] password for student:` is
# sudo's own wording, so its presence proves the prompt was not faked and its count proves the
# prime is one prompt rather than one per call site.
assert_says "sb-sudo-password:really-prompted" "password for student" "$out"
assert_eq   "sb-sudo-password:asked-exactly-once" "1" \
            "$(printf '%s' "$out" | grep -c 'password for student')"
# THE ANNOUNCEMENT CAME FIRST, which is the whole of rule 2 reduced to two words in order.
order="$(printf '%s' "$out" | sed -n 's/.*\(Asking for your password\).*/announced/p; s/.*\(password for student\).*/prompted/p' | tr '\n' ' ')"
assert_eq "sb-sudo-password:announced-before-prompted" "announced prompted " "$order"
# Unanswered, so nothing ran and nothing claimed to.
assert_says_key "sb-sudo-password:refuses-when-unanswered" err.sudo-refused "$out" \
                "$PRIVATE/course-install-messages.txt"
assert_eq   "sb-sudo-password:the-range-is-untouched" "" "$(sb_section "$out" ETC-SUBUID)"
assert_says_not "sb-sudo-password:does-not-claim-the-range" "subuid range added" "$out"
sandbox_reap

# ─── /etc/wsl.conf, all four states, with no Windows anywhere ──────────────────
# platform() decides WSL by `grep -qi microsoft /proc/version` and setup_wslconf's effect is
# two file writes, so one bind mount makes the entire arm executable here. Verified rather
# than assumed: podman will bind a file over /proc/version, and the survey then reports
# "wsl on <arch>" -- the platform word is the claim, and the arch half is checked against what
# the fixture itself reports rather than against a constant. See assert_survey_platform.
#
# THE MOUNT IS NOT WHAT MAKES THIS THE WSL CASE (#152), and reading it that way is how the
# fixture's platform axis came to mean two different things on two different hosts. EVERY case
# here gets a /proc/version bound over it; what makes this one wsl is WHICH string. Before that
# was true the linux arm had no mount and inherited the host's -- so on a WSL host these four
# cases were the only ones whose platform was what they said it was, and even they could not
# prove it, because the host's own string satisfied the check as well as the fixture's.
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
assert_survey_platform "sb-wsl:detected-as-wsl-on-linux" wsl "$out"

# No wsl.conf at all: announced with ok(), not need(), so this one needs no permission -- the
# only host-changing step in the whole installer that does not ask.
assert_says "sb-wsl-absent:needs-no-permission" "Nothing on your computer needs to change" "$out"
assert_says "sb-wsl-absent:says-it-will-create-it" "systemd will be enabled" "$out"
assert_eq   "sb-wsl-absent:writes-both-lines" "[boot]
systemd=true" "$(sb_section "$out" WSL-CONF)"
assert_says "sb-wsl-absent:names-the-restart-command" "wsl --terminate CS193V" "$out"
assert_system_diff wsl /home/student/cs193v wsl-absent
sandbox_reap


# ── the machine that asked for NOTHING and still needs a password  (#226) ──────
# THE GAP THIS ISSUE DID NOT NAME, and the one case in the whole file where "needs consent" and
# "needs root" come apart. Creating /etc/wsl.conf is rule 1's "things it created itself" -- the
# file was not here, so no permission is owed -- and it is `sudo tee` that creates it. So survey
# records an ok() and no need(), NEEDS[] is empty, ask_consent says "Nothing on your computer
# needs to change" and never draws a menu... and before this the next thing the student saw was
# a password prompt with nothing whatsoever having announced it.
#
# WHICH IS WHY needs_root COUNTS ROOT_WANTS[] AND NOT NEEDS[]. Keyed off the consent list, this
# machine would still be silent.
#
# NO KEYS AT ALL: there is no menu on this path. The prompt goes unanswered for the reason
# sb-sudo-password gives at length, so the run must also refuse without writing the file.
sb_machine platform=wsl fake-podman=yes sudo=password:hunter2
out="$(sandbox_run wsl-absent-password '' -e SB_WSLCONF=absent -e CS193V_DIR=/home/student/cs193v)"
assert_eq "sb-wsl-pw:the-machine-really-wants-a-password" "password:hunter2" \
          "$(sb_section "$out" SUDO)"
# RULE 1 IS UNCHANGED, and this is the control for it: nothing was owed a consent question and
# nothing asked for one.
assert_says "sb-wsl-pw:still-asks-no-permission" "Nothing on your computer needs to change" "$out"
assert_says_not "sb-wsl-pw:draws-no-menu" "permission for" "$out"
# AND RULE 2 IS KEPT ANYWAY, which is the whole point of the case.
assert_says_key "sb-wsl-pw:announces-the-password" step.password "$out" \
                "$PRIVATE/course-install-messages.txt"
assert_says     "sb-wsl-pw:really-prompted" "password for student" "$out"
assert_eq "sb-wsl-pw:announced-before-prompted" "announced prompted " \
          "$(printf '%s' "$out" | sed -n 's/.*\(Asking for your password\).*/announced/p; s/.*\(password for student\).*/prompted/p' | tr '\n' ' ')"
# THE EFFECT: unanswered, so the file it was about to create does not exist.
assert_says_key "sb-wsl-pw:refuses-when-unanswered" err.sudo-refused "$out" \
                "$PRIVATE/course-install-messages.txt"
assert_eq "sb-wsl-pw:the-file-was-not-created" "" "$(sb_section "$out" WSL-CONF)"
assert_says_not "sb-wsl-pw:does-not-claim-it-enabled-systemd" "systemd enabled" "$out"
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
# WHERE IT STOPS is check_podman, and that is a property of Tier A rather than of Debian: no
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
# consent and before check_podman, so `launcher-is-executable` can only be true on a run that
# passed the survey.
assert_eq "sb-deb:the-course-files-arrived" "launcher-is-executable" \
          "$(sb_section "$out" COURSE-DIR)"
# ...and then stops for the Tier A reason, not a Debian one. Asserted rather than recorded, because
# a run that got FURTHER would mean this fixture had grown nesting flags nobody declared.
assert_says "sb-deb:stops-where-tier-a-always-stops" "Podman is installed but is not answering" "$out"
record "sb-deb:installer-rc" "$(printf '%s' "$out" | sed -n 's/.*===INSTALLER-RC=\([0-9]*\)===.*/\1/p' | head -1)"
# NO EXACT-SET AUDIT, deliberately, and lib/sandbox.sh gives the reason where SB_PROBE_PODMAN is
# defined: any podman command that touches the runtime creates a store, an events log and lock
# files whose exact set differs between runs. This case reaches `podman info`, so an audit here
# would chase new paths every run. The refusal cases keep theirs, because a refusal touches nothing.
sandbox_reap

# ─── Fedora: reaches its own package manager ───────────────────────────────────
# THE CASE THAT INVERTED. It used to assert the defect #94 describes: install_podman ran
# `sudo apt-get update` on a machine that has never had apt and died with "apt-get update failed",
# a message that reads like a network problem. It now runs dnf, with Fedora's package names.
#
# WHAT IT PROVES, AND WHAT IT CANNOT. Everything up to and including the package manager's own
# network access: the family is detected, the consent screen names Fedora's packages, and dnf
# really runs and really tries Fedora's mirrors. What it cannot prove is that the install SUCCEEDS
# -- sandbox_run always passes --network=none, so there is nothing for dnf to reach. That proof is
# the nested end-to-end case below, which has a network.
#
# ONE CONSENT ITEM, AND IT SAYS "Install podman" WITH NO "(and uidmap)", which is the visible half
# of PKG_UIDMAP being empty on this family. On Debian the setuid helpers are a Recommends of podman
# and have to be named; on Fedora they come with shadow-utils, which also owns usermod and cannot be
# absent. The negative assertions below are what stop that regressing to the Debian spelling.
fixture_build fedora || exit 1
sb_machine base=fedora
out="$(sandbox_run fedora '2' -e CS193V_DIR=/home/student/cs193v)"
assert_survey_platform "sb-fed:detected-as-plain-linux" linux "$out"
assert_says "sb-fed:asks-for-one-thing"       "permission for 1 thing" "$out"
assert_says "sb-fed:names-podman-alone"       "Install podman" "$out"
assert_says_not "sb-fed:does-not-name-the-debian-uidmap" "(and uidmap)" "$out"
assert_says "sb-fed:says-what-it-is-installing" "Installing podman" "$out"
assert_says_not "sb-fed:does-not-ask-for-uidmap" "Installing podman uidmap" "$out"
# NO apt ANYWHERE, which is the whole issue in one assertion.
assert_says_not "sb-fed:never-mentions-apt"   "apt-get" "$out"
# IT REALLY RAN dnf, and the witness is Fedora's own mirror host rather than dnf's progress wording
# -- that wording is dnf5's and could be reworded upstream, while a machine that reached
# mirrors.fedoraproject.org can only have got there through dnf.
assert_says "sb-fed:really-reached-fedoras-repos" "mirrors.fedoraproject.org" "$out"
# ...and stops for the reason Tier A always stops: no network. Asserted rather than recorded,
# because a run that got FURTHER would mean this fixture had grown a network nobody declared.
assert_says "sb-fed:stops-because-there-is-no-network" "Could not install podman" "$out"
assert_says "sb-fed:exits-nonzero"            "===INSTALLER-RC=1===" "$out"
assert_says_not "sb-fed:does-not-claim-success" "Setup finished" "$out"
assert_eq "sb-fed:installed-nothing" "" "$(sb_section "$out" DPKG-ADDED)"
assert_eq "sb-fed:no-course-tree" "absent" "$(sb_section "$out" COURSE-DIR)"
sandbox_reap

# ─── Arch: detected and refused, before anything is asked ──────────────────────
# A DECISION, NOT A DEFECT, which is why this case is here and green rather than in the release
# tier and red. Arch is a rolling release, so pacman resolves a new package against its sync
# database -- and if that database is ahead of what is installed, installing one package upgrades
# some libraries and not others. That is the partial upgrade Arch does not support, and a student
# can already be in that state (the ArchWiki notes a `pacman -Syu` that dies has already completed
# its `-Sy` half). It is guardable, but on a rolling system the guard usually refuses anyway, and
# an Arch user is better served by a conversation. .private/README.md keeps the full analysis.
#
# NO ARCH-SPECIFIC CODE PRODUCES THIS. distro_family() returns `unsupported` for everything that is
# not Debian- or Fedora-family, and say_unsupported_distro names the machine from os-release's
# PRETTY_NAME -- so NixOS, openSUSE, Alpine and Gentoo all get the same box with their own name in
# it, and nothing has to be added for them. This case is that whole class, tested once.
#
# BEFORE CONSENT, deliberately, and that is the strongest assertion here. survey() refuses at
# "Looking at your computer", the same place say_intel_mac refuses an Intel Mac -- so the student is
# never asked permission to install things this script has no way to install.
# ARCH IS x86_64-ONLY, and that is a property of Arch rather than of this suite: the project
# publishes no arm64 image at all (Arch Linux ARM is a separate project), so on an Apple Silicon
# Mac podman spends 185 s pulling and retrying before
#   no image found in image index for architecture "arm64", variant "v8", OS "linux"
#
# SKIPPED RATHER THAN HARD-FAILED, which is the one exception to this suite's rule that a missing
# prerequisite fails. That rule exists so nobody quietly opts out of something they could have
# installed; an instruction set is not that. The whole class this case stands for -- NixOS,
# openSUSE, Alpine, Gentoo, per the comment above -- is still covered on any x86_64 host.
if [ "$(uname -m)" != x86_64 ] && [ "$(uname -m)" != amd64 ]; then
    skip "fixture:arch" "Arch publishes no arm64 image"
else
fixture_build arch || exit 1
sb_machine base=arch
out="$(sandbox_run arch '' -e CS193V_DIR=/home/student/cs193v)"
assert_survey_platform "sb-arch:looked-at-the-computer-first" linux "$out"
assert_says "sb-arch:names-the-distro-from-os-release" "running Arch Linux" "$out"
assert_says "sb-arch:points-at-course-staff"      "contact course staff" "$out"
assert_says "sb-arch:exits-nonzero"               "===INSTALLER-RC=1===" "$out"
assert_says_not "sb-arch:does-not-claim-success"   "Setup finished" "$out"
# IT NEVER ASKED FOR ANYTHING, which is the point of refusing in survey rather than in
# install_podman. A consent screen here would be asking to do something we cannot do.
assert_says_not "sb-arch:asked-no-permission"     "permission for" "$out"
# AND IT NEVER REACHED A PACKAGE MANAGER -- neither the wrong one nor the right one.
assert_says_not "sb-arch:never-mentions-apt"      "apt-get" "$out"
assert_says_not "sb-arch:never-mentions-pacman"   "pacman"  "$out"
assert_eq "sb-arch:installed-nothing" "" "$(sb_section "$out" DPKG-ADDED)"
assert_eq "sb-arch:no-course-tree" "absent" "$(sb_section "$out" COURSE-DIR)"
# A REFUSAL MUST COST NOTHING, in both directions, and this is the assertion that says so -- the
# same exact-set audit the podman-old version refusal takes. It should be the shortest set in the
# fixtures directory: survey refuses before it even probes podman.
assert_system_diff arch /home/student/cs193v
sandbox_reap
fi

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

# ─── and a container really starts in here, which is the question #119 was (#119) ──
# THE ASSERTION THIS TIER WAS MISSING, and its absence is the whole of #119. Everything above is
# answered by `podman unshare` or `podman info`; neither creates a container. So on a host whose
# policy refuses the mounts crun makes, this tier reported nesting as WORKING and the refusal
# surfaced eleven assertions and several minutes later, inside a 25-step build, as eleven
# statements about the installer -- which is not what was wrong.
#
# THE VALUE CARRIES ITS OWN DIAGNOSIS, so nothing here classifies an error message. `ok` or
# crun's verbatim words: on this host, before the flag existed,
#
#     crun: mount `proc` to `proc`: Permission denied: OCI permission denied
#
# which is a sentence about the machine and not about install-cs193v.sh. lib/sandbox.sh records
# how the probe manages a container with no image and no network to pull one with.
assert_eq "nest:a-container-really-starts-inside" "ok" "$(nest_get "$np" INNER_RUN)"
# WHAT THE HOST APPLIED, and WHAT WE ASKED FOR, recorded rather than asserted -- both are
# platform-dependent by nature, which is record()'s stated case. Together they are what a reader
# of a future red assertion needs: the posture the fixture actually ran under, and whether the
# flag set contained what this host needs. Neither claims a cause.
record "nest:lsm-label-applied"   "$(nest_get "$np" PROC_ATTR_CURRENT)"
machine_flags '' host no machine
record "nest:the-flags-this-base-gets" "$(printf '%s ' ${MACHINE_FLAGS[@]+"${MACHINE_FLAGS[@]}"})"

# ─── THE THIRD DEPARTURE, WITH ITS OWN CONTROL (#119) ──────────────────────────
# The same doctrine as the two controls above, on the flag they did not cover: asserting only that
# the privileged run works would leave the requirement untested, and a later podman or policy
# needing less -- or more -- would go unnoticed either way.
#
# SKIPPED WHERE IT CANNOT BE MEASURED, rather than branched. Off SELinux machine_flags passes no
# label flag at all, so removing it changes nothing and the control would be asserting that an
# unchanged machine behaves differently. A named skip says that in the results; a conditional
# expectation would bury a whole platform's worth of "this proved nothing" inside a green pass.
#
# THIS IS NOT THE CLASSIFIER THIS SUITE REFUSES ELSEWHERE, and the difference is worth stating
# because the shapes look alike. The precondition skips below read a token to decide CONTROL FLOW,
# so they must never be keyed on the words in an error message. This is an assertion about the
# symptom of a deprivation we chose -- exactly what `without-SYS_ADMIN-newuidmap-is-what-fails`
# does one screen up. Nothing branches on it.
if [ -z "$(vt_selinux)" ]; then
    skip "nest:without-the-label-off-nothing-starts-inside" \
         "this host has no SELinux, so machine_flags passes no label flag and there is none to remove"
else
nlp="$(nest_probe_nolabel)"
assert_match "nest:the-nolabel-probe-also-really-ran" '^machine-fixture-[0-9]+$' \
             "$(nest_get "$nlp" FIXTURE_ID)"
assert_says "nest:without-the-label-off-nothing-starts-inside" 'Permission denied' \
            "$(nest_get "$nlp" INNER_RUN)"
assert_says "nest:and-a-mount-is-what-crun-is-refused" 'mount' "$(nest_get "$nlp" INNER_RUN)"
# ...and the control must still create its NAMESPACE, or it is failing for one of the other two
# departures' reasons and proving nothing about this one -- the same guard the nounmask control
# carries above.
assert_match "nest:the-nolabel-control-isolates-one-flag" '^user:\[[0-9]+\]$' \
             "$(nest_get "$nlp" INNER_USERNS)"
# THE SECOND LIMIT, IN THE SAME CONTROL, and this is the assertion that retires #119's
# prerequisite. The issue concluded /dev/net/tun needed `setsebool -P container_use_devices 1` --
# a root, machine-wide change. It does not: that boolean gates container_t, and with the label off
# the device arrives while the boolean stays exactly as the distro shipped it. Here the device is
# MISSING with the label on and char-device with it off, on one host, with nothing else varying.
assert_eq "nest:and-dev-net-tun-is-what-the-label-was-hiding" "MISSING" \
          "$(nest_get "$nlp" DEVNETTUN)"
fi
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
# ─── A SECOND HOST PRECONDITION, IN THE DISK CHECK'S SHAPE (#119) ──────────────
# THE SAME ARGUMENT AS THE DISK, one line down: this build cannot succeed on a machine whose
# policy will not let crun create a container, and spending six minutes and 6 GB to discover that
# -- then reporting it as eleven statements about install-cs193v.sh -- is the defect #119 filed.
#
# IT SKIPS ONLY WHAT IT MUST, AND ONLY BEHIND A RED ASSERTION. nest:a-container-really-starts-inside
# above has already FAILED by the time this is reached, carrying crun's own words, so the machine's
# refusal is reported once, loudly, in the tier that costs seconds. What this suppresses is the
# eleven consequences -- and it cannot suppress a regression, because anything that breaks the
# nesting flags reddens that assertion first.
#
# NOT A CLASSIFIER. This reads a token the probe wrote, exactly as the disk check reads df; nothing
# here parses crun's message to decide what it meant. A gate keyed on the words "Permission denied"
# would fire on precisely the symptom of the fixture losing its nesting flags, which would turn a
# regression into a calm named skip.
if [ "$(nest_get "$np" INNER_RUN)" != ok ]; then
    skip "nested:the-course-build" "no container starts inside this fixture on this host, so a 25-step build cannot: $(nest_get "$np" INNER_RUN)"
else
sb_free_gb="$(do_df_avail /)"
record "nest:free-disk-gb-before" "${sb_free_gb:-unknown}"
if [ -z "$sb_free_gb" ] || [ "$sb_free_gb" -lt 15 ]; then
    skip "nested:the-course-build" "only ${sb_free_gb:-?}GB free; this build wants ~8GB and a margin"
else

# WHAT THIS MACHINE HELD BEFORE, narrowed to the rows this run could be responsible for --
# see assert_host_state in lib/sandbox.sh, and #199 for the cksum of the whole computer that
# used to be here.
imgs_before="$SB_TMP/host-imgs.before.nest"; host_images  > "$imgs_before"
vols_before="$SB_TMP/host-vols.before.nest"; host_volumes > "$vols_before"
# GUARDED, because /etc/subuid does not exist on macOS: `cksum < /etc/subuid` fails there, both
# sides come back the empty string, and the assertion reported PASS on every Mac run without
# ever having read anything. A skip says so instead (#155's rule, one assertion over).
subuid_before=''
[ -r /etc/subuid ] && subuid_before="$(cksum < /etc/subuid)"

# ─── THE CASE THAT DID NOT EXIST: no podman, install succeeds, image builds ─────
# nest_build takes the prereq list, so this is the whole point of one machine with everything
# on it: apt installs podman for real, the installer then asks THAT podman for its arch and gets
# an answer, writes the args, and the launcher assembles the course image with it. Before this,
# `no-podman` proved apt installs podman and `nested` proved the build works, and nothing joined
# them -- so the one path every student actually takes was the one path nothing ran.
out="$(nest_build nest podman,ssh "2")"
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

assert_host_state nest machine "$imgs_before" "$vols_before"
if [ -n "$subuid_before" ]; then
    assert_eq "nest:host-subuid-untouched" "$subuid_before" "$(cksum < /etc/subuid)"
else
    skip "nest:host-subuid-untouched" "no /etc/subuid on this host"
fi
sandbox_reap
# ...and the space really came back, which is the half a precondition cannot promise.
record "nest:free-disk-gb-after" "$(do_df_avail /)"
fi
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
# THE HOST PRECONDITION AGAIN (#119), and here it has to name TWO cases. Everything from here to
# the `fi` below is inside one else-block: the 4.9.3 build AND the floor-skew case, which needs a
# build of its own to reach the hand-off it is about. So a single skip would suppress seven
# assertions under one name that mentions neither -- which is the shape VERIFICATION.md's own
# doctrine calls an assertion that never executed. Both get named.
#
# THE DISK BRANCH BELOW HAS THE SAME GAP and it predates this: it skips only
# oldest-supported:the-build while floor-skew's seven assertions vanish with it. Fixed here too,
# since it is one line and the alternative is a results file that quietly stops mentioning a case.
if [ "$(nest_get "$osp" INNER_RUN)" != ok ]; then
    skip "oldest-supported:the-build"  "no container starts inside the 22.04 fixture on this host: $(nest_get "$osp" INNER_RUN)"
    skip "floor-skew:the-skewed-build" "same host limit; this case needs a real build to reach the launcher hand-off"
else
osp_free="$(do_df_avail /)"
record "oldest-supported:free-disk-gb-before" "${osp_free:-unknown}"
if [ -z "$osp_free" ] || [ "$osp_free" -lt 15 ]; then
    skip "oldest-supported:the-build"  "only ${osp_free:-?}GB free; this build wants ~8GB and a margin"
    skip "floor-skew:the-skewed-build" "only ${osp_free:-?}GB free; this case needs a build of its own"
else
osp_imgs="$SB_TMP/host-imgs.before.oldest-supported"; host_images > "$osp_imgs"
# THE REAL INSTALLER, unpatched, which is what makes this a regression check rather than a
# measurement -- and is itself an assertion that 4.9.3 is admitted by the shipped floors.
out="$(nest_build oldest-supported "" "" podman-old-nested)"
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
record "oldest-supported:build-log-tail" "$(sb_section "$out" BUILD-LOG | tail -6 | do_tr '\n' '|')"
assert_host_state oldest-supported podman-old-nested "$osp_imgs"
sandbox_reap
record "oldest-supported:free-disk-gb-after" "$(do_df_avail /)"

# ─── the two declarations became one, and this is what proves it  (#221) ───────
# WHAT THIS CASE USED TO MEASURE, because the change is the interesting part. MIN_PODMAN_LINUX
# was declared in install-cs193v.sh and AGAIN in cs193v -- the installer was downloaded on its
# own and could not source the launcher -- and nothing behavioural checked that the two numbers
# matched. So this case raised the LAUNCHER's floor to 5.7.0, left the installer's at 4.9.0, and
# showed a student what drift felt like: survey passes, the files download, podman is confirmed,
# the disk is confirmed, and only then does build_image hand off to a launcher that refuses.
# Every reassuring step first and the refusal last, on a machine the installer had just declared
# fit.
#
# THAT CANNOT BE BUILT ANY MORE, and it is not that the test got harder -- the defect is gone.
# course-install.sh sources cs193v-ui.sh out of the tree it downloaded, and the floor is declared
# there once. sb_work_skew still raises it in the tarball's copy, and now BOTH ends move together:
# the installer refuses in survey, naming 5.7.0, because it is reading the launcher's number.
# There is no edit that makes them disagree.
#
# SO THE ASSERTION INVERTS INTO ITS OWN SUCCESSOR. Three assertions asserted the divergence --
# the-installer-accepted-4.9.3, it-got-all-the-way-to-the-build, but-the-launcher-refuses -- and
# they are retired rather than reworded, because each one is now false by construction. What
# replaces them is the stronger claim: raise the one declaration and the installer moves with it,
# which is the behavioural proof that 25-installer.sh's min-podman:course-install-declares-no-*
# lints statically.
#
# AND THE STUDENT-FACING SHAPE IMPROVED, which is worth asserting too rather than just noting: an
# unsupported podman is now refused at "Looking at your computer", before the download is used,
# before consent, and before anything is built -- instead of at the very end of a run that had
# reported success at every step.
#
# CHEAP, because it dies before building anything -- more cheaply than before, in fact.
sb_work_skew || { fail "floor-skew:the-skew-could-be-built" "sb_work_skew failed"; exit 1; }
pass "floor-skew:the-skew-could-be-built"
out="$(nest_build floor-skew "" "" podman-old-nested /work/installer-skew.sh)"
assert_says "floor-skew:the-skewed-copy-is-what-ran" "installer-skew.sh" \
            "$(sb_section "$out" INSTALLER-USED)"
# THE ONE COPY, PROVED BEHAVIOURALLY. Only cs193v-ui.sh was edited, so an installer that still
# carried its own floor would have accepted this machine at 4.9.0 and said nothing about 5.7.0.
assert_says "floor-skew:the-installer-reads-the-launchers-floor" "5.7.0" "$out"
assert_says "floor-skew:and-refuses-this-machine-by-version"     "4.9.3" "$out"
# REFUSED EARLY, and the needle is the step it never reached. Guarded against the empty-string
# pass by the-skewed-copy-is-what-ran above and by exits-nonzero below, so this cannot go green on
# a run that produced no transcript.
assert_says_not "floor-skew:refuses-before-it-builds-anything" "Building the course container" "$out"
assert_says "floor-skew:exits-nonzero"             "===INSTALLER-RC=1===" "$out"
assert_eq   "floor-skew:and-nothing-was-built" "no" "$(sb_section "$out" IMAGE-EXISTS)"
sandbox_reap
fi
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
# WHAT THAT DOES AND DOES NOT SETTLE, and this paragraph used to say the opposite. It claimed
# MACHINE_SYSADMIN_BASES "grants it to the two Debian-family bases and NOT to fedora-nested". It
# grants it to ALL THREE (lib/sandbox.sh), and the block below already records why: crun calls
# sethostname(2) to create the container for a RUN step, which needs CAP_SYS_ADMIN whatever the
# base's packaging, and fedora-e2e failed at STEP 2/25 when the capability was withheld on the
# strength of the userns differential alone.
#
# LEFT STALE, IT SENDS THE NEXT READER THE WRONG WAY, which is not hypothetical: issue #119 spent
# its SYS_ADMIN paragraph disproving this sentence before it could get to the actual cause, which
# was the host's SELinux policy and had nothing to do with capabilities.
#
# So what these assertions keep honest is narrower than the old wording: Fedora's newuidmap makes
# a USER NAMESPACE without the capability where a Debian-family one cannot. That is a true claim
# about packaging and says nothing about whether a base can BUILD. The differential below withholds
# the capability from each base in turn to show it.
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

# THE FLAG SET IS THE SAME FOR BOTH BASES, and that is the corrected position rather than the
# original one. This case briefly asserted that fedora-nested was handed no capability, on the
# strength of the userns differential below -- and fedora-e2e then failed at STEP 2/25 with
# `sethostname: Operation not permitted`, because crun needs CAP_SYS_ADMIN to create the container
# for a RUN step whatever the base's packaging. So the differential below is a true statement about
# USER NAMESPACES and not about what a base needs overall; lib/sandbox.sh records both reasons.
machine_flags '' host no fedora-nested
record "fedora-caps:the-flags-fedora-gets" "$(printf '%s ' ${MACHINE_FLAGS[@]+"${MACHINE_FLAGS[@]}"})"

# THE DIFFERENTIAL, which is what this case is really for: with the capability WITHHELD from each
# base in turn, Fedora still makes a namespace and Ubuntu cannot.
fnp="$(nest_probe_nocap fedora-nested)"
record "fedora-caps:podman-inside" "$(nest_get "$fnp" PODMAN_VERSION)"
assert_match "fedora-caps:the-probe-ran-inside-the-fedora-fixture" '^fedora-nested-fixture-[0-9]+$' \
             "$(nest_get "$fnp" FIXTURE_ID)"
assert_match "fedora-caps:fedora-nests-with-SYS_ADMIN-withheld" '^user:\[[0-9]+\]$' \
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

# ─── Fedora, end to end: dnf really installs, and that podman really builds ────
# THE PROOF THE TIER A CASE CANNOT GIVE. sb-fed above shows the installer reaches dnf with Fedora's
# package names, and stops there because sandbox_run always passes --network=none. This is the other
# half: nest_build runs WITH a network, so `dnf install -y podman` reaches Fedora's mirrors for real,
# and then the podman it produced assembles the whole 25-step course image.
#
# --no-prereqs=podman ON A FIXTURE THAT HAS IT, rather than a second fixture without it. The
# alternative was a near-duplicate of Containerfile.fedora-nested minus one package -- 600 MB and a
# drift risk -- and the removal axis already exists for exactly this. lib/sandbox-guest.sh's table
# supplies `dnf remove -y`; SB_DISTRO comes from the base name via machine_distro, not from the
# guest's own os-release, so a bug in the installer's detection cannot be masked by the same bug in
# the harness's.
#
# THIS CASE DOES GET SYS_ADMIN, and the paragraph here used to say it did not -- "NO SYS_ADMIN, and
# that is worth watching rather than assuming". That was written while fedora-nested was briefly out
# of MACHINE_SYSADMIN_BASES; it went back in when this very case failed at STEP 2/25 with
# `sethostname: Operation not permitted`, and the note above the differential records why. The
# question it posed was answered -- the narrowing WAS right for probing and wrong for building -- so
# what is left to say is the answer rather than the question.
#
# WHAT IS STILL WORTH WATCHING IS ONE LEVEL IN, and it is asserted below rather than described:
# fedora-e2e:SYS_ADMIN-did-not-reach-it. The outer fixture holds SYS_ADMIN and, on an SELinux host,
# runs with its label off as well; the course container it builds must have neither. `inner-caps`
# comes back `[]` on both counts.
if [ "${CS193V_INSTALL_NESTED:-}" != 1 ]; then
    skip "fedora-e2e:the-prerequisites" "set CS193V_INSTALL_NESTED=1"
elif [ "${CS193V_INSTALL_NESTED_BUILD:-}" != 1 ]; then
    skip "fedora-e2e:the-build" "set CS193V_INSTALL_NESTED_BUILD=1 -- a real dnf install and 25-step build, ~6GB"
else
fixture_build fedora-nested || exit 1
# THE HOST PRECONDITION (#119), ON THIS BASE'S OWN PROBE. There was no nest_probe for
# fedora-nested at all -- fedora-caps runs only the nocap variant, whose whole point is a reduced
# flag set -- so this asks the question about the machine that is about to build.
#
# NO SECOND RED ASSERTION HERE, deliberately. nest:a-container-really-starts-inside announces the
# host's refusal once, in the seconds tier; repeating it per base would report one machine's
# property three times and say nothing new. What each block needs is a precondition keyed on ITS
# OWN base, which is what this is -- so the skip is never inferred from another base's result.
fe2e_np="$(nest_probe fedora-nested)"
record "fedora-e2e:lsm-label-applied" "$(nest_get "$fe2e_np" PROC_ATTR_CURRENT)"
if [ "$(nest_get "$fe2e_np" INNER_RUN)" != ok ]; then
    skip "fedora-e2e:the-build" "no container starts inside the fedora fixture on this host: $(nest_get "$fe2e_np" INNER_RUN)"
else
fe2e_free="$(do_df_avail /)"
record "fedora-e2e:free-disk-gb-before" "${fe2e_free:-unknown}"
if [ -z "$fe2e_free" ] || [ "$fe2e_free" -lt 15 ]; then
    skip "fedora-e2e:the-build" "only ${fe2e_free:-?}GB free; this build wants ~8GB and a margin"
else
fe2e_imgs="$SB_TMP/host-imgs.before.fedora-e2e"; host_images > "$fe2e_imgs"
out="$(nest_build fedora-e2e podman "2" fedora-nested)"
assert_says "fedora-e2e:the-machine-was-really-arranged" "prereqs=podman" "$(sb_section "$out" ARRANGED)"
# THE CONSENT SHAPE, on the family where it differs: one item, and no "(and uidmap)".
assert_says "fedora-e2e:asks-for-one-thing"   "permission for 1 thing" "$out"
assert_says "fedora-e2e:names-podman-alone"   "Installing podman" "$out"
# NO "never mentions apt" ASSERTION HERE, and the reason is the distinction issue #94 itself draws:
# the installer runs on the HOST, but the image it builds is Ubuntu. So this transcript carries the
# course Containerfile's own `apt-get install` lines in its build log, and asserting their absence
# would be asserting the course image is not Ubuntu. The Tier A sb-fed case makes that assertion
# instead, where there is no build log to confuse it.
record "fedora-e2e:installer-rc"      "$(printf '%s' "$out" | sed -n 's/.*===INSTALLER-RC=\([0-9]*\)===.*/\1/p' | head -1)"
record "fedora-e2e:inner-store-bytes" "$(sb_section "$out" INNER-STORE-BYTES)"
# THE CONTAINER, NOT JUST THE IMAGE. build_image runs `cs193v --rebuild`, which builds the image
# AND recreates the container, so a run that exits 0 has created one -- but that was INFERRED here
# rather than observed, and inference is not evidence. `podman inspect cs193v` answers directly,
# and its fallback is NO-CONTAINER, so an absent container fails rather than reads as empty.
#
# AN EXACT VALUE, for the reason the nested case gives: the course container has NO capabilities at
# all and podman reports the empty set as "[]". That is both halves in one assertion -- an empty
# value or NO-CONTAINER fails it, and so would any capability leaking in from the outer container,
# which on this base has SYS_ADMIN.
fe2e_caps="$(sb_section "$out" INNER-CAPS)"
record "fedora-e2e:inner-caps" "$fe2e_caps"
assert_eq "fedora-e2e:the-container-was-really-created" "[]" "$fe2e_caps"
assert_says_not "fedora-e2e:SYS_ADMIN-did-not-reach-it" "SYS_ADMIN" "$fe2e_caps"
# THE VERDICT: dnf installed a working podman, and that podman built the course image.
assert_says "fedora-e2e:dnf-installed-and-the-install-finished" "Setup finished" "$out"
assert_says "fedora-e2e:exited-0"             "===INSTALLER-RC=0===" "$out"
assert_eq   "fedora-e2e:built-the-course-image" "yes" "$(sb_section "$out" IMAGE-EXISTS)"
# PAIRED WITH THE IMAGE, because doctor returns ok on an installation with no image at all.
assert_eq   "fedora-e2e:doctor-runs"          "ok"  "$(sb_section "$out" DOCTOR)"
fe2e_store="$(sb_section "$out" INNER-STORE-BYTES)"
if [ -n "$fe2e_store" ] && [ "$fe2e_store" -gt 1000000000 ]; then pass "fedora-e2e:the-inner-store-really-grew"
else fail "fedora-e2e:the-inner-store-really-grew" "inner graph root is ${fe2e_store:-empty} bytes"; fi
record "fedora-e2e:build-log-tail" "$(sb_section "$out" BUILD-LOG | tail -6 | do_tr '\n' '|')"
assert_host_state fedora-e2e fedora-nested "$fe2e_imgs"
sandbox_reap
record "fedora-e2e:free-disk-gb-after" "$(do_df_avail /)"
fi
fi
fi

# ─── podman installed but not on PATH  (issue #121) ────────────────────────────
# NAMED RATHER THAN ABSENT, per VERIFICATION.md §A.15: a gate outside the default run is an
# assertion that never executed, and so is a claim nobody wrote down.
#
# THE CLAIM THIS TIER CANNOT MAKE is "the repair finds a podman the real .pkg really installed".
# Not for want of a machine arrangement -- a container could `mv /usr/bin/podman /opt/podman/bin`
# easily enough -- but because that is not what the repair reads. ensure_podman_path asks
# `pkgutil` for a macOS PACKAGE RECEIPT, and a Linux container cannot hold one; a fixture that
# faked pkgutil here would be re-proving exactly what 25-installer.sh's probe:* truth table
# already proves against both copies of the function, on this machine, in milliseconds.
#
# IT IS ALSO NOT THE no-prereqs AXIS. That axis is ABSENCE, and its doctrine is removal rather
# than concealment (see machine_flags in lib/sandbox.sh); what #121 needs is a RELOCATION, which
# is a third kind of thing and would cost a new sb_machine key, a sibling of arrange_prereqs in
# lib/sandbox-guest.sh, a line in install-sandbox.sh's help, and an amendment to 10-static.sh's
# "only one place names these flags" rule -- for a claim the cheap lane already makes.
#
# So what the real .pkg does is checked by hand on a Mac, and tests/MANUAL.md says how.
skip "sb-offpath:a-really-relocated-podman" \
     "needs a macOS package receipt, which no Linux container has -- ensure_podman_path reads pkgutil, not the filesystem. The decisions are covered in 25-installer.sh (probe:*) and 30-launcher-shim.sh (probe:*); what the real .pkg does is a by-hand Mac check (tests/MANUAL.md)"
