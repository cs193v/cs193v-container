# shellcheck shell=bash
#
# Shared test driver for the CS193V tmux suite.
#
# THIS FILE RUNS INSIDE THE CONTAINER, NOT ON THE HOST. 65-tmux.sh copies this directory in
# with `podman cp` and runs suite.sh there, so what gets tested is the real installed
# /etc/cs193v/tmux.conf, the image's own tmux and terminfo, and the real /etc/bash.bashrc
# hook -- rather than a copy of the config exercised against whatever tmux the host has.
#
# Two consequences worth knowing:
#   * bash here is the container's bash 5, so the project's bash 3.2 rule does not apply to
#     this directory. It applies to 65-tmux.sh, which is the part that runs on a TA's Mac.
#     10-static.sh says so at the assertion that would otherwise catch this.
#   * `python3`, `pgrep`, `awk` and `od` are all present in the image, so nothing here needs
#     a fallback for a missing tool. If one goes missing the suite should fail loudly.
#
# Forked from the multiplexer prototype's harness/lib.sh; see suite.sh for the divergences.
#
# The trick that makes all of this testable: we run the multiplexer under test inside a
# *separate* tmux instance (on its own socket, its own config, status bar off). That outer
# tmux gives us three things a plain script cannot get:
#
#   1. a real PTY at a fixed, known size (so screen positions are deterministic)
#   2. `send-keys -H`, which writes exact raw bytes to the inner program's PTY -- letting us
#      emulate precisely what macOS Terminal.app vs Windows Terminal would send, including
#      mouse events
#   3. `capture-pane -p -e`, which screenshots the inner program's rendered output *with*
#      its SGR color sequences, so we can assert on both text and legibility
#
# The outer tmux is a measuring instrument only; it is never the thing under test.

HX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# FORK: the prototype prepended a rootless .local-prefix extraction to PATH and fell back to
# a tmux binary bundled inside it. Both are gone. In this container tmux is an apt package at
# a known path, and the whole point of running in here is to test THAT tmux -- a fallback
# that silently picked up a different binary would turn "the image is missing tmux", which is
# a total failure for every student, into a green run.
HX_TMUX="${HX_TMUX:-$(command -v tmux || true)}"
[ -x "$HX_TMUX" ] || { printf 'FAIL\ttmux:harness-found-no-tmux\tno tmux on PATH in the container\n'; exit 1; }

HX_SOCK="${HX_SOCK:-hx-$$}"
HX_W="${HX_W:-100}"
HX_H="${HX_H:-30}"

HX_PASS=0
HX_FAIL=0
HX_SKIP=0
declare -a HX_FAILURES=()

if [ -t 1 ]; then C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else C_G=""; C_R=""; C_Y=""; C_B=""; C_0=""; fi

# shellcheck source=keys.sh
. "$HX_DIR/keys.sh"

# --- assertions -------------------------------------------------------------

# FORK: every result is also written to $HX_TSV as one tab-separated line, so the host-side
# driver (65-tmux.sh) can replay each check through lib/assert.sh's pass/fail/skip. Without
# this the whole suite would collapse into a single pass-or-fail line in the project's
# report, and a failure would name nothing.
#
# The description doubles as the assertion name, slugified into the project's house style --
# "session starts and the tab bar is visible" becomes
# tmux:session-starts-and-the-tab-bar-is-visible. Details are squeezed onto one line,
# because a newline in the middle of a record would be read as the start of a new one.
hx_slug() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' \
    | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//' -e 's/^/tmux:/'
}
hx_emit() { # status desc [detail]
  [ -n "${HX_TSV:-}" ] || return 0
  printf '%s\t%s\t%s\n' "$1" "$(hx_slug "$2")" \
    "$(printf '%s' "${3:-}" | tr '\t\n' '  ' | sed 's/  */ /g')" >> "$HX_TSV"
}

hx_pass() { HX_PASS=$((HX_PASS + 1)); hx_emit PASS "$1"; printf '  %sPASS%s %s\n' "$C_G" "$C_0" "$1"; }
hx_fail() {
  HX_FAIL=$((HX_FAIL + 1))
  HX_FAILURES+=("$1")
  hx_emit FAIL "$1" "${2:-}"
  printf '  %sFAIL%s %s\n' "$C_R" "$C_0" "$1"
  [ -n "${2:-}" ] && printf '       %s\n' "$2"
  return 0
}
hx_skip() { HX_SKIP=$((HX_SKIP + 1)); hx_emit SKIP "$1" "${2:-}"; printf '  %sSKIP%s %s\n' "$C_Y" "$C_0" "$1"; }
hx_note() { printf '       %s\n' "$1"; }

# Section timing, silent unless HX_TIMING is set. This is the only visibility the project has
# into where its slowest suite spends its time -- the suite's own stdout is written to a temp
# file by 65-tmux.sh and thrown away, so a number printed here would never be read. The rows
# go into $HX_TSV instead, and 65-tmux.sh replays them as record() lines.
#
# $EPOCHREALTIME is a bash 5 variable and costs no subprocess. This file may use it freely: it
# runs in the container and never on a TA's Mac, which is the whole reason the directory is
# exempt from the bash 3.2 rule.
HX_SECT=''
HX_SECT_T0=''
_hx_section_end() {
  [ -n "${HX_TIMING:-}" ] || return 0
  [ -n "$HX_SECT" ] || return 0
  hx_emit TIME "section $HX_SECT" \
    "$(awk "BEGIN{printf \"%.1fs\", $EPOCHREALTIME - $HX_SECT_T0}")"
  HX_SECT=''
}
hx_section() {
  _hx_section_end
  HX_SECT="$1"; HX_SECT_T0="$EPOCHREALTIME"
  printf '\n%s== %s%s\n' "$C_B" "$1" "$C_0"
}

hx_expect_contains() { # desc haystack needle
  case "$2" in *"$3"*) hx_pass "$1" ;; *) hx_fail "$1" "expected to find: $3" ;; esac
}
hx_expect_absent() { # desc haystack needle
  case "$2" in *"$3"*) hx_fail "$1" "should NOT contain: $3" ;; *) hx_pass "$1" ;; esac
}
hx_expect_eq() { # desc actual expected
  if [ "$2" = "$3" ]; then hx_pass "$1"; else hx_fail "$1" "got '$2', want '$3'"; fi
}

hx_summary() { # label
  _hx_section_end                     # close the last section, which no hx_section follows
  printf '\n%s---- %s: %s%d passed%s, %s%d failed%s, %d skipped ----%s\n' \
    "$C_B" "${1:-results}" "$C_G" "$HX_PASS" "$C_0$C_B" \
    "$([ "$HX_FAIL" -gt 0 ] && echo "$C_R" || echo "$C_G")" "$HX_FAIL" "$C_0$C_B" "$HX_SKIP" "$C_0"
  if [ "$HX_FAIL" -gt 0 ]; then
    printf '%sFailures:%s\n' "$C_R" "$C_0"
    for f in "${HX_FAILURES[@]}"; do printf '  - %s\n' "$f"; done
    return 1
  fi
  return 0
}

# --- outer tmux control -----------------------------------------------------

hx_tmux() { "$HX_TMUX" -L "$HX_SOCK" -f "$HX_DIR/harness.tmux.conf" "$@"; }

hx_start() { # session command...
  local name="$1"; shift
  hx_tmux kill-session -t "$name" 2>/dev/null
  hx_tmux new-session -d -s "$name" -x "$HX_W" -y "$HX_H" "$@"
  hx_tmux set-option -t "$name" status off >/dev/null 2>&1
}

hx_stop() { hx_tmux kill-session -t "$1" 2>/dev/null; return 0; }
hx_teardown() { hx_tmux kill-server 2>/dev/null; return 0; }

hx_alive() { hx_tmux has-session -t "$1" 2>/dev/null; }

# Is the inner program still running, or has it exited (leaving the pane's shell)?
hx_pane_cmd() { hx_tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null; }

# --- input injection --------------------------------------------------------

# Send exact bytes, given as a space-separated hex string ("1b 74").
hx_hex() { # session hexbytes
  local name="$1"; shift
  # shellcheck disable=SC2086
  hx_tmux send-keys -t "$name" -H $*
}

# Send a literal string as exact bytes (handles ESC, control chars, anything).
hx_str() { # session string
  local name="$1" s="$2" hex
  hex="$(printf '%s' "$s" | od -An -tx1 | tr -s ' \n' ' ')"
  # shellcheck disable=SC2086
  hx_tmux send-keys -t "$name" -H $hex
}

hx_type() { hx_str "$1" "$2"; }
hx_enter() { hx_hex "$1" "$KEY_ENTER"; }
hx_cmd() { hx_str "$1" "$2"; hx_enter "$1"; }   # type a shell command and run it

# --- mouse injection (SGR 1006 protocol, what every modern emulator sends) ---
#
# Coordinates are 1-based, like the wire protocol: row 1 is the top line.
hx_click() { # session row col
  hx_str "$1" "$(printf '\033[<0;%d;%dM' "$3" "$2")"
  hx_str "$1" "$(printf '\033[<0;%d;%dm' "$3" "$2")"
}
hx_wheel_up() { # session row col [count]
  local n="${4:-3}"
  for _ in $(seq "$n"); do hx_str "$1" "$(printf '\033[<64;%d;%dM' "$3" "$2")"; done
}
hx_wheel_down() {
  local n="${4:-3}"
  for _ in $(seq "$n"); do hx_str "$1" "$(printf '\033[<65;%d;%dM' "$3" "$2")"; done
}

# --- screen capture ---------------------------------------------------------

hx_cap() { hx_tmux capture-pane -p -t "$1" 2>/dev/null; }            # plain text
hx_cap_ansi() { hx_tmux capture-pane -p -e -t "$1" 2>/dev/null; }    # text + SGR colors

# --- waiting for something, rather than waiting a while ---------------------
#
# hx_settle pays its full duration whether the screen settled in 50 ms or not, so every one
# of them is a guess in two directions at once: too short and the suite flakes on a slower
# machine, too long and every run pays the difference. But wherever a keystroke has just been
# injected there IS a positive condition to wait for -- the window count went up, the label
# changed, the pane left copy mode -- and hx_wait already proves the shape works for the
# screen. The rest of these do the same for the structure probes.
#
# THE TIMEOUT IS NOT THE COST. It is only reached when the thing never happens, which is when
# the assertion that follows was going to fail anyway. So each ceiling at the call sites is
# set LARGER than the fixed sleep it replaces: the wait is strictly more patient than the old
# one on a slow machine and strictly faster on a fast one.
#
# And none of these replaces an assertion. Every call site still asserts afterwards against a
# freshly read probe, so a wait that times out reports exactly the failure it always did --
# just later. Nothing here can turn a red check green.
HX_POLL=0.05                          # 20 Hz. A tmux client round trip is ~5 ms.

# Once per wait, not once per poll: awk is the only float arithmetic available and a fork per
# tick would cost more than the sleep it is timing.
_hx_polls() { awk "BEGIN{printf \"%d\", ($1) / $HX_POLL}"; }

# Wait until the screen matches an extended regex. Returns 1 on timeout.
hx_wait() { # session regex [timeout_seconds]
  local name="$1" re="$2" i=0 max
  max="$(_hx_polls "${3:-8}")"
  while [ "$i" -lt "$max" ]; do
    if hx_cap "$name" | grep -qE "$re"; then return 0; fi
    sleep "$HX_POLL"
    i=$((i + 1))
  done
  return 1
}

# Wait until a probe reports an expected value. The probe is a command STRING, evaluated the
# same way hx_test_forbidden_keys evaluates its own probe argument.
hx_until() { # 'probe command' expected [timeout_seconds]
  local cmd="$1" want="$2" i=0 max
  max="$(_hx_polls "${3:-8}")"
  while [ "$i" -lt "$max" ]; do
    [ "$(eval "$cmd" 2>/dev/null)" = "$want" ] && return 0
    sleep "$HX_POLL"
    i=$((i + 1))
  done
  return 1
}

# ...or until it reports anything other than what it reported before. NON-EMPTY and different,
# not merely different: a probe answers "" for the moment a window is being created or
# destroyed, and treating that as the change would return before the thing had happened.
hx_until_ne() { # 'probe command' baseline [timeout_seconds]
  local cmd="$1" base="$2" i=0 max out
  max="$(_hx_polls "${3:-8}")"
  while [ "$i" -lt "$max" ]; do
    out="$(eval "$cmd" 2>/dev/null)"
    [ -n "$out" ] && [ "$out" != "$base" ] && return 0
    sleep "$HX_POLL"
    i=$((i + 1))
  done
  return 1
}

# The general case: wait until a command succeeds. For conditions that are not one probe's
# value -- "the clipboard contains COPYME", "the session is gone".
hx_until_ok() { # 'command' [timeout_seconds]
  local cmd="$1" i=0 max
  max="$(_hx_polls "${2:-8}")"
  while [ "$i" -lt "$max" ]; do
    eval "$cmd" >/dev/null 2>&1 && return 0
    sleep "$HX_POLL"
    i=$((i + 1))
  done
  return 1
}

# The other half of hx_wait: something must go AWAY on its own. ONLY for things that expire by
# themselves -- the SCROLLED BACK and COPIED notices, which are `display-message -d 3000`.
# Never for "nothing happened": an absence that was never a presence is not evidence, and the
# checks that prove a forbidden key did nothing keep their fixed sleep for that reason.
hx_gone() { # session regex [timeout_seconds]
  local name="$1" re="$2" i=0 max
  max="$(_hx_polls "${3:-8}")"
  while [ "$i" -lt "$max" ]; do
    hx_cap "$name" | grep -qE "$re" || return 0
    sleep "$HX_POLL"
    i=$((i + 1))
  done
  return 1
}

hx_settle() { sleep "${1:-0.6}"; }

# Locate text on screen. Prints "row col" as 1-based wire coordinates.
hx_find() { # session needle
  hx_cap "$1" | awk -v needle="$2" '
    { i = index($0, needle); if (i > 0 && !found) { print NR, i; found = 1 } }
    END { if (!found) exit 1 }'
}

# --- test fixtures ----------------------------------------------------------
#
# To test "tabs are labeled with the name of the running process" we need a long-lived
# process with a known name. Two traps make this harder than it looks:
#
#   * Ubuntu 26.04 ships uutils (Rust) coreutils, and `/usr/bin/sleep` is a multi-call
#     binary that dispatches on argv[0] -- so a copy of it named `claude` exits instantly
#     instead of sleeping.
#   * A shell script named `claude` is reported by /proc (and therefore by tmux's
#     automatic-rename) as `sh`/`bash`, not `claude`.
#
# So the fixture must be a real ELF binary whose filename is the name we want to see.
# A copy of the python3 interpreter fits: it is a plain executable, and `-c` makes it sit
# still for as long as we like.
# The fixture directory is DERIVED, not stored in a variable. Test suites idiomatically call
# this as FAKEBIN="$(hx_fake_binary claude)", which runs in a command-substitution subshell --
# so any variable the function set would be lost to the caller, and hx_fake_run would then fail
# (or worse, fall back to a bare name). Deriving the path from $$ makes it identical in the
# parent and in any subshell.
hx_fakebin_dir() { printf '%s/hx-fakebin-%s' "${TMPDIR:-/tmp}" "$$"; }
HX_FAKEBIN="$(hx_fakebin_dir)"

hx_fake_binary() { # name -> prints the dir to prepend to PATH
  local d; d="$(hx_fakebin_dir)"
  mkdir -p "$d"
  cp "$(readlink -f "$(command -v python3)")" "$d/$1"
  printf '%s' "$d"
}

# Return a command line that runs the fixture binary and sits still.
#
# ALWAYS ABSOLUTE, AND THIS MATTERS ENORMOUSLY. Invoking the fixture by bare name
# ("claude ...") depends on the inner shell's PATH containing the fixture directory. Inside a
# multiplexer the inner shell frequently re-derives PATH from /etc/profile or ~/.bashrc, so the
# bare name resolves to the student's REAL `claude` CLI instead. When that happened here it:
#   * launched a real Claude Code process (~490MB RSS each) -- with several test suites running
#     in parallel this exhausted system RAM and the OOM killer took out the whole run;
#   * passed the fixture's "-c 'import time; time.sleep(300)'" argument to Claude Code as a
#     PROMPT, which posted that text into the user's live session.
# Do not "simplify" this back to a bare command name.
hx_fake_run() { # name [secs]
  local d; d="$(hx_fakebin_dir)"
  if [ ! -x "$d/$1" ]; then
    printf 'echo "HARNESS ERROR: call hx_fake_binary %s before hx_fake_run %s"' "$1" "$1"
    return 1
  fi
  printf '%s/%s -c "import time; time.sleep(%s)"' "$d" "$1" "${2:-120}"
}

# Belt and braces: assert a test never started the real Claude Code CLI. Call after any test
# that runs a "claude" fixture.
hx_assert_no_real_claude() { # desc
  local p exe bad=0 d
  d="$(hx_fakebin_dir)"
  for p in $(pgrep -x claude 2>/dev/null); do
    exe="$(readlink -f "/proc/$p/exe" 2>/dev/null)"
    case "$exe" in
      "$d"/*) ;;                                # our fixture, fine
      */claude/versions/*|*/.local/share/claude/*) bad=1 ;;
    esac
  done
  if [ "$bad" -eq 1 ]; then
    hx_note "NOTE: a real Claude Code process is running. If this test started it, the fixture"
    hx_note "      is resolving 'claude' from PATH instead of \$HX_FAKEBIN -- see hx_fake_run."
  fi
  return 0
}

# CRITICAL: putting the fixture dir on PATH in the multiplexer's environment is NOT enough.
# The pane's shell reads ~/.bashrc, which on a normal machine PREPENDS ~/.local/bin -- where a
# real `claude` lives. The fixture then loses the lookup and the test silently launches the
# REAL Claude Code instead, which looks like a pass (the tab really is named "claude") while
# testing nothing, burning API calls, and leaving a window that will not close.
#
# Always claim the name from inside the pane and assert you got the fixture.
hx_use_fixture() { # session fixture_dir name
  local name_sess="$1" dir="$2" name="$3" out
  # Both commands are sent without waiting between them: send-keys writes to the pty and the
  # line discipline queues the second line until the shell asks for it, so the ordering is the
  # kernel's problem rather than ours. What has to be waited for is the OUTPUT of the second
  # one, which is the thing the capture below reads.
  hx_cmd "$name_sess" "export PATH=$dir:\$PATH; hash -r"
  hx_cmd "$name_sess" "command -v $name"
  hx_until_ok "hx_cap $name_sess | grep -qF '$dir/$name'" 6 || true
  out="$(hx_cap "$name_sess")"
  case "$out" in
    *"$dir/$name"*) hx_pass "fixture '$name' resolves to the test copy, not a real install" ;;
    *) hx_fail "fixture '$name' resolves to the test copy, not a real install" \
               "'command -v $name' did not report $dir/$name -- a real $name may shadow it" ;;
  esac
}

# --- legibility -------------------------------------------------------------

hx_check_colors() { # session label [extra screencheck args...]
  local name="$1" label="$2"; shift 2
  local out rc
  out="$(hx_cap_ansi "$name" | python3 "$HX_DIR/screencheck.py" --label "$label" "$@" 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -eq 0 ]; then hx_pass "legible: $label"; else hx_fail "legible: $label"; fi
}

# --- R1: prove no other keybinding does anything ----------------------------
#
# Takes a "structure probe" -- a command that prints a stable fingerprint of the session's
# structure (tab count, pane count, active tab, mode). We snapshot it, mash every key in
# the forbidden battery, and require the fingerprint to be identical afterwards. This
# catches a key that splits a pane, opens a menu, enters copy mode, detaches, or renames.
hx_test_forbidden_keys() { # session probe_command_string [screen_denylist_regex]
  local name="$1" probe="$2" deny="${3:-}"
  local before after screen_before screen_after k label hex bad=0
  before="$(eval "$probe")"
  screen_before="$(hx_cap "$name")"
  for k in "${FORBIDDEN_KEYS[@]}"; do
    label="${k%%:*}"
    hex="${k#*:}"
    hx_hex "$name" "$hex"
    sleep 0.12
    after="$(eval "$probe")"
    if [ "$after" != "$before" ]; then
      hx_fail "forbidden key changed session structure: $label" "before[$before] after[$after]"
      bad=1
      before="$after"   # re-baseline so one bad key doesn't cascade
    fi
    if [ -n "$deny" ]; then
      screen_after="$(hx_cap "$name")"
      if printf '%s' "$screen_after" | grep -qE "$deny"; then
        hx_fail "forbidden key revealed UI matching /$deny/: $label"
        bad=1
      fi
    fi
  done
  # Clear whatever junk landed on the command line so later tests start clean.
  hx_hex "$name" "15" 2>/dev/null || true   # Ctrl+U
  hx_settle 0.3
  [ "$bad" -eq 0 ] && hx_pass "no forbidden key (${#FORBIDDEN_KEYS[@]} tested) changed session structure"
  return 0
}

# --- host-terminal key encoding matrix -------------------------------------
#
# Runs one action under each encoding a real emulator might send, and reports which work.
# The output is the compatibility matrix for "will ALT+arrows work in Terminal.app".
hx_test_key_encodings() { # session action_label probe verify_fn "enc_label:hex" ...
  local name="$1" action="$2" probe="$3" verify="$4"; shift 4
  local spec label hex before after
  for spec in "$@"; do
    label="${spec%%:*}"; hex="${spec#*:}"
    before="$(eval "$probe")"
    hx_hex "$name" "$hex"
    hx_settle 0.5
    after="$(eval "$probe")"
    if "$verify" "$before" "$after"; then
      hx_pass "$action works with encoding: $label"
    else
      hx_fail "$action does NOT work with encoding: $label" "probe stayed [$before]"
    fi
  done
}
