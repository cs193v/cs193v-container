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

# ═══════════════════════════════════════════════════════════════════════════════
# --dev-tunnel: the port list the suite derives from, and the tunnel's own file names
#
# WHY IT LIVES IN THIS FILE. It is load_args' other consumer, and the only one whose answer the
# TEST SUITE depends on: lib/assert.sh reads it to find out which ports to assert about, so a
# mis-parse here does not fail one assertion, it silently points every port assertion in the
# container and live tiers at the wrong ports. That is issue #46 in the other direction -- the
# suite used to read container.args itself and ignore local.args, and five assertions reddened
# for a developer who used the documented CS193V_PORTS override.
#
# The fixture is the same one above: a real launcher, our args files, no podman.
tun()        { "$FIX/cs193v" --dev-tunnel 2>/dev/null; }
tun_field()  { tun | awk -F'\t' -v k="$1" '$1 == k { print $2 }'; }
tun_ports()  { tun | awk -F'\t' '$1 == "port" { print $2 }' | tr '\n' ' ' | sed 's/ *$//'; }

# 1. The spec, and its expansion, from container.args alone. A bare port, a range and a
#    comma list in one value, because those are the three shapes tunnel_ports walks.
fix_reset
printf -- '-e CS193V_PORTS=3000,4173-4175,8080\n' | fix_args container.args
assert_eq "tunnel:spec-is-the-declared-value" "3000,4173-4175,8080" "$(tun_field spec)"
assert_eq "tunnel:ranges-are-expanded-in-order" "3000 4173 4174 4175 8080" "$(tun_ports)"

# 2. THE CASE #46 IS ABOUT: local.args wins, in the spec AND in the expansion. Both are checked
#    because they are read by different callers -- the spec is what the container's environment
#    must equal, the expansion is what the suite probes -- and a fix that moved only one of them
#    would leave the two disagreeing, which is worse than the original bug.
printf -- '-e CS193V_PORTS=13000-13002\n' | fix_args local.args
assert_eq "tunnel:local-args-overrides-the-spec" "13000-13002" "$(tun_field spec)"
assert_eq "tunnel:local-args-overrides-the-ports" "13000 13001 13002" "$(tun_ports)"

# 3. A backwards range is warned about and contributes nothing -- and, the part that matters for a
#    machine reading this, the warning goes to STDERR and leaves stdout parseable. tunnel_ports
#    warns for a reason: container.args is a file people edit.
fix_reset
printf -- '-e CS193V_PORTS=3005-3000,8080\n' | fix_args container.args
assert_eq "tunnel:backwards-range-contributes-no-port" "8080" "$(tun_ports)"
# BY KEY, not by quoting the prose, per assert_says_key's own reasoning -- and the chunk itself is
# asserted separately, because that half is behaviour rather than wording: a warning that does not
# name which chunk it skipped sends a developer to read all 239 lines of container.args.
badout="$("$FIX/cs193v" --dev-tunnel 2>&1 >/dev/null)"
assert_says_key "tunnel:backwards-range-warns" warn.tunnel-bad-port "$badout"
assert_contains "tunnel:the-warning-names-the-bad-chunk" "3005-3000" "$badout"

# 4. No CS193V_PORTS at all: no port lines, and still exit 0. The launcher's own warn.tunnel-no-ports
#    covers the student-facing half of this; here the point is that the seam does not become
#    unparseable, because fwd_init's hard-fail message is what a developer has to be shown instead.
fix_reset
printf -- '--memory=1g\n' | fix_args container.args
assert_eq "tunnel:no-ports-declared-prints-none" "" "$(tun_ports)"
assert_eq "tunnel:no-ports-declared-prints-an-empty-spec" "" "$(tun_field spec)"
assert_exit "tunnel:no-ports-declared-still-exits-0" 0 "$FIX/cs193v" --dev-tunnel

# 5. The three paths are the tunnel's real ones: one id, three extensions. This is what lets a test
#    ask "is this listener MINE" at all -- TUNNEL_ID hashes the course directory and the instance,
#    so nothing outside the launcher can derive it.
ctl="$(tun_field ctl)"; pidf="$(tun_field pid)"; logf="$(tun_field log)"
assert_match "tunnel:ctl-path-is-a-cs193v-socket" 'cs193v-[0-9a-f]+\.ctl$' "$ctl"
assert_eq "tunnel:pid-path-shares-the-ctl-stem" "${ctl%.ctl}.pid" "$pidf"
assert_eq "tunnel:log-path-shares-the-ctl-stem" "${ctl%.ctl}.log" "$logf"

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
