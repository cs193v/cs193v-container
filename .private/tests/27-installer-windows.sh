#!/usr/bin/env bash
# TIER: windows
#
# install-cs193v-windows.cmd, EXECUTED -- on Linux, with no Windows anywhere.
#
# `windows` is not in DEFAULT_TIERS (run-tests.sh:64) and lane_of() sends an unrecognised tier to
# the serialised podman lane, so this needs no change to the runner and never runs on a default
# invocation. That is deliberate: the fixture carries wine, which is ~2.2 GB.
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
    "$(awk -F'\t' '!/^#/ && NF==3 && $2 !~ /^[ABCD]$/ {print $1 " has tier " $2}' "$MSGFILE")"
# The fakes must hold no prose of their own -- that is what makes the table auditable.
assert_eq "windows:fakes-hold-no-prose" "" \
    "$(grep -nE '(printf|fputs)\s*\(\s*"[A-Z][a-z]+ [a-z]' "$FIXTURE_DIR"/win-fakes/fake-*.c || true)"

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
assert_says "win-name:blames-the-wsl-version"    "Naming a new environment needs WSL" "$WINE_OUT"
assert_says "win-name:asks-for-wsl-version"      "wsl --version" "$WINE_OUT"
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
    assert_says "win-$knob:says-it-is-safe-to-retry" "safe to run this file again" "$WINE_OUT"
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
wine_new
wine_list CS193V
wine_knob ps.rc 9009                   # powershell missing: cmd's own not-found code
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
