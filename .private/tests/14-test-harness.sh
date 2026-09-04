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
    done | LC_ALL=C sort | do_tr '\n' ' ' | sed 's/ *$//'
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

# THE SIX FILES A CHECKOUT ACQUIRES THE FIRST TIME IT IS LAUNCHED. A fresh checkout has none
# of them, GitHub's archive endpoint holds none of them (they are git-ignored), and until they
# were in this fixture the assertion below could not have noticed a copy carrying them: it was
# measuring a tree with nothing to leak. The five keys are the load-bearing ones -- cs193v:1415
# says a private key must be generated per machine and never shipped, and a copy that arrives
# with one means tunnel_keys()'s `[ -f ] ||` guard skips the keygen in every test that follows.
printf 'PRIVATE KEY\n'          > "$FIX/.config/tunnel-key"
printf 'ssh-ed25519 pub\n'       > "$FIX/.config/tunnel-key.pub"
printf 'PRIVATE HOST KEY\n'     > "$FIX/.config/tunnel-host-key"
printf 'ssh-ed25519 hostpub\n'   > "$FIX/.config/tunnel-host-key.pub"
printf 'cs193v-tunnel ssh-ed25519 hostpub\n' > "$FIX/.config/tunnel-known-hosts"
printf -- '--memory=9999m\n'     > "$FIX/.config/local.args"

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
# .config/container.args IS in that list and the five tunnel files and local.args are NOT,
# which is the whole point: .config is excluded wholesale and its one TRACKED file put back,
# the same treatment projects/ gets. Naming the six to exclude instead would leak the seventh.
got="$( cd "$D" 2>/dev/null && find . -mindepth 1 | LC_ALL=C sort | do_tr '\n' ' ' | sed 's/ *$//' )"
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
# run-tests.sh sources lib/portable.sh from its OWN directory -- above the option loop, because
# that loop uses do_tr -- so a copy of the script alone cannot start. Symlinked rather than
# copied: this fixture is about the runner's behaviour, not the libraries'.
ln -s "$TESTS_DIR/lib" "$RUN/lib"
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

# ─── a CHECKER that could not run must fail, not pass ──────────────────────────
# THE SAME DEFECT AS #76, one layer in. box_problems and render_pty both pipe their input
# through `python3 -c`, and both are read by assertions whose HAPPY answer is the empty string:
# `assert_eq NAME "" "$(... | box_problems)"` and `assert_not_contains NAME needle "$(...
# | render_pty)"`. So an interpreter that dies prints nothing, and nothing is the happy answer.
#
# MEASURED ON 740a14f, not imagined (#79): a fake python3 that printed a traceback and exited 1
# left 26 assertions in the cheap lane passing with no checker having run — nine box_problems
# sites and ten render_pty-fed negatives among them. `require_cmd python3` guarded three of
# those call sites and caught none of it: the sabotaged interpreter EXISTS, so `command -v`
# was satisfied.
#
# DRIVEN THROUGH A CHILD, for the reason the results-file fixture above is: the assertion under
# test has to really FAIL, and a failing assertion in this process would fail this suite. The
# child sources assert.sh with its own $CS193V_RESULTS and its own PATH.
#
# THIS IS THE DURABLE HALF OF AN AUDIT, and the other half is written down rather than automated:
# VERIFICATION.md §A.15 carries the differential-sabotage recipe that found the twenty-six, the
# before-and-after counts, and the argument for why it is a hand-run audit instead of a tier
# (`lane_of` would serialise a `sabotage` tier behind the container, and DEFAULT_TIERS would have
# to exclude it -- an unrun gate being the same defect over again). What lives HERE is the part
# that costs milliseconds and therefore runs on every single run.
FAKEBIN="$WORK/fake-dead"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/python3" <<'FAKE'
#!/bin/sh
printf 'Traceback (most recent call last):\n  SyntheticError: sabotaged interpreter\n' >&2
exit 1
FAKE
chmod 755 "$FAKEBIN/python3"

# BOTH SHAPES, spelled exactly as the suites spell them. The box is a closed one and the
# transcript is clean, so with a working interpreter both of these PASS — which is what the
# control run below is for.
cat > "$WORK/checker.sh" <<'CHILD'
set -u
. "$1"
assert_eq "box:closed" "" "$(printf '┏━━┓\n┃ x┃\n┗━━┛\n' | box_problems)"
assert_not_contains "screen:no-escape-parameters" "1;32m" "$(printf 'hello\n' | render_pty)"
CHILD

# THE SENTINEL IS RENAMED ON THE WAY IN, and finding out why is worth the line: the child's
# report QUOTES $CHECKER_DIED in its failure detail, and the assertions below are the same
# assertions that now refuse any value carrying it -- so reading the child's output raw fails
# every one of them on the strength of the thing it is reporting. Renaming it leaves the rest of
# the detail, including which command died, exactly as the child wrote it.
out="$(PATH="$FAKEBIN:$PATH" CS193V_RESULTS="$WORK/checker.tsv" CS193V_SUITE=checker \
       bash "$WORK/checker.sh" "$TESTS_DIR/lib/assert.sh" 2>/dev/null \
       | sed "s/$CHECKER_DIED/A-CHECKER-DIED-HERE/g")"
assert_contains "checker:a-dead-box-checker-fails"  "FAIL  box:closed"                  "$out"
assert_contains "checker:a-dead-pty-replayer-fails" "FAIL  screen:no-escape-parameters" "$out"
# AND IT NAMES WHAT DIED, with the status. Without this the next person reads a bare
# "expected: / actual:" mismatch and goes hunting for a box that was never drawn.
assert_contains "checker:says-which-command-died"   "exit 1 from: python3"              "$out"

# THE CONTROL, and it is not optional: a fixture whose box art is broken or whose transcript
# is dirty would fail both assertions above for the wrong reason, and this pair of tests would
# then pass forever no matter what assert.sh did.
ctl="$(CS193V_RESULTS="$WORK/checker-ok.tsv" CS193V_SUITE=checker \
       bash "$WORK/checker.sh" "$TESTS_DIR/lib/assert.sh" 2>/dev/null)"
assert_not_contains "checker:the-fixture-is-green-with-a-real-interpreter" "FAIL" "$ctl"

# ─── ...and a POISONED interpreter is caught at the door ───────────────────────
# The other half, and the one no sentinel can see: an interpreter that exits 0 and prints
# something else. run_checker cannot help — there is no failure to notice — so this is what
# require_python3 is for, and why require_cmd is not enough on its own.
POISONBIN="$WORK/fake-poison"
mkdir -p "$POISONBIN"
cat > "$POISONBIN/python3" <<'FAKE'
#!/bin/sh
echo SABOTAGEPOISON
exit 0
FAKE
chmod 755 "$POISONBIN/python3"

cat > "$WORK/poison.sh" <<'CHILD'
set -u
. "$1"
require_python3
pass "poison:got-past-the-guard"
CHILD
out="$(PATH="$POISONBIN:$PATH" CS193V_RESULTS="$WORK/poison.tsv" CS193V_SUITE=poison \
       bash "$WORK/poison.sh" "$TESTS_DIR/lib/assert.sh" 2>&1; printf '[rc=%s]' "$?")"
assert_contains     "python3:a-poisoned-interpreter-is-rejected" "FAIL  require:python3" "$out"
assert_contains     "python3:the-guard-aborts-the-suite"         "[rc=1]"                "$out"
assert_not_contains "python3:nothing-runs-after-the-guard"       "poison:got-past"       "$out"
# And it lets a REAL interpreter through, or every suite that calls it is dead on arrival.
out="$(CS193V_RESULTS="$WORK/python3-ok.tsv" CS193V_SUITE=poison \
       bash "$WORK/poison.sh" "$TESTS_DIR/lib/assert.sh" 2>&1)"
assert_contains "python3:a-real-interpreter-passes-the-guard" "PASS  poison:got-past-the-guard" "$out"

# ─── assert_fail must not accept "could not run" as a failure ─────────────────
# 125, 126 and 127 are not the command failing, they are the command never happening: podman
# refusing before it started a container, a file that is not executable, a binary that is not
# installed. Six `podman run --rm` sites in 50-image.sh are assert_fails, so a podman that
# cannot start the throwaway made every one of them green with no container created — and
# `srv_up` in 70-sighup.sh is a bare curl, which exits 127 if curl is missing.
cat > "$WORK/exits.sh" <<'CHILD'
set -u
. "$1"
assert_fail "rc1:is-a-real-failure"  sh -c 'exit 1'
assert_fail "rc125:cannot-be-run"    sh -c 'exit 125'
assert_fail "rc126:cannot-be-run"    sh -c 'exit 126'
assert_fail "rc127:cannot-be-run"    sh -c 'exit 127'
assert_fail "rc0:succeeded"          sh -c 'exit 0'
CHILD
out="$(CS193V_RESULTS="$WORK/exits.tsv" CS193V_SUITE=exits \
       bash "$WORK/exits.sh" "$TESTS_DIR/lib/assert.sh" 2>&1)"
assert_contains "assert-fail:an-ordinary-failure-still-passes" "PASS  rc1:is-a-real-failure" "$out"
assert_contains "assert-fail:rejects-125" "FAIL  rc125:cannot-be-run" "$out"
assert_contains "assert-fail:rejects-126" "FAIL  rc126:cannot-be-run" "$out"
assert_contains "assert-fail:rejects-127" "FAIL  rc127:cannot-be-run" "$out"
assert_contains "assert-fail:still-rejects-success" "FAIL  rc0:succeeded" "$out"

# ─── a record carries its VALUE into the results file ─────────────────────────
# WHY THIS IS THE HARNESS'S BUSINESS AND NOT COSMETIC. `record` is how every platform-dependent
# number reaches a human, and the line it wrote was `REC<TAB>suite<TAB>name` with the value
# dropped — so a diff of two runs' results could not see a record go from "46 of 46" to nothing.
# That is exactly how #34 and #46 lied: a number that looked measured and was not.
cat > "$WORK/rec.sh" <<'CHILD'
set -u
. "$1"
record "rec:a-number"    "46 of 46"
record "rec:two-lines"   "$(printf 'first\tsecond\nthird\n')"
record "rec:nothing"     ""
CHILD
CS193V_RESULTS="$WORK/rec.tsv" CS193V_SUITE=rec \
    bash "$WORK/rec.sh" "$TESTS_DIR/lib/assert.sh" >/dev/null 2>&1
assert_eq "record:the-value-is-the-fourth-field" "46 of 46" \
          "$(awk -F'\t' '$3 == "rec:a-number" { print $4 }' "$WORK/rec.tsv")"
# ONE LINE PER RESULT is the property the whole file rests on, so newlines and tabs in a value
# are flattened rather than carried through.
assert_eq "record:a-multiline-value-stays-one-line" "first second third" \
          "$(awk -F'\t' '$3 == "rec:two-lines" { print $4 }' "$WORK/rec.tsv")"
assert_eq "record:the-file-is-still-one-line-per-result" "3" "$(wc -l < "$WORK/rec.tsv" | do_tr -d ' ')"
# An EMPTY value is still four fields: "the value went away" has to be visible as an empty
# field, which is the whole point of putting it on the wire.
assert_eq "record:an-empty-value-is-still-a-field" "4" \
          "$(awk -F'\t' '$3 == "rec:nothing" { print NF }' "$WORK/rec.tsv")"

# ─── machine_flags, and the SELinux label it takes off a nested fixture (#119) ──
#
# WHY THIS IS A UNIT TEST AND NOT ONLY A BEHAVIOURAL ONE. The arm it covers is decided by whether
# the HOST has SELinux, so on the machines this suite is usually developed on the interesting
# branch is the one that never runs. A fixture case can only ever exercise the local answer;
# these four calls exercise both answers on any machine, which is the same argument
# 10-static.sh's `,z` rules make for reading the source instead of launching a container.
#
# THE DOOR IS FORCED, NOT OBSERVED. $VT_SELINUX is read at call time, so setting it here reaches
# the arm without touching lib/shared.sh's probe or this host's real posture.
#
# EXACT LISTS, NOT `does it contain`, and that is the whole design of this block. The obvious
# spelling -- assert the withheld case does NOT contain label=disable -- passes when machine_flags
# REFUSES the call, because it clears MACHINE_FLAGS before it validates and an absence assertion
# is satisfied by an empty array. That is lib/assert.sh's vacuous-green shape exactly, and it was
# green against a deliberately broken call while this block was being written. An equality says
# both halves at once: the flag went, and nothing else moved.
mf() {                                # mf VT_SELINUX DROP BASE -> the flag list, or REFUSED-N
    ( set -u
      # shellcheck source=lib/sandbox.sh
      . "$TESTS_DIR/lib/sandbox.sh"
      VT_SELINUX="$1"
      machine_flags "$2" linux no "$3" || { printf 'REFUSED-%s' "$?"; exit 0; }
      printf '%s ' ${MACHINE_FLAGS[@]+"${MACHINE_FLAGS[@]}"} | sed 's/ $//' )
}
MF_NEST='--cap-add=SYS_ADMIN --security-opt unmask=/proc/* --device /dev/fuse --device /dev/net/tun'

assert_eq "flags:on-selinux-a-nested-base-runs-with-the-label-off" \
          "$MF_NEST --security-opt label=disable" "$(mf yes '' machine)"
# THE OTHER HALF OF lib/shared.sh's RULE -- fix Fedora without changing anything else. Off
# SELinux this must be byte-identical to what every machine got before #119, which is what makes
# the comparison with $MF_NEST alone the assertion rather than a spot check.
assert_eq "flags:off-selinux-the-flag-set-is-unchanged" "$MF_NEST" "$(mf '' '' machine)"
assert_eq "flags:the-drop-name-takes-only-the-label-away" "$MF_NEST" "$(mf yes label machine)"
# TWO DROPS AT ONCE, because sandbox_run appends `label` to whatever a case already asked for and
# sb-noans really does ask for `sysadmin`. If the append clobbered instead of adding, this is
# where it shows.
assert_eq "flags:two-drops-compose" \
          "--security-opt unmask=/proc/* --device /dev/fuse --device /dev/net/tun" \
          "$(mf yes sysadmin,label machine)"
# A BASE THAT DIES IN SURVEY GETS NONE OF IT, label included -- the arm is inside the nesting gate.
assert_eq "flags:a-base-that-does-not-nest-gets-nothing-at-all" "" "$(mf yes '' debian)"
# ...and a typo is refused rather than silently granting the thing it meant to remove.
assert_eq "flags:an-unknown-drop-name-is-refused" "REFUSED-2" "$(mf yes labl machine)"

# ─── ...and lib/shared.sh's one door answers both of its consumers ─────────────
#
# STUBBED, so both branches run on every machine. The door is `command -v selinuxenabled &&
# selinuxenabled`, so a directory at the front of PATH holding an executable of that name decides
# it either way -- and its ABSENCE from a PATH with nothing else on it decides the other.
sel_door() {                          # sel_door yes|no|absent -> "$VT_SELINUX|$VT_MOUNT_Z"
    ( set -u
      d="$WORK/seldoor"; rm -rf "$d"; mkdir -p "$d"
      case "$1" in
          absent) : ;;
          *)      printf '#!/bin/sh\n[ "%s" = yes ]\n' "$1" > "$d/selinuxenabled"
                  chmod +x "$d/selinuxenabled" ;;
      esac
      PATH="$d"; export PATH
      # shellcheck source=lib/shared.sh
      . "$TESTS_DIR/lib/shared.sh"
      printf '%s|%s' "$VT_SELINUX" "$VT_MOUNT_Z" )
}
assert_eq "door:an-selinux-host-relabels-and-drops-the-label" "yes|,z" "$(sel_door yes)"
# INSTALLED BUT DISABLED is its own case: the tool is there and says no, which must answer the
# same as no tool at all. Both were one expression before #119 and are now read by two consumers,
# so a disagreement between them is what this pair exists to catch.
assert_eq "door:selinux-installed-but-off-decides-neither" "|" "$(sel_door no)"
assert_eq "door:no-selinuxenabled-at-all-decides-neither" "|" "$(sel_door absent)"

# ─── a ceiling that fires says so, in the results file as well (#130) ──────────
#
# WHY THIS IS A UNIT TEST. The thing under test decides which of podman's exit statuses mean "a
# ceiling killed this run", and the host decides which of them a real run produces -- so a
# behavioural case can only ever exercise the one answer this machine happens to give. 26's
# ceiling case drives the real pipeline and sees 255; the two backstop arms are reachable there
# only by breaking podman on purpose. These four calls exercise all of them on any machine, which
# is the same argument the machine_flags block above makes.
#
# THE 137 ARM IS THE POINT. `timeout --kill-after` returns 137, not 124, whenever it has to
# escalate to SIGKILL -- `timeout --help` says so, and measured against a real attached podman
# that is what the outer backstop ALWAYS returns, because podman does not exit on TERM while it is
# attached. So sandbox_run's original 124 arm was dead in exactly the case its comment said it
# existed for, and the container it was supposed to force-remove was left running.
#
# ITS OWN RESULTS FILE, the same trick the assert_fail and record blocks above use: the call being
# tested is one whose whole job is to FAIL, so it has to fail somewhere this suite is not counting.
cat > "$WORK/ceil.sh" <<'CHILD'
set -u
. "$1"
# shellcheck source=lib/sandbox.sh
. "$2"
sb_ceiling_note ceil "$4" 900 1000 cs193v-fixture-ceiling "$3"
printf 'RETURNED=%s\n' "$?"
CHILD

# A PARTIAL TRANSCRIPT TO APPEND TO, not an empty file: the marker is added to a run that printed
# something before it was killed, and `>` instead of `>>` would throw away the very output the
# marker exists to explain. Asserted below rather than trusted.
ceil_run() {                          # ceil_run RC -> RETURNED=n, and fills $WORK/ceil.{txt,tsv,podman}
    rm -rf "$WORK/ceilbin"; mkdir -p "$WORK/ceilbin"
    # THE DOOR IS FORCED: sb_ceiling_note's 124|137 arm removes the container by name, and a unit
    # test must see that call without a podman anywhere near it. A stub first on PATH logs the
    # arguments; its own output is discarded by the caller, so the log is the only witness.
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$WORK/ceil.podman" > "$WORK/ceilbin/podman"
    chmod +x "$WORK/ceilbin/podman"
    printf 'STEP 3/25: RUN apt-get update\n' > "$WORK/ceil.txt"
    : > "$WORK/ceil.tsv"; : > "$WORK/ceil.podman"
    ( PATH="$WORK/ceilbin:$PATH"; export PATH
      CS193V_RESULTS="$WORK/ceil.tsv" CS193V_SUITE=ceil \
          bash "$WORK/ceil.sh" "$TESTS_DIR/lib/assert.sh" "$TESTS_DIR/lib/sandbox.sh" \
               "$WORK/ceil.txt" "$1" 2>/dev/null )
}
ceil_said() {                         # ceil_said -> the transcript, one line
    tr '\n' ' ' < "$WORK/ceil.txt" | sed 's/ *$//'
}
ceil_results() {                      # ceil_results -> "STATUS name" per result
    awk -F'\t' '{ print $1, $3 }' "$WORK/ceil.tsv" | tr '\n' ' ' | sed 's/ *$//'
}

# ─── rc 0: nothing happened, and nothing is said about it ──────────────────────
# THE ARM THAT MUST STAY SILENT. Every sandbox_run in the suite passes through here, so an
# announcement on a healthy run would put a result on every one of them -- and a `podman rm -f`
# would destroy the container `podman diff` is about to read.
assert_eq "ceiling:a-run-that-finished-returns-0"        "RETURNED=0" "$(ceil_run 0)"
assert_eq "ceiling:a-run-that-finished-says-nothing"     "STEP 3/25: RUN apt-get update" "$(ceil_said)"
assert_eq "ceiling:a-run-that-finished-records-nothing"  "" "$(ceil_results)"
assert_eq "ceiling:a-run-that-finished-touches-no-container" "" "$(cat "$WORK/ceil.podman")"

# ─── rc 255: podman's own --timeout, which is the one a real hang produces ─────
assert_eq "ceiling:podmans-own-ceiling-returns-1" "RETURNED=1" "$(ceil_run 255)"
assert_says "ceiling:podmans-own-ceiling-names-itself" \
            "===SANDBOX-TIMEOUT=== podman killed the container at its 900s ceiling" "$(ceil_said)"
# APPENDED, not written over: the output the run managed before it died is the diagnosis.
assert_says "ceiling:podmans-own-ceiling-keeps-what-the-run-printed" \
            "STEP 3/25: RUN apt-get update" "$(ceil_said)"
# THE HALF A TRANSCRIPT MARKER CANNOT REACH (#130). _detail goes to stdout only, and half the
# assertions downstream read sb_section rather than the transcript -- so the results file is the
# only place a reader is guaranteed to see this.
assert_eq "ceiling:podmans-own-ceiling-is-a-named-result" \
          "FAIL ceil:the-run-stayed-inside-its-ceiling" "$(ceil_results)"
# NOT REMOVED HERE. sandbox_run is deliberately not --rm so `podman diff` can read the container;
# conmon has already stopped it, and sandbox_reap collects it.
assert_eq "ceiling:podmans-own-ceiling-leaves-the-container-for-diff" "" "$(cat "$WORK/ceil.podman")"

# ─── rc 124: the outer backstop, where no container ever existed ───────────────
# Measured: a podman that hangs BEFORE the container exists -- a stalled pull, a storage lock --
# dies on the backstop's TERM and returns 124. There is nothing to remove, and asking costs
# nothing, so both backstop arms are spelt the same way.
assert_eq "ceiling:the-outer-backstop-returns-1" "RETURNED=1" "$(ceil_run 124)"
assert_says "ceiling:the-outer-backstop-names-itself-and-its-rc" \
            "===SANDBOX-TIMEOUT=== the OUTER backstop fired at 1000s (rc 124)" "$(ceil_said)"
assert_eq "ceiling:the-outer-backstop-is-a-named-result" \
          "FAIL ceil:the-run-stayed-inside-its-ceiling" "$(ceil_results)"
assert_eq "ceiling:the-outer-backstop-removes-the-container-by-name" \
          "rm -f cs193v-fixture-ceiling" "$(cat "$WORK/ceil.podman")"

# ─── rc 137: the SAME backstop, escalated to SIGKILL -- and what it really returns ──
# THIS IS THE ARM THAT WAS MISSING, from nest_build and from sandbox_run alike. Measured against a
# real attached podman: the backstop's TERM is forwarded to the container's process instead of
# ending podman, --kill-after then escalates, and `timeout` reports 137 (128+9) rather than 124.
# The container survives its dead podman -- conmon keeps it -- so this is the arm where the
# removal is not a formality but the whole reason the arm exists.
assert_eq "ceiling:a-SIGKILLed-backstop-returns-1" "RETURNED=1" "$(ceil_run 137)"
assert_says "ceiling:a-SIGKILLed-backstop-names-itself-and-its-rc" \
            "===SANDBOX-TIMEOUT=== the OUTER backstop fired at 1000s (rc 137)" "$(ceil_said)"
assert_eq "ceiling:a-SIGKILLed-backstop-is-a-named-result" \
          "FAIL ceil:the-run-stayed-inside-its-ceiling" "$(ceil_results)"
assert_eq "ceiling:a-SIGKILLed-backstop-removes-the-abandoned-container" \
          "rm -f cs193v-fixture-ceiling" "$(cat "$WORK/ceil.podman")"

# ─── lib/ptyrun.py delivers keystrokes to a real pty ──────────────────────────
# WHY THIS IS THE HARNESS'S BUSINESS. Eleven sites drive an interactive program by piping
# keystrokes into a pty, and every one of them exists ONLY to deliver those keystrokes: the
# arrow keys menu() reads, the consent digits, the `exit\n` that ends a shell, the leading bare
# ENTER 80-launcher-live.sh:336 calls load-bearing. If the bytes arrive shifted, or one is
# eaten, the program takes its EOF/safe-default path instead — which is LOUD for a positive
# assertion and SILENT for the ~125 assert_says_not / assert_not_contains ones behind these
# helpers. So the delivery itself has to be measured, not assumed.
#
# MEASURED, NOT IMAGINED. This replaced script(1), which cannot do the job on a Mac:
# BSD script writes a VEOF to the master before forwarding piped stdin, so
#   printf 'one\ntwo\n' | script -q /dev/null sh -c 'read a; read b; ...'
# yields a=[] b=[one] -- every read shifted by one and the last keystroke never consumed.
# Unchanged by -k and -F. It also hard-errors on a fifo stdin ("tcgetattr/ioctl: Operation not
# supported on socket"), which is exactly what launcher_pty_silent_start feeds it.
PTYRUN="$TESTS_DIR/lib/ptyrun.py"

cat > "$WORK/reader.sh" <<'CHILD'
read a
read b
printf 'A=[%s] B=[%s]\n' "$a" "$b"
CHILD

# THE ASSERTION THAT CAUGHT script(1). Two lines in, both out, in order, neither shifted.
pr_out="$(printf 'one\ntwo\n' | python3 "$PTYRUN" "sh $WORK/reader.sh" 2>&1 | do_tr -d '\r')"
assert_says "ptyrun:both-lines-arrive-in-order" "A=[one] B=[two]" "$pr_out"
assert_says_not "ptyrun:no-eof-is-injected-first" "A=[]" "$pr_out"

# The child must be on a TERMINAL, or menu() takes its no-tty branch and reads nothing.
assert_says "ptyrun:the-child-sees-a-tty" "ISTTY" \
            "$(printf '\n' | python3 "$PTYRUN" 'test -t 0 && echo ISTTY' 2>&1 | do_tr -d '\r')"

# The child's status must survive. util-linux script needs -e for this and BSD script does it
# by default; a replacement that swallowed it would make every rc assertion behind these
# helpers meaningless.
assert_exit "ptyrun:propagates-the-child-status" 7 \
            sh -c "printf '\n' | python3 '$PTYRUN' 'exit 7' >/dev/null 2>&1"

# IT MUST BE A FILE, NOT A SHELL FUNCTION, because do_script hands it to `timeout`, which
# execvp()s its argument and cannot see a function. rc 127 with output on stderr is
# indistinguishable from a program that printed an error, so this is asserted rather than
# assumed.
assert_says "ptyrun:composes-with-timeout" "COMPOSED" \
            "$(printf '\n' | timeout 20 python3 "$PTYRUN" 'echo COMPOSED' 2>&1 | do_tr -d '\r')"

# A FIFO STDIN MUST WORK. launcher_pty_silent_start is built entirely on mkfifo, because a fifo
# held open by a non-writing writer is the only way to distinguish "the launcher is waiting for
# input" from "the launcher read EOF and carried on" (lib/podman-shim.sh:120-127). BSD script
# refuses one outright -- `script: tcgetattr/ioctl: Operation not supported on socket`, rc 1,
# nothing run -- so the flagship backgrounded site could not work on it at all.
mkfifo "$WORK/pf"
( exec 3>"$WORK/pf"; sleep 5 ) & PR_HOLDER=$!
assert_says "ptyrun:accepts-a-fifo-stdin" "FIFO-OK" \
            "$(timeout 10 python3 "$PTYRUN" 'echo FIFO-OK' < "$WORK/pf" 2>&1 | do_tr -d '\r')"
kill "$PR_HOLDER" 2>/dev/null || true

# BACKGROUNDED, $! MUST BE THE PTY OWNER AND ITS CHILD MUST BE THE COMMAND. Five sites background
# this and read $! to kill the session; 60-container.sh:250 records what getting it wrong costs:
# "killing that leaves script, podman and the tmux client happily alive -- so the window was
# never really closed and every assertion after it measures nothing." A shell FUNCTION
# backgrounded would give the subshell's pid, which is why ptyrun is a file.
#
# `sh -c 'sleep 30'` exec-optimises, so the pty owner's direct child is the command itself with
# no interposed shell -- which is what pgrep -P at 70-sighup.sh:213 depends on.
printf 'x\n' | python3 "$PTYRUN" 'sleep 30' >/dev/null 2>&1 &
PR_OWNER=$!
wait_until 10 sh -c "pgrep -P $PR_OWNER >/dev/null 2>&1" || true
PR_KID="$(pgrep -P "$PR_OWNER" 2>/dev/null | head -1)"
assert_eq "ptyrun:backgrounded-child-is-the-command" "sleep" \
          "$(ps -o comm= -p "${PR_KID:-0}" 2>/dev/null | sed 's#.*/##' | do_tr -d ' ')"
kill "$PR_OWNER" "$PR_KID" 2>/dev/null || true

# ─── lib/portable.sh: the wrappers, and the properties they exist for ─────────
# Each of these guards a MEASURED macOS failure, not a hypothetical one. The tools divide three
# ways and only the middle group is a mere flag: `timeout` and `ss` are ABSENT on a Mac, `script`
# and `stat` have DIFFERENT SIGNATURES, and `tr` is the same signature with a locale-dependent
# behaviour. So the wrappers are not one pattern applied five times.

# do_tr -- 88 of the 91 locale errors in an un-normalised macOS run were this. BSD tr aborts with
# "Illegal byte sequence" on a non-UTF-8 byte under a UTF-8 locale and TRUNCATES its output, so an
# assertion downstream compares against a short string and fails for a confusing reason.
# LC_ALL=C is the entire cure -- measured byte-identical to gtr on every form this tree uses -- and
# it must be per-invocation, because forcing it run-wide breaks 9 multibyte comparisons against
# messages.txt.
assert_eq "portable:do_tr-survives-an-invalid-utf8-byte" "X-Y" \
          "$(printf 'X\xe9Y' | do_tr '\350\351' '--')"
assert_eq "portable:do_tr-does-the-ordinary-thing-too" "a b" "$(printf 'a\tb' | do_tr '\t' ' ')"

# do_stat -- BSD stat has no -c at all; it spells the same question `-f %Lp`. Callers keep writing
# GNU -c and the wrapper resolves a binary that accepts it.
chmod 640 "$WORK/reader.sh"
assert_eq "portable:do_stat-reads-a-mode-with-gnu--c" "640" "$(do_stat -c %a "$WORK/reader.sh")"

# do_listeners -- THE SELF-CHECK THAT MAKES F15 IMPOSSIBLE TO REPEAT. macOS has no `ss`, and the
# twelve call sites all swallowed its absence with `2>/dev/null` and `|| true`, so a missing tool
# yielded EMPTY and every consumer reported a confident zero: fwd_owned_ports found nothing,
# no_forwards() was unconditionally true, and every "the forwards were released" assertion passed
# having measured nothing. netstat cannot fix it either -- macOS netstat has no pid option under
# any flag. So this asserts the one property every consumer needs: A PID, for a port we hold.
python3 -c '
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(1)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
time.sleep(60)
' "$WORK/port" &
PL_PID=$!
wait_until 10 sh -c "[ -s '$WORK/port' ]" || true
PL_PORT="$(cat "$WORK/port" 2>/dev/null)"
PL_LINE="$(do_listeners 2>/dev/null | grep ":${PL_PORT}	" | head -1)"
assert_says "portable:do_listeners-reports-the-address" "127.0.0.1:$PL_PORT" "$PL_LINE"
assert_says "portable:do_listeners-reports-a-pid"       "pid=$PL_PID"        "$PL_LINE"
kill "$PL_PID" 2>/dev/null || true
wait "$PL_PID" 2>/dev/null || true

# do_timeout -- macOS ships NO timeout(1) at all, so this is absence, not divergence. rc 124 is
# the ceiling's number and sandbox.sh:846 branches on it to clean up an abandoned container.
# NOT via `sh -c`: a child shell does not inherit a function, so that would assert 127 and pass
# for the wrong reason -- the same trap that made `do_timeout 120 do_script` unrunnable.
assert_exit "portable:do_timeout-returns-124-on-a-timeout" 124 do_timeout 1 sleep 5
assert_eq "portable:do_timeout-passes-stdout-through" "THROUGH" "$(do_timeout 10 echo THROUGH)"

# do_script SECS CMD -- the timeout goes INSIDE, so each caller keeps its own value. An earlier
# draft wrote `do_timeout 120 do_script "$cmd"`, which cannot run: timeout execvp()s and cannot
# see a shell function (rc 127), and the literal 120 discarded ${SG_TIMEOUT:-120} and the 600 at
# 90-setup-git-github.sh:178 -- a silent 5x truncation.
assert_says "portable:do_script-drives-a-pty-with-its-own-timeout" "A=[one] B=[two]" \
            "$(printf 'one\ntwo\n' | do_script 20 "sh $WORK/reader.sh" 2>&1 | do_tr -d '\r')"

# do_sha256 -- exposed as a VARIABLE too, because 25-installer.sh:595 calls it as
# `find ... -exec sha256sum {} +` and find needs a binary, not a function.
assert_eq "portable:do_sha256-hashes-stdin" \
          "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03" \
          "$(printf 'hello\n' | do_sha256 | cut -d' ' -f1)"
assert_ok "portable:DO_SHA256-is-a-usable-binary-path" sh -c '[ -x "$DO_SHA256" ]'

# ─── the preflight dependency gate (#124) ─────────────────────────────────────
# WHY A GATE AND NOT ASSERTIONS. A missing tool used to surface as ordinary failures scattered
# through the list -- 139 `timeout: command not found` in one macOS run -- so "your machine is
# wrong" was indistinguishable from "the code is wrong". 10-static.sh is even ORDERED around it
# (`:1602`: shellcheck checked last "because require_cmd aborts the suite"). These are not test
# cases: a missing dependency means the suite cannot ask its questions at all, so the gate
# refuses the run rather than recording a result.
#
# DRIVEN AGAINST A COPY of the runner, with a MINIMAL PATH built from symlinks. Absence cannot be
# faked by prepending something, so the fixture builds a PATH containing exactly the tools the
# gate wants and then removes one.
GATE="$WORK/gate"
mkdir -p "$GATE/bin"
cp "$TESTS_DIR/run-tests.sh" "$GATE/run-tests.sh"
# The copied runner sources lib/portable.sh from its own directory, so the libs have to be
# reachable. Symlinked rather than copied: this fixture is about the runner, not the libs.
ln -s "$TESTS_DIR/lib" "$GATE/lib"
cat > "$GATE/01-fine.sh" <<'EOF'
# TIER: static
printf 'PASS\t01-fine.sh\tfake:the-gate-let-me-run\n' >> "$CS193V_RESULTS"
EOF
for _t in bash sh env python3 shellcheck podman curl sed awk tr mktemp pgrep grep cat printf \
          timeout gtimeout stat gstat sha256sum gsha256sum ss lsof cut sort head tail wc \
          basename dirname rm mkdir ln chmod date sleep id od paste tee expr; do
    _p="$(command -v "$_t" 2>/dev/null)" && ln -s "$_p" "$GATE/bin/$_t" 2>/dev/null
done
unset _t _p

gate_run() {                          # gate_run [REMOVE_TOOL...] -> output with [rc=N]
    local t
    mkdir -p "$GATE/bin.save"
    for t in "$@"; do mv "$GATE/bin/$t" "$GATE/bin.save/$t" 2>/dev/null || true; done
    ( cd "$GATE" && env -i PATH="$GATE/bin" HOME="$WORK" TMPDIR="$WORK" NO_COLOR=1 \
        bash ./run-tests.sh --tier static 2>&1; printf '[rc=%s]' "$?" )
    for t in "$@"; do mv "$GATE/bin.save/$t" "$GATE/bin/$t" 2>/dev/null || true; done
}

# A MISSING TOOL MUST BE NAMED, AND FIXABLE. The name alone is a diagnosis without a remedy; the
# whole point of the gate over a bare failure is that it says what to type. Matched loosely
# enough to hold on both platforms -- `brew install shellcheck` and `apt install -y shellcheck`
# both satisfy it -- so this does not silently become a macOS-only assertion.
out="$(gate_run shellcheck)"
assert_contains "preflight:names-the-missing-tool"        "shellcheck" "$out"
assert_match    "preflight:offers-a-command-that-fixes-it" 'install .*shellcheck' "$out"
# ITS OWN EXIT CODE, so CI can tell a broken machine from a broken commit. 78 is EX_CONFIG from
# sysexits.h; 0/1/2/97/130 are all taken already -- see the table in run-tests.sh's header.
assert_contains "preflight:has-its-own-exit-code"         "[rc=78]"    "$out"
# NOTHING RAN, and nothing was recorded. Both halves matter: a gate that let one suite through
# before refusing would leave a results file that the summary would then under-report from.
assert_not_contains "preflight:no-suite-ran"              "01-fine.sh" "$out"
assert_not_contains "preflight:records-no-result"         "PASS"       "$out"
assert_not_contains "preflight:prints-no-tally"           "0 fail"     "$out"
# AND NO RUN DIRECTORY, which is the cheapest possible proof that it refused ABOVE the setup at
# run-tests.sh:145 rather than tearing down afterwards.
assert_not_contains "preflight:makes-no-run-directory"    "log:"       "$out"

# EVERY FAULT IN ONE REPORT. A fresh Mac is missing several things at once, and a gate that makes
# you fix them one run at a time is worse than the disease.
out="$(gate_run shellcheck podman)"
assert_contains "preflight:names-every-fault-at-once-1"   "shellcheck" "$out"
assert_contains "preflight:names-every-fault-at-once-2"   "podman"     "$out"

# THE CONTROL, and it is not optional: without it every assertion above passes forever the day
# the gate is accidentally made unreachable.
out="$(gate_run)"
assert_contains     "preflight:a-sound-machine-runs"      "01-fine.sh" "$out"
assert_not_contains "preflight:a-sound-machine-is-not-refused" "CANNOT RUN" "$out"
