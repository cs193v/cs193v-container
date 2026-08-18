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
# NOT COVERED HERE, and deliberately: the rest of load_args' contract -- the missing-file paths,
# the container.args-then-local.args read order, the cs193v-*:* volume rewrite, globbing through
# the unquoted `for word in $line`, quotes staying literal. None of it is touched by #57's
# change. It is issue #63, and this file is where it should land.

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
            line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
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
