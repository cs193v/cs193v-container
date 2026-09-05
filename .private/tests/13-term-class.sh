#!/usr/bin/env bash
# TIER: unit
#
# term_class(), one environment at a time. No podman, no container, no terminal.
#
# WHY THIS EXISTS AS ITS OWN SUITE. The whole per-terminal hint system (#122, #123, #133) hangs
# off one string, and that string is chosen on the HOST because it cannot be chosen anywhere
# else: tmux overwrites TERM_PROGRAM to "tmux" for every pane it spawns (environ.c, since 3.2),
# so nothing inside the container can see which terminal the student is actually using. The
# launcher resolves it once and forwards a token; everything downstream is a lookup. So this
# function is the single point where a wrong answer becomes a wrong instruction on screen, and
# it is pure string arithmetic over the environment -- which makes it exactly the thing to test
# at the cheap tier rather than through a container.
#
# THE OUTPUT IS A CLOSED SET, and that is the property worth protecting rather than any
# individual row. A token that reaches the image and matches nothing there would print an empty
# hint, so the fall-through matters more than the hits: the corpus below ends with a fuzz pass
# that asserts the answer is always one of the six, whatever the environment.
#
# Driven through `cs193v --dev-term-class`, which prints the token and nothing else -- the same
# arrangement as --dev-args and --dev-steps, and for the same reason: the alternative is
# sourcing the launcher, which runs its whole prologue.

set -u
. "$(dirname -- "$0")/lib/assert.sh"

cd "$REPO" || exit 1

# EVERY TERMINAL VARIABLE CLEARED, then only the ones under test set. Without the scrub this
# suite would report whatever terminal the person running it happens to be sitting in -- green
# on a Mac, red in CI, and never the same twice. The list is every variable term_class reads
# plus the ones the rejected guards used to read, so a re-added guard cannot pass by accident.
# A STRING AND NOT AN ARRAY, because macOS ships bash 3.2 and this suite has to run on it:
# `"${arr[@]}"` on an empty array is an unbound-variable error there under `set -u`, and
# 10-static.sh's bash32:empty-array-expansions-guarded rule bans the unguarded form outright.
# Safe to word-split -- these are environment variable NAMES, so none of them contains a space.
SCRUB='TERM_PROGRAM TERM_PROGRAM_VERSION TERM_SESSION_ID LC_TERMINAL LC_TERMINAL_VERSION
       ITERM_SESSION_ID ITERM_PROFILE WT_SESSION WT_PROFILE_ID GNOME_TERMINAL_SERVICE
       GNOME_TERMINAL_SCREEN PTYXIS_VERSION PTYXIS_PROFILE VTE_VERSION KITTY_PID
       KITTY_WINDOW_ID WEZTERM_PANE ALACRITTY_WINDOW_ID GHOSTTY_BIN_DIR GHOSTTY_RESOURCES_DIR
       KONSOLE_VERSION XTERM_VERSION TERMINATOR_UUID TERMINAL_EMULATOR TMUX TMUX_PANE STY
       TERM COLORTERM'

UNSET_ARGS=''
for v in $SCRUB; do UNSET_ARGS="$UNSET_ARGS -u $v"; done

tc() {                                # tc VAR=VAL ... -> the token
    # shellcheck disable=SC2086
    env $UNSET_ARGS "$@" ./cs193v --dev-term-class 2>/dev/null
}

expect() {                            # expect NAME TOKEN VAR=VAL ...
    local name="$1" want="$2"; shift 2
    assert_eq "$name" "$want" "$(tc "$@")"
}

# ─── the five rows that ship ───────────────────────────────────────────────────

# iTerm2 FIRST, and the order is the assertion. iTerm2 sets TERM_PROGRAM=iTerm.app as well as
# its own variables, so a resolver that tested TERM_PROGRAM before ITERM_SESSION_ID would still
# get this right -- but LC_TERMINAL is the only terminal variable designed to survive an ssh
# hop, so it is the one signal that can arrive WITHOUT TERM_PROGRAM beside it.
expect "term-class:iterm2-by-term-program"   iterm2 TERM_PROGRAM=iTerm.app
expect "term-class:iterm2-by-session-id"     iterm2 ITERM_SESSION_ID=w0t0p0:UUID
expect "term-class:iterm2-by-lc-terminal"    iterm2 LC_TERMINAL=iTerm2

expect "term-class:apple-terminal"           apple-terminal TERM_PROGRAM=Apple_Terminal

# EVERY VS CODE FORK IS ONE TOKEN, deliberately. Cursor, Windsurf, VSCodium and Antigravity all
# inherit TERM_PROGRAM=vscode from upstream and none of them changes it -- and they are all
# xterm.js embeddings, so they all want the same instruction. The collision is real and harmless.
expect "term-class:vscode"                   vscode TERM_PROGRAM=vscode

# Windows Terminal sets no TERM_PROGRAM at all; WT_SESSION is the only signal, and it crosses
# into WSL because Windows Terminal puts it in WSLENV itself.
expect "term-class:windows-terminal"         windows-terminal WT_SESSION=abc-123

expect "term-class:vte-gnome-terminal"       vte GNOME_TERMINAL_SERVICE=:1.42
expect "term-class:vte-ptyxis"               vte PTYXIS_VERSION=47.0
expect "term-class:vte-bare-vte-version"     vte VTE_VERSION=7803

# ─── the fall-through ──────────────────────────────────────────────────────────
# EVERY TERMINAL WE DELIBERATELY DID NOT ENUMERATE LANDS HERE, and that is the whole reason the
# shipped list is five terminals rather than fifteen: kitty, Alacritty, WezTerm, Ghostty, foot,
# Warp, Konsole, xterm, Terminator and Tilix all use SHIFT to bypass mouse reporting, which is
# exactly what the `unknown` wording says. Paring the list cost nothing because the default is
# already correct for everything dropped from it.
expect "term-class:empty-environment"        unknown
expect "term-class:kitty-falls-through"      unknown KITTY_PID=99 TERM=xterm-kitty
expect "term-class:ghostty-falls-through"    unknown GHOSTTY_BIN_DIR=/x TERM_PROGRAM=ghostty
expect "term-class:wezterm-falls-through"    unknown WEZTERM_PANE=0 TERM_PROGRAM=WezTerm
expect "term-class:alacritty-falls-through"  unknown ALACRITTY_WINDOW_ID=1 TERM=alacritty
expect "term-class:konsole-falls-through"    unknown KONSOLE_VERSION=250800
expect "term-class:warp-falls-through"       unknown TERM_PROGRAM=WarpTerminal
expect "term-class:unknown-term-program"     unknown TERM_PROGRAM=SomethingNobodyHasHeardOf

# ─── the two guards that were considered and REJECTED ──────────────────────────
# These two cases are here so the decision is pinned rather than merely argued in the plan. Both
# look like oversights to a reader who has not measured them, and both would be "fixed" by adding
# a bail-out that makes the second one WRONG.
#
# INSIDE tmux: no guard is needed, because tmux already overwrote TERM_PROGRAM with "tmux" --
# so nothing matches and the fall-through does the work by itself.
expect "term-class:nested-in-tmux-is-unknown" unknown TMUX=/tmp/x,1,0 TERM_PROGRAM=tmux

# INSIDE screen: a $STY bail-out would be actively WRONG. screen sets no TERM_PROGRAM and scrubs
# nothing -- it filters only TERM, TERMCAP, STY, WINDOW, SCREENCAP, SHELL, LINES and COLUMNS --
# so Apple_Terminal survives, and it is the CORRECT answer: screen requests no mouse reporting by
# default, the outermost terminal is still Terminal.app, and FN still bypasses there. Bailing out
# on $STY would throw away a right answer and substitute SHIFT, which does not work.
expect "term-class:nested-in-screen-keeps-the-terminal" \
        apple-terminal STY=1234.pts-0.host TERM_PROGRAM=Apple_Terminal

# A STALE-TERM_PROGRAM SENTINEL WAS ALSO REJECTED, and this is what that decision looks like.
# TERM_PROGRAM only goes stale when one terminal is launched as a CHILD PROCESS of another's
# shell -- typing `kitty` at a Terminal.app prompt. A terminal launched from the Dock, Finder or
# Spotlight is started by LaunchServices and inherits no TERM_PROGRAM at all, so no path a
# student of this course takes can reach it. Recorded rather than asserted-against: if someone
# later decides the enthusiast case is worth a row, this is the line that changes.
record "term-class:kitty-launched-from-terminal-app" \
       "$(tc KITTY_PID=99 TERM_PROGRAM=Apple_Terminal)"

# ─── the closed set ────────────────────────────────────────────────────────────
# THE FALL-THROUGH MATTERS MORE THAN THE HITS. A token that reaches the image and matches
# nothing there prints an EMPTY hint, which is worse than a wrong one -- the box would show a
# blank line where the instruction goes, and the linkbox's height contract asserts rows, not
# content. So the claim being tested is not "these inputs give these answers" but "no input
# gives anything else".
CLOSED='apple-terminal iterm2 vscode windows-terminal vte unknown'
bad=''
while read -r case_env; do
    [ -n "$case_env" ] || continue
    # shellcheck disable=SC2086
    got="$(tc $case_env)"
    case " $CLOSED " in
        *" $got "*) ;;
        *) bad="$bad [$case_env -> '$got']" ;;
    esac
done <<'CORPUS'
TERM_PROGRAM=
TERM_PROGRAM=Apple_Terminal
TERM_PROGRAM=apple_terminal
TERM_PROGRAM=APPLE_TERMINAL
TERM_PROGRAM=Apple_Terminal_Extra
TERM_PROGRAM=vscode-insiders
TERM_PROGRAM=iTerm.app2
WT_SESSION=
VTE_VERSION=
LC_TERMINAL=iTerm2Extra
LC_TERMINAL=xterm
TERM_PROGRAM=*
TERM_PROGRAM=;rm
TERM=xterm-256color
CORPUS
assert_eq "term-class:answer-is-always-in-the-closed-set" "" "$bad"

# ─── it must not call podman, a tty, or the args files ─────────────────────────
# The unit tier's whole promise, and the same claim 16-args-parse.sh makes about --dev-args --
# but asserted the way that suite asserts it, by making a podman call FAIL LOUDLY rather than by
# emptying PATH. Emptying PATH proves nothing useful: the launcher's prologue needs `uname` and
# `sed` too, so it dies for reasons that have nothing to do with podman and the test goes green
# on a product bug.
SHIM="$(new_tmpdir)"
printf '#!/bin/sh\necho PODMAN-WAS-CALLED >&2\nexit 97\n' > "$SHIM/podman"
chmod +x "$SHIM/podman"
tc_out="$(PATH="$SHIM:$PATH" env -u TMUX -u STY TERM_PROGRAM=Apple_Terminal \
            ./cs193v --dev-term-class 2>"$SHIM/err")"
assert_eq "term-class:answers-without-calling-podman" "apple-terminal" "$tc_out"
assert_eq "term-class:really-did-not-call-podman"     ""               "$(cat "$SHIM/err")"
rm -rf "$SHIM"
