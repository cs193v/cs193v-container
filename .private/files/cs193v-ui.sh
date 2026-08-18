# shellcheck shell=bash
#
# CS193V shared presentation layer — the code that draws.
#
# THREE CONSUMERS, TWO PATHS TO IT.
#
#   * cs193v (the launcher) sources this file out of the checkout, at
#     .private/files/cs193v-ui.sh. It already read .private/messages.txt on every launch, so
#     this adds a second dependency on that directory rather than a first -- but it adds one
#     the launcher cannot degrade around, which is what the guard at the top of cs193v is for:
#     a launcher with no box() cannot draw the box that would report the problem.
#   * setup-git, and any future setup-*, source it from INSIDE the image at /etc/cs193v/ui.sh,
#     the way cs193v-welcome and cs193v-goodbye already source /etc/cs193v/strings.sh. The
#     container cannot see the checkout, so it has to be installed; the Containerfile does
#     that and validates it with `bash -n` in the same layer.
#   * install-cs193v.sh CANNOT source it. It is curl-piped and standalone, so it keeps inline
#     copies of box(), menu() and version_lt(), and 20-messages.sh and 25-installer.sh assert
#     those copies have not drifted from these. That is the one duplication left, where before
#     it was one copy per script.
#
# WHAT BELONGS IN HERE: anything at least two consumers need. Everything below arrived by
# being cut out of the launcher verbatim, comments included — those comments are the record of
# why each function is shaped the way it is, and they are worth more here than they were there.
#
# WHAT DOES NOT: anything only the launcher does. warn()/acknowledge_warnings() and WARN_ACK,
# transient_cleanup, the whole meter_* block, sha_stdin, safe_term and pm/pmq all stayed
# behind, because a container-side script has no podman, no tunnel, and no tmux alternate
# screen to lose its output to.
#
# MUST STAY BASH 3.2 COMPATIBLE. macOS ships bash 3.2 and this is now part of the launcher;
# the container's bash 5 does not relax the rule. No associative arrays, no mapfile, no
# ${var,,}, no `read -t 0.5`.
#
# SOURCING THIS MUST BE INERT: assignments and function definitions only, no traps, no output,
# no reads. Bash keeps exactly ONE EXIT trap, and both the launcher and setup-git install their
# own — so a trap in here would either silently replace theirs or be silently replaced by it.
#
# msg() reads $MESSAGES, which the SOURCING script sets: the launcher points it at
# .private/messages.txt, setup-git at /etc/cs193v/setup-git-messages.txt. Container-side prose
# cannot live in messages.txt because the container cannot see it, and 10-static.sh asserts
# that it does not.

ESC=$(printf '\033')

# ─── output helpers ────────────────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$(printf '\033[1;91m'); C_DIM=$(printf '\033[2m')
    C_CYAN=$(printf '\033[1;36m'); C_YEL=$(printf '\033[1;33m')
    C_GRN=$(printf '\033[1;32m')
    C_OFF=$(printf '\033[0m')
else
    C_RED=''; C_DIM=''; C_CYAN=''; C_YEL=''; C_GRN=''; C_OFF=''
fi

info() { printf '%s\n' "$*"; }
note() { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }

# THE CURSOR IS HIDDEN WHILE THE METER RUNS, and that is not a cosmetic nicety. The block
# redraws ten times a second and the cursor comes to rest wherever the last write left it --
# the end of the bar row on one frame, the end of the caption row on the next -- so a terminal
# that blinks its cursor strobes it between two places at 10 Hz. It is invisible in a
# transcript, which is why no test caught it and why it took someone watching a real install.
#
# RESTORING IT IS THE HALF THAT MATTERS. A launcher that exits with the cursor still hidden
# leaves the student typing blind in that terminal for everything they do afterwards, which is
# a great deal worse than a strobe. So it is restored in meter_stop and again from the EXIT
# trap -- which bash runs on INT, TERM and HUP as well as on a normal exit (verified; Ctrl-C
# during a four-minute build is an entirely ordinary thing for a student to do).
#
# `return 0` on both: the -t test is the last command, and a non-terminal stdout must not make
# these look like failures to a caller or to `set -e` if this script ever gains it.
cursor_hide() { [ -t 1 ] && printf '%s[?25l' "$ESC"; return 0; }
cursor_show() { [ -t 1 ] && printf '%s[?25h' "$ESC"; return 0; }

# ─── the box ───────────────────────────────────────────────────────────────────
# The STOP box, in display columns, corners included. 71 leaves a 67-column text field,
# which is what messages.txt is already hard-wrapped to (ERRORS.md A7) — so the box was
# widened by two rather than the 26 messages rewrapped by one.
#
# The borders are GENERATED from this number rather than typed out. They were typed out
# before, in four separate string literals across two scripts, and the copies in
# install-cs193v.sh had already drifted a column apart from each other without anyone
# noticing — which was easy, because while no box had a right edge there was nothing for a
# width to fail to line up with. See box().
BOX_W=71

# Draws a box around whatever it is given on stdin.
#   box [TITLE] [COLOUR] [INDENT]      defaults: STOP, red, none
#
# The title and colour are parameters because the build's success box (issue #22) is the
# first box here that is not an error, and a second renderer to draw a green one would put
# back exactly the duplication issue #21 removed.
#
# Duplicated verbatim in install-cs193v.sh, the way version_lt already is: the installer is
# curl-piped and standalone, so it cannot source anything from here. 20-messages.sh renders
# BOTH copies and asserts the same shape of both.
#
# awk, and LC_ALL=C awk in particular, because the padding has to be measured in DISPLAY
# COLUMNS and every other way of doing that is wrong somewhere we ship:
#
#   * bash's ${#s} counts characters only in a UTF-8 locale and BYTES in the C locale, so
#     a student with LC_ALL=C would see every line containing — or § padded two columns
#     short. Measured: 32 vs 34 for the same string.
#   * awk's own length() is not multibyte-aware in mawk (Ubuntu's default), which scores
#     the ━ border at 3× and is exactly how an earlier width check passed vacuously.
#
# Stripping UTF-8 continuation bytes (0x80-0xBF) and counting what is left turns a byte
# count into a character count with no locale involved at all. Verified identical under
# gawk, mawk and busybox awk. Everything the box ever contains is a narrow character;
# nothing here would survive CJK, and nothing routes CJK to it.
box() {
    LC_ALL=C awk -v w="$BOX_W" -v title="${1:-STOP}" -v red="${2-$C_RED}" \
                 -v ind="${3:-}" -v off="$C_OFF" '
        function dw(s,  t) { t = s; gsub(/[\200-\277]/, "", t); return length(t) }
        # The first n display columns of s, kept whole: a multibyte character is never
        # sliced down the middle, which is what a byte-wise substr would do.
        function dsub(s, n,  i, c, out, cnt) {
            out = ""; cnt = 0
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c ~ /[\200-\277]/) { out = out c; continue }
                if (cnt >= n) break
                cnt++; out = out c
            }
            return out
        }
        function rule(n,  s) { s = ""; while (n-- > 0) s = s "━"; return s }
        function row(text,  pad, n) {
            pad = ""; n = lim - dw(text)
            while (n-- > 0) pad = pad " "
            printf "%s%s┃%s %s%s %s┃%s\n", ind, red, off, text, pad, red, off
        }
        # Wrap rather than spill. err.create-failed interpolates raw podman output, which is
        # written to no width at all and cannot be hand-wrapped in messages.txt -- only here.
        # A line that already fits is emitted untouched, so the hand-chosen line breaks in
        # messages.txt survive exactly as written.
        function put(text,  lead, rest, chunk, k, brk) {
            # Continuation lines keep the original indent, so a wrapped "    cs193v doctor"
            # stays visibly one item rather than starting a new column.
            lead = text; sub(/[^ ].*$/, "", lead)
            if (dw(lead) >= lim) lead = ""
            rest = text
            while (dw(rest) > lim) {
                chunk = dsub(rest, lim)
                brk = 0
                for (k = length(chunk); k > length(lead); k--)
                    if (substr(chunk, k, 1) == " ") { brk = k; break }
                if (brk > 0) {
                    row(substr(chunk, 1, brk - 1))
                    rest = lead substr(rest, brk + 1)
                } else {
                    # No space to break at: a container id, a URL or a deep path. Broken
                    # hard, because the alternative is breaching the wall we just drew.
                    row(chunk)
                    rest = lead substr(rest, length(chunk) + 1)
                }
            }
            if (dw(rest) > dw(lead) || dw(text) <= lim) row(rest)
        }
        # "┏━━ " is four columns and " " plus "┓" is two, so the rule takes what a title of
        # this width leaves. Measured with dw() like everything else, so a title is free to
        # contain whatever the messages do.
        BEGIN {
            lim = w - 4
            # Built rather than passed in, so this function stays copy-pasteable into
            # install-cs193v.sh with nothing else to keep in step. See the note above.
            esc = sprintf("%c", 27)
            printf "%s%s┏━━ %s %s┓%s\n", ind, red, title, rule(w - 6 - dw(title)), off
        }
        # A tab has no defined width inside a box, and podman emits them. So do COLOUR
        # SEQUENCES and CARRIAGE RETURNS, and those two are worse than untidy, because this box
        # interpolates raw podman output verbatim -- err.build-failed carries the tail of
        # $BUILD_LOG, and err.create-failed the whole of a failure:
        #
        #   * dw() measures a colour sequence as the columns its BYTES would occupy, so a line
        #     carrying one comes out 11 columns short and takes the right wall in with it;
        #   * a \r sends the rest of the row back to column 0 on the way to the terminal, over
        #     the wall this has already drawn.
        #
        # Found by feeding a realistic build log to it rather than by reading one: apt, npm and
        # the Playwright download all emit both, and neither can appear in messages.txt where
        # somebody might have noticed it.
        {
            t = $0
            gsub(esc "\\[[0-9;?]*[A-Za-z]", "", t)
            gsub(esc ".", "", t)
            # Only the last segment of a self-overwriting line was ever on a screen.
            n = split(t, seg, "\r")
            if (n > 1) { t = ""; for (i = n; i >= 1; i--) if (seg[i] != "") { t = seg[i]; break } }
            gsub(/\t/, " ", t)
            put(t)
        }
        END { printf "%s%s┗%s┛%s\n", ind, red, rule(w - 2), off }
    '
}

# The red STOP banner, in the same spirit as the devcontainer's .error.sh: a novice must
# be able to tell "this is course infrastructure, stop and contact staff" from "I typed
# something wrong."
die() {
    printf '\n' >&2
    printf '%s\n' "$*" | box STOP "$C_RED" >&2
    printf '\n' >&2
    exit 1
}

# A green box, for the one thing here that is not a failure. Same renderer, same width.
celebrate() {                         # celebrate TITLE  <- body on stdin
    printf '\n'
    box "$1" "$C_GRN"
    printf '\n'
}

# ─── the spinner glyphs ────────────────────────────────────────────────────────
# Braille rather than the ASCII / - \ | this replaced. Eight frames of a dot pattern
# orbiting a 2x4 cell, which reads as motion at a glance instead of as a character
# flickering between four shapes -- and cannot be mistaken for punctuation in the output.
#
# A `case` rather than ${FRAMES:i:1}: substring extraction on a multibyte string is
# character-wise in a UTF-8 locale and BYTE-wise in the C locale, so indexing would slice
# these three-byte glyphs into fragments for anyone running LC_ALL=C. Same trap as box().
# ok and bad are the two endings rather than frames: the animation has stopped and the line
# is being left on the screen, so what sat in the glyph column has to say which way it went.
# A spinner frame left there reads as a build still running, which is what it did before.
meter_glyph() {                       # meter_glyph N|ok|bad  -> one cell
    case "$1" in
        ok)  printf '%s✓%s' "$C_GRN" "$C_OFF" ;;
        bad) printf '%s✗%s' "$C_RED" "$C_OFF" ;;
        0) printf '⣾' ;; 1) printf '⣽' ;; 2) printf '⣻' ;; 3) printf '⢿' ;;
        4) printf '⡿' ;; 5) printf '⣟' ;; 6) printf '⣯' ;; *) printf '⣷' ;;
    esac
}

# ─── messages ──────────────────────────────────────────────────────────────────
# Student-facing prose lives in messages.txt so it can be reworded without touching
# logic. msg <key> [NAME=value ...]
msg() {
    local key="$1"; shift
    local out kv n v ph head tail
    [ -f "$MESSAGES" ] || { printf '(messages.txt missing)\n'; return 1; }
    out="$(awk -v k="[[$key]]" '
        $0 == k { found = 1; next }
        /^\[\[.*\]\]$/ { if (found) exit }
        found { print }
    ' "$MESSAGES")"
    if [ -z "$out" ]; then printf '(missing message: %s)\n' "$key"; return 1; fi
    for kv in "$@"; do
        n="${kv%%=*}"; v="${kv#*=}"
        ph="{{$n}}"
        # Substitution is done by literal split-and-rejoin. Both obvious alternatives are
        # wrong here, and both fail in ways that only show up in an error path:
        #
        #   sed "s|{{$n}}|$v|g"  — sed's replacement text cannot contain a newline, and
        #       err.create-failed interpolates raw podman output, which is always
        #       multi-line. It printed "unterminated `s' command" and returned nothing, so
        #       die() drew an EMPTY red STOP box: the student got a blank banner at the
        #       exact moment they most needed the diagnosis.
        #
        #   ${out//"$ph"/$v}  — bash 5.2 and newer expand `&` in the replacement to the
        #       matched text, the way sed does, while bash 3.2 treats it literally. Any
        #       podman message containing & would therefore render differently on Linux
        #       than on macOS, which is worse than a bug that is wrong everywhere.
        #
        # `head` accumulates what is already substituted and `tail` is what is left to
        # scan, so a value that itself contains {{NAME}} is copied through instead of
        # being rescanned forever.
        head=''; tail="$out"
        while :; do
            case "$tail" in
                *"$ph"*) head="$head${tail%%"$ph"*}$v"; tail="${tail#*"$ph"}" ;;
                *)       break ;;
            esac
        done
        out="$head$tail"
    done
    printf '%s\n' "$out"
}

# ─── portable timeout ──────────────────────────────────────────────────────────
# GNU `timeout` is NOT on stock macOS, so this is hand-rolled with zero dependencies.
# Every podman probe goes through it: after a Mac wakes from sleep, `podman info` HANGS
# rather than fails (containers/podman#21675), and an unguarded probe makes the launcher
# look frozen with no output at all.
# RT_SPIN turns the wait into something visible: set it to a label and run_timeout animates
# a spinner beside that label until the command returns. Empty for every probe, which is
# almost all of them -- a spinner on a 20-second `podman inspect` that normally takes 40ms
# would be noise. `podman run` is the one that needed it (issue #24): it is allowed 180
# seconds, it says nothing for all of them, and the last line a student saw before the
# silence was "Setting up the course container..." -- which is what an interrupted command
# looks like.
#
# TWO WAYS TO WAIT, and which one a call gets depends only on whether there is a label to
# animate. Issue #38: this function spent longer noticing that its child had finished than the
# child spent running. Measured, before -> after: a launch that finds its container already
# there makes ~14 podman calls and took 3.55s against the fake podman, now 2.16s; `doctor`
# against REAL podman, 4.04s -> 3.10s.
#
#   * NOTHING TO DRAW -- every probe, which is nearly every call -- blocks in `read -t` on a
#     pipe the command's wrapper holds open. That returns the moment the status lands, and
#     `read -t` is poll(2) with a deadline, so the ceiling costs nothing extra and neither
#     outcome involves sleeping. A 4ms `podman image exists` costs 4ms rather than the ~100ms
#     the poll below took to notice it, and a launch does fourteen of them.
#   * A LABEL TO DRAW keeps the 10 Hz poll loop, because a spinner needs a frame clock and
#     bash 3.2 cannot `read -t 0.1` -- fractional timeouts are bash 4, and a static test
#     forbids them, which makes that ban load-bearing rather than hygienic. The cost is one
#     tick on a 180s `podman run` and on each of setup-git's rows, which is invisible; the
#     alternative was a third animated process to own the frames.
#     THE SAME BRANCH IS THE FALLBACK when mkfifo declines -- a TMPDIR on a filesystem with
#     no FIFOs, which is what a WSL student pointed at /mnt/c would have -- so the exact path
#     is skippable and never load-bearing.
#
# The poll loop's spinner costs one printf per two ticks and no extra process. The frame is
# picked with a `case`, not `cut -c`, because a subprocess every 0.2s for three minutes is
# 900 of them for four characters of output.
RT_OUT=''
RT_SPIN=''
# The second mode, added for setup-git's lists of commands. See run_step below for what it is
# for; the only differences from RT_SPIN are the indent and the ending.
RT_ROW=''
run_timeout() {                       # run_timeout SECS CMD...  -> RT_OUT, returns rc
    local secs="$1"; shift
    local tmp fifo pid cpid i rc frame lbl pad end line
    # $$ IN THE NAME so that rt_cleanup can sweep what a signal interrupted. A remembered path
    # cannot: half these calls are made from inside a command substitution, and a variable
    # assigned in that subshell never reaches the parent's trap. See rt_cleanup.
    tmp="$(mktemp "${TMPDIR:-/tmp}/cs193v-$$.XXXXXX")" || return 125
    i=0; rc=124; frame=0
    # One animation, two callers. RT_ROW wins if both are somehow set, because a persistent
    # row is the more specific request. The indent differs because the two live in different
    # output: RT_SPIN covers a wait inside the launcher's own two-space prose, RT_ROW is an
    # item in setup-git's four-space list.
    lbl="$RT_SPIN"; pad='  '
    [ -n "$RT_ROW" ] && { lbl="$RT_ROW"; pad='    '; }
    # UNIQUE BY CONSTRUCTION: mktemp created $tmp with O_EXCL, so nothing else on this machine
    # holds the name this is derived from -- two developers' launchers cannot meet in one
    # TMPDIR. And mkfifo REFUSES a name that exists, so the worst a collision could do is send
    # the call down the poll branch.
    fifo="$tmp.fifo"
    if [ -n "$lbl" ] || ! mkfifo "$fifo" 2>/dev/null; then
        # Only reachable with a name mktemp just proved unique, so anything under it is our
        # own litter from a run that was killed between the mkfifo and the unlink below.
        rm -f "$fifo"
        ( "$@" >"$tmp" 2>&1 ) & pid=$!
        if [ -n "$lbl" ]; then
            # Drawn once up front rather than only from inside the loop, so a command that
            # returns immediately still announces itself instead of flashing nothing.
            #
            # RT_ROW is the exception, and deliberately: with no tty there is no row to
            # overwrite, so it says nothing here and prints its one line at the end WITH the
            # outcome on it. That is what makes a piped transcript one line per step rather
            # than one line per step twice.
            if [ -t 1 ]; then printf '%s%s  %s' "$pad" "$(meter_glyph 0)" "$lbl"
            elif [ -z "$RT_ROW" ]; then printf '%s\n' "$lbl"; fi
        fi
        while [ "$i" -lt "$((secs * 10))" ]; do
            if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; rc=$?; break; fi
            if [ -n "$lbl" ] && [ -t 1 ] && [ "$((i % 2))" -eq 0 ]; then
                # Same braille frames as the meter, so the two never look like different
                # programs. meter_glyph is the single definition of them.
                printf '\r%s%s  %s' "$pad" "$(meter_glyph "$frame")" "$lbl"
                frame=$(( (frame + 1) % 8 ))
            fi
            sleep 0.1
            i=$((i + 1))
        done
    else
        # THE PIPE IS A DEATH CERTIFICATE. The wrapper subshell holds the write end, and its
        # last act is to print the command's status down it -- so the read below returns the
        # moment that lands, rather than at the next tick of a clock nobody set.
        #
        # 9>&- CLOSES IT FOR THE COMMAND ITSELF, which is not belt and braces: podman leaves
        # conmon behind, and anything that inherited the write end would hold the pipe open
        # after podman had gone and turn an EOF into a hang.
        #
        # THE TWO OPENS ARE A RENDEZVOUS -- each blocks until the other arrives, which is how
        # a FIFO with no writer and no reader gets both. mktemp above forked first, so a
        # machine that cannot fork has already left with 125 rather than waiting here.
        #
        # TWO LINES COME BACK, AND THE PID IS THE FIRST OF THEM. It has to be: the wrapper is a
        # subshell AROUND the command here, not the command itself -- bash execs a subshell
        # holding one command in place, which is why the poll branch's $! is podman, and this
        # one's is not. Killing only what $! names at the ceiling would leave the hung
        # `podman info` this whole function exists to time out running as an orphan.
        ( "$@" >"$tmp" 2>&1 9>&- & c=$!; printf '%s\n' "$c" >&9
          wait "$c"; printf '%s\n' "$?" >&9 ) 9>"$fifo" & pid=$!
        exec 9<"$fifo"
        # Unlinked with both ends open: the fd pair survives, the name is finished with, and a
        # signal arriving during the wait leaves nothing behind in TMPDIR.
        rm -f "$fifo"
        cpid=''; line=''
        # ONE CEILING, NOT TWO. The pid arrives the microsecond the wrapper forks, so this read
        # is a formality -- and if it is not, the wrapper never got as far as a command and
        # there is no status to wait for either, so skipping the second read keeps the worst
        # case at $secs rather than doubling it.
        read -t "$secs" -r cpid <&9
        case "$cpid" in
            ''|*[!0-9]*) cpid='' ;;
            *)           read -t "$secs" -r line <&9 ;;
        esac
        exec 9<&-
        # WHETHER A NUMBER ARRIVED, deliberately not read's own exit status -- which is >128 on
        # bash 4 and 1 on the 3.2 macOS ships, so testing it would mean two behaviours. A line
        # IS the answer. No line with the wrapper still alive is the box expiring. No line with
        # it gone is the wrapper itself having been killed, and only `wait` can describe that.
        case "$line" in
            ''|*[!0-9]*) kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; rc=$?; } ;;
            *)           rc="$line"; wait "$pid" 2>/dev/null ;;
        esac
    fi
    # TWO ENDINGS, and the difference between them is the whole of what RT_ROW adds. RT_SPIN
    # covered a wait, so it takes the glyph away and leaves the caller a clean line to print
    # its own outcome on -- a half-drawn spinner frame ahead of a message looks like part of
    # it. RT_ROW *is* the outcome: the row stays, with a check or a cross where the spinner
    # was, because the rows above it are staying too.
    if [ -n "$RT_ROW" ]; then
        end=bad; [ "$rc" -eq 0 ] && end=ok
        if [ -t 1 ]; then printf '\r%s%s  %s%s[K\n' "$pad" "$(meter_glyph "$end")" "$RT_ROW" "$ESC"
        else printf '%s%s  %s\n' "$pad" "$(meter_glyph "$end")" "$RT_ROW"; fi
    elif [ -n "$RT_SPIN" ] && [ -t 1 ]; then
        printf '\r  %s%s[K\n' "$RT_SPIN" "$ESC"
    fi
    # THE COMMAND FIRST, THEN WHATEVER IS WRAPPING IT. cpid is set only by the branch whose $!
    # is a subshell rather than the command, and skipping it there would end the wait while
    # leaving the hung process behind -- which is not a timeout, it is a disowning.
    if [ "$rc" -eq 124 ]; then
        [ -n "$cpid" ] && kill -9 "$cpid" 2>/dev/null
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    fi
    RT_OUT="$(cat "$tmp")"
    rm -f "$tmp"
    return "$rc"
}

# What a signal leaves behind. run_timeout removes its own scratch file on every path that
# reaches the end of it, and a Ctrl-C during a four-minute `podman run` is the path that does
# not -- so one file has been orphaned in TMPDIR per interrupted call since long before the
# pipe arrived. Called from the two EXIT traps that already exist for this: the launcher's
# transient_cleanup and setup-git's sg_cleanup.
#
# A GLOB ON OUR OWN PID, not a remembered path, because run_timeout is called from inside
# command substitutions -- state, label_of, image_label_of -- and a variable assigned in that
# subshell never reaches the parent's trap. The name is the only channel that survives, and $$
# stays the parent shell's pid inside a subshell, which is what makes the two halves agree on
# it; WARN_ACK is built on the same fact.
#
# SCOPED TO $$ RATHER THAN TO cs193v-*, and that is not caution: CS193V_INSTANCE does not
# suffix these, so a second developer's launcher has live scratch files in the same TMPDIR and
# a wider glob would delete them mid-probe.
rt_cleanup() {
    rm -f "${TMPDIR:-/tmp}"/cs193v-$$.* 2>/dev/null
    return 0
}

# ─── a row that runs a command ─────────────────────────────────────────────────
# run_step LABEL CMD...   -> the command's rc; its combined output in RT_OUT
#
# One row per command, glyph in column 5, animated while the command runs and finished with a
# green check or a red cross. setup-git's two lists of commands -- the config it applies, and
# the probes it runs against the sandbox -- are both this, repeated.
#
# THIS IS run_timeout WEARING A DIFFERENT HAT, not a second animator. The poll loop, the
# timeout, the output capture and the braille frames were all already in run_timeout, which
# grew its RT_SPIN mode for exactly this reason (issue #24: `podman run` says nothing for
# three minutes). What RT_SPIN cannot do is LEAVE the row on the screen with an outcome in it:
# it exists to cover a wait, so it clears its line on the way out and lets the caller print
# what happened next. A list of eight commands needs the opposite -- eight rows that persist,
# each carrying its own result. So run_timeout gained RT_ROW beside RT_SPIN: same loop, same
# glyphs, different ending. Two modes of one function, rather than two functions with one
# poll loop each and a second place for the frame rate to drift.
#
# NO CURSOR MOVES, and that is the whole reason this is not the build's meter. Only the row
# being drawn is ever redrawn, always with \r on the line the cursor is already on, so
# nothing here can land a row low and smear the block the way ERRORS.md B18 and the
# METER_ROW arithmetic describe. A block of rows scrolls, resizes and is copy-pasted like
# ordinary output, because that is all it is.
#
# The caller hides the cursor and is responsible for showing it again from an EXIT trap. Not
# done here: run_step is called in a loop, and hiding and showing the cursor per row would
# strobe it exactly the way B18 records.
run_step() {                          # run_step LABEL CMD...
    local label="$1"; shift
    local rc
    RT_ROW="$label"
    run_timeout "${RUN_STEP_SECS:-60}" "$@"
    rc=$?
    RT_ROW=''
    return "$rc"
}

# ─── arrow-key menu ────────────────────────────────────────────────────────────
# Never [y/N]: students do not know that convention this early in the quarter. The
# default is always the SAFE option and is visually highlighted rather than signalled by
# capitalisation. Falls back to the default when there is no tty.
MENU_CHOICE=0
menu() {                              # menu DEFAULT_INDEX opt1 opt2 ...
    local def="$1"; shift
    local opts n sel i key rest
    opts=( "$@" ); n=${#opts[@]}; sel="$def"

    if [ ! -t 0 ] || [ ! -t 1 ]; then
        MENU_CHOICE="$def"
        printf '  (not a terminal; choosing "%s")\n' "${opts[$def]}"
        return 0
    fi

    while :; do
        i=0
        while [ "$i" -lt "$n" ]; do
            if [ "$i" -eq "$sel" ]; then
                printf '  %s▸ %s%s\n' "$C_CYAN" "${opts[$i]}" "$C_OFF"
            else
                printf '    %s\n' "${opts[$i]}"
            fi
            i=$((i + 1))
        done
        printf '\n  %s(use the up and down arrow keys, then press Enter)%s' "$C_DIM" "$C_OFF"

        IFS= read -rsn1 key
        if [ "$key" = "$ESC" ]; then IFS= read -rsn2 rest; key="$key$rest"; fi

        printf '\r%s[K' "$ESC"
        printf '%s[%dA%s[J' "$ESC" "$((n + 1))" "$ESC"

        case "$key" in
            "${ESC}[A"|k|K) sel=$(( (sel + n - 1) % n )) ;;
            "${ESC}[B"|j|J) sel=$(( (sel + 1) % n )) ;;
            ''|"$(printf '\n')") break ;;
            [1-9]) if [ "$key" -le "$n" ]; then sel=$((key - 1)); break; fi ;;
        esac
    done
    printf '  %s▸ %s%s\n\n' "$C_CYAN" "${opts[$sel]}" "$C_OFF"
    MENU_CHOICE="$sel"
}

confirm() {                           # confirm "no-text" "yes-text"  -> 0 if yes
    menu 0 "$1" "$2"
    [ "$MENU_CHOICE" -eq 1 ]
}

# ─── small utilities ───────────────────────────────────────────────────────────
version_lt() {                        # version_lt A B -> prints yes if A < B
    awk -v a="$1" -v b="$2" 'BEGIN{
        na = split(a, A, "."); nb = split(b, B, ".")
        for (i = 1; i <= 3; i++) {
            x = (i <= na ? A[i] + 0 : 0); y = (i <= nb ? B[i] + 0 : 0)
            if (x < y) { print "yes"; exit }
            if (x > y) { print "no";  exit }
        }
        print "no" }'
}
