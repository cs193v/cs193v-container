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

# UNBUFFERED (-u), or a fuzzer killed without unwinding -- a signal, os._exit -- takes every line
# still in python's buffer with it and is reported as one that produced nothing. Measured: a walk
# that sent its caller SIGTERM in property 3 left $OUT empty (#435).
python3 -u - "$PRIVATE/install-cs193v.sh" "$SEED" "$WORK" > "$OUT" 2>&1 <<'PY'
import errno, hashlib, os, random, re, shutil, subprocess, sys

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

# STDOUT AS PRINTED, NOT STRIPPED (#454). It used to be stripped here, before anything judged it,
# so a walk that padded its digest passed every property that read one -- measured: a leading
# space, a leading or trailing blank line, a trailing space, each 11 pass 0 fail. Every reader of
# stdout below gets it raw, refusal-is-quiet included, so a refusal that prints only a newline now
# counts as printing something. stderr is left stripped, as it was.
def run_verb(d, boot=BOOT):           # -> (rc, stdout, stderr)
    p = subprocess.run(["bash", boot, "--dev-manifest-hash", d],
                       capture_output=True)
    return p.returncode, p.stdout.decode("utf-8", "replace"), \
           p.stderr.decode("utf-8", "replace").strip()

# ONE DIGEST LINE AND NOTHING ELSE, which is the verb's own contract (install-cs193v.sh: "ONE LINE
# ON STDOUT AND NOTHING ELSE") and narrower than what its readers forgive. The verb prints exactly
# what manifest_hash prints, and everything that reads either takes it through `$(...)` --
# release.sh's pin and the tests through the verb, install-cs193v.sh's payload check through
# manifest_hash itself. `$(...)` strips trailing newlines and nothing else, so a leading space or
# blank line, or a trailing space, reaches a comparison against the pin and fails it, while a
# trailing blank line would be forgiven. The contract is what is held here, blank line included;
# only the newline that ends the one line is optional, since `$(...)` makes it so.
DIGEST_LINE = re.compile(r"[0-9a-f]{64}\n?")
def digest_of(printed):               # -> the digest, or None if stdout is not one digest line
    return printed[:64] if DIGEST_LINE.fullmatch(printed) else None

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
# on it, the oracle emitted nothing but a traceback, and mffuzz:the-fuzzer-ran (now
# mffuzz:the-fuzzer-ran-to-the-end) fired -- correctly, since nothing below it had run. The name
# is still worth having: on Linux it is the case that catches a tool which decoded a path instead
# of treating it as bytes.
#
# A REFUSAL OF ANYTHING ELSE STILL RAISES, which is the whole guard and the reason there is no
# numeric floor here. A filesystem that refused the corpus wholesale would be stopped by the very
# first name -- plain.txt is not in this set -- and that arrives as the traceback and the gate
# above, loudly, rather than as a suite that quietly skipped everything and reported green.
MAY_REFUSE = {b"not-utf8-\xff\xfe.txt"}
out("names-may-be-refused", str(len(MAY_REFUSE)))
refused, refused_as_dir = [], []

def fresh(tag):
    d = os.path.join(WORK, tag)
    shutil.rmtree(d, ignore_errors=True)
    os.mkdir(d)
    return d

def as_dirname(name):                 # how property 2 spells a corpus name as a directory
    return name.replace(b"-", b"d")
MAY_REFUSE_AS_DIR = {as_dirname(n): n for n in MAY_REFUSE}

# THE REFUSAL IS ANSWERED HERE IN BOTH ITS FORMS (#454): MAY_REFUSE's name as the file, and as a
# directory in the spelling as_dirname() gives it, which os.makedirs refuses before the file is
# reached. Judged by the component the filesystem actually named in the error, and by which step
# failed -- the file's name only from open(), its directory spelling only from os.makedirs() --
# then recorded under the corpus entry it came from, so names-refused names corpus entries. The
# directory form used to be let through by property 2 and recorded nowhere -- 6 of the 14 refusals
# at the default seed on a Mac, measured.
def plant(d, name, body=b"x\n", sub=None):   # -> True if it landed, False if refused
    base = os.fsencode(d)
    as_dir = True                     # which step failed: each spelling is allowed only at its own
    try:
        if sub is not None:
            base = os.path.join(base, sub)
            os.makedirs(base, exist_ok=True)
        as_dir = False
        with open(os.path.join(base, name), "wb") as fh:
            fh.write(body)
    except OSError as exc:
        what = os.path.basename(os.fsencode(exc.filename)) if exc.filename is not None else None
        allowed = MAY_REFUSE_AS_DIR if as_dir else MAY_REFUSE
        if exc.errno != errno.EILSEQ or what not in allowed:
            raise
        if as_dir:
            refused_as_dir.append(what)
            what = MAY_REFUSE_AS_DIR[what]
        refused.append(what)
        return False
    return True

# ─── the plan, printed before any case runs ────────────────────────────────────
# Every generated loop below counts each case it reaches into `reached`, which is printed as the
# LAST line, and mffuzz:the-fuzzer-ran-to-the-end wants the two to agree (#435). A case skipped by
# design -- the name this filesystem refuses, an empty random tree -- is still reached, so the plan
# is the same on every platform and the skip goes on being reported where it always was.
N_RANDOM, N_MUTATED, N_STABLE = 120, 40, 6
out("cases-planned", str(len(NAMES) + N_RANDOM + N_MUTATED + N_STABLE))
reached = 0

# ─── the judge first: one digest line is a digest, and nothing else is  (#454) ─
# Properties 1, 2, 3 and 5 read the walk's digest through run_verb and digest_of, so the two are
# asked here, before anything trusts them, of a stand-in verb that prints each shape verbatim. The
# same path the real verb takes, which is the point: a strip creeping back into run_verb is caught
# as surely as a digest_of that has been loosened, and both pass every property below on a walk
# that prints its digest correctly. The first two are the ones that must be ACCEPTED, so a judge
# that refused everything does not pass either.
JUDGE = os.path.join(WORK, "judge-verb.sh")
with open(JUDGE, "w") as fh:
    fh.write('cat -- "$2"\n')
H = "0123456789abcdef" * 4
JUDGED = [(H + "\n", True), (H, True),
          ("\n" + H + "\n", False), (H + "\n\n", False), (" " + H + "\n", False),
          (H + " \n", False), (H + "\r\n", False), (H + "\n" + H + "\n", False),
          ("", False), ("\n", False), (H.upper() + "\n", False), (H[:-1] + "\n", False)]
misjudged = []
for k, (text, want) in enumerate(JUDGED):
    f = os.path.join(WORK, "judged%d" % k)
    with open(f, "w") as fh:
        fh.write(text)
    rc, got, _ = run_verb(f, boot=JUDGE)
    if (rc == 0 and digest_of(got) is not None) != want:
        misjudged.append("%r %s" % (text, "refused" if want else "accepted"))
out("judge-misjudged", "; ".join(misjudged))

# ─── property 1: valid input first, which is what stops "refuse everything" passing ──
disagree, nonhex, dirty_err = [], [], []
n_ok = 0
for i, name in enumerate(NAMES):
    reached += 1
    d = fresh("ok%d" % i)
    # THE WHOLE CASE, NOT THE NAME ALONE. A case that ran without its own name would compare the
    # walk against the oracle over a tree holding only the sibling -- green, and proving nothing
    # about the entry it is named for. So it is skipped and n_ok counts what really ran.
    if not plant(d, name, body=bytes([rng.randint(0, 255) for _ in range(rng.randint(0, 40))])):
        continue
    plant(d, b"sibling", sub=b"sub" + (b"dir with space" if i % 3 == 0 else b""))
    rc, printed, err = run_verb(d)
    n_ok += 1
    got = digest_of(printed)
    if rc != 0 or got is None:
        nonhex.append("%r rc=%d out=%r" % (name, rc, printed[:80]))
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
GENERATOR_COLLISIONS = {errno.ENOTDIR, errno.EEXIST, errno.EISDIR}

# EVERY PLANTING ACCOUNTED FOR (#454): it landed, collided, or plant() put it in `refused` -- the
# list behind the plantings-the-filesystem-refused record. A planting let through without being
# any of those is a refusal nobody recorded, which is what the directory form of #305's was until
# #454, and what every refusal was under the `except OSError: pass` that stood here before #445.
rand_disagree = []
n_rand_skipped = 0
p2_asked = p2_landed = p2_collided = 0
p2_refused_from = len(refused)
for i in range(N_RANDOM):
    reached += 1
    d = fresh("rand%d" % i)
    n_planted = 0
    for _ in range(rng.randint(1, 6)):
        p2_asked += 1
        name = rng.choice(NAMES)
        sub = None
        if rng.random() < 0.4:
            sub = b"/".join(as_dirname(rng.choice(NAMES)) for _ in range(rng.randint(1, 2)))
        # THE except IS THE GENERATOR'S, NOT THE FILESYSTEM'S, and the two must not be merged.
        # sub is built from corpus names, so this loop asks for a file to be a directory or the
        # reverse, and gets ENOTDIR, EEXIST or EISDIR -- on every platform, not just a Mac.
        # plant() handles the filesystem refusing a NAME (#305) through its return value; this
        # handles the generator asking the impossible. Narrowing this to EILSEQ was tried and
        # crashes on rand0.
        #
        # AND NOTHING ELSE (#445), which it used to swallow too. #305's refusal, as a file or as a
        # directory, is plant()'s to answer (#454); any other refusal -- EILSEQ on another name,
        # EACCES, EINVAL -- raises to the gate, as plant()'s do. Measured: an EACCES on every name
        # here left 0 random trees tested and the suite green.
        try:
            if plant(d, name, body=bytes([rng.randint(0, 255) for _ in range(rng.randint(0, 60))]), sub=sub):
                n_planted += 1
        except OSError as exc:
            if exc.errno not in GENERATOR_COLLISIONS:
                raise
            p2_collided += 1
    p2_landed += n_planted
    # AN EMPTY TREE IS NOT A SUBJECT. --dev-manifest-hash refuses one ("the course files are
    # empty", rc 1) and it is right to, so judging it here would count a correct refusal as a
    # disagreement. Reachable two ways: every planting collided, which any platform can do at
    # some seed, or the tree drew only a name this filesystem refuses, as a file or a directory --
    # which is tree 27 at the default seed on a Mac, and is what turned #305 into a red here
    # instead of a dead suite.
    if n_planted == 0:
        n_rand_skipped += 1
        continue
    rc, printed, _ = run_verb(d)
    got = digest_of(printed)
    if rc != 0 or got is None:
        rand_disagree.append("tree %d did not hash: rc=%d out=%r" % (i, rc, printed[:80]))
        continue
    if got != oracle(d):
        rand_disagree.append("tree %d: shell=%s oracle=%s" % (i, got, oracle(d)))
out("cases-random", str(N_RANDOM - n_rand_skipped))
out("cases-random-skipped", str(n_rand_skipped))
out("random-disagree", "; ".join(rand_disagree[:4]))
p2_unaccounted = p2_asked - p2_landed - p2_collided - (len(refused) - p2_refused_from)
out("plantings-unaccounted", "" if p2_unaccounted == 0 else
    "%d of the %d plantings property 2 asked for neither landed, collided nor were recorded as refused"
    % (p2_unaccounted, p2_asked))

# ─── property 3: every single-point mutation moves the digest ─────────────────
# THE HALF THAT MATTERS MOST. A walk that agreed with the oracle but ignored, say, the last file
# in a directory would pass everything above -- both sides would ignore it. Sensitivity is what
# says the digest is a function of the WHOLE tree.
#
# AND A REFUSAL IS A FAILURE, NAMED FOR ITS MUTATION. Every mutation below leaves a valid tree, so
# a walk that refuses one is rejecting what it must accept. This property used to read "moves the
# digest, or is refused", and passed on exactly that -- measured: a walk refusing any tree with an
# empty directory in it stayed green (#445). So does a walk that says nothing and exits 0, which
# is why both answers must be digests.
MUTATIONS = ("flip a content byte", "add a file", "remove a file", "rename a file",
             "add an empty directory")
insensitive = []
for i in range(N_MUTATED):
    reached += 1
    d = fresh("mut%d" % i)
    for k in range(3):
        plant(d, b"file%d" % k, body=b"body %d\n" % k, sub=(b"sub" if k == 2 else None))
    rc0, printed0, err0 = run_verb(d)
    base = digest_of(printed0)
    if rc0 != 0 or base is None:
        insensitive.append("base tree %d did not hash (rc=%d, out=%r): %s" % (i, rc0, printed0[:80], err0[:80]))
        continue
    op = i % len(MUTATIONS)
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
    rc1, printed1, err1 = run_verb(d)
    after = digest_of(printed1)
    if rc1 != 0 or after is None:
        insensitive.append("tree %d, %s: the mutated tree did not hash (rc=%d, out=%r): %s"
                           % (i, MUTATIONS[op], rc1, printed1[:80], err1[:80]))
    elif after == base:
        insensitive.append("tree %d, %s: digest unchanged" % (i, MUTATIONS[op]))
out("cases-mutated", str(N_MUTATED))
out("insensitive", "; ".join(insensitive[:4]))

# ─── property 4: what the format refuses, it refuses ──────────────────────────
accepted = []
d = fresh("neg-symlink"); plant(d, b"real"); os.symlink("real", os.path.join(d, "link"))
rc, got, _ = run_verb(d)
if rc == 0: accepted.append("a symlink was accepted: %r" % got)
d = fresh("neg-dirlink"); plant(d, b"real", sub=b"sub")
os.symlink("sub", os.path.join(d, "sublink"))
rc, got, _ = run_verb(d)
if rc == 0: accepted.append("a symlink to a directory was accepted: %r" % got)
d = fresh("neg-newline"); plant(d, b"we\nird")
rc, got, _ = run_verb(d)
if rc == 0: accepted.append("a newline in a name was accepted: %r" % got)
d = fresh("neg-fifo"); plant(d, b"real"); os.mkfifo(os.path.join(d, "pipe"))
rc, got, _ = run_verb(d)
if rc == 0: accepted.append("a fifo was accepted: %r" % got)
d = fresh("neg-empty")
rc, got, _ = run_verb(d)
if rc == 0: accepted.append("an empty tree was accepted: %r" % got)
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
for i in range(N_STABLE):
    reached += 1
    d = fresh("det%d" % i)
    # NO except HERE (#445). Five distinct names in one flat directory raise no collision -- `A`
    # and `a` on a case-insensitive filesystem merely become one file -- and the one refusal the
    # corpus allows is plant()'s to answer, by returning False. So the `except OSError: pass` that
    # stood here could only ever swallow a refusal outside MAY_REFUSE. Measured: on six seeds it
    # swallowed nothing at all.
    for name in rng.sample(NAMES, 5):
        plant(d, name)
    # A DIGEST BOTH TIMES, not merely the same answer twice: two refusals print the same nothing,
    # and that passed here as stable -- measured, a walk refusing every tree this property builds
    # stayed green (#445).
    ra, pa, ea = run_verb(d)
    rb, pb, eb = run_verb(d)
    a, b = digest_of(pa), digest_of(pb)
    if ra != 0 or rb != 0 or a is None or b is None:
        unstable.append("tree %d did not hash: rc=%d %r, then rc=%d %r: %s"
                        % (i, ra, pa[:80], rb, pb[:80], (ea or eb)[:80]))
    elif a != b:
        unstable.append("tree %d: %s then %s" % (i, a, b))
out("unstable", "; ".join(unstable[:4]))

out("plantings-refused", str(len(refused)))
out("plantings-refused-as-dir", str(len(refused_as_dir)))
out("names-refused", b" ".join(sorted(set(refused))).decode("utf-8", "replace"))

# ─── THE LAST LINE: how many cases the loops above actually reached ────────────
# Counted case by case, unlike cases-random and cases-mutated, which a loop cut short still printed
# in full (measured, #435). And last, so it is missing if anything above died at all.
out("cases-reached", str(reached))
PY
FUZZ_RC=$?

fz() { awk -F'\t' -v k="$1" '$1==k{print $2}' "$OUT"; }

# ─── the oracle ran, and ran to its last line ──────────────────────────────────
# FIRST AND ON ITS OWN, the rule 19-shortlink-fuzz.sh states: every property below is satisfied by
# a run that produced nothing, so a python traceback would otherwise read as a clean pass.
#
# AND AT THE END, NOT PARTWAY. This used to be mffuzz:the-fuzzer-ran, which asked only whether
# cases-valid had been printed -- after property 1 -- and never looked at python's exit status. A
# run that died after it passed every property from 2 on, on keys it never printed (#435). Measured
# both ways: a sys.exit(0) after property 1, and a walk that left the oracle a dangling symlink in
# property 2, each 12 pass 0 fail. Against the fuzzer's own plan rather than a literal, so a name
# added to the corpus reaches every-name-is-in-the-corpus below instead of stopping here.
#
# NO except AROUND A CASE, unlike 19-shortlink-fuzz.sh's, and on purpose: the walk runs in a
# subprocess, so what it does comes back as a status each property already judges. What raises in
# here uncaught -- plant()'s re-raise, which properties 2 and 5 no longer swallow (#445), or the
# oracle on a tree the walk left it unable to read -- ends the run, and this gate is where that
# belongs: the traceback it prints names the path.
planned="$(fz cases-planned)"
reached="$(fz cases-reached)"
if [ "$FUZZ_RC" != 0 ] || [ -z "$reached" ] || [ "$reached" != "$planned" ]; then
    fail "mffuzz:the-fuzzer-ran-to-the-end" \
"python3 exited $FUZZ_RC, and its last line counted '$reached' of the '$planned' cases it planned,
so nothing below is read from this run.
$(cat "$OUT")"
    exit 1
fi
pass "mffuzz:the-fuzzer-ran-to-the-end"

assert_eq "mffuzz:only-one-digest-line-is-a-digest" "" "$(fz judge-misjudged)"
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
#
# AND IT COUNTS A REFUSAL AS A DIRECTORY TOO (#454), saying how many, so a diff can see them; the
# assertion beneath is what keeps a planting from going missing from it again.
record "mffuzz:plantings-the-filesystem-refused" \
       "$(fz plantings-refused) across [$(fz names-refused)] ($(fz plantings-refused-as-dir) of them as a directory), $(fz cases-random-skipped) random trees left empty"
assert_eq "mffuzz:every-refused-planting-is-recorded" "" "$(fz plantings-unaccounted)"
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
