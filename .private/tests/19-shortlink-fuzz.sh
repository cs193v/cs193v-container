#!/usr/bin/env bash
# TIER: unit
#
# shortlink's reader of /tmp/cs193v-volatile/ports, fuzzed. No podman, no container, no network.
#
# WHY THIS IS A PARSER WORTH FUZZING AT ALL, when the file it reads is written by code we also
# wrote: shortlink decides from it whether to print a SHORT url or the long one, and getting that
# wrong is the failure mode #67 exists to prevent. A reader that says "up" about a port that is
# not forwarded hands a student a link their browser cannot reach, and the symptom -- connection
# refused, from a URL that reads as perfectly ordinary -- arrives with nothing pointing back here.
# The file is also the one piece of state that survives a supervisor crash, so a truncated or
# half-written copy is reachable in normal operation rather than only under attack.
#
# WRITTEN BEFORE THE PARSER, deliberately, which is the rule this project applies to every parser
# that takes real input: the fuzzer states the contract before there is an implementation to shape
# it around. Run against nothing it fails on the existence check below, loudly, and that is the
# intended first result.
#
# A PURE FUNCTION, not the script. port_verdict(text, port) takes the file's CONTENTS, so the
# fuzzer never touches a filesystem and runs thousands of cases per second. That is a design
# constraint on shortlink, not a convenience here.
#
# DETERMINISTIC, for the reason 17-portparse-fuzz.sh gives: this suite's results are compared
# across instances and machines, so the generator is seeded and the seed is printed on failure.

set -u
. "$(dirname -- "$0")/lib/assert.sh"

cd "$REPO" || exit 1

SEED="${CS193V_FUZZ_SEED:-20260821}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cs193v-slfuzz.XXXXXX")"
OUT="$WORK/out"
CANARY="$WORK/canary"
trap 'rm -rf "$WORK"' EXIT

python3 - "$PRIVATE/files/shortlink" "$SEED" "$CANARY" > "$OUT" 2>&1 <<'PY'
import importlib.machinery, importlib.util, io, os, random, shlex, sys, traceback

PATH, SEED, CANARY = sys.argv[1], int(sys.argv[2]), sys.argv[3]

loader = importlib.machinery.SourceFileLoader("shortlink_under_test", PATH)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

def out(k, v):
    print("%s\t%s" % (k, v))

if not hasattr(mod, "port_verdict"):
    out("exists", "no")
    sys.exit(0)
out("exists", "yes")

verdict = mod.port_verdict
VOCAB = getattr(mod, "VERDICTS", None)
out("vocab", "yes" if VOCAB else "no")
VOCAB = set(VOCAB or ())

# ─── an INDEPENDENT oracle for soundness ───────────────────────────────────────
# Deliberately not a second copy of the parser: it answers only the one question the soundness
# property needs -- is there a well-formed `up<TAB><port>` row -- in the most literal way possible,
# so agreeing with it means something.
def really_up(text, port):
    for line in text.split("\n"):
        f = line.split("\t")
        if len(f) >= 2 and f[0] == "up" and f[1] == str(port):
            return True
    return False

GOOD = ("state\thealthy\n"
        "floor\t1024\n"
        "up\t3000\tlo\n"
        "up\t41573\tlo\n"
        "refused\t8080\tbusy\n"
        "refused\t9000\tv6lo\n"
        "refused\t80\tbelow-floor\n"
        "refused\t5900\tcapped\n")

# ─── property 7 first: valid input is still read correctly ─────────────────────
# The property fuzzers usually omit, and the one that stops "reject everything" from passing.
known = [(3000, "up"), (41573, "up"), (8080, "busy"), (9000, "v6lo"),
         (80, "below-floor"), (5900, "capped"), (1234, None)]
bad_known = [x for x in known if verdict(GOOD, x[0]) != x[1]]
out("known-good", ";".join("%s->%r want %r" % (p, verdict(GOOD, p), w) for p, w in bad_known))

# ─── the hostile corpus, which is also the mutator's seed material ─────────────
# THE CANARY, aimed into this run's own scratch directory (#395), in BOTH places a reason lives:
# the text of a `reason` row, which follows a state that is not healthy, and the third field of a
# `refused` row, which port_verdict itself reads as `reason`. It used to be the first alone, aimed
# at /tmp/CANARY, and nothing ever looked -- measured: a port_verdict that os.system'd either field
# passed every check here, and the second never reached the payload at all. This covers
# port_verdict only; doctor reads `reason` rows too, and nothing here drives it.
# slfuzz:nothing-in-the-input-is-run is the look.
CANARY_CASE = ("state\tbroken\n"
               "reason\t$(touch {0})\n"
               "refused\t3000\t$(touch {0})\n").format(shlex.quote(CANARY))
HOSTILE = [
    "", "\n", "\t", "\0", "up", "up\t", "up\t3000", "up\t3000\t",
    "up\t3000\tlo\nup\t3000\tany\n",
    "up\t03000\tlo\n",                       # non-canonical: must NOT answer for 3000
    "up\t3000x\tlo\n", "up\t 3000\tlo\n", "up\t3000 \tlo\n",
    "up\t-3000\tlo\n", "up\t+3000\tlo\n", "up\t0x0BB8\tlo\n", "up\t3e3\tlo\n",
    "up\t99999999999999999999\tlo\n",
    "refused\t3000\t\n", "refused\t3000\tnot-a-reason\n", "refused\t3000\tbusy\textra\n",
    "UP\t3000\tlo\n", " up\t3000\tlo\n", "up 3000 lo\n",
    "up\t3000\tlo\r\n",                      # CR must not become part of the class
    CANARY_CASE,
    "up\t3000\t`id`\n", "up\t3000\t${IFS}\n",
    "state\t" + "A" * 100000 + "\n",         # one enormous line
    "up\t3000\tlo\n" * 5000,                 # a huge file
    "\n" * 10000,
    "up\t3000\tlo",                          # no trailing newline
    "\x1b[2Jup\t3000\tlo\n",                 # ANSI, in case a verdict is ever printed raw
]
out("hostile-cases", str(len(HOSTILE)))

def mutate(rng, s):
    b = bytearray(s.encode("utf-8", "surrogateescape"))
    for _ in range(rng.randint(1, 6)):
        if not b:
            b = bytearray(b"up\t3000\tlo\n")
        op, i = rng.randint(0, 4), rng.randrange(len(b))
        if op == 0:   b[i] ^= 1 << rng.randint(0, 7)
        elif op == 1: del b[i]
        elif op == 2: b.insert(i, rng.randint(0, 255))
        elif op == 3: b[i:i] = b[i:i + rng.randint(1, 8)]
        else:         del b[i:]
    return b.decode("utf-8", "replace")

# EVERY HOSTILE CASE BUT THE CANARY. Its bytes name a scratch path whose length varies by machine,
# and mutate() draws its offsets from the length, so as seed material it would give every machine
# a different corpus under the same printed seed. And mutated copies of a shell payload are what a
# broken reader runs: against the old corpus they left /tmp/CANAR], /tmp/CANARYY and a third
# stray beside /tmp/CANARY, none of them inside anything a trap removes.
SEEDS = [GOOD] + [h for h in HOSTILE if h != CANARY_CASE]
rng = random.Random(SEED)
cases = list(HOSTILE)
for _ in range(4000):
    seed_s = rng.choice(SEEDS)
    cases.append(mutate(rng, seed_s))
for _ in range(1000):
    cases.append("".join(chr(rng.randint(0, 255)) for _ in range(rng.randint(0, 200))))

PORTS = [3000, 1, 65535, 0, -1, 99999999999999999999, 8080]

raised, bad_vocab, unsound = [], [], []
err = io.StringIO()
real_err, sys.stderr = sys.stderr, err
try:
    for c in cases:
        for p in PORTS:
            try:
                v = verdict(c, p)
            except Exception:
                raised.append("%r/%s: %s" % (c[:40], p, traceback.format_exc(0).strip()))
                continue
            if v is not None and (not isinstance(v, str) or (VOCAB and v not in VOCAB)):
                bad_vocab.append("%r/%s -> %r" % (c[:40], p, v))
            if v == "up" and not really_up(c, p):
                unsound.append("%r/%s claimed up" % (c[:40], p))
finally:
    sys.stderr = real_err

out("cases", str(len(cases) * len(PORTS)))
out("raised", "; ".join(raised[:3]))
out("bad-vocab", "; ".join(bad_vocab[:3]))
out("unsound", "; ".join(unsound[:3]))
out("stderr", err.getvalue().strip().replace("\n", " ")[:300])

# ─── the text need not be text ─────────────────────────────────────────────────
# Found by mutation testing: removing the isinstance guard broke nothing this suite could see,
# because every case above hands in a str. A caller that reads the file as bytes, or passes the
# None that read_ports_file returns when there is no file, must get an answer rather than a
# traceback -- that None path is the ordinary "no tunnel" case, not an exotic one.
nonstr = []
for t in [None, b"up\t3000\tlo\n", 3000, ["up", "3000"], {"up": 3000}, object()]:
    try:
        v = verdict(t, 3000)
        if v is not None:
            nonstr.append("%r -> %r" % (t, v))
    except Exception:
        nonstr.append("%r raised" % (t,))
out("nonstr-text", "; ".join(nonstr[:3]))

# ─── only a canonical decimal port is answered for ─────────────────────────────
# Also found by mutation testing: dropping the canonicality gate changed no observable behaviour,
# because nothing asked. It is asked now. The file's writer emits `3000` and never `03000`, so a
# row that spells it any other way is not a row about port 3000 -- and a reader that shrugs and
# matches it is the octal-port bug from 17-portparse-fuzz.sh wearing different clothes.
noncanon = []
for p in ["03000", " 3000", "3000 ", "3000\n", "+3000", "\u0663\u0660\u0660\u0660", "3_000"]:
    text = "up\t%s\tlo\n" % p
    if verdict(text, p) is not None:
        noncanon.append("%r answered" % p)
out("noncanonical-port", "; ".join(noncanon[:3]))

# ─── a hostile PORT argument must be as safe as hostile text ───────────────────
weird = []
for p in ["3000", None, 3.5, [], {"a": 1}, True]:
    try:
        v = verdict(GOOD, p)
        if v is not None and VOCAB and v not in VOCAB:
            weird.append("%r -> %r" % (p, v))
    except Exception:
        weird.append("%r raised" % (p,))
out("weird-port", "; ".join(weird[:3]))

# ─── what the canary is aimed at, and whether it was hit ───────────────────────
# LAST, so nothing here can cut short a probe above, every one of which reads a missing answer as
# a pass. And only once the corpus has run, so a run that died inside it reports nothing.
#
# Spelled HERE, row by row, from the path the shell handed in, not taken from CANARY_CASE, so a
# corpus aimed elsewhere cannot vouch for itself. HOSTILE must hold each row once, and the corpus as
# run no other `$(touch` at all: a dropped or moved row, an unquoted path a shell would split, a
# canary back among the seeds or a second payload aimed at /tmp is each a canary nobody watches,
# and #395 was one.
want = "$(touch %s)" % shlex.quote(CANARY)
rows = ["reason\t" + want, "refused\t3000\t" + want]
lines = "\n".join(HOSTILE).split("\n")
found = [r for r in rows if lines.count(r) == 1]
n_any = sum(c.count("$(touch ") for c in cases)
out("canary-aimed", CANARY if found == rows and n_any == len(rows) else
    "want %r once each and no other `$(touch`; found %r, and %d in all" % (rows, found, n_any))
out("canary", "%s %s" % (CANARY, "present" if os.path.exists(CANARY) else "absent"))
PY

fz() { awk -F'\t' -v k="$1" '$1==k{print $2}' "$OUT"; }

# ─── the contract exists at all ────────────────────────────────────────────────
# First and on its own: every property below is vacuous without it, and a fuzzer that drives
# nothing passes everything.
if [ "$(fz exists)" != yes ]; then
    fail "slfuzz:the-parser-exists" \
"port_verdict(text, port) is not defined in files/shortlink.
Every assertion in this suite drives it, so there is nothing to test.
$(cat "$OUT")"
    exit 1
fi
pass "slfuzz:the-parser-exists"
assert_eq "slfuzz:the-vocabulary-is-declared" "yes" "$(fz vocab)"

# ─── the seven properties ──────────────────────────────────────────────────────
assert_eq "slfuzz:valid-input-is-still-read"  "" "$(fz known-good)"
assert_eq "slfuzz:nothing-ever-raises"        "" "$(fz raised)"
assert_eq "slfuzz:answers-stay-in-vocabulary" "" "$(fz bad-vocab)"
assert_eq "slfuzz:never-claims-up-falsely"    "" "$(fz unsound)"
assert_eq "slfuzz:stderr-stays-clean"         "" "$(fz stderr)"
assert_eq "slfuzz:a-hostile-port-is-safe"     "" "$(fz weird-port)"
assert_eq "slfuzz:text-need-not-be-text"      "" "$(fz nonstr-text)"
assert_eq "slfuzz:only-canonical-ports-match" "" "$(fz noncanonical-port)"

# ─── nothing in the input is ever run ──────────────────────────────────────────
# THE GUARD FIRST. An absent canary is also what a missing case, a payload aimed somewhere else --
# #395's was aimed at /tmp/CANARY -- or a run that died before the loop finished all produce, so
# the absence means nothing until the corpus is known to have aimed at exactly the path looked at.
#
# BOTH ANSWERS NAME THE PATH, so neither can be pointed somewhere the other is not looking. The
# first draft looked with `assert_no_file "$CANARY"`, and editing only that argument passed --
# measured.
#
# NO SLEEP BEFORE THE LOOK, though it proves an absence. The payload runs inside verdict() for any
# reader that waits for its shell, and for one that does not, the rest of the corpus -- ~35,000
# calls after HOSTILE's canary -- is already the wait.
#
# AND A FAIL, NOT A PASS, when the guard fails: the look was not taken, and a green line for it
# would be counted as one. Not a skip either -- nothing goes red for a skip, so a gate that broke
# would skip the look forever on a green run.
aimed="$(fz canary-aimed)"
assert_eq "slfuzz:the-canary-is-in-the-corpus" "$CANARY" "$aimed"
if [ "$aimed" = "$CANARY" ]; then
    assert_eq "slfuzz:nothing-in-the-input-is-run" "$CANARY absent" "$(fz canary)"
else
    fail "slfuzz:nothing-in-the-input-is-run" "not looked at: the canary is not in the corpus"
fi
record "slfuzz:cases-run" "$(fz cases) (seed $SEED)"

# A LITERAL, so adding a hostile case makes you come and look at this line -- the same device
# 17-portparse-fuzz.sh uses, and for the same reason: the corpus is the part that silently shrinks.
assert_eq "slfuzz:every-hostile-case-is-in-the-corpus" "33" "$(fz hostile-cases)"
