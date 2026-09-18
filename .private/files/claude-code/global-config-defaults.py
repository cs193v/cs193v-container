#!/usr/bin/env python3
"""Course defaults for Claude Code's GLOBAL CONFIG, ~/.claude.json.

WHY THIS FILE EXISTS, AND WHY IT IS NOT A POLICY SETTING. `"tui": "fullscreen"` in
managed-settings.json turns on the renderer's own text selection, whose `copyOnSelect`
DEFAULTS TO TRUE: a drag inside Claude Code then copies with `tmux load-buffer -w -` and
toasts "copied N chars to tmux buffer - paste with prefix + ]". This configuration sets
`prefix None`, so that names a key that does not exist -- and on macOS Terminal.app, which
does not implement OSC 52 (measured; files/tmux/tmux.conf Part 3), the copy does not reach
the clipboard either. A message claiming a copy that did not happen is issue #66.

IT CANNOT BE A SETTING. `copyOnSelect` is not in Claude Code's settings schema at all; it
is read from the GLOBAL CONFIG, ~/.claude.json. /etc/claude-code/managed-settings.json
cannot carry it, and there is no environment variable for it (all 647 CLAUDE_CODE_* names
in the shipped binary were enumerated; none touch the clipboard).

WHY IT RESOLVES THE PATH FIRST, and this is the trap that makes the file worth testing.
rename(2) does NOT follow a symlink on its destination, and ~/.claude.json IS a symlink
into the cs193v-claude-json volume (see files/entrypoint.sh). os.replace() against the
link would therefore REPLACE THE SYMLINK with a regular file in the container's writable
layer: the student's real config would go stale on the volume, and the replacement would
vanish at the next --rebuild. realpath() first means the temp lands beside the real file,
on the volume, so the rename is same-filesystem and the symlink survives.

WHY ONLY WHEN THE KEY IS ABSENT. /config offers "Copy on select" as a toggle and nothing
here can mark a value as policy the way `tui` is, so forcing it every start would make
that toggle appear to work and then revert -- the same species of lie as the toast. A
student who turns it back on keeps it, and on a terminal that implements OSC 52 it works.

WHY THE ENTRYPOINT AND NOT THE IMAGE. podman copies image content only into an EMPTY
named volume, so a copy baked in at this path would be seeded on first mount and never
refreshed -- which is every student and every staff checkout that already exists. Same
trap and same shape of fix as ~/.codex/AGENTS.md next door.

IT NEVER RAISES AND main() ALWAYS EXITS 0. The outcome is carried in a single word on
stdout so tests can assert it without inspecting the file, and so PID 1's prologue can
never be made to fail by anything in here.
"""

import json
import os
import sys
import tempfile

DEFAULTS = {"copyOnSelect": False}


def merge(path, defaults=DEFAULTS):
    """Add any missing keys from `defaults` to the JSON object at `path`.

    Returns one word: "added:<k>,<k>" | "unchanged" | "declined:<reason>".
    Never raises. Never opens `path` for writing, so the file cannot be
    truncated: a new copy is written beside it and renamed over it.
    """
    try:
        path = os.path.realpath(path)
    except OSError as e:
        return "declined:unresolvable-%s" % getattr(e, "errno", "?")

    try:
        with open(path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        return "declined:unreadable"

    # A JSON array or scalar parses fine and is not something to merge into.
    if not isinstance(cfg, dict):
        return "declined:not-an-object"

    missing = [k for k in defaults if k not in cfg]
    if not missing:
        return "unchanged"
    for k in missing:
        cfg[k] = defaults[k]

    # The mode is captured from the ORIGINAL: mkstemp makes 0600, so without this a
    # 0644 config silently becomes 0600. Harmless today; a silent mode change is not
    # the kind of thing to ship unremarked.
    try:
        mode = os.stat(path).st_mode & 0o7777
    except OSError:
        mode = 0o644

    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(
            dir=os.path.dirname(path), prefix=".claude.json.new."
        )
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            # indent=2 is what Claude Code itself writes, so a second run over a file
            # that already has the key is a byte-identical no-op rather than a reformat.
            json.dump(cfg, f, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
        # NO DIRECTORY FSYNC, deliberately: a crash between the rename and the dirent
        # flush loses the key, and losing the key means the next start sets it again.
        tmp = None
    except Exception as e:
        # BROADER THAN OSError, and the breadth is the "never raises" promise rather than
        # defensiveness for its own sake. PID 1's prologue calls this; an exception escaping
        # here would be a traceback in the entrypoint. Today nothing but OSError can arrive
        # -- cfg came from json.load, so it is serializable by construction, and DEFAULTS is
        # ours -- but "today" is not a guarantee worth resting the container's start on.
        return "declined:%s" % (getattr(e, "errno", None) or "write-failed")
    finally:
        if tmp is not None:
            try:
                os.unlink(tmp)
            except OSError:
                pass

    return "added:" + ",".join(missing)


def main(argv):
    if len(argv) != 2:
        print("usage: global-config-defaults.py PATH", file=sys.stderr)
        return 0
    print(merge(argv[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
