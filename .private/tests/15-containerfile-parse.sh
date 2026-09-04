#!/usr/bin/env bash
# TIER: unit
#
# The Containerfile parser, one edge case at a time. No podman, no image, no network -- the
# unit tier, which this is now the only member of.
#
# WHY THIS EXISTS AS ITS OWN SUITE. The progress meter's side text comes from `####>` markers
# in the Containerfile, and the launcher has to number that file's instructions EXACTLY the way
# buildah does or every label after the first disagreement names the wrong step. That numbering
# is the only genuinely new logic in the feature, and it is the part that would fail late, on a
# student's machine, in a way nobody would notice: a label is not load-bearing, so a wrong one
# does not break a build, it just quietly lies about what is happening.
#
# Driven through `cs193v --dev-steps`, which prints the parse as index/label/instruction. That
# verb exists for this: inside build_progress the parser can only be reached by running a whole
# build, which is far too coarse for "does a comment inside a continuation end it".
#
# WHAT THIS CANNOT DO is prove the parse matches podman -- only real podman can settle that, and
# 00-release-gates.sh diffs the two against a real build. What it can do is pin every rule the
# parse is built on, so a change to one of them fails here in half a second rather than there in
# four minutes.

set -u
. "$(dirname -- "$0")/lib/assert.sh"

cd "$REPO" || exit 1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cs193v-parse.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# steps FIXTURE  -> the parse, as "index<TAB>label<TAB>instruction" rows
steps() { "$REPO/cs193v" --dev-steps "$1"; }
# Compact forms, so a case can assert on the one column it is about.
count()  { steps "$1" | wc -l | do_tr -d ' '; }
labels() { steps "$1" | cut -f2 | paste -sd'|' -; }
texts()  { steps "$1" | cut -f3 | paste -sd'|' -; }

# WRITES THE FILE AND PRINTS NOTHING, and the caller names the path itself. It used to print the
# path, so every call site wrapped it in `f="$(fixture NAME <<'EOF' ... EOF)"` -- and a heredoc
# inside a command substitution is CORRUPTED on bash 3.2: to find the closing `)` the shell scans
# forward and strips backslash-newline pairs BEFORE the heredoc body is recognised as one, so the
# literalness `<<'EOF'` asks for never applies. Measured, same script:
#
#   bash 3.2:  R U N   o n e   #   c            <- the "\" and its newline eaten
#   bash 5.3:  R U N   o n e   \  \n  #   c
#
# It happens at PARSE time, before a line runs, so nothing at runtime can detect it. Three of the
# twelve fixtures below carry a continuation and were silently rewritten -- and `continued` still
# PASSED, because collapsing the continuation happens to give the expected count AND the expected
# joined text. The case this file calls "the single most likely way to desync from podman" was
# testing nothing at all on a Mac.
fixture() {                           # fixture NAME  <- content on stdin
    cat > "$WORK/$1"
}

# ─── the counting rule ─────────────────────────────────────────────────────────
# One instruction per line that is not blank, not a comment and not a continuation of the line
# above. This is podman's rule; every case below is a way of getting it wrong.
fixture plain <<'EOF'
FROM scratch
RUN one
RUN two
EOF
f="$WORK/plain"
assert_eq "count:one-per-line" "3" "$(count "$f")"
assert_eq "count:indices-are-dense" "1 2 3" "$(steps "$f" | cut -f1 | paste -sd' ' -)"

# A CONTINUED INSTRUCTION IS ONE INSTRUCTION. Getting this wrong is the single most likely way
# to desync from podman, because the real Containerfile is almost entirely continued RUNs.
fixture continued <<'EOF'
FROM scratch
RUN one \
    two \
    three
RUN after
EOF
f="$WORK/continued"
assert_eq "continuation:counts-as-one-instruction" "3" "$(count "$f")"
# Joined the way podman joins: the backslash and the newline go, everything else stays, and the
# comparison form squeezes whitespace runs. So the indentation becomes single spaces.
assert_eq "continuation:joined-text" "FROM scratch|RUN one two three|RUN after" "$(texts "$f")"

# A COMMENT INSIDE A CONTINUATION DOES NOT END IT. Comments are stripped before continuations
# are joined, so this is one instruction with the comment simply gone. The Containerfile forbids
# writing them (10-static.sh), but the parser must still agree with podman about what they mean.
fixture comment_in_continuation <<'EOF'
FROM scratch
RUN one \
# an explanation
    two
RUN after
EOF
f="$WORK/comment_in_continuation"
assert_eq "comment-in-continuation:does-not-split" "3" "$(count "$f")"
assert_eq "comment-in-continuation:comment-is-dropped" \
          "FROM scratch|RUN one two|RUN after" "$(texts "$f")"

# A `#` INSIDE A COMMAND IS NOT A COMMENT. Only a line whose first non-blank character is `#`.
fixture hash_in_command <<'EOF'
FROM scratch
RUN echo '# not a comment' && echo done
EOF
f="$WORK/hash_in_command"
assert_eq "hash-in-command:still-one-instruction" "2" "$(count "$f")"
assert_match "hash-in-command:text-is-intact" "not a comment" "$(texts "$f")"

# Leading whitespace before an instruction is legal Dockerfile and must not hide it.
fixture indented <<'EOF'
FROM scratch
   RUN spaces
	RUN tab
EOF
f="$WORK/indented"
assert_eq "indented:instructions-still-count" "3" "$(count "$f")"

# A BACKSLASH FOLLOWED BY A SPACE CONTINUES NOTHING. It reads like a continuation, which is why
# 10-static.sh forbids it in our file, but the behaviour is pinned here so the two agree.
#
# WRITTEN WITH printf, NOT A HEREDOC, and that is the whole test: the trailing space is the
# subject, and in a heredoc it is invisible -- to a reader, to a diff, and to every editor that
# strips it on save. Written as an escape it cannot be lost without the assertion changing.
printf 'FROM scratch\nRUN one \\ \nRUN two\n' > "$WORK/space_after_backslash"
assert_eq "trailing-space:is-not-a-continuation" "3" "$(count "$WORK/space_after_backslash")"

# Blank lines and comment lines between instructions are simply skipped.
fixture blanks <<'EOF'
# a comment

FROM scratch


# another
RUN one
EOF
f="$WORK/blanks"
assert_eq "blanks:skipped" "2" "$(count "$f")"

# CRLF, which is what a Windows developer with core.autocrlf gets in their working tree. A stray
# \r would break the continuation test and put an invisible character in every instruction it
# compared against podman -- so every label would go off, on that machine only.
printf 'FROM scratch\r\nRUN one \\\r\n    two\r\n' > "$WORK/crlf"
assert_eq "crlf:counts-the-same"    "2"                          "$(count "$WORK/crlf")"
assert_eq "crlf:text-has-no-stray-cr" "FROM scratch|RUN one two" "$(texts "$WORK/crlf")"

# ─── the markers ───────────────────────────────────────────────────────────────
# Sticky: a marker names its own instruction and every one after it until the next marker. That
# is what lets ~13 markers name 23 steps, and what makes each version ARG share a label with the
# layer it feeds.
fixture sticky <<'EOF'
####> First thing...
FROM scratch
ARG X=1
RUN one
####> Second thing...
RUN two
RUN three
EOF
f="$WORK/sticky"
assert_eq "sticky:applies-until-the-next-marker" \
          "First thing...|First thing...|First thing...|Second thing...|Second thing..." \
          "$(labels "$f")"

# Instructions before the first marker have no name rather than a wrong one. The real
# Containerfile cannot reach this state -- 10-static.sh requires a marker above FROM -- but a
# fixture can, and inventing a label here would be inventing one anywhere.
fixture before_first <<'EOF'
FROM scratch
####> Later...
RUN one
EOF
f="$WORK/before_first"
assert_eq "sticky:no-label-before-the-first-marker" "|Later..." "$(labels "$f")"

# Padding is trimmed, so a marker can be aligned with the prose around it.
fixture padding <<'EOF'
####>    Spaced out...
FROM scratch
EOF
f="$WORK/padding"
assert_eq "marker:text-is-trimmed" "Spaced out..." "$(labels "$f")"

# An empty marker clears the label rather than crashing or keeping the previous one. A blank
# name is a step the meter says nothing about, which is what an author asked for by writing it.
fixture empty_marker <<'EOF'
####> Something...
FROM scratch
####>
RUN one
EOF
f="$WORK/empty_marker"
assert_eq "marker:empty-clears-the-label" "Something...|" "$(labels "$f")"

# A MARKER INSIDE A CONTINUATION IS JUST A COMMENT, which is what podman sees. It must not
# become a label -- the step it appears to name is already underway -- and must not split the
# instruction it is buried in.
fixture marker_in_continuation <<'EOF'
####> Real...
FROM scratch
RUN one \
####> Not a label...
    two
EOF
f="$WORK/marker_in_continuation"
assert_eq "marker-in-continuation:does-not-label"  "Real...|Real..." "$(labels "$f")"
assert_eq "marker-in-continuation:does-not-split"  "2"               "$(count "$f")"

# ─── degenerate input ──────────────────────────────────────────────────────────
# Nothing here should produce a crash, a stack trace or a nonzero exit: the meter must never be
# able to stop a build, and that starts with the parse.
: > "$WORK/empty"
assert_ok "empty:exits-zero"     "$REPO/cs193v" --dev-steps "$WORK/empty"
assert_eq "empty:parses-to-nothing" "0" "$(count "$WORK/empty")"

fixture markers_only <<'EOF'
####> A label with nothing to name...
# and a comment
EOF
f="$WORK/markers_only"
assert_ok "markers-only:exits-zero" "$REPO/cs193v" --dev-steps "$f"
assert_eq "markers-only:parses-to-nothing" "0" "$(count "$f")"

# A file that ends mid-continuation still yields the text it read. Left empty, that instruction
# would compare as blank against podman and switch every label off.
printf 'FROM scratch\nRUN one \\\n' > "$WORK/truncated"
assert_eq "truncated:last-instruction-keeps-its-text" \
          "FROM scratch|RUN one" "$(texts "$WORK/truncated")"

# A missing file is a launcher error, not a silent empty parse.
assert_fail "missing:reports-an-error" "$REPO/cs193v" --dev-steps "$WORK/does-not-exist"

# ─── the real Containerfile ────────────────────────────────────────────────────
# The fixtures above pin the rules; this pins the file the rules are applied to. The count is
# asserted against podman itself in 00-release-gates.sh, which is the only place it can be.
#
# A LITERAL ON PURPOSE, unlike the forward counts #46 derived: deriving this from the same parse
# it is checking would assert nothing at all. It is a canary -- add a layer and the number moves,
# so you are made to look. Codex moved it by TWO, from 22, because `ARG` is an instruction in its
# own right and takes a step of its own beside the `RUN`.
assert_eq "real:parses-every-instruction" "24" "$(count "$PRIVATE/Containerfile")"
assert_match "real:first-step-is-the-base-image" \
             '^1	Downloading the base image\.\.\.	FROM ubuntu:' "$(steps "$PRIVATE/Containerfile")"
# No instruction text may be empty: that is what a mis-joined continuation looks like, and it
# would read as a mismatch against podman and take the labels down with it.
blank="$(steps "$PRIVATE/Containerfile" | awk -F'\t' '$3 == "" { print $1 }')"
assert_eq "real:no-instruction-parses-to-nothing" "" "$blank"

rm -rf "$WORK"
