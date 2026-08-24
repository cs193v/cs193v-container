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
    "$(awk -F'\t' '!/^#/ && NF==3 && $2 !~ /^[ABC]$/ {print $1 " has tier " $2}' "$MSGFILE")"
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
assert_eq   "win-ok:hands-off-to-bash-once"       "1" "$(wine_argv_count 'wsl.exe .*-e bash')"
assert_eq   "win-ok:never-creates-an-existing-distro" "0" "$(wine_argv_count '\-\-install -d')"

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

# ─── CLASS: a captured value must be validated before use ─────────────────────
#
# Defect 3. wsl.exe writes its ERRORS TO STDOUT, and a `for /f` backtick discards the exit code,
# so "There is no distribution with the supplied name." arrived looking exactly like an answer and
# was handed to bash as a filename.
wine_new
wine_list CS193V
wine_knob wsl.wslpath.rc -1
wine_run
assert_ne   "win-wslpath:does-not-exit-zero"      "0" "$WINE_RC"
assert_says "win-wslpath:admits-it-cannot-locate-the-folder" "Could not work out where" "$WINE_OUT"
assert_eq   "win-wslpath:never-runs-bash"         "0" "$(wine_argv_count 'wsl.exe .*-e bash')"
assert_says_not "win-wslpath:does-not-claim-success" "Done. From now on" "$WINE_OUT"

# The subtler half: exit 0 with prose on stdout. The exit-code check cannot catch that, so the
# absolute-path check has to.
for bogus in "There is no distribution with the supplied name." "" "C:\\not\\a\\linux\\path"; do
    wine_new
    wine_list CS193V
    wine_knob wsl.wslpath.out "$bogus"
    wine_run
    assert_eq "win-bogus:never-hands-a-non-path-to-bash" "0" "$(wine_argv_count 'wsl.exe .*-e bash')"
    assert_says_not "win-bogus:does-not-claim-success" "Done. From now on" "$WINE_OUT"
done

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
for dir in "Downloads" "My Downloads" "Down!loads" "Down&loads" "cs193v (1)" "a(b)c" "it's mine"; do
    wine_new "$dir"
    wine_list CS193V
    wine_run
    assert_eq   "win-path[$dir]:succeeds"          "0" "$WINE_RC"
    assert_says "win-path[$dir]:says-it-is-done"   "Done. From now on" "$WINE_OUT"
    assert_says_not "win-path[$dir]:no-syntax-error"   "unexpected" "$WINE_OUT$WINE_ERR"
    assert_says_not "win-path[$dir]:no-unrecognised-command" "recognize" "$WINE_OUT$WINE_ERR"
done

# And the same folders on the path that PRINTS the folder name, which is where the original broke:
# `echo   into %HERE% and run this again.` inside a parenthesized block.
for dir in "cs193v (1)" "Down&loads" "Down!loads"; do
    wine_new "$dir"
    wine_list CS193V
    wine_no_sibling
    wine_run
    assert_ne   "win-missing[$dir]:refuses"        "0" "$WINE_RC"
    assert_says "win-missing[$dir]:names-the-missing-file" "Could not find install-cs193v.sh" "$WINE_OUT"
    assert_says "win-missing[$dir]:says-both-must-be-together" "same folder" "$WINE_OUT"
    assert_says_not "win-missing[$dir]:no-syntax-error" "unexpected" "$WINE_OUT$WINE_ERR"
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
