#!/usr/bin/env bash
# TIER: unit
#
# install-cs193v.sh's manifest walk, fuzzed against an independent oracle. No podman, no
# container, no network (#232).
#
# WHY THIS WALK IS WORTH FUZZING. It decides whether a student's course files are the release, and
# it decides that by turning a directory tree into one text and hashing it. Everything that can go
# wrong with that is a NAME: a space word-splits, a leading dash becomes an option, a bare `-`
# becomes stdin, a locale reorders two files, a non-UTF-8 byte confuses a tool. Each of those
# yields a DIFFERENT digest rather than an error -- so the failure is every install on every
# platform refusing, with nothing in the message pointing at a filename.
#
# AND THE ORACLE IS WRITTEN FROM THE SPEC, NOT FROM THE SHELL. The format is stated in prose in
# install-cs193v.sh's own header, and this file implements that prose in Python: one line per
# entry, `d  <path>` and `f  <sha256>  <path>`, paths relative with no `./`, bytewise sort,
# trailing newline. Transliterating the shell would be the same bug written twice, which is the
# one way a differential test can agree and mean nothing. 25-installer.sh's manifest:* vectors are
# the other half of this: frozen constants, which is what catches the FORMAT moving. A fuzzer
# cannot catch that -- both sides would move together.
#
# DETERMINISTIC, for the reason 17-portparse-fuzz.sh gives: this suite's results are compared
# across instances and machines, so the generator is seeded and the seed is printed on failure.
#
# THE VERB, NOT A COPY. Every case shells out to `install-cs193v.sh --dev-manifest-hash`, which is
# the code a student's machine runs. installer-door:no-other-way-to-start-it exempts that verb by
# name, because it dispatches above the temp directory and every arm exits.

set -u
. "$(dirname -- "$0")/lib/assert.sh"

cd "$REPO" || exit 1

require_cmd python3 "the oracle this suite compares the shell walk against is written in python"

SEED="${CS193V_FUZZ_SEED:-20260917}"
OUT="$(mktemp "${TMPDIR:-/tmp}/cs193v-mffuzz.XXXXXX")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cs193v-mfwork.$$.XXXXXX")"
trap 'rm -f "$OUT"; rm -rf "$WORK"' EXIT

python3 - "$PRIVATE/install-cs193v.sh" "$SEED" "$WORK" > "$OUT" 2>&1 <<'PY'
import errno, hashlib, os, random, shutil, subprocess, sys

BOOT, SEED, WORK = sys.argv[1], int(sys.argv[2]), sys.argv[3]
rng = random.Random(SEED)

def out(k, v):
    print("%s\t%s" % (k, v))

# ─── the oracle, from install-cs193v.sh's stated format and nothing else ───────
# BYTES THROUGHOUT. A path is not text -- it is a sequence of bytes that need not be valid UTF-8 --
# and `LC_ALL=C sort` compares bytes. Sorting `str` under any locale would be a different order,
# which is precisely the bug this suite exists to notice.
def oracle(root):
    lines = []
    rootb = os.fsencode(root)
    for dirpath, dirnames, filenames in os.walk(rootb):
        for name in dirnames:
            full = os.path.join(dirpath, name)
            lines.append(b"d  " + os.path.relpath(full, rootb))
        for name in filenames:
            full = os.path.join(dirpath, name)
            with open(full, "rb") as fh:
                digest = hashlib.sha256(fh.read()).hexdigest().encode()
            lines.append(b"f  " + digest + b"  " + os.path.relpath(full, rootb))
    lines.sort()
    return hashlib.sha256(b"".join(l + b"\n" for l in lines)).hexdigest()

def run_verb(d):                      # -> (rc, stdout, stderr)
    p = subprocess.run(["bash", BOOT, "--dev-manifest-hash", d],
                       capture_output=True)
    return p.returncode, p.stdout.decode("utf-8", "replace").strip(), \
           p.stderr.decode("utf-8", "replace").strip()

# ─── the name corpus: every shape that has ever broken a shell walk ───────────
# BYTES, INCLUDING ONE THAT IS NOT VALID UTF-8. surrogateescape is how Python carries such a name,
# and a tool that decoded it would produce a different digest than one that did not.
NAMES = [
    b"plain.txt",
    b"a file with spaces.txt",
    b"  leading-and-trailing  ",
    b"-",                              # bare dash: stdin to anything that does not redirect
    b"-n", b"-e", b"--", b"-rf",       # option injection into printf, find, sort
    b"'single'", b'"double"', b"back`tick`", b"dollar$VAR", b"${BRACE}",
    b"star*", b"question?", b"brack[et]", b"brace{s}", b"pipe|", b"semi;colon",
    b"amp&ersand", b"less<than", b"more>than", b"paren(theses)", b"hash#mark",
    b"tab\there", b"cr\rhere",         # CR is legal in a name and must survive
    b"caf\xc3\xa9.txt",                # UTF-8
    b"not-utf8-\xff\xfe.txt",          # deliberately invalid
    b"A", b"_", b"a",                  # order differently under C than under en_US
    b"deadbeefcafe0123456789abcdef0123456789abcdef0123456789abcdef0123",
    b"." * 3 + b"leading-dots",
    b".hidden",
    b"x" * 200,
    b"\xe2\x80\x8bzero-width",
]
out("name-corpus", str(len(NAMES)))

# ─── ...and the one entry a conforming filesystem is allowed to refuse  (#305) ─
# DECLARED, NOT A WILDCARD, and that is what keeps this from becoming a hole. APFS requires
# filenames to be valid UTF-8 and refuses this one with EILSEQ, so on every Mac property 1 died
# on it, the oracle emitted nothing but a traceback, and mffuzz:the-fuzzer-ran fired -- correctly,
# since nothing below it had run. The name is still worth having: on Linux it is the case that
# catches a tool which decoded a path instead of treating it as bytes.
#
# A REFUSAL OF ANYTHING ELSE STILL RAISES, which is the whole guard and the reason there is no
# numeric floor here. A filesystem that refused the corpus wholesale would be stopped by the very
# first name -- plain.txt is not in this set -- and that arrives as the traceback and the gate
# above, loudly, rather than as a suite that quietly skipped everything and reported green.
MAY_REFUSE = {b"not-utf8-\xff\xfe.txt"}
out("names-may-be-refused", str(len(MAY_REFUSE)))
refused = []

def fresh(tag):
    d = os.path.join(WORK, tag)
    shutil.rmtree(d, ignore_errors=True)
    os.mkdir(d)
    return d

def plant(d, name, body=b"x\n", sub=None):   # -> True if it landed, False if refused
    base = os.fsencode(d)
    if sub is not None:
        base = os.path.join(base, sub)
        os.makedirs(base, exist_ok=True)
    try:
        with open(os.path.join(base, name), "wb") as fh:
            fh.write(body)
    except OSError as exc:
        if exc.errno != errno.EILSEQ or name not in MAY_REFUSE:
            raise
        refused.append(name)
        return False
    return True

# ─── property 1: valid input first, which is what stops "refuse everything" passing ──
disagree, nonhex, dirty_err = [], [], []
n_ok = 0
for i, name in enumerate(NAMES):
    d = fresh("ok%d" % i)
    # THE WHOLE CASE, NOT THE NAME ALONE. A case that ran without its own name would compare the
    # walk against the oracle over a tree holding only the sibling -- green, and proving nothing
    # about the entry it is named for. So it is skipped and n_ok counts what really ran.
    if not plant(d, name, body=bytes([rng.randint(0, 255) for _ in range(rng.randint(0, 40))])):
        continue
    plant(d, b"sibling", sub=b"sub" + (b"dir with space" if i % 3 == 0 else b""))
    rc, got, err = run_verb(d)
    n_ok += 1
    if rc != 0 or len(got) != 64 or any(c not in "0123456789abcdef" for c in got):
        nonhex.append("%r rc=%d out=%r" % (name, rc, got[:80]))
        continue
    if err:
        dirty_err.append("%r: %s" % (name, err[:80]))
    want = oracle(d)
    if got != want:
        disagree.append("%r shell=%s oracle=%s" % (name, got, want))
out("cases-valid", str(n_ok))
out("nonhex", "; ".join(nonhex[:4]))
out("disagree", "; ".join(disagree[:4]))
out("stderr-on-success", "; ".join(dirty_err[:4]))

# ─── property 2: random trees, same comparison ────────────────────────────────
rand_disagree = []
n_rand_skipped = 0
for i in range(120):
    d = fresh("rand%d" % i)
    n_planted = 0
    for _ in range(rng.randint(1, 6)):
        name = rng.choice(NAMES)
        sub = None
        if rng.random() < 0.4:
            sub = b"/".join(rng.choice(NAMES) for _ in range(rng.randint(1, 2)))
            sub = sub.replace(b"-", b"d")          # keep dir names off the dash cases
        # THE except IS THE GENERATOR'S, NOT THE FILESYSTEM'S, and the two must not be merged.
        # sub is built from corpus names, so this loop asks for a file to be a directory and gets
        # ENOTDIR -- on every platform, not just a Mac. plant() handles the filesystem refusing a
        # NAME (#305) through its return value; this handles the generator asking the impossible.
        # Narrowing this to EILSEQ was tried and crashes on rand0.
        try:
            if plant(d, name, body=bytes([rng.randint(0, 255) for _ in range(rng.randint(0, 60))]), sub=sub):
                n_planted += 1
        except OSError:
            pass
    # AN EMPTY TREE IS NOT A SUBJECT. --dev-manifest-hash refuses one ("the course files are
    # empty", rc 1) and it is right to, so judging it here would count a correct refusal as a
    # disagreement. Reachable two ways: every planting ENOTDIR'd, which any platform can do at
    # some seed, or the tree drew only a name this filesystem refuses -- which is tree 27 at the
    # default seed on a Mac, and is what turned #305 into a red here instead of a dead suite.
    if n_planted == 0:
        n_rand_skipped += 1
        continue
    rc, got, _ = run_verb(d)
    if rc != 0:
        rand_disagree.append("rc=%d on tree %d" % (rc, i))
        continue
    if got != oracle(d):
        rand_disagree.append("tree %d: shell=%s oracle=%s" % (i, got, oracle(d)))
out("cases-random", str(120 - n_rand_skipped))
out("cases-random-skipped", str(n_rand_skipped))
out("random-disagree", "; ".join(rand_disagree[:4]))

# ─── property 3: every single-point mutation moves the digest, or is refused ──
# THE HALF THAT MATTERS MOST. A walk that agreed with the oracle but ignored, say, the last file
# in a directory would pass everything above -- both sides would ignore it. Sensitivity is what
# says the digest is a function of the WHOLE tree.
insensitive = []
for i in range(40):
    d = fresh("mut%d" % i)
    for k in range(3):
        plant(d, b"file%d" % k, body=b"body %d\n" % k, sub=(b"sub" if k == 2 else None))
    rc0, base, _ = run_verb(d)
    if rc0 != 0:
        insensitive.append("base tree %d did not hash" % i)
        continue
    op = i % 5
    if op == 0:                                   # flip a content byte
        with open(os.path.join(d, "file0"), "r+b") as fh:
            fh.write(b"B")
    elif op == 1:                                 # add a file
        plant(d, b"extra", body=b"e\n")
    elif op == 2:                                 # remove a file
        os.unlink(os.path.join(d, "file1"))
    elif op == 3:                                 # rename, content unchanged
        os.rename(os.path.join(d, "file0"), os.path.join(d, "file0-renamed"))
    else:                                         # add a directory, no files in it
        os.mkdir(os.path.join(d, "newdir"))
    rc1, after, _ = run_verb(d)
    if rc1 == 0 and after == base:
        insensitive.append("tree %d op %d: digest unchanged" % (i, op))
out("cases-mutated", "40")
out("insensitive", "; ".join(insensitive[:4]))

# ─── property 4: what the format refuses, it refuses ──────────────────────────
accepted = []
d = fresh("neg-symlink"); plant(d, b"real"); os.symlink("real", os.path.join(d, "link"))
rc, got, _ = run_verb(d)
if rc == 0: accepted.append("a symlink was accepted: %s" % got)
d = fresh("neg-dirlink"); plant(d, b"real", sub=b"sub")
os.symlink("sub", os.path.join(d, "sublink"))
rc, got, _ = run_verb(d)
if rc == 0: accepted.append("a symlink to a directory was accepted: %s" % got)
d = fresh("neg-newline"); plant(d, b"we\nird")
rc, got, _ = run_verb(d)
if rc == 0: accepted.append("a newline in a name was accepted: %s" % got)
d = fresh("neg-fifo"); plant(d, b"real"); os.mkfifo(os.path.join(d, "pipe"))
rc, got, _ = run_verb(d)
if rc == 0: accepted.append("a fifo was accepted: %s" % got)
d = fresh("neg-empty")
rc, got, _ = run_verb(d)
if rc == 0: accepted.append("an empty tree was accepted: %s" % got)
out("accepted-what-it-refuses", "; ".join(accepted))

# AND A REFUSAL PRINTS NOTHING ON STDOUT, which is what makes `$(...)` around the verb safe: a
# refusal that printed a partial digest would be captured as one by every caller.
noisy = []
for tag, build in (("symlink", lambda d: (plant(d, b"real"), os.symlink("real", os.path.join(d, "l")))),
                   ("newline", lambda d: plant(d, b"we\nird")),
                   ("empty",   lambda d: None)):
    d = fresh("quiet-" + tag)
    build(d)
    rc, got, err = run_verb(d)
    if got:
        noisy.append("%s printed %r" % (tag, got[:40]))
    if rc == 0 or not err:
        noisy.append("%s rc=%d err=%r" % (tag, rc, err[:40]))
out("refusal-is-quiet", "; ".join(noisy[:4]))

# ─── property 5: the same tree twice is the same digest ───────────────────────
unstable = []
for i in range(6):
    d = fresh("det%d" % i)
    for name in rng.sample(NAMES, 5):
        try:
            plant(d, name)
        except OSError:
            pass
    a = run_verb(d)[1]
    b = run_verb(d)[1]
    if a != b:
        unstable.append("tree %d: %s then %s" % (i, a, b))
out("unstable", "; ".join(unstable[:4]))

out("plantings-refused", str(len(refused)))
out("names-refused", b" ".join(sorted(set(refused))).decode("utf-8", "replace"))
PY

fz() { awk -F'\t' -v k="$1" '$1==k{print $2}' "$OUT"; }

# ─── the oracle ran at all ─────────────────────────────────────────────────────
# FIRST AND ON ITS OWN, the rule 19-shortlink-fuzz.sh states: every property below is satisfied by
# a run that produced nothing, so a python traceback would otherwise read as a clean pass.
if [ -z "$(fz cases-valid)" ]; then
    fail "mffuzz:the-fuzzer-ran" \
"the oracle produced no results, so nothing below tested anything.
$(cat "$OUT")"
    exit 1
fi
pass "mffuzz:the-fuzzer-ran"

assert_eq "mffuzz:every-valid-tree-hashes"        "" "$(fz nonhex)"
assert_eq "mffuzz:the-walk-agrees-with-the-oracle" "" "$(fz disagree)"
assert_eq "mffuzz:success-writes-no-stderr"       "" "$(fz stderr-on-success)"
assert_eq "mffuzz:random-trees-agree"             "" "$(fz random-disagree)"
assert_eq "mffuzz:every-mutation-moves-the-digest" "" "$(fz insensitive)"
assert_eq "mffuzz:it-refuses-what-it-says-it-refuses" "" "$(fz accepted-what-it-refuses)"
assert_eq "mffuzz:a-refusal-prints-no-digest"     "" "$(fz refusal-is-quiet)"
assert_eq "mffuzz:the-same-tree-hashes-the-same"  "" "$(fz unstable)"
record "mffuzz:cases-run" \
       "$(fz cases-valid) named + $(fz cases-random) random + $(fz cases-mutated) mutated (seed $SEED)"

# ─── and what this filesystem would not let us ask  (#305) ────────────────────
# A SKIP RATHER THAN SILENCE, the shape 12-run-timeout.sh uses for a platform it cannot measure
# on: the corpus entry that is not valid UTF-8 cannot exist on APFS, so on a Mac one name is
# never put to the walk and saying so is the difference between "not applicable here" and
# "quietly stopped testing". On Linux nothing is refused and this is a plain pass.
#
# THE record IS THE DURABLE HALF, not decoration: skip() passes only its NAME to _emit
# (lib/assert.sh:86), so the reason reaches the screen and never $CS193V_RESULTS. Without this
# line a diff of two runs could not see the skipped set change.
record "mffuzz:plantings-the-filesystem-refused" \
       "$(fz plantings-refused) across [$(fz names-refused)], $(fz cases-random-skipped) random trees left empty"
if [ -n "$(fz names-refused)" ]; then
    skip "mffuzz:every-name-in-the-corpus-was-planted" \
         "this filesystem refuses $(fz names-refused) -- APFS requires valid UTF-8 in a filename (EILSEQ), so that entry cannot be put to the walk here"
else
    pass "mffuzz:every-name-in-the-corpus-was-planted"
fi

# A LITERAL, the same device as the corpus count below: the tolerated set is the ONLY thing
# standing between "one name this filesystem cannot hold" and "a filesystem that refuses
# everything", since a refusal outside it re-raises and takes the oracle down. Growing it must
# make somebody come and look.
assert_eq "mffuzz:only-one-name-may-be-refused" "1" "$(fz names-may-be-refused)"

# A LITERAL, so adding a name to the corpus makes you come and look at this line -- the device
# 17-portparse-fuzz.sh uses, for the reason it gives: the corpus is the part that silently shrinks.
assert_eq "mffuzz:every-name-is-in-the-corpus" "36" "$(fz name-corpus)"
