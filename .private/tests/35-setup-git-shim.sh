#!/usr/bin/env bash
# TIER: shim
#
# setup-git driven end to end, over a real pty, against a fake `gh` and a fake `git`.
#
# WHY FAKES RATHER THAN THE REAL THING. What this script has to get right is a sequence and a
# set of decisions: which command runs when, what it does with the answer, which message a
# failing step produces, and what it never lets onto the screen. None of that needs a real API,
# and all of it is untestable against one — a real run needs a real credential committed
# somewhere, and it leaves branches and issues in a repository every student can see. The
# measurement only a real token can settle is which permission each failure actually reports,
# and that lives in 90-setup-git-github.sh, opt-in, plus MANUAL.md.
#
# A REAL PTY, because every decision in the script is behind menu(), and menu() with no tty
# deliberately takes its default and returns — so a piped run would march through the whole
# flow agreeing to everything and prove nothing about the arrow keys.
#
# The transcript is what the STUDENT SEES, so that is what the assertions read: the ✓ and ✗
# glyphs in it, the messages by key rather than by quoted prose, and — the one that matters most
# — the absence of the token anywhere in it.

set -u
. "$(dirname -- "$0")/lib/assert.sh"
. "$(dirname -- "$0")/lib/setup-git-shim.sh"

cd "$REPO" || exit 1

require_cmd script "needed to drive the arrow-key menus through a pty"

# THIS SUITE HAD NO TRAP AT ALL, so sg_cleanup_all was never called and every shim directory it
# made survived the run — 241 of them were in /tmp when #76 was measured. Both ends, the way
# 60-container.sh does it: the trap for a normal exit, the sweep for a run that was killed.
trap 'sg_cleanup_all' EXIT
record "sg:leftover-dirs-from-an-earlier-run" "$(sg_sweep_stale)"

SG_SETUP_GIT="$PRIVATE/files/setup-git"
SGM="$PRIVATE/files/setup-git-messages.txt"
# Every run needs these four: two to find the helper and the catalogue in the CHECKOUT rather than
# at the image paths, and two to pin the organization and the date, so a staff member with either
# exported in their shell gets the same answers CI does. sg_tty appends TMPDIR and CS193V_SGSHIM
# per run, because those change with each fresh shim.
SG_ENV="CS193V_UI=$PRIVATE/files/cs193v-ui.sh CS193V_MESSAGES=$SGM"
SG_ENV="$SG_ENV CS193V_GH_ORG=cs193v-students CS193V_TOKEN_EXPIRY=2026-12-31 CS193V_TODAY=2026-08-17"
# THE REAL SHAPE, NOT MERELY A LONG STRING: 93 characters, `github_pat_` then 22 alphanumerics, an
# underscore and 59 more, which is what token_kind has required since issue #53. Built from its
# three parts rather than typed out, the same way 45-setup-git.sh builds its table fixture, because
# a hand-typed one that is a character short is a fixture nobody can tell from a bug.
#
# The whole point of several assertions below is that this string never appears anywhere a human or
# a log could read it. TOKEN_B is the run of `b`s on its own: a fragment of the token is as good as
# the token to anyone reading over a shoulder, so it gets its own assertion.
TOKEN_B="$(printf 'b%.0s' $(seq 1 59))"
TOKEN="github_pat_11ABCDEFG0aaaaaaaaaaaa_$TOKEN_B"
# 87 = 93 - the three dots drawn at each end. What the tally says while the token is being pasted.
TOKEN_MID=87

# The keystrokes for a clean first run: email, Enter to confirm, name, Enter to confirm, Enter at
# the checkpoint, Enter at "Yes, I see my token" (issue #58's menu), the token, Enter at "is that
# your account?".
#
# THAT SIXTH ENTER IS THE NEW ONE, and every sequence below that reaches the token prompt needs
# one -- including the ones that come BACK to it, because re-entering ask_token draws the menu
# again. A sequence one keystroke short does not fail where the keystroke is missing: menu() eats
# the token's first line as its answer and the run fails somewhere further on, for a reason the
# assertion cannot name.
HAPPY="jdoe@stanford.edu\n|\n|Jane Doe\n|\n|\n|\n|$TOKEN\n|\n"

# ─── the happy path ────────────────────────────────────────────────────────────
sg_new
out="$(sg_tty "$HAPPY")"

sg_says "happy:greets"          intro             "$out"
sg_says "happy:asks-the-three-github-things" github.checkpoint "$out"
sg_says "happy:explains-the-token" token.intro    "$out"
sg_says "happy:succeeds"        status.all-set    "$out"
sg_has     "happy:confirms-the-address" "jdoe@stanford.edu" "$out"
sg_has     "happy:confirms-the-name"    "Jane Doe"          "$out"
# The account check, which is the cheap catch for a token pasted from the wrong browser profile.
sg_has     "happy:names-the-account"    "@janedoe"          "$out"

# EVERY ROW ENDS IN A CHECK AND NONE IN A CROSS. Eleven of them: five config commands plus
# init.defaultBranch, then the five verification rows.
assert_eq "happy:eleven-rows-succeeded" "11" "$(printf '%s' "$out" | grep -c '✓' || true)"
assert_not_contains "happy:no-row-failed" "✗" "$out"

# The commands, in the order a student watches them go by. Named individually, so a deleted one
# says which.
assert_match "happy:sets-the-email"   'git config --global user.email jdoe@stanford.edu' "$(sg_log)"
assert_match "happy:sets-the-name"    'git config --global user.name Jane Doe'           "$(sg_log)"
assert_match "happy:sets-pull-rebase" 'git config --global pull.rebase true'             "$(sg_log)"
assert_match "happy:sets-default-branch" 'git config --global init.defaultBranch main'   "$(sg_log)"
assert_match "happy:logs-in"          'gh auth login --with-token'                       "$(sg_log)"
assert_match "happy:sets-up-git-auth" 'gh auth setup-git'                                "$(sg_log)"

# And the probes, all five rows' worth.
assert_match "happy:clones"      'git clone --quiet https://github.com/cs193v-students/install-sandbox.git' "$(sg_log)"
assert_match "happy:pulls"       'git -C .* pull --quiet'  "$(sg_log)"
assert_match "happy:pushes"      'git -C .* push -q origin cs193v-setup/' "$(sg_log)"
assert_match "happy:lists-issues" 'gh issue list'    "$(sg_log)"
assert_match "happy:creates-an-issue" 'gh issue create' "$(sg_log)"
assert_match "happy:closes-the-issue"  'gh issue close --repo cs193v-students/install-sandbox 7' "$(sg_log)"
assert_match "happy:opens-a-pr"  'gh pr create'      "$(sg_log)"
# The NUMBER the pull request links, not just the word: a tidy-up once deleted the file the issue
# number is read out of, and every body said "Closes #0" while a check for `Closes #` passed. The
# number is the one gh-fake handed back from `issue create`, so this also proves setup-git read it
# rather than assuming it. Anchored at end of line, not at a closing quote: this log is written by
# the fake, which prints its argv plainly — the quoting in setup-git's own record is what
# 45-setup-git.sh sees.
assert_match "happy:pr-links-the-issue-it-opened" 'Closes #7$' "$(sg_log)"
assert_match "happy:reviews-with-a-comment" 'gh pr review --repo [^ ]* 9 --comment' "$(sg_log)"
assert_match "happy:merges"      'gh pr merge --repo [^ ]* 9 --merge' "$(sg_log)"
assert_match "happy:closes-the-second-pr" 'gh pr close' "$(sg_log)"
assert_eq "happy:deletes-its-three-branches" "3" "$(sg_count 'push -q origin --delete')"

# THE NUMBER COMES FROM THE URL gh PRINTED, not from a guess. `gh issue close ... 7` and
# `gh pr merge ... 9` are the fake's configured numbers, so these two assertions are what prove
# setup-git parses what gh handed back rather than assuming anything.
sg_new
sg_set issue_no 4242
sg_set pr_no 9999
out="$(sg_tty "$HAPPY")"
assert_match "parse:issue-number-comes-from-gh" 'issue close --repo [^ ]* 4242' "$(sg_log)"
assert_match "parse:pr-number-comes-from-gh"    'pr merge --repo [^ ]* 9999'    "$(sg_log)"

# ─── the token never gets out ──────────────────────────────────────────────────
# THE MOST IMPORTANT ASSERTION IN THIS FILE. read_secret reads the token one character at a time
# with echo turned off at the terminal, drawing a tally rather than the characters, so it never
# reaches the screen; it is passed to gh over stdin so it never reaches argv; and the row that names
# the login command is redacted. Each of those three is a separate place it could leak, and tmux
# keeps 50,000 lines of scrollback per tab while students screenshot their terminals for help.
sg_new
out="$(sg_tty "$HAPPY")"
assert_not_contains "secret:not-in-the-transcript" "$TOKEN" "$out"
assert_not_contains "secret:not-in-the-command-log" "$TOKEN" "$(sg_log)"
# Not even a recognisable chunk of it: a partial echo would be as good as the whole thing to
# anyone reading over a shoulder.
assert_not_contains "secret:no-fragment-in-the-transcript" "$TOKEN_B" "$out"
sg_has "secret:login-row-is-redacted" "gh auth login --with-token < your-token" "$out"

# ─── what IS shown while it is pasted ──────────────────────────────────────────
# The tally, which is issue #53's second half: `read -rs` showed nothing at all, so a paste that
# silently failed looked exactly like one that worked. THE COUNT IS THE FEEDBACK — six dots and a
# number, not 93 dots, because 93 dots beside the prompt is about 108 columns and wraps on the
# 80-column terminal MANUAL.md says to test in.
sg_has "tally:counts-the-hidden-characters" "$TOKEN_MID more characters" "$out"

tally="$(sg_final "$out" "$TOKEN_MID more characters")"
assert_eq "tally:draws-six-dots-not-ninety-three" "6" \
          "$(printf '%s' "$tally" | grep -o '•' | wc -l | tr -d ' ')"

# NO WRAPPED LINE AT THAT PROMPT. Measured in display columns rather than bytes, because a • is
# three bytes and mawk's length() would score this at 3× and pass vacuously — the same trap box()
# records. A line that has wrapped cannot be redrawn with \r, which is how the tally is drawn at all.
cols="$(printf '%s' "$tally" | LC_ALL=C awk '{ t = $0; gsub(/[\200-\277]/, "", t); print length(t) }')"
assert_eq "tally:fits-an-80-column-terminal" "yes" \
          "$([ "${cols:-999}" -le 80 ] && printf 'yes' || printf '%s columns' "$cols")"

# THE CURSOR IS VISIBLE WHILE IT WAITS, which is issue #53's first half: main() hides it for the
# whole run, and a prompt with no cursor in it cannot be told from a program that has stopped.
# Asserted as an ORDERING — the show sequence immediately ahead of the prompt — because a bare
# "[?25h appears somewhere" would pass on the one the EXIT trap emits at the end of every run.
assert_match "cursor:shown-at-the-token-prompt" "$SG_ESC\[\?25h.{0,60}Your token" \
             "$(printf '%s' "$out" | tr -d '\r')"
# And the same for the two prompts that echo normally, which were just as cursorless.
assert_match "cursor:shown-at-the-email-prompt" "$SG_ESC\[\?25h" \
             "$(printf '%s' "$out" | tr -d '\r' | sed -n '/email address/,$p' | head -1)"

# ─── the two ways to get a token (issue #58) ───────────────────────────────────
# The link screen ends in a choice, and the by-hand steps sit behind it. Printing both to
# everybody is what made this screen 53 rows on an 80-column terminal, of which the container's
# tmux leaves 23 visible — so the student who followed the link arrived at `Your token:` with the
# link itself scrolled off. Two things are asserted here: the fallback is REACHABLE, and it is out
# of the way of the student who did not need it.
sg_new
out="$(sg_tty "$HAPPY")"
sg_says "prefill:offers-the-link"  token.prefill "$out"
sg_says "prefill:offers-a-way-out" opt.by-hand   "$out"
# THE LINK ITSELF, and where to look for it MOVED with issue #67. The prefilled parameters are the
# whole point of offering the link, and they used to be on the screen because the screen carried the
# whole 157-character URL. They are now behind a redirect, so what the student sees is the short URL
# and what carries the parameters is the argument setup-git handed shortlink -- which is why the
# fake logs its argv. Both halves are asserted, because either one alone would pass while the
# student was being shown a link to nothing. 45-setup-git.sh still checks each parameter.
sg_has "prefill:the-link-is-short" "http://localhost:8084/magic-token-link" "$out"
assert_eq "prefill:shortlink-was-asked-for-the-prefilled-url" "1" \
          "$(sg_count 'shortlink https://github.com/settings/personal-access-tokens/new[?]name=CS193V')"
sg_says_not "prefill:hides-the-by-hand-steps" token.byhand "$out"
# Generating a token takes two clicks. A student who stops at the first sees no token at all and
# has nothing to paste, which looks from their side like the link having failed.
sg_has "prefill:names-the-confirmation" "confirm when GitHub asks you to" "$out"
sg_says "prefill:the-link-path-still-works" status.all-set "$out"

# ─── the link fits an 80-column terminal (issue #67) ───────────────────────────
# THE REGRESSION TEST FOR #67, and it has to live here rather than in 20-messages.sh. The
# catalogue line is `    {{URL}}`: what wraps is the VALUE setup-git substitutes, and only a run
# of the script produces that. A catalogue lint can bound what the placeholder costs at worst; it
# cannot see which URL the script chose to pass.
#
# WHY WRAPPING COSTS A TOKEN rather than merely looking untidy: tmux.conf hands text selection
# back to the terminal (SHIFT+drag), and the terminal selects what it has DRAWN — so a URL long
# enough to wrap comes back with a newline in the middle of it. Some terminals then send GitHub
# only the first half, the page silently drops the parameters that were in the second, and the
# student ends up holding a token with permissions the course cannot use. The symptom arrives
# three screens later as a bare 404.
record "prefill:widest-row" "$(sg_widest_row "$out") columns"
assert_eq "prefill:the-link-fits-an-80-column-terminal" "" "$(sg_rows_over 80 "$out")"

# THE SERVER IS ENDED WHEN THE SCREEN IS DONE. It would go on its own after fifteen minutes, but a
# student who finished in two should not be holding a forwarded port for the other thirteen -- that
# is a port their own dev server wants. The pid comes out of the log rather than the pidfile
# because sg_cleanup deletes the directory the pidfile was in.
slpid="$(sg_log | sed -n 's/^shortlink-pid //p' | tail -1)"
if [ -n "$slpid" ]; then
    assert_fail "prefill:the-redirect-server-was-ended" kill -0 "$slpid"
else
    fail "prefill:the-redirect-server-was-ended" "the fake never recorded a pid"
fi

# ─── with no shortlink at all: the long URL, and nothing broken ────────────────
# A TA's Mac has no /usr/local/bin/shortlink, and 45-setup-git.sh drives this script there. The
# real shortlink degrades the same way when no port is forwarded, so this one case covers both --
# and what it must show is the URL this screen printed before any of this existed.
sg_new
rm -f "$SGSHIM/shortlink"
out="$(sg_tty "$HAPPY")"
sg_says "noshortlink:still-offers-the-link" token.prefill "$out"
sg_has  "noshortlink:falls-back-to-the-long-url" \
        "settings/personal-access-tokens/new?name=CS193V" "$out"
sg_says "noshortlink:the-flow-still-completes" status.all-set "$out"
# AND IT WRAPS, which is the measurement that says the short link is doing the work rather than
# something else having changed. Recorded rather than asserted: this is the old behaviour, and a
# test that demanded it stay broken would be the wrong shape.
record "noshortlink:widest-row" "$(sg_widest_row "$out") columns"

# Arrowing down is the only way to the by-hand steps, and it has to end at the same prompt.
BYHAND="jdoe@stanford.edu\n|\n|Jane Doe\n|\n|\n|\033[B|\n|$TOKEN\n|\n"
sg_new
out="$(sg_tty "$BYHAND")"
sg_says "byhand:shows-the-steps"      token.byhand   "$out"
sg_says "byhand:then-accepts-a-token" status.all-set "$out"
# THE THREE THINGS THE OLD STEPS GOT WRONG about GitHub's page, each asserted by the phrase that
# fixes it, because each one stopped a student who followed the instructions exactly:
#   * the page is opened directly, so there is no "Generate new token" button to click first;
#   * the section is called Permissions, not Repository permissions;
#   * the three permissions have to be ADDED before they can be set to Read and write, and
#     nothing on the page lists them until they are.
sg_has_not "byhand:no-generate-new-token-step"        "Generate new token"         "$out"
sg_has     "byhand:names-the-permissions-section"     "Under Permissions"          "$out"
sg_has     "byhand:says-a-permission-must-be-added"   "Add permissions"            "$out"
sg_has     "byhand:says-they-arrive-read-only"        "added as Read-only"         "$out"

# ─── the four permission failures ──────────────────────────────────────────────
# One injected failure each, and three things asserted every time: the row that failed carries a
# cross, the rows before it carry checks, and NOTHING AFTER IT RAN. That last one is what keeps a
# failure honest — a probe list that carried on past a failure would report the last permission
# rather than the first broken one.
#
# The keystrokes end in \033[B\033[B\n: down, down, Enter — the third option, "I'm stuck", which
# is what produces the staff box. Reaching it by arrow key rather than by digit is deliberate:
# this is the only place the third menu entry is exercised at all.
STUCK='|\033[B|\033[B|\n'

sg_new
sg_set fail_at 'clone'
out="$(sg_tty "$HAPPY$STUCK")"
sg_says "fail-clone:says-which-repo-it-cannot-reach" err.clone "$out"
sg_has     "fail-clone:names-the-resource-owner-first"  "Resource owner" "$out"
assert_contains "fail-clone:the-row-failed" "✗" "$out"
assert_eq       "fail-clone:nothing-after-it-ran" "0" "$(sg_count 'git pull')"
sg_says "fail-clone:ends-with-the-staff-box" err.setup-failed "$out"
# THE BOX, NOT THE TRANSCRIPT, and that distinction is the whole of issue #54: the command and the
# exit code used to be prose above the box, so a needle looked for anywhere in the output said
# nothing about what a student actually pastes to staff. sg_box cuts the box out; assert_says
# flattens the walls away and rejoins whatever box() wrapped.
sgbox="$(sg_box "$out")"
assert_says "fail-clone:box-names-the-command"  "Failed command: git clone --quiet" "$sgbox"
assert_says "fail-clone:box-quotes-the-failure" "remote: Permission to"             "$sgbox"

sg_new
sg_set fail_at 'push -q origin cs193v-setup'
out="$(sg_tty "$HAPPY$STUCK")"
sg_says "fail-push:blames-contents" err.push "$out"
sg_has     "fail-push:says-read-and-write" "Read and write" "$out"
sg_has     "fail-push:says-the-token-can-be-kept" "You do not need to make a new token" "$out"
assert_eq       "fail-push:clone-and-pull-still-passed" "2" \
                "$(sg_plain "$out" | grep -oE '✓ git (clone|pull)' | grep -c . || true)"
assert_eq       "fail-push:nothing-after-it-ran" "0" "$(sg_count 'gh issue')"

sg_new
sg_set fail_at 'issue create'
out="$(sg_tty "$HAPPY$STUCK")"
sg_says "fail-issue:blames-issues" err.issues "$out"
sg_says_not "fail-issue:does-not-blame-contents" err.push "$out"
assert_eq       "fail-issue:nothing-after-it-ran" "0" "$(sg_count 'gh pr create')"

sg_new
sg_set fail_at 'pr create'
out="$(sg_tty "$HAPPY$STUCK")"
sg_says "fail-pr:blames-pull-requests" err.prs "$out"
sg_says_not "fail-pr:does-not-blame-issues" err.issues "$out"

# ─── the token created under the wrong account ─────────────────────────────────
# The most likely mistake and the only unrecoverable one: resource owner cannot be changed after
# a token exists. It produces exactly the same 404 as three other causes, so the message is
# earned by evidence — the repositories the token CAN see belong to the student and none belong to
# the organization — and falls back to the four-item checklist when the evidence is not there.
sg_new
sg_set fail_at 'clone'
sg_set fail_rc 128
sg_set fail_err 'fatal: repository not found'
sg_set owners 'janedoe'
out="$(sg_tty "$HAPPY$STUCK")"
sg_says "wrong-owner:says-so-outright" err.clone-wrong-owner "$out"
sg_has     "wrong-owner:names-the-account" "@janedoe" "$out"
sg_says_not "wrong-owner:not-the-generic-checklist" err.clone "$out"

# AND THE BOX STILL QUOTES THE CLONE (issue #64). The evidence for the message above comes from
# token_owner_wrong, which is a run_timeout, and run_timeout writes RT_OUT — so the staff box used
# to quote that probe's answer, `janedoe`, under a heading naming `git clone`. Measured: this is
# the box a student sent staff for every clone and pull failure, not an edge case.
sgbox="$(sg_box "$out")"
assert_says "wrong-owner:box-quotes-the-clone-failure"    "fatal: repository not found" "$sgbox"
assert_says "wrong-owner:box-reports-the-clone-exit-code" "Exit code: 128"              "$sgbox"
sg_has_not  "wrong-owner:box-does-not-quote-the-owner-probe" "janedoe" "$sgbox"

# Ambiguous evidence must NOT produce the specific message. An empty list means the token can see
# nothing at all, which is consistent with several causes, and guessing wrong here sends a student
# to throw away a token that was fine.
sg_new
sg_set fail_at 'clone'
sg_set owners ''
out="$(sg_tty "$HAPPY$STUCK")"
sg_says "ambiguous-owner:falls-back-to-the-checklist" err.clone "$out"
sg_says_not "ambiguous-owner:no-unearned-accusation" err.clone-wrong-owner "$out"

# And when the organization IS in the list, the token's owner is not the problem.
sg_new
sg_set fail_at 'clone'
sg_set owners 'janedoe cs193v-students'
out="$(sg_tty "$HAPPY$STUCK")"
sg_says "org-visible:falls-back-to-the-checklist" err.clone "$out"
sg_says_not "org-visible:no-unearned-accusation" err.clone-wrong-owner "$out"

# ─── the three ways out of a failure ───────────────────────────────────────────
# "I was able to follow those instructions" runs the probes AGAIN with the same token, which is
# the whole point: a student who fixed a permission on the token they already pasted must not be
# asked to paste it again.
sg_new
sg_set fail_at 'issue create'
out="$(sg_tty "$HAPPY|\n$STUCK")"
assert_eq "retry:probes-run-a-second-time" "2" "$(sg_count 'gh issue create')"
assert_eq "retry:does-not-ask-for-the-token-again" "1" \
          "$(sg_asks "$out" "$(sg_phrase prompt.token)")"

# "Let me re-enter my access token" goes back to the token prompt and nowhere further back: the
# name and the address are already right and asking for them again would be punishing the
# student for our failure.
sg_new
sg_set fail_at 'issue create'
out="$(sg_tty "$HAPPY|\033[B|\n|\n|$TOKEN\n|\n$STUCK")"
assert_eq "retoken:asks-for-the-token-twice" "2" \
          "$(sg_asks "$out" "$(sg_phrase prompt.token)")"
assert_eq "retoken:asks-for-the-email-once" "1" \
          "$(printf '%s' "$out" | grep -c 'What is your @stanford.edu' || true)"
assert_eq "retoken:asks-for-the-name-once" "1" \
          "$(printf '%s' "$out" | grep -c 'What is your full name' || true)"

# "I'm stuck" is the only path that ends in the staff box, and it has to carry the command, the
# exit code and the command's output — the three things staff cannot diagnose without, all three
# INSIDE the box, because what a student sends is what they can select (issue #54).
sg_new
sg_set fail_at 'issue create'
sg_set fail_rc 42
sg_set fail_err 'gh: HTTP 403: Resource not accessible by personal access token'
out="$(sg_tty "$HAPPY$STUCK")"
sgbox="$(sg_box "$out")"
assert_ne   "stuck:the-box-is-drawn" "" "$sgbox"
assert_says "stuck:box-names-the-command"     "Failed command: gh issue create" "$sgbox"
assert_says "stuck:box-reports-the-exit-code" "Exit code: 42"                   "$sgbox"
assert_says "stuck:box-quotes-the-output" \
            "Resource not accessible by personal access token" "$sgbox"
assert_eq "stuck:the-box-is-closed" "" "$(printf '%s\n' "$sgbox" | box_problems)"

# ─── the wrong-account branch ──────────────────────────────────────────────────
# Answering "no, that's not my account" goes back to the token prompt without running a single
# probe: there is nothing to learn from probing a token that belongs to somebody else.
sg_new
out="$(sg_tty "jdoe@stanford.edu\n|\n|Jane Doe\n|\n|\n|\n|$TOKEN\n|\033[B|\n|\n|$TOKEN\n|\n")"
assert_eq "wrong-account:asks-for-the-token-twice" "2" \
          "$(sg_asks "$out" "$(sg_phrase prompt.token)")"
sg_says "wrong-account:eventually-succeeds" status.all-set "$out"

# ─── the environmental failures ────────────────────────────────────────────────
# Neither of these is the student's token, and blaming it would send them to edit something that
# was already correct. A whole lab section starting at once really does trip the secondary rate
# limit, and it looks exactly like a permission error unless something reads the message.
sg_new
sg_set fail_at 'clone'
sg_set fail_err 'fatal: unable to access: Could not resolve host: github.com'
out="$(sg_tty "$HAPPY")"
sg_says "network:says-the-network" err.network "$out"
sg_says_not "network:does-not-blame-the-token" err.clone "$out"

sg_new
sg_set fail_at 'issue create'
sg_set fail_err 'gh: You have exceeded a secondary rate limit. Please wait a few minutes.'
out="$(sg_tty "$HAPPY")"
sg_says "ratelimit:says-to-wait" err.rate-limit "$out"
sg_says_not "ratelimit:does-not-blame-the-token" err.issues "$out"

# ─── validation, as the student meets it ───────────────────────────────────────
# The unit suite covers the verdicts exhaustively; what this covers is the loop around them —
# that a rejection re-prompts on the spot rather than starting the screen over, and that the two
# email messages are actually different where the transcript in issue #49 says they are.
sg_new
out="$(sg_tty "not an email\n|me@gmail.com\n|me@nested.stanford.edu\n|   jdoe@stanford.edu   \n|\n|Jane Doe\n|\n|\n|\n|$TOKEN\n|\n")"
assert_eq "retry-email:complains-twice-about-the-shape" "2" \
          "$(printf '%s' "$out" | grep -c 'not a valid @stanford.edu' || true)"
assert_says "retry-email:has-a-separate-message-for-a-subdomain" \
            "Please use your regular @stanford.edu email address" "$out"
sg_has "retry-email:confirms-the-trimmed-address" "You entered jdoe@stanford.edu" "$out"
sg_says "retry-email:still-gets-there" status.all-set "$out"

# "No, I want to retype that" asks the same question again rather than moving on.
sg_new
out="$(sg_tty "typo@stanford.edu\n|\033[B|\n|jdoe@stanford.edu\n|\n|Jane Doe\n|\n|\n|\n|$TOKEN\n|\n")"
assert_eq "retype-email:asks-again" "2" \
          "$(printf '%s' "$out" | grep -c 'What is your @stanford.edu' || true)"
assert_match "retype-email:configures-the-second-answer" \
             'user.email jdoe@stanford.edu' "$(sg_log)"
assert_not_match "retype-email:never-configures-the-first" \
                 'user.email typo@stanford.edu' "$(sg_log)"

# A classic token is turned away before anything runs, with its own message: one with the `repo`
# scope would very nearly work, so "that is not a token" would be both wrong and unhelpful.
sg_new
out="$(sg_tty "jdoe@stanford.edu\n|\n|Jane Doe\n|\n|\n|\n|ghp_16C7e42F292c6912E7710c838347Ae178B4a\n|$TOKEN\n|\n")"
sg_says "classic-token:says-which-kind-it-is" err.token-classic "$out"
assert_eq "classic-token:nothing-ran-with-it" "0" "$(sg_count 'gh auth login.*ghp_')"
sg_says "classic-token:then-accepts-the-right-one" status.all-set "$out"

sg_new
out="$(sg_tty "jdoe@stanford.edu\n|\n|Jane Doe\n|\n|\n|\n|hello\n|$TOKEN\n|\n")"
sg_says "junk-token:says-what-one-looks-like" err.token-shape "$out"
# FIVE DOTS AND NO COUNT for five characters: below SG_DOTS_MAX the tally is the dots themselves,
# because "... -1 more characters ..." is what a short typo would otherwise render as.
assert_eq "junk-token:draws-one-dot-per-character" "5" \
          "$(sg_final "$out" "Your token:" | grep -o '•' | wc -l | tr -d ' ')"
sg_has_not "junk-token:no-count-for-five-characters" "more characters" \
           "$(sg_final "$out" "Your token:")"

# A TRUNCATED PASTE IS THE CASE ISSUE #53 DREW, and it was accepted outright before that issue: the
# check was the prefix, and half a token still has the prefix. It reaches `gh auth login` now only
# in the sense that the good one pasted after it does.
sg_new
HALF="$(printf '%s' "$TOKEN" | cut -c1-50)"
out="$(sg_tty "jdoe@stanford.edu\n|\n|Jane Doe\n|\n|\n|\n|$HALF\n|$TOKEN\n|\n")"
sg_says "partial-token:says-it-is-only-part-of-one" err.token-partial "$out"
sg_says_not "partial-token:does-not-say-it-is-not-a-token" err.token-shape "$out"
# 44 = 50 - the six dots. The number a student compares against the one a whole token shows.
sg_has "partial-token:counts-what-did-arrive" "44 more characters" "$out"
assert_eq "partial-token:nothing-ran-with-it" "1" "$(sg_count 'gh auth login')"
sg_says "partial-token:then-accepts-the-right-one" status.all-set "$out"

# ─── the checkpoint's escape hatch ─────────────────────────────────────────────
# "Uh oh, something's wrong" at the GitHub checkpoint has to stop, not carry on into a token
# prompt the student cannot answer.
sg_new
out="$(sg_tty "jdoe@stanford.edu\n|\n|Jane Doe\n|\n|\033[B|\n")"
sg_says "checkpoint-help:ends-in-the-staff-box" err.setup-failed "$out"
sg_says_not "checkpoint-help:never-asks-for-a-token" token.paste "$out"
assert_eq "checkpoint-help:configures-nothing" "0" \
          "$(sg_count 'git config --global [a-z.]+ .')"

# ─── a failed config command ───────────────────────────────────────────────────
# The other route into the staff box, and the one issue #49 spells out: a `git config` that fails
# is not something a student can act on, so it goes straight to staff with the command and what the
# command said, rather than through a menu.
sg_new
sg_set fail_at 'config --global pull.rebase'
sg_set fail_rc 6
sg_set fail_err 'error: could not lock config file /home/student/.config/git/config'
out="$(sg_tty "$HAPPY")"
sg_says "config-fails:goes-to-staff" err.setup-failed "$out"
sgbox="$(sg_box "$out")"
assert_says "config-fails:box-names-the-command" \
            "Failed command: git config --global pull.rebase true" "$sgbox"
assert_says "config-fails:box-reports-the-exit-code" "Exit code: 6"          "$sgbox"
assert_says "config-fails:box-quotes-the-output" "could not lock config file" "$sgbox"
assert_eq "config-fails:never-reached-the-login" "0" "$(sg_count 'gh auth login')"

# ─── the second run ────────────────────────────────────────────────────────────
# Re-running is the normal case, not an edge one: a token expires, a permission was wrong, or
# --rebuild --logout cleared the volumes. Re-asking for a name and an address that are already
# right is the wrong answer to any of those.
sg_new
sg_touch auth_token
printf 'user.name=Jane Doe\nuser.email=jdoe@stanford.edu\n' > "$SGSHIM/gitconfig"
out="$(sg_tty '\n')"
sg_says "second-run:says-it-is-already-set-up" already.configured "$out"
sg_has "second-run:shows-the-name"    "Jane Doe"          "$out"
sg_has "second-run:shows-the-address" "jdoe@stanford.edu" "$out"
sg_has "second-run:shows-the-account" "@janedoe"          "$out"
sg_says_not "second-run:does-not-ask-again" prompt.email "$out"
sg_says "second-run:just-checks-and-passes" status.all-set "$out"
assert_eq "second-run:configures-nothing" "0" \
          "$(sg_count 'git config --global [a-z.]+ .')"

# "Start over" does ask again, and that is the option that exists for a student whose name or
# address was wrong.
sg_new
sg_touch auth_token
printf 'user.name=Wrong Name\nuser.email=wrong@stanford.edu\n' > "$SGSHIM/gitconfig"
out="$(sg_tty "\033[B|\n|jdoe@stanford.edu\n|\n|Jane Doe\n|\n|\n|\n|$TOKEN\n|\n")"
sg_has "start-over:asks-for-the-address-again" "What is your @stanford.edu" "$out"
assert_match "start-over:configures-the-new-answer" 'user.email jdoe@stanford.edu' "$(sg_log)"

# And "nothing, thanks" changes nothing at all.
sg_new
sg_touch auth_token
printf 'user.name=Jane Doe\nuser.email=jdoe@stanford.edu\n' > "$SGSHIM/gitconfig"
out="$(sg_tty '\033[B|\033[B|\n')"
assert_eq "quit:runs-no-probes" "0" "$(sg_count 'git clone')"
sg_says_not "quit:does-not-claim-success" status.all-set "$out"

# An unfinished setup must NOT take the second-run screen. A git config with no working token is
# not "already set up" whatever the config says, and the ordinary flow is the right place to be.
sg_new
printf 'user.name=Jane Doe\nuser.email=jdoe@stanford.edu\n' > "$SGSHIM/gitconfig"
out="$(sg_tty "$HAPPY")"
sg_says_not "no-token:is-not-already-configured" already.configured "$out"
sg_says "no-token:asks-from-the-start" prompt.email "$out"

# ─── tidying up after itself ───────────────────────────────────────────────────
# A student who gives up halfway should not leave a branch and an open issue behind in a
# repository the whole class can see. Best-effort and silent: none of it is their business.
sg_new
sg_set fail_at 'gh pr create'
out="$(sg_tty "$HAPPY$STUCK")"
assert_eq "cleanup:deletes-the-branches-it-pushed" "3" "$(sg_count 'push -q origin --delete')"
assert_match "cleanup:closes-the-issue-it-opened" 'gh issue close' "$(sg_log)"
sg_has_not "cleanup:says-nothing-about-it" "--delete" "$out"

# ─── nothing invisible in what a student copies ────────────────────────────────
# A blank line inside a message is a blank line. emph_stream used to end one with two spaces and a
# reset sequence — awk's split() returns 0 fields for an empty string, 0 is even, and the branch
# that closes an unpaired *asterisk* fired on nothing. Neither a screen nor any assertion here
# could show it, because both strip the escapes; a student pasting a screenful into a help request
# carries it. Checked against the whole transcript rather than one message, since every message
# with a paragraph break in it was affected.
sg_new
out="$(sg_tty "$HAPPY")"
assert_eq "copy:no-line-is-invisible-whitespace" "" \
          "$(sg_rows "$out" | grep -nE '^[[:space:]]+$' | head -3 | tr '\n' ' ')"

# ─── the cursor comes back ─────────────────────────────────────────────────────
# run_step hides the cursor for the duration of a row. A script that exits with it hidden leaves
# the student typing blind in that terminal for everything they do afterwards — ERRORS.md B18,
# found by watching a real install. Asserted on both endings, because the failure path installs
# the same trap and is the one more likely to be missed.
sg_new
out="$(sg_tty "$HAPPY")"
assert_contains "cursor:hidden-during-the-rows" "[?25l" "$out"
assert_contains "cursor:restored-on-success"    "[?25h" "$out"
sg_new
sg_set fail_at 'clone'
out="$(sg_tty "$HAPPY$STUCK")"
assert_contains "cursor:restored-on-failure"    "[?25h" "$out"

# ─── and so does the terminal ──────────────────────────────────────────────────
# read_secret turns echo off AT THE TERMINAL for the length of a paste rather than leaving it to
# `read -s` per character — see the comment there for what that buys. What it costs is a second
# thing that has to be given back, with a worse failure than the cursor's if it is not: a student
# typing invisibly for the rest of the session. sg_cleanup gives it back on every path the cursor is
# given back on, but no transcript can show tty state — so this asks the pty itself, afterwards.
sg_new
SG_RUN="bash -c 'env $SG_ENV TMPDIR=$SGSHIM CS193V_SGSHIM=$SGSHIM bash $SG_SETUP_GIT; stty -a'"
out="$(sg_tty "$HAPPY")"
SG_RUN=''
sg_says "tty:the-run-still-succeeds" status.all-set "$out"
# Word-bounded, because stty -a also prints echoe, echok, echoctl and echoke.
assert_match     "tty:echo-is-on-afterwards"     '(^| )echo( |$)'    "$(sg_plain "$out")"
assert_not_match "tty:echo-is-not-left-off"      '(^| )-echo( |$)'   "$(sg_plain "$out")"
assert_not_match "tty:canonical-mode-is-restored" '(^| )-icanon( |$)' "$(sg_plain "$out")"
