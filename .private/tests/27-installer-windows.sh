#!/usr/bin/env bash
# TIER: windows
#
# install-cs193v-windows.cmd, EXECUTED -- on Linux, with no Windows anywhere.
#
# `windows` is not in DEFAULT_TIERS (run-tests.sh:64) and lane_of() sends an unrecognised tier to
# the serialised podman lane, so this needs no change to the runner and never runs on a default
# invocation. That is deliberate: the fixture carries wine, and the image is 3.45 GB -- see
# fixtures/Containerfile.wine, which holds the measurement and the date it was taken.
#
#     .private/tests/run-tests.sh --tier windows
#
# WHY THIS IS WORTH A FIXTURE THAT SIZE. Stage one is the first thing a Windows student runs, and
# until now nothing had ever executed a line of it. Reading it found two suspected defects;
# executing it confirmed six, and the harness turned up a seventh nobody had considered.
#
# HOW THE CASES ARE ORGANISED. Not one case per defect -- that would be worthless the moment
# someone adds an eighth call site. Each defect is an instance of a CLASS, and the classes are
# what is covered here, with the work list derived by PARSING the .cmd wherever it can be. The
# static half of the same classes lives in 25-installer.sh, which is where the two things wine
# gets outright WRONG (LF endings, `::` in a block) have to be checked.

set -u
. "$(dirname -- "$0")/lib/assert.sh"
. "$(dirname -- "$0")/lib/sandbox.sh"
. "$(dirname -- "$0")/lib/wine.sh"

cd "$REPO" || exit 1
WINE_TMP="$(new_tmpdir)"
WINE_MSG_VERSION=2.9.8
# Read by fixture_build and export_tree in lib/sandbox.sh (:467, :481), which this file
# sources: the driver owns the scratch root and the library writes into it.
# shellcheck disable=SC2034
SB_TMP="$WINE_TMP"                    # fixture_build logs its build output here
trap 'rm -rf "$WINE_TMP"' EXIT

# THE REASON IS THE FACT AND NOTHING MORE. wine_require sets it, because "this machine is the
# wrong architecture" and "the fixture would not build" want different words and the old message
# guessed at both.
wine_require || { skip "windows:wine" "$WINE_SKIP_WHY"; exit 0; }

# ─── the message table is the only source of prose ─────────────────────────────
#
# Asserted before anything runs, because every transcript check below is only as good as this
# file: a fake that silently printed nothing would let assert_says_not pass for free.
MSGFILE="$FIXTURE_DIR/wsl-messages.$WINE_MSG_VERSION"
assert_file "windows:message-table-exists" "$MSGFILE"
assert_eq "windows:every-message-has-a-provenance-tier" "" \
    "$(awk -F'\t' '!/^#/ && NF && NF!=3 {print "malformed: " $0}' "$MSGFILE")"
assert_eq "windows:no-unknown-provenance-tier" "" \
    "$(awk -F'\t' '!/^#/ && NF==3 && $2 !~ /^[ABCDE]$/ {print $1 " has tier " $2}' "$MSGFILE")"
# The fakes must hold no prose of their own -- that is what makes the table auditable.
assert_eq "windows:fakes-hold-no-prose" "" \
    "$(grep -nE '(printf|fputs)\s*\(\s*"[A-Z][a-z]+ [a-z]' "$FIXTURE_DIR"/win-fakes/fake-*.c || true)"

# ─── AND EVERY MESSAGE IN IT MUST BE REACHABLE ────────────────────────────────
#
# THE GATE THAT WOULD HAVE CAUGHT #112, and it is worth saying exactly how it failed to. The
# table was transcribed off microsoft/WSL's own source, tier-tagged, and correct -- including
# MessageEnableVirtualization and SystemErrorRebootRequired, which are the verbatim prose of the
# two defects in that issue. TEN of its keys were wired to nothing: no fake named them,
# no case named them, no win-sandbox.sh flag reached them. So the file read as coverage of
# a failure the suite could not produce, and the installer shipped a message blaming the WSL
# version for it.
#
# WHAT THIS ASSERTS IS REACHABILITY, NOT EXECUTION, and the difference matters enough to write
# down: a key named only by a fake arm that no case drives still passes here. That is deliberate
# -- the thing worth banning outright is a string with no mechanism at all -- but it means a
# green run here is not a claim that every message was printed. `record` below reports which
# keys are named ONLY by a fake, so that weaker half is visible rather than implied.
mt_keys="$(awk -F'\t' '!/^#/ && NF==3 {print $1}' "$MSGFILE")"
mt_dead=''; mt_fake_only=''
for k in $mt_keys; do
    if grep -qF "$k" "$FIXTURE_DIR"/win-fakes/*.c 2>/dev/null; then
        grep -qF "$k" "$0" "$TESTS_DIR/win-sandbox.sh" "$TESTS_DIR/lib/wine-guest.sh" 2>/dev/null \
            || mt_fake_only="$mt_fake_only $k"
    elif ! grep -qF "$k" "$0" "$TESTS_DIR/win-sandbox.sh" "$TESTS_DIR/lib/wine-guest.sh" 2>/dev/null; then
        mt_dead="$mt_dead $k"
    fi
done
assert_eq "windows:every-message-is-reachable" "" "$(printf '%s' "$mt_dead" | sed 's/^ //')"
record "windows:messages-named-only-by-a-fake" "$(printf '%s' "${mt_fake_only:-none}" | sed 's/^ //')"

# ─── the end-to-end success path ───────────────────────────────────────────────
#
# First, because until this works no failure case means anything, and because it is the path that
# carries defect 4: the folder-location message had unescaped < >, which cmd extracts as
# redirection BEFORE echo runs, so the line printed nothing at all on every successful install.
wine_new
wine_list CS193V
wine_run
assert_eq   "win-ok:exits-zero"                   "0" "$WINE_RC"
assert_says "win-ok:reports-wsl-present"          "WSL is installed" "$WINE_OUT"
assert_says "win-ok:reports-the-environment-ready" "environment is ready" "$WINE_OUT"
# THE CLOSING MESSAGE IS NOT ASSERTED HERE ANY MORE, AND CANNOT BE (#218). This case used to
# check five things about the block of instructions the .cmd echoed on success -- that it
# appeared, that it named wsl.localhost, that the whole projects path survived cmd's habit of
# eating an unescaped `<` as redirection, and that the old [your-linux-username] placeholder
# had not come back. That block is gone: course-install.sh prints one sign-off inside WSL
# instead, chosen by CS193V_WINDOWS. Every one of those assertions would now be matching
# against output nothing produces, which is the shape of vacuous test this project files
# issues about -- and the cmd-escaping hazard the middle three existed for cannot recur in a
# line bash prints. 25-installer.sh asserts the message itself, against the real installer.
#
# WHAT IS LEFT HERE IS THE HANDOVER, which is this file's half of it. That the variable is
# passed at all is pinned by `hands-off-to-bash-once` below, which spells the student pass out
# in full; the one thing it cannot see is which of the two passes got it.
# NOT THE ROOT PASS, which has no sign-off to choose between: wsl-provision.sh prints its
# own prov.* lines and never reaches say_done. A .cmd that set the variable on both would
# still look correct in every other assertion in this file.
assert_eq   "win-ok:the-root-pass-is-not-told-that" "0" \
            "$(wine_argv_count 'CS193V_PROVISION=1.*CS193V_WINDOWS|CS193V_WINDOWS.*CS193V_PROVISION')"
assert_eq   "win-ok:no-stderr-noise"              "" "$WINE_ERR"
# Pinned to the exact path now, not just `-e bash`: the handoff argument is a constant this file
# owns, so there is no reason to accept any other one.
#
# /var/tmp AND NOT /tmp, WHICH IS A MEASUREMENT RATHER THAN A PREFERENCE (#217). Inside a WSL
# instance with systemd, /tmp is a tmpfs -- measured on 2026-09-10 -- and this flow now restarts
# the instance between downloading stage 2 and running it, so a copy in /tmp is gone by then. The
# fake models that: it records where curl was told to write, and --terminate wipes the file if it
# landed under /tmp, after which bash exits 127 the way the real one does.
assert_eq   "win-ok:hands-off-to-bash-once"       "1" "$(wine_argv_count '\-e env CS193V_WINDOWS=1 bash /var/tmp/install-cs193v.sh')"
# AND NOTHING RIDES ALONG WITH IT (#280). %XENV% is empty on every case but the two override ones
# at the foot of this file, so this is what proves the two hand-over lines still render exactly as
# they did before it existed -- and it is why the needle above can stay spelled out in full.
# 25-installer.sh can only make that claim about the source text; this makes it about argv.
assert_eq   "win-ok:passes-no-override-along" "0" "$(wine_argv_count 'CS193V_TARBALL')"
assert_eq   "win-ok:stage-two-does-not-live-in-tmp" "0" "$(wine_argv_count '\-o /tmp/')"
assert_eq   "win-ok:never-creates-an-existing-distro" "0" "$(wine_argv_count '\-\-install -d')"

# ─── THE PROVISIONING SEQUENCE, WHICH IS AN ORDER AND NOT A SET  (#217) ────────
#
# Five calls, each asserted once, and the fake makes them a real sequence rather than five
# independent answers: the root pass records that the account exists, --terminate records the
# restart, and `test -O` is 0 only once BOTH have happened. So a .cmd that got the order wrong --
# handing over before the restart, say, which is the trap that silently installs into /root --
# fails here rather than passing a fixture that cannot tell.
assert_eq "win-ok:asks-whether-the-account-is-ours" "1" \
          "$(wine_argv_count '\-e getent passwd student')"
assert_eq "win-ok:asks-whether-anyone-else-lives-here" "1" \
          "$(wine_argv_count '\-e getent passwd 1000')"
assert_eq "win-ok:runs-the-root-pass-once" "1" \
          "$(wine_argv_count 'env CS193V_PROVISION=1 bash')"
assert_eq "win-ok:restarts-the-instance-once" "1" "$(wine_argv_count '\-\-terminate')"
assert_eq "win-ok:asks-who-owns-the-home-directory" "1" "$(wine_argv_count '\-e test -O')"
# THE ORDER ITSELF, out of argv.log rather than out of the file: the restart must come between
# the root pass and the student's, because /etc/wsl.conf is read when an instance STARTS and an
# idle one lingers 15 seconds. Getting this wrong is invisible in the .cmd and total at runtime.
assert_eq "win-ok:restarts-between-the-two-passes" "PROVISION TERMINATE STAGE2" \
          "$(printf '%s\n' "$WINE_ARGV" \
             | sed -n 's/.*env CS193V_PROVISION=1 bash.*/PROVISION/p; s/.*--terminate.*/TERMINATE/p; s/.*-e env CS193V_WINDOWS=1 bash \/var\/tmp.*/STAGE2/p' \
             | do_tr '\n' ' ' | sed 's/ *$//')"

# ─── stage two is FETCHED, and the machine it is fetched into is checked first ──
#
# The four calls of the handoff, each asserted once so an extra or missing one is a failure
# rather than a detail. The apt count is the one that is easy to leave out: without it, a .cmd
# that ran `apt-get update` on every single launch -- on a file whose own header promises it is
# safe to run any number of times -- would pass everything else here.
assert_eq   "win-ok:probes-for-curl-once"         "1" "$(wine_argv_count '\-e curl --version')"
assert_eq   "win-ok:does-not-apt-when-curl-is-there" "0" "$(wine_argv_count 'apt-get')"
assert_eq   "win-ok:downloads-once"               "1" "$(wine_argv_count '\-e curl -fsSL')"
# THE DIGEST CHECK HAPPENS ONCE, AND IT IS COUNTED ON THE POWERSHELL CALL NOW (#232). This used to
# count `-e grep `, the sentinel check; there is no grep any more. The probe reaches
# fake-powershell.exe rather than fake-wsl.exe, so the needle is the marker that fake's digest arm
# dispatches on -- which is also why no `-e sha256sum` appears in the log at all: the batch side
# asks PowerShell, and PowerShell is faked.
assert_eq   "win-ok:checks-the-download-once"     "1" "$(wine_argv_count 'sha256sum')"
# READ OUT OF THE .cmd, NOT RETYPED (#232). This needle used to end in `/main`, a constant nobody
# would ever move; the pinned tag moves at every release, so a literal here would be a second
# place to remember it and this assertion would go red on the release commit rather than on a
# defect. 25-installer.sh checks the URL is well formed and needs no quoting on either side of
# the boundary; what this one checks is that the .cmd really printed it to the student.
#
# THE SAME PARSER 00-release-gates.sh USES, and \r stripped first for its reason: the file is
# CRLF, and a trailing carriage return inside a needle matches nothing and says nothing about why.
wcget() {                             # wcget NAME -> the .cmd's `set "NAME=..."` value
    sed 's/\r$//' "$PRIVATE/install-cs193v-windows.cmd" \
        | sed -n "s/^set \"$1=\(.*\)\"\$/\1/p" | head -1
}
win_url="$(wcget INSTALLER_URL \
           | sed -e "s|%REPO_OWNER%|$(wcget REPO_OWNER)|" \
                 -e "s|%REPO_NAME%|$(wcget REPO_NAME)|" \
                 -e "s|%REPO_TAG%|$(wcget REPO_TAG)|")"
# NON-EMPTY FIRST, and it is load-bearing rather than ceremonial: assert_says with an empty needle
# matches any output at all, so a parser that stopped matching would turn the assertion below into
# a tautology that passes on a run which printed nothing.
assert_ne   "win-ok:the-url-needle-was-composed" "" "$win_url"
assert_says "win-ok:names-the-url-it-fetches"     "$win_url" "$WINE_OUT"

# ORDER, from argv.log rather than from reading the file: whichever of the two calls appears
# FIRST must be the download. 25-installer.sh pins the same thing statically; this pins that the
# static claim describes what actually ran. An empty argv leaves this empty and fails, so it
# cannot pass by finding nothing.
assert_match "win-ok:downloads-before-it-runs-bash" 'curl' \
             "$(printf '%s\n' "$WINE_ARGV" | grep -oE '\-e (curl -fsSL|bash)' | head -1)"

# ─── CLASS: a nonzero exit from any external command must be detected ──────────
#
# Defects 1 and 2. wsl.exe fails with -1 (WslClient.cpp: exitCode = -1), and `if errorlevel N` is
# a >= test, so it is FALSE for -1 -- measured under wine: a program exiting -1 leaves
# `if errorlevel 1` unfired while `if %errorlevel% neq 0` fires. A machine with broken WSL was
# therefore told "WSL is installed" and carried on.
#
# The matrix is over (probe x failure code), not one case for the one line that was wrong.
for rc in -1 1 2 9009; do
    wine_new
    wine_list CS193V
    wine_knob wsl.status.rc "$rc"
    wine_knob wsl.status.msg MessageWslOptionalComponentRequired
    wine_run
    assert_says_not "win-status-$rc:does-not-claim-wsl-is-installed" "WSL is installed" "$WINE_OUT"
    # THE WORDING MOVED WITH THE ARM: this used to read "Installing WSL", from a step the file ran
    # itself once it had been started elevated. It now says what is about to happen and why a
    # prompt is appearing, because the step is a child it asks permission for.
    assert_says     "win-status-$rc:offers-to-turn-wsl-on"           "Turning WSL on" "$WINE_OUT"
    assert_says     "win-status-$rc:warns-about-the-prompt"          "ask for an administrator" "$WINE_OUT"
done

# 5. THE CREATE THAT FAILS AFTER THE DOWNLOAD, which is where the diagnosis lives now that the
#    pre-flight is gone. Three shapes, deliberately not one loop over knobs, because the whole
#    point is that they DIVERGE: two of them say why they failed and one does not, and the
#    installer owes a different answer to each.
#
#    WHY THE CLASSIFIER READS `wsl --status` AND NOT THE CREATE'S OWN OUTPUT. `wsl --install -d`
#    streams a download progress bar, and redirecting it to a file so the .cmd could grep it would
#    leave a student watching nothing for 600 MB. So the create stays unredirected -- its error is
#    on screen for staff either way -- and the classification comes from `wsl --status`, which is
#    instant, downloads nothing, and is the very stdout issue #112 was about throwing away. Read
#    only AFTER something has already failed, it is a presentation choice and not a gate: a miss
#    lands on :distrofailed, which is case 5b.

# 5a. IT SAYS WHY, so the installer must not invent a different reason. Against the file as it
#     shipped this reached :distrofailed and asserted "this computer can run virtual machines" --
#     contradicting the error wsl.exe had printed immediately above it.
wine_new
wine_list
wine_knob wsl.install.novirt 1          # the create fails at CreateVm, AFTER downloading...
wine_knob wsl.status.novirt 1           # ...and --status says so, on stdout, still exiting 0
wine_run
assert_ne   "win-novm-create:does-not-exit-zero"           "0" "$WINE_RC"
# THE ASSERTION THE WHOLE REDESIGN EXISTS FOR: the window a student is told to send staff has to
# carry wsl.exe's own error code, which is the thing #112's message asked them to replace with
# `wsl --version`.
assert_says "win-novm-create:carries-the-error-code"       "HCS_E_HYPERV_NOT_INSTALLED" "$WINE_OUT"
assert_says "win-novm-create:carries-wsl-own-words"        "virtualization is not enabled" "$WINE_OUT"
# ...and the remediation arrives as WSL's own advice, which is what replaces :enablevmp.
assert_says "win-novm-create:carries-the-remediation"      "--install --no-distribution" "$WINE_OUT"
assert_says "win-novm-create:carries-the-link"             "aka.ms/enablevirtualization" "$WINE_OUT"
# AND THE INSTALLER DOES NOT ARGUE WITH ANY OF IT.
assert_says_not "win-novm-create:does-not-claim-vms-work"  "can run virtual machines" "$WINE_OUT"
assert_says_not "win-novm-create:does-not-blame-the-floor" "2.5.8" "$WINE_OUT"
assert_says_not "win-novm-create:does-not-guess"           "a guess" "$WINE_OUT"
assert_says "win-novm-create:asks-for-the-whole-window"    "this whole window" "$WINE_OUT"
assert_eq   "win-novm-create:never-runs-bash"              "0" "$(wine_argv_count '\-e bash ')"

# 5b. IT FAILS AND NOTHING SAYS WHY -- the create dies at CreateVm but `--status` is clean, which
#     is what a firmware-disabled box looks like: Status() checks for the optional component and
#     vmcompute, not for whether a VM can actually start. The classifier MISSES here, and that is
#     the designed degradation: :distrofailed, offering its one remaining cause as a guess. What
#     it may not do is claim the machine can run VMs, which is what the retired pre-flight let it
#     say for free.
wine_new
wine_list
wine_knob wsl.install.novirt 1
wine_run
assert_ne   "win-create-novirt-quiet:does-not-exit-zero"    "0" "$WINE_RC"
assert_says "win-create-novirt-quiet:offers-a-guess"        "a guess" "$WINE_OUT"
assert_says "win-create-novirt-quiet:asks-for-the-window"   "this whole window" "$WINE_OUT"
assert_says_not "win-create-novirt-quiet:claims-nothing-about-vms" "can run virtual machines" "$WINE_OUT"

# 5c. IT EXITS ZERO HAVING DONE NOTHING. `wsl --install -d` enables a component, prints the reboot
#     notice, installs NOTHING and returns ZERO (WslClient.cpp:544-611) -- no error to read at
#     all. The re-probe after the create is the only thing that catches it, and that is unchanged.
wine_new
wine_list
wine_knob wsl.install.rebootrequired 1
wine_run
assert_ne   "win-rebootrequired:does-not-exit-zero"         "0" "$WINE_RC"
assert_says "win-rebootrequired:offers-the-cause-as-a-guess" "a guess" "$WINE_OUT"
assert_says "win-rebootrequired:asks-for-the-whole-window"   "this whole window" "$WINE_OUT"
assert_says_not "win-rebootrequired:claims-nothing-about-vms" "can run virtual machines" "$WINE_OUT"
assert_eq   "win-rebootrequired:never-runs-bash"            "0" "$(wine_argv_count '\-e bash ')"

# ─── CLASS: the SECOND site, where the environment already exists ──────────────
#
# The machine that has the environment and has since lost virtualisation. #112's fix never
# reached here, because :makedistro is skipped entirely: the run goes straight to the curl probe,
# every `-d` call fails because each one needs the utility VM, and against the file as it shipped
# the student was told "[2/3] The CS193V environment is ready", then that curl was missing, then
# that the network was not up yet inside the environment, then that it was safe to run again --
# a loop with no exit and three wrong claims on the way into it.
#
# These two cases are the same pair as 5a/5b at this site: with the cause readable, the same
# refusal as 5a; without it, an honest :curlfailed that no longer states a cause it does not know.
wine_new
wine_list CS193V                        # the environment is there; the VM is not
wine_knob wsl.vm.cannotstart 1
wine_knob wsl.status.novirt 1
wine_run
assert_ne   "win-novm-existing:refuses"                        "0" "$WINE_RC"
assert_says "win-novm-existing:gives-the-same-refusal"         "could not start a virtual" "$WINE_OUT"
assert_says "win-novm-existing:carries-wsl-own-words"          "virtualization is not enabled" "$WINE_OUT"
assert_says_not "win-novm-existing:does-not-blame-the-network" "network is not up" "$WINE_OUT"
assert_says_not "win-novm-existing:does-not-invite-a-retry"    "safe to rerun the installer" "$WINE_OUT"
assert_eq   "win-novm-existing:never-runs-bash"                "0" "$(wine_argv_count '\-e bash ')"
# NOT ASSERTED: that it never says "environment is ready". It IS ready -- it exists, and saying so
# is true. What was wrong was everything after it, which is what the assertions above pin.

# ...and the same site with nothing to read, which must not become a diagnosis either.
wine_new
wine_list CS193V
wine_knob wsl.vm.cannotstart 1
wine_run
assert_ne   "win-existing-quiet:refuses"                        "0" "$WINE_RC"
assert_says_not "win-existing-quiet:does-not-blame-the-network"  "network is not up" "$WINE_OUT"
assert_says_not "win-existing-quiet:does-not-invite-a-retry"     "safe to rerun the installer" "$WINE_OUT"
assert_says "win-existing-quiet:asks-for-the-whole-window"       "this whole window" "$WINE_OUT"
assert_eq   "win-existing-quiet:never-runs-bash"                 "0" "$(wine_argv_count '\-e bash ')"

# AND THE DIAGNOSIS PROBE ITSELF FAILING, which is the third state %VMFAILPROBE% deliberately does
# not have. Windows really cannot start a VM here AND `wsl --status` really would say so -- but the
# probe that reads it cannot run. The refusal must degrade to naming no cause, never to naming the
# wrong one: this is the shape that mattered in #114, pointed the other way.
#
# Driven with ps.vmfail.rc rather than ps.rc, for the reason the distro-probe case below gives:
# the blanket knob would fail the FIRST probe and never reach this one.
wine_new
wine_list CS193V
wine_knob wsl.vm.cannotstart 1
wine_knob wsl.status.novirt 1
wine_knob ps.vmfail.rc 9009
wine_run
assert_ne   "win-vmfailprobe:refuses"                       "0" "$WINE_RC"
assert_says_not "win-vmfailprobe:does-not-blame-the-network" "network is not up" "$WINE_OUT"
assert_says_not "win-vmfailprobe:does-not-claim-a-vm-cause"  "could not start a virtual" "$WINE_OUT"
assert_says "win-vmfailprobe:asks-for-the-whole-window"      "this whole window" "$WINE_OUT"
assert_eq   "win-vmfailprobe:never-runs-bash"                "0" "$(wine_argv_count '\-e bash ')"

# Creating the environment, and the on-screen promise it makes while doing so. The text is the
# installer's OWN words, so it is fair to pin.
#
# FOUR PROMISES WERE PINNED HERE AND ALL FOUR ARE GONE (#217): a username, a password to go with
# it, a third question about usage reports, and "TYPE exit AND PRESS ENTER". They described what
# `wsl --install` did when it LAUNCHED the new distribution, which was Ubuntu's first-run setup.
# With --no-launch none of it happens.
#
# REPLACED RATHER THAN DELETED, and that is the point of this block. The .cmd's prose has no key
# reconciliation -- nothing pairs its echo lines against a catalogue -- so deleting a promise and
# the assertion that pinned it in the same commit leaves NOTHING red, and the next person cannot
# tell whether the message was retired or lost. So the new promise is asserted in the old one's
# place: there is nothing to type, and it may be quiet for a while. That second half matters more
# than it looks -- the provisioning stretch is silent for up to a minute, and a student who was
# told to expect questions would sit watching a still window waiting for one.
wine_new
wine_list                              # nothing registered yet
wine_run
assert_eq   "win-create:succeeds"                  "0" "$WINE_RC"
assert_says "win-create:says-it-is-creating"       "Creating the CS193V Linux environment" "$WINE_OUT"
assert_says "win-create:says-there-is-nothing-to-type" "nothing for you to type" "$WINE_OUT"
assert_says "win-create:warns-that-it-goes-quiet"  "may go quiet" "$WINE_OUT"
# AND THE OLD PROMISES MUST NOT COME BACK, because they would now be lies rather than merely
# stale: nothing asks for a username, nothing asks for a password, and there is no shell to exit.
assert_says_not "win-create:does-not-promise-a-username" "a username" "$WINE_OUT"
assert_says_not "win-create:does-not-promise-a-password" "a password to go with it" "$WINE_OUT"
assert_says_not "win-create:does-not-promise-a-telemetry-question" "usage reports" "$WINE_OUT"
assert_says_not "win-create:does-not-tell-them-to-type-exit" "TYPE exit" "$WINE_OUT"
assert_says "win-create:then-reports-it-ready"     "environment is ready" "$WINE_OUT"
assert_eq   "win-create:creates-it-once"           "1" "$(wine_argv_count '\-\-install -d')"
assert_eq   "win-create:asks-for-no-launch"        "1" "$(wine_argv_count '\-\-no-launch')"
# THE FIRST-RUN SETUP IS SWITCHED OFF BEFORE ANYTHING ELSE, and the order is the assertion: the
# Start Menu entry exists the moment --install returns, so for as long as Ubuntu's setup is armed
# a student who clicks it fires the questions in another window -- and the .cmd's next `-e` call
# then blocks on an event with no timeout. The fake's mv arm fails the second time, exactly as
# the real one does, so this cannot be satisfied by doing it twice.
assert_eq   "win-create:switches-the-first-run-setup-off" "1" \
            "$(wine_argv_count '\-e mv /etc/wsl-distribution.conf')"
assert_eq   "win-create:switches-it-off-before-it-downloads" "MV CURL" \
            "$(printf '%s\n' "$WINE_ARGV" \
               | sed -n 's/.*-e mv \/etc\/wsl-distribution.conf.*/MV/p; s/.*-e curl -fsSL.*/CURL/p' \
               | do_tr '\n' ' ' | sed 's/ *$//')"

# The same class at the distro-creation call, which is the one that mattered most: its exit code
# is the LAUNCHED SHELL'S, not the install's, so it cannot be trusted in either direction. The
# installer re-probes instead, and these two cases pin both halves of that.
wine_new
wine_list                              # nothing registered
wine_knob wsl.name.unsupported 1       # WSL < 2.5.8: no --name at all, exits -1
wine_run
assert_ne   "win-name:does-not-exit-zero"        "0" "$WINE_RC"
assert_says "win-name:offers-the-wsl-version-as-a-cause" "older than 2.4.4" "$WINE_OUT"
assert_says "win-name:asks-for-wsl-version"      "wsl --version" "$WINE_OUT"
# AND IT MUST NOT ASSERT IT. The message names one likely cause out of several, which is the whole
# defect in issue #112 -- a machine that could not run a VM at all was told this and only this.
assert_says "win-name:says-it-is-a-guess"        "a guess" "$WINE_OUT"
# AND IT MUST HAVE TRIED. This is the one cause :distrofailed names, and the file used to name it
# without ever running the command that fixes it -- `wsl --update` was on the no-WSL-at-all arm
# only, so a student with an old-but-working WSL was told to check a version nobody had offered
# to raise. Counted rather than asserted as prose: the message could say anything.
assert_eq   "win-name:tried-to-update-first"     "1" "$(wine_argv_count '\-\-update')"

# ─── CLASS: the create's own exit code, which is finally worth reading  (#217) ─
#
# THIS CASE USED TO ASSERT THE OPPOSITE, and it is worth saying why rather than quietly turning it
# round. `wsl --install -d` LAUNCHED the new distribution and returned THE LAUNCHED SHELL's exit
# code, so a student who mistyped a command before typing `exit` looked exactly like a failed
# install -- which is why the .cmd could not test that code at all and re-probed instead. With
# --no-launch there is no shell in the picture: the code is the install's own, and a nonzero one
# is a real failure that must refuse rather than carry on.
#
# THE PROBE STAYS ALL THE SAME, and win-rebootrequired below is why: a create that enables a
# Windows component prints the reboot notice, installs NOTHING and exits ZERO. So the code and the
# probe answer different questions and both are asked.
wine_new
wine_list                              # nothing registered
wine_knob wsl.install.rc 1             # the install itself failed
wine_run
assert_ne   "win-installrc:refuses"               "0" "$WINE_RC"
assert_eq   "win-installrc:never-runs-bash"       "0" "$(wine_argv_count '\-e bash ')"
assert_eq   "win-installrc:never-provisions"      "0" "$(wine_argv_count 'CS193V_PROVISION=1')"

# A WSL SO OLD IT HAS NO --no-launch. Nothing supported is: --no-launch predates the 2.4.4 floor
# the docs name, and 2.7.13 is current stable. The case exists because the assertion above needs a
# failure arm that is reachable -- an exit check whose nonzero branch no fixture can produce is an
# assertion in appearance only, which is exactly the class of defect the issue that added this
# flow set out to find.
wine_new
wine_list
wine_knob wsl.nolaunch.unsupported 1
wine_run
assert_ne   "win-nolaunch:refuses"                "0" "$WINE_RC"
assert_says "win-nolaunch:blames-the-create"      "Could not create" "$WINE_OUT"
assert_says_not "win-nolaunch:does-not-blame-provisioning" "Could not prepare" "$WINE_OUT"
assert_eq   "win-nolaunch:never-provisions"       "0" "$(wine_argv_count 'CS193V_PROVISION=1')"


# ─── CLASS: what is already in the environment decides what may be done to it ──
#
# THE CASE THAT WAS RED BEFORE THE .cmd CHANGED AT ALL. A registered CS193V with no account in it
# is what a run that died between `--install` and the account looks like -- and it is the state
# the whole two-pass design has to be able to resume, because the file's own header promises it is
# safe to run again. There is no fast path for "the account is already ours" either: provisioning
# is idempotent by construction, and a version that skipped it after seeing the account would jump
# straight to the student's pass on a machine where podman was never installed -- into a sudo
# prompt on an account whose password is locked, which is the one failure this design exists to
# prevent.
wine_new
wine_list CS193V                       # registered, and nothing has ever run in it
wine_run
assert_eq   "win-noaccount:succeeds"              "0" "$WINE_RC"
assert_eq   "win-noaccount:creates-no-distro"     "0" "$(wine_argv_count '\-\-install -d')"
assert_eq   "win-noaccount:asks-whether-the-account-is-ours" "1" \
            "$(wine_argv_count '\-e getent passwd student')"
assert_eq   "win-noaccount:provisions-it"         "1" "$(wine_argv_count 'CS193V_PROVISION=1')"
assert_eq   "win-noaccount:then-runs-the-student-pass" "1" \
            "$(wine_argv_count '\-e env CS193V_WINDOWS=1 bash /var/tmp/install-cs193v.sh')"
# AND IT DOES NOT TOUCH THE FIRST-RUN SETUP ON THIS PATH. The mv belongs to the arm that has just
# created the environment; here the file may well have been moved already by the run that died,
# and `mv` fails on a source that is not there -- so doing it again would turn a resumable state
# into a refusal. The root pass ensures it instead, where a shell can tell the two apart.
assert_eq   "win-noaccount:leaves-the-first-run-setup-to-the-root-pass" "0" \
            "$(wine_argv_count '\-e mv /etc/wsl-distribution.conf')"

# SOMEBODY ELSE'S ACCOUNT, which is what a CS193V made by the installer that asked students to
# choose a username looks like -- last quarter's environment, with their work in it. Creating a
# second account there would change which one they land in and where their files live, silently,
# and stage 1 has no way to ask: it is non-interactive apart from `pause`. So it refuses, and the
# refusal names the destructive command AND what it destroys.
wine_new
wine_list CS193V
wine_knob wsl.account.foreign keith
wine_run
assert_ne   "win-foreign:refuses"                 "0" "$WINE_RC"
assert_says "win-foreign:offers-unregister"       "wsl --unregister CS193V" "$WINE_OUT"
assert_says "win-foreign:says-what-that-destroys" "DELETES EVERYTHING" "$WINE_OUT"
assert_eq   "win-foreign:never-provisions"        "0" "$(wine_argv_count 'CS193V_PROVISION=1')"
assert_eq   "win-foreign:never-runs-the-student-pass" "0" \
            "$(wine_argv_count '\-e bash /var/tmp')"

# ─── CLASS: provisioning is a third site that can fail, and it fails on its own ─
#
# The root pass refusing. It must not be reported as anything else -- :distrofailed names one
# cause ("a WSL older than...") that has nothing to do with this, which is #112's anatomy: a
# refusal printing a different cause over the top of a correct one.
wine_new
wine_list CS193V
wine_knob wsl.provision.rc 1
wine_run
assert_ne   "win-provisionfail:refuses"           "0" "$WINE_RC"
assert_says "win-provisionfail:says-what-failed"  "Could not prepare" "$WINE_OUT"
assert_says_not "win-provisionfail:does-not-blame-the-wsl-version" "older than" "$WINE_OUT"
assert_eq   "win-provisionfail:never-runs-the-student-pass" "0" \
            "$(wine_argv_count '\-e bash /var/tmp')"

# AND THE VIRTUALISATION CLASSIFIER REACHES IT, which is the second-site lesson of #114 arriving
# at a third site: every `wsl -d` call needs the utility VM, so a machine that has the environment
# and has lost virtualisation fails HERE, and must get the shared refusal rather than a guess of
# its own. Driven with ps.vmfail.rc left honest so the classifier really answers.
wine_new
wine_list CS193V
wine_knob wsl.vm.cannotstart 1
wine_knob wsl.status.novirt 1
wine_run
assert_ne   "win-provisionfail-novm:refuses"      "0" "$WINE_RC"
assert_says "win-provisionfail-novm:names-virtualisation" "could not start a virtual" "$WINE_OUT"
assert_says_not "win-provisionfail-novm:does-not-guess-at-provisioning" "Could not prepare" "$WINE_OUT"

# THE RESTART FAILING, which is the quietest of the three and the reason the handover is asked
# rather than assumed: /etc/wsl.conf is read when an instance STARTS, so without the restart the
# student's pass would run as root and install into /root. A .cmd that ignored this code would
# then be caught by `test -O` -- but one refusal is better than two, and this pins the first.
wine_new
wine_list CS193V
wine_knob wsl.terminate.rc 1
wine_run
assert_ne   "win-terminatefail:refuses"           "0" "$WINE_RC"
assert_eq   "win-terminatefail:never-runs-the-student-pass" "0" \
            "$(wine_argv_count '\-e bash /var/tmp')"

# THE FIRST-RUN SETUP THAT CANNOT BE SWITCHED OFF, which is the shape of a future Ubuntu image
# that keeps its OOBE configuration somewhere else. Refusing is the whole reason the .cmd uses
# `mv` rather than `truncate`: truncate CREATES the file if it is absent and exits 0, so that
# version would have carried on with the questions still armed and a student would have met them
# in a Start Menu window part-way through an install.
wine_new
wine_list                              # nothing registered: this is the create path
wine_knob wsl.oobe.conf.missing 1
wine_run
assert_ne   "win-oobeconf:refuses"                "0" "$WINE_RC"
assert_eq   "win-oobeconf:never-runs-the-student-pass" "0" \
            "$(wine_argv_count '\-e bash /var/tmp')"

# THE HANDOVER CHECK ITSELF, ASKED RATHER THAN ASSUMED. "Is /home/student owned by the user I am
# running as?" is the one question that proves the whole sequence worked, and this case makes its
# failure arm reachable: wsl.terminate.noop exits 0 WITHOUT restarting the instance, which is not
# a hypothetical -- `wsl --manage --set-default-user` terminates only `if (modified)`, so an
# obvious alternative to the restart really does behave this way on a re-run. Without the restart
# /etc/wsl.conf has not been read, the student's pass would run as root, and this check is what
# notices.
wine_new
wine_list CS193V
wine_knob wsl.terminate.noop 1
wine_run
assert_ne   "win-handover:refuses"                "0" "$WINE_RC"
assert_eq   "win-handover:asked-the-question"     "1" "$(wine_argv_count '\-e test -O')"
assert_eq   "win-handover:never-runs-the-student-pass" "0" \
            "$(wine_argv_count '\-e bash /var/tmp')"
# ─── CLASS: a machine that cannot fetch must be fixed, or refused ─────────────
#
# What used to be here was the wslpath capture: stage two came from a Windows path, wsl.exe
# wrote its errors to STDOUT, and a `for /f` backtick handed "There is no distribution with the
# supplied name." to bash as a filename. Stage two is downloaded now, so there is no captured
# value left in the file to validate -- 25-installer.sh asserts that %HERE%, wslpath and %TEMP%
# are all gone, which is what stops that class coming back by the front door.
#
# The class that replaces it: the environment is Ubuntu's image, and a base Ubuntu is not
# entitled to have curl. Stage one installs it rather than refusing -- the environment is one
# this same file created minutes earlier -- and every step of that has to be checked.
wine_new
wine_list CS193V
wine_knob wsl.curl.missing 1
wine_run
assert_eq   "win-nocurl:succeeds"                  "0" "$WINE_RC"
assert_says "win-nocurl:says-it-is-installing-curl" "Installing curl in CS193V" "$WINE_OUT"
assert_eq   "win-nocurl:updates-apt-first"         "1" "$(wine_argv_count 'apt-get update')"
assert_eq   "win-nocurl:installs-curl-and-the-ca-bundle" "1" \
            "$(wine_argv_count 'apt-get install -y curl ca-certificates')"
# TWICE: once to find out, once to confirm. apt exiting 0 is not the same claim as "curl is on
# the PATH now", which is the distinction the distro probe already makes about `wsl --install`.
assert_eq   "win-nocurl:re-probes-after-installing" "2" "$(wine_argv_count '\-e curl --version')"
assert_eq   "win-nocurl:then-downloads"            "1" "$(wine_argv_count '\-e curl -fsSL')"
assert_eq   "win-nocurl:then-hands-off-to-bash"    "1" "$(wine_argv_count '\-e env CS193V_WINDOWS=1 bash ')"

# Either apt step failing. -1 because that is what wsl.exe returns for its own failures, and it
# is the code `if errorlevel 1` cannot see.
for knob in wsl.apt.update.rc wsl.apt.install.rc; do
    wine_new
    wine_list CS193V
    wine_knob wsl.curl.missing 1
    wine_knob "$knob" -1
    wine_run
    assert_ne   "win-$knob:does-not-exit-zero"     "0" "$WINE_RC"
    assert_says "win-$knob:admits-what-failed"     "Could not install curl" "$WINE_OUT"
    # THE RETRY IS STILL OFFERED, but it is now attached to the cause it belongs to rather than
    # promised outright. :curlfailed used to open by stating the network as THE cause and then
    # saying it was safe to run again -- which on a machine that had lost virtualisation was a
    # loop with no exit, since every attempt failed the same way. The offer survives for the case
    # it was always right about; what went is the unconditional promise.
    assert_says "win-$knob:still-offers-a-retry"   "the installer is enough" "$WINE_OUT"
    assert_says "win-$knob:bounds-the-retry"       "it is something" "$WINE_OUT"
    assert_eq   "win-$knob:never-downloads"        "0" "$(wine_argv_count '\-e curl -fsSL')"
    assert_eq   "win-$knob:never-runs-bash"        "0" "$(wine_argv_count '\-e bash ')"
done

# THE CASE THE RE-PROBE EXISTS FOR: apt exits 0 and curl still is not there. Without the second
# probe this reaches the download, fails there, and blames the network for a missing program.
wine_new
wine_list CS193V
wine_knob wsl.curl.missing 1
wine_knob wsl.apt.nomarker 1
wine_run
assert_ne   "win-aptlied:does-not-exit-zero"       "0" "$WINE_RC"
assert_says "win-aptlied:admits-what-failed"       "Could not install curl" "$WINE_OUT"
assert_eq   "win-aptlied:never-downloads"          "0" "$(wine_argv_count '\-e curl -fsSL')"
assert_eq   "win-aptlied:never-runs-bash"          "0" "$(wine_argv_count '\-e bash ')"

# ─── CLASS: bytes that are not the installer must never reach bash ────────────
#
# -1 is wsl.exe failing on its own account; the rest are curl's: 6 no such host, 22 an HTTP
# error under -f, 23 could not write the file, 28 timed out, 56 the transfer died mid-flight.
for rc in -1 6 22 23 28 56; do
    wine_new
    wine_list CS193V
    wine_knob wsl.curl.rc "$rc"
    wine_run
    assert_ne   "win-dl-$rc:does-not-exit-zero"    "0" "$WINE_RC"
    assert_says "win-dl-$rc:names-the-url"         "raw.githubusercontent.com" "$WINE_OUT"
    assert_says "win-dl-$rc:says-it-is-safe-to-retry" "safe to rerun the installer" "$WINE_OUT"
    assert_eq   "win-dl-$rc:never-runs-bash"       "0" "$(wine_argv_count '\-e bash ')"
done

# AND THE ONE curl CANNOT REPORT. The fake serves a cut-short body and exits ZERO, which is what a
# captive portal answering 200 with its own sign-in page looks like from the outside: the bytes
# arrived, they are simply not the installer. Without this check it is the case that ends with bash
# running a login page and the .cmd printing "Done".
#
# RETARGETED FROM THE SENTINEL TO THE DIGEST (#232), and the wording it asserts moved with it: the
# old refusal said "not the whole file", which was exactly what a last-line token could conclude.
# A digest cannot distinguish a short body from a substituted one, so the refusal says "not the
# file this installer expects" and keeps naming the sign-in page as the likely cause -- because it
# still is.
wine_new
wine_list CS193V
wine_body truncated
wine_run
assert_ne   "win-portal:does-not-exit-zero"        "0" "$WINE_RC"
assert_says "win-portal:says-it-is-not-the-expected-file" "not the file this installer" "$WINE_OUT"
assert_says "win-portal:names-the-likely-cause"    "sign-in page" "$WINE_OUT"
assert_says "win-portal:names-the-expected-digest" "expected:" "$WINE_OUT"
assert_says "win-portal:names-what-arrived"        "received:" "$WINE_OUT"
assert_eq   "win-portal:never-runs-bash"           "0" "$(wine_argv_count '\-e bash ')"

# AND A BODY OF THE RIGHT LENGTH WITH A BYTE CHANGED, which is the case the truncated one cannot
# stand in for. A check that compared the byte COUNT rather than the content would pass every other
# case in this tier: win-portal would fail it for the wrong reason, and nothing would say so. This
# is the fixture that tells those two implementations apart.
#
# THE VACUITY GUARD IS FIRST AND IT IS NOT CEREMONIAL. wine_body's `altered` arm is a sed on the
# payload constant, and a sed whose address stops matching is a silent no-op -- which would serve
# the whole file under the name of a corrupt one and turn this whole case green. So the served
# body's digest is compared against the one the .cmd expects BEFORE anything is asserted about the
# run: they must differ, or there is nothing here to refuse.
wine_new
wine_list CS193V
wine_body altered
assert_ne "win-altered:the-body-really-differs" \
          "$(do_sha256 "$PRIVATE/install-cs193v.sh" | awk '{print $1}')" "$(wine_body_digest)"
assert_eq "win-altered:the-body-is-the-same-length" \
          "$(wc -c < "$PRIVATE/install-cs193v.sh" | do_tr -d ' ')" \
          "$(wc -c < "$WINE_CASE/stage2.src" | do_tr -d ' ')"
wine_run
assert_ne   "win-altered:does-not-exit-zero"       "0" "$WINE_RC"
assert_says "win-altered:is-refused"               "not the file this installer" "$WINE_OUT"
assert_eq   "win-altered:never-runs-bash"          "0" "$(wine_argv_count '\-e bash ')"

# ─── CLASS: a probe must not conflate "no" with "cannot tell" ─────────────────
#
# Defect 6's class. The distro probe answers with an exit code: 0 present, 1 absent, anything
# else means the question itself failed -- which is NOT the same as "absent", and must not silently
# become "create it".
#
# ps.distro.rc, NOT ps.rc. `ps.rc` forces EVERY probe, which is what a machine with no powershell
# looks like -- and this is now the FIRST probe the .cmd runs, so the blanket knob would land here
# anyway and prove nothing about which arm answered. Forcing this one keeps the assertion about
# THIS arm. (It was briefly the second probe, behind a virtualisation pre-flight; that pre-flight
# is gone, and the diagnosis probe that replaced it runs only after a failure.)
wine_new
wine_list CS193V
wine_knob ps.distro.rc 9009            # this probe alone cannot answer: cmd's not-found code
wine_run
assert_ne   "win-probe:does-not-exit-zero"        "0" "$WINE_RC"
assert_says "win-probe:says-the-question-failed"  "Could not ask WSL which environments exist" "$WINE_OUT"
assert_says "win-probe:distinguishes-it-from-absent" "not the same as not having" "$WINE_OUT"
assert_eq   "win-probe:does-not-create-anything"  "0" "$(wine_argv_count '\-\-install -d')"

# ─── CLASS: an elevated run is REFUSED, which is the reverse of what was here ─
#
# win-admin:* USED TO BE HERE AND ASSERTED THE OPPOSITE: that an UN-elevated run was refused with
# "needs to run as Administrator". Recorded rather than deleted quietly, because the probe
# survives with a different job and a reader should be able to tell "reversed" from "lost". Its
# original point was the old `net session` form, which returned 2 -- not 5 -- when the Server
# service is stopped and so reported a real Administrator as not one; the reg.exe form has no such
# third state. That reasoning stands; it just no longer decides whether to continue.
#
# WHY THE REVERSAL. A standard user cannot be elevated as THEMSELVES: UAC asks for a different
# administrator's credentials and the whole file then runs as that account, silently installing the
# course into that profile. Measured on Windows 11 26200 on 2026-09-15 -- 25-installer.sh's
# elevation block carries the chain. And no run needs elevation up front: if WSL is present the
# rest is per-user, and if it is not, :installwsl asks for permission itself. So the class is
# refused rather than its identity examined.
#
# reg.query.rc 0 IS THE ARRANGEMENT, and this is the only case in the file that asks for it, now
# that fake-reg.c defaults to not-elevated -- the ordinary invocation.
wine_new
wine_list CS193V
wine_knob reg.query.rc 0
wine_run
assert_ne   "win-isadmin:refuses"                 "0" "$WINE_RC"
assert_says "win-isadmin:says-not-to"             "Do not run setup as an administrator" "$WINE_OUT"
assert_says "win-isadmin:says-why-it-matters"     "belongs to ONE Windows account" "$WINE_OUT"
assert_says "win-isadmin:says-what-to-do"         "Rerun the installer as yourself" "$WINE_OUT"
# THE NEGATIVES ARE THE POINT OF THE CASE, not the message: the defect was that an elevated run
# went on to do all of its per-user work under the wrong token.
assert_eq   "win-isadmin:touches-nothing-else"    "0" "$(wine_argv_count 'wsl.exe')"
assert_eq   "win-isadmin:asks-no-permission"      "0" "$(wine_argv_count 'powershell\.exe .*Start-Process')"
assert_eq   "win-isadmin:writes-no-start-menu-entry" "no" \
            "$(wine_lnk_has 'Programs/CS193V Development Environment.lnk')"
assert_eq   "win-isadmin:deletes-nothing"         "0" "$(wine_argv_count 'powershell\.exe .*Remove-Item\b')"
assert_says_not "win-isadmin:claims-no-success"   "environment is ready" "$WINE_OUT"

# ...AND THE ORDINARY RUN IS NOT REFUSED, which would otherwise rest on the fake's default alone.
# Named so the property has a case of its own: if the refusal above were ever widened to every
# run, this is what catches it.
wine_new
wine_list CS193V
wine_run
assert_eq   "win-unelevated:installs"             "0" "$WINE_RC"
assert_eq   "win-unelevated:asks-no-permission"   "0" "$(wine_argv_count 'powershell\.exe .*Start-Process')"
assert_eq   "win-unelevated:hands-off-to-bash"    "1" \
            "$(wine_argv_count '\-e env CS193V_WINDOWS=1 bash /var/tmp/install-cs193v.sh')"

# ─── CLASS: the installer works from any folder a student downloads into ──────
#
# Defect 7 and its family. Measured on the ORIGINAL file: `Down!loads` silently became
# `Downloads` (delayed expansion eats `!`), `Down&loads` truncated the message and emitted a
# spurious "Can not recognize" error, and `cs193v (1)` -- what a browser names a second download
# -- died with "Syntax error: unexpected (".
#
# WEAKER THAN IT LOOKS NOW, and worth saying so rather than letting it read as full cover. Those
# three defects were all about %~dp0, which no longer exists in the file: stage two is fetched
# by URL, so the folder name is not read, expanded or printed anywhere. What this still proves
# is that cmd.exe RUNS the file from such a folder at all -- which is not nothing, since the
# harness itself had to work around `wine64 cmd /c` refusing a path containing parentheses --
# and that no future line reintroduces the class. The keeper for the delayed-expansion rule
# itself is now windows:never-enables-delayed-expansion in 25-installer.sh.
for dir in "Downloads" "My Downloads" "Down!loads" "Down&loads" "cs193v (1)" "a(b)c" "it's mine"; do
    wine_new "$dir"
    wine_list CS193V
    wine_run
    assert_eq   "win-path[$dir]:succeeds"          "0" "$WINE_RC"
    assert_says_not "win-path[$dir]:no-syntax-error"   "unexpected" "$WINE_OUT$WINE_ERR"
    assert_says_not "win-path[$dir]:no-unrecognised-command" "recognize" "$WINE_OUT$WINE_ERR"
done

# ─── the reboot arm, and the two calls whose codes used to be ignored ─────────
#
# "NO WSL" IS A FAILING --status, NOT A MISSING BINARY, and that distinction arrived with issue
# #125. This case used to set `where.wsl.exe 0` while leaving the fake wsl.exe in place, which is a
# machine that cannot exist: `where` reported no wsl.exe and then wsl.exe ran fine. On a real box
# the optional component being disabled leaves System32\wsl.exe present -- it is the OS component
# -- and it is `--status` that fails. That is the machine the restart arm is for, so that is what
# this arranges. A genuinely absent System32\wsl.exe is the next case, and it is a different thing.
wine_new
wine_list
wine_knob wsl.status.rc -1             # WSL present but not usable: the optional component is off
wine_run
assert_eq   "win-nowsl:exits-zero-because-nothing-failed" "0" "$WINE_RC"
assert_says "win-nowsl:tells-them-to-restart"     "RESTART YOUR COMPUTER NOW" "$WINE_OUT"
assert_says "win-nowsl:tells-them-to-rerun"       "rerun the installer" "$WINE_OUT"
# THE ANTI-VACUITY POSITIVE, and the assertion that this arm now goes through a UAC prompt rather
# than requiring the whole run to have been elevated: ONE permission request, and it is the only
# one the file ever makes. A run that died before reaching it would satisfy every line above.
assert_eq   "win-nowsl:asks-permission-once"      "1" "$(wine_argv_count 'powershell\.exe .*Start-Process')"
assert_says "win-nowsl:says-why-it-is-asking"     "change to Windows itself" "$WINE_OUT"
# AND IT STOPS THERE. The per-user work belongs to the run after the restart, so nothing on this
# arm may create an environment or write a Start Menu entry -- the property 25-installer.sh
# asserts statically as windows:the-elevated-arm-touches-nothing-per-user.
assert_eq   "win-nowsl:creates-nothing"           "0" "$(wine_argv_count '\-\-install -d')"
assert_eq   "win-nowsl:writes-no-start-menu-entry" "no" \
            "$(wine_lnk_has 'Programs/CS193V Development Environment.lnk')"

# ...AND A DECLINED PROMPT IS NOT A BROKEN MACHINE. Start-Process THROWS when consent is refused,
# which without the .cmd's catch would be indistinguishable from the install failing -- so a
# student who clicked No would be told the feature could not be turned on. Nothing has happened at
# that point, and the remedy is to run it again and allow it.
wine_new
wine_list
wine_knob wsl.status.rc -1
wine_knob win.uac-declined 1
wine_run
assert_ne   "win-uacdeclined:does-not-exit-zero"  "0" "$WINE_RC"
assert_says "win-uacdeclined:says-permission-was-refused" "permission was" "$WINE_OUT"
assert_says "win-uacdeclined:says-nothing-changed" "nothing has been changed" "$WINE_OUT"
assert_says "win-uacdeclined:says-how-to-retry"   "choose Yes when Windows" "$WINE_OUT"
assert_says_not "win-uacdeclined:does-not-blame-the-feature" "Could not turn on" "$WINE_OUT"
assert_says_not "win-uacdeclined:does-not-promise-a-restart-will-help" "RESTART YOUR COMPUTER" "$WINE_OUT"
# NOTHING WAS ARMED, AND THAT IS WHAT "NOTHING HAS BEEN CHANGED" MEANS (#275). The prompt comes
# before any change, so a student who clicked No has not left the machine half-configured -- and
# an entry registered ahead of the prompt would reopen, at the next logon, a setup they declined.
assert_eq "win-uacdeclined:arms-no-resume-entry" "" "$(wine_resume_entry)"

# ...AND A MACHINE WITH NO System32\wsl.exe AT ALL, which `if exist` is what now detects. Microsoft
# treats that state as unrepairable by anything short of an in-place upgrade -- `where wsl` returns
# nothing, DISM and SFC will not restore it -- so telling the student to restart would be advice
# that cannot work. The installer reaches :installwsl, cannot run `wsl --update` either, and
# refuses. Asserted because the refusal is the CORRECT answer here and a restart is not.
wine_new
wine_list
wine_hide_wsl
wine_run
assert_ne   "win-nowslexe:does-not-exit-zero"     "0" "$WINE_RC"
# THE MESSAGE CHANGED WITH THE ARM. `wsl --update` used to run here directly, with
# :wslupdatefailed and "Could not update WSL" of its own; it now runs inside the elevated child
# beside `wsl --install --no-distribution`, and cmd returns one code for the pair -- so the
# distinction is unrecoverable and :wslupdatefailed is gone rather than left unreachable. Both
# land on :wslfeaturefailed, whose words cover this machine: the feature did not get turned on.
assert_says "win-nowslexe:admits-what-failed"     "Could not turn on the WSL Windows feature" "$WINE_OUT"
assert_says "win-nowslexe:asks-for-the-whole-window" "send course staff this whole window" "$WINE_OUT"
assert_says_not "win-nowslexe:does-not-promise-a-restart-will-help" "RESTART YOUR COMPUTER" "$WINE_OUT"
# AND IT GOT THERE THROUGH THE PROMPT, not by skipping it. This is what makes the case about the
# child failing rather than about the .cmd never asking: fake-powershell answers 102 here because
# system32\wsl.exe is genuinely gone from the prefix, which is what cmd.exe would do.
assert_eq   "win-nowslexe:asked-permission-first" "1" "$(wine_argv_count 'powershell\.exe .*Start-Process')"
# AND A FAILED FEATURE ARMS NOTHING EITHER. There is no restart to resume from, so an entry
# here would reopen setup at the next logon on a machine nothing has changed on.
assert_eq "win-nowslexe:arms-no-resume-entry" "" "$(wine_resume_entry)"

# THE CHILD FAILING, WHICH USED TO BE TWO CASES DRIVING wsl.update.rc AND wsl.feature.rc. Those
# knobs reach the commands the CHILD runs, and the child is not run under wine at all -- there is
# no elevation and no AppInfo service here -- so they no longer touch this arm and driving them
# would have measured nothing. One knob replaces both, for the same reason the .cmd has one
# message: the pair's exit code is all that crosses back.
#
# ps.elev.rc AND NOT ps.rc, for the reason win-probe gives: the blanket knob fails every probe,
# including the distro one, so the case would stop somewhere else and still look green here.
#
# -1 IS DELIBERATE, AND IT IS THE CODE THAT USED TO ARRANGE NOTHING. fake-powershell.c's answer()
# read any value below zero as "not set" -- `if (forced >= 0) return forced;` -- so this case set
# `ps.elev.rc -1`, the fake answered 0, and the installer printed the restart notice while the case
# reported green. The fake now decides on the knob's PRESENCE, which is what fake-wsl.c always did,
# so -1 means -1. Kept here rather than replaced with a positive code, because it is the spelling
# that was broken and the one a reader will reach for: `wsl.status.rc -1` on the line above is the
# documented value for a real wsl.exe failure, and the two should not need different conventions.
#
# AND -1 EXERCISES THE CATCH-ALL. The .cmd tests `equ 101` and then `neq 0`, so any code that is
# neither 0 nor 101 proves the second branch rather than a value spelled in the file.
wine_new
wine_list
wine_knob wsl.status.rc -1
wine_knob ps.elev.rc -1
wine_run
assert_ne "win-elevfailed:does-not-exit-zero"     "0" "$WINE_RC"
assert_says "win-elevfailed:admits-what-failed"   "Could not turn on the WSL Windows feature" "$WINE_OUT"
assert_says_not "win-elevfailed:does-not-tell-them-to-restart" "RESTART YOUR COMPUTER" "$WINE_OUT"
# NOT READ AS A DECLINED PROMPT. 101 is a person saying no and has its own message; every other
# non-zero code is the child having failed, and conflating them tells a student to click Yes when
# the problem is their machine.
assert_says_not "win-elevfailed:is-not-a-declined-prompt" "permission was" "$WINE_OUT"
assert_eq "win-elevfailed:arms-no-resume-entry" "" "$(wine_resume_entry)"

# ─── resuming after the restart  (issue #275) ────────────────────────────────
#
# THE SECOND RUN IS THE ONE STUDENTS LOSE. On a machine with no WSL the install takes two, and the
# second needs them to remember it, find the file they downloaded, and start it BY FULL PATH -- a
# double-click is refused, because the copy carries a Zone.Identifier stream. So the reboot arm
# now registers an HKCU RunOnce entry naming itself, and Windows starts it at the next logon.
#
# EVERY CASE BELOW IS ABOUT THE ENTRY AND NOT ABOUT THE REGISTRY. fake-powershell.c keeps the value
# in a file and records it out of $env:RESUMECMD verbatim, so what these assert is the command line
# the INSTALLER decided on -- see that arm for why the fake composes none of it itself.

# THE ENTRY IS WRITTEN ON THE ROAD IT IS FOR, and it names this file through cmd.exe. `/s` is the
# part most likely to be wrong and the part a reader would drop: without it the outer quotes are
# kept or stripped depending on whether the path holds whitespace AND whether it holds & ^ ( or ),
# so a profile called `Tom & Jerry` breaks the resume and nothing else changes.
wine_new
wine_list
wine_knob wsl.status.rc -1
wine_run
assert_ne   "win-resumearm:registers-something"        "" "$(wine_resume_entry)"
assert_says "win-resumearm:registers-the-interpreter"  "System32\\cmd.exe" "$(wine_resume_entry)"
assert_says "win-resumearm:registers-unambiguous-quoting" "/s /c" "$(wine_resume_entry)"
assert_says "win-resumearm:registers-this-file"        "install-cs193v-windows.cmd" "$(wine_resume_entry)"
# ...AS AN ABSOLUTE PATH. The .cmd is invoked here by a RELATIVE name, the way wine_run has to
# invoke it, so a `%~n0` or a bare `%0` would register something that only works from the download
# folder -- and the folder is exactly where the resumed run does not start. This is the assertion
# that would go red for that mistake; the second-run case below is what proves the path resolves.
assert_says "win-resumearm:registers-an-absolute-path" "Z:\\tmp\\case" "$(wine_resume_entry)"
# AND IT ASKS FOR NO ELEVATION OF ITS OWN. An entry that relaunched elevated would walk into
# :isadmin and refuse itself on the one machine this feature exists for -- which is also why the
# key is HKCU, asserted statically because no prefix here has two hives to tell apart.
assert_says_not "win-resumearm:registers-no-elevation" "RunAs" "$(wine_resume_entry)"
# THE NOTICE PROMISES IT, and the promise is what makes the entry worth writing.
assert_says "win-resumearm:says-setup-will-reopen" "by itself" "$WINE_OUT"
assert_says "win-resumearm:still-says-to-restart"  "RESTART YOUR COMPUTER NOW" "$WINE_OUT"
# ...AND STILL NAMES THE FALLBACK. A RunOnce entry can be stripped by antivirus, skipped in Safe
# Mode, or blocked by policy, and none of that is visible from here. The sentence that tells a
# student what to do when nothing opens is the one thing that must survive every such case.
assert_says "win-resumearm:still-says-how-to-do-it-by-hand" "rerun the installer" "$WINE_OUT"

# A REGISTRY THAT REFUSED THE WRITE MAKES NO PROMISE. This is the arm that keeps the sentence
# above honest: the .cmd reads its own write back, and prints the wording it has always had when
# the value is not there afterwards. "Exited 0 and wrote nothing" is a real state -- #270 was
# exactly that, one layer over -- so the read-back decides the message rather than the exit code.
wine_new
wine_list
wine_knob wsl.status.rc -1
wine_knob ps.runonce.rc 1
wine_run
assert_eq   "win-resumefail:exits-zero-because-nothing-failed" "0" "$WINE_RC"
assert_eq   "win-resumefail:registers-nothing" "" "$(wine_resume_entry)"
assert_says "win-resumefail:still-says-to-restart" "RESTART YOUR COMPUTER NOW" "$WINE_OUT"
assert_says "win-resumefail:tells-them-to-rerun"   "rerun the installer" "$WINE_OUT"
# THE PROMISE IS THE DIFFERENCE, AND IT IS ABSENT. Without this the two notices could converge on
# one string and the read-back would be machinery with nothing behind it.
assert_says_not "win-resumefail:promises-nothing-it-cannot-keep" "by itself" "$WINE_OUT"

# ─── ...AND THEN THE MACHINE CAME BACK ────────────────────────────────────────
#
# THE CASE THIS WHOLE FEATURE IS FOR, and the only one in the file that runs the installer twice.
# The second run is the COMMAND LINE THE FIRST ONE STORED -- not install-cs193v-windows.cmd again.
# Re-invoking the .cmd would assert idempotency, which was already true and already covered, and
# would say nothing about whether the value Windows was handed is one it could start. It runs from
# the filesystem root, because at logon the student is not standing in their download folder.
wine_new
wine_list
wine_knob wsl.status.rc -1
wine_resume_knob wsl.status.rc 0
wine_run
# RUN ONE STOPPED WHERE IT ALWAYS DID. The per-user work belongs to the run after the restart.
assert_eq "win-resume:first-run-exits-zero"       "0" "$WINE_RC"
assert_eq "win-resume:first-run-creates-nothing"  "0" "$(wine_argv_count '\-\-install -d')"
assert_eq "win-resume:first-run-writes-no-start-menu-entry" "no" \
          "$(wine_lnk_has 'Programs/CS193V Development Environment.lnk')"
# RUN TWO IS THE STORED LINE, AND IT FINISHED THE JOB.
assert_eq   "win-resume:second-run-exits-zero"    "0" "$WINE_RCB"
assert_says "win-resume:second-run-says-wsl-is-installed" "WSL is installed" "$WINE_OUTB"
assert_eq   "win-resume:second-run-creates-the-environment" "1" \
            "$(wine_argv_count_b '\-\-install -d')"
assert_eq   "win-resume:second-run-hands-off-to-stage-two" "1" \
            "$(wine_argv_count_b '\-e env CS193V_WINDOWS=1 bash /var/tmp/install-cs193v\.sh')"
assert_eq   "win-resume:second-run-writes-the-start-menu-entry" "yes" \
            "$(wine_lnk_has_b 'Programs/CS193V Development Environment.lnk')"
# AND IT NEVER ASKS FOR PERMISSION AGAIN, which is what the notice told the student.
assert_eq   "win-resume:second-run-asks-no-permission" "0" \
            "$(wine_argv_count_b 'powershell\.exe .*Start-Process')"
# THE ENTRY IS GONE AFTERWARDS. Windows deletes a RunOnce value before running it, and the .cmd
# clears any leftover at :havewsl for the student who re-ran the file by hand before logging off.
# Either way a finished install must leave nothing armed, or the next logon reopens a window on an
# install that is already done.
assert_ne "win-resume:something-was-armed-to-begin-with" "" "$(wine_resume_entry)"
assert_eq "win-resume:nothing-is-left-armed" "" "$(wine_resume_entry_after)"

# AN ALREADY-INSTALLED MACHINE ARMS NOTHING, AND DISARMS WHAT IT FINDS. The clear at :havewsl is
# not for the reboot road -- Windows has already cleared that one -- it is for the student who
# re-ran the file by hand in the same session. Without it they get a window at the next logon
# running a setup that finished an hour ago.
#
# THE ENTRY IS SEEDED FIRST, AND MUTATION TESTING IS WHY. This case used to arrange nothing and
# assert that the clear had been CALLED, counted off argv.log -- and a fake whose clear removed
# nothing left it green, because a call that does nothing is still a call. The seeded value and
# the before/after pair are what make it an assertion about the effect: something was armed
# going in, and nothing is armed coming out.
wine_new
wine_list CS193V
wine_arm_resume 'C:\windows\System32\cmd.exe /s /c ""Z:\tmp\case\Downloads\install-cs193v-windows.cmd""'
wine_run
assert_eq "win-resumeclear:exits-zero" "0" "$WINE_RC"
assert_ne "win-resumeclear:something-was-armed-to-begin-with" "" "$(wine_resume_entry_before)"
assert_eq "win-resumeclear:the-stale-entry-is-gone" "" "$(wine_resume_entry)"
assert_eq "win-resumeclear:clears-the-entry-exactly-once" "1" \
          "$(wine_argv_count 'powershell\.exe .*Remove-ItemProperty')"

# ...AND A MACHINE THAT HAD NOTHING ARMED ARMS NOTHING. The pair matters: the case above cannot
# tell "cleared it" from "never wrote one" on its own, and this one cannot tell "wrote nothing"
# from "wrote one and cleared it". Together they pin both.
wine_new
wine_list CS193V
wine_run
assert_eq "win-resumeclear:nothing-was-armed-to-begin-with" "" "$(wine_resume_entry_before)"
assert_eq "win-resumeclear:arms-nothing-when-there-is-nothing-to-resume" "" "$(wine_resume_entry)"

# ─── waiting for the network before the download ──────────────────────────────
#
# A RunOnce entry fires EARLY at logon -- earlier than the Startup group, which Windows is
# documented as deliberately delaying -- and the next thing on this road pulls about 600 MB. A
# laptop whose Wi-Fi has not associated yet would fail into :distrofailed, which guesses at a WSL
# version, and printing a wrong cause over a correct one is issue #112 exactly.
#
# WHAT THIS TIER CAN SEE IS THE BRANCH AND NOT THE WAIT. The container runs --network=none and no
# case may pay two minutes, so fake-powershell answers instantly. The deadline, the attempt floor
# and the gap between tries are held by 25-installer.sh as text and by a MANUAL.md row.
wine_new
wine_list
wine_knob net.reachable 0
wine_run
assert_ne   "win-nonet:does-not-exit-zero" "0" "$WINE_RC"
assert_says "win-nonet:says-the-network-is-unreachable" "could not reach the internet" "$WINE_OUT"
# THE REMEDY IS WHAT KEEPS A BOUNDED WAIT FROM BEING A REFUSAL. A probe has a blind spot the real
# download may not, so the one thing this arm must never do is send a working machine away.
assert_says "win-nonet:tells-them-to-run-it-again" "rerun the installer" "$WINE_OUT"
# AND IT STOPS BEFORE SPENDING THE DOWNLOAD. Asserted because a wait that warned and carried on
# would satisfy every line above.
assert_eq   "win-nonet:downloads-nothing" "0" "$(wine_argv_count '\-\-install -d')"
assert_eq   "win-nonet:does-not-even-update-wsl" "0" "$(wine_argv_count 'wsl\.exe --update$')"

# ...AND THE WAIT IS ASKED ONCE ON THE ROAD THAT NEEDS IT AND NOT AT ALL ON THE ONE THAT DOES NOT.
# A student whose environment already exists is downloading nothing here and must pay nothing.
wine_new
wine_list
wine_run
assert_eq "win-netwait:asks-once-before-creating" "1" \
          "$(wine_argv_count 'powershell\.exe .*Invoke-WebRequest')"
wine_new
wine_list CS193V
wine_run
assert_eq "win-netwait:asks-nothing-when-the-environment-exists" "0" \
          "$(wine_argv_count 'powershell\.exe .*Invoke-WebRequest')"

# ─── CLASS: a download folder that already holds hostile executables ──────────
#
# ISSUE #125, and the only case in this file that asserts a security property by EXECUTING rather
# than by reading the source. The installer's working directory is the download folder, and cmd.exe
# searches that directory BEFORE %PATH% -- so a wsl.exe, reg.exe, where.exe or powershell.exe
# already sitting in Downloads was what ran. Downloads is the likeliest place on a real machine for
# an untrusted file to already be, and wsl.exe had nineteen call sites, one of them the handoff to
# stage two.
#
# "WITH ADMINISTRATOR RIGHTS" USED TO END THAT SENTENCE, and the case is not weaker without it.
# The installer required elevation then, so a planted program ran elevated; it now refuses an
# elevated run, so one would run as the student. Smaller consequence, identical hole -- their whole
# account, their WSL environment, and the fetch that executes stage two -- and the elevated path
# still exists, since :installwsl starts a `cmd /c` carrying two program names. Full paths are what
# carry the property either way, which is what this case executes.
#
# IT WAS RED BEFORE THE FIX AND IS GREEN AFTER IT, which is the whole reason it exists rather than
# leaving the property to 25-installer.sh's static rule. It also inverts what this harness used to
# do: lib/wine.sh copied the fakes into this very folder and relied on being found first, so the
# tier DEPENDED on the defect -- and once the calls were qualified it would have gone on reporting
# green while executing none of the installer's real decisions.
#
# WHAT IT DOES NOT PROVE. wine is not Windows, and it appears to ignore
# NoDefaultCurrentDirectoryInExePath -- which is precisely what makes this case worth having,
# because it means the green below measures the QUALIFICATION and not that guard. Were it the other
# way round the case could not go red at all. MANUAL.md carries the check on a real machine.
wine_new
wine_list CS193V
wine_plant_hijack
wine_run
# THE NEGATIVE, which is the point of the case.
assert_eq   "win-hijack:the-planted-binaries-never-run" "0" "$(wine_argv_count 'HIJACKED')"
# ...AND THE POSITIVES THAT STOP IT PASSING VACUOUSLY. A count of zero is an ABSENCE, and a run
# where the installer died on its first line -- or where the fakes were never found in system32 at
# all -- produces exactly the same zero. So the same case asserts that the real programs DID run
# and that the install went all the way through. Together those say the installer did its whole
# job while never reaching any of the planted copies; either one alone says much less.
#
# MEASURED AGAINST THE UNFIXED INSTALLER, which is what makes the split above worth the words: 8
# planted binaries ran and 0 real ones did -- the hostile copies displaced them completely -- and
# `exits-zero` and `hands-off-to-bash-once` BOTH STILL PASSED, because a hostile wsl.exe is
# handed the same arguments and the transcript looks like a clean install. So the two counts are
# the only assertions here that can see the defect, and neither is redundant.
assert_ne   "win-hijack:the-real-programs-did-run"      "0" "$(wine_argv_count '^wsl\.exe ')"
assert_eq   "win-hijack:exits-zero"                     "0" "$WINE_RC"
assert_eq   "win-hijack:hands-off-to-bash-once"         "1" "$(wine_argv_count '\-e env CS193V_WINDOWS=1 bash /var/tmp/install-cs193v.sh')"
assert_says_not "win-hijack:no-unrecognised-command"    "recognize" "$WINE_OUT$WINE_ERR"

# ─── CLASS: the Start Menu, which is an EFFECT and not a decision  (#134, #270) ─
#
# THE SECOND CASE IN THIS FILE THAT ASSERTS ON WHAT IS ON THE MACHINE AFTERWARDS rather than on a
# transcript or an argv count, and it is here for the same reason win-hijack is: the property
# cannot be read off the source. #270's defect was one wrong directory in a string that named the
# right filename and guarded on the right target, so every static assertion about it compared
# that string against itself and passed.
#
# WHAT MADE IT UNREACHABLE, WHICH IS THE PART WORTH NOT REPEATING. #134 added both PowerShell
# calls without touching this file or fixtures/win-fakes/, and three separate things then stopped
# any of it from running: the icon copy reads a \\wsl.localhost path and wine does not implement
# UNC, so `copy` failed first; fake-powershell.c dispatched on neither marker, so both calls
# would have returned its 120; and the .cmd checks PSLNK's code, so the run would have taken
# :shortcutfailed even had the copy worked. The tier reported 213 pass 1 fail, and the one fail
# was win-ok:no-stderr-noise carrying `Path not found.` -- which reads as harness noise rather
# than as a block nothing entered. lib/wine.sh's wine_hide_shim_icon has the measurement.
#
# THE WHOLE SEQUENCE IS THE FIXTURE, AND NOTHING PLANTS THE ENTRY UNDER TEST. This case starts
# with NO environment registered, so the .cmd creates one -- and it is the fake's own `--install`
# arm that writes the Start Menu entry, at the path Windows writes it to. So what the delete
# finds is what a create produced, which is the same standard win-ok:restarts-between-the-two-
# passes holds the provisioning order to.
wine_new
wine_list                               # nothing registered yet: this run creates it
# TWO ENTRIES THAT MUST SURVIVE, and each rules out a different way of passing. Another
# distribution's entry says the delete named a file rather than emptying a directory; a longer
# name beginning with this one says it named it exactly rather than by prefix -- which is not
# idle, because `-match` is a REGEX operator and the obvious wrong spelling of this whole step
# is `Get-ChildItem | Where-Object Name -match $env:DISTRO`.
#
# NEITHER OF THESE TESTS THE TARGET GUARD, and an earlier draft claimed the second one did.
# Measured: with `-match 'wsl'` removed from the .cmd altogether the tier stayed at 231 pass 0
# fail, because the delete only ever opens %DISTRO%.lnk and neither of these entries is at that
# path. The guard has a case of its own below, where the decoys ARE at the two paths.
wine_plant_lnk 'Ubuntu.lnk'        'C:\Program Files\WSL\wsl.exe'
wine_plant_lnk 'CS193V-notwsl.lnk' 'C:\Windows\notepad.exe'
# AND ONE IN THE APP LIST, which is where the delete used to look and the only place it looked.
# With the fix it checks both, so this one goes too -- and it is what would go red if a later
# change swapped one directory for the other instead of adding the second.
wine_plant_lnk 'Programs/CS193V.lnk' 'C:\Program Files\WSL\wsl.exe'
wine_run
assert_eq   "win-lnk:exits-zero"            "0" "$WINE_RC"
assert_eq   "win-lnk:no-stderr-noise"       ""  "$WINE_ERR"
# THE BLOCK WAS ENTERED AT ALL, asserted before anything about its results. Every assertion
# below is an absence or a presence in a directory tree, and :shortcutfailed produces a tree
# that satisfies several of them for the wrong reason.
assert_says_not "win-lnk:does-not-report-the-entry-as-failed" "could not be created" "$WINE_OUT"
assert_eq   "win-lnk:creates-the-entry-once" "1" \
            "$(wine_argv_count 'powershell\.exe .*CreateShortcut.*\.Save\(\)')"
assert_eq   "win-lnk:runs-the-delete-once"   "1" \
            "$(wine_argv_count 'powershell\.exe .*Remove-Item\b')"
# ─── and now the tree itself ───────────────────────────────────────────────────
# OURS IS IN THE APP LIST. %LNKDIR% is what puts it in "All apps"; the root is not enumerated
# there on Windows 11, so an entry written to %SMDIR% would be one a student cannot find.
assert_eq "win-lnk:writes-the-course-entry-to-the-app-list" "yes" \
          "$(wine_lnk_has 'Programs/CS193V Development Environment.lnk')"
assert_contains "win-lnk:the-course-entry-targets-wsl" "wsl.exe" \
          "$(wine_lnk_target 'Programs/CS193V Development Environment.lnk')"
# AND WSL'S OWN IS GONE. This is the assertion #270 is about: it is red against the shipped
# .cmd, whose delete reads %LNKDIR% and therefore never looks here at all.
assert_eq "win-lnk:removes-the-entry-wsl-made-for-itself" "no" \
          "$(wine_lnk_has 'CS193V.lnk')"
assert_eq "win-lnk:also-removes-one-left-in-the-app-list" "no" \
          "$(wine_lnk_has 'Programs/CS193V.lnk')"
# THE THREE THINGS IT MUST NOT TOUCH.
assert_eq "win-lnk:leaves-another-distros-entry-alone" "yes" "$(wine_lnk_has 'Ubuntu.lnk')"
assert_eq "win-lnk:matches-the-name-exactly-not-by-prefix" "yes" \
          "$(wine_lnk_has 'CS193V-notwsl.lnk')"
# The empty folder `wsl --install` makes beside its shortcut, which is the thing that made the
# wrong directory look like the right one. A student may have put something in it since.
assert_eq "win-lnk:leaves-the-empty-folder-wsl-made" "yes" "$(wine_lnk_has 'Programs/CS193V/')"

# ─── THE TARGET GUARD, at the two paths where it can actually be consulted ─────
#
# WHY THIS NEEDS A CASE OF ITS OWN. The delete opens exactly %SMDIR%\%DISTRO%.lnk and
# %LNKDIR%\%DISTRO%.lnk, so `-match 'wsl'` can only ever change the outcome for an entry AT one
# of those two paths -- and in the case above both of them hold something WSL made, which the
# guard is supposed to accept. A decoy anywhere else cannot go red when the guard is broken, and
# one placed here would have to displace the entry whose removal that case exists to check.
#
# SO THE ENVIRONMENT ALREADY EXISTS HERE. With CS193V registered the .cmd skips :makedistro, the
# fake's --install arm never runs, and both paths are free for a decoy that must survive. That is
# also a real machine: a student who had renamed or retargeted these by hand, or a future WSL
# that writes something else there, must not have it deleted on the strength of its filename.
#
# MEASURED IN BOTH DIRECTIONS, because a guard can fail two ways and the wrong one is the one
# that deletes a student's file. `-match ''` is true for every string: with it, both assertions
# below go red. `-match 'zzz'` is true for none: with that, win-lnk:removes-the-entry-wsl-made-
# for-itself in the case above goes red instead. Neither mutation touches the other's case.
wine_new
wine_list CS193V
wine_plant_lnk 'CS193V.lnk'          'C:\Windows\notepad.exe'
wine_plant_lnk 'Programs/CS193V.lnk' 'C:\Windows\notepad.exe'
wine_run
assert_eq "win-lnk-guard:exits-zero"      "0" "$WINE_RC"
assert_eq "win-lnk-guard:runs-the-delete" "1" \
          "$(wine_argv_count 'powershell\.exe .*Remove-Item\b')"
assert_eq "win-lnk-guard:leaves-a-non-wsl-entry-in-the-root" "yes" \
          "$(wine_lnk_has 'CS193V.lnk')"
assert_eq "win-lnk-guard:leaves-a-non-wsl-entry-in-the-app-list" "yes" \
          "$(wine_lnk_has 'Programs/CS193V.lnk')"

# ...AND THE ARM WHERE THE ENTRY CANNOT BE MADE, which is what stops the case above passing for
# a reason other than the one it claims: with the icon gone the .cmd takes :shortcutfailed, so
# the same tree assertions come out the other way and the install still succeeds.
#
# THE SIGN-OFF IS NOT ASSERTED HERE, for the reason win-ok gives: course-install.sh prints it
# inside WSL, and this file's half of #218 is the handover. What is asserted is the one line the
# .cmd itself prints on this arm, and that a failed shortcut does not fail the install.
wine_new
wine_list CS193V
wine_hide_shim_icon
wine_run
assert_eq   "win-lnk-noicon:still-exits-zero"      "0" "$WINE_RC"
assert_says "win-lnk-noicon:says-the-entry-failed" "could not be created" "$WINE_OUT"
assert_says "win-lnk-noicon:points-back-at-the-typed-commands" "commands shown above" "$WINE_OUT"
assert_eq   "win-lnk-noicon:writes-no-course-entry" "no" \
            "$(wine_lnk_has 'Programs/CS193V Development Environment.lnk')"
assert_eq   "win-lnk-noicon:never-reaches-the-delete" "0" \
            "$(wine_argv_count 'powershell\.exe .*Remove-Item\b')"

# ─── the two staff overrides, proved on the command line  (#280) ──────────────
#
# WHAT THESE ARE FOR. Testing the Windows installer against a working tree means two things have
# to come from somewhere other than GitHub: stage two, which the .cmd fetches by URL, and the
# course tarball, which stage two fetches for itself. CS193V_INSTALLER_URL and CS193V_TARBALL are
# those two switches, and both cross the Windows/Linux boundary on a wsl.exe command line.
#
# WHY THEY ARE DRIVEN HERE RATHER THAN LEFT TO A STATIC CHECK. 25-installer.sh pins the SOURCE
# TEXT of the two hand-over lines, which proves %XENV% is written in the right place and nothing
# more. Whether cmd.exe expands it into an argument wsl.exe really receives is a runtime question,
# and argv.log is the only thing that can answer it. This project has twice refused an unexercised
# fallback as "a path that rots"; a staff escape hatch that silently stopped working is the same
# defect with a smaller audience.
#
# WHAT THEY CANNOT SHOW, said plainly. fake-wsl's bash arm never executes the fetched bootstrap --
# it checks that stage2.sh exists, prints a boundary marker and returns a knob -- and its curl arm
# serves stage2.src whatever URL it is handed. So the EFFECT of either variable is out of reach
# here by design, and is covered where it can be: 25-installer.sh drives CS193V_TARBALL through
# the real bootstrap, and 26-installer-sandbox.sh drives it through a real download.

# ── the tarball override rides on both hand-over lines ──
wine_new
wine_list CS193V
wine_env CS193V_TARBALL /mnt/c/Users/student/Downloads/course.tar.gz
wine_run
assert_eq   "win-tarball:exits-zero" "0" "$WINE_RC"
# ONE PER PASS, AND BOTH SPELLED OUT, because the two lines are edited separately and a %XENV%
# dropped from either is a by-hand test that silently downloads from GitHub for half the install.
assert_eq "win-tarball:the-root-pass-carries-it" "1" \
          "$(wine_argv_count '\-e env CS193V_TARBALL=/mnt/c/Users/student/Downloads/course\.tar\.gz CS193V_PROVISION=1 bash /var/tmp/install-cs193v\.sh')"
assert_eq "win-tarball:the-student-pass-carries-it" "1" \
          "$(wine_argv_count '\-e env CS193V_TARBALL=/mnt/c/Users/student/Downloads/course\.tar\.gz CS193V_WINDOWS=1 bash /var/tmp/install-cs193v\.sh')"
# AND IT IS PREPENDED, not substituted: the switch each pass already carried must still be there,
# which the two needles above assert by naming both tokens in one string. This is the separate
# claim that neither pass acquired the OTHER pass's switch on the way through.
assert_eq "win-tarball:the-two-passes-stay-distinct" "0" \
          "$(wine_argv_count 'CS193V_PROVISION=1.*CS193V_WINDOWS|CS193V_WINDOWS.*CS193V_PROVISION')"
assert_eq "win-tarball:no-stderr-noise" "" "$WINE_ERR"

# ── the stage-two override replaces the URL curl is given ──
# A file:// URL, which is the shape a by-hand test uses: curl inside the distro takes it, so the
# real download path runs against a file on the Windows drive. The fake serves stage2.src whatever
# it is asked for, so what is asserted is the URL it was ASKED for.
wine_new
wine_list CS193V
wine_env CS193V_INSTALLER_URL 'file:///mnt/c/Users/student/Downloads/install-cs193v.sh'
wine_run
assert_eq   "win-url:exits-zero" "0" "$WINE_RC"
assert_eq   "win-url:downloads-once" "1" "$(wine_argv_count '\-e curl -fsSL')"
assert_eq   "win-url:curl-is-given-the-override" "1" \
            "$(wine_argv_count '\-o /var/tmp/install-cs193v\.sh file:///mnt/c/Users/student/Downloads/install-cs193v\.sh$')"
assert_eq   "win-url:github-is-not-asked-at-all" "0" \
            "$(wine_argv_count 'raw\.githubusercontent\.com')"
# AND THE STUDENT IS TOLD. The .cmd echoes %INSTALLER_URL% while it downloads, so the override
# announces itself with no code of its own -- the same reason install-cs193v.sh prints a banner.
assert_says "win-url:the-transcript-names-the-override" \
            "file:///mnt/c/Users/student/Downloads/install-cs193v.sh" "$WINE_OUT"
assert_says_not "win-url:and-does-not-still-name-github" "raw.githubusercontent.com" "$WINE_OUT"
assert_eq   "win-url:no-stderr-noise" "" "$WINE_ERR"

# ─── decision coverage, reported rather than assumed ──────────────────────────
# What this checks is that every branch target in the file was reached by some case above, and
# the count is derived from the .cmd rather than from a number typed here.
LABELS="$(sed 's/\r$//' "$PRIVATE/install-cs193v-windows.cmd" \
          | sed -n 's/^:\([a-z][a-z0-9]*\)[[:space:]]*$/\1/p' | sort -u)"
record "windows:branch-targets-in-the-file" "$(printf '%s' "$LABELS" | do_tr '\n' ' ')"
