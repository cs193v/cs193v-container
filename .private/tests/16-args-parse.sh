#!/usr/bin/env bash
# TIER: unit
#
# load_args, one edge case at a time. No podman, no container, no terminal.
#
# WHY THIS EXISTS AS ITS OWN SUITE. Every flag the container is created with comes out of this
# one function, and until #57 it trimmed each line with a `sed` in a command substitution --
# BEFORE testing whether the line had anything on it. container.args is 239 lines of which 228
# are a comment or blank, so a launch forked `sed` 239 times and spent ~700ms of its ~1.8s
# startup doing it. Nothing in the suite noticed, for the same reason nothing noticed
# run_timeout's 100ms poll before #38 (see 12-run-timeout.sh): no other assertion here measures
# cost, and being slow changes no output at all.
#
# The fix asks "does this line hold anything?" ahead of the trim. That is a behaviour-preserving
# change only if the two orders really do agree on every shape an args file can take, which is
# what the oracle below is for: today's order is kept here as a reference implementation and
# diffed against the shipped launcher over a corpus of the awkward cases. The corpus IS the
# claim -- hand-written expectations would only restate what the author already believed.
#
# Driven through `cs193v --dev-args`, which prints the parse one word per line. That verb exists
# for this: --dev-print-command joins the same words with spaces, so it cannot tell one word
# containing a space from two words, and a word that is a bare \r is invisible in it entirely --
# and a word boundary is what nearly everything in here is about. Same reason --dev-steps exists
# for the Containerfile parser.
#
# THE REST OF load_args' CONTRACT lands in its own section at the bottom -- the missing-file
# paths, the container.args-then-local.args read order, the cs193v-*:* volume rewrite, globbing
# through the unquoted `for word in $line`, quotes staying literal. None of it is touched by
# #57's change, which is why it is kept apart from the corpus above rather than folded into it.
# It was issue #63.

set -u
. "$(dirname -- "$0")/lib/assert.sh"

cd "$REPO" || exit 1

WORK="$(new_tmpdir)"
trap 'rm -rf "$WORK"' EXIT

# ─── the fixture ───────────────────────────────────────────────────────────────
# A course directory holding the real launcher, the real .private/ and OUR args files. A copy
# of the launcher rather than a symlink to it, because the launcher resolves its own symlinks
# to find the directory it mounts -- a link would send it straight back to the working tree's
# container.args and every case below would test the same file.
#
# Lighter than 30-launcher-shim.sh's repo_copy() on purpose: that lives in podman-shim.sh and
# brings the shim's TMPDIR machinery with it, and the unit tier is meant to need none of it.
# PHYSICAL, because the launcher resolves its own directory with `pwd -P` and names it in the
# missing-args refusal -- so a $FIX under a raw $TMPDIR could never match: on macOS that is
# /var/... against the launcher's /private/var/..., and $TMPDIR's trailing slash doubles the
# separator as well. Resolved HERE rather than in new_tmpdir, which becomes the launcher's own
# TMPDIR in 14-test-harness.sh and so carries the tunnel's unix socket -- and that path is capped
# near 104 bytes (cs193v:903). This one is only ever compared as a string.
WORK="$(cd -- "$WORK" && pwd -P)"
FIX="$WORK/course"
mkdir -p "$FIX/.config"
cp "$REPO/cs193v" "$FIX/cs193v"
ln -s "$PRIVATE" "$FIX/.private"

# fix_args FILE  <- body on stdin.  FILE is container.args or local.args.
fix_args() { cat > "$FIX/.config/$1"; }
fix_reset() { rm -f "$FIX/.config/container.args" "$FIX/.config/local.args"; }

# The parse, one word per line, from the launcher under test.
parsed() { "$FIX/cs193v" --dev-args; }

# ─── the oracle ────────────────────────────────────────────────────────────────
# load_args' loop EXACTLY as it stood before #57: sed first, `[ -z ]` after. Kept here rather
# than in git history because a test that reads "the old way and the new way agree" has to hold
# the old way where a reader can see it. NAME comes from assert.sh and matches the launcher's,
# so the volume rewrite lands identically on both sides.
ref_parse() {                         # ref_parse FILE... -> one word per line
    local f line word
    for f in "$@"; do
        [ -f "$f" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%%#*}"
            # LC_ALL=C, tracking the same change in load_args. The oracle is "load_args' loop
            # exactly as it stood", so it has to move with it -- and note that when only the
            # launcher was fixed, `agrees` went RED. That is the differential test working: it
            # cannot see a bug both sides share, but it does see them diverge.
            line="$(printf '%s' "$line" | LC_ALL=C sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            [ -z "$line" ] && continue
            for word in $line; do
                case "$word" in
                    cs193v-*:*) word="$NAME-${word#cs193v-}" ;;
                esac
                printf '%s\n' "$word"
            done
        done < "$f"
    done
}

# agrees NAME  -- the shipped parse and the oracle must be byte-identical on the current fixture.
# `od -c`, not the raw bytes: a difference in trailing whitespace or a stray \r is otherwise
# invisible in the failure message, which is the whole class of bug this file is about.
agrees() {
    local want got
    want="$(ref_parse "$FIX/.config/container.args" "$FIX/.config/local.args" | od -c)"
    got="$(parsed | od -c)"
    assert_eq "$1" "$want" "$got"
}

# ─── the corpus, case by case ──────────────────────────────────────────────────
# Each block is one shape an args file can take. Numbers match the plan's edge-case list.

# 1. CRLF throughout -- what editing local.args on Windows produces. The trim is the only thing
#    taking the \r off, and \r is NOT an IFS character, so a line the trim missed would put a
#    bare \r on the podman run line.
fix_reset
printf -- '--memory=2048m\r\n\r\n   \r\n# c\r\n   # indented\r\n-e X=1\r\n' | fix_args container.args
agrees "corpus:crlf-throughout"
assert_eq "crlf:parses-to-three-clean-words" "--memory=2048m
-e
X=1" "$(parsed)"
assert_not_contains "crlf:no-carriage-return-survives" "$(printf '\r')" "$(parsed)"

# 2. Whitespace-only lines, every class the trim covers. \v and \f are in [[:space:]] and are
#    the two a hand-rolled trim forgets.
fix_reset
printf -- '--memory=1g\n \n\t\n\v\n\f\n \t \v \f \r \n-e Y=2\n' | fix_args container.args
agrees "corpus:whitespace-only-lines"
assert_eq "whitespace:contributes-no-words" "--memory=1g
-e
Y=2" "$(parsed)"

# 3. Indented comments. Non-empty after ${line%%#*}, so this is the case that separates a
#    whitespace guard from a plain `[ -z ]` -- and the shape a reflowed comment block takes.
fix_reset
printf -- '    # indented one\n\t# indented two\n--memory=1g\n' | fix_args container.args
agrees "corpus:indented-comments"
assert_eq "indented-comments:contribute-no-words" "--memory=1g" "$(parsed)"

# 4/5/6. The comment marker in every position that matters. `#` inside an apparently quoted
#    value truncates the line -- existing behaviour, pinned rather than fixed.
fix_reset
printf -- '#col1\n#\n-m 8g#glued\n-m 1024g   # cap\n--label a="x # y"\n' | fix_args container.args
agrees "corpus:comment-shapes"
assert_eq "comments:glued-and-quoted" '-m
8g
-m
1024g
--label
a="x' "$(parsed)"

# 7. A last line with no trailing newline -- the `|| [ -n "$line" ]` clause exists for it.
fix_reset
printf -- '--memory=1g\n--no-trailing-newline' | fix_args container.args
agrees "corpus:no-trailing-newline"
assert_contains "no-trailing-newline:last-word-survives" "--no-trailing-newline" "$(parsed)"

# 8. An args file with nothing in it. ARGS ends up empty, which build_run_args survives only
#    through ${ARGS[@]+"..."} -- fatal under `set -u` on bash 3.2 written the obvious way.
fix_reset
printf -- '# only comments\n\n#\n   \n' | fix_args container.args
agrees "corpus:comments-only"
assert_eq "comments-only:parses-to-nothing" "" "$(parsed)"
assert_exit "comments-only:still-exits-0" 0 "$FIX/cs193v" --dev-args
fix_reset
: > "$FIX/.config/container.args"
agrees "corpus:zero-byte-file"
assert_eq "zero-byte:parses-to-nothing" "" "$(parsed)"
assert_exit "zero-byte:still-exits-0" 0 "$FIX/cs193v" --dev-args

# 9. Tabs as the separator between words, not just as padding.
fix_reset
printf -- '\t-e A=1\t-e B=2\t\n' | fix_args container.args
agrees "corpus:tab-separated-words"
assert_eq "tabs:split-like-spaces" "-e
A=1
-e
B=2" "$(parsed)"

# 10. An invalid UTF-8 byte. sed passes it through rather than dropping the line; a student
#     whose editor wrote Latin-1 should get podman's complaint about the flag, not a silently
#     missing one.
fix_reset
printf -- '--label caf\xe9=1\n-e OK=2\n' | fix_args container.args
agrees "corpus:invalid-utf8-byte"
assert_contains "invalid-utf8:line-not-dropped" "-e" "$(parsed)"
# THE FLAG ITSELF, not just the line after it. `agrees` cannot see this bug and neither could the
# assertion above: the oracle is load_args' own former loop, so BOTH sides shell out to sed, both
# lose the same line, and empty compares equal to empty. `line-not-dropped` then passes on the
# strength of `-e` from the NEXT line surviving.
#
# Measured on macOS under the default LANG=en_US.UTF-8: BSD sed rejects the \xe9 with
# "RE error: illegal byte sequence" and emits nothing for that line, so `--label caf<e9>=1`
# vanished -- exactly the "silently missing one" the comment above says must not happen. Under
# LC_ALL=C the same sed passes the byte through untouched, which is why load_args now sets it
# per-invocation.
assert_contains "invalid-utf8:the-flag-is-not-silently-dropped" "--label" "$(parsed)"

# Everything at once, in one file, so an interaction between two rules cannot hide behind two
# separate green cases.
fix_reset
printf -- '--memory=2048m\r\n \n\t\n\v\n\f\n    # indented\r\n#col1\n-m 8g#glued\n \t \r \n-m 1024g   # cap\n--label a="x # y"\n\t-e A=1\t-e B=2\t\n--last' \
    | fix_args container.args
agrees "corpus:all-cases-in-one-file"

# And with local.args in play as well, since that is the file a person hand-edits.
printf -- '   --cpus 2   \r\n\r\n# tail comment\n' | fix_args local.args
agrees "corpus:both-files-together"
assert_contains "both-files:local-args-reaches-the-parse" "--cpus" "$(parsed)"

# ─── the cost, which is the point of the change ────────────────────────────────
# COUNTED WITH A SHIM ON PATH, not with strace: the TAs run this tier on Macs, where there is no
# strace and dtrace needs root. A `sed` that logs a line and then execs the real one measures
# exactly the thing that regressed, on every platform, deterministically -- where a wall-clock
# ceiling would go yellow on a loaded machine and prove nothing about why.
mkdir -p "$WORK/bin"
REAL_SED="$(command -v sed)"
{ printf '#!/bin/sh\n'
  printf 'printf "x\\n" >> "%s/sed.count"\n' "$WORK"
  printf 'exec %s "$@"\n' "$REAL_SED"
} > "$WORK/bin/sed"
chmod +x "$WORK/bin/sed"

# sed_calls FILE -> how many times a parse of the working tree's own container.args forks sed
sed_calls() {
    : > "$WORK/sed.count"
    PATH="$WORK/bin:$PATH" "$FIX/cs193v" --dev-args >/dev/null 2>&1
    awk 'END { print NR }' "$WORK/sed.count"
}

# AND IT MUST ASK PODMAN NOTHING. The unit tier's whole promise is that it runs on a machine with
# no podman, and --dev-args is only in that tier because it takes no preflight -- one line added to
# its dispatch arm would move it out and nobody would notice, because podman IS installed wherever
# this suite actually runs. Same shim trick as the sed counter, for the same portability reason.
{ printf '#!/bin/sh\n'
  printf 'printf "x\\n" >> "%s/podman.count"\n' "$WORK"
  printf 'exit 0\n'
} > "$WORK/bin/podman"
chmod +x "$WORK/bin/podman"
fix_reset
printf -- '--memory=1g\n' | fix_args container.args
: > "$WORK/podman.count"
PATH="$WORK/bin:$PATH" "$FIX/cs193v" --dev-args >/dev/null 2>&1
assert_eq "cost:asks-podman-nothing" "0" "$(awk 'END { print NR }' "$WORK/podman.count")"

# The real file, as shipped: 11 lines carry an argument, and nothing else may cost a fork.
fix_reset
cp "$REPO/.config/container.args" "$FIX/.config/container.args"
real_lines="$(awk '{ l = $0; sub(/#.*/, "", l) } l ~ /[^[:space:]]/ { n++ } END { print n+0 }' \
    "$REPO/.config/container.args")"
assert_eq "cost:one-sed-per-line-with-content" "$real_lines" "$(sed_calls)"

# THE FILE THAT ACTUALLY SHIPS, against the old order. Every case above is a fixture someone
# invented; this one is the file every student's container is built from, and it is the only
# place the corpus could be comprehensive and still miss something. It also covers what
# --dev-print-command cannot: that verb joins the words with spaces, so a change that merged
# two words into one, or split one into two, prints identically while argv differs.
agrees "corpus:the-shipped-container-args"

# THE REGRESSION THIS FILE EXISTS FOR. Indenting the comment block is a reflow, not a semantic
# edit, and it must not change the cost. It is exactly what a `[ -z "$line" ]` guard cannot
# survive -- an indented comment is whitespace, not empty, so all 239 lines would fork again.
sed 's/^#/    #/' "$REPO/.config/container.args" > "$FIX/.config/container.args"
assert_eq "cost:unchanged-when-comments-are-indented" "$real_lines" "$(sed_calls)"
agrees "corpus:indenting-comments-changes-no-word"

# And the floor: a file with no arguments at all must fork nothing.
fix_reset
printf -- '# a\n\n   \n\t\n' | fix_args container.args
assert_eq "cost:no-content-no-forks" "0" "$(sed_calls)"

# ═══════════════════════════════════════════════════════════════════════════════
# the rest of load_args' contract  (#63)
#
# Everything above is about ONE line of the loop -- the trim, and #57's reordering of it. The
# rest of the function was unasserted anywhere in the suite: the two missing-file paths, the
# read order CLAUDE.md's "local.args is read after container.args, last occurrence winning"
# rests on, the instance rewrite that renames six volumes, and what the unquoted expansion does
# to a word full of shell metacharacters. Every flag the container is created with comes out of
# here, so none of it was cheap to leave unmeasured.
#
# RED-FIRST BY MUTATION, since coverage of correct code has no failing behaviour to start from.
# Eight mutants of load_args were run against the assertions below: the required-file die
# dropped, each of the two `[ -f ]` guards weakened to `[ -e ]`, the read order swapped, the
# volume rewrite removed, its trailing colon dropped, the expansion quoted, and `set -f` wrapped
# round the loop. Each is caught by the assertion naming the property it broke -- the `[ -e ]`
# one only after it survived the first draft of this section, which is what the silent-skip
# assertion below exists for and why its comment is the longest one here.
#
# NO `agrees` IN THIS SECTION, which is not an omission. The oracle answers a #57 question --
# "do the two trim orders agree" -- and it cannot answer these: it does not die on a missing
# file, and it globs against the suite's own working directory rather than the fixture's.

# ─── the missing-file paths ────────────────────────────────────────────────────
# container.args ships in the repo, so its absence is a broken install rather than something a
# student did, and it has to say so. Without the die the parse would simply produce an empty
# ARGS and the student would get podman's complaint about a run line with no flags on it.
fix_reset
assert_exit "missing:no-container-args-exits-1" 1 "$FIX/cs193v" --dev-args
missing_err="$("$FIX/cs193v" --dev-args 2>&1 >/dev/null)"
assert_says_key "missing:no-container-args-says-so" err.no-args-file "$missing_err"
# AND IT NAMES THE PATH. The keyed assertion above cannot see {{FILE}}, and that interpolation is
# what tells a developer with two checkouts which one of them is broken.
#
# COMPARED WITH THE WHITESPACE TAKEN OUT OF BOTH SIDES, and that is not belt-and-braces. box()
# hard-wraps its body to the STOP box width and will break a long path MID-TOKEN, so the same
# assertion reads `.../course/.config/container.args` on one line under a short $TMPDIR and
# `.../contain` + `er.args` on two under a longer one. assert_says is no help: it flattens box art
# but only COLLAPSES runs of whitespace, and cannot rejoin a token the wrap split.
#
# Written the naive way first, which is worth recording because of how it passed: it is green under
# TMPDIR=/tmp, where the fixture path is short enough to fit, and red the moment the suite is run
# with $TMPDIR somewhere longer -- which is exactly what #76 forces a developer to do. An assertion
# that depends on the length of a temp path is one nobody would think to distrust.
squash_ws() { printf '%s' "$1" | sed -e 's/[┃┏┓┗┛━]//g' | do_tr -d '[:space:]'; }
assert_contains "missing:the-error-names-the-file" \
                "$(squash_ws "$FIX/.config/container.args")" "$(squash_ws "$missing_err")"
# ON STDERR, WITH STDOUT EMPTY. --dev-args is read by a machine; box art on stdout would arrive
# as words in the list a caller is parsing.
assert_eq "missing:nothing-reaches-stdout" "" "$("$FIX/cs193v" --dev-args 2>/dev/null)"

# A DIRECTORY where container.args should be takes the same path, because `[ -f ]` is the
# question the guard asks. Worth holding: `[ -e ]` would let it through to the read and the
# student would get bash's "Is a directory" instead of ours.
fix_reset
mkdir -p "$FIX/.config/container.args"
assert_exit "missing:a-directory-is-not-an-args-file" 1 "$FIX/cs193v" --dev-args
assert_says_key "missing:a-directory-says-the-same-thing" err.no-args-file \
                "$("$FIX/cs193v" --dev-args 2>&1 >/dev/null)"
rmdir "$FIX/.config/container.args"

# local.args is git-ignored and optional, so NOT existing is its ordinary state -- the `[ -f ]`
# continue is the only thing that makes that ordinary rather than fatal.
fix_reset
printf -- '-m 1g\n' | fix_args container.args
assert_eq "missing:absent-local-args-is-skipped" "-m
1g" "$(parsed)"
assert_exit "missing:absent-local-args-still-exits-0" 0 "$FIX/cs193v" --dev-args
assert_eq "missing:absent-local-args-is-silent" "" "$("$FIX/cs193v" --dev-args 2>&1 >/dev/null)"

# ...and a DIRECTORY named local.args is skipped rather than fatal, which is the asymmetry with
# container.args above: one file is required and one is not, and the same `[ -f ]` produces both
# answers.
#
# THE ASSERTION THAT HOLDS THE GUARD IS THE SILENT ONE, and that is a measurement rather than a
# preference. Replacing this `[ -f ]` with `[ -e ]` changes NEITHER the word list NOR the exit
# status: bash opens the directory, the `read` fails with EISDIR before the body runs once, and
# the parse comes out byte-identical at status 0. What it does produce is
# `read: 0: read error: Is a directory` on stderr -- so stdout and the status cannot tell the two
# spellings apart and only silence can. Found by mutating the guard and watching the obvious
# assertions stay green.
mkdir -p "$FIX/.config/local.args"
assert_eq "missing:a-local-args-directory-is-skipped" "-m
1g" "$(parsed)"
assert_exit "missing:a-local-args-directory-still-exits-0" 0 "$FIX/cs193v" --dev-args
assert_eq "missing:a-local-args-directory-is-skipped-silently" "" \
          "$("$FIX/cs193v" --dev-args 2>&1 >/dev/null)"
rmdir "$FIX/.config/local.args"

# ─── the read order CLAUDE.md makes a promise about ───────────────────────────
# "local.args is read AFTER container.args, last occurrence winning" is CLAUDE.md section 2, and
# it is the entire mechanism behind the documented CS193V_PORTS override. It is true only
# because of the order of the `for f in` list, and a swap would be invisible to every assertion
# above: both files' words still reach the run line, just the other way round. So the fixture
# uses values that can be told apart, and the assertion is the whole list in order -- "both
# files got there" is exactly the weaker claim that would survive the swap.
fix_reset
printf -- '-m 1g\n--cpus 1\n' | fix_args container.args
printf -- '-m 8g\n--cpus 4\n' | fix_args local.args
assert_eq "order:container-args-is-read-first" "-m
1g
--cpus
1
-m
8g
--cpus
4" "$(parsed)"
# And the consequence, read off the run line rather than restated: the LAST -m podman sees is
# local.args'. This is the sentence the documentation makes, and podman's own
# last-occurrence-wins is what turns it into an override.
assert_eq "order:the-last-occurrence-is-local-args" "8g" \
          "$(parsed | awk '$0 == "-m" { want = 1; next } want { v = $0; want = 0 } END { print v }')"

# ─── the instance rewrite, which renames six volumes ──────────────────────────
# The volume names live in container.args, so the CS193V_INSTANCE suffix has to be applied as
# they are read. The pattern that does it, `cs193v-*:*`, needs the trailing colon for exactly
# one reason, which cs193v:940 states and nothing held: `--hostname cs193v-development` is the
# other word in that file beginning with the same eight characters, and renaming it would give
# every instance a different hostname inside the container.
#
# WITH THE INSTANCE FORCED, not taken from the environment. NAME follows CS193V_INSTANCE, so on
# a run with it unset -- a TA's machine, and a student's launcher -- the rewrite is the identity
# and an assertion written against "$NAME" would hold while saying nothing at all.
inst_parsed() { CS193V_INSTANCE="$1" "$FIX/cs193v" --dev-args; }
fix_reset
printf -- '%s\n' '-v cs193v-claude:/home/student/.claude' \
                 '-v cs193v-claude-json:/home/student/.claude-json' \
                 '--hostname cs193v-development' \
                 '--label cs193v.dir=/somewhere' \
                 '-e SEED=cs193v-claude:/elsewhere' | fix_args container.args
assert_eq "instance:the-suffix-lands-on-the-volume-names" "-v
cs193v-vt9-claude:/home/student/.claude
-v
cs193v-vt9-claude-json:/home/student/.claude-json
--hostname
cs193v-development
--label
cs193v.dir=/somewhere
-e
SEED=cs193v-claude:/elsewhere" "$(inst_parsed vt9)"
# The three words the pattern must NOT touch, each for its own reason, so a widened pattern
# fails on the one it widened past: the hostname has no colon, the label's prefix is
# `cs193v.` rather than `cs193v-`, and SEED= holds a volume-shaped value but does not START
# with the prefix -- the match is anchored at the beginning of the word.
assert_eq "instance:nothing-but-a-volume-name-is-rewritten" "3" \
          "$(inst_parsed vt9 | grep -c 'cs193v-development\|cs193v\.dir=\|SEED=cs193v-claude')"
# And with no instance at all it is the identity, which is what keeps this off a student's run.
assert_eq "instance:no-instance-renames-nothing" "-v
cs193v-claude:/home/student/.claude
-v
cs193v-claude-json:/home/student/.claude-json
--hostname
cs193v-development
--label
cs193v.dir=/somewhere
-e
SEED=cs193v-claude:/elsewhere" "$(inst_parsed '')"

# ─── what the unquoted expansion does to a metacharacter ──────────────────────
# `for word in $line` is unquoted, so every word is also a GLOB PATTERN matched against the
# directory ./cs193v was run FROM. This section is a RECORD of what that does, not a promise
# that it should keep doing it -- and the second case below is the argument for changing it.
#
# Realistic values are inert, and the reason is luck rather than design: the whole word is the
# pattern, so `-e PATTERN=*.txt` would have to match a file literally named `-e PATTERN=...`.
#
# RUN FROM A DIRECTORY WITH KNOWN CONTENTS. The answer is a directory listing, so reading it out
# of the working tree would make the assertion depend on which files happen to be in the repo
# root that week.
GLOBDIR="$WORK/globdir"
mkdir -p "$GLOBDIR"
: > "$GLOBDIR/one.txt"
: > "$GLOBDIR/two.txt"
globbed() { ( cd "$GLOBDIR" && "$FIX/cs193v" --dev-args ); }

fix_reset
printf -- '%s\n' '-e PATTERN=*.txt' '-e Q=?' '-e BRACKET=[abc]' | fix_args container.args
assert_eq "glob:a-pattern-inside-a-value-is-inert" "-e
PATTERN=*.txt
-e
Q=?
-e
BRACKET=[abc]" "$(globbed)"

# THE CASE THAT IS NOT INERT, pinned so it is on the record rather than in someone's memory: a
# word that is a bare pattern expands, so one local.args produces different podman flags
# depending on where the launcher was started. Nothing in the shipped container.args is this
# shape, which is the only reason it has never bitten.
fix_reset
printf -- '%s\n' '--label bare *' | fix_args container.args
assert_eq "glob:a-bare-pattern-expands-to-the-working-directory" "--label
bare
one.txt
two.txt" "$(globbed)"
# ...and one matching nothing stays literal, which is bash's nullglob-off default and the reason
# the case above is the exception rather than the rule.
fix_reset
printf -- '%s\n' '--label bare *.nomatch' | fix_args container.args
assert_eq "glob:a-pattern-matching-nothing-stays-literal" "--label
bare
*.nomatch" "$(globbed)"

# ─── quotes and backslashes stay literal ──────────────────────────────────────
# The expansion splits words but performs no quote removal, so `--label x="a b"` is TWO words
# with the quote marks still inside them. That is why build_run_args appends ARGS element by
# element instead of word-splitting a string, and it means there is no way to write a single
# flag containing a space in these files. Pinned because the obvious reading of the file says
# otherwise, and someone will eventually put a space in a --label and expect it to survive.
fix_reset
printf -- '%s\n' '--label x="a b"' '--label y=a\ b' "--label z='c d'" | fix_args container.args
assert_eq "literal:quotes-and-backslashes-are-not-interpreted" \
          "$(printf '%s\n' '--label' 'x="a' 'b"' '--label' 'y=a\' 'b' '--label' "z='c" "d'")" \
          "$(parsed)"

# ═══════════════════════════════════════════════════════════════════════════════
# --dev-tunnel: the file names that identify THIS instance's tunnel
#
# WHY IT LIVES IN THIS FILE. It is load_args' other consumer, and the only one whose answer the
# TEST SUITE depends on: lib/assert.sh reads it to find out which ssh master and which supervisor
# are ours, so a mis-parse here does not fail one assertion, it silently points the container and
# live tiers at another checkout's processes. That is issue #46 in the other direction.
#
# THE PORT HALF OF THIS GROUP IS GONE, and it is worth saying why rather than leaving a gap: the
# spec, the range expansion, the local.args override and the backwards-range warning were all
# about a declared list, and nothing declares ports now. They were not weakened or moved; the
# behaviour they described does not exist. What a suite needs from this seam is identity, which
# is everything below.
#
# The fixture is the same one above: a real launcher, our args files, no podman.
tun()        { "$FIX/cs193v" --dev-tunnel 2>/dev/null; }
tun_field()  { tun | awk -F'\t' -v k="$1" '$1 == k { print $2 }'; }

fix_reset
printf -- '--memory=1g\n' | fix_args container.args
# NO PORT LINES AT ALL, asserted rather than assumed. A `port` line coming back would mean someone
# reintroduced a declared list, and lib/assert.sh would not notice -- it stopped reading them.
assert_eq "tunnel:no-port-lines-are-printed" "" \
          "$(tun | awk -F'\t' '$1 == "port" || $1 == "spec" { print }')"
assert_exit "tunnel:still-exits-0" 0 "$FIX/cs193v" --dev-tunnel

# 5. The three paths are the tunnel's real ones: one id, three extensions. This is what lets a test
#    ask "is this listener MINE" at all -- TUNNEL_ID hashes the course directory and the instance,
#    so nothing outside the launcher can derive it.
ctl="$(tun_field ctl)"; pidf="$(tun_field pid)"; logf="$(tun_field log)"
assert_match "tunnel:ctl-path-is-a-cs193v-socket" 'cs193v-[0-9a-f]+\.ctl$' "$ctl"
assert_eq "tunnel:pid-path-shares-the-ctl-stem" "${ctl%.ctl}.pid" "$pidf"
assert_eq "tunnel:log-path-shares-the-ctl-stem" "${ctl%.ctl}.log" "$logf"
# The supervisor's two files, keyed by the same id and printed for the same reason: teardown finds
# it by pidfile, and a test asking "is dynamic forwarding actually running" has no other way to
# tell our supervisor from another checkout's.
assert_eq "tunnel:supervisor-pidfile-shares-the-ctl-stem" "${ctl%.ctl}.sup.pid" "$(tun_field suppid)"
assert_eq "tunnel:supervisor-log-shares-the-ctl-stem"     "${ctl%.ctl}.sup.log" "$(tun_field suplog)"

# 5b. THE BUILD LOG, which is the one that does NOT share the stem: the launcher writes
#     cs193v-build-<id>.log, not cs193v-<id>.something. It is reported here because
#     00-release-gates.sh used to find it with `ls -t /tmp/cs193v-build-*.log | head -1` -- newest
#     on the MACHINE -- which throws away the very keying that makes it per-instance, so a
#     colleague's --rebuild finishing after ours handed the release gate THEIR build to diff
#     against OUR Containerfile (#74). Asked of the launcher for the reason lib/assert.sh's port
#     header gives: one derivation cannot drift from the launcher, and a copy of a naming rule in
#     a test already has.
buildf="$(tun_field buildlog)"
tid="${ctl##*/cs193v-}"; tid="${tid%.ctl}"
assert_eq "tunnel:buildlog-shares-the-tunnel-id" \
          "$(dirname "$ctl")/cs193v-build-$tid.log" "$buildf"

# 5c. AND THE PATHS MUST SURVIVE AN UNSET TMPDIR, which is the environment most machines
#     actually hand the launcher: TMPDIR is set on macOS and in a login shell, and unset in
#     most Linux logins and in every cron job and systemd unit. The launcher strips a
#     trailing slash off it -- macOS supplies one, and every path below is built as
#     "${TMPDIR:-/tmp}/name", so a doubled slash reached the STUDENT in `cs193v doctor` --
#     and the first version of that strip was unguarded, so `set -u` made an unset TMPDIR a
#     fatal at line one of the launcher. Every verb died, including a bare `./cs193v`.
#
#     ASSERTED AGAINST THE TMPDIR=/tmp RUN rather than a hardcoded path, because that is the
#     claim: an unset TMPDIR must land exactly where /tmp does. TUNNEL_ID hashes the course
#     directory and the instance, not TMPDIR, so the two runs must agree file for file.
#
#     `unset` in a SUBSHELL, not `env -u`: this suite has to run on BSD userland too, and a
#     subshell needs nothing of either.
tmp_default="$(TMPDIR=/tmp "$FIX/cs193v" --dev-tunnel 2>/dev/null \
               | awk -F'\t' '$1 == "ctl" { print $2 }')"
tmp_unset="$( (unset TMPDIR; "$FIX/cs193v" --dev-tunnel 2>/dev/null) \
               | awk -F'\t' '$1 == "ctl" { print $2 }')"
assert_eq "tunnel:paths-survive-an-unset-TMPDIR" "$tmp_default" "$tmp_unset"

#     The other half, and the reason the strip exists at all. This one passes on its own
#     terms today; it is here because NOTHING pinned it, which is exactly how the guard
#     above came to be missing -- the trailing-slash fix shipped green on the one platform
#     that sets TMPDIR, and took the launcher out on every platform that does not.
tmp_slash="$(TMPDIR=/tmp/ "$FIX/cs193v" --dev-tunnel 2>/dev/null \
             | awk -F'\t' '$1 == "ctl" { print $2 }')"
assert_eq "tunnel:no-doubled-slash-when-TMPDIR-ends-in-one" "$tmp_default" "$tmp_slash"

# 6. And the id MOVES WITH CS193V_INSTANCE, which is the whole basis of the ownership test in
#    lib/assert.sh: two instances of the same checkout must not be able to mistake each other's
#    tunnel for their own.
other="$(CS193V_INSTANCE=vt-other "$FIX/cs193v" --dev-tunnel 2>/dev/null \
         | awk -F'\t' '$1 == "ctl" { print $2 }')"
assert_ne "tunnel:the-id-changes-with-CS193V_INSTANCE" "$ctl" "$other"

# 7. AND IT MUST ASK PODMAN NOTHING, for the same reason --dev-args must: this seam is read by the
#    unit tier, and one line added to its dispatch arm would move it out of that tier silently,
#    because podman IS installed wherever this suite actually runs.
: > "$WORK/podman.count"
PATH="$WORK/bin:$PATH" "$FIX/cs193v" --dev-tunnel >/dev/null 2>&1
assert_eq "tunnel:asks-podman-nothing" "0" "$(awk 'END { print NR }' "$WORK/podman.count")"
