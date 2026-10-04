#!/usr/bin/env bash
# Validates the test instrument itself before any prototype is trusted to it.
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

S=hxself
trap 'hx_teardown' EXIT

hx_section "harness self-test"
[ -x "$HX_TMUX" ] || { echo "no tmux available at '$HX_TMUX'"; exit 1; }
hx_note "outer tmux: $HX_TMUX ($("$HX_TMUX" -V))"

hx_start "$S" "bash --norc --noprofile"
hx_wait "$S" '\$|#' 5 || true

# 1. byte-exact input delivery
hx_cmd "$S" 'echo HARNESS_OK'
hx_wait "$S" 'HARNESS_OK' 5 || true
hx_expect_contains "literal input reaches the inner PTY" "$(hx_cap "$S")" "HARNESS_OK"

# 2. hex input delivery (this is how every key in the battery is sent)
hx_str "$S" 'echo HEX'
hx_hex "$S" "5f" "4f" "4b"   # _OK
hx_enter "$S"
hx_wait "$S" 'HEX_OK' 5 || true
hx_expect_contains "hex-encoded input reaches the inner PTY" "$(hx_cap "$S")" "HEX_OK"

# 3. color capture round-trip.
#    The marker is assembled at runtime so the echoed command line does not itself contain
#    it -- otherwise --grep also matches the prompt row, whose default colors are
#    legitimately theme-dependent, and the assertion below would be testing the wrong row.
hx_cmd "$S" 'clear; A=GOOD; printf "\033[38;5;231;48;5;24m %sCONTRAST \033[0m\n" "$A"'
hx_wait "$S" 'GOODCONTRAST' 5 || true
ansi="$(hx_cap_ansi "$S")"
hx_expect_contains "capture-pane -e preserves SGR sequences" "$ansi" $'\033['

# 4. the contrast checker must ACCEPT a legible run...
if printf '%s' "$ansi" | python3 "$HX_DIR/screencheck.py" --grep GOODCONTRAST --require-explicit >/dev/null 2>&1; then
  hx_pass "screencheck accepts white-on-blue with explicit 256 colors"
else
  hx_fail "screencheck accepts white-on-blue with explicit 256 colors" \
          "$(printf '%s' "$ansi" | python3 "$HX_DIR/screencheck.py" --grep GOODCONTRAST --require-explicit 2>&1)"
fi

# 5. ...and must REJECT the classic invisible-on-light-themes bug.
#    Bright white fg with no explicit bg: fine on a dark theme, gone on a light one.
hx_cmd "$S" 'clear; B=BAD; printf "\033[97m %sCONTRAST \033[0m\n" "$B"'
hx_wait "$S" 'BADCONTRAST' 5 || true
if hx_cap_ansi "$S" | python3 "$HX_DIR/screencheck.py" --grep BADCONTRAST >/dev/null 2>&1; then
  hx_fail "screencheck rejects bright-white-on-default (invisible on light themes)" \
          "checker passed a run it should have failed"
else
  hx_pass "screencheck rejects bright-white-on-default (invisible on light themes)"
fi

# 6. text location, used to aim mouse clicks at tab labels
hx_cmd "$S" 'clear; printf "  FINDME\n"'
hx_wait "$S" 'FINDME' 5 || true
loc="$(hx_find "$S" "FINDME")" || loc="none"
if grep -qE '^[0-9]+ [0-9]+$' <<< "$loc"; then
  hx_pass "hx_find locates on-screen text (row/col = $loc)"
else
  hx_fail "hx_find locates on-screen text" "got '$loc'"
fi

# 6b. ...and the column it reports is the screen column, not an offset into the captured string
#     (issue #376). Each needle is placed with CSI G, so its column is known by construction. ┃ and
#     ✓ are three bytes and one column each. ⚠️ is U+26A0 plus VS16: six bytes, and two columns
#     here where East Asian Width says one. 🚫 is one code point and two columns.
#     Written to a file and cat'd so that no needle is on the screen in the echo of a typed command.
F="$(hx_scratch)"
{
  printf 'plain ascii\033[30GAT30ASCII\n'
  printf '┃\033[30GAT30BAR\n'
  printf '✓\033[30GAT30CHECK\n'
  printf '\xe2\x9a\xa0\xef\xb8\x8f\033[30GAT30WARN\n'
  printf '🚫\033[30GAT30NOENTRY\n'
  printf '┃ ✓ \xe2\x9a\xa0\xef\xb8\x8f 🚫 \033[30GAT30ALL\n'
} > "$F"
hx_cmd "$S" "clear; cat $F"
hx_wait "$S" 'AT30ALL' 5 || true
got=""
for n in ASCII BAR CHECK WARN NOENTRY ALL; do
  got="$got${got:+, }$(hx_find "$S" "AT30$n" || echo none)"
done
hx_expect_eq "hx_find reports the screen column after multibyte glyphs" \
  "$got" "1 30, 2 30, 3 30, 4 30, 5 30, 6 30"

# 6c. hx_box_widths measures every row of a box in screen columns, between its walls (issue #375).
#     One row of each way to be wrong: short, long, and a 🚫 row -- 71 code points, 72 columns.
#     Indented, as the link box popup is, and with text past two right walls. Waited for on the
#     last row's text, so the capture cannot be taken with the bottom rows still to come.
B="$(hx_scratch)"
rep() { local s='' i; for ((i = 0; i < $2; i++)); do s+="$1"; done; printf '%s' "$s"; }
{
  printf '    ┏━━ BOXFIXTURE %s┓\n' "$(rep ━ 55)"
  printf '    ┃%s┃ tail text\n' "$(rep ' ' 69)"
  printf '    ┃%s┃\n' "$(rep ' ' 68)"
  printf '    ┃%s┃\n' "$(rep ' ' 70)"
  printf '    ┃ 🚫%s┃\n' "$(rep ' ' 67)"
  printf '    ┗%s┛ BOXEND\n' "$(rep ━ 69)"
} > "$B"
hx_cmd "$S" "clear; cat $B"
hx_wait "$S" 'BOXEND' 5 || true
hx_expect_eq "hx_box_widths measures each box row in screen columns" \
  "$(hx_box_widths "$S")" "71 71 70 72 72 71"

# 7. mouse bytes are deliverable (inner program must see the SGR sequence verbatim).
#    `cat -v` renders them visibly so we can assert on the wire format.
hx_cmd "$S" 'clear; cat -v'
hx_settle 0.4
hx_click "$S" 1 5
hx_settle 0.4
hx_expect_contains "SGR mouse click bytes reach the inner PTY" "$(hx_cap "$S")" "[<0;5;1M"
hx_wheel_up "$S" 10 20 1
hx_settle 0.4
hx_expect_contains "SGR wheel bytes reach the inner PTY" "$(hx_cap "$S")" "[<64;20;10M"
hx_hex "$S" "03"  # Ctrl+C out of cat

# 8. suite.sh's danger check sees every forbidden command a binding can reach (#377). Each shape is
#    bound alone in a config of its own and must come back naming exactly what it hides. The first
#    seven are #377's shapes, and all but the braced arm used to pass. The last three must come
#    back clean, and refused.
danger_fixture() { # what binding expected [key]
  local f; f="$(hx_scratch)"
  printf 'bind -T hxfixture %s %s\n' "${4:-X}" "$2" > "$f"
  hx_expect_eq "the danger check sees $1" \
    "$(hx_keys_of "$f" hxfixture | hx_reach | hx_danger_hits | cut -f2 | sort -u | tr '\n' ' ' |
       sed 's/ $//')" "$3"
}
danger_fixture "a braced if-shell arm"          'if -F 1 { split-window -h }'                  'split-window'
danger_fixture "a quoted multi-word arm"        'if -F 1 "select-window -t 1 ; kill-window"'   'kill-window'
danger_fixture "the second if-shell arm"        'if -F 1 "select-window" "split-window -h"'    'split-window'
danger_fixture "an alias in a quoted arm"       'if -F 1 "popup -E true"'                      'display-popup'
danger_fixture "a single-word alias"            'if -F 1 killw'                                'kill-window'
danger_fixture "a command run-shell -C carries" 'run-shell -t . -C "kill-pane -a"'             'kill-pane run-shell'
danger_fixture "an arm inside an arm"           "if -F 1 \"if -F 1 'run -C killp'\""           'kill-pane run-shell'
danger_fixture "an arm after if-shell -t"       'if -t . -F 1 "kill-window -a"'                'kill-window'
danger_fixture "confirm-before's command"       'confirm-before -p x "kill-pane -a"'           'kill-pane'
danger_fixture "a later line of a braced arm"   $'if -F 1 {\n  select-window\n  if -F 1 "kill-window -a"\n}' 'kill-window'
danger_fixture "a later line of a braced block" $'{\n  select-window\n  if -F 1 "kill-pane -a"\n}' 'kill-pane'
danger_fixture "a block any command is given"   'bind -n F2 { kill-server }'                   'kill-server'
danger_fixture "a name passed as an argument"   'new-window tmux kill-server'                  'kill-server'
danger_fixture "only run-shell without -C"      'run-shell "echo kill-window -a"'              'run-shell'
danger_fixture "nothing in a clean binding"     'if -F 1 "select-window -t 1" { send-keys -M }' ''
danger_fixture "nothing in a binding for ;"     'select-window'                                '' '\;'
danger_fixture "an arm tmux cannot parse"       'if -F 1 "nosuchcommand"'                      '?'

hx_summary "harness self-test"
