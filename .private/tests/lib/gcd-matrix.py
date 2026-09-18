#!/usr/bin/env python3
"""Drive global-config-defaults.py's merge() over every case that matters (#307).

Lives here rather than in a heredoc inside 10-static.sh for two reasons: bash's `$(...)`
scanner mishandles a heredoc whose body carries unbalanced quotes, and a .py under tests/
is picked up by this suite's own `syntax:python` gate for free.

Argument: the path to global-config-defaults.py. Prints one `ok NAME` / `FAIL NAME` per
line and always exits 0 -- the caller asserts on the lines, so a failing case is a named
failure rather than a dead probe.

EVERY CASE IS A THUNK AND EVERY EXCEPTION IS THAT CASE'S OWN FAILURE, and that is worth
stating because the obvious shape is wrong. Written as bare expressions accumulated into a
list and printed at the end, one raising case takes the whole file down BEFORE the print --
so the caller sees every assertion red and no clue which one broke. Measured while mutation
testing: deleting realpath() from the helper made the symlink case raise KeyError and
reddened all eighteen. Now it reddens one. Lines are flushed as they are decided, so even a
hard crash leaves the earlier results readable.
"""

import importlib.util
import json
import os
import shutil
import stat
import sys
import tempfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("gcd", sys.argv[1])
gcd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gcd)

# ITS OWN TEMP ROOT. There is no suite-wide scratch variable to borrow -- assert.sh mints its
# own with mktemp -d -- and a matrix that wrote into the working tree would show up in git
# status and eventually in somebody's commit.
ROOT = tempfile.mkdtemp(prefix="cs193v-gcd.")


def case(name, fn):
    try:
        ok = bool(fn())
    except Exception as e:                      # this case's failure, not the run's
        print("FAIL %s (raised %s: %s)" % (name, type(e).__name__, e), flush=True)
        return
    print("%s %s" % ("ok" if ok else "FAIL", name), flush=True)


def write(rel, text, mode=0o644):
    p = os.path.join(ROOT, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write(text)
    os.chmod(p, mode)
    return p


def load(p):
    with open(p) as f:
        return json.load(f)


# --- the key is added when absent, and is the course default ------------------
p = write("a/c.json", "{}\n")
case("absent-key-is-added", lambda: gcd.merge(p) == "added:copyOnSelect")
case("added-value-is-false", lambda: load(p)["copyOnSelect"] is False)

# --- THE ONLY-WHEN-ABSENT INVARIANT. Deleting the helper's `k not in cfg` filter --
# i.e. forcing the value on every start -- reddens this and little else.
p = write("b/c.json", '{"copyOnSelect":true}\n')
case("a-students-own-choice-is-left-alone", lambda: gcd.merge(p) == "unchanged")
case("a-students-own-choice-is-still-true", lambda: load(p)["copyOnSelect"] is True)

# --- the trust-state guard: ~/.claude.json also holds project trust and history --
p = write("c/c.json", '{"projects":{"/p":{"hasTrustDialogAccepted":true}},"numStartups":7}\n')
case("everything-else-survives", lambda: gcd.merge(p) == "added:copyOnSelect")
case("the-trust-state-survives",
     lambda: load(p)["projects"]["/p"]["hasTrustDialogAccepted"] is True
     and load(p)["numStartups"] == 7)

# --- a config it cannot parse is declined, and left exactly as found ----------
p = write("d/c.json", '{"projects":')
raw = open(p, "rb").read()
case("an-unparseable-config-is-declined", lambda: gcd.merge(p) == "declined:unreadable")
case("an-unparseable-config-is-byte-identical", lambda: open(p, "rb").read() == raw)

p = write("e/c.json", "[]\n")
case("a-json-array-is-declined", lambda: gcd.merge(p) == "declined:not-an-object")

# --- mkstemp makes 0600, so without the chmod a 0644 config silently narrows --
p = write("f/c.json", "{}\n", 0o644)
gcd.merge(p)
case("the-file-mode-survives-0644", lambda: stat.S_IMODE(os.stat(p).st_mode) == 0o644)
p = write("g/c.json", "{}\n", 0o600)
gcd.merge(p)
case("the-file-mode-survives-0600", lambda: stat.S_IMODE(os.stat(p).st_mode) == 0o600)

# --- THE TRAP realpath() EXISTS FOR. ~/.claude.json is a symlink into a named
# volume, and rename(2) does not follow a symlink on its destination: without
# realpath() the merge REPLACES THE SYMLINK with a regular file in the writable
# layer, so the volume's copy goes stale and the replacement dies at the next
# --rebuild.
real = write("h/vol/real.json", '{"real":1}\n')
link = os.path.join(ROOT, "h", "link.json")
os.symlink(real, link)
case("a-symlink-argument-reaches-the-real-file",
     lambda: gcd.merge(link) == "added:copyOnSelect")
case("and-leaves-the-symlink-a-symlink", lambda: os.path.islink(link))
case("and-the-real-file-got-the-key", lambda: load(real)["copyOnSelect"] is False)

# --- indent=2 matches what Claude Code writes, so a second start reformats nothing --
p = write("i/c.json", "{}\n")
gcd.merge(p)
raw = open(p, "rb").read()
case("a-second-run-is-a-byte-identical-no-op",
     lambda: gcd.merge(p) == "unchanged" and open(p, "rb").read() == raw)

# --- ATOMICITY, and the failure has to be forced MID-WRITE ---------------------
# A read-only directory does NOT test this: mkstemp fails there before writing a
# byte, while a naive open(path,"w") on a writable file in a read-only directory
# SUCCEEDS. With the failure injected inside the dump, the helper leaves the file
# byte-identical and a truncating implementation leaves it as
# `{\n  "partial": 1,\n  "and then"` -- an unparseable config, which costs the
# student the project trust state and history that file also holds. Measured.
p = write("j/c.json", '{"projects":{"/p":{"hasTrustDialogAccepted":true}}}\n')
raw = open(p, "rb").read()
orig_dump = json.dump


def exploding_dump(obj, fp, **kw):
    fp.write('{\n  "partial": 1,\n  "and then"')
    raise OSError(28, "no space left on device")


json.dump = exploding_dump
try:
    verdict = gcd.merge(p)
except BaseException as e:
    verdict = "RAISED:%s" % type(e).__name__
finally:
    json.dump = orig_dump
case("a-failure-mid-write-is-declined-not-raised", lambda: verdict == "declined:28")
case("and-the-original-survives-a-failed-write", lambda: open(p, "rb").read() == raw)

case("no-temp-file-is-left-behind",
     lambda: not [f for _, _, fs in os.walk(ROOT) for f in fs
                  if f.startswith(".claude.json.new.")])

shutil.rmtree(ROOT, ignore_errors=True)
