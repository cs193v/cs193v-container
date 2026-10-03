#!/usr/bin/env python3
r"""frozen-waits.py [--count] FILE...  -> FILE:LINE:TEXT for every wait whose condition is frozen

10-static.sh's waits: rule (#378). Some waits take their condition as a shell STRING and run it
again on every poll: `wait_until SECS ... sh -c WORD`, and the tmux harness's hx_until family,
which evals one of its arguments. A `$(` or a backtick that the CALLER's shell expands is run once,
while the arguments are being built, so every poll then tests the same frozen answer. So is one in
`wait_until SECS [ ... ]` or `wait_until SECS test ...`, which re-run a comparison whose every
operand was fixed before the first poll.

The condition is read as shell WORDS, the way the shell reads them: `\$(` is deferred and `\\$(`
is not; single quotes defer everything; arithmetic `$((` is fine unless it holds a `$(` of its
own; and a word goes on past its closing quote, so `"[ -n "$(x)" ]"` is caught as well. Any other
argument -- hx_until's expected value, a function's operand -- is meant to be computed once and
is not looked at.

A call is skipped when the text before it ON ITS LINE puts it in a comment or a string. A string
opened on an earlier line is not seen, so a call quoted on the second line of a message is
reported: wrongly, but loudly, which is the direction to be wrong in.

--count prints how many conditions were examined, as `wait=N hx=M`, so the caller can tell a rule
that found nothing wrong from one that found nothing at all.
"""
import re
import sys

BLANK = r'(?:[ \t]|\\\n)'             # a blank, or a backslash-newline continuation
OPT = BLANK + r'+-[A-Za-z]+'
# The shell's -c string is what every poll runs, wherever it sits in CMD: after
# `podman exec "$NAME"`, its `$(` still expands on this side, once. The shell is captured so that
# the text before IT is checked as well -- a trailing comment can mention `sh -c`.
WAIT_SH = re.compile(r'(?<![\w-])wait_until' + BLANK + r'(?:[^\n;&|]|\\\n)*?'
                     r'(?<![\w.-])(?P<cmd>(?:ba|da)?sh)(?:' + OPT + r')*?'
                     + BLANK + r'+-[A-Za-z]*c[A-Za-z]*(?:' + OPT + r')*(?:' + BLANK + r'+--)?'
                     r'(?=' + BLANK + r')')
# `[` and `test` re-run a fixed comparison, so every operand is the condition.
WAIT_TEST = re.compile(r'(?<![\w-])wait_until' + BLANK + r'+[^ \t\n;&|]+' + BLANK
                       + r'+(?P<cmd>\[|test)(?=' + BLANK + r')')
# Which argument each of these evals, counting from 1.
HX_ARG = {'hx_until': 1, 'hx_until_ok': 1, 'hx_until_ne': 1,
          'hx_test_forbidden_keys': 2, 'hx_test_key_encodings': 3}
HX = re.compile(r'(?<![\w-])(?P<cmd>' + '|'.join(sorted(HX_ARG, key=len, reverse=True)) + r')'
                r'(?=' + BLANK + r')')
DELIM = ' \t\n;&|<>()'


def live(prefix):
    """False if a call after PREFIX, the text before it on its line, is in a comment or a string."""
    q, saved, prev, i = '', [], ' ', 0
    while i < len(prefix):
        c = prefix[i]
        if q == "'":
            if c == "'":
                q = ''
        elif c == '\\':
            i, prev = i + 2, 'x'
            continue
        elif prefix.startswith('$(', i):
            saved.append(q)
            q, prev, i = '', '(', i + 2
            continue
        elif q == '"':
            if c == '"':
                q = ''
        elif c == '#' and prev in ' \t;&|(':
            return False
        elif c in '\'"':
            q = c
        elif c == ')' and saved:
            q = saved.pop()
        prev = c
        i += 1
    return q == ''


def substitution(text, i):
    """True if a `$(` that is not arithmetic, or a backtick, starts at I."""
    return text[i] == '`' or (text.startswith('$(', i) and not text.startswith('$((', i))


def close(text, i, depth):
    """-> (index just past the parenthesis that brings DEPTH to zero, first substitution met or -1)"""
    hit = -1
    while i < len(text) and depth:
        if hit < 0 and substitution(text, i):
            hit = i
        if text[i] == '(':
            depth += 1
        elif text[i] == ')':
            depth -= 1
        i += 1
    return i, hit


def blanks(text, i):
    while True:
        if text.startswith('\\\n', i):
            i += 2
        elif i < len(text) and text[i] in ' \t':
            i += 1
        else:
            return i


def word(text, i):
    """Scan one shell word from I -> (end, offset of its first early substitution, or -1)."""
    hit, q = -1, ''
    while i < len(text):
        c = text[i]
        if q == "'":
            if c == "'":
                q = ''
            i += 1
        elif c == '\\':
            i += 2
        elif q == '' and c in DELIM:
            break
        elif c == '"':
            q = '' if q == '"' else '"'
            i += 1
        elif q == '' and c == "'":
            q = "'"
            i += 1
        elif text.startswith('$((', i):
            i, inner = close(text, i + 3, 2)
            hit = inner if hit < 0 else hit
        elif text.startswith('$(', i):
            hit = i if hit < 0 else hit
            i, _ = close(text, i + 2, 1)
        elif c == '`':
            hit = i if hit < 0 else hit
            end = text.find('`', i + 1)
            i = len(text) if end < 0 else end + 1
        else:
            i += 1
    return i, hit


def condition(text, i, argn):
    """The ARGN'th word from I, or with None every word to the end of the command.
    -> (whether there was one, offset of its first early substitution or -1)"""
    if argn is None:
        found, hit = False, -1
        while True:
            i = blanks(text, i)
            end, h = word(text, i)
            if end == i:
                return found, hit
            found, hit, i = True, (h if hit < 0 else hit), end
    for _ in range(argn - 1):
        i, _ = word(text, blanks(text, i))
    i = blanks(text, i)
    end, hit = word(text, i)
    return end > i, hit


def main(argv):
    count = bool(argv) and argv[0] == '--count'
    files = argv[1:] if count else argv
    sites = {'wait': 0, 'hx': 0}
    for path in files:
        with open(path, encoding='utf-8', errors='replace') as fh:
            text = fh.read()
        calls = [(m, 'wait', 1) for m in WAIT_SH.finditer(text)]
        calls += [(m, 'wait', None) for m in WAIT_TEST.finditer(text)]
        calls += [(m, 'hx', HX_ARG[m.group('cmd')]) for m in HX.finditer(text)]
        for m, kind, argn in calls:
            bol = text.rfind('\n', 0, m.start()) + 1
            if not live(text[bol:m.start('cmd')]):
                continue
            found, hit = condition(text, m.end(), argn)
            if not found:
                continue              # no such argument: not a call this rule knows
            sites[kind] += 1
            if hit >= 0 and not count:
                eol = text.find('\n', bol)
                print('%s:%d:%s' % (path, text.count('\n', 0, bol) + 1,
                                    text[bol:len(text) if eol < 0 else eol]))
    if count:
        print('wait=%d hx=%d' % (sites['wait'], sites['hx']))


main(sys.argv[1:])
