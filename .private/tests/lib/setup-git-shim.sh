# shellcheck shell=bash
#
# Helpers for driving setup-git through a pty. Source after lib/assert.sh.
#
# MUST STAY BASH 3.2 COMPATIBLE.
#
# Two suites use these and they want opposite things from PATH: 35-setup-git-shim.sh puts
# lib/gh-fake and lib/git-fake in front of it, and 90-setup-git-github.sh must not, because it is
# the one that talks to the real API. So sg_new decides what goes on PATH and sg_run only prepends
# $SGSHIM — which holds the fakes in one case and nothing executable in the other.

SGDIRS=''

# sg_new [real]  -> a fresh shim directory in $SGSHIM, with the fakes in it unless told otherwise.
#
# A fresh one per case keeps state from leaking between them, and it doubles as the run's TMPDIR
# so setup-git's own scratch directory lands somewhere the suite can look at and clean up.
sg_new() {
    SGSHIM="$(mktemp -d "${TMPDIR:-/tmp}/cs193v-sg.$$.XXXXXX")"
    export SGSHIM CS193V_SGSHIM="$SGSHIM"
    if [ "${1:-fake}" = fake ]; then
        cp "$TESTS_DIR/lib/gh-fake"  "$SGSHIM/gh"
        cp "$TESTS_DIR/lib/git-fake" "$SGSHIM/git"
        # shortlink joins the fakes rather than getting its own switch: setup-git asks for it on
        # every run that reaches the token screen, and a run without it is the DEGRADED path --
        # the long URL, which is what a TA's Mac gets and what one case below asks for by name.
        cp "$TESTS_DIR/lib/shortlink-fake" "$SGSHIM/shortlink"
        chmod +x "$SGSHIM/gh" "$SGSHIM/git" "$SGSHIM/shortlink"
    fi
    : > "$SGSHIM/argv.log"
    SGDIRS="$SGDIRS $SGSHIM"
}
sg_set()   { printf '%s' "$2" > "$SGSHIM/$1"; }
sg_touch() { : > "$SGSHIM/$1"; }
sg_log()   { cat "$SGSHIM/argv.log" 2>/dev/null; }
# A LINE COUNT ON PURPOSE, and the one in this file that should stay one. Each fake writes exactly
# one `printf '%s\n'` per invocation (lib/gh-fake:28, lib/git-fake:24, lib/shortlink-fake:21), so a
# row IS a call here and rows and occurrences are the same number. Do not "fix" it into sg_times
# below: that reads a TRANSCRIPT, where they are not.
sg_count() { sg_log | grep -cE "$1" || true; }
sg_cleanup_all() { local d; for d in $SGDIRS; do rm -rf "$d"; done; SGDIRS=''; }

# What an earlier, KILLED run left behind. The pid in each name is what makes this safe to run
# while another suite is working; see sweep_stale_tmpdirs in lib/assert.sh. Called at suite start
# as well as from an EXIT trap, because a trap does not run when the process is killed — and
# until #76 there was no trap either, so 35-setup-git-shim.sh leaked every one of these on a
# clean run: 241 of them were sitting in /tmp when that was measured.
sg_sweep_stale() {                    # -> how many directories it removed
    sweep_stale_tmpdirs "${TMPDIR:-/tmp}" cs193v-sg
}

# ─── the conversation, as a table ──────────────────────────────────────────────
# WHAT REPLACED THE CLOCK, and why the clock had to go.
#
# sg_feed used to type a `|`-separated string of keystrokes with `sleep 0.3` between them and no
# knowledge of the child at all. MEASURED, and every one of these is a way for a green run to mean
# nothing:
#
#   * the answer is delivered before the question. The tty echoes on ARRIVAL, not on read, so a
#     keystroke that lands early is echoed into the transcript wherever the program happens to be.
#   * under CPU oversubscription the row structure of the transcript collapses, and the assertions
#     that count rows silently undercount -- 35-setup-git-shim.sh:476-509 is a whole essay about
#     one assertion that had to be rewritten as an occurrence count to survive it.
#   * on Linux/bash 5 keystrokes are LOST at the default pacing. The run then hangs until the
#     outer `timeout` fires, which truncates the transcript -- and about 125 assert_says_not /
#     assert_not_contains / assert_eq-to-empty assertions pass vacuously on a truncated one.
#   * and when the margin goes, the 93-character token is echoed in clear text. That is a REAL
#     credential in 90-setup-git-github.sh, whose transcript is `record`ed to a file at :212.
#
# A LONGER SLEEP DOES NOT FIX ANY OF THAT; it moves the boundary. What fixes it is knowing where
# the child is, which is what lib/ptydrive.py does: it holds the pty master, so it can read the
# program's output AND the slave's terminal settings before it decides to type.
#
# THREE KINDS OF READ, EACH WITH A TERMINAL STATE ONLY IT HAS:
#
#     line     ICANON and ECHO on   read_line, files/setup-git:395
#     secret   both off             read_secret, files/setup-git:486, via `stty -echo -icanon`
#     menu     both off             cs193v-ui.sh:659, via bash's own `read -rsn1`
#
# So `paste` IS NOT WRITTEN INTO A TERMINAL THAT IS ECHOING. If read_secret ever lost its stty --
# the exact defect the tally and the three secret:* assertions exist to catch -- the driver
# refuses to type the token and names the step, instead of pasting the credential into a
# transcript. Measured: with the token step declared `line` instead of `secret`, nothing is typed
# and the report reads "the screen arrived but the terminal was never at a line read".
#
# WHERE THE SEQUENCE LIVES: fixtures/setup-git-flows.txt, once, rather than in 39 keystroke
# strings. See that file's header.

SG_FLOWS="$TESTS_DIR/fixtures/setup-git-flows.txt"

# THE PROSE COMES OUT OF THE CATALOGUE, NOT OUT OF THE FIXTURE, so a reworded message does not
# break a flow -- the same rule assert_says_key exists for. One awk over both files per case;
# nothing here is per-keystroke.
#
# THE VALUES ARE SUBSTITUTED AFTERWARDS, IN THE SHELL, AND THAT IS LOAD-BEARING. `awk -v
# TOKEN=github_pat_...` would put a real credential in awk's argv, where `ps` can read it, and the
# whole point of files/setup-git:680-683 and of 35-setup-git-shim.sh:155-162 is that it reaches no
# argv, no environment and no file. awk sees `{{TOKEN}}` and nothing else.
sg_flow() {                           # sg_flow [VAR=VALUE]... FLOW... -> wire steps on stdout
    local a names='' n v pat out line
    local sub_n=''
    for a in "$@"; do
        case "$a" in
            *=*) n="${a%%=*}"; v="${a#*=}"
                 sub_n="$sub_n $n"
                 # Held in a parallel string rather than an array of pairs: bash 3.2, and a value
                 # may contain anything except a newline.
                 eval "SGV_$n=\$v" ;;
            *)   names="$names $a" ;;
        esac
    done
    for n in ID NAME TOKEN; do eval "[ -n \"\${SGV_$n-}\" ] || SGV_$n=\"\${SG_DEFAULT_$n-}\""; done
    out="$(awk -v want="$names" -v FLOWFILE="$SG_FLOWS" '
        function flat(s) {
            gsub(/\*/, "", s); gsub(/[\t]/, " ", s)
            while (sub(/  /, " ", s)) ; sub(/^ /, "", s); sub(/ $/, "", s); return s
        }
        # msg()`s own block parser, and msg_text`s truncation at the first placeholder: only the
        # literal prefix is prose a student is guaranteed to read.
        FILENAME != FLOWFILE {
            if ($0 ~ /^\[\[.*\]\]$/) { k = substr($0, 3, length($0) - 4); next }
            if (k != "") { prose[k] = prose[k] " " $0 }
            next
        }
        # The flow file. Bodies are kept whole and expanded at the end, so `include` can name a
        # flow defined later.
        /^#/ || /^[ \t]*$/ { next }
        /^\[\[.*\]\]$/ { f = substr($0, 3, length($0) - 4); order[++nf] = f; next }
        f != "" { body[f] = body[f] $0 "\n" }
        function phrase(key,   t) {
            if (!(key in prose)) { bad = bad " " key; return "" }
            t = prose[key]; sub(/\{\{.*/, "", t); t = flat(t)
            if (t == "" || t == " ") { bad = bad " " key }
            return t
        }
        function emit(kind, name, needles, keys) {
            printf "%s%s\t%s\t%s\t%s\n", (opt ? "?" : ""), kind, name, needles, keys
        }
        function expand(name, depth,   lines, i, nl, ln, lhs, rhs, kind, keys, nk, kk,
                        act, arg, needles, j, idx, d, sname) {
            if (depth > 8) { print "ptydrive-flow: include loop at " name > "/dev/stderr"; exit 2 }
            if (!(name in body)) { print "ptydrive-flow: no such flow: " name > "/dev/stderr"; exit 2 }
            nl = split(body[name], lines, "\n")
            for (i = 1; i <= nl; i++) {
                ln = lines[i]; sub(/[ \t]+$/, "", ln)
                if (ln == "") continue
                if (ln ~ /^optional[ \t]*$/) { opt = 1; continue }
                if (ln ~ /^include[ \t]/) { sub(/^include[ \t]+/, "", ln); expand(ln, depth + 1); continue }
                idx = index(ln, "->")
                if (idx == 0) { print "ptydrive-flow: no -> in: " ln > "/dev/stderr"; exit 2 }
                lhs = substr(ln, 1, idx - 1); rhs = substr(ln, idx + 2)
                sub(/^[ \t]+/, "", lhs); sub(/[ \t]+$/, "", lhs)
                sub(/^[ \t]+/, "", rhs); sub(/[ \t]+$/, "", rhs)
                nk = split(lhs, kk, /[ \t]+/); kind = kk[1]
                needles = ""
                for (j = 2; j <= nk; j++) needles = needles (j > 2 ? "\037" : "") phrase(kk[j])
                act = rhs; arg = ""
                if (match(rhs, /[ \t]/)) { act = substr(rhs, 1, RSTART - 1); arg = substr(rhs, RSTART + 1) }
                sub(/^[ \t]+/, "", arg)
                if (arg ~ /^".*"$/) arg = substr(arg, 2, length(arg) - 2)
                nstep[name]++
                sname = name "#" nstep[name] " " kk[2]
                if (act == "type" || act == "paste") { emit(kind, sname, needles, arg "\\n") }
                else if (act == "pick") {
                    d = -1
                    for (j = 2; j <= nk; j++) if (kk[j] == arg) d = j - 2
                    if (d < 0) { print "ptydrive-flow: " arg " is not an option of " ln > "/dev/stderr"; exit 2 }
                    # ARROWS, NOT A DIGIT. menu() accepts both, and the arrow path is the one a
                    # student uses -- the comment this change deletes called reaching the third
                    # entry by arrow key "deliberate", and this is where that is now written down.
                    for (j = 1; j <= d; j++)
                        emit(kind, sname " " act " " arg " (down " j "/" d ")", needles, "\\033[B")
                    emit(kind, sname " " act " " arg, needles, "\\n")
                }
                else if (act == "send") { emit(kind, sname, needles, arg) }
                else { print "ptydrive-flow: unknown action: " act > "/dev/stderr"; exit 2 }
            }
        }
        END {
            nw = split(want, w, /[ \t]+/)
            for (i = 1; i <= nw; i++) if (w[i] != "") expand(w[i], 0)
            if (bad != "") { print "ptydrive-flow: no literal prose for key(s):" bad > "/dev/stderr"; exit 2 }
        }
    ' "$SGM" "$SG_FLOWS")" || { printf 'BROKEN-FLOW\n'; return 1; }
    # THE VALUES GO IN HERE, in the shell. Not a fork and not an argv: see the note above.
    printf '%s\n' "$out" | while IFS= read -r line; do
        for n in $sub_n ID NAME TOKEN; do
            eval "v=\${SGV_$n-}"
            pat="{{$n}}"
            line="${line//$pat/$v}"
        done
        printf '%s\n' "$line"
    done
}

# sg_run CASE FLOW... [VAR=VALUE ...] -- the transcript in $SG_OUT, and one named result for the
# conversation itself.
#
# A STATEMENT, NOT A SUBSTITUTION, and that is forced rather than stylistic. lib/assert.sh:57
# states the rule this suite runs on -- "no assertion in this suite is called from a subshell;
# every pass/fail is a statement, and the $( ) around them are values being handed IN" -- and this
# function emits one. Inside `out="$(sg_run ...)"` its PASS line would land in the transcript,
# where every assertion in the file would then read it and the 80-column row lint would count it.
#
# TWO WAYS TO NAME WHAT RUNS, unchanged from the sg_tty this replaced: $SG_SETUP_GIT plus $SG_ENV
# for the shim tier, or $SG_RUN verbatim for 90-setup-git-github.sh, which runs the INSTALLED copy
# inside the container. Per-run VAR=VALUE extras still go to the former only, for the reason that
# file gives: `env A=B podman exec` sets A on podman, not in the container.
#
# THE ENVIRONMENT EXTRAS AND THE FLOW ARGUMENTS SHARE ONE `VAR=VALUE` SPELLING and are told apart
# by name: a flow placeholder is one of the ones the fixture uses. Anything else is for `env`.
#
# THE DEFAULTS THE FIXTURE'S PLACEHOLDERS FALL BACK TO, so a case that does not care who the
# student is says `sg_run happy happy` and nothing else. Read only through the `eval` in sg_flow,
# which shellcheck cannot follow -- grouped under ONE directive rather than three, and grouped
# rather than made file-level, so a fourth variable that really is dead still gets named.
# shellcheck disable=SC2034
{ SG_DEFAULT_ID=jdoe; SG_DEFAULT_NAME='Jane Doe'; SG_DEFAULT_TOKEN=''; }
sg_run() {                            # sg_run CASE FLOW|VAR=VAL...
    local case_name="$1"; shift
    local a cmd flowargs='' envargs='' steps rc
    for a in "$@"; do
        case "$a" in
            ID=*|NAME=*|TOKEN=*|HALF=*) flowargs="$flowargs${A_TAB}$a" ;;
            *=*)                        envargs="$envargs $a" ;;
            *)                          flowargs="$flowargs${A_TAB}$a" ;;
        esac
    done
    if [ -n "${SG_RUN:-}" ]; then
        cmd="$SG_RUN"
    else
        cmd="env $SG_ENV TMPDIR=$SGSHIM CS193V_SGSHIM=$SGSHIM$envargs bash $SG_SETUP_GIT"
    fi
    SG_REPORT="$SGSHIM/drive.report"
    rm -f "$SG_REPORT"
    # SPLIT ON TABS ONLY, so a flow value may contain spaces (`NAME=Jane Doe`).
    local oldifs="$IFS"
    IFS="$A_TAB"
    # shellcheck disable=SC2086
    set -- $flowargs
    IFS="$oldifs"
    steps="$(sg_flow "$@")"
    SG_OUT="$(printf '%s\n' "$steps" \
        | CS193V_DRIVE_REPORT="$SG_REPORT" PATH="$SGSHIM:$PATH" \
          do_drive "${SG_TIMEOUT:-120}" "$cmd" 2>&1)"
    rc=$?
    # ONE NAMED RESULT PER RUN, and it is not decoration: it is the only thing that can say a
    # reflowed flow diverged, and it says WHERE. Recorded through the same pass/fail channel as
    # everything else, so run-tests.sh counts it.
    sg_conversation "$case_name" "$rc"
}

# The verdict on the conversation, from the report file lib/ptydrive.py wrote. NOT from the
# transcript and NOT from stderr: sg_run ends `2>&1`, so this process`s stderr IS the transcript
# and a diagnostic there would be read by every assertion in the suite.
sg_conversation() {                   # sg_conversation CASE RC
    local name="$1:the-conversation-went-as-described" bad
    if [ ! -f "${SG_REPORT:-/nonexistent}" ]; then
        fail "$name" "lib/ptydrive.py wrote no report, so nothing here was measured (rc $2)"
        return 0
    fi
    bad="$(grep -c '^FAIL' "$SG_REPORT" 2>/dev/null || true)"
    if [ "${bad:-1}" -eq 0 ]; then pass "$name"; return 0; fi
    fail "$name" "$(sed -n "s/^FAIL\\t/diverged at step: /p;s/^# /  /p" "$SG_REPORT")"
    # AND THE TRANSCRIPT IS POISONED, which is this file's own doctrine read from the failing
    # side. A run that stopped at step 6 of 9 did not produce the screens the assertions below it
    # ask about, so every one of them is a question about a run that never happened -- and about
    # half of them are NEGATIVE, which means they would pass. $CHECKER_DIED in the value is what
    # lib/assert.sh:138 already turns into a named failure on both the positive and the negative
    # forms, and it survives $( ) and a pipe from one checker into another.
    #
    # MEASURED: with one screen inserted into ask_token, the suite as it stands reports 94
    # failures across 30 case prefixes and not one of them names the extra screen. With this, the
    # 35 conversation results name it and everything downstream says which run it could not read.
    SG_OUT="$SG_OUT
$CHECKER_DIED (the conversation diverged before this run finished: $name)"
}

# How many steps a run actually sent, for a case that wants to assert on the shape of the
# conversation rather than on its contents.
sg_steps_sent() {                     # sg_steps_sent -> N
    grep -c '^OK' "${SG_REPORT:-/nonexistent}" 2>/dev/null || printf '0'
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
# LC_ALL=C ON EVERY sed THAT READS A TRANSCRIPT. BSD sed decodes its input to evaluate a
# character class, so ONE non-UTF-8 byte anywhere in a pty transcript aborts it with
# "RE error: illegal byte sequence" and the flattened text comes back TRUNCATED -- on which
# assert_says fails confusingly and every assert_says_not passes vacuously. Under LC_ALL=C the
# same sed treats input as bytes and passes the offending one straight through. Measured.
#
# SAFE HERE ONLY BECAUSE THESE PATTERNS ARE ASCII. Do not copy this to a sed whose pattern
# contains a multibyte bracket expression -- see _flatten in lib/assert.sh, where LC_ALL=C would
# turn [┃┏┓┗┛━] into a set of BYTES and strip E2 out of every other box-drawing and bullet
# character in the text.
sg_plain() {                          # sg_plain TEXT -> the words, with the terminal removed
    printf '%s' "$1" | do_tr -d '\r' | LC_ALL=C sed -e "s/${SG_ESC}\\[[0-9;?]*[A-Za-z]//g" \
        | do_tr '\n' ' ' | LC_ALL=C sed -e 's/[[:space:]][[:space:]]*/ /g'
}
sg_phrase() {                         # sg_phrase KEY -> its prose, markup removed
    msg_text "$1" "$SGM" | do_tr -d '*' | LC_ALL=C sed -e 's/[[:space:]][[:space:]]*/ /g'
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

# THE STATES A LINE WENT THROUGH, which is a different thing from the lines in the transcript.
# read_secret redraws its tally with \r after every keystroke, so a 93-character paste writes 94
# states onto one physical line and only the last of them was ever on a screen. Splitting on \r is
# what turns those back into something assertable — the same thing box() does with podman's
# self-overwriting output, and for the same reason. Colour comes off here too, so neither reader
# below has to know about it.
sg_rows() {                           # sg_rows TEXT -> one row per \r-segment, colour removed
    printf '%s' "$1" | do_tr '\r' '\n' | LC_ALL=C sed -e "s/${SG_ESC}\[[0-9;?]*[A-Za-z]//g"
}

# EVERY ROW THAT DID NOT FIT, which is the shape issue #67 needed and nothing here had. The
# catalogue lint in 20-messages.sh can bound what a *placeholder* costs; it cannot see which URL
# the script decided to substitute into it, and that is the half that wrapped.
#
# 80 AND NOT 76 is deliberate: the lint measures a catalogue line before render() indents it,
# and this measures what actually reached the pty, indent included. The two limits are the same
# limit seen from opposite sides.
#
# WIDTHS IN CODE POINTS, via python3, for the reason 20-messages.sh records: these rows carry box
# art, and mawk counts bytes, so `━` would score three columns and every box would look overwide.
sg_rows_over() {                      # sg_rows_over LIMIT TEXT -> "COLUMNS: row" per row too wide
    sg_rows "$2" | LIMIT="$1" run_checker python3 -c '
import os, sys
limit = int(os.environ["LIMIT"])
for row in sys.stdin.read().splitlines():
    row = row.rstrip()
    if len(row) > limit:
        print("%d: %s" % (len(row), row))
'
}

# The widest row there was, for the results file. A number that moves is worth seeing even on a
# run where nothing failed.
sg_widest_row() {                     # sg_widest_row TEXT -> the column count of the widest row
    sg_rows "$1" | run_checker python3 -c '
import sys
rows = [r.rstrip() for r in sys.stdin.read().splitlines()]
print(max([len(r) for r in rows]) if rows else 0)
'
}

# The last row mentioning a needle: the final state of the line it was drawn on, which is what a
# student was left looking at.
sg_final() {                          # sg_final TEXT NEEDLE -> the last row mentioning NEEDLE
    sg_rows "$1" | grep -- "$2" | tail -1
}

# HOW MANY TIMES A PROMPT WAS ASKED, which is not how many times it was written: one 93-character
# paste puts `Your token:` on the wire 94 times. What happens exactly once per ask is the state
# BEFORE the first keystroke — the prompt with an empty tally after it — so that is what this counts.
# Until issue #53 these counts came from the receipt line, which the tally replaced.
#
# The needle is an ERE, and the prose it is given comes from the catalogue rather than being quoted
# here, for the reason sg_says exists: a test that hardcodes wording fails the day somebody rewords
# the catalogue, which punishes the wrong change.
#
# NOT INTERCHANGEABLE WITH sg_times BELOW, in either direction, and the names are close enough that
# it is worth saying twice. This one ANCHORS -- `^ prompt $` -- so it answers 0 on any prompt whose
# answer the terminal echoes onto the same row: measured 0 for prompt.sunetid and prompt.name on
# real transcripts, where the answers are 1 and 2. sg_times is the reader for those.
sg_asks() {                           # sg_asks TEXT PROMPT -> times PROMPT was drawn with nothing after it
    sg_rows "$1" | grep -cE "^[[:space:]]*$2[[:space:]]*$" || true
}

# HOW MANY TIMES A PHRASE IS THERE, which is not how many ROWS carry it -- and the difference is
# the whole of issue #200 and then #207. `grep -c` counts rows, so two occurrences on one row
# score 1 and it can only ever UNDERCOUNT, silently. #200 was one row boundary the TERMINAL wrote,
# which really did go red under load; #207 then found four more written the same way that did NOT.
# All four agreed with the occurrence count on every transcript setup-git produces today, each for
# a reason incidental to what it claimed -- a trailing `\n` on every meter row from run_timeout, a
# leading `\n` on every prompt from ask_sunetid and ask_name -- and nothing enforced either.
#
# THREE SPELLING DECISIONS, ALL MEASURED against /usr/bin/grep (BSD grep 2.6.0-FreeBSD), which is
# what this suite gets on a Mac. Each of them is a wrong answer somebody would otherwise reach:
#
#   * `-F`, NOT `-E`. `What is your SUNetID (e.g. htiek, szum)?` read as an ERE has its trailing
#     `?` make the parenthetical OPTIONAL, so the bare stem matches as well. Against a haystack
#     holding the prompt twice plus one decoy row: `-oF` -> 2, `-oE` -> 3, `grep -c` -> 1. A
#     caller naming a KEY cannot audit the prose behind it for metacharacters first, so the
#     literal flag is the only safe one here.
#   * `LC_ALL=C` ON THE SEARCHING grep, for the reason sg_plain's header records for its seds:
#     BSD grep in the ambient locale abandons the whole LINE a non-UTF-8 byte sits on. sg_plain
#     has already made the transcript exactly ONE line, so a single stray byte anywhere zeroes
#     the entire count. Measured: 0 ambient against 2 under LC_ALL=C. GNU grep does NOT abandon
#     the line -- it answers 1, the row count, so the ambient spelling is wrong on both platforms
#     but wrong differently, and only the BSD half is a zero. Safe because -F takes the needle as
#     bytes either way -- a multibyte needle still matches.
#   * `grep -c .`, NOT `wc -l`. BSD wc pads its output to a column, which is why the two `wc`
#     spellings this replaced carried a `do_tr -d ' '` to scrub it back off.
#
# AND NOT FOR A PROMPT THE SCRIPT REDRAWS. sg_plain strips `\r` and keeps every state it
# separated, so on read_secret's tally this counts the STATES: `Your token:` measures 94 on one
# real transcript and 188 on another, where the answer is 1 and 2. sg_asks ABOVE is the reader for
# that shape and this is not a substitute for it. The converse is also true -- see its header.
sg_times() {                          # sg_times NEEDLE TEXT -> how many times NEEDLE occurs
    # AN EMPTY NEEDLE ANSWERS THE SENTINEL RATHER THAN 0. `grep -oF ''` against sg_plain's single
    # line emits one empty line, which `grep -c .` scores 0 -- so an assertion expecting 0 would
    # pass with no search having happened. #79's trap, so #79's answer: the failure travels in
    # the value and _checker_ok fails on it wherever it is asserted.
    case "$1" in '') printf '%s (empty needle)\n' "$CHECKER_DIED"; return 0 ;; esac
    sg_plain "$2" | LC_ALL=C grep -oF -- "$1" | LC_ALL=C grep -c . || true
}
sg_has_times() {                      # sg_has_times NAME COUNT NEEDLE TEXT
    assert_eq "$1" "$2" "$(sg_times "$3" "$4")"
}
# By KEY rather than by quoted prose, for the reason sg_says exists -- and with sg_says' guard,
# because a key that resolves to nothing would otherwise count occurrences of nothing and answer
# 0. msg_text returns ONE FLATTENED LINE, so a keyed needle can never be multi-line; that matters
# because `grep -F` reads a multi-line pattern as SEVERAL alternatives rather than one phrase.
sg_says_times() {                     # sg_says_times NAME COUNT KEY TEXT
    local phrase; phrase="$(sg_phrase "$3")"
    case "$phrase" in ''|' ') fail "$1" "no literal prose for key: $3"; return 0 ;; esac
    assert_eq "$1" "$2" "$(sg_times "$phrase" "$4")"
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
# A SECRET NEEDS ITS OWN FLATTENER, and finding out why cost a round during the #155 audit.
#
# _flatten in lib/assert.sh joins wrapped lines with a SPACE, which is exactly right for prose --
# it asserts on what the student reads rather than on where the line happened to break. It is
# wrong for a credential. box() wraps at 69 columns and a fine-grained token is 93 characters, so
# a leaked token lands across two rows and the joining space falls INSIDE it. Measured: with the
# token deliberately interpolated into the staff box, assert_not_contains against the raw box AND
# assert_says_not against the flattened one BOTH passed, while the token sat there on screen
# split 33 + 26 characters across two rows.
#
# A token contains no whitespace, so deleting all of it is lossless for this one question and
# cannot manufacture a false negative. Use this, not _flatten, whenever the needle is a secret.
sg_unwrap() {                         # sg_unwrap TEXT -> box art and ALL whitespace removed
    printf '%s' "$1" | do_tr -d '\n' | sed -e 's/[┃┏┓┗┛━]//g' -e 's/[[:space:]]//g'
}

sg_box() {                            # sg_box TEXT -> just the box, ready for box_problems
    printf '%s' "$1" | do_tr -d '\r' | LC_ALL=C sed -e "s/${SG_ESC}\\[[0-9;?]*[A-Za-z]//g" -e 's/^  //' \
        | sed -n '/[┏]/,/[┗]/p'   # NO LC_ALL=C: [┏] and [┗] are multibyte brackets
}
