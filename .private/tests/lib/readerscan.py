#!/usr/bin/env python3
"""readerscan.py MARKER FILE... -> the assertions a failed read would pass, one per line.

An assertion that passes on an EMPTY value -- every negative form, and assert_eq NAME "" -- passes
just as well when the value is empty because its reader failed: `cat` of a missing file prints
nothing, and nothing contains no needle (#437, #476, #539, #559). run_checker, run_grep and
lint_grep turn that failure into $CHECKER_DIED, which the assertions refuse; this finds the values
that do not go through one of them.

Four shapes, each a line `FILE:LINE: WHY`:
  bare       the value is a reader's own output: "$(cat F)", "$(grep x F | ...)", or a
             pipe with a later `grep -f FILE` in it, which reads FILE.
  filtered   a checked reader piped into a stage that keeps only some lines, which can drop the
             marker line before the assertion sees it: "$(run_checker sed ... F | grep x)".
  var-filtered  the same through a variable this file filled from a checked reader, without
             died_in in front: "$(printf '%s\\n' "$v" | grep x)".
  var-bare   the value is a variable this file filled from a bare reader, or printf of one.

A file it cannot read, and a statement it cannot parse, print MARKER and why, so that neither can
pass as "found nothing". Comment lines are skipped. The parser is a shell tokenizer for exactly
what assertion arguments contain -- quotes, $( ), ${ }, backquotes, line continuations -- and
not a shell; it refuses rather than guesses.
"""
import os
import re
import sys

NEG = {"assert_not_contains", "assert_says_not", "assert_says_not_key", "assert_says_not_key_tail",
       "assert_says_not_sub", "assert_not_match"}
READERS = {"cat", "sed", "grep", "egrep", "fgrep", "awk", "do_awk", "head", "tail", "cut", "sort",
           "uniq", "tr", "do_tr", "jq", "find", "ls", "xargs", "paste", "strings", "python3"}
CHECKED = {"run_checker", "run_grep", "lint_grep"}
# Stages that keep only SOME lines. grep -v keeps the marker unless its pattern matches it, and
# sed without -n prints every line, so neither is here.
KEEPERS = {"grep", "egrep", "fgrep", "head", "tail", "awk", "do_awk", "uniq", "cut", "python3"}

START = re.compile(r'(?:^|[;&|({]|\bthen\b|\bdo\b|\belse\b)[ \t]*(assert_[a-z_]+)(?=[ \t\\])', re.M)
WORD_END = ' \t\n;&|'


class Unparsed(Exception):
    pass


def skip_single(s, i):                # s[i] is ' -> index after the closing one
    j = s.find("'", i + 1)
    if j < 0:
        raise Unparsed("an unterminated '")
    return j + 1


def skip_back(s, i):                  # s[i] is `
    j = i + 1
    while j < len(s) and s[j] != '`':
        j += 2 if s[j] == '\\' else 1
    if j >= len(s):
        raise Unparsed("an unterminated `")
    return j + 1


def skip_double(s, i):                # s[i] is "
    i += 1
    while i < len(s):
        c = s[i]
        if c == '\\':
            i += 2
        elif c == '"':
            return i + 1
        elif s.startswith('$(', i):
            i = skip_subst(s, i + 2)
        elif s.startswith('${', i):
            i = skip_brace(s, i + 2)
        elif c == '`':
            i = skip_back(s, i)
        else:
            i += 1
    raise Unparsed('an unterminated "')


def skip_brace(s, i):                 # i is just after ${
    while i < len(s):
        c = s[i]
        if c == '\\':
            i += 2
        elif c == "'":
            i = skip_single(s, i)
        elif c == '"':
            i = skip_double(s, i)
        elif s.startswith('$(', i):
            i = skip_subst(s, i + 2)
        elif s.startswith('${', i):
            i = skip_brace(s, i + 2)
        elif c == '}':
            return i + 1
        else:
            i += 1
    raise Unparsed("an unterminated ${")


def skip_subst(s, i):                 # i is just after $( -> index after its )
    depth, word_start = 1, True
    while i < len(s):
        c = s[i]
        if c == '\\':
            i += 2
        elif c == "'":
            i = skip_single(s, i)
        elif c == '"':
            i = skip_double(s, i)
        elif c == '`':
            i = skip_back(s, i)
        elif s.startswith('$(', i):
            i = skip_subst(s, i + 2)
        elif s.startswith('${', i):
            i = skip_brace(s, i + 2)
        elif c == '#' and word_start:
            j = s.find('\n', i)
            i = len(s) if j < 0 else j
        else:
            if c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
                if depth == 0:
                    return i + 1
            word_start = c in ' \t\n;|&('
            i += 1
            continue
        word_start = False
    raise Unparsed("an unterminated $(")


def skip_word(s, i):                  # -> index just past the word starting at i
    while i < len(s) and s[i] not in WORD_END and not s.startswith('\\\n', i):
        c = s[i]
        if c == '\\':
            i += 2
        elif c == "'":
            i = skip_single(s, i)
        elif c == '"':
            i = skip_double(s, i)
        elif c == '`':
            i = skip_back(s, i)
        elif s.startswith('$(', i):
            i = skip_subst(s, i + 2)
        elif s.startswith('${', i):
            i = skip_brace(s, i + 2)
        elif c == ')':
            break
        else:
            i += 1
    return i


def words_at(s, i, n):                # the first N words of the command at s[i:], and its end
    out = []
    while len(out) < n:
        while i < len(s) and (s[i] in ' \t' or s.startswith('\\\n', i)):
            i += 2 if s[i] == '\\' else 1
        if i >= len(s) or s[i] in '\n;&|)#':
            break
        j = skip_word(s, i)
        out.append(s[i:j])
        i = j
    return out, i


def words(s, i, n):
    return words_at(s, i, n)[0]


def stages(body):                     # a $( )'s body -> [(separator before it, its words)]
    out, sep, i = [], '', 0
    while True:
        out.append((sep, words(body, i, 8)))
        # to the next separator at this level
        while i < len(body):
            if body[i] in ' \t' or body.startswith('\\\n', i):
                i += 2 if body[i] == '\\' else 1
            elif body[i] in '\n;&|':
                break
            elif body[i] == '#':
                j = body.find('\n', i)
                i = len(body) if j < 0 else j
            else:
                i = max(skip_word(body, i), i + 1)
        if i >= len(body):
            return out
        for op in ('||', '&&', '|', ';', '\n', '&'):
            if body.startswith(op, i):
                sep, i = op, i + len(op)
                break


def first_cmd(ws):                    # a stage's words -> its command, past any VAR=value
    for w in ws:
        if not re.match(r'[A-Za-z_][A-Za-z0-9_]*=', w):
            return w
    return ''


def subst_body(word):                 # "$(...)" or $(...) at the start -> its body, else None
    i = 1 if word.startswith('"') else 0
    if not word.startswith('$(', i) or word.startswith('$((', i):
        return None
    end = skip_subst(word, i + 2)
    return word[i + 2:end - 1]


def unquote_var(word):                # "$v" or "${v}" -> v, else None
    m = re.fullmatch(r'"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))"', word)
    return (m.group(1) or m.group(2)) if m else None


def keeper(st):                       # a stage that keeps only some lines?
    cmd = first_cmd(st)
    if cmd in ('grep', 'egrep', 'fgrep'):
        return not any(re.fullmatch(r'-[A-Za-z]*v[A-Za-z]*', w) for w in st[1:])
    if cmd == 'sed':
        return any(re.fullmatch(r'-[A-Za-z]*n[A-Za-z]*', w) for w in st[1:])
    return cmd in KEEPERS


def reads_a_file(sts):                # a stage past the first that is a bare grep -f FILE
    for sep, st in sts[1:]:
        if first_cmd(st) in ('grep', 'egrep', 'fgrep') and any(
                re.match(r'-[A-Za-z]*f|--file\b', w) for w in st[1:]):
            return True
    return False


# `cmd || printf 'failed'` turns its own failure into a line; `|| true` does not.
def answers_for_itself(sts):
    return any(sep == '||' and first_cmd(st) in ('printf', 'echo') for sep, st in sts[1:])


def counts(sts):                      # a count of nothing is 0, not empty
    return any(first_cmd(st) == 'wc' for _, st in sts)


def classify(sts, helpers):           # a pipe's stages -> (bare|filtered|checked|other, what)
    if answers_for_itself(sts) or counts(sts):
        return 'other', ''
    head = first_cmd(sts[0][1])
    if head in READERS:
        return 'bare', f"{head}'s own output"
    if head in helpers:
        return 'bare', f"{head}, a helper that reads with a bare {helpers[head]}"
    if reads_a_file(sts):
        return 'bare', "a pipe whose grep -f reads its pattern file unchecked"
    if head in CHECKED:
        for sep, st in sts[1:]:
            if sep == '|' and keeper(st):
                return 'filtered', f"{head}'s marker can be dropped by {first_cmd(st)}"
        return 'checked', head
    return 'other', head


def kind(value, helpers):             # an assignment's value -> ('checked'|'bare'|'other', what)
    body = subst_body(value)
    if body is None:
        return 'other', ''
    sts = stages(body)
    if first_cmd(sts[0][1]) == 'died_in':   # it can carry the marker, so it is checked
        return 'checked', 'died_in'
    k, what = classify(sts, helpers)
    return ('bare' if k == 'filtered' else k), what


# WHERE EACH VARIABLE WAS LAST SET, by position, because these are shell globals and a name is
# reused: assert.sh's `t` is a parameter in one function and an awk read in another. A statement
# that is ONLY assignments sets them; `VAR=x cmd` is cmd's environment and sets nothing; every
# word of a local/export line is one. `v="$(...)" || v=...` checked its own status and is not bare.
STMT = re.compile(r'(?:^|\|\||&&|;|[({]|\bthen\b|\bdo\b|\belse\b)[ \t]*', re.M)
NAME_EQ = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)=(.*)', re.S)


def assignments(text, helpers):       # -> {name: [(pos, kind, what)]}, each list in order
    out = {}
    for m in STMT.finditer(text):
        try:
            ws, end = words_at(text, m.end(), 64)
            if not ws:
                continue
            decl = ws[0] in ('local', 'export', 'readonly', 'declare')
            cand = [w for w in ws[1:] if not w.startswith('-')] if decl else ws
            sets = [NAME_EQ.match(w) for w in cand]
            if not sets or not all(sets):
                if not decl:
                    continue
                sets = [s for s in sets if s]
            guarded = text[end:].lstrip(' \t').startswith('||')
            for s in sets:
                k, what = ('other', '') if guarded else kind(s.group(2), helpers)
                out.setdefault(s.group(1), []).append((m.end(), k, what))
        except Unparsed:
            continue
    return out


def last_set(sets, name, pos):        # the assignment to NAME in force at POS, or None
    best = None
    for p, k, what in sets.get(name, ()):
        if p < pos:
            best = (k, what)
    return best


# A HELPER WHOSE WHOLE BODY IS ONE READ is that read at every call site: `fz() { awk ... "$OUT"; }`
# makes "$(fz key)" exactly as blind as "$(awk ...)". One statement only -- a body that reads into
# a local and puts died_in in front is the fix, and is not second-guessed.
FNDEF = re.compile(r'^[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*\(\)[ \t]*\{', re.M)
FNEND = re.compile(r'^[ \t]*\}[ \t]*$', re.M)


def definitions(text):                # -> {name: the bare reader its one statement is, or None}
    out = {}
    for m in FNDEF.finditer(text):
        eol = text.find('\n', m.end())
        eol = len(text) if eol < 0 else eol
        rest = text[m.end():eol].rstrip()
        if rest.endswith('}') and not rest.lstrip().startswith('#'):
            body = rest[:-1]
        else:
            close = FNEND.search(text, eol)
            body = text[eol + 1:close.start()] if close else ''
        code = '\n'.join(l for l in body.split('\n') if l.strip() and not l.strip().startswith('#'))
        out[m.group(1)] = None
        try:
            sts = stages(code.strip().rstrip(';').rstrip())
        except Unparsed:
            continue
        if any(sep not in ('|', '||') for sep, _ in sts[1:]):
            continue
        if classify(sts, {})[0] in ('bare', 'filtered'):
            out[m.group(1)] = first_cmd(sts[0][1])
    return out


def why(value, sets, pos, helpers):
    body = subst_body(value)
    if body is None:
        v = unquote_var(value)
        got = last_set(sets, v, pos) if v else None
        if got and got[0] == 'bare':
            return f"var-bare: ${v} was filled by {got[1]}"
        return None
    sts = stages(body)
    k, what = classify(sts, helpers)
    if k == 'bare':
        return f"bare: the value is {what}"
    if k == 'filtered':
        return f"filtered: {what}"
    piped = [st for sep, st in sts[1:] if sep == '|']
    if first_cmd(sts[0][1]) == 'printf':
        for v in filter(None, (unquote_var(w) for w in sts[0][1][1:])):
            got = last_set(sets, v, pos)
            if got and got[0] == 'bare':
                return f"var-bare: ${v} was filled by {got[1]}"
            if got and got[0] == 'checked' and any(keeper(st) for st in piped):
                return f"var-filtered: ${v} reaches a line-keeping stage without died_in"
    return None


def scan(path, text, marker, lib_helpers):
    line_of = lambda i: text.count('\n', 0, i) + 1
    own = definitions(text)
    helpers = {n: r for n, r in lib_helpers.items() if n not in own}
    helpers.update({n: r for n, r in own.items() if r})
    sets = assignments(text, helpers)
    for m in START.finditer(text):
        fn = m.group(1)
        if fn not in NEG and fn not in ('assert_eq', 'assert_ne'):
            continue
        bol = text.rfind('\n', 0, m.start(1)) + 1
        if text[bol:m.start(1)].lstrip().startswith('#'):
            continue
        try:
            ws = words(text, m.start(1), 4)
            if len(ws) < 4:
                continue
            # assert_eq passes on empty only when it expects empty; assert_ne only when it does not.
            if (fn == 'assert_eq') != (ws[2] in ('""', "''")):
                continue
            w = why(ws[3], sets, m.start(1), helpers)
        except Unparsed as e:
            print(f"{path}:{line_of(m.start(1))}: {marker} (could not parse this {fn}: {e})")
            continue
        if w:
            print(f"{path}:{line_of(m.start(1))}: {fn} {ws[1]}: {w}")


def main(argv):
    if len(argv) < 3:
        print(f"{argv[1] if len(argv) > 1 else 'CHECKER-DIED'} (readerscan.py was handed no files)")
        return 0
    texts = {}
    for path in argv[2:]:
        try:
            with open(path, encoding='utf-8', errors='surrogateescape') as f:
                texts[path] = f.read()
        except OSError as e:
            print(f"{argv[1]} (cannot read {path}: {e.strerror})")
    # lib/'s helpers reach every suite that sources it; a suite's own definitions shadow them.
    lib_helpers = {}
    for path, text in texts.items():
        if os.path.basename(os.path.dirname(path)) == 'lib':
            lib_helpers.update({n: r for n, r in definitions(text).items() if r})
    for path, text in texts.items():
        scan(path, text, argv[1], lib_helpers)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
