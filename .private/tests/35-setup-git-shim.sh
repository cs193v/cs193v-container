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

# SC2034: SG_RUN is set here and read by sg_run in lib/setup-git-shim.sh:91, which this file
# sources -- invisible without -x, and -x cannot resolve a path built from $0. File-level rather
# than per-line because it is written at two sites and shellcheck names only one of them.
# shellcheck disable=SC2034
set -u
. "$(dirname -- "$0")/lib/assert.sh"
. "$(dirname -- "$0")/lib/setup-git-shim.sh"

cd "$REPO" || exit 1

# NO require_cmd script: nothing here uses script(1) any more. lib/ptyrun.py replaced it because
# BSD script cannot deliver keystrokes and macOS has no GNU one to install -- so demanding it would
# refuse a machine over a tool the suite does not touch. ptyrun needs python3, which the preflight
# in run-tests.sh checks for every tier.
# sg_rows_over, sg_widest_row and box_problems all measure with python3, and two of the
# assertions they feed read the empty string as their happy answer -- so this suite had five of
# #79's twenty-six vacuous passes and asked nothing of the interpreter at all.
require_python3

# THIS SUITE HAD NO TRAP AT ALL, so sg_cleanup_all was never called and every shim directory it
# made survived the run — 241 of them were in /tmp when #76 was measured. Both ends, the way
# 60-container.sh does it: the trap for a normal exit, the sweep for a run that was killed.
trap 'sg_cleanup_all' EXIT
record "sg:leftover-dirs-from-an-earlier-run" "$(sg_sweep_stale)"

SG_SETUP_GIT="$PRIVATE/files/setup-git"
SGM="$PRIVATE/files/setup-git-messages.txt"
# Every run needs these four: two to find the helper and the catalogue in the CHECKOUT rather than
# at the image paths, and two to pin the organization and the date, so a staff member with either
# exported in their shell gets the same answers CI does. sg_run appends TMPDIR and CS193V_SGSHIM
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

# THE CONVERSATION IS A FIXTURE NOW, not a keystroke string per call site:
# fixtures/setup-git-flows.txt describes each screen setup-git draws, by catalogue key, and what
# is answered at it. `sg_run CASE FLOW...` walks that table -- waiting for each screen and for the
# terminal to be in the state that read implies before it types -- and reports the case's
# conversation as one named result. See lib/setup-git-shim.sh for what the clock it replaced was
# measured doing.
#
# THE THREE STRINGS THAT USED TO LIVE HERE were HAPPY, BYHAND and STUCK, and 26 of the 38 runs
# below were built from them by concatenation. They are `[[happy]]`, `[[happy-by-hand]]` and
# `[[stuck]]` in the fixture, and the sixth keystroke this comment used to have to explain --
# "and every sequence below that reaches the token prompt needs one" -- is a step in `[[get-token]]`
# that says which screen it answers.
SG_DEFAULT_TOKEN="$TOKEN"

# ─── the happy path ────────────────────────────────────────────────────────────
sg_new
sg_run happy happy

sg_says "happy:greets"          intro             "$SG_OUT"
sg_says "happy:asks-the-three-github-things" github.checkpoint "$SG_OUT"
sg_says "happy:explains-the-token" token.intro    "$SG_OUT"
sg_says "happy:succeeds"        status.all-set    "$SG_OUT"
sg_has     "happy:confirms-the-sunetid"  "You entered jdoe"  "$SG_OUT"
sg_has     "happy:confirms-the-name"    "Jane Doe"          "$SG_OUT"
# THE ADDRESS IS DERIVED NOW (issue #92) and nobody types it, so the screen that names it is the
# GitHub checkpoint. A student never shown it anywhere cannot check it is on their account.
sg_has     "happy:names-the-derived-address" "jdoe@stanford.edu" "$SG_OUT"
# The account check, which is the cheap catch for a token pasted from the wrong browser profile.
sg_has     "happy:names-the-account"    "@janedoe"          "$SG_OUT"

# EVERY ROW ENDS IN A CHECK AND NONE IN A CROSS. Twelve of them: five config commands plus
# init.defaultBranch and cs193v.sunetid, then the five verification rows.
sg_has_times "happy:twelve-rows-succeeded" 12 "✓" "$SG_OUT"
assert_not_contains "happy:no-row-failed" "✗" "$SG_OUT"

# The commands, in the order a student watches them go by. Named individually, so a deleted one
# says which.
assert_match "happy:sets-the-email"   'git config --global user.email jdoe@stanford.edu' "$(sg_log)"
# THE ONE ROW THAT MAKES A SECOND RUN POSSIBLE. The repository is named after the student now, so
# something has to remember which student this is. The address above would very nearly do it, and
# does not, because a student may legitimately set a different commit address afterwards.
assert_match "happy:sets-the-sunetid" 'git config --global cs193v.sunetid jdoe'          "$(sg_log)"
assert_match "happy:sets-the-name"    'git config --global user.name Jane Doe'           "$(sg_log)"
assert_match "happy:sets-pull-rebase" 'git config --global pull.rebase true'             "$(sg_log)"
assert_match "happy:sets-default-branch" 'git config --global init.defaultBranch main'   "$(sg_log)"
assert_match "happy:logs-in"          'gh auth login --with-token'                       "$(sg_log)"
assert_match "happy:sets-up-git-auth" 'gh auth setup-git'                                "$(sg_log)"

# And the probes, all five rows' worth.
assert_match "happy:clones"      'git clone --quiet https://github.com/cs193v-students/sandbox-jdoe.git' "$(sg_log)"
assert_match "happy:pulls"       'git -C .* pull --quiet'  "$(sg_log)"
assert_match "happy:pushes"      'git -C .* push -q origin cs193v-setup/' "$(sg_log)"
assert_match "happy:lists-issues" 'gh issue list'    "$(sg_log)"
assert_match "happy:creates-an-issue" 'gh issue create' "$(sg_log)"
assert_match "happy:closes-the-issue"  'gh issue close --repo cs193v-students/sandbox-jdoe 7' "$(sg_log)"
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
sg_run parse happy
assert_match "parse:issue-number-comes-from-gh" 'issue close --repo [^ ]* 4242' "$(sg_log)"
assert_match "parse:pr-number-comes-from-gh"    'pr merge --repo [^ ]* 9999'    "$(sg_log)"

# ─── the token never gets out ──────────────────────────────────────────────────
# THE MOST IMPORTANT ASSERTION IN THIS FILE. read_secret reads the token one character at a time
# with echo turned off at the terminal, drawing a tally rather than the characters, so it never
# reaches the screen; it is passed to gh over stdin so it never reaches argv; and the row that names
# the login command is redacted. Each of those three is a separate place it could leak, and tmux
# keeps 50,000 lines of scrollback per tab while students screenshot their terminals for help.
sg_new
sg_run secret happy
# THROUGH sg_unwrap, since #155: these compared against the RAW transcript, so a token that
# reached the screen inside anything box() had wrapped -- which is every error box -- would have
# been split across two rows and matched neither needle. No leak was found by adding it; the
# assertion simply now covers the shape it always claimed to.
assert_not_contains "secret:not-in-the-transcript" "$TOKEN" "$(sg_unwrap "$SG_OUT")"
assert_not_contains "secret:not-in-the-command-log" "$TOKEN" "$(sg_unwrap "$(sg_log)")"
# Not even a recognisable chunk of it: a partial echo would be as good as the whole thing to
# anyone reading over a shoulder.
assert_not_contains "secret:no-fragment-in-the-transcript" "$TOKEN_B" "$(sg_unwrap "$SG_OUT")"
sg_has "secret:login-row-is-redacted" "gh auth login --with-token < your-token" "$SG_OUT"

# ─── what IS shown while it is pasted ──────────────────────────────────────────
# The tally, which is issue #53's second half: `read -rs` showed nothing at all, so a paste that
# silently failed looked exactly like one that worked. THE COUNT IS THE FEEDBACK — six dots and a
# number, not 93 dots, because 93 dots beside the prompt is about 108 columns and wraps on the
# 80-column terminal MANUAL.md says to test in.
sg_has "tally:counts-the-hidden-characters" "$TOKEN_MID more characters" "$SG_OUT"

tally="$(sg_final "$SG_OUT" "$TOKEN_MID more characters")"
sg_has_times "tally:draws-six-dots-not-ninety-three" 6 "•" "$tally"

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
             "$(printf '%s' "$SG_OUT" | do_tr -d '\r')"
# And the same for the two prompts that echo normally, which were just as cursorless. The needle is
# the PROMPT rather than the words "email address": those now appear first in the GitHub
# checkpoint's signup link, three screens later, where the cursor is hidden and the assertion was
# passing on nothing.
assert_match "cursor:shown-at-the-sunetid-prompt" "$SG_ESC\[\?25h" \
             "$(printf '%s' "$SG_OUT" | do_tr -d '\r' | sed -n '/What is your SUNetID/,$p' | head -1)"

# ─── the two ways to get a token (issue #58) ───────────────────────────────────
# The link screen ends in a choice, and the by-hand steps sit behind it. Printing both to
# everybody is what made this screen 53 rows on an 80-column terminal, of which the container's
# tmux leaves 23 visible — so the student who followed the link arrived at `Your token:` with the
# link itself scrolled off. Two things are asserted here: the fallback is REACHABLE, and it is out
# of the way of the student who did not need it.
sg_new
sg_run prefill happy
sg_says "prefill:offers-the-link"  token.prefill "$SG_OUT"
sg_says "prefill:offers-a-way-out" opt.by-hand   "$SG_OUT"
# THE LINK ITSELF, and where to look for it MOVED with issue #67. The prefilled parameters are the
# whole point of offering the link, and they used to be on the screen because the screen carried the
# whole 157-character URL. They are now behind a redirect, so what the student sees is the short URL
# and what carries the parameters is the argument setup-git handed shortlink -- which is why the
# fake logs its argv. Both halves are asserted, because either one alone would pass while the
# student was being shown a link to nothing. 45-setup-git.sh still checks each parameter.
sg_has "prefill:the-link-is-short" "http://localhost:8084/magic-token-link" "$SG_OUT"
assert_eq "prefill:shortlink-was-asked-for-the-prefilled-url" "1" \
          "$(sg_count 'shortlink https://github.com/settings/personal-access-tokens/new[?]name=CS193V')"
sg_says_not "prefill:hides-the-by-hand-steps" token.byhand "$SG_OUT"
# Generating a token takes two clicks. A student who stops at the first sees no token at all and
# has nothing to paste, which looks from their side like the link having failed.
sg_has "prefill:names-the-confirmation" "confirm when GitHub asks you to" "$SG_OUT"
sg_says "prefill:the-link-path-still-works" status.all-set "$SG_OUT"

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
record "prefill:widest-row" "$(sg_widest_row "$SG_OUT") columns"
assert_eq "prefill:the-link-fits-an-80-column-terminal" "" "$(sg_rows_over 80 "$SG_OUT")"

# NOTHING ASSERTS THE SERVER WAS ENDED, because nothing ends it any more. setup-git used to kill it
# through --pidfile, on the grounds that a forwarded port was scarce; ports are ephemeral and
# per-listener now, so the flag and the kill are both gone. See the note in sg_cleanup.

# ─── with no shortlink at all: the long URL, and nothing broken ────────────────
# A TA's Mac has no /usr/local/bin/shortlink, and 45-setup-git.sh drives this script there. The
# real shortlink degrades the same way when no port is forwarded, so this one case covers both --
# and what it must show is the URL this screen printed before any of this existed.
sg_new
rm -f "$SGSHIM/shortlink"
sg_run noshortlink happy
sg_says "noshortlink:still-offers-the-link" token.prefill "$SG_OUT"
sg_has  "noshortlink:falls-back-to-the-long-url" \
        "settings/personal-access-tokens/new?name=CS193V" "$SG_OUT"
sg_says "noshortlink:the-flow-still-completes" status.all-set "$SG_OUT"
# AND IT WRAPS, which is the measurement that says the short link is doing the work rather than
# something else having changed. Recorded rather than asserted: this is the old behaviour, and a
# test that demanded it stay broken would be the wrong shape.
record "noshortlink:widest-row" "$(sg_widest_row "$SG_OUT") columns"

# Arrowing down is the only way to the by-hand steps, and it has to end at the same prompt. The
# arrows are counted by the harness from `pick opt.by-hand`, so a reordered menu retargets itself.
sg_new
sg_run byhand happy-by-hand
sg_says "byhand:shows-the-steps"      token.byhand   "$SG_OUT"
sg_says "byhand:then-accepts-a-token" status.all-set "$SG_OUT"
# THE THREE THINGS THE OLD STEPS GOT WRONG about GitHub's page, each asserted by the phrase that
# fixes it, because each one stopped a student who followed the instructions exactly:
#   * the page is opened directly, so there is no "Generate new token" button to click first;
#   * the section is called Permissions, not Repository permissions;
#   * the three permissions have to be ADDED before they can be set to Read and write, and
#     nothing on the page lists them until they are.
sg_has_not "byhand:no-generate-new-token-step"        "Generate new token"         "$SG_OUT"
sg_has     "byhand:names-the-permissions-section"     "Under Permissions"          "$SG_OUT"
sg_has     "byhand:says-a-permission-must-be-added"   "Add permissions"            "$SG_OUT"
sg_has     "byhand:says-they-arrive-read-only"        "added as Read-only"         "$SG_OUT"

# ─── the four permission failures ──────────────────────────────────────────────
# One injected failure each, and three things asserted every time: the row that failed carries a
# cross, the rows before it carry checks, and NOTHING AFTER IT RAN. That last one is what keeps a
# failure honest — a probe list that carried on past a failure would report the last permission
# rather than the first broken one.
#
# The keystrokes end in \033[B\033[B\n: down, down, Enter — the third option, "I'm stuck", which
# is what produces the staff box. Reaching it by arrow key rather than by digit is deliberate:
# this is the only place the third menu entry is exercised at all.

sg_new
sg_set fail_at 'clone'
sg_run fail-clone happy stuck
sg_says "fail-clone:says-which-repo-it-cannot-reach" err.clone "$SG_OUT"
# THE REPOSITORY BY NAME, and the SUNetID as item 1 (issue #92). The sandbox is per-student and
# private, so a mistyped SUNetID 404s exactly like a repository that does not exist -- nothing can
# tell those apart from outside. What the checklist can do is stop omitting the likeliest cause,
# and name the repository it actually looked for so a student can see the ID inside it.
sg_has     "fail-clone:names-the-repository-it-looked-for" "cs193v-students/sandbox-jdoe" "$SG_OUT"
sg_has     "fail-clone:the-first-item-is-the-sunetid"      "1. Your SUNetID"              "$SG_OUT"
sg_has     "fail-clone:still-names-the-resource-owner"     "Resource owner"               "$SG_OUT"
assert_contains "fail-clone:the-row-failed" "✗" "$SG_OUT"
assert_eq       "fail-clone:nothing-after-it-ran" "0" "$(sg_count 'git pull')"
sg_says "fail-clone:ends-with-the-staff-box" err.setup-failed "$SG_OUT"
# THE BOX, NOT THE TRANSCRIPT, and that distinction is the whole of issue #54: the command and the
# exit code used to be prose above the box, so a needle looked for anywhere in the output said
# nothing about what a student actually pastes to staff. sg_box cuts the box out; assert_says
# flattens the walls away and rejoins whatever box() wrapped.
sgbox="$(sg_box "$SG_OUT")"
assert_says "fail-clone:box-names-the-command"  "Failed command: git clone --quiet" "$sgbox"
assert_says "fail-clone:box-quotes-the-failure" "remote: Permission to"             "$sgbox"

# AND THE TOKEN IS IN NONE OF IT. The three secret:* assertions above run on the HAPPY path only,
# and this file drives fifteen failure paths -- every one of which reaches fail_to_staff, which
# renders $RT_OUT (the failing command's combined stdout AND stderr) into a box captioned for the
# student to send to course staff. That is a wider surface than the transcript, not a narrower
# one: a student pastes the box deliberately, and staff archive it. Nothing looked at it until
# the #155 audit, which found the token asserted on one of sixteen code paths.
# sg_unwrap, NOT the raw text and NOT _flatten -- see the note on sg_unwrap in
# lib/setup-git-shim.sh. A 93-character token wrapped across two rows of a 69-column box matches
# neither needle otherwise, which is how the first draft of these three assertions passed against
# a box that visibly contained the token.
sgflat="$(sg_unwrap "$sgbox")"
assert_not_contains "fail-clone:the-token-is-not-in-the-staff-box"  "$TOKEN"   "$sgflat"
assert_not_contains "fail-clone:no-token-fragment-in-the-staff-box" "$TOKEN_B" "$sgflat"
assert_not_contains "fail-clone:the-token-is-not-in-the-transcript" "$TOKEN"   "$(sg_unwrap "$SG_OUT")"
# ...and nothing this run left on disk holds it either. TMPDIR is $SGSHIM for the whole run
# (lib/setup-git-shim.sh:97), so setup-git's own $SG_TMP, the sandbox clone, and run_timeout's
# captured-output scratch files all land under it -- and a failure path is exactly when those
# hold a command's output rather than being cleaned up on the way past.
#
# GUARDED, because "grep found nothing" and "there was nothing to search" produce the same
# empty string, and this whole audit exists because that distinction kept being missed.
assert_file "fail-clone:the-shim-really-has-files-to-search" "$SGSHIM/argv.log"
assert_eq   "fail-clone:the-token-is-on-no-file-this-run-left" "" \
            "$(grep -rl -- "$TOKEN" "$SGSHIM" 2>/dev/null || true)"

sg_new
sg_set fail_at 'push -q origin cs193v-setup'
sg_run fail-push happy stuck
sg_says "fail-push:blames-contents" err.push "$SG_OUT"
sg_has     "fail-push:says-read-and-write" "Read and write" "$SG_OUT"
sg_has     "fail-push:says-the-token-can-be-kept" "You do not need to make a new token" "$SG_OUT"
# THE ONE OCCURRENCE COUNT THAT IS NOT sg_has_times, because its needle is an ALTERNATION and that
# helper searches for a literal (#207). Same three decisions as its header records -- sg_plain
# first, `grep -c .` rather than `wc -l` -- spelled out here because one call site cannot borrow
# them. `grep -oE` and not `grep -c`: both rows are checks on separate lines today, but nothing
# says a future meter cannot put two on one.
assert_eq       "fail-push:clone-and-pull-still-passed" "2" \
                "$(sg_plain "$SG_OUT" | LC_ALL=C grep -oE '✓ git (clone|pull)' | LC_ALL=C grep -c . || true)"
assert_eq       "fail-push:nothing-after-it-ran" "0" "$(sg_count 'gh issue')"

sg_new
sg_set fail_at 'issue create'
sg_run fail-issue happy stuck
sg_says "fail-issue:blames-issues" err.issues "$SG_OUT"
sg_says_not "fail-issue:does-not-blame-contents" err.push "$SG_OUT"
assert_eq       "fail-issue:nothing-after-it-ran" "0" "$(sg_count 'gh pr create')"

sg_new
sg_set fail_at 'pr create'
sg_run fail-pr happy stuck
sg_says "fail-pr:blames-pull-requests" err.prs "$SG_OUT"
sg_says_not "fail-pr:does-not-blame-issues" err.issues "$SG_OUT"

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
sg_run wrong-owner happy stuck
sg_says "wrong-owner:says-so-outright" err.clone-wrong-owner "$SG_OUT"
sg_has     "wrong-owner:names-the-account" "@janedoe" "$SG_OUT"
sg_says_not "wrong-owner:not-the-generic-checklist" err.clone "$SG_OUT"

# AND THE BOX STILL QUOTES THE CLONE (issue #64). The evidence for the message above comes from
# token_owner_wrong, which is a run_timeout, and run_timeout writes RT_OUT — so the staff box used
# to quote that probe's answer, `janedoe`, under a heading naming `git clone`. Measured: this is
# the box a student sent staff for every clone and pull failure, not an edge case.
sgbox="$(sg_box "$SG_OUT")"
assert_says "wrong-owner:box-quotes-the-clone-failure"    "fatal: repository not found" "$sgbox"
assert_says "wrong-owner:box-reports-the-clone-exit-code" "Exit code: 128"              "$sgbox"
sg_has_not  "wrong-owner:box-does-not-quote-the-owner-probe" "janedoe" "$sgbox"

# Ambiguous evidence must NOT produce the specific message. An empty list means the token can see
# nothing at all, which is consistent with several causes, and guessing wrong here sends a student
# to throw away a token that was fine.
sg_new
sg_set fail_at 'clone'
sg_set owners ''
sg_run ambiguous-owner happy stuck
sg_says "ambiguous-owner:falls-back-to-the-checklist" err.clone "$SG_OUT"
sg_says_not "ambiguous-owner:no-unearned-accusation" err.clone-wrong-owner "$SG_OUT"

# And when the organization IS in the list, the token's owner is not the problem.
sg_new
sg_set fail_at 'clone'
sg_set owners 'janedoe cs193v-students'
sg_run org-visible happy stuck
sg_says "org-visible:falls-back-to-the-checklist" err.clone "$SG_OUT"
sg_says_not "org-visible:no-unearned-accusation" err.clone-wrong-owner "$SG_OUT"

# ─── the three ways out of a failure ───────────────────────────────────────────
# "I was able to follow those instructions" runs the probes AGAIN with the same token, which is
# the whole point: a student who fixed a permission on the token they already pasted must not be
# asked to paste it again.
sg_new
sg_set fail_at 'issue create'
sg_run retry happy retry-probes stuck
assert_eq "retry:probes-run-a-second-time" "2" "$(sg_count 'gh issue create')"
assert_eq "retry:does-not-ask-for-the-token-again" "1" \
          "$(sg_asks "$SG_OUT" "$(sg_phrase prompt.token)")"

# "Let me re-enter my access token" goes back to the token prompt and nowhere further back: the
# name and the address are already right and asking for them again would be punishing the
# student for our failure.
sg_new
sg_set fail_at 'issue create'
sg_run retoken happy reenter-token stuck
assert_eq "retoken:asks-for-the-token-twice" "2" \
          "$(sg_asks "$SG_OUT" "$(sg_phrase prompt.token)")"
sg_says_times "retoken:asks-for-the-sunetid-once" 1 prompt.sunetid "$SG_OUT"
sg_says_times "retoken:asks-for-the-name-once"    1 prompt.name    "$SG_OUT"

# "I'm stuck" is the only path that ends in the staff box, and it has to carry the command, the
# exit code and the command's output — the three things staff cannot diagnose without, all three
# INSIDE the box, because what a student sends is what they can select (issue #54).
sg_new
sg_set fail_at 'issue create'
sg_set fail_rc 42
sg_set fail_err 'gh: HTTP 403: Resource not accessible by personal access token'
sg_run stuck happy stuck
sgbox="$(sg_box "$SG_OUT")"
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
sg_run wrong-account identity checkpoint-ok get-token account-wrong get-token account-ok
assert_eq "wrong-account:asks-for-the-token-twice" "2" \
          "$(sg_asks "$SG_OUT" "$(sg_phrase prompt.token)")"
sg_says "wrong-account:eventually-succeeds" status.all-set "$SG_OUT"

# ─── the environmental failures ────────────────────────────────────────────────
# Neither of these is the student's token, and blaming it would send them to edit something that
# was already correct. A whole lab section starting at once really does trip the secondary rate
# limit, and it looks exactly like a permission error unless something reads the message.
sg_new
sg_set fail_at 'clone'
sg_set fail_err 'fatal: unable to access: Could not resolve host: github.com'
sg_run network happy
sg_says "network:says-the-network" err.network "$SG_OUT"
sg_says_not "network:does-not-blame-the-token" err.clone "$SG_OUT"

sg_new
sg_set fail_at 'issue create'
sg_set fail_err 'gh: You have exceeded a secondary rate limit. Please wait a few minutes.'
sg_run ratelimit happy
sg_says "ratelimit:says-to-wait" err.rate-limit "$SG_OUT"
sg_says_not "ratelimit:does-not-blame-the-token" err.issues "$SG_OUT"

# ─── validation, as the student meets it ───────────────────────────────────────
# The unit suite covers the verdicts exhaustively; what this covers is the loop around them —
# that a rejection re-prompts on the spot rather than starting the screen over, and that the two
# messages are actually different where the transcript in issue #49 says they are.
#
# FOUR ANSWERS, THREE OF THEM WRONG IN TWO DIFFERENT WAYS. `jane.doe` is an email alias rather
# than a SUNetID and `ab` is too short, which are the same mistake and share a message;
# `me@cs.stanford.edu` is an email address, which is its own. The fourth is right but capslocked
# and padded — the case that proves what reaches git config is the NORMALISED value rather than
# what was typed, which matters because it also names the repository.
sg_new
sg_run retry-sunetid bad-sunetids checkpoint-ok get-token account-ok
# THE ONE SITE HERE WHERE ROWS AND OCCURRENCES USED TO DIVERGE ON A LIVE RUN, which is the whole
# of issue #200 and the reason sg_times exists at all. Each rejection is one
# `printf '  %s %s '` -- the complaint then prompt.retry, no newline at either end, so the retry
# lands where the student is already typing; files/setup-git:538-540 records that as a decision
# about what a student reads rather than one to trade away for an easier count. So NOTHING IN
# setup-git ENDS THAT ROW: the newline between complaint 1 and complaint 2 was only ever the
# terminal echoing `ab`, and sg_feed typed on a clock instead of waiting for a prompt.
#
# WHAT MADE THAT A RACE IS GONE (#206). sg_feed typed on a 0.3s clock with no knowledge of the
# child, so whether the echo arrived before the complaint was a coin flip: measured then at 1 row
# in 9 of 10 runs idle and 6 of 6 under 3x CPU oversubscription, on which this assertion in its
# `grep -c` form failed outright. Each rejection is now a step in [[bad-sunetids]] that names the
# complaint it expects and is not typed until that complaint is on the screen, so there is nothing
# left to race -- measured 2 rows and 2 occurrences in 6 runs of 6.
#
# THE MEASUREMENT STAYS AN OCCURRENCE COUNT ANYWAY, because it is strictly stronger and because
# counting rows is the wrong measurement of "complained twice" even in a synchronous harness. The
# row form is asserted BESIDE it rather than instead of it, as a canary: it reads 2 only because
# nothing races the echo any more, so if that ever comes back it is this assertion that says so
# rather than the occurrence count quietly drifting.
#
# BY KEY SINCE #207, where both of these quoted a fragment. The fragment was picked to sit clear of
# the colour emph_stream injects at `*htiek*`, so a reword that moved either asterisk would have
# scored 0 against the raw bytes and read as the message not having printed. sg_says_times takes
# the whole message with the colour off, and the row form goes through sg_rows and sg_phrase to
# get the same two properties one \r-segment at a time.
#
# So do not collapse the pair back to one count on the strength of a green run. MEASURED: drop
# ptydrive's screen gate and cursor arming for `line` steps -- which is the clock, reconstructed --
# and the two separate exactly as #200 described, 213 pass / 1 fail with the row form the only
# thing red. The occurrence count sat at 2 through it and would have reported the race as fixed.
sg_says_times "retry-sunetid:complains-twice-about-the-shape" 2 err.sunetid-invalid "$SG_OUT"
assert_eq "retry-sunetid:the-row-break-is-no-longer-a-race" "2" \
          "$(sg_rows "$SG_OUT" | LC_ALL=C grep -cF "$(sg_phrase err.sunetid-invalid)" || true)"
sg_says "retry-sunetid:has-a-separate-message-for-an-address" err.sunetid-is-an-email "$SG_OUT"
sg_has "retry-sunetid:confirms-the-normalised-id" "You entered jdoe" "$SG_OUT"
assert_match "retry-sunetid:configures-the-normalised-address" \
             'user.email jdoe@stanford.edu' "$(sg_log)"
assert_match "retry-sunetid:clones-the-normalised-sandbox" 'clone .*sandbox-jdoe' "$(sg_log)"
sg_says "retry-sunetid:still-gets-there" status.all-set "$SG_OUT"

# A WHOLE ADDRESS TYPED AT THE PROMPT IS THE RIGHT ANSWER IN THE WRONG FORM, and it is what a
# student who has typed jdoe@stanford.edu into every other form this week will type here. The
# domain has to be exactly stanford.edu — an alumni or department address is a real address of
# theirs that is not what the roster or the repository is named after, and gets the other message,
# which the run above covers.
sg_new
sg_run typed-address happy ID=jdoe@stanford.edu
sg_has "typed-address:confirms-just-the-id" "You entered jdoe" "$SG_OUT"
assert_match "typed-address:configures-the-derived-address" \
             'user.email jdoe@stanford.edu' "$(sg_log)"
assert_match "typed-address:records-the-id-alone" 'cs193v.sunetid jdoe' "$(sg_log)"
sg_says "typed-address:still-gets-there" status.all-set "$SG_OUT"

# "No, I want to retype that" asks the same question again rather than moving on. `wrong` is a
# structurally valid SUNetID, which is the point: this is the path for a student who typed
# somebody else's, and nothing but the confirmation can catch that.
sg_new
sg_run retype-sunetid retype-sunetid checkpoint-ok get-token account-ok
sg_says_times "retype-sunetid:asks-again" 2 prompt.sunetid "$SG_OUT"
assert_match "retype-sunetid:configures-the-second-answer" \
             'cs193v.sunetid jdoe' "$(sg_log)"
assert_not_match "retype-sunetid:never-configures-the-first" \
                 'cs193v.sunetid wrong' "$(sg_log)"
assert_match "retype-sunetid:derives-the-second-answers-address" \
             'user.email jdoe@stanford.edu' "$(sg_log)"
# AND THE REPOSITORY FOLLOWED IT. A first answer left behind in SG_SANDBOX would send the probes
# at a repository belonging to whoever `wrong` turns out to be.
assert_not_match "retype-sunetid:never-touches-the-first-answers-sandbox" \
                 'sandbox-wrong' "$(sg_log)"

# A classic token is turned away before anything runs, with its own message: one with the `repo`
# scope would very nearly work, so "that is not a token" would be both wrong and unhelpful.
sg_new
sg_run classic-token identity checkpoint-ok classic-token account-ok
sg_says "classic-token:says-which-kind-it-is" err.token-classic "$SG_OUT"
assert_eq "classic-token:nothing-ran-with-it" "0" "$(sg_count 'gh auth login.*ghp_')"
sg_says "classic-token:then-accepts-the-right-one" status.all-set "$SG_OUT"

sg_new
sg_run junk-token identity checkpoint-ok junk-token account-ok
sg_says "junk-token:says-what-one-looks-like" err.token-shape "$SG_OUT"
# FIVE DOTS AND NO COUNT for five characters: below SG_DOTS_MAX the tally is the dots themselves,
# because "... -1 more characters ..." is what a short typo would otherwise render as.
sg_has_times "junk-token:draws-one-dot-per-character" 5 "•" \
             "$(sg_final "$SG_OUT" "Your token:")"
sg_has_not "junk-token:no-count-for-five-characters" "more characters" \
           "$(sg_final "$SG_OUT" "Your token:")"

# A TRUNCATED PASTE IS THE CASE ISSUE #53 DREW, and it was accepted outright before that issue: the
# check was the prefix, and half a token still has the prefix. It reaches `gh auth login` now only
# in the sense that the good one pasted after it does.
sg_new
HALF="$(printf '%s' "$TOKEN" | cut -c1-50)"
sg_run partial-token identity checkpoint-ok partial-token account-ok HALF=$HALF
sg_says "partial-token:says-it-is-only-part-of-one" err.token-partial "$SG_OUT"
sg_says_not "partial-token:does-not-say-it-is-not-a-token" err.token-shape "$SG_OUT"
# 44 = 50 - the six dots. The number a student compares against the one a whole token shows.
sg_has "partial-token:counts-what-did-arrive" "44 more characters" "$SG_OUT"
assert_eq "partial-token:nothing-ran-with-it" "1" "$(sg_count 'gh auth login')"
sg_says "partial-token:then-accepts-the-right-one" status.all-set "$SG_OUT"

# ─── the checkpoint's escape hatch ─────────────────────────────────────────────
# "Uh oh, something's wrong" at the GitHub checkpoint has to stop, not carry on into a token
# prompt the student cannot answer.
sg_new
sg_run checkpoint-help identity checkpoint-help
sg_says "checkpoint-help:ends-in-the-staff-box" err.setup-failed "$SG_OUT"
sg_says_not "checkpoint-help:never-asks-for-a-token" token.paste "$SG_OUT"
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
sg_run config-fails happy-to-token
sg_says "config-fails:goes-to-staff" err.setup-failed "$SG_OUT"
sgbox="$(sg_box "$SG_OUT")"
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
printf 'user.name=Jane Doe\nuser.email=jdoe@stanford.edu\ncs193v.sunetid=jdoe\n' > "$SGSHIM/gitconfig"
sg_run second-run second-run-check
sg_says "second-run:says-it-is-already-set-up" already.configured "$SG_OUT"
sg_has "second-run:shows-the-name"    "Jane Doe"          "$SG_OUT"
sg_has "second-run:shows-the-address" "jdoe@stanford.edu" "$SG_OUT"
sg_has "second-run:shows-the-sunetid" "Your SUNetID: jdoe" "$SG_OUT"
sg_has "second-run:shows-the-account" "@janedoe"          "$SG_OUT"
sg_says_not "second-run:does-not-ask-again" prompt.sunetid "$SG_OUT"
sg_says "second-run:just-checks-and-passes" status.all-set "$SG_OUT"
# AND IT PROBED THE RIGHT REPOSITORY, which is the whole reason the SUNetID is stored at all: the
# second run never asks a question, so the only place sandbox-jdoe can come from is the config.
assert_match "second-run:probes-the-students-own-sandbox" 'clone .*sandbox-jdoe' "$(sg_log)"
assert_eq "second-run:configures-nothing" "0" \
          "$(sg_count 'git config --global [a-z.]+ .')"

# "Start over" does ask again, and that is the option that exists for a student whose name or
# address was wrong.
sg_new
sg_touch auth_token
printf 'user.name=Wrong Name\nuser.email=wrong@stanford.edu\ncs193v.sunetid=wrong\n' > "$SGSHIM/gitconfig"
sg_run start-over second-run-start-over happy
sg_has "start-over:asks-for-the-sunetid-again" "What is your SUNetID" "$SG_OUT"
assert_match "start-over:configures-the-new-answer" 'user.email jdoe@stanford.edu' "$(sg_log)"
assert_match "start-over:records-the-new-sunetid" 'cs193v.sunetid jdoe' "$(sg_log)"
# THE STALE ANSWER IS CLEARED, ALL OF IT. `wrong` was in the config when this started, so a
# start-over that reset the name and the address but not the ID would clone somebody else's repo.
assert_not_match "start-over:does-not-probe-the-old-sandbox" 'sandbox-wrong' "$(sg_log)"

# And "nothing, thanks" changes nothing at all.
sg_new
sg_touch auth_token
printf 'user.name=Jane Doe\nuser.email=jdoe@stanford.edu\ncs193v.sunetid=jdoe\n' > "$SGSHIM/gitconfig"
sg_run quit second-run-quit
assert_eq "quit:runs-no-probes" "0" "$(sg_count 'git clone')"
sg_says_not "quit:does-not-claim-success" status.all-set "$SG_OUT"

# An unfinished setup must NOT take the second-run screen. A git config with no working token is
# not "already set up" whatever the config says, and the ordinary flow is the right place to be.
sg_new
printf 'user.name=Jane Doe\nuser.email=jdoe@stanford.edu\ncs193v.sunetid=jdoe\n' > "$SGSHIM/gitconfig"
sg_run no-token happy
sg_says_not "no-token:is-not-already-configured" already.configured "$SG_OUT"
sg_says "no-token:asks-from-the-start" prompt.sunetid "$SG_OUT"

# NEITHER IS A CONFIG FROM BEFORE ISSUE #92, and this is the case every returning student meets
# exactly once. Their name and address are right and their token works, but nothing recorded which
# repository is theirs — and the shared sandbox those three were verified against is gone. Asking
# again is the only thing that can produce the answer, so this must not take the short path.
sg_new
sg_touch auth_token
printf 'user.name=Jane Doe\nuser.email=jdoe@stanford.edu\n' > "$SGSHIM/gitconfig"
sg_run no-sunetid happy
sg_says_not "no-sunetid:is-not-already-configured" already.configured "$SG_OUT"
sg_says "no-sunetid:asks-from-the-start" prompt.sunetid "$SG_OUT"
sg_says "no-sunetid:then-gets-there" status.all-set "$SG_OUT"

# And a stored value that is not a SUNetID is the same answer rather than half a repository name.
# Nothing a student does produces this; a hand-edited config does.
sg_new
sg_touch auth_token
printf 'user.name=Jane Doe\nuser.email=jdoe@stanford.edu\ncs193v.sunetid=jane.doe\n' > "$SGSHIM/gitconfig"
sg_run bad-sunetid happy
sg_says_not "bad-sunetid:is-not-already-configured" already.configured "$SG_OUT"
sg_says "bad-sunetid:asks-from-the-start" prompt.sunetid "$SG_OUT"
assert_not_match "bad-sunetid:never-clones-a-mangled-name" 'sandbox-jane.doe' "$(sg_log)"

# ─── tidying up after itself ───────────────────────────────────────────────────
# A student who gives up halfway should not leave a branch and an open issue behind in the
# repository they are about to do their homework in. Best-effort and silent: none of it is their
# business.
sg_new
sg_set fail_at 'gh pr create'
sg_run cleanup happy stuck
assert_eq "cleanup:deletes-the-branches-it-pushed" "3" "$(sg_count 'push -q origin --delete')"
assert_match "cleanup:closes-the-issue-it-opened" 'gh issue close' "$(sg_log)"
sg_has_not "cleanup:says-nothing-about-it" "--delete" "$SG_OUT"

# ─── nothing invisible in what a student copies ────────────────────────────────
# A blank line inside a message is a blank line. emph_stream used to end one with two spaces and a
# reset sequence — awk's split() returns 0 fields for an empty string, 0 is even, and the branch
# that closes an unpaired *asterisk* fired on nothing. Neither a screen nor any assertion here
# could show it, because both strip the escapes; a student pasting a screenful into a help request
# carries it. Checked against the whole transcript rather than one message, since every message
# with a paragraph break in it was affected.
sg_new
sg_run copy happy
assert_eq "copy:no-line-is-invisible-whitespace" "" \
          "$(sg_rows "$SG_OUT" | grep -nE '^[[:space:]]+$' | head -3 | do_tr '\n' ' ')"

# ─── the cursor comes back ─────────────────────────────────────────────────────
# run_step hides the cursor for the duration of a row. A script that exits with it hidden leaves
# the student typing blind in that terminal for everything they do afterwards — ERRORS.md B18,
# found by watching a real install. Asserted on both endings, because the failure path installs
# the same trap and is the one more likely to be missed.
sg_new
sg_run cursor-success happy
assert_contains "cursor:hidden-during-the-rows" "[?25l" "$SG_OUT"
assert_contains "cursor:restored-on-success"    "[?25h" "$SG_OUT"
sg_new
sg_set fail_at 'clone'
sg_run cursor-failure happy stuck
assert_contains "cursor:restored-on-failure"    "[?25h" "$SG_OUT"

# ─── and so does the terminal ──────────────────────────────────────────────────
# read_secret turns echo off AT THE TERMINAL for the length of a paste rather than leaving it to
# `read -s` per character — see the comment there for what that buys. What it costs is a second
# thing that has to be given back, with a worse failure than the cursor's if it is not: a student
# typing invisibly for the rest of the session. sg_cleanup gives it back on every path the cursor is
# given back on, but no transcript can show tty state — so this asks the pty itself, afterwards.
sg_new
SG_RUN="bash -c 'env $SG_ENV TMPDIR=$SGSHIM CS193V_SGSHIM=$SGSHIM bash $SG_SETUP_GIT; stty -a'"
sg_run tty happy
SG_RUN=''
sg_says "tty:the-run-still-succeeds" status.all-set "$SG_OUT"
# Word-bounded, because stty -a also prints echoe, echok, echoctl and echoke.
assert_match     "tty:echo-is-on-afterwards"     '(^| )echo( |$)'    "$(sg_plain "$SG_OUT")"
assert_not_match "tty:echo-is-not-left-off"      '(^| )-echo( |$)'   "$(sg_plain "$SG_OUT")"
assert_not_match "tty:canonical-mode-is-restored" '(^| )-icanon( |$)' "$(sg_plain "$SG_OUT")"
