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
if printf '%s' "$loc" | grep -qE '^[0-9]+ [0-9]+$'; then
  hx_pass "hx_find locates on-screen text (row/col = $loc)"
else
  hx_fail "hx_find locates on-screen text" "got '$loc'"
fi

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

hx_summary "harness self-test"
