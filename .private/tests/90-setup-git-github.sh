#!/usr/bin/env bash
# TIER: github
#
# setup-git against the REAL GitHub API and the real sandbox repository. Opt-in, and skipped
# unless you hand it a token:
#
#     CS193V_GH_TEST_TOKEN=github_pat_...  tests/run-tests.sh --tier github
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
# repository the whole class can see, and it takes tens of seconds per case.
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
require_cmd script "needed to drive the arrow-key menus through a pty"
require_running

ORG="${CS193V_GH_ORG:-cs193v-students}"
SANDBOX="${CS193V_GH_SANDBOX:-$ORG/install-sandbox}"
EXPECT_ROW="${CS193V_GH_EXPECT_ROW:-}"
EXPECT_KEY="${CS193V_GH_EXPECT_KEY:-}"
record "github:organization"   "$ORG"
record "github:sandbox"        "$SANDBOX"
record "github:gh-version"     "$(podman exec "$NAME" gh --version 2>&1 | head -1)"

# `real`, so nothing goes on PATH ahead of anything. Only $SGSHIM and sg_cleanup_all are wanted
# from it here — what actually runs lives in the container.
sg_new real

# The throwaway HOME inside the container. Named rather than mktemp'd so a run interrupted halfway
# leaves one directory to find rather than a scatter of them.
D=/tmp/cs193v-setup-git-github-test
podman exec "$NAME" rm -rf "$D"
podman exec "$NAME" mkdir -p "$D/gh"

# -e rather than `env`, because `env A=B podman exec ...` sets A on podman and not in the
# container. The token is the one thing NOT passed this way: it goes in over stdin, typed at the
# prompt like a student's, which is also what keeps it out of the process table.
SG_RUN="podman exec -i -t"
SG_RUN="$SG_RUN -e HOME=$D -e TMPDIR=$D -e GH_CONFIG_DIR=$D/gh -e GIT_CONFIG_GLOBAL=$D/gitconfig"
SG_RUN="$SG_RUN -e CS193V_GH_ORG=$ORG -e CS193V_GH_SANDBOX=$SANDBOX"
SG_RUN="$SG_RUN $NAME setup-git"
# Generous: this one really clones, pushes, and opens two pull requests over the network.
SG_TIMEOUT=600

# Same clean first run 35-setup-git-shim.sh uses. The trailing arrows pick "I'm stuck" if a probe
# fails, which is what produces the staff box and the exact stderr — the thing worth reading when
# the point of the run is to find out what GitHub said.
KEYS="cs193v-test@stanford.edu\n|\n|CS193V Setup Test\n|\n|\n|$CS193V_GH_TEST_TOKEN\n|\n|\033[B|\033[B|\n"

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
    # ELEVEN ROWS, the same count the fakes produce. If GitHub ever refuses one of the operations
    # outright — a self-review, a merge into a non-default branch — this is where it shows up.
    assert_eq "github:eleven-rows-succeeded" "11" \
              "$(printf '%s' "$plain" | grep -oE '✓' | grep -c . || true)"
fi

# THE SANDBOX IS LEFT AS IT WAS FOUND, on the failing path as well as the passing one. Every
# student has write access to that repository, so a suite that left branches in it would be handing
# the next person a mess and the class a puzzle. Checked rather than trusted, because the cleanup is
# best-effort by design and silent when it fails. Queried with the run's own token, from inside the
# container, since that is where it lives.
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
