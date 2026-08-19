#!/usr/bin/env bash
#
# Screen-level verification of the CS193V tmux configuration.
#
# RUNS INSIDE THE CONTAINER. ../65-tmux.sh copies this directory in with `podman cp` and
# runs it there, so the config under test is the INSTALLED /etc/cs193v/tmux.conf, the tmux
# is the image's apt tmux, and the shell hook is the real /etc/bash.bashrc line -- not a
# copy of any of them exercised somewhere else.
#
# It runs the real tmux inside an instrumented outer tmux, injects the exact byte sequences
# a student's terminal would send, and asserts on the rendered screen: text, structure, and
# colour contrast under both light and dark host palettes.
#
# WHAT THIS TIER IS FOR. The cheap tiers assert that files exist and settings are set.
# This one is the only thing that can see what a student SEES -- that the wheel does not
# strand them in a mode with a dead keyboard, that the chrome is legible on a light theme,
# that clicking a tab works, that a hundred-odd keys a beginner might mash do nothing.
# Every check here was written against a bug that actually happened during prototyping.
#
# Forked from the multiplexer prototype's tmux/tests/test-suite.sh. Divergences are marked
# `# FORK:` and they are not cosmetic -- the container's config differs from the prototype's
# in six ways, and several of the prototype's assertions assert the OPPOSITE of what this
# configuration should do.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

S=tmuxtest
SOCK="cs193v-t$$"
# FORK: the installed path, not a file in the source tree.
CONF="${CS193V_TMUX_CONF:-/etc/cs193v/tmux.conf}"
# Read from the image's own definition rather than repeated here, so rewording the title
# does not redden this suite. See files/cs193v-strings.sh.
# shellcheck source=/dev/null
[ -r /etc/cs193v/strings.sh ] && . /etc/cs193v/strings.sh
TITLE="${CS193V_TITLE:?/etc/cs193v/strings.sh did not define CS193V_TITLE}"
it() { tmux -L "$SOCK" "$@"; }     # "inner tmux": the instance under test

cleanup() { it kill-server 2>/dev/null; hx_teardown; }
trap cleanup EXIT

# --- structure probes -------------------------------------------------------
# Fingerprint of the session's shape plus whether any pane has entered a mode. If a keystroke
# splits a pane, opens copy mode, kills a window, or detaches, this string changes.
probe_struct() {
  it list-panes -a -F '#{window_index}.#{pane_index}.#{pane_in_mode}' 2>/dev/null |
    sort | tr '\n' ',' | sed 's/,$//'
}
probe_win() { it display-message -p -t cs193v '#{window_index}' 2>/dev/null; }
probe_name() { it display-message -p -t cs193v '#{window_name}' 2>/dev/null; }
probe_mode() { it display-message -p -t cs193v '#{pane_in_mode}' 2>/dev/null; }
# How far back the pane is scrolled, in lines. EMPTY when the pane is not in a mode, which is why
# every check that reads it pairs it with probe_mode rather than trusting it alone.
probe_pos() { it display-message -p -t cs193v '#{scroll_position}' 2>/dev/null; }
probe_wincount() { it list-windows -t cs193v 2>/dev/null | wc -l | tr -d ' '; }

# ============================================================================
hx_section "packaging and prerequisites"
# FORK: the prototype ran `apt-cache policy tmux` here to prove tmux comes from Ubuntu main.
# That cannot work in this image -- the Containerfile deletes /var/lib/apt/lists to keep the
# layer small, so there is no candidate to report. The claim it was making is about the
# distribution anyway, not about our image; 50-image.sh records the installed version.
#
# What matters HERE is the two things whose absence stops a student getting a shell at all.
if command -v tmux >/dev/null 2>&1; then
  hx_pass "tmux is installed in the image"
  hx_note "tmux $(tmux -V | awk '{print $2}')"
else
  hx_fail "tmux is installed in the image"; hx_summary "tmux"; exit 1
fi
# The terminfo gate. default-terminal is tmux-256color, whose entry ships in ncurses-term --
# a Recommends, which --no-install-recommends drops. Without it tmux exits immediately with
# "missing or unsuitable terminal" and NOBODY can open a shell.
if infocmp tmux-256color >/dev/null 2>&1; then
  hx_pass "the tmux-256color terminfo entry is present (ncurses-term)"
else
  hx_fail "the tmux-256color terminfo entry is present (ncurses-term)" \
          "tmux will refuse to start; the image is missing ncurses-term"
fi
if [ -r "$CONF" ]; then
  hx_pass "the configuration is installed at $CONF"
else
  hx_fail "the configuration is installed at $CONF"; hx_summary "tmux"; exit 1
fi
# -f suppresses both of tmux's default config paths, so neither may exist to be picked up.
for stray in /etc/tmux.conf "$HOME/.tmux.conf"; do
  if [ -e "$stray" ]; then
    hx_fail "no stray tmux config at $stray" "a file here could override the locked-down config"
  else
    hx_pass "no stray tmux config at $stray"
  fi
done

# ============================================================================
hx_section "config integrity"
FAKEBIN="$(hx_fake_binary claude)"
# Second fixture: `claude` installed the npm way, as a script run by a node interpreter.
# /proc then reports the interpreter, which is the failure mode worth documenting.
cp "$(readlink -f "$(command -v python3)")" "$FAKEBIN/node"
printf '#!/usr/bin/env node\nimport time; time.sleep(300)\n' > "$FAKEBIN/claude-npm"
chmod +x "$FAKEBIN/claude-npm"

hx_start "$S" "tmux -L $SOCK -f $CONF new-session -s cs193v"
# FORK: the prototype waited for its keyboard hint, "ALT+T new tab". There is no hint any
# more -- the course teaches the keys rather than advertising them -- so the thing to wait
# for is the button that replaced it.
if hx_wait "$S" '\+ NEW TAB' 12; then
  hx_pass "session starts and the tab bar is visible"
else
  hx_fail "session starts and the tab bar is visible" "screen: $(hx_cap "$S" | head -3)"
  hx_summary "tmux"; exit 1
fi
# A DURATION, deliberately. What comes next reads `show-messages` and asserts it holds NO
# config errors, and an error the server has not got round to reporting yet would satisfy that
# just as well as an error-free config does. There is no positive condition to poll for when
# the expected answer is "nothing arrived", so this waits for a while instead. See the note on
# hx_until in lib.sh for the general rule.
hx_settle 1.5

# A tmux config error does not abort the server -- it is reported in show-messages and shown
# to the user, which ALSO puts the pane into a message-viewing mode. That is how a misplaced
# `-N` flag silently unbound all three keys while making the "SCROLLED BACK" banner appear on
# a session nobody had scrolled. Both halves are now regression-tested.
msgs="$(it show-messages 2>/dev/null)"
if printf '%s' "$msgs" | grep -qiE 'unknown|invalid|error|ambiguous|bad '; then
  hx_fail "the config loads with zero error messages" \
          "$(printf '%s' "$msgs" | grep -iE 'unknown|invalid|error|ambiguous|bad ' | head -3)"
else
  hx_pass "the config loads with zero error messages"
fi
hx_expect_eq "no pane is in a mode at startup" "$(probe_mode)" "0"

# --- R1 as a direct keymap audit -------------------------------------------
# tmux can enumerate its own keymap, so this requirement is auditable rather than merely
# pokeable. NOTE: the audit must run against the live ATTACHED session. A detached probe
# session is destroyed instantly by `destroy-unattached on`, which takes the server with it
# (exit-empty) and leaves the next command talking to a fresh DEFAULT-config server -- which
# looks exactly like a catastrophic config failure and is entirely an artifact of the test.
keys="$(it list-keys 2>/dev/null)"
BASELINE_KEYS="$(printf '%s\n' "$keys" | grep -c 'bind-key')"
hx_note "bindings defined in the entire server: $BASELINE_KEYS"
for tbl in prefix copy-mode-vi; do
  if [ "$(printf '%s\n' "$keys" | grep -c -- "-T $tbl ")" -eq 0 ]; then
    hx_pass "the '$tbl' key table is completely empty"
  else
    hx_fail "the '$tbl' key table is completely empty" \
            "$(printf '%s\n' "$keys" | grep -m2 -- "-T $tbl ")"
  fi
done
pfx="$(it show-options -g prefix; it show-options -g prefix2)"
hx_expect_contains "no prefix key is set" "$pfx" "prefix None"
hx_expect_contains "no secondary prefix key is set" "$pfx" "prefix2 None"

# The keys must actually be bound. This is the assertion that would have caught the -N bug
# immediately (a misplaced -N flag registers nothing and reports no error).
#
# FORK: six, not three. Each action has an ALT key and a key that needs no Meta, because
# macOS terminals compose Option by default and an ALT-only keymap is unreachable for most
# of the class.
for k in "M-t" "C-t" "M-Left" "S-Left" "M-Right" "S-Right"; do
  if printf '%s\n' "$keys" | grep -qE -- "-T root +$k "; then
    hx_pass "$k is bound in the root table (no prefix needed)"
  else
    hx_fail "$k is bound in the root table" "not present in list-keys"
  fi
done
# ...and all six again inside copy mode, or the tab bar goes dead the instant the wheel is
# brushed -- which is exactly when a confused student reaches for it.
for k in "M-t" "C-t" "M-Left" "S-Left" "M-Right" "S-Right"; do
  if printf '%s\n' "$keys" | grep -qE -- "-T copy-mode +$k "; then
    hx_pass "$k still works while scrolled back"
  else
    hx_fail "$k still works while scrolled back" "not bound in the copy-mode table"
  fi
done
# Clicking the chip is the only route to a new tab that needs no keyboard at all.
if printf '%s\n' "$keys" | grep -qE -- "-T root +MouseDown1StatusRight "; then
  hx_pass "the + NEW TAB chip is bound to a click"
else
  hx_fail "the + NEW TAB chip is bound to a click" "MouseDown1StatusRight is not bound"
fi

# No binding anywhere may invoke a destructive or confusing command.
for danger in split-window detach-client command-prompt choose-tree choose-window kill-window \
              kill-pane kill-session kill-server display-menu display-popup rename-window \
              rename-session resize-pane swap-pane next-layout break-pane join-pane \
              switch-client suspend-client source-file run-shell new-session; do
  if printf '%s\n' "$keys" | grep -qE -- "(^|[ ;{])$danger([ ;}]|$)"; then
    hx_fail "no keybinding can invoke '$danger'" "$(printf '%s\n' "$keys" | grep -m1 -- "$danger")"
  else
    hx_pass "no keybinding can invoke '$danger'"
  fi
done

# --- the scrollbar must stay OFF -------------------------------------------
# This is a regression test for a measured bug, not a style preference. With pane-scrollbars on,
# tmux adds and removes the scrollbar column depending on whether there is scrollback to show --
# and an alternate-screen program (nano, vim, less) has none, so the column flickers in and out.
# Each change RESIZES the pane, and ncurses repaints the whole screen on every resize. Measured:
# geometry oscillated 100x27 <-> 99x27 eight times in five seconds, which made nano unusable.
if [ "$(it show-options -gv pane-scrollbars 2>/dev/null)" = "off" ]; then
  hx_pass "pane-scrollbars is off (prevents the alternate-screen resize flicker)"
else
  hx_fail "pane-scrollbars is off" \
          "got '$(it show-options -gv pane-scrollbars 2>/dev/null)' -- full-screen apps will flicker"
fi

# --- portability of the 3.6-only block -------------------------------------
# The target is Ubuntu 26.04 (tmux 3.6). The %if gate is belt-and-braces so the file still loads
# cleanly on 3.4, where copy-mode-position-format does not exist. Prove the gate works in BOTH
# directions by loading a copy whose gate can never be true and checking it is still error-free.
GATED="$(mktemp)"
sed 's/#{>=:#{version},3.6}/#{>=:#{version},99.0}/' "$CONF" > "$GATED"
SOCK2="cs193vgate$$"
tmux -L "$SOCK2" -f "$GATED" new-session -d -s gate 2>/dev/null
gmsg="$(tmux -L "$SOCK2" show-messages 2>/dev/null)"
gkeys="$(tmux -L "$SOCK2" list-keys 2>/dev/null | grep -c 'bind-key')"
# FORK: this used to be a skip. Under the prototype's `destroy-unattached on`, a detached
# probe session was destroyed the instant it was created -- taking the server with it via
# exit-empty -- so the check could never actually run and had to be excused. With
# destroy-unattached off (see Part 5 of the config, and ERRORS.md D1 for why) the probe
# survives and this is a real assertion again.
if [ -z "$gkeys" ] || [ "$gkeys" = "0" ]; then
  hx_fail "the config is error-free when the 3.6 block is gated off (simulates tmux 3.4)" \
          "the probe session reported no bindings at all -- the server did not come up"
elif printf '%s' "$gmsg" | grep -qiE 'unknown|invalid|error'; then
  hx_fail "the config is error-free when the 3.6 block is gated off (simulates tmux 3.4)" \
          "$(printf '%s' "$gmsg" | grep -iE 'unknown|invalid|error' | head -3)"
else
  hx_pass "the config is error-free when the 3.6 block is gated off (simulates tmux 3.4)"
fi
tmux -L "$SOCK2" kill-server 2>/dev/null

# ============================================================================
hx_section "startup appearance"
# Two status lines now: line 0 is the course title bar, line 1 is the tab bar. Every screen-row
# assertion below is offset accordingly (row 1 = title, row 2 = tabs, in 1-based capture terms).
title="$(hx_cap "$S" | sed -n 1p)"
hx_note "title bar: [$title]"
# FORK: "CS193V", not "CS193". The prototype's title bar dropped the V; the banner, the
# window title and the hostname in this project all have it, and this is the most visible
# string in the whole environment.
hx_expect_contains "a title bar names the environment" "$title" "$TITLE"
case "$title" in
  " "*"$TITLE"*)
    hx_pass "the title bar text is centered" ;;
  *)
    hx_fail "the title bar text is centered" "[$title]" ;;
esac
hx_expect_absent "the title bar is separate from the tab list" "$title" "TAB"
hx_check_colors "$S" "title bar (row 0)" --rows 0 --require-explicit

# The chrome deliberately has NO background of its own any more (dropped at the course staff's
# request: tmux's habit of suppressing a background that matches the terminal's made it unreliable
# across terminals). So the bar's text sits directly on whatever background the student's theme
# provides, and the requirement becomes: every text run must stay legible under BOTH a light and a
# dark host palette on its own. That is what the contrast floor checks, without --require-explicit.
hx_check_colors "$S" "chrome text is legible on light AND dark terminals" --rows 0,1

bar="$(hx_cap "$S" | sed -n 2p)"
hx_note "tab bar: [$bar]"
# ONE TAB MEANS NO TAB BAR CONTENT (issue #26). A count of one and a list of one are both
# answers to a question nobody asked: they take a row of chrome to tell a student who has
# opened nothing that they have opened nothing. The count and the labels earn their space
# the moment a second tab exists, and not before -- which is asserted further down, where
# the second tab gets opened.
#
# This assertion used to run the other way ("tab bar states how many tabs exist", expecting
# "1 TAB"), so the old behaviour was not merely uncovered, it was pinned. Note that the
# needle is "1 TAB" and not "TAB": the + NEW TAB chip stays, and is the reason a student
# with one tab can get a second one.
hx_expect_absent "no tab count when there is only one tab" "$bar" "1 TAB"
# FORK: the prototype asserted a keyboard cheat sheet here -- "ALT+T new tab   ALT+LEFT /
# ALT+RIGHT switch tab". By course decision the chrome no longer advertises any key: the
# keys are taught in class, and the bar stays quiet so tab labels get the width. What is
# asserted instead is the button that replaced the hint, and that no hint came back.
hx_expect_contains "tab bar offers a clickable new-tab button" "$bar" "+ NEW TAB"
hx_expect_absent "the chrome advertises no keybindings" "$bar" "ALT+"
hx_expect_absent "the chrome advertises no keybindings (CTRL)" "$bar" "CTRL+"
hx_expect_absent "the chrome advertises no keybindings (SHIFT)" "$bar" "SHIFT+"
hx_expect_absent "no SCROLLED BACK banner on a fresh session" "$bar" "SCROLLED BACK"
hx_check_colors "$S" "+ NEW TAB chip" --grep "NEW TAB" --require-explicit

# Row 3 is the pane border: the dividing line between the chrome and the student's own output.
# tmux draws borders only BETWEEN panes, so with one full-width pane this top edge is as close to
# "a border around the terminal" as tmux can get -- there is no left, right, or bottom edge.
border="$(hx_cap "$S" | sed -n 3p)"
case "$border" in
  *"━"*) hx_pass "a border line separates the chrome from the terminal area" ;;
  *)     hx_fail "a border line separates the chrome from the terminal area" "row 3: [$border]" ;;
esac
hx_expect_absent "the border carries no title (the tab bar already names the process)" "$border" "bash"
hx_check_colors "$S" "pane border (row 2)" --rows 2 --min-contrast 3

# The other half of issue #26: no label block either. "1 bash" is the single tab naming
# itself to a student who has no second tab to tell it apart from.
#
# This is where "first tab is labeled with its running process (bash)" used to be. It was
# a real requirement and still is, so it has MOVED to the multi-tab section below rather
# than been dropped -- a label that stops tracking the running process would otherwise
# become invisible to the suite.
bar="$(hx_cap "$S" | sed -n 2p)"
hx_expect_absent "no tab labels when there is only one tab" "$bar" "bash"

# Which leaves exactly one thing on the row. Asserted positively as well, because two
# absences would also be satisfied by a bar that failed to draw at all.
case "$(printf '%s' "$bar" | tr -d ' ')" in
  "+NEWTAB") hx_pass "a single tab leaves nothing on the bar but the new-tab button" ;;
  *)         hx_fail "a single tab leaves nothing on the bar but the new-tab button" \
                     "bar: [$bar]" ;;
esac

# Claim the fixture name from inside the pane. Without this the pane's ~/.bashrc prepends
# ~/.local/bin and a REAL claude install wins the lookup -- the test then launches actual
# Claude Code and "passes" while measuring nothing.
hx_use_fixture "$S" "$FAKEBIN" claude

# ============================================================================
hx_section "new tab: CTRL+T, ALT+T, and the chip (host-terminal encodings)"
# FORK: CTRL+T leads, because it is the key that works with no terminal configuration
# anywhere -- a plain control byte, 0x14. ALT+T is kept as the fast path for anyone whose
# terminal sends Meta.
#
# NOTE what this section can and cannot prove. It injects bytes straight into the inner
# tmux's pty, so it proves the CONTAINER responds correctly to each encoding. It cannot
# prove a given terminal EMITS them -- that is not a property of anything in here, and it
# is why tests/MANUAL.md §7.9 exists.
for spec in "REQ:CTRL+T (a plain control byte -- every terminal):$KEY_CTRL_T" \
            "REQ:ESC-prefix (macOS Terminal.app, xterm, Windows Terminal):$KEY_ALT_T_ESCPREFIX" \
            "INFO:CSI-u (kitty keyboard protocol):$KEY_ALT_T_CSIU"; do
  tier="${spec%%:*}"; rest="${spec#*:}"; label="${rest%:*}"; hex="${rest##*:}"
  before="$(probe_wincount)"
  hx_hex "$S" "$hex"
  # 2 s where the fixed sleep was 1.2. The ceiling is only reached by an encoding tmux does
  # NOT parse -- which is a deliberate INFO case in this list -- so the two that must work
  # return in a few tens of milliseconds and the one that must not gets MORE patience than
  # before, not less.
  hx_until_ne 'probe_wincount' "$before" 2
  after="$(probe_wincount)"
  if [ "$after" -gt "$before" ]; then
    hx_pass "ALT+T opens a tab via $label"
  elif [ "$tier" = REQ ]; then
    hx_fail "ALT+T opens a tab via $label" "window count stayed at $before"
  else
    hx_skip "ALT+T via $label -- not parsed by tmux (compatibility note only)"
  fi
done
n="$(probe_wincount)"
if [ "$n" -ge 2 ]; then
  hx_pass "multiple tabs coexist ($n open)"
  hx_expect_contains "tab bar pluralizes the count" "$(hx_cap "$S" | sed -n 2p)" "TABS"

  # Issue #26: the count and the labels are hidden at one tab, so this is where both have
  # to come BACK. Suppressing chrome that never returns would pass the absence checks above
  # just as well as suppressing it conditionally does.
  hx_expect_contains "tab count reappears once a second tab exists" \
                     "$(hx_cap "$S" | sed -n 2p)" "$n TABS"
  # Moved here from "startup appearance", where it asserted the single tab's label. The
  # requirement is unchanged -- a tab is labelled with what is running in it -- but with
  # one tab there is now no label to find.
  if hx_wait "$S" '1 bash' 8; then
    hx_pass "tabs are labeled with their running process (bash)"
  else
    hx_fail "tabs are labeled with their running process" \
            "bar: [$(hx_cap "$S" | sed -n 2p)]"
  fi
else
  hx_fail "multiple tabs coexist"
fi

# FORK: clicking the chip. This is the whole reason the chip exists -- it is the one way to
# open a tab that needs neither a working Meta key nor anyone to have told the student a
# keystroke, so if it silently stops being clickable the fallback plan for macOS is gone.
#
# The click must land on the chip and NOT be swallowed by the generic MouseDown1Status
# binding that switches tabs; that is what the separate range=right region in
# status-format[1] is for.
if loc="$(hx_find "$S" "+ NEW TAB")"; then
  set -- $loc
  before="$(probe_wincount)"
  hx_click "$S" "$1" "$(($2 + 2))"
  hx_until_ne 'probe_wincount' "$before" 6
  after="$(probe_wincount)"
  if [ -n "$after" ] && [ "$after" -gt "$before" ]; then
    hx_pass "clicking the + NEW TAB chip opens a tab ($before -> $after)"
  else
    hx_fail "clicking the + NEW TAB chip opens a tab" "count stayed at $before"
  fi
else
  hx_fail "clicking the + NEW TAB chip opens a tab" "could not find the chip on the tab bar"
fi

# ============================================================================
hx_section "switch tabs: SHIFT and ALT arrows (host-terminal encodings)"
# FORK: SHIFT+LEFT/RIGHT lead. They are a modified-key encoding rather than a control byte,
# so unlike CTRL+T they do depend on the terminal sending the modifier parameter -- which is
# exactly why the NEW TAB key is the control byte and not SHIFT+DOWN. If shift+arrow turns
# out not to be transmitted on some terminal, tabs there are still openable and still
# clickable; only the keyboard shortcut for switching is lost.
for spec in "REQ:SHIFT+arrow, CSI 1;2 (every mainstream terminal):$KEY_SHIFT_LEFT:$KEY_SHIFT_RIGHT" \
            "REQ:ESC-prefix (macOS Terminal.app 'Option as Meta'):$KEY_ALT_LEFT_ESCPREFIX:$KEY_ALT_RIGHT_ESCPREFIX" \
            "REQ:CSI 1;3 (Windows Terminal, iTerm2, VS Code):$KEY_ALT_LEFT_CSI3:$KEY_ALT_RIGHT_CSI3" \
            "REQ:SS3 / application-cursor mode:$KEY_ALT_LEFT_SS3:$KEY_ALT_RIGHT_SS3" \
            "INFO:CSI 1;9 (older xterm, Meta as bit 8):$KEY_ALT_LEFT_CSI9:$KEY_ALT_RIGHT_CSI9"; do
  tier="${spec%%:*}"; rest="${spec#*:}"
  label="${rest%%:*}"; rest="${rest#*:}"
  lhex="${rest%:*}"; rhex="${rest##*:}"
  for dir in LEFT RIGHT; do
    [ "$dir" = LEFT ] && hex="$lhex" || hex="$rhex"
    p0="$(probe_win)"
    hx_hex "$S" "$hex"
    hx_until_ne 'probe_win' "$p0" 2      # 2 s ceiling; see the note in the new-tab loop above
    p1="$(probe_win)"
    if [ "$p1" != "$p0" ] && [ -n "$p1" ]; then
      hx_pass "ALT+$dir switches tab via $label ($p0 -> $p1)"
    elif [ "$tier" = REQ ]; then
      hx_fail "ALT+$dir switches tab via $label" "window index stayed at $p0"
    else
      hx_skip "ALT+$dir via $label -- not parsed by tmux (compatibility note only)"
    fi
  done
done
hx_expect_eq "tabs are numbered from 1, not 0" "$(it list-windows -t cs193v -F '#{window_index}' | head -1)" "1"

# ============================================================================
hx_section "tabs are labeled with the running process"
hx_cmd "$S" "$(hx_fake_run claude 300)"
hx_until 'probe_name' claude 8
hx_expect_eq "tab label follows the running process automatically" "$(probe_name)" "claude"

# Both labels must be visible at once -- the point of R3 is seeing what is in the tab you are
# NOT looking at.
w0="$(probe_win)"
hx_hex "$S" "$KEY_ALT_LEFT_ESCPREFIX"
hx_until_ne 'probe_win' "$w0" 6
hx_use_fixture "$S" "$FAKEBIN" claude
hx_cmd "$S" "python3"
# WAIT FOR THE REPL, NOT FOR ITS LABEL, because a keystroke is sent to it below.
#
# /etc/cs193v/tabname.bash renames the window from bash's DEBUG trap, which fires when the
# command line is SUBMITTED -- before the fork, let alone before python is ready to read. So
# `hx_until 'probe_name' python3` is satisfied in about fifty milliseconds and says nothing
# about whether anything is listening yet. The CTRL+D below then lands in the gap and is lost,
# and the label never reverts. Measured exactly that, but only with both test lanes running:
# on an idle machine python3 wins the race and the bug is invisible.
#
# The label is still the right thing to wait for at the sites that only ASSERT on the label.
# It is the wrong thing anywhere the next step types at the program.
hx_wait "$S" '>>>' 10 || true
bar="$(hx_cap "$S" | sed -n 2p)"
hx_expect_contains "tab bar shows the other tab's process (claude)" "$bar" "claude"
hx_expect_contains "tab bar shows this tab's process (python3)" "$bar" "python3"
hx_note "tab bar: [$bar]"

hx_hex "$S" "$KEY_CTRL_D"
hx_until 'probe_name' bash 8
hx_expect_eq "tab label reverts to 'bash' when the process exits" "$(probe_name)" "bash"

# FORK: THE REASON THE HOOK IS NOT OPTIONAL HERE.
#
# In the prototype this was an informational skip: a `#!/usr/bin/env node` script is reported
# by /proc as `node`, but that machine's `claude` happened to be a native binary so nothing
# was actually broken. This image installs Claude Code with `npm install -g`, so the script
# case IS the real case, and `node` would be the label on most tabs in the course.
#
# `claude-npm` is deliberately NOT on the tab-label list, so it still demonstrates the raw
# behaviour -- and that is the point: the label is wrong exactly until a name is listed,
# which is why /etc/cs193v/tabname.bash lists `claude`. The positive half is asserted in the
# hook section below.
hx_cmd "$S" "claude-npm"
# Which name appears is the question being asked, so there is nothing to poll FOR -- only
# something to poll away from. Any of node / claude-npm / something else is a result; "bash"
# means the command has not started yet.
hx_until_ne 'probe_name' bash 6
wrapname="$(probe_name)"
if [ "$wrapname" = "node" ]; then
  hx_pass "an unlisted node script is labeled 'node' (which is why 'claude' is on the list)"
elif [ "$wrapname" = "claude-npm" ]; then
  hx_pass "a script-based claude is labeled by its own name"
else
  hx_skip "a script-based claude is labeled '$wrapname' -- /proc reports the interpreter, not the script"
  hx_note "if claude ships as a node script, use the automatic-rename-format override noted in README.md"
fi
hx_hex "$S" "03"; hx_until 'probe_name' bash 6

# ============================================================================
hx_section "R3/R6  tab bar legibility and clickability"
hx_check_colors "$S" "tmux tab bar (row 1)" --rows 1

if loc="$(hx_find "$S" "claude")"; then
  set -- $loc
  before="$(probe_win)"
  hx_click "$S" "$1" "$2"
  hx_until_ne 'probe_win' "$before" 6
  if [ "$(probe_win)" != "$before" ] && [ "$(probe_name)" = "claude" ]; then
    hx_pass "clicking a tab name switches to that tab"
  else
    hx_fail "clicking a tab name switches to that tab" "win $before -> $(probe_win), name $(probe_name)"
  fi
else
  hx_fail "clicking a tab name switches to that tab" "could not find 'claude' in the tab bar"
fi

# Right-click is a genuine R1 risk: tmux ships context menus on the status line and the pane.
for target in "the tab bar:10:1" "inside the terminal:20:12"; do
  what="${target%%:*}"; rest="${target#*:}"; cx="${rest%:*}"; cy="${rest##*:}"
  before="$(probe_struct)"
  hx_click "$S" "$cy" "$cx" 2          # button 3 == SGR code 2
  hx_settle 1                         # a DURATION: the claim is that NO menu opened
  scr="$(hx_cap "$S")"
  if [ "$(probe_struct)" = "$before" ] &&
     ! printf '%s' "$scr" | grep -qE 'Kill|Respawn|New Window|Horizontal|Vertical|Swap|Rename'; then
    hx_pass "right-clicking $what opens no menu"
  else
    hx_fail "right-clicking $what opens no menu" "$(printf '%s' "$scr" | sed -n '2,4p')"
  fi
done

# ============================================================================
hx_section "R5/R6  scrollback, mouse wheel, and the copy-mode trap"
# Run this on a FRESH tab. The R3 tests above left a 300-second `claude` fixture running in the
# current tab, and typing a shell loop into a sleeping process produces no output at all -- which
# looks exactly like "scrollback is broken" but is really the test aiming at the wrong pane.
n0="$(probe_wincount)"
hx_hex "$S" "$KEY_ALT_T_ESCPREFIX"
# Wait for the WINDOW before waiting for the prompt. `hx_wait '\$'` on its own would be
# satisfied by the prompt still on screen in the tab we are leaving, so the fixed sleep this
# replaces was load-bearing in a way that was not obvious -- the poll has to be for the new
# window existing, and only then for its prompt.
hx_until_ne 'probe_wincount' "$n0" 6
hx_wait "$S" '\$' 8 || true
hx_cmd "$S" 'for i in $(seq 1 400); do echo "LINE_$i"; done'
hx_wait "$S" 'LINE_400' 15 || true
hx_expect_contains "output reaches the bottom of the buffer" "$(hx_cap "$S")" "LINE_400"

hx_wheel_up "$S" 15 40 12
hx_until 'probe_mode' 1 6
hx_wait "$S" 'SCROLLED BACK' 6 || true
scrolled="$(hx_cap "$S")"
if printf '%s' "$scrolled" | grep -qE 'LINE_(2[0-9][0-9]|3[0-4][0-9])'; then
  hx_pass "mouse wheel scrolls back through history"
else
  hx_fail "mouse wheel scrolls back through history" "row 2: $(printf '%s' "$scrolled" | sed -n '2p')"
fi
# Being scrolled back must be VISIBLE, but only briefly. It is announced by a self-expiring
# `display-message -d 3000` on status line 0 (the decorative title row), not by a banner that sits
# there for as long as the student stays scrolled back.
hx_expect_contains "scrolling back announces itself" "$(hx_cap "$S" | sed -n 1p)" "SCROLLED BACK"

# tmux draws a position indicator -- "[0/0]", i.e. [scroll_position/history_size] -- in the top
# right of any pane in copy mode. It is informative for a tmux user and pure jargon for a beginner,
# and it used to appear when merely dragging to select, since that entered copy mode too -- which no
# longer happens, because a drag no longer selects anything (see the section on that below). Turned
# off via copy-mode-position-format (tmux 3.6+).
indicator="$(hx_cap "$S" | grep -oE '\[[0-9]+/[0-9]+\]' | head -1)"
if [ -z "$indicator" ]; then
  hx_pass "no [N/M] copy-mode position indicator is shown"
else
  hx_fail "no [N/M] copy-mode position indicator is shown" "found: $indicator"
fi
hx_check_colors "$S" "scrolled-back message" --grep "SCROLLED BACK" --require-explicit
hx_expect_absent "the notice does not squat on the tab bar" "$(hx_cap "$S" | sed -n 2p)" "SCROLLED BACK"

# ...and it clears itself a few seconds after the last scroll, with no keypress from the student.
# hx_gone, not a fixed sleep: the notice expiring IS the thing being waited for, so polling for
# it is the assertion's own condition rather than a guess at how long `-d 3000` takes. A notice
# that never expires still fails, at the ceiling, exactly as the 4.5 s sleep made it fail.
hx_gone "$S" 'SCROLLED BACK' 8 || true
hx_expect_absent "the notice disappears on its own (~3s)" "$(hx_cap "$S" | head -2)" "SCROLLED BACK"
hx_expect_contains "the title bar returns once the notice expires" \
                   "$(hx_cap "$S" | sed -n 1p)" "$TITLE"
# Expiring the message must NOT have quietly scrolled us back to the bottom.
hx_expect_eq "the pane is still scrolled back after the notice expires" "$(probe_mode)" "1"

# The three allowed actions must still work while scrolled back, or the tab bar goes dead the
# moment a student brushes the wheel.
before="$(probe_win)"
hx_hex "$S" "$KEY_ALT_RIGHT_ESCPREFIX"
hx_until_ne 'probe_win' "$before" 6
if [ "$(probe_win)" != "$before" ] && [ "$(probe_mode)" = "0" ]; then
  hx_pass "ALT+RIGHT still switches tabs while scrolled back (and leaves the mode)"
else
  hx_fail "ALT+RIGHT still switches tabs while scrolled back" \
          "win $before -> $(probe_win), in_mode $(probe_mode)"
fi

# THE TRAP TEST: after scrolling up, any keystroke must return to a live prompt.
w0="$(probe_win)"
hx_hex "$S" "$KEY_ALT_LEFT_ESCPREFIX"
hx_until_ne 'probe_win' "$w0" 6
hx_wheel_up "$S" 15 40 10
hx_until 'probe_mode' 1 6
hx_expect_eq "wheel-up put the pane in a mode (as tmux does)" "$(probe_mode)" "1"
hx_str "$S" "x"
hx_until 'probe_mode' 0 6
if [ "$(probe_mode)" = "0" ]; then
  hx_pass "typing any key escapes the scrollback view (no dead-end)"
else
  hx_fail "typing any key escapes the scrollback view" "pane is still in a mode"
fi
hx_hex "$S" "15"; hx_settle 0.5       # Ctrl+U clears the line; nothing observable to poll for

hx_wheel_up "$S" 15 40 6
hx_until 'probe_mode' 1 6
hx_wheel_down "$S" 15 40 25
hx_until 'probe_mode' 0 6
hx_expect_contains "wheel scrolls forward back to the live prompt" "$(hx_cap "$S")" "LINE_400"
hx_expect_eq "scrolling to the bottom exits the mode automatically" "$(probe_mode)" "0"

hx_expect_eq "scrollback depth is configured" \
             "$(it show-options -gv history-limit)" "50000"

# ============================================================================
hx_section "R6  the mouse does not select text -- the terminal does (#61)"
#
# WHAT THIS SECTION ASSERTS IS AN ABSENCE, and that is the point. Two rounds of #61 made a
# tmux-side selection work correctly -- the right characters, the view held still -- and it made no
# difference, because a tmux-side copy can only reach a student's clipboard through OSC 52 and the
# terminal this course is taught from does not implement that escape. Measured by hand, outside any
# container: `printf '\033]52;c;'"$(printf CLIPTEST | base64)"'\a'` leaves the clipboard empty.
#
# So selection was handed back to the terminal, where SHIFT+drag has always worked, and the mouse
# gestures now do nothing except say so. That makes tmux's own paste buffer the thing to watch: it
# must stay EMPTY after every gesture, in the scrollback and at a live prompt alike. A check that
# looked for the right text would have passed all along; only a check that demands nothing at all
# can tell this design from the one it replaced.
#
# SHIFT+drag ITSELF IS NOT TESTABLE FROM IN HERE, and cannot be: holding Shift makes the terminal
# suppress mouse reporting, so nothing reaches tmux and there are no bytes to inject. Its absence
# from this suite is the mechanism working, not a gap. The manual matrix in MANUAL.md covers it.
n0="$(probe_wincount)"
hx_hex "$S" "$KEY_ALT_T_ESCPREFIX"
hx_until_ne 'probe_wincount' "$n0" 6
hx_wait "$S" '\$' 8 || true

# The marker is assembled from $M at runtime so the ECHOED COMMAND LINE does not contain it: crow
# searches the visible screen, and once the fixture is scrolled back into view the typed command is
# on screen too, so a literal marker in the command would be matched first and every gesture would
# aim at the wrong row. selftest.sh uses the same trick.
#
# 35 filler lines, which is more than the ~26 rows a pane has under the chrome: the fixture has to
# be genuinely off-screen (asserted below) and no further back than that, because every case rewinds
# to it and the wheel costs a round trip per notch.
hx_cmd "$S" 'clear; M=SELECT; printf "%-10s alpha beta gamma delta\n" "${M}_ME"; for i in $(seq 1 35); do echo "FILL_$i"; done'
hx_wait "$S" 'FILL_35' 15 || true
hx_expect_absent "the selection fixture starts off-screen, in the scrollback" \
                 "$(hx_cap "$S")" "SELECT_ME"

# PIN THE SECTION TO ITS OWN TAB, and read the mode from that tab by number rather than from
# "whichever tab is current". Several checks here click the TAB BAR, and a click that lands on a tab
# label switches tabs -- correctly, via the root table, because a click on another tab's label
# resolves to that tab's pane, which is not in a mode. probe_mode would then report the wrong pane
# and the rest of the section would quietly measure a tab that was never scrolled back. That is not
# hypothetical: it is what this section did until the empty-bar-space click below stopped being
# aimed at a magic column.
cwin="$(probe_win)"
cmode() { it display-message -p -t "cs193v:$cwin" '#{pane_in_mode}' 2>/dev/null; }
cpos()  { it display-message -p -t "cs193v:$cwin" '#{scroll_position}' 2>/dev/null; }
crow()  { hx_cap "$S" | awk -v n="$1" '$0 ~ n {print NR; exit}'; }
ccopy() { it show-buffer 2>/dev/null; }
# Rewind to the fixture. Three things, and each one was a bug in this section before it was one of
# its rules:
#
#   * EMPTY THE BUFFER FIRST, or a gesture that copies nothing at all -- which is now every gesture
#     -- inherits the previous case's clipboard and passes on it.
#   * RESET TO THE LIVE BOTTOM FIRST, so every case starts from the same scroll position instead of
#     from wherever the last gesture left the pane. Without this, hx_scroll_to returns without
#     scrolling when the fixture is still on screen, and scrolls its full ceiling when the pane is
#     deep in the history. `send-keys -X cancel` is the harness resetting state between cases, not
#     part of what is under test; it errors harmlessly when the pane is not in a mode.
#   * FAIL, not note, if the fixture cannot be brought back. hx_note goes to the suite's stdout,
#     which 65-tmux.sh writes to a temp file and discards -- only hx_emit rows reach the report.
cback() {
  it delete-buffer 2>/dev/null || true
  it select-window -t "cs193v:$cwin" 2>/dev/null || true
  it send-keys -X -t "cs193v:$cwin" cancel 2>/dev/null || true
  hx_settle 0.2
  hx_scroll_to "$S" 'SELECT_ME' 40 || hx_fail "the fixture can be rewound into view" \
      "hx_scroll_to gave up after 40 notches; the gesture that follows would aim at the wrong row"
  hx_settle 0.3
}

# --- the three selection gestures, in the scrollback -------------------------
# Each one: nothing copied, the view exactly where it was, and the hint on screen. The drag is the
# gesture from the issue's own steps; the two multi-clicks are separate KEYS (SecondClick1Pane and
# friends) rather than variations of it, which is why they get their own checks rather than a loop
# over one.
cback; cr="$(crow SELECT_ME)"; cstart="$(cpos)"
hx_drag "$S" "$cr" 18 "$((cr + 3))" 20
hx_settle 0.8
hx_expect_eq "a drag in the scrollback copies NOTHING" "$(ccopy)" ""
hx_expect_eq "a drag in the scrollback leaves the pane scrolled back" "$(cmode)" "1"
hx_expect_eq "a drag in the scrollback does not move the view" "$(cpos)" "$cstart"
hx_expect_contains "a drag in the scrollback explains SHIFT+drag instead" \
                   "$(hx_cap "$S" | head -2)" "hold SHIFT"

cback; cr="$(crow SELECT_ME)"; cstart="$(cpos)"
hx_multiclick "$S" "$cr" 16 2
hx_settle 0.6
hx_expect_eq "double-clicking in the scrollback copies NOTHING" "$(ccopy)" ""
hx_expect_eq "double-clicking in the scrollback does not move the view" "$(cpos)" "$cstart"
hx_expect_contains "double-clicking explains SHIFT+drag too" "$(hx_cap "$S" | head -2)" "hold SHIFT"

cback; cr="$(crow SELECT_ME)"; cstart="$(cpos)"
hx_multiclick "$S" "$cr" 16 3
hx_settle 0.6
hx_expect_eq "triple-clicking in the scrollback copies NOTHING" "$(ccopy)" ""
hx_expect_eq "triple-clicking in the scrollback does not move the view" "$(cpos)" "$cstart"

# --- and at a live prompt ----------------------------------------------------
# Same three gestures, the other arm of every guard in Part 3. The mode check is the one that would
# catch a copy path sneaking back in through copy-mode: a selection used to enter it.
# CANCEL BEFORE TYPING, here and before the app fixture below. If any gesture above has left the
# pane in a mode -- which is exactly what a regression to a tmux-side selection would do -- the `Any`
# hatch eats the first character of the next command and the shell runs `lear; echo ...`. The command
# then fails, crow finds nothing, every later gesture aims at row "" and the whole section reports a
# cascade of unrelated failures. Seen for real in the red run that preceded this design.
it send-keys -X -t "cs193v:$cwin" cancel 2>/dev/null || true
hx_settle 0.3
# NO `clear` ANYWHERE IN THIS SECTION, and it is not a style choice. ncurses' `clear` emits the E3
# capability, which clears tmux's SCROLLBACK as well as the screen -- measured, history_size 10 -> 0
# -- so a single `clear` here destroys the fixture that the section below rewinds to, and every
# check there then fails for a reason that has nothing to do with what it tests. That cost a full
# suite run to find. The marker is assembled from $P at runtime for the usual reason: crow searches
# the visible screen, and the echoed command line is on it.
hx_cmd "$S" 'P=PROMPT; echo ${P}LINE here'
hx_until_ok "hx_cap $S | grep -q 'PROMPTLINE here'" 8
lr="$(crow 'PROMPTLINE here$')"
it delete-buffer 2>/dev/null || true
hx_drag "$S" "$lr" 1 "$lr" 11
hx_settle 0.8
hx_expect_eq "a drag at a live prompt copies NOTHING" "$(ccopy)" ""
hx_expect_eq "a drag at a live prompt leaves no lingering mode" "$(cmode)" "0"
hx_expect_contains "a drag at a live prompt explains SHIFT+drag" "$(hx_cap "$S" | head -2)" "hold SHIFT"
hx_expect_absent "no gesture claims to have copied anything any more" "$(hx_cap "$S" | head -2)" "COPIED"
# The hint is chrome, so it answers to the same two rules as the rest of it: legible on either host
# theme, and self-expiring rather than a banner that sits there.
hx_check_colors "$S" "SHIFT+drag hint" --grep "hold SHIFT" --require-explicit
hx_gone "$S" 'hold SHIFT' 8 || true
hx_expect_absent "the hint expires on its own" "$(hx_cap "$S" | head -2)" "hold SHIFT"

it delete-buffer 2>/dev/null || true
hx_multiclick "$S" "$lr" 3 2
hx_settle 0.6
hx_expect_eq "double-clicking at a live prompt copies NOTHING" "$(ccopy)" ""
hx_expect_eq "double-clicking at a live prompt leaves no lingering mode" "$(cmode)" "0"

# --- but a mouse-aware app must still get the drag ---------------------------
# THE ONE REGRESSION THIS DESIGN COULD CAUSE. Every gesture above reaches its hint through the else
# arm of a guard whose true arm forwards to the application; break the guard and claude, nano, vim
# and less all lose the mouse at once. `cat -v` after enabling SGR mouse reporting is the smallest
# possible stand-in for such an app: it renders the raw bytes, so a forwarded event is visible ON
# SCREEN, and the hint must NOT appear.
it send-keys -X -t "cs193v:$cwin" cancel 2>/dev/null || true
hx_settle 0.2
hx_cmd "$S" "printf '\\033[?1006h\\033[?1000h'; cat -v"
hx_settle 0.8
hx_expect_eq "a mouse-reporting app is detected as one" \
             "$(it display-message -p -t "cs193v:$cwin" '#{mouse_any_flag}')" "1"
# THE FORWARDED COORDINATES ARE PANE-RELATIVE. tmux translates the event before handing it on, so a
# press at screen row 8 reaches the app as row 5: the two status lines and the pane border sit above
# the pane. Derived here rather than hardcoded, so this check follows the chrome if it ever changes.
drag_row=8
hx_drag "$S" "$drag_row" 5 "$drag_row" 9
hx_settle 0.8
app_saw="$(hx_cap "$S" | grep -o '\[<[0-9;]*[Mm]' | tr '\n' ' ')"
hx_expect_contains "a drag inside a mouse-aware app still reaches the app" \
                   "$app_saw" "[<0;5;$((drag_row - 3))M"
hx_expect_absent "and does NOT get the SHIFT+drag hint" "$(hx_cap "$S" | head -2)" "hold SHIFT"
hx_hex "$S" "03"
hx_settle 0.4
# TURN MOUSE REPORTING BACK OFF, or everything after this section measures the wrong thing. Killing
# `cat` does not undo the `\033[?1000h` it was reading through: the pane keeps asking for mouse
# events, mouse_any_flag stays 1, and every wheel event is then FORWARDED to the pane instead of
# scrolling tmux back -- so the scrollback checks below cannot rewind to the fixture at all and fail
# in a way that looks nothing like its cause. Found the hard way; a real app resets this on exit.
hx_cmd "$S" "printf '\\033[?1000l\\033[?1006l'"
hx_settle 0.5
hx_expect_eq "the mouse goes back to tmux when the app stops asking for it" \
             "$(it display-message -p -t "cs193v:$cwin" '#{mouse_any_flag}')" "0"

# ============================================================================
hx_section "R6  clicks and drags never move the scrollback view (#61)"
#
# THE BUG AS REPORTED. `bind -T copy-mode Any` is the "you can never be stuck" escape hatch, and
# tmux's `Any` pseudo-key matches MOUSE events as well as keystrokes -- so a button press, which is
# the first half of every drag and arrives before any motion, cancelled copy mode. Cancelling copy
# mode returns the pane to the live screen, which is the jump to the bottom of a 50,000-line
# scrollback. Guarding the hatch on "did this event carry a mouse position" is the fix, and these
# checks are what hold it in place now that no gesture copies anything.
cback; cr="$(crow SELECT_ME)"; cstart="$(cpos)"
hx_press "$S" "$cr" 18
hx_settle 0.6
hx_expect_eq "a button press while scrolled back stays in the scrollback view" "$(cmode)" "1"
hx_expect_eq "a button press while scrolled back does not move the view" "$(cpos)" "$cstart"
hx_release "$S" "$cr" 18
hx_settle 0.4
hx_expect_eq "releasing that button does not move the view either" "$(cmode)" "1"

# Column 1 is the reason the guard tests `#{==:#{mouse_x},}` rather than the truthiness of mouse_x:
# coordinates are 0-based, so a click there reports "0", which tmux's conditional reads as FALSE. A
# truthiness test would take the leftmost column for a keystroke and scroll the student to the
# bottom -- one column wide, and invisible to every other check here.
cback; cr="$(crow SELECT_ME)"
hx_click "$S" "$cr" 1
hx_settle 0.6
hx_expect_eq "clicking column 1 while scrolled back does not move the view" "$(cmode)" "1"

# EMPTY BAR SPACE HAS TO BE FOUND, NOT GUESSED. A fixed column was over a tab label by the time the
# suite reached this section -- the bar had grown to six tabs -- so the click switched tabs instead
# of doing nothing, and every check after it measured the wrong pane. The gap between the last label
# and the + NEW TAB chip is always empty, and two columns left of the chip's `+` is outside its
# range=right region, so the click lands on the status line's default region.
cback
if loc="$(hx_find "$S" "+ NEW TAB")"; then
  set -- $loc
  hx_click "$S" "$1" "$(($2 - 2))"
  hx_settle 0.6
  hx_expect_eq "clicking empty tab-bar space does not move the view" "$(cmode)" "1"
  hx_expect_eq "clicking empty tab-bar space does not switch tabs" "$(probe_win)" "$cwin"
else
  hx_fail "clicking empty tab-bar space does not move the view" "could not locate the chip"
fi

# A right-click is its own key (MouseDown3Pane) and cancelled the mode under the unguarded hatch.
cback; cr="$(crow SELECT_ME)"
hx_click "$S" "$cr" 5 2
hx_settle 0.6
hx_expect_eq "right-clicking while scrolled back does not move the view" "$(cmode)" "1"
# The pane border is a LOCK, not a regression: measured, a border click never cancelled the mode even
# with the bug present, because tmux does not deliver it to the pane's mode table at all. Kept
# because "no mouse event anywhere in the chrome scrolls the view away" is the property, and a reader
# who finds this green in both directions should know it was checked rather than assumed. Row 3 is
# the border, drawn there by pane-border-status top.
cback
hx_click "$S" 3 40
hx_settle 0.6
hx_expect_eq "clicking the pane border does not move the view" "$(cmode)" "1"

# --- the escape hatch must still be a hatch ----------------------------------
# The guard narrows what `Any` fires for, so both halves of "you can never be stuck" are re-asserted
# here against the fixture, not just in the LINE_400 tab above.
cback
hx_str "$S" "x"
hx_until 'cmode' 0 6
hx_expect_eq "a keystroke still leaves the scrollback view" "$(cmode)" "0"
hx_hex "$S" "15"; hx_settle 0.3
cback
hx_wheel_down "$S" "$((HX_H / 2))" "$((HX_W / 2))" 30
hx_until 'cmode' 0 6
hx_expect_eq "scrolling to the bottom still leaves the scrollback view" "$(cmode)" "0"

# --- the one action that needs no keyboard at all ---------------------------
# The + NEW TAB chip is the only route to a new tab that needs neither a working Meta key nor prior
# instruction. Its click resolves to the pane the mouse is over -- which while scrolled back is a
# pane in copy mode -- so it needs its own copy-mode binding. The tab LABELS do not: a click on
# another tab's label resolves to THAT tab's pane, which is not in a mode, so the root binding
# handles it. Left last because it lands the suite in the new tab, at a live prompt.
cback
n0="$(probe_wincount)"
if loc="$(hx_find "$S" "+ NEW TAB")"; then
  set -- $loc
  hx_click "$S" "$1" "$(($2 + 2))"
  hx_until_ne 'probe_wincount' "$n0" 6
  if [ "$(probe_wincount)" -gt "$n0" ]; then
    hx_pass "clicking + NEW TAB while scrolled back still opens a tab"
  else
    hx_fail "clicking + NEW TAB while scrolled back still opens a tab" \
            "count stayed at $n0 -- the chip is dead in the copy-mode key table"
  fi
  # probe_mode, not cmode, and deliberately: the subject is the tab the chip just opened, which is
  # now the current one -- not the fixture tab the rest of the section pins itself to.
  hx_expect_eq "the tab the chip opened is a live prompt, not a scrolled-back view" \
               "$(probe_mode)" "0"
else
  hx_fail "clicking + NEW TAB while scrolled back still opens a tab" \
          "could not find the chip on the tab bar"
fi

# ============================================================================
hx_section "R6  no clipboard write is emitted at all, on a bare pty"
#
# WHY A SECOND INSTRUMENT EXISTS. Everything above watches the inner tmux through the outer one, and
# an outer tmux is not a terminal: it accepts an OSC 52 write and stores the payload whatever
# selection the sequence names. That blind spot passed a green "the drag reached the host clipboard"
# while a real terminal was putting the text on PRIMARY, where Ctrl+V never looks -- and it could not
# see a gesture that emitted no write at all. clipprobe.py runs tmux on a bare pty and reads the wire.
#
# The assertion is now that tmux writes NOTHING. Selection belongs to the terminal, so the config
# must make no clipboard claim at all -- and this is the check that fails the day a copy path creeps
# back in, whatever it copies and wherever it puts it.
clip_out="$(python3 "$HX_DIR/clipprobe.py" "$CONF" 2>&1)"
clip_target() {
  printf '%s\n' "$clip_out" | awk -F'\t' -v g="$1" '$1 == g {print $2; hit = 1} END {if (!hit) print "NO-RESULT"}'
}
for gesture in scrolled-back-drag live-prompt-drag live-prompt-double-click; do
  hx_expect_eq "$gesture writes no clipboard sequence" "$(clip_target "$gesture")" "NONE"
done
# ============================================================================
hx_section "R1  no other keybinding does anything"
hx_note "mashing ${#FORBIDDEN_KEYS[@]} key combinations a beginner might hit by accident"
# NOTE: the deny pattern deliberately does NOT include bash's "[1]+ Stopped" job-control
# output. Ctrl+Z suspending a foreground job is ordinary UNIX shell behavior that happens
# with or without a multiplexer; flagging it would be a false positive.
hx_test_forbidden_keys "$S" probe_struct \
  'Kill|Respawn|New Window|Horizontal|Vertical|Swap|Rename|\(detached\)|choose|--INSERT--|SCROLLED BACK'
if [ "$(probe_wincount)" -ge 2 ]; then
  hx_pass "tabs survived the key battery ($(probe_wincount) still open)"
else
  hx_fail "tabs survived the key battery" "only $(probe_wincount) left"
fi
if it list-sessions 2>/dev/null | grep -q 'cs193v'; then
  hx_pass "the session was never detached or destroyed by a stray key"
else
  hx_fail "the session was never detached or destroyed by a stray key"
fi
hx_expect_eq "no stray key left the pane in a mode" "$(probe_mode)" "0"

# ============================================================================
hx_section "R3  the tab bar under stress"
n0="$(probe_wincount)"
for _ in $(seq 1 10); do hx_hex "$S" "$KEY_ALT_T_ESCPREFIX"; done
hx_until 'probe_wincount' "$((n0 + 10))" 10
n="$(probe_wincount)"
hx_note "$n tabs open; bar: [$(hx_cap "$S" | sed -n 2p)]"
if [ "$n" -ge 10 ]; then
  hx_pass "$n tabs open without corrupting the screen"
else
  hx_fail "many tabs open" "only $n"
fi
hx_check_colors "$S" "tab bar with $n tabs" --rows 1

# Narrow window. Testing at 40 columns is what revealed, in the prototype, that a fixed-width
# keyboard hint pushed every tab name off the bar.
#
# FORK: the prototype width-gated that hint so it would yield below 80 columns. The hint is
# gone and the gate with it, so what is asserted now is different: the chip is only 11
# columns and is NOT gated, because it is the only mouse route to a new tab and must survive
# at any size -- but the tab names still have to be visible alongside it.
hx_tmux resize-window -t "$S" -x 40 -y 20 2>/dev/null || true
# The outer resize returns immediately; what has to be waited for is the INNER tmux noticing
# its pty changed size and redrawing the bar at the new width. Ask the inner server.
hx_until 'it display-message -p -t cs193v "#{window_width}"' 40 6
narrow="$(hx_cap "$S" | sed -n 2p)"
hx_note "at 40 columns: [$narrow]"
hx_expect_contains "at 40 columns the tab count still shows" "$narrow" "TAB"
hx_expect_contains "at 40 columns the new-tab button survives" "$narrow" "NEW TAB"
if printf '%s' "$narrow" | grep -q "bash"; then
  hx_pass "at 40 columns tab names are still visible"
else
  hx_fail "at 40 columns tab names are still visible" "the chrome is crowding out the tabs"
fi
hx_tmux resize-window -t "$S" -x "$HX_W" -y "$HX_H" 2>/dev/null || true
hx_until 'it display-message -p -t cs193v "#{window_width}"' "$HX_W" 6

# ============================================================================
hx_section "R7  exit closes the tab; last exit ends the session"
# Test the actual requirement on a KNOWN-CLEAN tab: open one with ALT+T (guaranteed to be a
# fresh bash prompt) and type `exit`. Testing it on whatever tab happens to be focused is
# unreliable -- earlier tests leave a python3 REPL behind, and a REPL ignores both `exit`
# (it just prints "Use exit() or Ctrl-D") and Ctrl+C.
n0="$(probe_wincount)"
hx_hex "$S" "$KEY_ALT_T_ESCPREFIX"
hx_until_ne 'probe_wincount' "$n0" 6      # the window, then its prompt -- see the R5 section
hx_wait "$S" '\$' 8 || true
before="$(probe_wincount)"
hx_cmd "$S" 'exit'
hx_until 'probe_wincount' "$((before - 1))" 8
after="$(probe_wincount)"
if [ -n "$after" ] && [ "$after" -lt "$before" ]; then
  hx_pass "typing 'exit' closes the current tab ($before -> $after)"
else
  hx_fail "typing 'exit' closes the current tab" "count stayed at $before"
fi

# Now drain the rest so the "last tab" case can be tested. Ctrl+C interrupts a running program,
# Ctrl+D sends EOF, which exits a REPL *and* a shell -- between them every tab can be closed.
closed=0
guard=0
while [ "$(probe_wincount)" -gt 1 ] && [ "$guard" -lt 40 ]; do
  before="$(probe_wincount)"
  hx_hex "$S" "03"; hx_settle 0.3        # interrupt anything running -- nothing to poll for
  hx_hex "$S" "$KEY_CTRL_D"
  hx_until_ne 'probe_wincount' "$before" 2
  after="$(probe_wincount)"
  [ -n "$after" ] && [ "$after" -lt "$before" ] && closed=$((closed + 1))
  guard=$((guard + 1))
done
if [ "$(probe_wincount)" = "1" ]; then
  hx_pass "all but the last tab could be closed ($closed closed)"

  # Issue #26 on the way back DOWN, which is the direction nothing else here exercises. A
  # student who opens a second tab and closes it again should get the quiet bar back, not
  # a "1 TAB" badge left behind by a format that only re-evaluated upwards.
  # Wait for the bar to reach its one-tab STATE, not for a duration. Polling for the absence
  # of "1 TAB" would be the wrong shape -- it would also be satisfied by a bar caught halfway
  # through a redraw, which is exactly the reading the two assertions below must not get.
  # "+ NEW TAB and nothing else" is the positive form of the same condition.
  hx_until 'hx_cap "$S" | sed -n 2p | tr -d " "' '+NEWTAB' 6
  bar="$(hx_cap "$S" | sed -n 2p)"
  hx_expect_absent "the tab count goes away again when tabs are closed" "$bar" "1 TAB"
  hx_expect_absent "the tab labels go away again when tabs are closed" "$bar" "bash"
else
  hx_fail "all but the last tab could be closed" "remaining=$(probe_wincount)"
fi

hx_cmd "$S" 'exit'
hx_until_ok '! it has-session -t cs193v 2>/dev/null' 8
if it has-session -t cs193v 2>/dev/null; then
  hx_fail "closing the last tab ends the session" "the session is still alive"
else
  hx_pass "closing the last tab ends the session (nothing left to reattach to)"
fi
# Poll rather than checking once. Server shutdown is not instantaneous: for a moment after the
# last session is destroyed the socket is still accepting connections while `exit-empty` tears
# it down, and `list-sessions` in that window prints nothing at all -- which is neither the
# "no server" message nor a live session, and read as a failure on a single-shot check.
gone=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  out="$(it list-sessions 2>&1)"
  if printf '%s' "$out" | grep -qE 'no server|No such file|error connecting'; then gone=1; break; fi
  if [ -z "$out" ] && ! it has-session -t cs193v 2>/dev/null; then gone=1; break; fi
  sleep 0.5
done
if [ "$gone" -eq 1 ]; then
  hx_pass "the tmux server shut down (no orphaned background session)"
else
  hx_fail "the tmux server shut down" "$(it list-sessions 2>&1 | head -2)"
fi

# ============================================================================
hx_section "tab labels: wrapper commands show what they are running"
# tmux labels tabs from the foreground process NAME, so `sudo apt install nginx` reads "sudo".
# tmux cannot fix this by configuration: `display-message -a` dumps every format variable it knows
# and none contains the argument vector (verified). /etc/cs193v/tabname.bash is the bridge.
#
# FORK, AND IT SIMPLIFIES THE TEST. The prototype had to install the hook with
# `set -g default-command 'bash --rcfile .../bashrc -i'`, and warned that handing the hooked
# shell to `new-session` instead reaches tab one only. In the container none of that applies:
# the hook's source line is in /etc/bash.bashrc, which every interactive bash reads, so every
# tab gets it with no tmux involvement at all. This session is therefore started exactly the
# way cs193v-shell starts one -- which means the test now exercises the real wiring rather
# than a stand-in for it.
#
# First, assert the wiring actually exists. Without this the label tests below could all pass
# against a hook that was sourced some other way.
if grep -q '/etc/cs193v/tabname.bash' /etc/bash.bashrc 2>/dev/null; then
  hx_pass "the tab-label hook is wired into /etc/bash.bashrc (so it reaches every tab)"
else
  hx_fail "the tab-label hook is wired into /etc/bash.bashrc" \
          "no reference to /etc/cs193v/tabname.bash -- labels will be one word everywhere"
fi

S2=tmuxhook
SOCK2H="cs193vhook$$"
it2() { tmux -L "$SOCK2H" "$@"; }
FAKESUDO="$(mktemp -d)"
# Real sudo would demand a password; this stand-in parses flags the way sudo does, then execs.
cat > "$FAKESUDO/sudo" <<'FAKE'
#!/bin/sh
while [ $# -gt 0 ]; do case "$1" in -u|-g|-U|-C|-p) shift 2 ;; -*) shift ;; *) break ;; esac; done
exec "$@"
FAKE
chmod +x "$FAKESUDO/sudo"
# Long-running stand-ins for the multi-tools, so a label can be observed while one is "running".
# Several of these (npm, npx, cargo) are not installed here at all, and the point of the test is the
# LABEL the hook computes from the typed text, not whether the tool exists.
for _fake in git npm npx docker make cargo pytest apt apt-get pip3; do
  printf '#!/bin/sh\nsleep 45\n' > "$FAKESUDO/$_fake"
  chmod +x "$FAKESUDO/$_fake"
done

# No default-command: /etc/bash.bashrc carries the hook, so a plain session gets it.
hx_start "$S2" "env PATH=$FAKESUDO:\$PATH tmux -L $SOCK2H -f $CONF new-session -s cs193v"
if hx_wait "$S2" '\+ NEW TAB' 12; then
  probe_name2() { it2 display-message -p -t cs193v '#{window_name}' 2>/dev/null; }
  probe_wincount2() { it2 list-windows -t cs193v 2>/dev/null | wc -l | tr -d ' '; }

  # FORK, AND IT COST AN ENTIRE FAILING SECTION TO FIND.
  #
  # Exporting PATH into tmux's environment is NOT enough here, even though it was in the
  # prototype. The prototype ran `bash --rcfile ... -i`, a non-login shell. This
  # configuration deliberately runs the real LOGIN shell, so that the hook arrives the way
  # it does for a student -- and Debian's /etc/profile assigns PATH unconditionally rather
  # than appending to it. Every fake tool was therefore stripped before the first label test
  # ran, `git`/`npm`/`sudo` resolved to the real ones, and all fifteen label assertions
  # failed while the hook itself was working perfectly.
  #
  # Claim PATH from INSIDE the pane instead, after the login shell has finished with it.
  # This is the same idiom hx_use_fixture uses for the claude fixture, and for the same
  # underlying reason.
  hx_cmd "$S2" "export PATH=$FAKESUDO:\$PATH; hash -r"
  hx_cmd "$S2" "command -v sudo"
  hx_until_ok "hx_cap $S2 | grep -qF '$FAKESUDO/sudo'" 6
  hx_expect_contains "the fake tools win the PATH lookup inside the pane" \
                     "$(hx_cap "$S2")" "$FAKESUDO/sudo"

  hx_cmd "$S2" "sudo python3 -c 'import time; time.sleep(30)'"
  hx_until 'probe_name2' 'sudo python3' 8
  hx_expect_eq "a wrapper command shows the real command too" "$(probe_name2)" "sudo python3"
  hx_hex "$S2" "03"; hx_until 'probe_name2' bash 8
  hx_expect_eq "the label returns to the shell at the prompt" "$(probe_name2)" "bash"

  # The hook must reach tabs created later, not just the first one. This is the assertion
  # that catches the default-command trap the prototype documented -- a hooked shell handed
  # only to `new-session` reaches tab one and silently nowhere else. /etc/bash.bashrc has no
  # such failure mode, which is why the container wires it there.
  #
  # PATH has to be re-claimed in the new tab too: it is a fresh login shell, so /etc/profile
  # has reset it again.
  c0="$(probe_wincount2)"
  hx_hex "$S2" "$KEY_ALT_T_ESCPREFIX"
  hx_until_ne 'probe_wincount2' "$c0" 6
  hx_cmd "$S2" "export PATH=$FAKESUDO:\$PATH; hash -r"
  hx_cmd "$S2" "sudo python3 -c 'import time; time.sleep(30)'"
  hx_until 'probe_name2' 'sudo python3' 8
  hx_expect_eq "the hook reaches tabs opened with ALT+T" "$(probe_name2)" "sudo python3"
  hx_hex "$S2" "03"; hx_until 'probe_name2' bash 8

  # Multi-purpose tools show their subcommand, which is the informative half.
  # SIXTEEN CALLS, and it used to be the single most expensive thing in this file: 2.2 s + 1.2 s
  # of fixed sleep each, 54 seconds of the suite spent waiting for something that happens in
  # about eighty milliseconds. Both waits now poll the label itself, with ceilings four times
  # longer than the sleeps they replace -- so this is more patient on a slow machine and
  # roughly free on a fast one. The hx_expect_eq between them is unchanged and is still what
  # decides the result: a label that never arrives fails here exactly as it always did.
  label_check() { # typed expected
    hx_cmd "$S2" "$1"
    hx_until 'probe_name2' "$2" 8
    hx_expect_eq "label for \`$1\`" "$(probe_name2)" "$2"
    hx_hex "$S2" "03"; hx_until 'probe_name2' bash 8
  }
  label_check "git commit -m 'a message'"              "git commit"
  label_check "npm install express"                    "npm install"
  label_check "docker run -it ubuntu"                  "docker run"
  label_check "make -j4 all"                           "make all"

  # The rule is RECURSIVE: `apt` is itself on the list, so "sudo apt" keeps unwrapping to reach the
  # subcommand. It stops at the first word that is not a runner, and is capped at three words.
  label_check "sudo apt update"                        "sudo apt update"
  label_check "sudo apt install nginx"                 "sudo apt install"
  label_check "sudo apt-get upgrade"                   "sudo apt-get upgrade"
  label_check "sudo pip3 install requests"             "sudo pip3 install"
  label_check "sudo docker run ubuntu"                 "sudo docker run"
  label_check "sudo -u root npm install"               "sudo npm install"
  label_check "sudo apt"                               "sudo apt"
  # `time` is a bash KEYWORD, so the DEBUG trap only ever sees the inner command -- which is why
  # this labels as "git commit" and not "time git commit". Not a bug; bash never shows us the word.
  label_check "time git commit"                        "git commit"
  # `-c` is ambiguous and both readings must work: code for python3, a setting for git.
  label_check "python3 -c 'import time; time.sleep(30)'" "python3"
  label_check "git -c user.name=x commit"              "git commit"
  # An argument keeps only its basename, so labels stay short.
  label_check "python3 -m http.server 8080"            "python3 http.server"
  # REGRESSION (reported from real use): a command that finishes while the student is looking at a
  # DIFFERENT tab must still revert its label. This used to fail permanently. precmd's
  # `set-window-option automatic-rename on` had no -t target, and a tmux command run inside a pane
  # resolves against the session's CURRENT window rather than its own -- so the option landed on
  # whatever tab was active, the background tab kept automatic-rename off, and its pinned label
  # ("python3 slowpoke.py") never reverted, not even after switching back to it.
  bgwin="$(it2 display-message -p -t cs193v '#{window_index}')"
  hx_cmd "$S2" "python3 -c 'import time; time.sleep(4)'"
  hx_until 'probe_name2' python3 8
  hx_expect_eq "the label is pinned while a listed command runs" "$(probe_name2)" "python3"
  hx_hex "$S2" "$KEY_ALT_T_ESCPREFIX"      # switch away while it is still running
  # ...and let it finish in the background. The sleep(4) has to elapse whatever we do, so the
  # win here is only the slack the 6.5 s sleep carried -- but the ceiling is now 12 s, which is
  # what a machine slow enough to need it would have failed on before.
  hx_until "it2 display-message -p -t cs193v:$bgwin '#{window_name}'" bash 12
  hx_expect_eq "a background tab's label reverts when its command finishes" \
    "$(it2 display-message -p -t "cs193v:$bgwin" '#{window_name}' 2>/dev/null)" "bash"
  hx_expect_eq "automatic-rename is restored on the background tab" \
    "$(it2 display-message -p -t "cs193v:$bgwin" '#{automatic-rename}' 2>/dev/null)" "1"
  c0="$(probe_wincount2)"                  # close the extra tab this test opened
  hx_cmd "$S2" 'exit'
  hx_until 'probe_wincount2' "$((c0 - 1))" 8

  # FORK: `claude` IS on the list now, so it can no longer stand in for "a command the hook
  # ignores". That is the single most important divergence in this file, and it is not a
  # test-only detail: Claude Code is installed here with `npm install -g`, so
  # /usr/local/bin/claude is a script with a `#!/usr/bin/env node` shebang and /proc reports
  # the INTERPRETER. Without the hook every Claude Code tab in the course reads `node`.
  #
  # So the claude case is now a positive assertion, using the fixture rather than the real
  # CLI -- see hx_fake_run for why that must never be a bare command name.
  hx_cmd "$S2" "$(hx_fake_run claude 30)"
  hx_until 'probe_name2' claude 8
  hx_expect_eq "claude is labeled 'claude', not 'node'" "$(probe_name2)" "claude"
  hx_hex "$S2" "03"; hx_until 'probe_name2' bash 8
  hx_assert_no_real_claude "claude label test"

  # ...and something genuinely off the list still goes to tmux's native mechanism, which is
  # the cheaper and always-accurate path.
  #
  # `sleep`, not `less`. less was the obvious stand-in and does not work: the image sets
  # LESS=FRX, and F means "quit immediately if the content fits one screen", so less on a
  # short file exits before the label can ever be read.
  hx_cmd "$S2" "sleep 20"
  hx_until 'probe_name2' sleep 8
  hx_expect_eq "a command not on the list is labeled natively" "$(probe_name2)" "sleep"
  hx_hex "$S2" "03"; hx_until 'probe_name2' bash 8

  # And the hook must not have smuggled in any extra keybinding. Compared against the count taken
  # at startup, NOT against the original server -- the R7 section above deliberately shut that one
  # down, so querying it now would report 0 and fail for entirely the wrong reason.
  hx_expect_eq "the hook adds no keybindings" \
    "$(it2 list-keys 2>/dev/null | grep -c 'bind-key')" "$BASELINE_KEYS"
else
  hx_fail "hooked session starts" "screen: $(hx_cap "$S2" | head -3)"
fi
it2 kill-server 2>/dev/null
hx_stop "$S2"

hx_summary "tmux prototype"
