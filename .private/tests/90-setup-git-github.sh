#!/usr/bin/env bash
# TIER: github
#
# setup-git against the REAL GitHub API and a real sandbox repository. Opt-in, and skipped
# unless you hand it a token:
#
#     CS193V_GH_TEST_TOKEN=github_pat_...  tests/run-tests.sh --tier github
#
# IT NEEDS A REPOSITORY THAT EXISTS, and since issue #92 there is no longer one with a fixed name:
# the sandbox is per-student, `$ORG/sandbox-<sunetid>`, released by the homework deploy script. So
# this tier types a SUNetID like a student and works against the repository that follows from it.
# The default is `cs193v` — a structurally valid SUNetID that is nobody's — so what staff keep for
# this is one repository, cs193v-students/sandbox-cs193v, private with at least one commit. Point
# CS193V_GH_TEST_ID at your own SUNetID to use your own sandbox instead. Writing into a real
# student's is what the default exists to avoid.
#
# WHY THIS EXISTS AS A SEPARATE, OPT-IN TIER. Everything else about setup-git is settled against
# fakes, which is right: a sequence of commands and a set of decisions needs no network, and a
# suite that needed a credential in the repository would be worse than no suite. What fakes
# CANNOT settle is the one thing the failure messages are built on — WHICH PERMISSION each broken
# operation actually reports. That answer belongs to GitHub, it is undocumented in the direction
# we need it (the docs say which permission an endpoint requires, not what a token lacking it
# produces), and it can change under us. So this is the harness for measuring it, and for
# re-measuring it when GitHub moves something.
#
# It is not in DEFAULT_TIERS and it never should be: it needs a real credential, it writes to a
# repository somebody owns, and it takes tens of seconds per case.
#
# IT RUNS THE INSTALLED COPY, INSIDE THE CONTAINER, and that is the point rather than an
# incidental. The words this suite exists to record are gh's, and the image ships gh 2.97 while a
# host package can be fifty versions behind it — measured on the development machine: 2.46 on the
# host, 2.97 in the image. A message written from the host's wording would be a message a student
# never sees.
#
# ─── how to use it to settle the permission mapping ────────────────────────────
# Make FOUR tokens on cs193v-students, each identical to what students are told to make except
# for one thing held back, and run this once per token:
#
#   CS193V_GH_EXPECT_ROW='git push'  CS193V_GH_EXPECT_KEY=err.push    <- Contents: Read-only
#   CS193V_GH_EXPECT_ROW='gh issue'  CS193V_GH_EXPECT_KEY=err.issues  <- no Issues
#   CS193V_GH_EXPECT_ROW='gh pr'     CS193V_GH_EXPECT_KEY=err.prs     <- no Pull requests
#   CS193V_GH_EXPECT_ROW='git clone'                                  <- resource owner = you
#
# With neither set, the suite asserts a clean pass — the case to run with a correctly configured
# token, and the one that proves the probe list is possible at all. Either way it records what
# GitHub actually said under `github:what-github-said`; the messages in
# files/setup-git-messages.txt should be written from that rather than from the documentation.
#
# ─── what it does to your machine, and to your container ───────────────────────
# NOTHING PERSISTENT. HOME, GH_CONFIG_DIR and GIT_CONFIG_GLOBAL are all redirected into a
# throwaway directory INSIDE the container, so the run cannot touch your own gh login or the git
# identity in the cs193v-git volume, and the directory is removed afterwards. That is not caution
# for its own sake: setup-git's whole job is to write those two files, and running it unisolated
# would log you out of gh and rewrite your identity.

set -u
. "$(dirname -- "$0")/lib/assert.sh"
. "$(dirname -- "$0")/lib/setup-git-shim.sh"

cd "$REPO" || exit 1

SGM="$PRIVATE/files/setup-git-messages.txt"

if [ -z "${CS193V_GH_TEST_TOKEN:-}" ]; then
    skip "github:probes-against-the-real-sandbox" "set CS193V_GH_TEST_TOKEN to run this"
    exit 0
fi
# NO require_cmd script: nothing here uses script(1) any more. lib/ptyrun.py replaced it because
# BSD script cannot deliver keystrokes and macOS has no GNU one to install -- so demanding it would
# refuse a machine over a tool the suite does not touch. ptyrun needs python3, which the preflight
# in run-tests.sh checks for every tier.
require_running

# The shim directories go on a trap rather than only on the last line of the file: this suite
# talks to the real API, so it is the one most likely to be interrupted mid-wait (#76).
trap 'sg_cleanup_all' EXIT

ORG="${CS193V_GH_ORG:-cs193v-students}"
# THE SUNETID IS THE INPUT AND THE REPOSITORY FOLLOWS FROM IT. Both are worked out here as well as
# inside the run, because the leftover checks at the bottom have to query the same repository the
# run used — and they run with a different token from a different place.
TEST_ID="${CS193V_GH_TEST_ID:-cs193v}"
PREFIX="${CS193V_GH_SANDBOX_PREFIX:-sandbox-}"
SANDBOX="${CS193V_GH_SANDBOX:-$ORG/$PREFIX$TEST_ID}"
EXPECT_ROW="${CS193V_GH_EXPECT_ROW:-}"
EXPECT_KEY="${CS193V_GH_EXPECT_KEY:-}"
record "github:organization"   "$ORG"
record "github:sunetid"        "$TEST_ID"
record "github:sandbox"        "$SANDBOX"
record "github:gh-version"     "$(podman exec "$NAME" gh --version 2>&1 | head -1)"

# CS193V_GH_TEST_ID IS CHECKED AGAINST THE VALIDATOR FIRST, for the same reason
# CS193V_GH_EXPECT_ROW is checked against the five row labels below: an ID that setup-git will
# refuse at its first prompt reads exactly like the finding this suite exists to produce. Asked of
# the INSTALLED script rather than of a pattern copied in here, so the two cannot disagree.
id_verdict="$(podman exec "$NAME" setup-git --dev-validate-sunetid "$TEST_ID" | awk '{print $1}')"
if [ "$id_verdict" != ok ]; then
    fail "github:test-id-is-a-valid-sunetid" \
         "CS193V_GH_TEST_ID=$TEST_ID is '$id_verdict', so setup-git would turn it away at the
first prompt and every row below would be red for a reason that is not GitHub's."
    exit 1
fi

# `real`, so nothing goes on PATH ahead of anything. Only $SGSHIM and sg_cleanup_all are wanted
# from it here — what actually runs lives in the container.
sg_new real

# The throwaway HOME inside the container. Named rather than mktemp'd so a run interrupted halfway
# leaves one directory to find rather than a scatter of them.
D=/tmp/cs193v-setup-git-github-test
podman exec "$NAME" rm -rf "$D"
podman exec "$NAME" mkdir -p "$D/gh"

# THE SANDBOX HAS TO EXIST BEFORE ANY OF THIS MEANS ANYTHING, and its absence is indistinguishable
# from the finding this suite is for: a private repository that is not there answers `git clone`
# with the same 404 a missing permission does. So it is asked once, up front, with the token the run
# will use — passed by NAME rather than by value, so the credential stays out of podman's argv the
# way setup-git keeps it out of gh's.
sandbox_api() {                       # sandbox_api PATH JQ -> the answer, or non-zero and the error
    GH_TOKEN="$CS193V_GH_TEST_TOKEN" podman exec -e GH_TOKEN "$NAME" \
        gh api "$1" --jq "$2" 2>&1
}

# EXISTENCE FIRST, and separately from having a commit, because the two are different things to fix
# and a run that stops should say which.
if branch="$(sandbox_api "repos/$SANDBOX" .default_branch)" \
   && [ -n "$branch" ] && [ "$branch" != null ]; then
    record "github:sandbox-default-branch" "$branch"
    pass "github:the-sandbox-exists"
else
    fail "github:the-sandbox-exists" \
         "this token cannot read $SANDBOX:
  $branch
Create it private with everybody's write access, or set CS193V_GH_TEST_ID to a SUNetID
whose sandbox you already have."
    exit 1
fi

# AND A COMMIT — WHICH .default_branch DOES NOT PROVE. MEASURED 2026-08-25, the hard way, on the
# first real run of this tier: GitHub answers `"default_branch": "main"` for a repository with
# nothing in it, because that is the name it WILL use rather than a ref that exists. This check was
# written against .default_branch and waved an empty sandbox straight through — the clone
# "succeeded", `git pull` failed with "your configuration specifies to merge with the ref
# 'refs/heads/main' ... but no such ref was fetched", and what should have been one refusal here
# became three red assertions and a staff box about the wrong thing.
#
# THE BRANCH LIST IS THE QUESTION THAT DISTINGUISHES THEM: an empty repository has no branches, and
# answers 200 with an empty array rather than an error. `refs/heads/main` in that git error is
# setup-git's own init.defaultBranch talking, not GitHub's — which is exactly why nothing about the
# clone or the pull can tell you the repository was empty.
refs="$(sandbox_api "repos/$SANDBOX/branches?per_page=1" length)"
case "$refs" in
    0)  fail "github:the-sandbox-has-a-commit" \
             "$SANDBOX has no branches, so it has no commits. git clone \"succeeds\" on an empty
repository and git pull then fails with 'no such ref was fetched', which is not about the
token at all — see the staff README's item 3. Push one commit to it and run this again." ;;
    ''|*[!0-9]*)
        fail "github:the-sandbox-has-a-commit" \
             "could not count $SANDBOX's branches, so this proves nothing either way: $refs" ;;
    *)  record "github:sandbox-branches" "$refs"
        pass "github:the-sandbox-has-a-commit" ;;
esac
case "$refs" in 0|''|*[!0-9]*) exit 1 ;; esac

# -e rather than `env`, because `env A=B podman exec ...` sets A on podman and not in the
# container. The token is the one thing NOT passed this way: it goes in over stdin, typed at the
# prompt like a student's, which is also what keeps it out of the process table.
SG_RUN="podman exec -i -t"
SG_RUN="$SG_RUN -e HOME=$D -e TMPDIR=$D -e GH_CONFIG_DIR=$D/gh -e GIT_CONFIG_GLOBAL=$D/gitconfig"
SG_RUN="$SG_RUN -e CS193V_GH_ORG=$ORG"
# THE REPOSITORY IS NOT PASSED IN unless the caller pinned it. Handing the run the name this file
# derived would be testing the derivation against itself; leaving it out makes the run work the
# name out of the SUNetID typed at the prompt, which is the one thing this tier can settle and the
# shim suite cannot.
[ -n "${CS193V_GH_SANDBOX:-}" ] && \
    SG_RUN="$SG_RUN -e CS193V_GH_SANDBOX=$CS193V_GH_SANDBOX"
[ -n "${CS193V_GH_SANDBOX_PREFIX:-}" ] && \
    SG_RUN="$SG_RUN -e CS193V_GH_SANDBOX_PREFIX=$CS193V_GH_SANDBOX_PREFIX"
SG_RUN="$SG_RUN $NAME setup-git"
# Generous: this one really clones, pushes, and opens two pull requests over the network.
SG_TIMEOUT=600

# Same clean first run 35-setup-git-shim.sh uses. The trailing arrows pick "I'm stuck" if a probe
# fails, which is what produces the staff box and the exact output — the thing worth reading when
# the point of the run is to find out what GitHub said.
KEYS="$TEST_ID\n|\n|CS193V Setup Test\n|\n|\n|\n|$CS193V_GH_TEST_TOKEN\n|\n|\033[B|\033[B|\n"

# CS193V_GH_EXPECT_ROW IS CHECKED AGAINST THE FIVE REAL LABELS FIRST, because a typo in it reads
# exactly like the finding this suite exists to produce. Measured the hard way: `git issues` instead
# of `gh issue` reported "the expected row failed" as a FAILURE while the row that mattered was red
# and the right message was on the screen — a mapping confirmed and a suite saying otherwise.
case "${EXPECT_ROW:-none}" in
    none|'git clone'|'git pull'|'git push'|'gh issue'|'gh pr') : ;;
    *)  fail "github:expect-row-is-one-of-the-five" \
             "CS193V_GH_EXPECT_ROW=$EXPECT_ROW is not a row label. The five are:
  git clone   git pull   git push   gh issue   gh pr"
        exit 1 ;;
esac

out="$(sg_tty "$KEYS")"
plain="$(sg_plain "$out")"

if [ -n "$EXPECT_ROW" ]; then
    # A row that failed, and the ROWS BEFORE IT that did not. Both halves matter: a token missing
    # Issues must fail at `gh issue` and not at `git clone`, or the message names the wrong
    # permission and sends the student to change something that was already right.
    assert_match "github:the-expected-row-failed" "✗ $EXPECT_ROW" "$plain"
    assert_not_contains "github:no-earlier-row-failed" "✗ git clone" \
        "$(printf '%s' "$plain" | sed "s/✗ $EXPECT_ROW.*//")"
    [ -n "$EXPECT_KEY" ] && sg_says "github:the-expected-message-appeared" "$EXPECT_KEY" "$out"
    # The verbatim words, which is the whole reason to run this by hand.
    record "github:what-github-said" "$plain"
else
    sg_says "github:a-correct-token-passes-every-probe" status.all-set "$out"
    assert_not_contains "github:no-row-failed" "✗" "$plain"
    # TWELVE ROWS, the same count the fakes produce. If GitHub ever refuses one of the operations
    # outright — a self-review, a merge into a non-default branch — this is where it shows up.
    assert_eq "github:twelve-rows-succeeded" "12" \
              "$(printf '%s' "$plain" | grep -oE '✓' | grep -c . || true)"
fi

# THE SANDBOX IS LEFT AS IT WAS FOUND, on the failing path as well as the passing one. It belongs
# to somebody — staff, or whoever CS193V_GH_TEST_ID names — so a suite that left branches in it
# would be handing the next person a mess and its owner a puzzle. Checked rather than trusted,
# because the cleanup is best-effort by design and silent when it fails. Queried with the run's own
# token, from inside the container, since that is where it lives.
#
# GUARDED, BOTH OF THEM, because an empty answer has two meanings: the sandbox is clean, or the
# query never ran. A token that GitHub rejected outright answers both of these with nothing, and an
# unguarded `assert_eq ""` would report a spotless sandbox on the strength of a failed API call —
# which is the one shape of vacuous pass this suite exists to avoid.
GHX="podman exec -e GH_CONFIG_DIR=$D/gh $NAME gh"
if left="$($GHX api "repos/$SANDBOX/branches?per_page=100" \
           --jq '[.[].name | select(startswith("cs193v-setup/"))] | join(" ")' 2>&1)"; then
    record "github:branches-left-behind" "${left:-none}"
    assert_eq "github:no-branches-left-in-the-sandbox" "" "$left"
else
    fail "github:no-branches-left-in-the-sandbox" \
         "could not read the sandbox's branches, so this proves nothing either way: $left"
fi

# Closed issues accumulate and that is expected — deleting one needs admin permission, which no
# student has, so setup-git closes rather than deletes. What must not be left is an OPEN one.
if open_left="$($GHX api "repos/$SANDBOX/issues?state=open&per_page=100" \
                --jq '[.[].title | select(startswith("cs193v setup check"))] | length' 2>&1)"; then
    record "github:open-issues-left-behind" "$open_left"
    assert_eq "github:no-open-issues-left-in-the-sandbox" "0" "$open_left"
else
    fail "github:no-open-issues-left-in-the-sandbox" \
         "could not read the sandbox's issues, so this proves nothing either way: $open_left"
fi

# And the container is left as it was found: the throwaway HOME goes, so the developer's own gh
# login and the identity in the cs193v-git volume are untouched by construction and by cleanup.
podman exec "$NAME" rm -rf "$D"
assert_fail "github:leaves-no-test-home-behind" \
            sh -c "podman exec $NAME test -e $D"
sg_cleanup_all
