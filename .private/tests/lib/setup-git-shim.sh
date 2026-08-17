# shellcheck shell=bash
#
# Helpers for driving setup-git through a pty. Source after lib/assert.sh.
#
# MUST STAY BASH 3.2 COMPATIBLE.
#
# Two suites use these and they want opposite things from PATH: 35-setup-git-shim.sh puts
# lib/gh-fake and lib/git-fake in front of it, and 90-setup-git-github.sh must not, because it is
# the one that talks to the real API. So sg_new decides what goes on PATH and sg_tty only prepends
# $SGSHIM — which holds the fakes in one case and nothing executable in the other.

SGDIRS=''

# sg_new [real]  -> a fresh shim directory in $SGSHIM, with the fakes in it unless told otherwise.
#
# A fresh one per case keeps state from leaking between them, and it doubles as the run's TMPDIR
# so setup-git's own scratch directory lands somewhere the suite can look at and clean up.
sg_new() {
    SGSHIM="$(mktemp -d "${TMPDIR:-/tmp}/cs193v-sg.XXXXXX")"
    export SGSHIM CS193V_SGSHIM="$SGSHIM"
    if [ "${1:-fake}" = fake ]; then
        cp "$TESTS_DIR/lib/gh-fake"  "$SGSHIM/gh"
        cp "$TESTS_DIR/lib/git-fake" "$SGSHIM/git"
        chmod +x "$SGSHIM/gh" "$SGSHIM/git"
    fi
    : > "$SGSHIM/argv.log"
    SGDIRS="$SGDIRS $SGSHIM"
}
sg_set()   { printf '%s' "$2" > "$SGSHIM/$1"; }
sg_touch() { : > "$SGSHIM/$1"; }
sg_log()   { cat "$SGSHIM/argv.log" 2>/dev/null; }
sg_count() { sg_log | grep -cE "$1" || true; }
sg_cleanup_all() { local d; for d in $SGDIRS; do rm -rf "$d"; done; }

# ONE KEYSTROKE AT A TIME, separated by |, with a pause between them — and that is a requirement,
# not politeness. MEASURED: bash's `read -n1` puts the terminal into non-canonical mode and
# restores it afterwards, and the restore DISCARDS whatever is queued behind it. Push a whole
# session into the pty up front and the FIRST menu works, the second reads ^D, and everything
# typed after it is gone. Reproduced outside these suites in six lines, so it is bash and the tty
# discipline rather than anything in setup-git:
#
#     read -r a; read -rsn1 k; read -r b; read -rsn1 k; read -r c
#     printf 'one\n\ntwo\n\nthree\n' | script -q -c ... /dev/null
#     ->  A=[one] K1=[] B=[two] K2=[04] C=[]        with the input pushed at once
#     ->  A=[one] K1=[] B=[two] K2=[]  C=[three]    with 0.3s between keystrokes
#
# 30-launcher-shim.sh never met this because no launcher flow has two menus in it, and a student
# never will either — a human types one key at a time, which is exactly what this reproduces. Each
# keystroke is one answer: a whole typed line ending in \n, or one escape sequence.
SG_KEY_DELAY="${SG_KEY_DELAY:-0.3}"
sg_feed() {                           # sg_feed KEYS  -> the bytes, paced, on stdout
    local ks="$1" k
    while [ -n "$ks" ]; do
        case "$ks" in
            *"|"*) k="${ks%%|*}"; ks="${ks#*|}" ;;
            *)     k="$ks"; ks='' ;;
        esac
        printf '%b' "$k"
        sleep "$SG_KEY_DELAY"
    done
}

# KEYS goes through printf %b, so \n is Enter and \033[B is a down arrow. Extra arguments are
# VAR=VALUE settings for this run only, so each case is independent of the last.
#
# TWO WAYS TO NAME WHAT RUNS, because the two suites need different binaries under it:
#
#   * $SG_SETUP_GIT plus $SG_ENV — the checkout's copy, on this machine, with the fakes ahead of it
#     on PATH. That is 35-setup-git-shim.sh, and it is the default.
#   * $SG_RUN, a whole command line, used verbatim. That is 90-setup-git-github.sh, which runs the
#     INSTALLED copy inside the container via `podman exec`, because the point of that suite is to
#     record what gh says and the image's gh is fifty versions ahead of a host package. Per-run
#     VAR=VALUE extras do not apply to it: `env A=B podman exec` sets A on podman, not in the
#     container, so anything that has to reach the script goes in the exec's own -e flags.
sg_tty() {                            # sg_tty KEYS [VAR=VAL ...]
    local keys="$1"; shift
    local cmd a
    if [ -n "${SG_RUN:-}" ]; then
        cmd="$SG_RUN"
    else
        # TMPDIR points at this case's own shim, so setup-git's scratch directory and clone land
        # somewhere the suite can inspect afterwards and remove wholesale. Before the extras, so a
        # case can still override either.
        cmd="env $SG_ENV TMPDIR=$SGSHIM CS193V_SGSHIM=$SGSHIM"
        for a in "$@"; do cmd="$cmd $a"; done
        cmd="$cmd bash $SG_SETUP_GIT"
    fi
    # util-linux script takes -c CMD; BSD/macOS script takes the command as trailing words.
    if script --version 2>&1 | grep -qi util-linux; then
        sg_feed "$keys" | PATH="$SGSHIM:$PATH" timeout "${SG_TIMEOUT:-120}" \
            script -q -c "$cmd" /dev/null 2>&1
    else
        # shellcheck disable=SC2086
        sg_feed "$keys" | PATH="$SGSHIM:$PATH" timeout "${SG_TIMEOUT:-120}" \
            script -q /dev/null $cmd 2>&1
    fi
}

# ─── reading the transcript ────────────────────────────────────────────────────
# Two layers sit between a message in the catalogue and the same words in the transcript, and both
# have to come off before a phrase can be looked for.
#
#   * THE TERMINAL added them: colour, cursor moves, and a \r at the end of every line, because a
#     pty maps \n to \r\n on the way out. _flatten in assert.sh knows about box art and newlines
#     and about neither of those.
#   * THE MARKUP took them away: setup-git renders *asterisks* as colour, so the phrase in the
#     catalogue still has its asterisks and the transcript has escape sequences where they were. A
#     needle carrying `*Before we go on` can never match, and would fail for a reason that looks
#     like the message being absent.
#
# So these strip both sides and assert on what a student actually reads — by KEY rather than by
# quoted prose, for the reason assert_says_key exists: a test that hardcodes wording fails the day
# somebody rewords the catalogue, which punishes the wrong change.
SG_ESC="$(printf '\033')"
sg_plain() {                          # sg_plain TEXT -> the words, with the terminal removed
    printf '%s' "$1" | tr -d '\r' | sed -e "s/${SG_ESC}\\[[0-9;?]*[A-Za-z]//g" \
        | tr '\n' ' ' | sed -e 's/[[:space:]][[:space:]]*/ /g'
}
sg_phrase() {                         # sg_phrase KEY -> its prose, markup removed
    msg_text "$1" "$SGM" | tr -d '*' | sed -e 's/[[:space:]][[:space:]]*/ /g'
}
# An unknown or all-placeholder key fails rather than passing vacuously — the same trap
# assert_says_key records, and worse in the negative form, where an empty needle passes always.
sg_says() {                           # sg_says NAME KEY TEXT
    local phrase; phrase="$(sg_phrase "$2")"
    case "$phrase" in ''|' ') fail "$1" "no literal prose for key: $2"; return 0 ;; esac
    assert_contains "$1" "$phrase" "$(sg_plain "$3")"
}
sg_says_not() {                       # sg_says_not NAME KEY TEXT
    local phrase; phrase="$(sg_phrase "$2")"
    case "$phrase" in ''|' ') fail "$1" "no literal prose for key: $2"; return 0 ;; esac
    assert_not_contains "$1" "$phrase" "$(sg_plain "$3")"
}

# The same, for a phrase rather than a key. Needed more often than it looks: `exit code 42` is
# rendered as `exit code <cyan>42<off>`, so a needle spanning an emphasised word matches nothing in
# the raw transcript, and the failure reads as the number being wrong rather than the escape
# sequences being in the way. Six assertions failed that way before this existed.
sg_has()     { assert_contains     "$1" "$2" "$(sg_plain "$3")"; }
sg_has_not() { assert_not_contains "$1" "$2" "$(sg_plain "$3")"; }

# Colour and \r removed, everything ELSE left exactly as it was — which is what box_problems needs:
# it measures display columns and looks for a border at each end, so sg_plain's whitespace
# collapsing would destroy the padding it is there to check, while the colour it would otherwise
# count as columns makes every line eleven too wide.
#
# The two-column indent comes off too. setup-git draws its box indented to match the rest of the
# screen; box_problems, shared with the launcher's unindented boxes, wants the border in column 1.
sg_box() {                            # sg_box TEXT -> just the box, ready for box_problems
    printf '%s' "$1" | tr -d '\r' | sed -e "s/${SG_ESC}\\[[0-9;?]*[A-Za-z]//g" -e 's/^  //' \
        | sed -n '/[┏]/,/[┗]/p'
}
