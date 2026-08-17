#!/usr/bin/env bash
# TIER: unit
#
# setup-git's pure parts, one table at a time. No podman, no container, no network, no terminal.
#
# WHY A UNIT SUITE AND NOT JUST THE SHIM ONE. Three of the four things this covers are decisions
# made about a student's typing, and the cost of getting one wrong is not a crash — it is a
# student being told their real @stanford.edu address is invalid, or being handed a token link
# with an expiry a year in the past. Those are cheap to enumerate and expensive to notice, which
# is exactly what a table is for. The fourth, the probe plan, is a regression guard: GitHub does
# not permit three of the operations the original design asked for, and "somebody puts one back"
# is a realistic future.
#
# Driven through `setup-git --dev-*`, the same kind of seam `cs193v --dev-steps` is. Those
# handlers run before the terminal check for exactly this reason.
#
# CS193V_UI and CS193V_MESSAGES are set because this runs the script out of the CHECKOUT, on a
# machine where /etc/cs193v does not exist — a TA's Mac, in the cheap lane, with no image built.

set -u
. "$(dirname -- "$0")/lib/assert.sh"

cd "$REPO" || exit 1

SG="$PRIVATE/files/setup-git"
export CS193V_UI="$PRIVATE/files/cs193v-ui.sh"
export CS193V_MESSAGES="$PRIVATE/files/setup-git-messages.txt"
# The org is pinned rather than inherited, so a staff member with the variables exported in
# their shell does not get a different answer from this suite than CI does.
export CS193V_GH_ORG=cs193v-students
export CS193V_GH_SANDBOX=cs193v-students/install-sandbox
export CS193V_TOKEN_EXPIRY=2026-12-31

assert_file "setup-git:exists" "$SG"
assert_ok   "setup-git:parses" bash -n "$SG"

# ─── the email validator ───────────────────────────────────────────────────────
# THREE OUTCOMES, and the table asserts which one, not merely pass or fail. That is the whole
# point of it: `me@cs.stanford.edu` and `me@gmail.com` are both rejected, and telling a student
# with a real Stanford subdomain address that it "is not a valid @stanford.edu email address"
# would be a lie they cannot act on. Two of these rows exist because they are the ones a
# careless regex gets wrong: stanford.edu.evil.com ends with neither, and stanford.education
# starts with the right thing.
email_verdict() { bash "$SG" --dev-validate-email "$1" | awk '{print $1}'; }
email_value()   { bash "$SG" --dev-validate-email "$1" | awk '{print $2}'; }

for row in \
    'ok|jdoe@stanford.edu' \
    'ok|jane.doe+cs193v@stanford.edu' \
    'ok|a_b%c@stanford.edu' \
    'ok|x@stanford.edu' \
    'subdomain|me@alumni.stanford.edu' \
    'subdomain|me@cs.stanford.edu' \
    'subdomain|me@nested.deeply.stanford.edu' \
    'invalid|not an email' \
    'invalid|my.personal.gmail@gmail.com' \
    'invalid|me@notstanford.edu' \
    'invalid|me@stanford.education' \
    'invalid|me@stanford.edu.evil.com' \
    'invalid|a@b@stanford.edu' \
    'invalid|@stanford.edu' \
    'invalid|jdoe@' \
    'invalid|jdoe' \
    'invalid|.jdoe@stanford.edu' \
    'invalid|jdoe.@stanford.edu' \
    'invalid|j..doe@stanford.edu' \
    'invalid|' ; do
    want="${row%%|*}"; input="${row#*|}"
    assert_eq "email:$want($input)" "$want" "$(email_verdict "$input")"
done

# Whitespace either side is stripped rather than rejected: a pasted address very often carries
# some, and refusing it would be refusing a correct answer.
assert_eq "email:leading-and-trailing-space-accepted" "ok" \
          "$(email_verdict '     me@stanford.edu     ')"
assert_eq "email:space-is-stripped-from-the-value" "me@stanford.edu" \
          "$(email_value '     me@stanford.edu     ')"
# A tab inside is a different matter — it cannot be a real address, and it must not reach the
# terminal echoed back at the student.
assert_eq "email:internal-tab-rejected" "invalid" "$(email_verdict "$(printf 'a\tb@stanford.edu')")"

# The domain is normalised and the local part is not. Both halves matter: git config should not
# carry STANFORD.EDU, and echoing back a local part the student did not type invites an argument
# about what they typed.
assert_eq "email:domain-is-lowercased" "JDoe@stanford.edu" "$(email_value 'JDoe@Stanford.EDU')"

# 64 characters is the standard's limit for a local part, so 64 passes and 65 does not.
LP64="$(printf 'a%.0s' $(seq 1 64))"
LP65="$(printf 'a%.0s' $(seq 1 65))"
assert_eq "email:64-char-local-part-accepted" "ok"      "$(email_verdict "$LP64@stanford.edu")"
assert_eq "email:65-char-local-part-rejected" "invalid" "$(email_verdict "$LP65@stanford.edu")"

# ─── the name validator ────────────────────────────────────────────────────────
# ONE FAILURE MESSAGE, so this table only has two outcomes — but the accepted VALUE is where the
# work is, and the row that matters most is the accented one. A control-character filter written
# with a byte range rather than [[:cntrl:]] eats UTF-8 continuation bytes, and would mangle a
# good fraction of any Stanford class list while passing every ASCII test anyone wrote.
name_verdict() { bash "$SG" --dev-validate-name "$1" | awk '{print $1}'; }
name_value()   { bash "$SG" --dev-validate-name "$1" | cut -d' ' -f2-; }

assert_eq "name:plain"                "ok"    "$(name_verdict 'Jane Doe')"
assert_eq "name:mononym"              "ok"    "$(name_verdict 'Prince')"
assert_eq "name:apostrophe"           "ok"    "$(name_verdict "O'Brien")"
assert_eq "name:hyphen"               "ok"    "$(name_verdict 'Ada Lovelace-Byron')"
assert_eq "name:accented-is-accepted" "ok"    "$(name_verdict 'José Ángel')"
assert_eq "name:accented-is-unchanged" "José Ángel" "$(name_value 'José Ángel')"
assert_eq "name:cjk-is-accepted"      "ok"    "$(name_verdict '陳大文')"
assert_eq "name:empty"                "empty" "$(name_verdict '')"
assert_eq "name:only-spaces"          "empty" "$(name_verdict '     ')"
assert_eq "name:only-a-tab"           "empty" "$(name_verdict "$(printf '\t')")"
assert_eq "name:trimmed"              "Jane Doe" "$(name_value '   Jane Doe   ')"
assert_eq "name:internal-runs-squeezed" "Jane Doe" "$(name_value 'Jane     Doe')"
assert_eq "name:tab-becomes-a-space"  "Jane Doe" "$(name_value "$(printf 'Jane\tDoe')")"
N100="$(printf 'a%.0s' $(seq 1 100))"
N101="$(printf 'a%.0s' $(seq 1 101))"
assert_eq "name:100-characters-accepted" "ok"    "$(name_verdict "$N100")"
assert_eq "name:101-characters-rejected" "empty" "$(name_verdict "$N101")"

# ─── the token shape ───────────────────────────────────────────────────────────
# The classic token is told apart from junk on purpose. One with the `repo` scope would very
# nearly work, so a student holding one needs to know this course wants the other kind — not to
# be told that what they are holding is not a token.
kind() { bash "$SG" --dev-token-kind "$1"; }
assert_eq "token:fine-grained"     "fine"    "$(kind 'github_pat_11ABCDE0abcdefghij')"
assert_eq "token:classic"          "classic" "$(kind 'ghp_16C7e42F292c6912E7710c838347Ae178B4a')"
assert_eq "token:oauth-is-unknown" "unknown" "$(kind 'gho_16C7e42F292c6912E7710c838347Ae178B4a')"
assert_eq "token:server-is-unknown" "unknown" "$(kind 'ghs_16C7e42F292c6912E7710c838347Ae178B4a')"
assert_eq "token:empty"            "empty"   "$(kind '')"
assert_eq "token:spaces-only"      "empty"   "$(kind '   ')"
assert_eq "token:prose"            "unknown" "$(kind 'my token is secret')"
# A paste out of a browser very often carries a newline or a space. Trimmed, not rejected.
assert_eq "token:padded-paste-accepted" "fine" "$(kind '  github_pat_11ABCDE  ')"

# ─── the prefilled link ────────────────────────────────────────────────────────
# CS193V_TODAY is what makes this assertable at all: expires_in is a number of DAYS and staff
# configure a DATE, so without a pinned today this test would give a different answer tomorrow.
url() { CS193V_TODAY="$1" bash "$SG" --dev-print-token-url; }

# 2026-08-17 to 2026-12-31 is 136 days: 14 left in August, then 30 + 31 + 30 + 31.
assert_contains "url:expiry-is-days-from-today" "expires_in=136" "$(url 2026-08-17)"
assert_contains "url:leap-and-month-lengths"    "expires_in=137" "$(url 2026-08-16)"
# The three permissions the course needs, and the organization as resource owner. Named
# individually so a deleted parameter says which one went.
assert_contains "url:contents-write"  "contents=write"      "$(url 2026-08-17)"
assert_contains "url:issues-write"    "issues=write"        "$(url 2026-08-17)"
assert_contains "url:prs-write"       "pull_requests=write" "$(url 2026-08-17)"
assert_contains "url:resource-owner"  "target_name=cs193v-students" "$(url 2026-08-17)"
assert_contains "url:is-the-fine-grained-page" \
                "settings/personal-access-tokens/new" "$(url 2026-08-17)"
# NOT the classic page, which is one path segment away and would hand every student the wrong
# kind of token with instructions that almost fit.
assert_not_contains "url:not-the-classic-page" "settings/tokens/new" "$(url 2026-08-17)"

# A configured expiry that has already passed is staff rot rather than student error, and the
# floor keeps the link usable while 00-release-gates.sh is what fails loudly about the date.
assert_contains "url:past-expiry-clamps-to-a-floor" "expires_in=30" "$(url 2027-06-01)"
assert_contains "url:expiry-today-clamps-too"       "expires_in=30" "$(url 2026-12-31)"

# ─── the probe plan ────────────────────────────────────────────────────────────
# --dev-probe-plan runs the REAL probe functions with the commands recorded instead of executed,
# so this cannot go stale against what a student's machine actually does. That is also what makes
# the three negative assertions below meaningful rather than decorative.
PLAN="$(bash "$SG" --dev-probe-plan)"
assert_ne "plan:not-empty" "" "$PLAN"

# THE THREE OPERATIONS GITHUB DOES NOT PERMIT, which the original design asked for and which
# would each fail on a student rather than here:
#   * approving your own pull request answers 422 "Can not approve your own pull request";
#   * a pull request cannot be deleted at all, only closed;
#   * deleting an issue needs admin permission on the repository, which no student has.
# The review is a --comment for the first reason, and the closes below stand in for the others.
assert_not_match "plan:never-approves-its-own-pr" 'pr review.*--approve' "$PLAN"
assert_not_match "plan:never-deletes-a-pr"        'pr delete'            "$PLAN"
assert_not_match "plan:never-deletes-an-issue"    'issue delete'         "$PLAN"
assert_match     "plan:reviews-with-a-comment"    'pr review.*--comment' "$PLAN"
assert_match     "plan:closes-the-second-pr"      'pr close'             "$PLAN"
assert_match     "plan:closes-the-issue"          'issue close'          "$PLAN"

# Every operation the course will ask of the token, in the order that lets a failure name one
# permission: reading before writing, and pushing before anything that needs a pushed branch.
assert_match "plan:clones"        'git clone .*install-sandbox'  "$PLAN"
assert_match "plan:pulls"         'pull --quiet'                 "$PLAN"
assert_match "plan:pushes"        'push -q origin cs193v-setup/' "$PLAN"
assert_match "plan:lists-issues"  'issue list'                   "$PLAN"
assert_match "plan:creates-an-issue" 'issue create'              "$PLAN"
assert_match "plan:creates-a-pr"  'pr create'                    "$PLAN"
assert_match "plan:merges-a-pr"   'pr merge'                     "$PLAN"
assert_match "plan:deletes-its-branches" 'push -q origin --delete' "$PLAN"

# Ordering, asserted rather than assumed: `gh pr create --head` needs the branch to exist on the
# remote, and a student whose Contents permission is Read-only has to see `git push` fail rather
# than `gh pr` fail, or the message names the wrong permission.
line_of() { printf '%s\n' "$PLAN" | grep -nE "$1" | head -1 | cut -d: -f1; }
if [ "$(line_of 'push -q origin cs193v-setup/')" -lt "$(line_of 'pr create')" ]; then
    pass "plan:pushes-before-it-opens-a-pr"
else
    fail "plan:pushes-before-it-opens-a-pr" "$PLAN"
fi
if [ "$(line_of 'issue create')" -lt "$(line_of 'pr create')" ]; then
    pass "plan:creates-the-issue-the-pr-links"
else
    fail "plan:creates-the-issue-the-pr-links" "$PLAN"
fi
# THE NUMBER, not just the word: `Closes #0` matched a bare `Closes #` for one commit, after a
# tidy-up deleted the file probe_pr reads the issue number out of. The placeholder --dev-probe-plan
# hands back for a created issue is 1, so that is what the link has to name.
assert_match "plan:pr-links-the-issue" 'Closes #1"$' "$PLAN"

# NOTHING TOUCHES THE DEFAULT BRANCH. Every student has write access to the sandbox, so the one
# ref that would break setup for the rest of the class is the one the probes must stay off. The
# second pull request targets it and is closed rather than merged; nothing is ever pushed to it.
assert_not_match "plan:never-pushes-to-the-default-branch" 'push -q origin main' "$PLAN"
assert_not_match "plan:never-deletes-the-default-branch" 'origin --delete main' "$PLAN"

# THREE DISTINCT BRANCHES, each a readable prefix plus 64 hex characters. The randomness is what
# lets a whole lab section run this at once against one repository; the prefix is what lets staff
# see what the churn in it is.
branches="$(printf '%s\n' "$PLAN" | grep -oE 'cs193v-setup/[0-9a-f]+' | LC_ALL=C sort -u)"
assert_eq "plan:three-branches" "3" "$(printf '%s\n' "$branches" | grep -c .)"
assert_eq "plan:branch-names-are-64-hex" "" \
          "$(printf '%s\n' "$branches" | grep -vE '^cs193v-setup/[0-9a-f]{64}$' | tr '\n' ' ')"
assert_match "plan:issue-title-carries-64-hex" 'cs193v setup check [0-9a-f]{64}' "$PLAN"

# Two runs must not collide, or two students setting up at the same moment would.
other="$(bash "$SG" --dev-probe-plan | grep -oE 'cs193v-setup/[0-9a-f]+' | LC_ALL=C sort -u)"
assert_ne "plan:names-differ-between-runs" "$branches" "$other"

# ─── the terminal requirement ──────────────────────────────────────────────────
# Everything here is a question, so a run with no terminal has to say so rather than answering
# itself. menu() would take its default and every read would see EOF, which marches through the
# whole script agreeing to things and then fails somewhere unrelated.
out="$(bash "$SG" </dev/null 2>&1; printf '[rc=%s]' "$?")"
assert_says_key "notty:says-it-needs-a-terminal" err.no-terminal "$out" \
                "$CS193V_MESSAGES"
assert_contains "notty:exits-nonzero" "[rc=1]" "$out"

# An unknown flag is refused rather than treated as "no arguments", which would drop a staff
# member with a typo into a student's first-run flow.
out="$(bash "$SG" --wat </dev/null 2>&1; printf '[rc=%s]' "$?")"
assert_contains "args:unknown-flag-refused" "unknown option --wat" "$out"
assert_contains "args:unknown-flag-exits-2" "[rc=2]" "$out"

# ─── the missing-helper guard ──────────────────────────────────────────────────
# setup-git sources /etc/cs193v/ui.sh, and cannot draw its own error box without it. The guard is
# the same one the launcher has and exists for the same reason.
out="$(CS193V_UI=/nonexistent/ui.sh bash "$SG" </dev/null 2>&1; printf '[rc=%s]' "$?")"
assert_contains "guard:names-the-missing-file" "/nonexistent/ui.sh" "$out"
assert_contains "guard:tells-them-to-ask-staff" "course staff" "$out"
assert_contains "guard:exits-nonzero" "[rc=1]" "$out"
