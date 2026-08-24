#!/usr/bin/env bash
# A batch-language linter for install-cs193v-windows.cmd.
#
# WHY THIS EXISTS AND NOT MORE EXECUTION. The wine tier (27-installer-windows.sh) executes the
# file and reaches every DECISION in it, but wine's cmd.exe is deliberately MORE PERMISSIVE than
# the real one in two measured places -- it accepts `::` inside a parenthesized block, and it
# parses LF-only files that real cmd.exe misparses. Those are false negatives no amount of
# execution can catch, so they are checked here, statically, instead.
#
# The other half of the reason is reach: these rules apply to code that does not exist yet. A
# call site added next term gets checked the day it lands, which is why every rule below derives
# its work list by PARSING THE FILE rather than from a list of line numbers.
#
# Each checker prints one violation per line and nothing when clean, so a caller writes
#     assert_eq "windows:no-unescaped-echo" "" "$(run_checker cmdlint_echo_specials "$W")"
# and `run_checker` turns a checker that dies into a value the assertion cannot pass on.

# cmd.exe builtins. Anything else at the start of a command is an EXTERNAL program, whose exit
# code is therefore outside our control and may be negative -- which is the whole point of
# cmdlint_unchecked_calls below.
CMDLINT_BUILTINS='echo|set|setlocal|endlocal|if|for|goto|rem|pause|exit|call|cd|chdir|del|erase|copy|move|ren|rename|md|mkdir|rd|rmdir|type|shift|ver|cls|title|prompt|path|assoc|ftype|start|color|date|time|verify|vol|popd|pushd|break|dir|more'

# _cmdlint_stream FILE -> "DEPTH<TAB>LINENO<TAB>TEXT" for each line, CR stripped.
#
# DEPTH is the parenthesis nesting the line sits INSIDE (0 = top level), computed before the
# line's own trailing `(` is counted, so `if x==y (` reports 0 and its body reports 1. Quoted
# runs and caret-escaped parens are ignored, because `echo ^(` and `"a(b"` open nothing.
_cmdlint_stream() {
    awk '
    { sub(/\r$/, "") }
    {
        line = $0
        # strip quoted runs and caret escapes before counting parens
        probe = line
        gsub(/\^./, "", probe)
        gsub(/"[^"]*"/, "", probe)
        opens = gsub(/\(/, "(", probe)
        closes = gsub(/\)/, ")", probe)
        # a line that closes more than it opens sits at the shallower level
        entry = depth - (closes > opens ? closes - opens : 0)
        if (entry < 0) entry = 0
        printf "%d\t%d\t%s\n", entry, NR, line
        depth += opens - closes
        if (depth < 0) depth = 0
    }' "$1"
}

# _cmdlint_commands FILE -> "DEPTH<TAB>LINENO<TAB>FIRSTWORD<TAB>TEXT" for real commands only
# (comments, labels and blank lines dropped).
_cmdlint_commands() {
    _cmdlint_stream "$1" | awk -F'\t' '
    {
        text = $3
        body = text
        sub(/^[ \t]+/, "", body)
        sub(/^@/, "", body)
        if (body == "") next
        if (body ~ /^::/) next
        if (tolower(body) ~ /^rem([ \t]|$)/) next
        if (body ~ /^:/) next
        # a leading `(` or `) else (` is block punctuation, not a command
        sub(/^\)[ \t]*/, "", body)
        sub(/^else[ \t]*/, "", body)
        sub(/^\([ \t]*/, "", body)
        if (body == "") next
        first = body
        sub(/[ \t].*$/, "", first)
        # a word may abut its redirection, as in `break> file`; the operator is not part of it
        sub(/[<>|&].*$/, "", first)
        # `echo.`, `echo:` and `echo/` are the blank-line idiom, not a program called "echo."
        if (tolower(first) ~ /^echo[.:\/]/) first = "echo"
        printf "%s\t%s\t%s\t%s\n", $1, $2, tolower(first), text
    }'
}

cmdlint_line_endings() {              # cmdlint_line_endings FILE -> violations
    [ -s "$1" ] || { echo "file is empty or missing: $1"; return 0; }
    local total cr
    total=$(wc -l < "$1")
    cr=$(tr -dc '\r' < "$1" | wc -c)
    [ "$cr" -ge "$total" ] || printf 'LF-only line endings (%s lines, %s CR bytes): cmd.exe reads batch in 512-byte chunks and its label scanner assumes CRLF, so goto/call fails by byte offset\n' "$total" "$cr"
}

cmdlint_non_ascii() {                 # cmdlint_non_ascii FILE -> violations
    [ -s "$1" ] || { echo "file is empty or missing: $1"; return 0; }
    grep -nP '[^\x00-\x7F]' "$1" | sed 's/^/non-ASCII byte on line /' || true
}

cmdlint_labels() {                    # cmdlint_labels FILE -> violations
    [ -s "$1" ] || { echo "file is empty or missing: $1"; return 0; }
    local labels
    labels=$(sed 's/\r$//' "$1" | sed -n 's/^[ \t]*:\([A-Za-z0-9_][A-Za-z0-9_]*\).*/\1/p' | tr 'A-Z' 'a-z' | sort -u)
    sed 's/\r$//' "$1" | grep -niE '^[ \t]*@?goto[ \t]+:?[A-Za-z0-9_]+' | while IFS= read -r hit; do
        local n t
        n=${hit%%:*}; t=${hit#*:}
        t=$(printf '%s' "$t" | sed -E 's/^[ \t]*@?[Gg][Oo][Tt][Oo][ \t]+:?([A-Za-z0-9_]+).*/\1/' | tr 'A-Z' 'a-z')
        [ "$t" = eof ] && continue
        printf '%s\n' "$labels" | grep -qxF "$t" || printf 'line %s: goto %s has no matching label\n' "$n" "$t"
    done
}

cmdlint_echo_specials() {             # cmdlint_echo_specials FILE -> violations
    [ -s "$1" ] || { echo "file is empty or missing: $1"; return 0; }
    _cmdlint_commands "$1" | awk -F'\t' '
    $3 ~ /^echo/ {
        depth = $1; n = $2; text = $4
        arg = text
        sub(/^[ \t]*@?[Ee][Cc][Hh][Oo]([.:\/]|[ \t])/, "", arg)
        # caret-escaped and double-quoted runs are safe; remove them before judging
        probe = arg
        gsub(/\^./, "", probe)
        gsub(/"[^"]*"/, "", probe)
        # redirection metacharacters are ALWAYS wrong in message text, at any depth:
        # cmd extracts them before echo ever runs, so the line silently prints nothing.
        if (probe ~ /[<>|]/)
            printf "line %d: echo contains unescaped < > or | -- cmd parses it as redirection and the message is lost: %s\n", n, text
        # parens only break INSIDE a block, where a bare `)` closes it early
        else if (depth > 0 && probe ~ /[()]/)
            printf "line %d: echo contains unescaped ( or ) inside a block (depth %d) -- closes the block early\n", n, depth
    }'
}

cmdlint_comments_in_blocks() {        # cmdlint_comments_in_blocks FILE -> violations
    [ -s "$1" ] || { echo "file is empty or missing: $1"; return 0; }
    _cmdlint_stream "$1" | awk -F'\t' '
    $1 > 0 {
        body = $3
        sub(/^[ \t]+/, "", body)
        if (body ~ /^::/)
            printf "line %d: `::` inside a parenthesized block (depth %s) -- wine accepts this, real cmd.exe does not\n", $2, $1
    }'
}

# A line may waive a rule for itself with a comment DIRECTLY above it:
#     :: cmdlint-allow: unchecked-exit -- because <reason>
# The waiver sits at the site it excuses, so it cannot drift from the code the way a list of
# line numbers in another file does, and the reason is read by whoever next changes the line.
_cmdlint_waivers() {                  # _cmdlint_waivers FILE RULE -> waived line numbers
    sed 's/\r$//' "$1" | awk -v rule="$2" '
    /^[ \t]*:: cmdlint-allow:/ { if (index($0, rule)) pending = 1; next }
    # Comment and blank lines between the waiver and the command it excuses do not consume it,
    # so the reason may run to as many lines as it needs.
    /^[ \t]*(::|$)/ { next }
    { if (pending) { print NR; pending = 0 } }'
}

cmdlint_unchecked_calls() {           # cmdlint_unchecked_calls FILE -> violations
    [ -s "$1" ] || { echo "file is empty or missing: $1"; return 0; }
    local waived
    waived="$(_cmdlint_waivers "$1" unchecked-exit | tr '\n' ' ')"
    _cmdlint_commands "$1" | awk -F'\t' -v builtins="$CMDLINT_BUILTINS" -v waived=" $waived " '
    BEGIN { split(builtins, b, "|"); for (i in b) isb[b[i]] = 1 }
    {
        depth[NR] = $1; num[NR] = $2; word[NR] = $3; txt[NR] = $4; n = NR
    }
    END {
        for (i = 1; i <= n; i++) {
            w = word[i]; sub(/\.exe$/, "", w)
            if (isb[w]) continue
            if (index(waived, " " num[i] " ")) continue
            # an external program. Does it carry its own || handler?
            if (txt[i] ~ /\|\|/) continue
            nxt = txt[i+1]
            if (nxt == "") {
                printf "line %d: external command `%s` exit code is never checked\n", num[i], word[i]
                continue
            }
            probe = tolower(nxt)
            sub(/^[ \t]*/, "", probe)
            if (probe ~ /^if[ \t]+errorlevel[ \t]+[0-9]/)
                printf "line %d: `%s` is followed by bare `if errorlevel N`. That is a >= test, so it is FALSE for negative exit codes -- and wsl.exe fails with -1 (4294967295). Use `if %%errorlevel%% neq 0`.\n", num[i], word[i]
            else if (probe ~ /^if[ \t]+(not[ \t]+errorlevel|%errorlevel%|"%errorlevel%")/)
                continue
            # Capturing the code for a later test is a legitimate check, and on this file it is
            # the ONLY one that handles the -1 from wsl.exe correctly: a string compare catches
            # 4294967295 where `if errorlevel 1` does not.
            else if (probe ~ /^set[ \t]*"?[a-z_][a-z0-9_]*=[%!]errorlevel[%!]/)
                continue
            else
                printf "line %d: external command `%s` exit code is never checked\n", num[i], word[i]
        }
    }'
}

cmdlint_captures() {                  # cmdlint_captures FILE -> violations
    [ -s "$1" ] || { echo "file is empty or missing: $1"; return 0; }
    _cmdlint_commands "$1" | awk -F'\t' '
    { num[NR] = $2; txt[NR] = $4; n = NR }
    END {
        for (i = 1; i <= n; i++) {
            if (txt[i] !~ /for[ \t]+\/f/) continue
            if (txt[i] !~ /do[ \t]+set[ \t]*"?[A-Za-z_][A-Za-z0-9_]*=/) continue
            var = txt[i]
            sub(/^.*do[ \t]+set[ \t]*"?/, "", var)
            sub(/=.*$/, "", var)
            # cleared before?
            cleared = 0
            for (j = i - 1; j >= 1 && j >= i - 3; j--)
                if (txt[j] ~ ("set[ \t]*\"?" var "=")) cleared = 1
            if (!cleared)
                printf "line %d: `for /f` sets %s with no prior initialisation -- on empty output the body never runs and %s silently keeps whatever it held\n", num[i], var, var
            # validated after? look for any test of the variable in the next few commands
            ok = 0
            for (j = i + 1; j <= n && j <= i + 3; j++)
                if (txt[j] ~ ("if.*[%!]" var "[%!]") || txt[j] ~ ("if.*defined[ \t]+" var)) ok = 1
            if (!ok)
                printf "line %d: `for /f` result %s is used without a validity check\n", num[i], var
        }
    }'
}
