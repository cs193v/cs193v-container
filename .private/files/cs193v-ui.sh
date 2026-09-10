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
#     the way cs193v-welcome already sources /etc/cs193v/strings.sh. The container cannot see
#     the checkout, so it has to be installed; the Containerfile does that and validates it
#     with `bash -n` in the same layer.
#   * course-install.sh -- the installer proper -- sources it out of the tree the bootstrap
#     downloaded, at the same .private/files/cs193v-ui.sh the launcher uses, just under a
#     mktemp directory instead of a checkout. THIS IS WHAT #221 CHANGED. install-cs193v.sh used
#     to be one file a student downloaded on its own, so it could source nothing and carried
#     inline copies of box(), menu(), version_lt(), platform(), ensure_podman_path() and the
#     podman floors; two suites existed to assert those copies had not drifted. Fetching the
#     tree FIRST means there is something to source, so there is one copy of each and nothing
#     to keep in agreement.
#   * install-cs193v.sh -- the bootstrap -- still sources nothing, and that is the property the
#     split rests on rather than a limitation. It is the file a student downloads and checks a
#     SHA-256 against: it finds a downloader, fetches the tree, checks the pieces arrived and
#     execs course-install.sh, and 10-static.sh asserts it sources and evals nothing so it
#     stays readable in one sitting.
#
# WHAT BELONGS IN HERE: anything at least two consumers need. Everything below arrived by
# being cut out of the launcher verbatim, comments included — those comments are the record of
# why each function is shaped the way it is, and they are worth more here than they were there.
#
# WHAT DOES NOT, AND THE RULE CHANGED WITH #221. It used to be "anything only the launcher
# does", justified by a container-side script having no podman, no tunnel and no tmux
# alternate screen. That reason no longer decides, because the second host-side consumer
# arrived: install-cs193v.sh was split so that the installer proper could source this file
# instead of carrying copies, and what it needed came here -- the podman floors, the receipt
# id, platform(), min_podman(), ensure_podman_path() and the whole meter RENDERER.
#
# SO THE TEST IS "TWO CONSUMERS NEED IT", NOT "THE LAUNCHER DOES IT". The provider half of the
# meter stayed in cs193v on exactly that test: build_progress and CF_PARSE_AWK know podman's
# `STEP i/N` grammar, which is a launcher concern, while the renderer draws whatever it is
# handed and now has two callers.
#
# THE METER ARRIVES IN THE IMAGE WITH NO CONTAINER CONSUMER, and that is deliberate rather than
# an oversight nobody has noticed. This whole file is installed at /etc/cs193v/ui.sh for
# setup-git, so ~410 lines of renderer go with it that nothing inside the container calls.
# Splitting it in two to avoid that was weighed and declined: it would put a second shared file
# and a second sourcing path in front of every reader to save a directory nobody measures.
# None of them has a reader inside the image. That is expected, not an oversight -- and until
# the split lands, the installer still carries its own copies and the drift tests still diff
# them against these.
#
# The rule that replaced it: anything at least two consumers need, wherever they run. What is
# still launcher-only is what only the launcher can want -- warn()/acknowledge_warnings() and
# WARN_ACK, the EXIT trap itself, sha_stdin, safe_term, term_class, pm/pmq, and the meter's
# PROVIDER (build_progress and CF_PARSE_AWK, which know podman's STEP grammar and the
# Containerfile's ####> markers). The renderer/provider line is the one worth keeping straight:
# this file draws the block; the consumer decides what the block says.
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

# ─── the four presentation knobs  (#221) ──────────────────────────────────────
# THREE CONSUMERS DRAW AT DIFFERENT DEPTHS, and these are the whole of the difference.
# install-cs193v.sh prints inside an indented step list, so its notes, its menu and its
# STOP boxes sit two columns deeper than the launcher's, and its refusals carry a
# sign-off. Those used to be a second copy of note(), die() and menu(); they are four
# variables now.
#
# THE DEFAULTS ARE WHAT THE LAUNCHER AND setup-git PRINTED BEFORE, exactly, so neither
# had to change and 20-messages.sh asserts each default as well as each override.
#
# VALUES, NOT msg() KEYS, deliberately: a key would have to exist in all three
# catalogues, and this file has no business reading any of them.
NOTE_INDENT=''
MENU_INDENT='  '
MENU_HINT='(use the up and down arrow keys, then press Enter)'
DIE_INDENT=''
DIE_TRAILER=''

info() { printf '%s\n' "$*"; }
note() { printf '%s%s%s%s\n' "$NOTE_INDENT" "$C_DIM" "$*" "$C_OFF"; }

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

# ─── taking back the row above ─────────────────────────────────────────────────
# For the one row this launcher does not write and cannot suppress: tmux's `[exited]`.
#
# THERE IS NO tmux OPTION FOR IT. The client's exit message is an unconditional
# `printf("[%s]\n", client_exit_message())` in tmux's own client.c, guarded on nothing but
# "was attached" and "has a reason" -- so no line in /etc/cs193v/tmux.conf can reach it, and
# every reachable reason has a string. Rearranging the session lifetime only changes WHICH
# string: detaching first says "detached (from session cs193v)", killing the server says
# "server exited". Erasing it afterwards is the only option that does not rest on tmux's
# internals, and it fails soft -- a terminal that ignores these leaves a stray line rather
# than a blank screen.
#
# 1A THEN \r THEN 0J, and each of the three is chosen rather than convenient:
#   * ESC[1A leaves the COLUMN alone, so the \r is what actually gets us to the left margin.
#     Without it the erase would start wherever the cursor happened to sit.
#   * ESC[J -- erase to end of SCREEN -- rather than ESC[K's end of line, so a message that
#     wrapped onto a second row goes too. There is nothing below the cursor to lose: this only
#     ever runs on the row after the last thing written to the terminal.
#   * All three are sequences lib/assert.sh's render_pty models, which is what lets a test
#     assert against the screen a student sees rather than the bytes that produced it. Its own
#     comment records the hazard: 2J and 3J are deliberately NOT modelled, so an erase built
#     from clean_break's clear would be asserted by a replayer that silently ignored it.
#
# `return 0` and the -t guard for the same reasons as the two above: piped output must carry no
# escapes, and the test must not look like a failure to a caller.
line_erase_above() { [ -t 1 ] && printf '%s[1A\r%s[J' "$ESC" "$ESC"; return 0; }

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
# ONE COPY SINCE #221, where there used to be two. install-cs193v.sh carried this verbatim,
# because a file downloaded on its own can source nothing; the installer proper sources this one
# now. What used to be "20-messages.sh renders both copies and asserts the same shape of both"
# is now a single renderer drawn twice -- once at the launcher's indent and once at the
# installer's, through the knobs below -- which is a stronger test of the thing students see.
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
    printf '%s\n' "$*" | box STOP "$C_RED" "$DIE_INDENT" >&2
    printf '\n' >&2
    # THE SIGN-OFF IS THE INSTALLER'S ALONE, and empty everywhere else. It was one of the three
    # reasons install-cs193v.sh carried its own die(); it is one variable now.
    [ -n "$DIE_TRAILER" ] && { printf '%s\n\n' "$DIE_TRAILER" >&2; }
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
    [ -f "$MESSAGES" ] || { printf '(catalogue missing: %s)\n' "$MESSAGES"; return 1; }
    out="$(awk -v k="[[$key]]" '
        $0 == k { found = 1; next }
        /^\[\[.*\]\]$/ { if (found) exit }
        # A HASH AT COLUMN 0 IS A NOTE TO STAFF AND IS NEVER PRINTED (#221). This is the one
        # thing the installer version of this reader did that msg() did not, and the split
        # hands msg() that catalogue to read: much of what makes those messages right is the
        # note beside them explaining why they say what they say. Indented is prose, so a
        # student-facing line beginning with a hash is written with a leading space.
        #
        # NO APOSTROPHES IN HERE. This awk program is single-quoted inside a command
        # substitution, so one would close it and the file would stop parsing.
        found && /^#/ { next }
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
# The command's stderr is KEPT SEPARATE from RT_OUT rather than merged into it. Set by pmv, for
# the reads whose ANSWER is used as a value -- and it is a fix rather than tidying (#171).
# podman writes warnings to stderr and exits 0, so merged, a warning line becomes part of the
# value: preflight's rootless check compares `level=warning ...\ntrue` against `true` and
# refuses the machine as "rootful", a message that says it is not something to work around.
#
# NO MISCONFIGURATION IS NEEDED, AND THAT IS THE POINT OF THE MODE. The reproduction is one
# unrecognised key in storage.conf, which is where this was found -- but the population case is
# the FIRST podman call after a boot, on a stock machine with nothing wrong with it: podman does
# its post-boot store fix-ups then and says so on stderr. Measured in the field on WSL2 with
# podman 5.7.0 and a fresh clone -- the distro booted at 09:16:47, /run/user/1000/libpod was
# created at 09:18, and by 09:26 the same read answered a bare `true` again. So the reach is
# every platform, and the evidence is GONE by the time anyone looks, which is why RT_ERR below
# exists rather than a `2>/dev/null`. `--log-level=error` does not suppress the storage line
# either; it comes from the storage-config loader, outside the log-level filter.
#
# DEFAULT OFF, AND THAT IS LOAD-BEARING. The readers that WANT stderr are the ones that report a
# failure rather than using an answer -- podman_version_of, create_container's ENOSPC and
# "already in use" matching, err.create-failed's OUT=, run_step's transcript -- and
# 12-run-timeout.sh's rt:captures-stderr is the assertion that it stays that way.
RT_BARE=''
# What RT_BARE took out of the answer, for the caller that has to explain a refusal. The first
# cut of RT_BARE sent stderr to /dev/null, which fixed the value and threw away the only record
# of why it had needed fixing -- and on a trigger that erases itself (see above) that leaves the
# student a dead end and staff nothing to read. err.create-failed's `OUT=` is the house
# precedent for quoting podman into a refusal; this is the same idea for a read.
#
# ONLY IN BARE MODE, and empty otherwise: the merging default has stderr in RT_OUT already, and
# a second copy would be a second thing to keep in step. Cleared on every call either way, so a
# caller testing it cannot be handed the PREVIOUS call's stderr.
RT_ERR=''
run_timeout() {                       # run_timeout SECS CMD...  -> RT_OUT, returns rc
    local secs="$1"; shift
    local tmp fifo eout pid cpid i rc frame lbl pad end line
    # $$ IN THE NAME so that rt_cleanup can sweep what a signal interrupted. A remembered path
    # cannot: half these calls are made from inside a command substitution, and a variable
    # assigned in that subshell never reaches the parent's trap. See rt_cleanup.
    tmp="$(mktemp "${TMPDIR:-/tmp}/cs193v-$$.XXXXXX")" || return 125
    # cpid WITH THEM, and not in the branch that has a use for it: `local cpid` leaves the name
    # unset rather than empty from bash 4.4 on, and the 124 arm below reads it whichever branch
    # ran. See the comment there for what that cost (#205).
    i=0; rc=124; frame=0; cpid=''
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
    # A SIBLING OF $tmp, for the reason the fifo is one: mktemp created $tmp with O_EXCL, so
    # nothing else on this machine holds the name these are derived from, and rt_cleanup's
    # `cs193v-$$.*` glob sweeps them both without being told about either.
    eout="$tmp.err"
    if [ -n "$lbl" ] || ! mkfifo "$fifo" 2>/dev/null; then
        # Only reachable with a name mktemp just proved unique, so anything under it is our
        # own litter from a run that was killed between the mkfifo and the unlink below.
        rm -f "$fifo"
        # SPELLED TWICE RATHER THAN PARAMETERISED. `2>&"$efd"` is a bash extension and this file
        # has to run on the 3.2 macOS ships, which 10-static.sh polices.
        if [ -n "$RT_BARE" ]; then ( "$@" >"$tmp" 2>"$eout" ) & pid=$!
        else                       ( "$@" >"$tmp" 2>&1 ) & pid=$!
        fi
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
        # The two arms differ in ONE redirection and are otherwise identical. Deliberately not
        # factored into a helper called from both: that would put a shell between $c and the
        # command, and the ceiling's `kill -9 "$cpid"` below would then kill the wrapper and
        # leave the hung podman running -- which is the disowning the comment above warns about.
        if [ -n "$RT_BARE" ]; then
          ( "$@" >"$tmp" 2>"$eout" 9>&- & c=$!; printf '%s\n' "$c" >&9
            wait "$c"; printf '%s\n' "$?" >&9 ) 9>"$fifo" & pid=$!
        else
          ( "$@" >"$tmp" 2>&1 9>&- & c=$!; printf '%s\n' "$c" >&9
            wait "$c"; printf '%s\n' "$?" >&9 ) 9>"$fifo" & pid=$!
        fi
        exec 9<"$fifo"
        # Unlinked with both ends open: the fd pair survives, the name is finished with, and a
        # signal arriving during the wait leaves nothing behind in TMPDIR.
        rm -f "$fifo"
        # RESTATED rather than left to the seeding at the top, and the duplicate is deliberate:
        # $line starts here and nowhere else, so the two read as one pair that the `read` below
        # is about to fill, with neither half of it eighty lines away.
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
    # THE COMMAND FIRST, THEN WHATEVER IS WRAPPING IT. Only the fifo branch has the two to tell
    # apart: there $! is a subshell AROUND the command, so ending the wait without killing $cpid
    # would leave the hung process behind -- which is not a timeout, it is a disowning. On the
    # poll branch $! IS the command, bash having exec'd `( cmd ) &` in place, so empty here is
    # the TRUE answer rather than a convenient one.
    #
    # WHICH IS WHY IT IS SEEDED WITH THE RUN-SCOPED STATE at the top rather than beside the read
    # that fills it. This comment used to state that precondition with nothing enforcing it, and
    # a bare `local` leaves the name UNSET on bash >= 4.4 -- so under the `set -u` both consumers
    # of this file set, every labelled call that reached its ceiling died with `cpid: unbound
    # variable` instead of timing out: the launcher's 180s `podman run` under a spinner, and all
    # twelve of setup-git's rows, since run_step sets RT_ROW on every one of them (#205).
    if [ "$rc" -eq 124 ]; then
        [ -n "$cpid" ] && kill -9 "$cpid" 2>/dev/null
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    fi
    RT_OUT="$(cat "$tmp")"
    # AFTER THE CEILING'S kill, not before: a command killed at $secs has usually said why on
    # its way out, and that line is the most useful one there is. Cleared unconditionally so
    # the bare mode's answer never carries over into a merging call, or the other way round.
    #
    # `[ -s ]` GUARDS THE FORK. The common case is a podman that says nothing, and a command
    # substitution costs a process; `-s` is a builtin, so the quiet path pays a stat instead.
    RT_ERR=''
    [ -n "$RT_BARE" ] && [ -s "$eout" ] && RT_ERR="$(cat "$eout")"
    # ONE rm FOR BOTH FILES, and that is measured rather than tidy: `rm` is an external command,
    # so removing the stderr file separately cost bare mode a SECOND fork+exec on every read --
    # 10.6-13.1 ms per call became 12.5-16.7 ms, on a path a launch takes about fourteen times.
    # `-f` on a name that was never created (every non-bare call) is silent and free.
    rm -f "$tmp" "$eout"
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
        printf '%s(not a terminal; choosing "%s")\n' "$MENU_INDENT" "${opts[$def]}"
        return 0
    fi

    while :; do
        i=0
        while [ "$i" -lt "$n" ]; do
            if [ "$i" -eq "$sel" ]; then
                printf '%s%s▸ %s%s\n' "$MENU_INDENT" "$C_CYAN" "${opts[$i]}" "$C_OFF"
            else
                printf '%s  %s\n' "$MENU_INDENT" "${opts[$i]}"
            fi
            i=$((i + 1))
        done
        printf '\n%s%s%s%s' "$MENU_INDENT" "$C_DIM" "$MENU_HINT" "$C_OFF"

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
    printf '%s%s▸ %s%s\n\n' "$MENU_INDENT" "$C_CYAN" "${opts[$sel]}" "$C_OFF"
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

# podman_version_of TEXT -> just the version, or empty
#
# ANCHORED TO THE LINE THAT ACTUALLY CARRIES A VERSION, which is the whole point. This used to be
# `awk '{print $NF}'` at two call sites, and awk runs that per LINE -- so it printed the last field
# of EVERY line it was given. The text handed in is run_timeout's RT_OUT, and run_timeout captures
# the command's stderr along with its stdout, so any second line podman writes turns a version
# into two words.
#
# ONE DEFINITION FOR TWO CALLERS -- the version gate and doctor -- because they were byte-identical
# and a drifted copy is exactly how this survived. `[0-9][^ ]*` rather than something stricter so
# that a version this does not anticipate (a 5.7.0-rc1, a distro's 4:5.7.0+ds1) is still returned
# whole for version_lt to judge, rather than silently truncated to something that compares wrong.
#
# AND THERE IS A FALLBACK, because anchoring on podman's exact wording is a NEW assumption and
# this is the one number the launcher refuses to start over. If no line says "podman version N",
# the old reading is used -- but on the FIRST LINE ONLY, which is the whole bug fixed and none of
# the robustness given up. 26-installer-sandbox.sh keeps a real 3.4.4 binary around precisely
# because it expects podman's output format to be able to change; this way a change costs the
# anchor, not the launcher.
podman_version_of() {                 # podman_version_of TEXT -> the version, or empty
    local v
    v="$(printf '%s' "$1" | sed -n 's/^podman version \([0-9][^ ]*\).*/\1/p' | head -1)"
    [ -n "$v" ] || v="$(printf '%s' "$1" | awk 'NR==1{print $NF}')"
    printf '%s' "$v"
}

# ─── host facts: the platform, the podman floors, and finding podman ───────────
#
# MOVED HERE OUT OF cs193v (#221). These have no container consumer -- setup-git and
# cs193v-linkbox will never ask which podman a Mac hid where -- and they are here anyway,
# because the installer needs them and the installer can source this file. That is the whole
# of the change: what used to be a copy in install-cs193v.sh and a copy in cs193v is now one
# definition that both read.
#
# So the rule at the top of this file gains a clause. "Anything at least two consumers need"
# still holds; "and both consumers may be host-side" is new. A function down here with no
# reader inside the image is expected, not an oversight.

# ─── the oldest podman the course works with, per platform ─────────────────────
# TWO FLOORS, and install-cs193v.sh carries the same pair for the same reasons -- the long form
# of the argument lives there. In brief: on Linux the floor decides which DISTROS work, and 4.9.0
# is measured (Ubuntu 24.04 LTS and everything on it, Debian 13 stable, Ubuntu 25.x, Fedora GA);
# on a Mac it decides nothing about distros and lowering it would admit the pre-5.0 `podman
# machine`, which nothing can test. 25-installer.sh asserts both copies agree and that the macOS
# floor is never the lower of the two.
MIN_PODMAN_LINUX="4.9.0"
MIN_PODMAN_MACOS="5.7.0"

# ─── where podman is when it is not on PATH ────────────────────────────────────
# ISSUE #121, AND IT IS NOT A PATH THE STUDENT BROKE. The macOS .pkg this course installs
# announces its binaries with one line -- `echo /opt/podman/bin > /etc/paths.d/podman-pkg` --
# and nothing reads /etc/paths.d but /usr/libexec/path_helper, which runs from /etc/zprofile,
# i.e. only when a LOGIN shell starts. So the terminal window that ran the installer never
# sees podman, and neither does any `zsh -c`: measured from a bare PATH, `bash -l` and `zsh -l`
# pick /opt/podman/bin up and every non-login shell does not, which is why "open a new
# terminal" is a workaround for some students and not others.
#
# THE INSTALLER CANNOT FIX THIS. A child process cannot write into its parent's environment,
# so its own `export PATH` -- which is why machine init, --rebuild and the smoke test all pass
# -- dies with it, and the student is handed back a shell that was never told. Only the
# launcher can repair the launcher's PATH.
#
# NOTHING UPSTREAM IS COMING. containers/podman#15831 WAS a podman bug: the postinstall used to
# append to ~/.bash_profile, ~/.zshenv, ~/.zshrc and fish's config, and skipped every branch on
# a fresh Mac that has none of them. PR #15854 deleted all of it in favour of the /etc/paths.d
# line above and was closed as fixed; #15542, #17910 and #27669 are the same report again and
# are closed too, the last of them ("command not found: podman" under oh-my-zsh, which skips
# /etc/zprofile entirely) as not a podman bug. Their contract is "the next login shell sees
# podman", and they are entitled to it -- no .pkg can do better. It is OUR say_done that tells
# a student to run ./cs193v in the window that cannot.
#
# THE IDENTIFIER RATHER THAN THE DIRECTORY, so nothing here guesses: ensure_podman_path asks
# macOS's own receipt where the payload went, and a future .pkg that moves it is still found.
# The .pkg declares this string itself, in its PackageInfo -- `identifier="com.redhat.podman"`
# -- so when install-cs193v.sh's PODMAN_MACOS_VERSION is bumped, check it there.
#
# ONE COPY SINCE #221. This was duplicated verbatim into install-cs193v.sh, and 25-installer.sh
# diffed the two for the reason it asserted the podman floors agreed: the installer runs FIRST
# and the launcher runs LAST, so a disagreement between them IS issue #121 over again. The
# installer proper sources this file, so there is nothing left to diff -- and the floors went
# the same way, which is what retired 26-installer-sandbox.sh's floor-skew case in the shape it
# had. That case now asserts the opposite: raise this number and BOTH ends move together.
PODMAN_PKG_ID="com.redhat.podman"
# Which directory the repair had to add, so `doctor` can say so. Empty means PATH was fine.
PODMAN_PATH_ADDED=""

platform() {
    case "$(uname -s)" in
        Darwin) printf 'macos' ;;
        Linux)  if grep -qi microsoft /proc/version 2>/dev/null; then printf 'wsl'
                else printf 'linux'; fi ;;
        *)      printf 'other' ;;
    esac
}

min_podman() {                        # min_podman -> the floor for THIS platform
    case "$(platform)" in
        macos) printf '%s' "$MIN_PODMAN_MACOS" ;;
        *)     printf '%s' "$MIN_PODMAN_LINUX" ;;
    esac
}

# podman that is INSTALLED AND INVISIBLE: issue #121, whose whole mechanism is written up at
# PODMAN_PKG_ID above. Repairs THIS process's PATH, and every child's, when podman is installed
# somewhere PATH does not name; a no-op on every machine whose PATH is already right.
#
# THE GUARD IS THE FIRST LINE, so a healthy launch pays nothing -- no pkgutil, no forks. It is
# also what makes appending safe: reaching the loop means PATH holds no podman at all, so
# nothing can be shadowed by adding a directory, and appending rather than prepending keeps the
# new directory from taking precedence for every OTHER name the launcher runs.
#
# PATH RATHER THAN A $PODMAN VARIABLE, deliberately. ensure_tunnel builds
# `-o ProxyCommand=podman exec -i $NAME ...`, which ssh hands to its own /bin/sh child; and
# `podman build`, `podman exec` and the supervisor's `podman exec` are bare calls in four more
# places. A variable would have to be threaded into a string ssh parses and into processes we
# do not start. An exported PATH reaches all of them by inheritance, with nothing to remember.
#
# ONE DIRECTORY IS ENOUGH. podman finds gvproxy, vfkit and krunkit through its own built-in
# helper_binaries_dir and not through PATH -- measured on a Mac with only /opt/podman/bin
# appended: doctor reported podman 6.0.2, the machine, and `podman sees`.
#
# ASKED OF pkgutil RATHER THAN GUESSED. `--pkg-info` gives a location relative to the volume
# root and `--only-files --files` gives paths relative to that, so composing them is how macOS
# itself would answer "where did that package put things". A hardcoded /opt/podman/bin would
# need re-checking on every version bump; this does not.
#
# MATCHED ON THE BASENAME, not on `bin/podman`: the payload's layout is podman's business, and
# `(^|/)podman$` names the file we want without asserting which directory holds it. Verified
# against the real receipt -- it matches exactly one entry, and does NOT match
# podman/bin/podman-mac-helper.
#
# A LOCATION TEST AND NOTHING ELSE. Whether the podman it finds ANSWERS is preflight's next
# three checks -- --version, the floor, and info -- each with its own message. That is also
# what makes a stale receipt harmless: podman removed by hand still has a receipt, the file
# tests below refuse it, and preflight goes on to die exactly as it would have.
ensure_podman_path() {
    command -v podman >/dev/null 2>&1 && return 0
    [ "$(platform)" = macos ] || return 1
    command -v pkgutil >/dev/null 2>&1 || return 1
    local loc rel d
    loc="$(pkgutil --pkg-info "$PODMAN_PKG_ID" 2>/dev/null | awk '/^location:/{print $2}')"
    [ -n "$loc" ] || return 1
    rel="$(pkgutil --only-files --files "$PODMAN_PKG_ID" 2>/dev/null \
           | grep -E '(^|/)podman$' | head -1)"
    [ -n "$rel" ] || return 1
    # The payload path's directory, and the volume-relative case where there isn't one. Spelled
    # as a case rather than ${rel%/*}, which returns its input unchanged when there is no slash
    # and would compose a directory one level too deep.
    case "$rel" in
        */*) d="/$loc/${rel%/*}" ;;
        *)   d="/$loc" ;;
    esac
    # -f AS WELL AS -x, because `[ -x somedir ]` is TRUE for a directory (measured on bash
    # 3.2.57), so -x alone would accept a receipt naming a directory called podman. -x as well
    # as -f, because a half-extracted .pkg leaves a mode-644 binary that PATH cannot run.
    [ -f "$d/podman" ] && [ -x "$d/podman" ] || return 1
    export PATH="$PATH:$d"
    PODMAN_PATH_ADDED="$d"
}

# ─── the build's progress meter: the RENDERER ──────────────────────────────────
#
# MOVED HERE OUT OF cs193v (#221), and only half of it moved. What is here draws: the two-row
# block, the tail box, the geometry, the animator. What stayed in the launcher is the PROVIDER
# -- build_progress and CF_PARSE_AWK -- because it knows podman's `STEP i/N` grammar and the
# Containerfile's ####> markers, and feeds --dev-steps besides. The installer has a provider of
# its own: one command, no step stream, so it starts the meter with a total of 0.
#
# THE HEADER'S OLD CLAIM THAT "the whole meter_* block stayed behind" IS THEREFORE VOID, and so
# is the reason it gave -- that a container-side script has no podman or tmux. True, and no
# longer the test: the second consumer is host-side, and a renderer with no reader inside the
# image is the price of one definition instead of two.
#
# TWO NAMES THE SOURCING SCRIPT OWNS. METER_STATE is where the reader and the animator meet,
# and its name is the consumer's business -- the launcher keys it off TUNNEL_ID, the installer
# off its own pid. Defaulted here so that a consumer which never starts a meter can still run
# meter_cleanup under `set -u`, which is what the launcher's EXIT trap does on every exit.
METER_STATE=''
METER_PID=''

# The output box: the last few lines the slow command printed, under the meter's caption row,
# redrawn three times a second (issue #23 left the screen with nothing on it that moves on a
# human timescale during the four minutes when apt, npm and Chromium are the ones doing the
# work). The build had it first; since #219 course-install.sh raises one too, around the host
# package manager, the podman .pkg and `podman machine init`.
#
# NOT box(), and not a mode added to it. That one wraps a long line rather than cutting it, is
# as tall as whatever it is handed, and is the renderer 26 messages depend on -- so teaching it
# a truncating fixed-height mode would change all of them to serve this. The requirements here
# are the opposite ones:
#
# (This paragraph used to argue from a second reason -- that box() was "duplicated verbatim into
# install-cs193v.sh with 20-messages.sh rendering both copies to assert they still match". #221
# ended both halves of that: the bootstrap draws no box, course-install.sh sources this one, and
# 20-messages.sh records the removal where the diff used to be. The conclusion is unchanged and
# the dead evidence is gone.)
# the height is fixed by the geometry rather than by the content, because a box that changed
# height between frames would move the rows above it, and for the same reason a long line has
# to be cut rather than allowed to become two rows.
#
# PRINTABLE ASCII ONLY, which is what keeps this cheap enough to run three times a second: with
# no multibyte characters in the body, awk's length() IS the display width and substr() cannot
# slice a character in half, so none of box()'s dw()/dsub() arithmetic is needed here. It costs
# a stray checkmark out of npm; it buys a box that cannot be broken by whatever seven
# third-party tools decide to print into it. The ellipsis is the one exception -- a single
# column, appended after the text has already been cut to fit.
#
# THE ESCAPE SEQUENCES GO FIRST, before the ASCII filter. Their parameters are printable ASCII,
# so filtering first would delete the ESC and leave a literal "[1;32mdone" on the screen.
#
# The apostrophe rule from build_progress applies: this is a single-quoted shell string, so an
# apostrophe in a comment below ENDS it. Write "does not" rather than "doesn t".
meter_tail_box() {                    # -> the whole box, one printf-ready blob, or nothing
    [ "$METER_ROWS" -gt 0 ] || return 0
    # tail -n 40 rather than -n $METER_ROWS: the filter below drops blank lines, commit ids and
    # our own notes, and a burst of those would leave the box half empty if it were fed exactly
    # as many lines as it has rows. tail seeks from the end, so the size of the log is free.
    tail -n 40 "$METER_LOG" 2>/dev/null | LC_ALL=C awk -v rows="$METER_ROWS" \
            -v w="$METER_BOX_W" -v dim="$C_DIM" -v off="$C_OFF" -v esc="$ESC" '
        function rule(n,  s) { s = ""; while (n-- > 0) s = s "━"; return s }
        # Cut to fit or padded to exactly the text field, so every row is the same width as the
        # lid no matter what it holds.
        function body(t,  pad, n) {
            if (length(t) > lim) return substr(t, 1, lim - 1) "…"
            pad = ""; n = lim - length(t); while (n-- > 0) pad = pad " "
            return t pad
        }
        BEGIN { lim = w - 4; k = 0 }
        {
            t = $0
            gsub(esc "\\[[0-9;?]*[A-Za-z]", "", t)     # colour, cursor moves, erases
            gsub(esc ".", "", t)                       # anything else two characters long
            # A self-overwriting progress line arrives as ONE record with carriage returns in
            # it, and only its last segment was ever on a screen.
            n = split(t, seg, "\r")
            if (n > 1) { t = ""; for (i = n; i >= 1; i--) if (seg[i] != "") { t = seg[i]; break } }
            gsub(/\t/, " ", t)                         # a tab has no width inside a box
            gsub(/[^ -~]/, "", t)                      # space through tilde: printable ASCII
            # A BLANK LINE GETS A ROW like any other, rather than being swallowed to save one.
            # podman emits them between some steps, and the box is a window onto the log: a
            # student comparing a row here with the file staff asked them to send should be able
            # to count lines. Consequence worth knowing: a line that was ONLY a colour sequence,
            # or only characters the filter above removes, arrives here empty and now spends a row
            # too. Rare enough in build output to be the honest trade.
            #
            # THE ONE EXCLUSION IS OURS RATHER THAN PODMANS. build_note_fold appends these to the
            # same log while the meter is still running, and they are addressed to staff -- they
            # report that this launcher has lost track of which Containerfile instruction a step
            # is, which is neither something a student can act on nor something podman said.
            #
            # No apostrophe in that sentence, and none anywhere below: this whole awk program is a
            # single-quoted shell string, so one ENDS it. It cost a syntax error to relearn.
            #
            # AND THE BLANK LINE IN FRONT OF IT GOES TOO. The note begins with a newline on
            # purpose -- podman does not always end its last line with one, and without it the
            # note would be glued onto the end of podman output in the log staff read -- so that
            # separator belongs to our text, not to the build. Left in, it is the NEWEST line by
            # the time build_note_fold runs, so the box would end on a blank row and give up a row
            # of real content on every build where the label check fires. Only ever removed when a
            # note line is what follows it, so a blank line podman actually printed is untouched.
            if (t ~ /^cs193v:/) {
                if (k > 0 && keep[k] == "") k--
                next
            }
            # COMMIT IDS ARE NOT DROPPED, and that is a decision rather than an omission. They
            # are 22 of the 134 lines of a warm build and they cost half the window -- with them
            # in, the eight rows reach back to STEP 22 instead of STEP 19 -- but this box is a
            # window onto what podman said, not an edited version of it, and a student comparing
            # it with a log staff asked them to send should find the same lines in both. If it is
            # ever reconsidered, note that podman prints them TWO ways: "--> <hash>" between
            # steps and the finished image id on a line of its own at the end.
            keep[++k] = t
        }
        # Padded out to `rows` even when fewer lines survived, so the height of the box never
        # depends on what the log happened to contain.
        #
        # EVERY GLYPH COMES OUT OF A printf, the same way box() does it, rather than being
        # concatenated into a string first. 20-messages.sh greps both scripts for box characters
        # outside a printf and calls what it finds hand-drawn art -- which is the bug that grew
        # back four times before issue #21, and the rule is worth keeping even though this is a
        # second renderer rather than a fifth copy of the first.
        #
        # The rows go out as one stream separated by \r\n, with no trailing separator: the caller
        # captures the lot and prints it as the tail of a single frame.
        END {
            printf "  %s┏%s┓%s%s[K", dim, rule(w - 2), off, esc
            first = (k > rows ? k - rows + 1 : 1)
            for (i = 0; i < rows; i++) {
                j = first + i
                printf "\r\n  %s┃ %s ┃%s%s[K", dim, body(j <= k ? keep[j] : ""), off, esc
            }
            printf "\r\n  %s┗%s┛%s%s[K", dim, rule(w - 2), off, esc
        }
    '
}

# ─── the progress meter ────────────────────────────────────────────────────────
# One line that moves, shared by everything slow enough to need it.
#
# WHY THIS IS A BACKGROUND PROCESS AND NOT JUST A printf. The bar advances when podman
# finishes a step, and the slow steps -- Playwright, Chromium, the apt layers -- hold a
# single frame for minutes. Drawing only on step boundaries therefore means a meter that
# sits perfectly still for minutes, which reads as a hang: exactly the impression this
# feature exists to remove. Something has to redraw while nothing is happening.
#
# It cannot be done in the reader. build_progress is an awk blocked on `read` between STEP
# lines -- no code of ours runs while it waits, so it cannot animate. So the reader only
# records state and an animator owns the line, ten frames a second, until it is told to stop.
#
# The two halves meet through a FILE rather than a variable because the animator is a
# background subshell: an assignment in either one is invisible to the other. Written whole
# on every update and re-read on every frame, so a torn read costs one frame and fixes
# itself 100ms later rather than corrupting anything.

meter_write() {                       # meter_write CUR TOTAL RETRY LABEL
    printf '%s %s %s %s\n' "$1" "$2" "${3:--}" "$4" > "$METER_STATE" 2>/dev/null || true
}

# TWO ROWS, and the second one is why there are cursor moves in here at all. Everything the
# meter has to say no longer fits on one line: 40 cells of bar, a count, a step name and a
# retry marker come to about 105 columns, and a wrapped line breaks \r redrawing outright --
# the bar smears across two rows and never recovers. Splitting it puts the fixed-width
# furniture on one row and the prose on another, and leaves room to say more later.
#
# Row 1:  <glyph> [####....]  7/24                    (retrying: 1/2)
# Row 2:       Installing the Vercel CLI...
# Rows 3+:     a box holding the last few lines podman printed. See meter_tail_box.
#
# The marker is right-aligned at the terminal edge, so it is beside the block rather than
# jostling the label whose length changes at every step.
METER_W=40
METER_COLS=80
METER_LINES=24

# The output box, in body rows and display columns. Zero rows means no box at all, which is
# what a short or narrow terminal, a non-terminal stdout, and any caller that passes no log get
# -- the block is then exactly the two rows it was before. Passing a log is what asks for one,
# and two consumers do: the build, and the installer's slow steps (#219).
#
# EIGHT ROWS, so the whole block is twelve: half of a default 80x24 terminal, which leaves a
# dozen rows of what came before it still readable, and visibly less than the `tail -n 12` the
# STOP box shows if the build then fails. Eight lines is also enough to hold a coherent chunk
# of apt or npm output rather than a strobing single line.
METER_ROWS_MAX=8
METER_ROWS=0
METER_BOX_W=0
METER_H=2
# The file the box tails, set by meter_start. Empty for every meter that is not a build.
METER_LOG=''
# Which row of the block the cursor is on, 0 before anything is drawn. The whole block is
# addressed relative to this, so it is the one piece of state a frame needs from the last one.
METER_ROW=0

# Row 1 is 52 columns of furniture, so a full-width bar plus a 17-column marker fits an
# 80-column terminal with room to spare and nothing shrinks there. Below that the BAR gives
# way rather than the words: a count and a step name a student can read out to staff are
# worth more than the last ten cells of a bar.
#
# THE BOX SHRINKS RATHER THAN WRAPS, and it stops three columns short of BOX_W's own width
# rather than two: a box drawn to the last cell of a row leaves some terminals holding a
# pending wrap, and the next frame's cursor move would then land a row low and smear the block
# permanently. Same reason meter_mark stops one short. Below 44 columns there is no useful text
# field left, and below twelve lines the block would be the whole screen, so the box goes and
# the two rows carry on alone.
meter_fit() {
    METER_COLS="$(tput cols 2>/dev/null || printf '%s' "${COLUMNS:-80}")"
    case "$METER_COLS" in ''|*[!0-9]*) METER_COLS=80 ;; esac
    METER_LINES="$(tput lines 2>/dev/null || printf '%s' "${LINES:-24}")"
    case "$METER_LINES" in ''|*[!0-9]*) METER_LINES=24 ;; esac
    METER_W=40
    if [ "$METER_COLS" -lt 72 ]; then
        METER_W=$(( METER_COLS - 32 ))
        [ "$METER_W" -lt 10 ] && METER_W=10
    fi
    METER_ROWS=0
    METER_BOX_W=$(( METER_COLS - 3 ))
    [ "$METER_BOX_W" -gt "$BOX_W" ] && METER_BOX_W="$BOX_W"
    if [ -n "$METER_LOG" ] && [ "$METER_BOX_W" -ge 44 ]; then
        METER_ROWS=$(( METER_LINES - 8 ))
        [ "$METER_ROWS" -gt "$METER_ROWS_MAX" ] && METER_ROWS="$METER_ROWS_MAX"
        [ "$METER_ROWS" -lt 4 ] && METER_ROWS=0
    fi
    # How tall the block is: the two rows, plus a lid and a floor around any body rows. Every
    # relative cursor move in the meter is derived from this and METER_ROW, so the formula lives
    # here once rather than at each of the places that step through the block.
    METER_H=2
    [ "$METER_ROWS" -gt 0 ] && METER_H=$(( METER_ROWS + 4 ))
    return 0
}

meter_bar() {                         # meter_bar CUR TOTAL -> [████░░░░]
    local cur="$1" tot="$2" filled n bar='' pad=''
    filled=$(( METER_W * cur / tot ))
    [ "$filled" -gt "$METER_W" ] && filled="$METER_W"
    [ "$filled" -lt 0 ] && filled=0
    # BRACED, and load-bearing rather than style -- this is issue #120. Bash 3.2, which is every
    # Mac, is not multibyte-aware when it decides where a variable name ends, so under a UTF-8
    # locale `"$bar█"` parses the block's leading byte as part of the NAME and dies with
    # `bar<byte>: unbound variable` under set -u. The student sees that line once per frame of the
    # build meter and no progress bar at all. Measured: fine under LC_ALL=C, fatal under
    # en_US.UTF-8, which is the default.
    n="$filled";                  while [ "$n" -gt 0 ]; do bar="${bar}█"; n=$((n - 1)); done
    n=$(( METER_W - filled ));    while [ "$n" -gt 0 ]; do pad="${pad}░"; n=$((n - 1)); done
    printf '[%s%s]' "$bar" "$pad"
}

# The retry marker, right-aligned against the terminal edge. Padded rather than positioned
# with ESC[<col>G, and the width is COMPUTED rather than measured: row 1 holds multibyte
# glyphs and possibly a colour escape, so ${#row} would count neither in screen columns.
meter_mark() {                        # meter_mark RETRY W1 -> padding + (retrying: n/m)
    local retry="$1" w1="$2" mark n pad=''
    [ -n "$retry" ] && [ "$retry" != '-' ] || return 0
    mark="(retrying: $retry)"
    # One column short of the edge on purpose: writing the last cell makes some terminals
    # set a pending wrap, and a wrapped row 1 would put the cursor move on the wrong line.
    n=$(( METER_COLS - w1 - ${#mark} - 1 ))
    [ "$n" -lt 2 ] && n=2
    while [ "$n" -gt 0 ]; do pad="$pad "; n=$((n - 1)); done
    printf '%s%s' "$pad" "$mark"
}

# One frame, the whole block. METER_ROW says which row the cursor is resting on, so a frame
# begins by stepping back up to row 1 -- and a METER_ROW of 0 opens the block by drawing it
# rather than by redrawing over it, which is what the first frame does.
#
# RELATIVE MOVES AND A PLAIN \n, never absolute positioning. When the block sits at the
# bottom of the screen the terminal scrolls, and every row travels up together -- absolute
# coordinates would keep pointing at where the block used to be.
#
# IT ENDS WITH ESC[J, erasing whatever is below the last row. That is what makes the region
# self-healing: a resize that shrinks the box, and the closing frame that draws none at all,
# would otherwise leave the rows it used to occupy stranded underneath. Nothing below the block
# is ever lost to it, because the block is the last thing printed until it is finished with.
#
# METER_ROW is updated AFTER each write rather than once at the end, because bash defers a trap
# until the current builtin has finished -- so the TERM handler in meter_animate always sees
# where the cursor really is. The box goes out as a single printf, so a signal arriving inside
# that one write is the only case it can be wrong about, and then only about how far down to
# park a cursor nobody is reading.
meter_draw() {                        # meter_draw FRAME CUR TOTAL RETRY LABEL [BOX]
    local frame="$1" cur="$2" tot="$3" retry="$4" label="$5" boxblob="${6:-}"
    local g count w1
    g="$(meter_glyph "$frame")"
    [ "$METER_ROW" -gt 1 ] && printf '\r%s[%dA' "$ESC" $(( METER_ROW - 1 ))
    if [ "${tot:-0}" -gt 0 ] 2>/dev/null; then
        count="$cur/$tot"
        # 2 indent + glyph + space + bracketed bar + 2 + the count.
        w1=$(( 8 + METER_W + ${#count} ))
        printf '\r  %s %s  %s%s%s[K' "$g" "$(meter_bar "$cur" "$tot")" "$count" \
               "$(meter_mark "$retry" "$w1")" "$ESC"
    else
        printf '\r  %s%s%s[K' "$g" "$(meter_mark "$retry" 3)" "$ESC"
    fi
    METER_ROW=1
    # Indented to sit under the bar rather than under the glyph, so the moving cell stays the
    # leftmost thing in the block and the words line up with what they describe.
    printf '\r\n     %s%s[K' "$label" "$ESC"
    METER_ROW=2
    # Already a blob of complete rows, separated the same way these two are. Empty whenever
    # there is no box -- a short terminal, a narrow one, or any meter that is not a build.
    if [ -n "$boxblob" ]; then
        printf '\r\n%s' "$boxblob"
        METER_ROW="$METER_H"
    fi
    printf '%s[J' "$ESC"
}

# Where the cursor is parked when the block is being abandoned mid-flight rather than finished:
# just below it, so that a shell prompt lands under an intact block instead of through the
# middle of one. Only Ctrl-C arrives here, by way of the EXIT trap killing the animator; before
# this the prompt landed on whichever row the last frame happened to stop on, which was survivable
# while the block was two rows tall and is not now.
meter_park() {
    local n=$(( METER_H - METER_ROW ))
    # Skipped rather than emitted with a zero: ESC[0B moves down a row on most terminals rather
    # than nowhere at all.
    [ "$n" -gt 0 ] && printf '\r%s[%dB' "$ESC" "$n"
    printf '\r\n'
}

# The animator. Stops when the state file goes away, which is how meter_stop ends it without
# depending on a signal arriving.
#
# ON THE WAY OUT IT LEAVES THE CURSOR ON ROW 1. That is meter_stop's precondition, and it is
# what lets the parent shell stop knowing how tall the block is -- which it cannot know: the
# height comes from the terminal size, WINCH is handled here, and the parent is blocked inside
# podman for the whole four minutes during which a student might resize the window.
#
# THE BOX IS REFRESHED EVERY THIRD FRAME, not every frame. The spinner has to move at 10 Hz to
# read as motion, but eight lines of log replaced ten times a second read as a blur rather than
# as text, and every refresh is a tail and an awk. Three a second is legible and nearly free.
meter_animate() {
    local i=0 t=0 cur tot retry label box=''
    # A resize changes where the marker belongs, how wide the bar and the box may be, and how
    # many rows the box may have. Re-measured on the signal rather than once per frame, which
    # would fork tput ten times a second for an event that happens approximately never. The box
    # is re-rendered in the handler too, so its width can never lag the geometry it is drawn to.
    trap 'meter_fit; box="$(meter_tail_box)"' WINCH
    trap 'meter_park; exit 0' TERM
    while [ -f "$METER_STATE" ]; do
        cur=''; tot=''; retry=''; label=''
        IFS=' ' read -r cur tot retry label < "$METER_STATE" 2>/dev/null || true
        [ "$(( t % 3 ))" -eq 0 ] && box="$(meter_tail_box)"
        meter_draw "$i" "${cur:-0}" "${tot:-0}" "${retry:--}" "${label:-}" "$box"
        i=$(( (i + 1) % 8 )); t=$(( t + 1 ))
        sleep 0.1
    done
    [ "$METER_ROW" -gt 1 ] && printf '\r%s[%dA' "$ESC" $(( METER_ROW - 1 ))
    printf '\r'
}

# Nothing animates when stdout is not a terminal: \r cannot overdraw a pipe or a log file,
# and ten frames a second of it would be thousands of columns of noise in the file staff ask
# a student to send. Callers print plainly in that case.
# THE FIRST FRAME IS DRAWN HERE, in the foreground, before the animator exists. Every later
# frame begins by moving the cursor up a row, so the two rows have to be on the screen before
# anything can redraw them -- and if the animator owned the opening frame, a meter_stop that
# arrived before its first tick would step up into whatever was printed above and overwrite
# it. Drawing it synchronously makes that race impossible rather than unlikely.
meter_start() {                       # meter_start TOTAL LABEL [LOG]
    [ -t 1 ] || return 0
    # Set before meter_fit, which only looks for room for a box when there is something to put
    # in it, and before the fork, so that the animator inherits it. A caller that leaves it
    # empty gets the two-row block unchanged -- which is the right answer for a step with
    # nothing to show, and the wrong one for a step whose output IS the reassurance.
    METER_LOG="${3:-}"
    meter_fit
    METER_ROW=0
    cursor_hide
    meter_write "0" "${1:-0}" '-' "${2:-}"
    # NO BOX ON THE OPENING FRAME. The log does not exist yet at this point -- build_image has
    # just removed it and tee has not created it -- so there is nothing to put in one. The
    # animator adds it a tenth of a second later and the block grows by ten rows, which needs no
    # special handling because every move a frame makes is relative to where the cursor is.
    meter_draw 0 0 "${1:-0}" '-' "${2:-}"
    meter_animate &
    METER_PID=$!
}

meter_label() {                       # meter_label CUR TOTAL LABEL  -- update in place
    [ -n "$METER_PID" ] || return 0
    # No retry, and no caller wants one: the launcher reaches this only at the container-creation
    # step, after a build has succeeded, so a marker still standing there would be describing the
    # past -- and the installer refuses on the first failure by design, so it never retries at
    # all. That is also why setup_phase can advance a phase through here (#219).
    meter_write "$1" "$2" '-' "$3"
}

# Leaves the block finished rather than mid-frame. The outcome is required, because the glyph
# column is the one place that says which way it went and a spinner frame left in it reads as
# a build still running.
#
# SUCCESS COLLAPSES THE BLOCK to its one finished line: the caption row is erased and the
# cursor left on it, so the next thing printed starts on a clean row. FAILURE KEEPS BOTH
# ROWS, because the caption names the step that failed and it belongs directly above the STOP
# box -- and the bar stays where it stopped. Filling it to tot/tot, which this used to do,
# drew a completed build immediately above the words "the build failed".
#
# THE OUTPUT BOX GOES ON BOTH PATHS. It is scaffolding for a build that is happening, and by
# here one is not: on success the block collapses past it to a single line, and on failure the
# same lines are about to be repeated inside the STOP box, wrapped rather than cut and with the
# rest of the log behind them. Two boxes saying nearly the same thing is worse than one.
meter_stop() {                        # meter_stop ok|bad [CUR TOTAL LABEL]
    [ -n "$METER_PID" ] || return 0
    local outcome="$1"; shift
    local cur='' tot='' retry='' label=''
    [ -f "$METER_STATE" ] && IFS=' ' read -r cur tot retry label < "$METER_STATE" 2>/dev/null
    rm -f "$METER_STATE"
    # WAITED FOR, NOT KILLED. The animator leaves its loop when the state file goes -- that is
    # what the loop condition is for -- and on the way out it puts the cursor on row 1, which is
    # what the drawing below assumes. Killing it instead left the cursor wherever that frame had
    # reached, and the ESC[1A that used to be here assumed it was the end of row 2: a one-row
    # error when it was wrong, which was survivable while the block was two rows tall and is an
    # eleven-row one now. Costs at most one frame, 100 ms.
    wait "$METER_PID" 2>/dev/null || true
    METER_PID=''
    METER_ROW=1
    if [ "$#" -ge 2 ]; then cur="$1"; tot="$2"; label="${3:-$label}"; fi
    cur="${cur:-0}"; tot="${tot:-0}"
    # Before the final frame, not after: whatever the caller prints next -- a STOP box, a
    # success box, a shell -- must have the cursor back, and on the failure path the very next
    # thing is a die() that never returns here.
    cursor_show
    if [ "$outcome" = bad ]; then
        # Drawn with no box, and meter_draw ends with ESC[J -- which is what takes the live one
        # off the screen ahead of the STOP box.
        meter_draw bad "$cur" "$tot" '-' "$label"
        printf '\n'
        return 0
    fi
    if [ "$tot" -gt 0 ] 2>/dev/null; then
        printf '\r  %s %s  %s/%s  %s%s[K' "$(meter_glyph ok)" "$(meter_bar "$cur" "$tot")" \
               "$cur" "$tot" "$label" "$ESC"
    else
        printf '\r  %s  %s%s[K' "$(meter_glyph ok)" "$label" "$ESC"
    fi
    # ESC[J rather than ESC[K, and it does both jobs: it erases the caption row from the cursor
    # onwards AND every row below, which is where the box was. The cursor is left on the blank
    # caption row, so whatever prints next -- the success box, a shell -- starts on a clean row.
    printf '\r\n%s[J' "$ESC"
}

# The meter's half of the teardown, carved out of the launcher's transient_cleanup (#221) so
# that both consumers tear the same thing down the same way. The TRAP stays with the consumer:
# bash keeps exactly one EXIT trap, and this file may not install it -- see the header.
#
# THE CURSOR IS THE POINT. meter_start hides it, and a Ctrl-C between there and meter_stop
# leaves a student typing blind; this is the second of the two routes that give it back.
meter_cleanup() {
    rm -f "$METER_STATE"
    if [ -n "${METER_PID:-}" ]; then
        kill "$METER_PID" 2>/dev/null
        wait "$METER_PID" 2>/dev/null
    fi
    cursor_show
    :
}

# ─── the dynamic-port frame parser ─────────────────────────────────────────────
# THE ONLY PLACE BYTES THE CONTAINER CONTROLS REACH THE HOST, and the only container-derived
# value that ever lands in an ssh argument comes out of it. Everything about the shape below is
# about that: it is a function rather than an inline loop so 17-portparse-fuzz.sh can drive it
# thousands of times a second, and it validates before it computes, in that order, always.
#
# THE WIRE FORMAT, one record per line, one token per record:
#
#     cs193v-portwatch 1      handshake, exactly once, first
#     BEGIN 3                 opens a frame, declares how many records follow
#     3000:lo                 port:addressclass
#     5173:any
#     END                     closes it -- the count is checked and the frame is APPLIED here
#     WARN too-many-listeners 214     degraded but continuing
#     ERR  cannot-create-tick-fifo    the watcher cannot continue
#
# One token per line is what lets this parse with NO word splitting anywhere -- no `set -f`, no
# IFS juggling, no whitespace-collapse detector. A stray space simply fails the digit or class
# test. The earlier single-line format needed all three.
#
# FRAMES ARE ATOMIC. Records accumulate in DYNPORTS_FRAME and nothing is handed back until a
# well-formed END. Found in testing: without the `seen -lt n` guard below, a `BEGIN 1` followed by
# two records handed the second one out before the count mismatch was noticed at END -- it still
# failed loudly, but it had already published a port from a frame that turned out to be malformed.
# It also makes EOF mid-frame free: a partial frame is simply never applied.
#
# WHY `case` FIRST, ALWAYS. Measured on bash 5.3: `$(( ))`, `(( ))`, `[[ -eq ]]`, `${v:x:y}` and
# `${a[x]}` all EXECUTE a command substitution found in their operand. `[ -eq ]` rejected it, but
# that is bash-5 behaviour and macOS ships 3.2, so nothing may depend on it. `case` evaluates
# nothing. It is the only safe first move.
DYNPORTS_FRAME=''
DYNPORTS_FATAL=''
DYNPORTS_WARN=''
DYNPORTS_STATE=''
DYNPORTS_N=0
DYNPORTS_SEEN=0
DYNPORTS_MAX=128
DYNPORTS_PROTO='cs193v-portwatch 1'

dynports_reset() {
    DYNPORTS_STATE=handshake
    DYNPORTS_FRAME=''; DYNPORTS_FATAL=''; DYNPORTS_WARN=''
    DYNPORTS_N=0; DYNPORTS_SEEN=0
}

# Rendering a rejected value for a human. NOT a security boundary -- it runs AFTER a value has
# already been refused and gates nothing. `printf %q` because it is a builtin (no fork), it
# neutralises the ESC byte so a hostile value cannot repaint a terminal or a log, and it keeps
# \r distinguishable from \t -- which `tr -c '[:print:]' '?'` does not, defeating the whole point.
# `printf -v`, never $(quoted ...): command substitution forks even for a builtin, and measured
# over 5000 calls that fork is the entire cost -- 3.61s versus 0.03s.
quoted() { printf -v QUOTED '%q' "$1"; }

dynports_fatal() {                    # dynports_fatal REASON [VALUE]
    if [ "$#" -gt 1 ]; then
        quoted "$2"; DYNPORTS_FATAL="$1: $QUOTED"
    else
        DYNPORTS_FATAL="$1"
    fi
    return 2
}

# A decimal port, validated without ever letting the value reach an arithmetic context first.
# Each line earns its place, all three found by adversarial review:
#   * the length bound comes BEFORE any arithmetic -- 99999999999999999999 passes a digit test
#     and $(( )) wraps it silently to 7766279631452241919.
#   * 10# forces base 10 -- `[ 03000 -ge 1024 ]` is true because test reads it as OCTAL 1536,
#     while ssh would parse the string as decimal 3000. Validate one port, forward another.
#   * the canonicality compare makes a non-canonical spelling fatal rather than quietly fixed.
#
# AND THE GUARDS ARE NOT BELT-AND-BRACES. A bash arithmetic error does not return a status you can
# branch on -- it unwinds the ENTIRE function call stack to top level, skipping every caller's
# remaining statements. Measured: with 10# removed, `08` made this function, its caller, and its
# caller's caller all vanish mid-body. So reaching $(( )) with anything that can error is not "a
# wrong answer", it is "the program silently stops doing what it was doing". Validate first.
dynports_port() {                     # dynports_port STR -> sets DYNPORTS_PORT, or returns 2
    case "$1" in ''|*[!0-9]*) dynports_fatal "non-decimal port" "$1"; return 2 ;; esac
    [ "${#1}" -le 5 ] || { dynports_fatal "over-long port" "$1"; return 2; }
    DYNPORTS_PORT=$(( 10#$1 ))
    if [ "$DYNPORTS_PORT" -lt 1 ] || [ "$DYNPORTS_PORT" -gt 65535 ]; then
        dynports_fatal "port out of range" "$1"; return 2
    fi
    [ "$DYNPORTS_PORT" = "$1" ] || { dynports_fatal "non-canonical port" "$1"; return 2; }
    return 0
}

dynports_line() {                     # 0 consumed | 1 frame complete | 2 fatal
    local line="$1" cnt rec p c
    [ -n "${DYNPORTS_STATE:-}" ] || dynports_reset

    if [ "$DYNPORTS_STATE" = handshake ]; then
        # A fixed-string compare, so there is no parsing at all. Forward compatibility lives in
        # the version token: a format we do not speak makes the host refuse to start rather than
        # misread a frame.
        [ "$line" = "$DYNPORTS_PROTO" ] || { dynports_fatal "bad handshake" "$line"; return 2; }
        DYNPORTS_STATE=outside
        return 0
    fi

    case "$line" in
        "BEGIN "*)
            [ "$DYNPORTS_STATE" = outside ] || { dynports_fatal "BEGIN inside a frame"; return 2; }
            [ "${#line}" -le 9 ] || { dynports_fatal "BEGIN line too long"; return 2; }
            cnt="${line#BEGIN }"
            case "$cnt" in ''|*[!0-9]*) dynports_fatal "non-decimal count" "$cnt"; return 2 ;; esac
            [ "${#cnt}" -le 3 ] || { dynports_fatal "count too long"; return 2; }
            DYNPORTS_N=$(( 10#$cnt ))
            [ "$DYNPORTS_N" = "$cnt" ] || { dynports_fatal "non-canonical count" "$cnt"; return 2; }
            [ "$DYNPORTS_N" -le "$DYNPORTS_MAX" ] || { dynports_fatal "count over $DYNPORTS_MAX"; return 2; }
            DYNPORTS_STATE=inside; DYNPORTS_SEEN=0; DYNPORTS_FRAME=''
            return 0 ;;
        END)
            [ "$DYNPORTS_STATE" = inside ] || { dynports_fatal "END outside a frame"; return 2; }
            if [ "$DYNPORTS_SEEN" -ne "$DYNPORTS_N" ]; then
                dynports_fatal "declared $DYNPORTS_N, saw $DYNPORTS_SEEN"; return 2
            fi
            DYNPORTS_STATE=outside
            DYNPORTS_FRAME="${DYNPORTS_FRAME# }"
            return 1 ;;
        "WARN "*)
            # Degraded but continuing -- currently only `too-many-listeners <total>`, sent
            # alongside a truncated frame. Recorded and shown; deliberately NOT fatal, because a
            # container with more listeners than we will report is the world being unusual, not
            # our code being wrong, and it clears itself when the count drops.
            [ "${#line}" -le 64 ] || { dynports_fatal "WARN line too long"; return 2; }
            quoted "${line#WARN }"; DYNPORTS_WARN="$QUOTED"
            return 0 ;;
        "ERR "*)
            [ "${#line}" -le 64 ] || { dynports_fatal "ERR line too long"; return 2; }
            dynports_fatal "the watcher stopped" "${line#ERR }"; return 2 ;;
    esac

    # Anything else must be a record, and a record is only legal inside a frame.
    [ "$DYNPORTS_STATE" = inside ] || { dynports_fatal "line outside a frame" "$line"; return 2; }
    [ "$DYNPORTS_SEEN" -lt "$DYNPORTS_N" ] || { dynports_fatal "more records than declared"; return 2; }
    [ "${#line}" -le 10 ] || { dynports_fatal "record too long"; return 2; }
    case "$line" in *:*) ;; *) dynports_fatal "malformed record" "$line"; return 2 ;; esac
    rec="$line"; p="${rec%%:*}"; c="${rec#*:}"
    case "$c" in lo|any|v6lo|eth|loalt) ;; *) dynports_fatal "unknown class" "$c"; return 2 ;; esac
    dynports_port "$p" || return 2
    DYNPORTS_FRAME="$DYNPORTS_FRAME $DYNPORTS_PORT:$c"
    DYNPORTS_SEEN=$(( DYNPORTS_SEEN + 1 ))
    return 0
}
