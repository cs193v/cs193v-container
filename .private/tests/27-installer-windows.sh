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
SB_TMP="$WINE_TMP"                    # fixture_build logs its build output here
trap 'rm -rf "$WINE_TMP"' EXIT

wine_require || { skip "windows:fixture" "podman or the wine fixture is unavailable"; exit 0; }

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
assert_says "win-ok:says-it-is-done"              "Done. From now on you work inside" "$WINE_OUT"
assert_says "win-ok:tells-them-where-projects-are" "wsl.localhost" "$WINE_OUT"
# The defect itself. assert_says matches with a shell glob, so the placeholder is asserted
# without its brackets -- `[...]` would be a character class matching one character.
#
# TWO assertions, because there are two things to be sure of: that the line SURVIVED at all (the
# original printed nothing here, since cmd extracted `<your-linux-username>` as redirection before
# echo ran), and that the angle-bracket form has not come back.
# ONE assertion, on the bracket form, and deliberately not a pair. Measured against the original:
# an assert_says_not for "<your-linux-username>" PASSES there -- not because the angle brackets are
# gone but because cmd ate the entire line, so there is nothing to match either way. A negative
# assertion about a line that may not exist is worthless. assert_match takes an ERE, where the
# brackets can be escaped, so this demands the real text be PRESENT and in the safe form.
assert_match "win-ok:the-projects-path-survives-echo" \
             'wsl\.localhost.CS193V.home.\[your-linux-username\].cs193v.projects' "$WINE_OUT"
assert_eq   "win-ok:no-stderr-noise"              "" "$WINE_ERR"
# Pinned to the exact path now, not just `-e bash`: the handoff argument is a constant this file
# owns, so there is no reason to accept any other one.
assert_eq   "win-ok:hands-off-to-bash-once"       "1" "$(wine_argv_count '\-e bash /tmp/install-cs193v.sh')"
assert_eq   "win-ok:never-creates-an-existing-distro" "0" "$(wine_argv_count '\-\-install -d')"

# ─── stage two is FETCHED, and the machine it is fetched into is checked first ──
#
# The four calls of the handoff, each asserted once so an extra or missing one is a failure
# rather than a detail. The apt count is the one that is easy to leave out: without it, a .cmd
# that ran `apt-get update` on every single launch -- on a file whose own header promises it is
# safe to run any number of times -- would pass everything else here.
assert_eq   "win-ok:probes-for-curl-once"         "1" "$(wine_argv_count '\-e curl --version')"
assert_eq   "win-ok:does-not-apt-when-curl-is-there" "0" "$(wine_argv_count 'apt-get')"
assert_eq   "win-ok:downloads-once"               "1" "$(wine_argv_count '\-e curl -fsSL')"
assert_eq   "win-ok:checks-the-download-once"     "1" "$(wine_argv_count '\-e grep ')"
assert_says "win-ok:names-the-url-it-fetches"     "raw.githubusercontent.com/cs193v/cs193v-container/main" "$WINE_OUT"
assert_says "win-ok:says-where-it-left-the-script" "/tmp/install-cs193v.sh" "$WINE_OUT"

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
    assert_says     "win-status-$rc:offers-to-install-wsl"           "Installing WSL" "$WINE_OUT"
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
assert_says_not "win-novm-create:does-not-claim-success"   "Done. From now on" "$WINE_OUT"
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
assert_says_not "win-create-novirt-quiet:does-not-claim-success" "Done. From now on" "$WINE_OUT"

# 5c. IT EXITS ZERO HAVING DONE NOTHING. `wsl --install -d` enables a component, prints the reboot
#     notice, installs NOTHING and returns ZERO (WslClient.cpp:544-611) -- no error to read at
#     all. The re-probe after the create is the only thing that catches it, and that is unchanged.
wine_new
wine_list
wine_knob wsl.install.rebootrequired 1
wine_run
assert_ne   "win-rebootrequired:does-not-exit-zero"         "0" "$WINE_RC"
assert_says_not "win-rebootrequired:does-not-claim-success"  "Done. From now on" "$WINE_OUT"
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
assert_says_not "win-novm-existing:does-not-invite-a-retry"    "safe to run this file again" "$WINE_OUT"
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
assert_says_not "win-existing-quiet:does-not-invite-a-retry"     "safe to run this file again" "$WINE_OUT"
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

# Creating the environment, and the on-screen promise it makes while doing so. The warning text
# is the installer's OWN words, so it is fair to pin: it tells the student how many questions to
# expect and that they must type `exit` to carry on, and both were wrong or missing before --
# `wsl --install` LAUNCHES the distro and leaves them at a Linux prompt with no instruction.
#
# Canonical's actual OOBE wording is NOT asserted anywhere. The fake replays it so a person can
# see it in win-sandbox.sh, but it belongs to another project and moves with wsl-setup, so
# pinning it here would punish the wrong change.
wine_new
wine_list                              # nothing registered yet
wine_run
assert_eq   "win-create:succeeds"                  "0" "$WINE_RC"
assert_says "win-create:says-it-is-creating"       "Creating the CS193V Linux environment" "$WINE_OUT"
assert_says "win-create:warns-about-the-username"  "a username" "$WINE_OUT"
assert_says "win-create:warns-about-the-password"  "a password to go with it" "$WINE_OUT"
assert_says "win-create:warns-about-the-third-question" "anonymous usage reports" "$WINE_OUT"
assert_says "win-create:tells-them-to-type-exit"   "TYPE exit AND PRESS ENTER" "$WINE_OUT"
assert_says "win-create:then-reports-it-ready"     "environment is ready" "$WINE_OUT"
assert_eq   "win-create:creates-it-once"           "1" "$(wine_argv_count '\-\-install -d')"
assert_says "win-create:says-it-is-done"           "Done. From now on" "$WINE_OUT"

# The same class at the distro-creation call, which is the one that mattered most: its exit code
# is the LAUNCHED SHELL'S, not the install's, so it cannot be trusted in either direction. The
# installer re-probes instead, and these two cases pin both halves of that.
wine_new
wine_list                              # nothing registered
wine_knob wsl.name.unsupported 1       # WSL < 2.5.8: no --name at all, exits -1
wine_run
assert_ne   "win-name:does-not-exit-zero"        "0" "$WINE_RC"
assert_says "win-name:offers-the-wsl-version-as-a-cause" "older than 2.5.8" "$WINE_OUT"
assert_says "win-name:asks-for-wsl-version"      "wsl --version" "$WINE_OUT"
# AND IT MUST NOT ASSERT IT. The message names one likely cause out of several, which is the whole
# defect in issue #112 -- a machine that could not run a VM at all was told this and only this.
assert_says "win-name:says-it-is-a-guess"        "a guess" "$WINE_OUT"
# AND IT MUST HAVE TRIED. This is the one cause :distrofailed names, and the file used to name it
# without ever running the command that fixes it -- `wsl --update` was on the no-WSL-at-all arm
# only, so a student with an old-but-working WSL was told to check a version nobody had offered
# to raise. Counted rather than asserted as prose: the message could say anything.
assert_eq   "win-name:tried-to-update-first"     "1" "$(wine_argv_count '\-\-update')"
assert_says_not "win-name:does-not-claim-success" "Done. From now on" "$WINE_OUT"

# A shell that exits nonzero after a SUCCESSFUL install must not be reported as a failed install.
wine_new
wine_list
wine_knob wsl.install.rc 1             # the student mistyped something, then typed `exit`
wine_run
assert_eq   "win-shellrc:still-succeeds"          "0" "$WINE_RC"
assert_says "win-shellrc:says-it-is-done"         "Done. From now on" "$WINE_OUT"
assert_says_not "win-shellrc:does-not-blame-the-wsl-version" "may not support" "$WINE_OUT"

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
assert_eq   "win-nocurl:then-hands-off-to-bash"    "1" "$(wine_argv_count '\-e bash ')"
assert_says "win-nocurl:says-it-is-done"           "Done. From now on" "$WINE_OUT"

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
    assert_says "win-$knob:still-offers-a-retry"   "this file again is enough" "$WINE_OUT"
    assert_says "win-$knob:bounds-the-retry"       "it is something" "$WINE_OUT"
    assert_eq   "win-$knob:never-downloads"        "0" "$(wine_argv_count '\-e curl -fsSL')"
    assert_eq   "win-$knob:never-runs-bash"        "0" "$(wine_argv_count '\-e bash ')"
    assert_says_not "win-$knob:does-not-claim-success" "Done. From now on" "$WINE_OUT"
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
assert_says_not "win-aptlied:does-not-claim-success" "Done. From now on" "$WINE_OUT"

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
    assert_says "win-dl-$rc:says-it-is-safe-to-retry" "safe to run this file again" "$WINE_OUT"
    assert_eq   "win-dl-$rc:never-runs-bash"       "0" "$(wine_argv_count '\-e bash ')"
    assert_says_not "win-dl-$rc:does-not-claim-success" "Done. From now on" "$WINE_OUT"
done

# AND THE ONE curl CANNOT REPORT. The fake writes a body with no sentinel in it and exits ZERO,
# which is what a captive portal answering 200 with its own sign-in page looks like from the
# outside: the bytes arrived, they are simply not the installer. Without the sentinel check this
# is the case that ends with bash running a login page and the .cmd printing "Done".
wine_new
wine_list CS193V
wine_knob wsl.curl.truncated 1
wine_run
assert_ne   "win-portal:does-not-exit-zero"        "0" "$WINE_RC"
assert_says "win-portal:says-it-is-not-the-whole-file" "not the whole file" "$WINE_OUT"
assert_says "win-portal:names-the-likely-cause"    "sign-in page" "$WINE_OUT"
assert_eq   "win-portal:never-runs-bash"           "0" "$(wine_argv_count '\-e bash ')"
assert_says_not "win-portal:does-not-claim-success" "Done. From now on" "$WINE_OUT"

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

# The elevation probe, whose old form (`net session`) returned 2 -- not 5 -- when the Server
# service is stopped, reporting a real Administrator as not one. The current probe has no such
# third state, and this pins that it refuses only when it should.
wine_new
wine_list CS193V
wine_knob reg.query.rc 1
wine_run
assert_ne   "win-admin:refuses"                   "0" "$WINE_RC"
assert_says "win-admin:explains-why"              "needs to run as Administrator" "$WINE_OUT"
assert_says "win-admin:says-how-to-fix-it"        "Run as administrator" "$WINE_OUT"
assert_eq   "win-admin:touches-nothing-else"      "0" "$(wine_argv_count 'wsl.exe')"

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
    assert_says "win-path[$dir]:says-it-is-done"   "Done. From now on" "$WINE_OUT"
    assert_says_not "win-path[$dir]:no-syntax-error"   "unexpected" "$WINE_OUT$WINE_ERR"
    assert_says_not "win-path[$dir]:no-unrecognised-command" "recognize" "$WINE_OUT$WINE_ERR"
done

# ─── the reboot arm, and the two calls whose codes used to be ignored ─────────
wine_new
wine_list
wine_knob where.wsl.exe 0              # no wsl.exe on PATH at all
wine_run
assert_eq   "win-nowsl:exits-zero-because-nothing-failed" "0" "$WINE_RC"
assert_says "win-nowsl:tells-them-to-restart"     "RESTART YOUR COMPUTER NOW" "$WINE_OUT"
assert_says "win-nowsl:tells-them-to-rerun"       "run this same file again" "$WINE_OUT"

for knob in wsl.update.rc wsl.feature.rc; do
    wine_new
    wine_list
    wine_knob where.wsl.exe 0
    wine_knob "$knob" -1
    wine_run
    assert_ne "win-$knob:does-not-exit-zero"      "0" "$WINE_RC"
    assert_says_not "win-$knob:does-not-tell-them-to-restart" "RESTART YOUR COMPUTER" "$WINE_OUT"
done

# ─── decision coverage, reported rather than assumed ──────────────────────────
#
# No line-coverage gate: wine's own `@echo on` echoing of `if` statements is broken
# (test_builtins.cmd.exp:138,141), so a trace-based denominator would measure the wrong thing.
# What IS checkable is that every branch target in the file was reached by some case above, so
# the count is derived from the .cmd rather than from a number typed here.
LABELS="$(sed 's/\r$//' "$PRIVATE/install-cs193v-windows.cmd" \
          | sed -n 's/^:\([a-z][a-z0-9]*\)[[:space:]]*$/\1/p' | sort -u)"
record "windows:branch-targets-in-the-file" "$(printf '%s' "$LABELS" | tr '\n' ' ')"
