# shellcheck shell=bash
#
# Key encodings, as hex byte sequences, exactly as real terminal emulators send them.
#
# This matters more than it looks. There is no single encoding for ALT+Left: different
# terminal emulators send different bytes, and a multiplexer that only recognizes one of
# them will appear "broken" to whichever half of the class uses the other terminal.
#
#   ESC-prefix ("meta sends escape")   macOS Terminal.app with "Use Option as Meta key",
#                                      iTerm2 with Option=Esc+, xterm default
#   CSI modifier 3 ("xterm style")     Windows Terminal, VS Code, iTerm2 default,
#                                      most modern emulators
#   CSI modifier 9                     older xterm builds that report Meta as bit 8
#   SS3/application-cursor + ESC       emulators in DECCKM (application cursor) mode
#
# Every prototype gets tested against ALL of these forms, and the results become the
# host-terminal compatibility matrix.

# --- ALT+T (new tab) ---------------------------------------------------------
KEY_ALT_T_ESCPREFIX="1b 74"           # ESC t          (Terminal.app, xterm, Windows Terminal)
KEY_ALT_T_CSIU="1b 5b 31 31 36 3b 33 75"  # CSI 116;3u  (kitty keyboard protocol / CSI-u)

# --- FORK: the keys that do not need Meta ------------------------------------
#
# The prototype had only the ALT keys. They are unreachable on macOS without a per-terminal
# settings change -- Terminal.app composes Option into "†", iTerm2 defaults left Option to
# Normal, VS Code needs macOptionIsMeta, and Ghostty/WezTerm/Alacritty all compose too. So
# each action gained a second key that every terminal sends unmodified.
#
# CTRL+T is a plain control byte, which is why it and not SHIFT+DOWN is the new-tab key:
# there is no such thing as a terminal that encodes Ctrl differently. SHIFT+arrow is a
# modified-key sequence and so does depend on the terminal emitting the modifier parameter,
# which is the one thing here that cannot be settled from inside a container -- see
# tests/MANUAL.md §7.9.
KEY_CTRL_T="14"                       # ^T
KEY_SHIFT_LEFT="1b 5b 31 3b 32 44"    # CSI 1;2 D
KEY_SHIFT_RIGHT="1b 5b 31 3b 32 43"   # CSI 1;2 C

# --- ALT+Left / ALT+Right (switch tab) --------------------------------------
KEY_ALT_LEFT_ESCPREFIX="1b 1b 5b 44"  # ESC ESC [ D    (Terminal.app "Option as Meta")
KEY_ALT_RIGHT_ESCPREFIX="1b 1b 5b 43" # ESC ESC [ C

KEY_ALT_LEFT_CSI3="1b 5b 31 3b 33 44" # CSI 1;3 D      (Windows Terminal, iTerm2, VS Code)
KEY_ALT_RIGHT_CSI3="1b 5b 31 3b 33 43" # CSI 1;3 C

KEY_ALT_LEFT_CSI9="1b 5b 31 3b 39 44" # CSI 1;9 D      (older xterm, Meta as bit 8)
KEY_ALT_RIGHT_CSI9="1b 5b 31 3b 39 43" # CSI 1;9 C

KEY_ALT_LEFT_SS3="1b 1b 4f 44"        # ESC ESC O D    (application cursor keys mode)
KEY_ALT_RIGHT_SS3="1b 1b 4f 43"       # ESC ESC O C

# --- plain keys --------------------------------------------------------------
KEY_ENTER="0d"
KEY_CTRL_D="04"
KEY_ESC="1b"
KEY_LEFT="1b 5b 44"
KEY_RIGHT="1b 5b 43"
KEY_UP="1b 5b 41"
KEY_DOWN="1b 5b 42"

# --- The "forbidden keys" battery -------------------------------------------
#
# R1 says only three actions may exist. These are the combos a novice is most likely to
# hit by accident, plus every default leader/prefix key used by the tools under test.
# After sending each one, the test asserts the session's structure is UNCHANGED: same
# number of tabs, same number of panes, no mode indicator, no prompt, no menu.
#
# Format: "label:hexbytes"
# FORK: Ctrl+T, Shift+Left and Shift+Right have been REMOVED from this list. They were on it
# because the prototype bound only the three ALT keys, so everything else had to be inert.
# They are now real bindings -- new tab, previous tab, next tab -- and leaving them here
# would assert that the feature does not work. Their positive behaviour is tested in the
# key-encoding matrix in suite.sh instead.
#
# Nothing else moves. Ctrl+N in particular stays forbidden: it was considered as the new-tab
# key ("N for new" is the most guessable of the candidates) and rejected because it costs
# readline's next-history, which is a key students do eventually meet.
FORBIDDEN_KEYS=(
  # tmux / screen / dvtm / zellij default leaders
  "Ctrl+B (tmux prefix):02"
  "Ctrl+A (screen prefix):01"
  "Ctrl+G (dvtm mod, zellij locked):07"
  "Ctrl+P (zellij pane mode):10"
  "Ctrl+N (zellij resize mode):0e"
  "Ctrl+O (zellij session mode):0f"
  "Ctrl+S (zellij scroll mode):13"
  "Ctrl+H (zellij move mode):08"
  "Ctrl+Q (zellij quit):11"
  # zellij / tmux secondary combos
  "Alt+N:1b 6e"
  "Alt+P:1b 70"
  "Alt+H:1b 68"
  "Alt+J:1b 6a"
  "Alt+K:1b 6b"
  "Alt+L:1b 6c"
  "Alt+F:1b 66"
  "Alt+W:1b 77"
  "Alt+X:1b 78"
  "Alt+S:1b 73"
  "Alt+I:1b 69"
  "Alt+O:1b 6f"
  "Alt+= :1b 3d"
  "Alt+- :1b 2d"
  "Alt+[:1b 5b 5b"
  "Alt+1:1b 31"
  "Alt+2:1b 32"
  "Alt+Up:1b 1b 5b 41"
  "Alt+Down:1b 1b 5b 42"
  # byobu F-keys (these are the ones byobu ships bound by default)
  "F1:1b 4f 50"
  "F2 (byobu new window):1b 4f 51"
  "F3 (byobu prev window):1b 4f 52"
  "F4 (byobu next window):1b 4f 53"
  "F5 (byobu reload):1b 5b 31 35 7e"
  "F6 (byobu detach):1b 5b 31 37 7e"
  "F7 (byobu scrollback):1b 5b 31 38 7e"
  "F8 (byobu rename):1b 5b 31 39 7e"
  "F9 (byobu menu):1b 5b 32 30 7e"
  "F10:1b 5b 32 31 7e"
  "F11:1b 5b 32 33 7e"
  "F12 (byobu lock):1b 5b 32 34 7e"
  # misc panic keys a beginner might mash
  "Ctrl+Z:1a"
  "Ctrl+X:18"
  "Ctrl+E:05"
  "Ctrl+F:06"
  "Ctrl+V:16"
  "Ctrl+Y:19"
  "Ctrl+minus:1f"
  "Shift+Up:1b 5b 31 3b 32 41"
  "Shift+Down:1b 5b 31 3b 32 42"
  "PageUp:1b 5b 35 7e"
  "PageDown:1b 5b 36 7e"
  "Home:1b 5b 48"
  "End:1b 5b 46"
  "Insert:1b 5b 32 7e"
  "Delete:1b 5b 33 7e"
)
