#!/usr/bin/env bash
# TIER: unit
#
# The test harness's own hygiene, one property at a time. No podman, no image, no network.
#
# WHY THIS EXISTS AS ITS OWN SUITE. Nothing else here measures what a run COSTS the machine it
# runs on, and #76 is what that blind spot bought. repo_copy carried the developer's projects/
# into every fixture copy — 58 MB where the course tree is 780 KB — and then leaked all of them,
# because the snapshot it memoises and the directories it registers for cleanup were both plain
# variable assignments inside the `$( )` that every one of its callers wraps it in. 2.9 GB of a
# 3.7 GB tmpfs, and $CS193V_RESULTS lives on that same filesystem: the run that filled it went
# on printing PASS for results it had already failed to record.
#
# So the two halves below are one bug. What a fixture copy contains, and what happens when the
# file the summary is counted from cannot be written.
#
# A FIXTURE $REPO, NOT THE CHECKOUT. What a copy of the real tree contains depends on what the
# developer has been working in, so an assertion about it would pass or fail for reasons that
# have nothing to do with this code — and on a clean checkout the leak is invisible. The fixture
# carries one of each thing the exclusion list names, plus a payload big enough that a size
# assertion cannot be a near miss.
#
# EVERY CHECK BELOW ANSWERS WITH A LISTING, NOT WITH AN ABSENCE. `assert_no_file` on a copy that
# was never made passes, and so does a size ceiling measured with `du` on a missing directory —
# both were green against the broken code the first time this suite ran. The listing form cannot
# be satisfied by nothing having happened.

set -u
. "$(dirname -- "$0")/lib/assert.sh"

REAL_REPO="$REPO"
WORK="$(new_tmpdir)"
trap 'chmod 755 "$WORK/readonly" 2>/dev/null; rm -rf "$WORK"' EXIT

# EVERYTHING BELOW LANDS IN $WORK, the helpers' own scratch included: half the assertions here
# are "it left nothing behind", and against the real TMPDIR they would be asking a question
# about whatever else on this machine happens to write there. Exported BEFORE podman-shim.sh is
# sourced, because that reads TMPDIR once, at source time, to pin SHIM_HOST_TMPDIR.
export TMPDIR="$WORK"
. "$(dirname -- "$0")/lib/podman-shim.sh"

# What is in the scratch dir, as one line, so an assertion can be an equality rather than a
# handful of absences — which is the form that cannot pass because nothing happened. Names only:
# the pid tags and the random suffixes are the callers' business.
scratch_dirs() {                      # scratch_dirs PREFIX... -> matching names, sorted, spaced
    local p d
    for p in "$@"; do
        for d in "$WORK/$p".*; do
            [ -d "$d" ] && printf '%s\n' "${d##*/}"
        done
    done | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//'
}
count_dirs() {                        # count_dirs PREFIX -> how many $WORK/PREFIX.* exist
    local d n=0
    for d in "$WORK/$1".*; do [ -d "$d" ] && n=$((n + 1)); done
    printf '%s' "$n"
}

# ─── the fixture ───────────────────────────────────────────────────────────────
FIX="$WORK/course"
mkdir -p "$FIX/.config" "$FIX/.private/tests/lib" "$FIX/.git/objects" "$FIX/projects/bulk"
cp "$REAL_REPO/cs193v" "$FIX/cs193v"
printf -- '--memory=2048m\n'                            > "$FIX/.config/container.args"
printf 'a fresh checkout has this and nothing else\n'   > "$FIX/projects/.gitkeep"
printf 'FROM debian\n'                                  > "$FIX/.private/Containerfile"
: > "$FIX/.private/tests/lib/assert.sh"
: > "$FIX/.git/objects/pack"
# 8 MB, standing in for the node_modules tree the live tier leaves in projects/. Big enough
# that "the copy is small" means something, and free in a tmpfs.
dd if=/dev/zero of="$FIX/projects/bulk/node_modules.bin" bs=1024 count=8192 2>/dev/null

REPO="$FIX"

# ─── what a fixture copy of the course tree contains ───────────────────────────
D="$WORK/copy"
assert_ok "copy:succeeds" copy_course_tree "$D"

# ONE EQUALITY FOR THE WHOLE TREE. Every property #76 is about is in this line: the launcher and
# the args file are there, .private survives but .private/tests does not, .git is gone, and
# projects/ holds .gitkeep and NOT the payload — which is what a fresh checkout looks like. The
# launcher would create projects/ if it were missing (`[ -d "$WORKSPACE" ] || mkdir -p`) and so
# would the installer, but a fixture that differs from a checkout is a fixture that can lie.
want="./.config ./.config/container.args ./.private ./.private/Containerfile"
want="$want ./cs193v ./projects ./projects/.gitkeep"
got="$( cd "$D" 2>/dev/null && find . -mindepth 1 | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//' )"
assert_eq "copy:is-a-fresh-checkout-and-nothing-more" "$want" "$got"

# THE SIZE, not just the names. The listing above is the leak we know about; this is the one that
# catches whatever lands in the course directory next. 8 MB of payload in the fixture against a
# 2 MB ceiling, so it cannot fail narrowly — and a zero is a failure, not a pass, because that is
# what `du` on a directory that was never created reports.
size_kb="$(du -sk "$D" 2>/dev/null | awk '{print $1}')"
if [ -n "${size_kb:-}" ] && [ "$size_kb" -gt 0 ] && [ "$size_kb" -lt 2048 ]; then
    pass "copy:is-small"
else
    fail "copy:is-small" "du reports ${size_kb:-nothing} KB for $D"
fi
record "copy:size-kb" "${size_kb:-nothing}"

# ─── repo_copy, called the way its callers call it ─────────────────────────────
# THE `$( )` IS THE POINT OF THESE. Every call site is `COPY="$(repo_copy)"`, which is a
# subshell, so anything repo_copy keeps in a variable is thrown away the moment it returns:
# the memo never fired and every call re-tarred the tree, and shim_cleanup was never told
# about a single directory. Called any other way, these would test something no suite does.
A="$(repo_copy)"
B="$(repo_copy)"
assert_ne   "repo-copy:hands-out-a-fresh-directory"   "$A"        "$B"
assert_file "repo-copy:the-copy-holds-a-launcher"     "$B/cs193v"
assert_file "repo-copy:the-copy-holds-the-args-file"  "$B/.config/container.args"
assert_eq   "repo-copy:snapshots-once-across-subshells" "1" "$(count_dirs cs193v-snap)"
assert_eq   "repo-copy:one-directory-per-call"          "2" "$(count_dirs cs193v-repo)"

# ─── and cleanup removes every one of them ─────────────────────────────────────
# A SHIM MADE INSIDE A COMMAND SUBSTITUTION COUNTS, and this shape is not hypothetical:
# 25-installer.sh's run_with_tarball calls shim_new and is itself called as
# `out="$(run_with_tarball ...)"`, three times. Registering a directory in a variable there
# reaches nothing — the same subshell that hid repo_copy's copies — and the sweep found exactly
# those three sitting in /tmp after a green run.
shim_new
sub="$(shim_new; printf '%s' "$SHIM")"
assert_ok "cleanup:the-subshell-shim-was-really-made" test -d "$sub"
shim_cleanup
assert_eq "cleanup:removes-everything-it-made" "" "$(scratch_dirs cs193v-snap cs193v-repo cs193v-shim)"
# shim_new redirects TMPDIR into the shim it just made, and shim_cleanup has now deleted it —
# so the runner fixture further down would mktemp into a directory that no longer exists.
export TMPDIR="$WORK"

# ─── the sweep that covers a KILLED run ────────────────────────────────────────
# BY PID, NOT BY AGE, and that is the whole design. The scratch directory is shared — one /tmp,
# and CS193V_INSTANCE does not namespace it — so a second checkout of this repo on the same
# machine can have a run of these very suites working in there. A blanket glob would delete one
# of its directories mid-assertion. Each name carries the pid of the suite that made it, and "is
# that suite still alive" is the test.
#
# An untagged name — one from before the tag existed — is left alone rather than guessed at:
# there is nothing in it to ask a question of, and a wrong guess deletes a running suite's
# scratch directory.
sleep 30 & DEAD=$!; kill "$DEAD" 2>/dev/null; wait "$DEAD" 2>/dev/null
mkdir -p "$WORK/cs193v-shim.$DEAD.aaaaaa" "$WORK/cs193v-repo.$$.bbbbbb" "$WORK/cs193v-shim.XXXXXX"
assert_eq "sweep:counts-what-it-removed" "1" "$(shim_sweep_stale)"
assert_eq "sweep:removes-the-dead-suites-directory-and-only-that" \
          "cs193v-repo.$$.bbbbbb cs193v-shim.XXXXXX" \
          "$(scratch_dirs cs193v-snap cs193v-repo cs193v-shim)"
rm -rf "$WORK/cs193v-shim.XXXXXX" "$WORK/cs193v-repo.$$.bbbbbb"

# ─── a results file that cannot be written is FATAL, not silent ────────────────
# THE FAILURE THIS PREVENTS IS A WRONG NUMBER, not a lost line. run-tests.sh counts the file,
# never the screen, so a printf that fails and is ignored drops a result while the terminal
# still says PASS — and it drops FAIL as readily, so a full disk gets reported as `0 fail` by a
# run that then exits 0.
#
# A READ-ONLY DIRECTORY rather than /dev/full, which macOS does not have, and this suite runs
# on the bash 3.2 a TA's Mac ships. Root ignores the mode, so under uid 0 there is nothing here
# to measure. The needle is OUR sentence, not bash's own "Permission denied" — that one is
# printed today, by the version of this that loses the result and carries on.
if [ "$(id -u)" = 0 ]; then
    skip "emit:aborts-when-the-results-file-cannot-be-written" "root ignores a read-only directory"
else
    RO="$WORK/readonly"
    mkdir -p "$RO"
    chmod 555 "$RO"
    cat > "$WORK/child.sh" <<'CHILD'
set -u
. "$1"
pass "child:first"
pass "child:second"
CHILD
    out="$(CS193V_RESULTS="$RO/results.tsv" CS193V_SUITE=child \
           bash "$WORK/child.sh" "$TESTS_DIR/lib/assert.sh" 2>&1; printf '[rc=%s]' "$?")"
    assert_contains "emit:says-the-results-are-being-lost" "results are being LOST" "$out"
    assert_contains "emit:names-the-file-it-could-not-write" "$RO/results.tsv" "$out"
    assert_contains "emit:exits-97"                          "[rc=97]"        "$out"
    # It stops AT the first assertion: a suite that carried on would produce a transcript full
    # of results none of which reached the file.
    assert_not_contains "emit:stops-at-the-first-assertion"   "child:second"   "$out"
    chmod 755 "$RO"
fi

# ─── a suite that DIES must fail the run ───────────────────────────────────────
# `run_suite` is `bash "$1" || true` and the verdict is the FAIL count in the file, so a suite
# that exits without finishing — which is what _emit now does on a full disk — costs the run its
# results and nothing else. Driven against a COPY of the runner with two fake suites beside it,
# because run-tests.sh discovers suites from its own directory and the real tree must not
# contain a suite that exits non-zero.
RUN="$WORK/runner"
mkdir -p "$RUN"
cp "$TESTS_DIR/run-tests.sh" "$RUN/run-tests.sh"
cat > "$RUN/01-fine.sh" <<'EOF'
# TIER: static
printf 'PASS\t01-fine.sh\tfake:finished\n' >> "$CS193V_RESULTS"
EOF
cat > "$RUN/02-dies.sh" <<'EOF'
# TIER: static
printf 'PASS\t02-dies.sh\tfake:got-this-far\n' >> "$CS193V_RESULTS"
exit 3
EOF
# And the whole chain, end to end, which is what #76 is actually about: a suite whose results
# file cannot be written dies at its first assertion, the runner names it, and the run fails.
# Each half is asserted above; this is the two of them wired together, driven for real.
cat > "$RUN/03-cannot-record.sh" <<'EOF'
# TIER: static
export CS193V_RESULTS=/nonexistent-cs193v-dir/results.tsv
. "$ASSERT_LIB"
pass "fake:this-cannot-be-recorded"
EOF
out="$(cd "$RUN" && NO_COLOR=1 ASSERT_LIB="$TESTS_DIR/lib/assert.sh" \
       bash ./run-tests.sh --tier static 2>&1; printf '[rc=%s]' "$?")"
# The suite's NAME appears in the header of any run, so the needle is the name AND what became
# of it. Today the whole run reports `0 fail` and exits 0 with a suite that died in it.
assert_match    "runner:names-the-suite-that-died"  '02-dies\.sh +exited 3' "$out"
assert_contains "runner:a-dead-suite-fails-the-run" "[rc=1]"                "$out"
# And it still reports what DID run: the point is a trustworthy number, not a blank verdict.
assert_contains "runner:still-counts-what-ran"      "2 pass"                "$out"
assert_match    "runner:names-the-one-that-could-not-record" '03-cannot-record\.sh +exited 97' "$out"
assert_contains "runner:says-results-were-lost"    "results were LOST"     "$out"
