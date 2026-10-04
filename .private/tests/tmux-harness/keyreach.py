#!/usr/bin/env python3
"""Every tmux command a key binding can reach, read from `list-keys` on stdin (#377).

Usage: keyreach.py TMUX < list-keys-output

Prints one line per command:   TABLE KEY <TAB> COMMAND <TAB> DEPTH
DEPTH is 0 for a command the binding runs itself, and one more for each argument the command
had to be unpacked from. A plain word passed as an argument is printed too, with DEPTH `arg`, so
a command that binds or runs another by name (bind-key, set-hook, a shell command) is still
caught by name, as the whole-word grep this replaced caught it. A line whose COMMAND is `?` is
something this could not read, and its third field says what. The caller fails on it, because
skipping it would skip what is inside.

TMUX DOES THE PARSING. `list-keys` is already tmux's parse of the config, with every command
name in full. What it leaves as text is an argument that tmux parses only when it runs: an
if-shell arm, the argument to run-shell -C, confirm-before's command. Each one is bound to a key
in a scratch server and listed again, so an alias (`popup`) or a unique prefix (`split-w`) comes
back as the full name, as tmux itself would resolve it. A braced argument is already parsed, and
is read as it stands, whichever command it is passed to. Both are searched again, to any depth.
"""
import itertools
import os
import subprocess
import sys

TMUX = sys.argv[1]
MAX_DEPTH = 16

# The arguments of a command that are themselves commands: (flags that take a value, which
# positional arguments, a flag that must be set for them to be commands).
ARMS = {
    'if-shell': ('t', slice(1, 3), None),
    'run-shell': ('cdt', slice(0, 1), 'C'),
    'confirm-before': ('cpt', slice(0, 1), None),
}
ESCAPES = {'n': '\n', 't': '\t', 'r': '\r', 'a': '\a', 'b': '\b', 'f': '\f', 'v': '\v'}
SEP, OPEN, CLOSE = (';',), ('{',), ('}',)
_socket = itertools.count()


def tokenize(s):
    """Split a listed line into words, separators and braces, undoing tmux's quoting."""
    toks, i, n = [], 0, len(s)
    while i < n:
        if s[i] in ' \t':
            i += 1
            continue
        if s[i] in '{}' and (i + 1 == n or s[i + 1] in ' \t'):
            toks.append(OPEN if s[i] == '{' else CLOSE)
            i += 1
            continue
        word, quoted = [], False
        while i < n and s[i] not in ' \t':
            c = s[i]
            if c == '"':
                quoted, i = True, i + 1
                while i < n and s[i] != '"':
                    if s[i] == '\\' and i + 1 < n:
                        i += 1
                        if len(s[i:i + 3]) == 3 and all(d in '01234567' for d in s[i:i + 3]):
                            word.append(chr(int(s[i:i + 3], 8)))
                            i += 3
                            continue
                        word.append(ESCAPES.get(s[i], s[i]))
                    else:
                        word.append(s[i])
                    i += 1
                i += 1
            elif c == "'":
                end = s.find("'", i + 1)
                end = n if end < 0 else end
                word.append(s[i + 1:end])
                quoted, i = True, end + 1
            elif c == '\\' and i + 1 < n:
                word.append(s[i + 1])
                i += 2
            else:
                word.append(c)
                i += 1
        text = ''.join(word)
        # `;;` ends a group, which is how a multi-line braced block comes back from list-keys.
        toks.append(SEP if text in (';', ';;') and not quoted else ('w', text))
    return toks


def nest(toks):
    """Group braces into blocks: ('w', text), SEP or ('blk', items). None if they do not balance."""
    stack = [[]]
    for t in toks:
        if t == OPEN:
            stack.append([])
        elif t == CLOSE:
            if len(stack) == 1:
                return None
            inner = stack.pop()
            stack[-1].append(('blk', inner))
        else:
            stack[-1].append(t)
    return stack[0] if len(stack) == 1 else None


def commands(items):
    cmd = []
    for it in items:
        if it == SEP:
            if cmd:
                yield cmd
            cmd = []
        else:
            cmd.append(it)
    if cmd:
        yield cmd


def arms(args, spec):
    """The arguments of one command that hold commands, by tmux's flag rules for that command."""
    valued, which, needed = spec
    flags, pos, i = set(), [], 0
    while i < len(args):
        a = args[i]
        i += 1
        if pos or a[0] != 'w' or not a[1].startswith('-') or a[1] == '-':
            pos.append(a)
            continue
        if a[1] == '--':
            pos.extend(args[i:])
            break
        for j, f in enumerate(a[1][1:]):
            if f in valued:
                if j + 2 == len(a[1]):
                    i += 1
                break
            flags.add(f)
    if needed and needed not in flags:
        return []
    return pos[which]


def binding(line):
    """(TABLE KEY, items) for one listed binding, or None if it is not one."""
    toks = tokenize(line)
    if not toks or toks[0] != ('w', 'bind-key'):
        return None
    i, table = 1, '?'
    while i < len(toks) and toks[i][0] == 'w' and toks[i][1] in ('-r', '-n', '-N', '-T'):
        if toks[i][1] in ('-N', '-T'):
            if toks[i][1] == '-T' and i + 1 < len(toks) and toks[i + 1][0] == 'w':
                table = toks[i + 1][1]
            i += 2
        else:
            i += 1
    if i < len(toks) and toks[i] == SEP:
        key = ';'                         # the key `;` is listed as `\;`, which reads as one
    elif i < len(toks) and toks[i][0] == 'w':
        key = toks[i][1]
    else:
        return None
    items = nest(toks[i + 1:])
    return None if items is None else ('%s %s' % (table, key), items)


def reparse(text):
    """tmux's own parse of a command string, as list-keys prints it, or None if tmux refuses it."""
    sock = 'hxreach-%d-%d' % (os.getpid(), next(_socket))
    r = subprocess.run([TMUX, '-L', sock, '-f', '/dev/null', 'start-server', ';',
                        'bind-key', '-T', 'hxreach', 'x', text, ';',
                        'list-keys', '-T', 'hxreach', ';', 'kill-server'],
                       capture_output=True, text=True, errors='surrogateescape')
    lines = [l for l in r.stdout.split('\n') if l.strip()]
    if r.returncode != 0 or len(lines) != 1:
        return None
    b = binding(lines[0])
    return None if b is None else b[1]


def walk(where, items, depth, out):
    if depth > MAX_DEPTH:
        out.append((where, '?', 'nested deeper than %d' % MAX_DEPTH))
        return
    for cmd in commands(items):
        if cmd[0][0] != 'w':
            out.append((where, '?', 'a braced block where a command name belongs'))
            continue
        out.append((where, cmd[0][1], str(depth)))
        # A block is a command list whoever takes it; a word is reported by name.
        for arg in cmd[1:]:
            if arg[0] == 'blk':
                walk(where, arg[1], depth + 1, out)
            else:
                out.append((where, arg[1], 'arg'))
        spec = ARMS.get(cmd[0][1])
        for arm in arms(cmd[1:], spec) if spec else []:
            if arm[0] == 'w' and arm[1].strip():
                inner = reparse(arm[1])
                if inner is None:
                    out.append((where, '?', 'tmux would not parse %r' % arm[1]))
                else:
                    walk(where, inner, depth + 1, out)


def main():
    out = []
    for line in sys.stdin.buffer.read().decode('utf-8', 'surrogateescape').split('\n'):
        if not line.strip():
            continue
        b = binding(line)
        if b is None:
            out.append(('?', '?', 'not a binding: %r' % line))
        else:
            walk(b[0], b[1], 0, out)
    for where, name, detail in out:
        print('%s\t%s\t%s' % (where, name, detail))


if __name__ == '__main__':
    sys.stdout.reconfigure(errors='surrogateescape')
    # A crash prints a `?` rather than nothing, which would read as "no binding reaches anything".
    try:
        main()
    except Exception as e:  # pylint: disable=broad-except
        print('?\t?\tkeyreach.py failed: %r' % e)
        sys.exit(1)
