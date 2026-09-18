#!/usr/bin/env bash
# A PowerShell linter for install-cs193v.ps1, and a deliberately small one.
#
# WHY THIS EXISTS AND WHY IT IS NOT cmdlint.sh. Its sibling defends against batch: ten checkers,
# most of them for pathologies that have no PowerShell equivalent at all. This file has three,
# because the .ps1 is forty lines of code rather than 1396 and because PowerShell takes most of
# the traps away by itself -- it does not resolve a bare command name against the current
# directory, it has no delayed expansion, and its parser does not care where a line ends.
#
# WHAT IT CANNOT DO IS EXECUTE ANYTHING, and that is the whole reason these rules are static. The
# wine tier runs the .cmd under wine's cmd.exe; there is no counterpart for PowerShell. Windows
# PowerShell 5.1 needs the .NET Framework CLR and cannot run under wine -- the fixture disables
# mscoree outright -- and pwsh 7 on Linux is a different language runtime whose divergences from
# 5.1 are not enumerated anywhere upstream, which is exactly the shape of failure that shipped a
# completely broken .cmd under a green tier (see cmdlint_bad_parameter_substitution). So the
# rules below are the ones a reader would otherwise have to remember, and MANUAL.md carries the
# rest as hand-verification.
#
# cmdlint_non_ascii IS REUSED RATHER THAN COPIED. The predicate is identical and file-type
# agnostic; only the REASON differs -- batch is decoded as OEM with no UTF-8 support, while this
# file is decoded by Invoke-RestMethod, which falls back to ISO-8859-1 when the response carries
# no charset. 25-installer.sh sources cmdlint.sh already and calls it on both files.
#
# Each checker prints one violation per line and nothing when clean, so a caller writes
#     assert_eq "winboot:never-exits" "" "$(run_checker ps1lint_exit "$P")"
# and `run_checker` turns a checker that dies into a value the assertion cannot pass on.

# _ps1lint_code FILE -> "LINENO<TAB>TEXT" for lines that are not whole-line comments.
#
# WHOLE-LINE COMMENTS ONLY, AND THAT IS CONSERVATIVE ON PURPOSE. A `#` can also open a trailing
# comment, but it can equally sit inside a string, and getting that wrong in the other direction
# would DELETE code from the work list -- a rule that silently stops looking is worse than one
# that occasionally looks at a comment. Every rule below tolerates being handed a trailing
# comment; none tolerates being handed nothing. The file's own style is whole-line comments, so
# in practice the two agree.
_ps1lint_code() {
    sed 's/\r$//' "$1" | grep -nv '^[[:space:]]*#' || true
}

# NO `exit`, ANYWHERE, AND THIS IS THE RULE NOBODY WILL REMEMBER.
#
# Measured on Windows PowerShell 5.1.26100.9444: `exit` inside text run by `iex` terminates
# powershell.exe ITSELF rather than the script. Under the published gesture the host IS the
# student's interactive window, so a refusal would print its four lines and the window would then
# vanish, taking the refusal with it -- the worst possible outcome for a message whose entire job
# is to be read. `return` inside the file's script block returns from the block and nothing else,
# measured the same day on the same host, and that is what every refusal arm uses.
#
# [Environment]::Exit AND [System.Environment]::Exit ARE THE SAME DEFECT IN A LONGER SPELLING,
# so they are caught here too. So is `$host.SetShouldExit`, which is how the same mistake is
# usually written by somebody who already knows `exit` is wrong.
ps1lint_exit() {                      # ps1lint_exit FILE -> violations
    [ -s "$1" ] || { echo "file is empty or missing: $1"; return 0; }
    _ps1lint_code "$1" \
        | grep -nE '(^|[^[:alnum:]_-])(exit([^[:alnum:]_-]|$)|\[(System\.)?Environment\]::Exit|SetShouldExit)' \
        | sed 's/^[0-9]*://' \
        | sed 's/^\([0-9]*\):/line \1: `exit` ends powershell.exe itself when this file is run by iex, which closes the student window before a refusal can be read -- use `return` inside the script block instead: /' \
        || true
}

# NO BYTE-ORDER MARK, which is a published-bytes defect and not a tidiness one.
#
# Measured on 5.1.26100.9444: a leading UTF-8 BOM makes `iex` fail to PARSE, so the one-liner dies
# on line one for every student at once with nothing to read but a parse error. Git has no
# attribute that can prevent one, so this and .private/release.sh are the whole defence.
#
# DELIBERATELY NOT A LINE-ENDING RULE, which is the opposite of cmdlint_line_endings and is worth
# saying here so nobody adds one for symmetry. CRLF is load-bearing for a batch file because
# cmd.exe's label scanner assumes a two-byte terminator; PowerShell's parser does not care.
# Measured: `iex` parses this file identically with LF and with CRLF, inside its script block and
# outside it, and the truncation property the script block provides holds either way. Nothing
# hashes this file, so a rule would be asserting a property no one can observe.
ps1lint_bom() {                       # ps1lint_bom FILE -> violations
    [ -s "$1" ] || { echo "file is empty or missing: $1"; return 0; }
    [ "$(head -c 3 "$1" | od -An -tx1 | do_tr -d ' \n')" = "efbbbf" ] \
        && echo "starts with a UTF-8 byte-order mark, which makes iex refuse to parse the file" \
        || true
}

# EVERY EXTERNAL PROGRAM CARRIES ITS OWN PATH, which is issue #125's rule kept rather than
# inherited.
#
# PowerShell does NOT resolve a bare command name against the current directory, so the hole this
# closes in the .cmd is not open here -- which is precisely why the rule needs writing down. The
# reason to keep it is the second half of #125: Windows need not be installed on C: and the
# directory need not be called Windows, so a hard-coded path is wrong for a different reason than
# a bare name is. $env:SystemRoot answers both.
#
# TWO SHAPES REACH A PROGRAM FROM HERE: `-FilePath` on Start-Process, and the call operator `&`.
# The work list is derived by parsing rather than listed, so a call site added next term is
# covered the day it lands.
#
# `& {` IS NOT A PROGRAM. The whole body of the file is a script block invoked with the call
# operator, and flagging it would make the rule unsatisfiable. A `&` followed by `{` opens a
# block; anything else is an invocation.
ps1lint_unqualified_programs() {      # ps1lint_unqualified_programs FILE -> violations
    [ -s "$1" ] || { echo "file is empty or missing: $1"; return 0; }
    _ps1lint_code "$1" | awk -F: '
    {
        lineno = $1
        text = substr($0, index($0, ":") + 1)

        # ─── Start-Process and anything else taking -FilePath ───
        if (match(text, /-FilePath[ \t]+[^ \t]+/)) {
            arg = substr(text, RSTART + 9, RLENGTH - 9)
            gsub(/^[ \t]+/, "", arg)
            if (arg !~ /\$env:SystemRoot\\/)
                printf "line %s: -FilePath %s does not name the program through $env:SystemRoot -- Windows need not be installed on C: and the directory need not be called Windows\n", lineno, arg
        }

        # ─── the call operator ───
        s = text
        while (match(s, /&[ \t]*[^ \t{]/)) {
            rest = substr(s, RSTART + RLENGTH - 1)
            # A quoted or $env:-rooted target is the qualified form.
            if (rest !~ /^\$env:SystemRoot\\/ && rest !~ /^"\$env:SystemRoot\\/)
                printf "line %s: `&` invokes %s without naming it through $env:SystemRoot\n", lineno, substr(rest, 1, 40)
            s = substr(s, RSTART + RLENGTH)
        }
    }' || true
}
