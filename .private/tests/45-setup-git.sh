#!/usr/bin/env bash
# TIER: unit
#
# setup-git's pure parts, one table at a time. No podman, no container, no network, no terminal.
#
# WHY A UNIT SUITE AND NOT JUST THE SHIM ONE. Three of the four things this covers are decisions
# made about a student's typing, and the cost of getting one wrong is not a crash — it is a
# student being told their real SUNetID is invalid, or being handed a token link with an expiry a
# year in the past. Those are cheap to enumerate and expensive to notice, which is exactly what a
# table is for. The fourth, the probe plan, is a regression guard: GitHub does not permit three of
# the operations the original design asked for, and "somebody puts one back" is a realistic future.
# The fifth is newer — the repository is derived from the SUNetID now (issue #92), so the name the
# probes work in is a decision rather than a constant, and a wrong one is a 404 on every student.
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
# their shell does not get a different answer from this suite than CI does. CS193V_GH_SANDBOX is
# pinned EMPTY on purpose: the repository is derived from the SUNetID now, the derivation is one of
# the things this suite checks, and a staff member with an override exported would check something
# else instead.
export CS193V_GH_ORG=cs193v-students
export CS193V_GH_SANDBOX=
export CS193V_TOKEN_EXPIRY=2026-12-31

assert_file "setup-git:exists" "$SG"
assert_ok   "setup-git:parses" bash -n "$SG"

# ─── the SUNetID validator ─────────────────────────────────────────────────────
# THREE OUTCOMES, and the table asserts which one, not merely pass or fail. That is the whole
# point of it: `jane.doe` and `me@cs.stanford.edu` are both rejected and they are different
# mistakes — the first is a real alias of theirs that is not the primary ID the sandbox is named
# after, the second is an answer to a question nobody asked. Two of these rows exist because they
# are the ones a careless pattern gets wrong: jane.doe@stanford.edu has the right domain and a
# local part that is not an ID, and jdoe@stanford.edu.evil.com ends with neither.
#
# THE PATTERN IS SOURCED, AND SO IS WHAT IS ABSENT FROM IT. Three to eight alphanumerics, read
# 2026-08-25 from Stanford UIT's Authentication Developer Information ("currently limited to
# between 3 and 8 alphanumeric characters" for primary SUNet IDs) and Administrative Guide 6.4.1
# ("SUNet IDs consist of alphabetic characters and digits ... Personal SUNet IDs are from three to
# eight characters in length"). NEITHER documents a must-begin-with-a-letter rule or a refusal of
# uppercase, which is why `1abc` is accepted below and `HTIEK` is lower-cased rather than turned
# away: an invented rule here stops a student on the first screen with nothing they can do about it.
id_verdict() { bash "$SG" --dev-validate-sunetid "$1" | awk '{print $1}'; }
id_value()   { bash "$SG" --dev-validate-sunetid "$1" | awk '{print $2}'; }

for row in \
    'ok|htiek' \
    'ok|szum' \
    'ok|abc' \
    'ok|a1b2c3d4' \
    'ok|1abc' \
    'ok|jdoe@stanford.edu' \
    'ok|JDoe@Stanford.EDU' \
    'email|me@cs.stanford.edu' \
    'email|me@alumni.stanford.edu' \
    'email|me@gmail.com' \
    'email|a@b@stanford.edu' \
    'email|jdoe@stanford.edu.evil.com' \
    'email|me@stanford.education' \
    'invalid|ab' \
    'invalid|abcdefghi' \
    'invalid|jane.doe' \
    'invalid|jane-doe' \
    'invalid|jane_doe' \
    'invalid|jane.doe@stanford.edu' \
    'invalid|@stanford.edu' \
    'invalid|jdoe!' \
    'invalid|not an id' \
    'invalid|' ; do
    want="${row%%|*}"; input="${row#*|}"
    assert_eq "sunetid:$want($input)" "$want" "$(id_verdict "$input")"
done

# Whitespace either side is stripped rather than rejected: a pasted answer very often carries
# some, and refusing it would be refusing a correct answer.
assert_eq "sunetid:leading-and-trailing-space-accepted" "ok" "$(id_verdict '     jdoe     ')"
assert_eq "sunetid:space-is-stripped-from-the-value" "jdoe" "$(id_value '     jdoe     ')"
# A tab INSIDE is a different matter — it cannot be an ID, and it must not reach the terminal
# echoed back at the student.
assert_eq "sunetid:internal-tab-rejected" "invalid" "$(id_verdict "$(printf 'jd\toe')")"

# NORMALISED, NOT MERELY ACCEPTED, and this is the half that matters more than the verdict: the
# value is what gets @stanford.edu appended to it and what names the repository the probes clone.
# A capslocked answer that came back unchanged would send a student's clone at sandbox-HTIEK and
# put HTIEK@stanford.edu in every commit they make this quarter.
assert_eq "sunetid:uppercase-is-lowercased" "htiek" "$(id_value 'HTIEK')"
assert_eq "sunetid:a-typed-address-yields-the-id" "jdoe" "$(id_value 'jdoe@stanford.edu')"
assert_eq "sunetid:a-typed-address-is-lowercased" "jdoe" "$(id_value 'JDoe@Stanford.EDU')"

# The documented range, at both ends: 3 and 8 pass, 2 and 9 do not.
ID8="$(printf 'a%.0s' $(seq 1 8))"
ID9="$(printf 'a%.0s' $(seq 1 9))"
assert_eq "sunetid:3-characters-accepted" "ok"      "$(id_verdict 'abc')"
assert_eq "sunetid:2-characters-rejected" "invalid" "$(id_verdict 'ab')"
assert_eq "sunetid:8-characters-accepted" "ok"      "$(id_verdict "$ID8")"
assert_eq "sunetid:9-characters-rejected" "invalid" "$(id_verdict "$ID9")"

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
# FIVE VERDICTS, AND THE TABLE ASSERTS WHICH ONE — the same argument the email table makes. Three
# of these are separate rows because they are separate mistakes: a classic token with the `repo`
# scope would very nearly work, so its holder needs to know this course wants the other kind; a
# paste that came up short needs "copy the whole thing"; and everything else needs to be told what
# a token looks like.
#
# THE SHAPE IS A LENGTH NOW, WHICH IS WHY THE FIXTURES ARE FULL-SIZED. Until issue #53 this checked
# the prefix alone, so every fixture here was a stub and `github_pat_x` was a valid token as far as
# the script was concerned. A real fine-grained token is 93 characters: `github_pat_`, 22
# alphanumerics, an underscore, and 59 more — measured 2026-08-18 against a live one.
kind() { bash "$SG" --dev-token-kind "$1"; }
# Built rather than typed out, so the three numbers that make up the shape are visible in the test
# as well as in the script, and a fixture cannot be a character out by a typo nobody can see.
T22="11ABCDEFG0$(printf 'a%.0s' $(seq 1 12))"
T59="$(printf 'b%.0s' $(seq 1 59))"
TOK="github_pat_${T22}_${T59}"
assert_eq "token:length-is-93" "93" "$(printf '%s' "$TOK" | LC_ALL=C awk '{print length($0)}')"

assert_eq "token:fine-grained"      "fine"    "$(kind "$TOK")"
# A paste out of a browser very often carries a newline or a space. Trimmed, not rejected.
assert_eq "token:padded-paste-accepted" "fine" "$(kind "  $TOK  ")"
assert_eq "token:classic"           "classic" "$(kind 'ghp_16C7e42F292c6912E7710c838347Ae178B4a')"
assert_eq "token:oauth-is-unknown"  "unknown" "$(kind 'gho_16C7e42F292c6912E7710c838347Ae178B4a')"
assert_eq "token:server-is-unknown" "unknown" "$(kind 'ghs_16C7e42F292c6912E7710c838347Ae178B4a')"
assert_eq "token:empty"             "empty"   "$(kind '')"
assert_eq "token:spaces-only"       "empty"   "$(kind '   ')"
assert_eq "token:prose"             "unknown" "$(kind 'my token is secret')"

# A TRUNCATED PASTE IS ITS OWN VERDICT. 50 characters is the case issue #53 drew, and it was
# accepted outright before that issue: it has the right prefix, and the prefix was the whole check.
assert_eq "token:half-a-paste-is-partial" "partial" \
          "$(kind "$(printf '%s' "$TOK" | cut -c1-50)")"
assert_eq "token:prefix-alone-is-partial" "partial" "$(kind 'github_pat_')"
assert_eq "token:old-stub-is-partial"     "partial" "$(kind 'github_pat_11ABCDE0abcdefghij')"

# And these three are NOT partial, because none of them is a token that got cut off: one character
# too many is what pasting twice starts to look like, and the other two are the right length with
# the wrong shape — the checks a length comparison on its own would pass.
assert_eq "token:one-too-long-is-unknown"  "unknown" "$(kind "${TOK}x")"
assert_eq "token:hyphen-is-unknown"        "unknown" "$(kind "github_pat_${T22}-${T59}")"
assert_eq "token:no-separator-is-unknown"  "unknown" "$(kind "github_pat_${T22}${T59}x")"

# THE ONE ASSERTION THAT CAN CATCH GITHUB MOVING THE FORMAT, and the reason a strict shape check is
# defensible at all: with a real token to hand, the pattern is checked against reality rather than
# against this file's idea of it. Skipped without one — the github tier is opt-in — and it prints no
# token on either path, whether it passes or fails.
# OVER STDIN, NOT AS AN ARGUMENT: an argument would put a live credential in the process table for
# as long as the check runs, which is exactly what setup-git refuses to do with the same token three
# functions later. The verdict is all that comes back, so a failure here prints `partial` or
# `unknown` and never the token.
if [ -n "${CS193V_GH_TEST_TOKEN:-}" ]; then
    assert_eq "token:a-real-token-is-fine" "fine" \
              "$(printf '%s' "$CS193V_GH_TEST_TOKEN" | bash "$SG" --dev-token-kind)"
else
    skip "token:a-real-token-is-fine" "set CS193V_GH_TEST_TOKEN to check the shape against GitHub"
fi

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

# ─── the repository the probes work in ─────────────────────────────────────────
# DERIVED FROM THE ID, which is the whole of issue #92: there is no fixed sandbox any more. Four
# things, because each one breaks differently — the derivation itself, that a different student
# gets a different repository, that the value is normalised on the way in, and that an override
# still wins, which is what lets a staff dry run point somewhere that is not a student's homework.
repo() { bash "$SG" --dev-sandbox-repo "$1"; }
assert_eq "sandbox:derived-from-the-id"  "cs193v-students/sandbox-jdoe"  "$(repo jdoe)"
assert_eq "sandbox:another-id-moves-it"  "cs193v-students/sandbox-htiek" "$(repo htiek)"
assert_eq "sandbox:the-id-is-lowercased" "cs193v-students/sandbox-jdoe"  "$(repo JDOE)"
assert_eq "sandbox:an-override-wins" "someone/scratch" \
          "$(CS193V_GH_SANDBOX=someone/scratch bash "$SG" --dev-sandbox-repo jdoe)"

# AND THE OLD SHARED REPOSITORY IS GONE FOR GOOD. install-sandbox was one repository every student
# could write to; nothing in this project may name it again, by default or by accident.
assert_not_contains "sandbox:never-the-old-shared-one" "install-sandbox" "$(repo jdoe)"

# AND A SEAM THAT ANSWERS A MALFORMED QUESTION REFUSES RATHER THAN GUESSING. A bad ID leaves
# VALID_ID empty, so without this both seams would name `cs193v-students/sandbox-` and print it
# like a repository — a whole probe plan working somewhere that does not exist, in the two seams
# staff read BY HAND, which is the only reason either of them exists.
out="$(bash "$SG" --dev-sandbox-repo jane.doe 2>&1; printf '[rc=%s]' "$?")"
assert_contains "sandbox:a-bad-id-is-refused" "not a SUNetID" "$out"
assert_contains "sandbox:a-bad-id-exits-2"    "[rc=2]"        "$out"
assert_not_contains "sandbox:a-bad-id-names-no-repository" "sandbox-" "$out"
out="$(bash "$SG" --dev-probe-plan jane.doe 2>&1; printf '[rc=%s]' "$?")"
assert_contains "plan:a-bad-id-is-refused" "not a SUNetID" "$out"
assert_contains "plan:a-bad-id-exits-2"    "[rc=2]"        "$out"
assert_not_contains "plan:a-bad-id-plans-nothing" "gh issue" "$out"

# ─── the probe plan ────────────────────────────────────────────────────────────
# --dev-probe-plan runs the REAL probe functions with the commands recorded instead of executed,
# so this cannot go stale against what a student's machine actually does. That is also what makes
# the three negative assertions below meaningful rather than decorative.
PLAN="$(bash "$SG" --dev-probe-plan jdoe)"
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
assert_match "plan:clones"        'git clone .*sandbox-jdoe'     "$PLAN"
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

# AND NOTHING NAMES THE OLD SHARED SANDBOX. Every command in this plan carries the repository, so
# a derivation that quietly fell back to install-sandbox would show up here and nowhere else.
assert_not_match "plan:never-names-the-old-shared-sandbox" 'install-sandbox' "$PLAN"
assert_match     "plan:every-gh-call-names-the-students-sandbox" \
                 'issue list --repo cs193v-students/sandbox-jdoe' "$PLAN"

# THREE DISTINCT BRANCHES, each a readable prefix plus 64 hex characters. The randomness kept a
# whole lab section off each other's refs when the sandbox was shared; with one repository per
# student it keeps a repeat run off its own. The prefix is what lets staff see the churn.
branches="$(printf '%s\n' "$PLAN" | grep -oE 'cs193v-setup/[0-9a-f]+' | LC_ALL=C sort -u)"
assert_eq "plan:three-branches" "3" "$(printf '%s\n' "$branches" | grep -c .)"
assert_eq "plan:branch-names-are-64-hex" "" \
          "$(printf '%s\n' "$branches" | grep -vE '^cs193v-setup/[0-9a-f]{64}$' | tr '\n' ' ')"
assert_match "plan:issue-title-carries-64-hex" 'cs193v setup check [0-9a-f]{64}' "$PLAN"

# Two runs must not collide, or two students setting up at the same moment would.
other="$(bash "$SG" --dev-probe-plan jdoe | grep -oE 'cs193v-setup/[0-9a-f]+' | LC_ALL=C sort -u)"
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
