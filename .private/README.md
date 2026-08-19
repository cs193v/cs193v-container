# CS193V container — staff README

Scaffolding for the CS193V course container. Students never read this file;
`CONTAINER-DESIGN.md` is the student-facing one.

This repo **is** the `~/cs193v` layout — students unpack it there, so the launcher and
its `projects/` directory are siblings.

A student's course directory shows them **two things**, and everything else is hidden. That
is deliberate (issue #16): a first-year student opening `~/cs193v` should see the command they
run and the folder their work goes in, not the machinery.

```
cs193v                         the launcher (bash 3.2 compatible, one script, all platforms)
projects/                      the student's work; the only directory shared with the container

.config/                       flag files the launcher reads
  container.args               every podman flag, heavily commented
  local.args                   machine-specific (memory cap); written by the installer, gitignored

.private/                      everything needed to BUILD or MAINTAIN the image
  Containerfile                the image
  files/                       everything the image installs
    entrypoint.sh              PID 1 — keep-alive + reaps orphans
    cs193v-shell               THE LANDING POINT — picks a tmux session and attaches
    cs193v-welcome             the entry banner
    cs193v-goodbye             the goodbye on exit
    cs193v-ui.sh               THE SHARED PRESENTATION LAYER — sourced by the launcher AND,
                               as /etc/cs193v/ui.sh, by everything in the image that draws
    setup-git                  guides a student through git and GitHub (issue #49)
    setup-git-messages.txt     all of setup-git's prose, messages.txt's format,
                               hard-wrapped at 76 columns (issue #58 — see below)
    tmux/tmux.conf             the beginner-locked tmux configuration
    tmux/tabname.bash          tab labels for wrapper commands ("sudo apt", "claude")
    open-url                   the $BROWSER stub
    rewrite-window-title.py    points the terminal's title at the course
    nanorc
    bash_logout                runs cs193v-goodbye, outside tmux only
    profile.d/                 stty -ixon, and the entry banner outside tmux
    claude-code/               managed-settings.json + CLAUDE.md
  messages.txt                 all student-facing launcher strings (script config, not reading)
  install-cs193v.sh            macOS / Ubuntu / WSL setup
  install-cs193v-windows.cmd   Windows stage one, then hands off to the above
  CONTAINER-DESIGN.md          threat model, ports and the tunnel, rough edges — publish this
  VERIFICATION.md              release gates — hand to a Claude Code instance per platform
  ERRORS.md                    what the first verification pass found, and what is still open
  tests/                       the regression suite
    tmux-harness/              the screen-scraping tmux suite, run inside the container
```

There is no `.github/` directory, and that is the design rather than an omission — see
"How the image reaches a student" below.

Note `CONTAINER-DESIGN.md` is course *reading* but lives in `.private/` — publish it on the
course website rather than expecting students to find it in a hidden directory.

## How the image reaches a student

**It doesn't. They build it.** `.private/Containerfile` is the distribution: the installer
runs `./cs193v --rebuild`, and the image is assembled on the student's own machine. There is
no registry, no published artifact, and no CI.

That is a deliberate reversal of the original plan, and the reasoning is worth keeping,
because "just publish it to ghcr" is the obvious first suggestion anyone will make:

* **The pull path was never exercised and the build path always was.** Building locally has
  been the staff loop since the beginning and every test tier runs against the locally
  built image. Shipping the tested path is the smaller risk, not the larger one.
* **Multi-arch was the expensive part.** A published image needs a manifest list covering
  amd64 and arm64, and two build steps make emulated cross-building genuinely nasty rather
  than merely slow: layer 5 launches Chromium and takes a screenshot, and layer 8 starts a
  tmux server and interrogates its key table. Building locally is always native.
* **A registry is a same-day-for-everyone failure.** A package set private, an account
  rotated, or an anonymous pull quota hit by one lab section behind one campus NAT breaks
  every student at once, with no local workaround.
* **`--rebuild` does not touch the image unless the recipe moved**, so the recovery loop staff
  suggest freely still costs two seconds and no network. The build is genuinely one-time.

What it costs, so nobody rediscovers it the hard way:

* **The pins in the Containerfile are now load-bearing.** A floating `ARG` used to mean CI
  drifted between runs while one artifact still reached everybody; now it means two
  students get different software. `00-release-gates.sh` §3 enforces every one of them.
* **The build's hard assertions now fail on students, not on CI.** Nine steps fail the
  build rather than ship a degraded image — the `tldr --update` page-count floor is the
  sharpest. They are kept (a student with no `tldr` and no `man` has no help at all and
  would never know), and `build_image` retries three times instead, which is cheap because
  podman keeps every completed layer.
* **Upstream rot lands on students.** Nothing runs this build on a schedule. `NODE_VERSION`
  is an exact apt version and survives only because NodeSource's nodistro suite retains the
  whole 24.x patch history — verified with `apt-cache madison nodejs`, not assumed. Re-check
  that before trusting the same of a future major.
* **The pull path is gone rather than dormant.** `IMAGE=` in `container.args`, the
  `--update` verb and its pull branch, `CS193V_IMAGE` and `OVERRIDE_IMAGE` were all removed
  outright. Keeping an untested override cost more than it saved: the stale-recipe check only
  ran when the resolved image equalled the locally built tag, so any value in any of them
  silently switched rebuild prompts off while `doctor` went on reporting `STALE` — and with
  `CS193V_INSTANCE` set, "the locally built tag" is suffixed, so even naming the obvious
  image did it. Publishing later now means writing that path and its messages again. That is
  a decision to make once rather than a line to fill in, which is the whole of what this
  section's first bullet is claiming.
* **Disk, measured.** Nothing to a running container costs **224 s, 4.1 GB of transient
  peak, and 4.3 GB retained** for an image reported as 2.2 GB. Creating the container is a
  second cost roughly equal to the image again, because `--userns=keep-id` writes an
  ID-mapped copy of every layer — which is why retained exceeds peak. Do not size a disk
  from `podman system df`: it reported 2.2 GB where the store held 6.7 GB.

## Before this works

Two things need real values:

1. **`install-cs193v.sh`** — set `REPO_OWNER` (and `REPO_NAME` if you rename it). This is
   the only remaining blank that is engineering rather than website work, and
   `run-tests.sh --release` fails on exactly this one thing until it is filled in.
2. **The course website** — host `install-cs193v.sh` and `install-cs193v-windows.cmd`
   with their SHA-256 published next to the links.

There is no third blank. `.config/container.args` used to carry an empty `IMAGE=` line that
looked like one; it is gone, along with the rest of the pull path — see "How the image
reaches a student" above.

### And four things on GitHub, before `setup-git` works for anybody

`setup-git` (issue #49) configures git and then proves the student's fine-grained access token can
do everything the course will ask of it. Three of these four are settings rather than code, and
each one breaks *every* student at once if it is wrong. `run-tests.sh --release` records the values
`setup-git` is compiled with and fails if the token expiry has gone stale.

1. **`cs193v-students` → Settings → Personal access tokens → "Do not require administrator
   approval".** Requiring approval is GitHub's **default**, and it applies to fine-grained tokens
   *only* — the docs are explicit that "Only fine-grained personal access tokens, not personal
   access tokens (classic), are subject to approval". A token awaiting approval "will only be able
   to read public resources", so a private sandbox answers 404 and every student stops at the
   `git clone` row until an owner clicks approve.
2. **Students must be organization MEMBERS, not outside collaborators.** This is not a preference:
   "Fine-grained personal access tokens do not currently support being used to contribute to
   repositories where the user is an outside or repository collaborator." An outside collaborator
   cannot even *name* the organization as a token's resource owner. Worth knowing because GitHub
   Classroom's default for individual assignments adds students as outside collaborators, which
   would break the whole design silently.
3. **`cs193v-students/install-sandbox`** — private, with a default branch and at least one commit.
   An empty repository has no default branch, so `git clone` "succeeds" with
   `warning: You appear to have cloned an empty repository`, `git pull` fails for a reason that has
   nothing to do with permissions, and the first student to run `setup-git` would create the
   default branch with their own push. Everybody needs write access to it. Protecting that branch
   against force-push and deletion is worth doing: every student can write to it and no probe ever
   needs to. Leave **"Allow merge commits"** on, which is the default: the probes merge one pull
   request — into a branch of their own rather than the default one — and a repository configured
   to permit only squashing would fail that row for every student.
4. **The token expiry in `files/setup-git`** (`CS193V_TOKEN_EXPIRY`) — a date, past the end of the
   quarter. Students are told to choose it, and GitHub's prefilled link wants a lifetime in *days*,
   so `setup-git` converts it on every run. A stale date is clamped to a 30-day floor rather than
   emitted as a negative lifetime, so the symptom is tokens expiring in week 8 rather than a broken
   link — which is why the release gate reads it and nothing in the everyday suite does.

The sandbox accumulates closed issues, and that is expected rather than a fault: deleting an issue
needs admin permission on the repository, which no student has, so `setup-git` closes them.
Branches it creates are deleted, on the failure path as well as the success one.

### The prose is hard-wrapped at 76 columns, and that is load-bearing

`files/setup-git-messages.txt` is wrapped at 76 rather than at whatever looks right in the editor,
because `render()` indents every line by two and a line that reaches the right edge **soft-wraps**
— costing a second row, invisibly, to anyone reading in a wide window. The container's tmux takes
one row for its status line, so an 80×24 terminal leaves 23.

Issue #58 is what that arithmetic cost. The token screen printed the prefilled link *and* the
by-hand steps to everybody, in a file wrapped at 94, and came to **53 rows**: a student who
followed the link reached `Your token:` with the link scrolled off the top. The fix was both
halves — the by-hand steps moved behind a menu, and the file rewrapped — and the screens are now
19, 21 and 22 rows. `20-messages.sh :: sgkeys:every-line-fits-an-80-column-terminal` holds the
width, substituting `{{ORG}}` and `{{EXPIRY}}` from `setup-git`'s own defaults and exempting the
one line that carries the prefilled link, which is 157 characters of GitHub's making and is issue
#67's to shorten.

Rewrapping is also when emphasis gets split across a line break, and `emph_stream` closes an
unpaired asterisk at end of line — so `titled *New` / `fine-grained token*.` renders the first
half plain and the second half's full stop in cyan. Every assertion in the suite strips the markup
before comparing and so cannot see it; `sgkeys:emphasis-is-paired-on-every-line` can.

And one thing that is GitHub's to change rather than ours. `setup-git` checks the *shape* of a token
before it tries it: 93 characters, `github_pat_` then 22 alphanumerics, an underscore and 59 more —
measured against a live token on 2026-08-18, for issue #53. That is what turns a truncated paste into
"copy the whole thing" rather than a 401 three screens later, and it is also a hostage to a format
whose own announcement says token lengths may grow. If that ever happens, every student stops at the
token prompt being told their token looks incorrect. The pattern is in `token_kind` in
`files/setup-git` and nowhere else, and `45-setup-git.sh :: token:a-real-token-is-fine` checks it
against `$CS193V_GH_TEST_TOKEN` whenever one is to hand — which is the cheap way to find out before a
lab section does.

## Your development loop

```
./cs193v --rebuild                     # recreate; builds first IF the recipe moved
./cs193v --rebuild --no-cache          # force a cold build — prove the network fetches work
CS193V_BUILD_RAW=1 ./cs193v --rebuild  # podman's raw output instead of the progress bar
./cs193v --rebuild --logout            # test the cold-start path a student sees
./cs193v --dev-print-command           # see the exact podman run line
./cs193v --dev-args                    # the args-file parse, one word per line
./cs193v --stop                        # stop it by hand — see below, you will need this
```

**There is one verb here where there were four.** `--build`, `--full-rebuild` and `--dev-build`
are gone; `--rebuild` is all of them, and what decides whether it builds is the recipe hash
rather than which flag you picked. So the everyday loop is `./cs193v --rebuild && ./cs193v`:
the first is a two-second recreate when your Containerfile has not moved and a real build when
it has, and the second drops you into a shell. That second step is what `--dev-build` used to
save you, and it was not worth a verb.

**Read this before the first time a verb refuses you.** Since issue #41 the container only runs
while a terminal window is open on it, and every verb above **leaves it stopped when it
finishes**. Two things follow that will otherwise waste your afternoon:

- Each of these verbs **refuses while a session is live**, naming `--stop`. So you cannot
  `--rebuild` from a second terminal while your first one is sitting in a shell. Leave the shell,
  or run `--stop`.
- `--rebuild` no longer leaves you a running container to `podman exec` into. If you want one
  without a shell — which is what the test suite wants — start it yourself with
  `podman start cs193v-$CS193V_INSTANCE`. There is deliberately no launcher verb for it: "running
  with nobody attached" is the state #41 abolished, and adding a verb for it would put a hole in
  the invariant to serve the tests. `hold_container` in `tests/lib/assert.sh` is that one line, and
  says so.

You and a student now run the *same command*, not merely the same `build_image` — which
matters more than the old arrangement did: the path you exercise every day is the path a
student takes on day one, including its retry, its out-of-disk message, and the
`cs193v.buildhash` label. There is no second implementation to drift, and no second verb
either.

What you do get that a student does not is `CS193V_BUILD_RAW=1`, which shows you **podman's
raw output instead of the progress bar** (issue #23). Debugging a build needs podman's words as
they arrive; a student needs to know it is moving. It replaced `--dev-build`, which had become
a whole verb for choosing an output format. Leave it unset when you are changing anything about
how the build *reports itself*, and remember that piping the default (`| tee`, CI) deliberately
switches the bar to one plain line per step.

A failed build no longer leaves podman's output on the screen, so `err.build-failed` now
carries the last lines of `$BUILD_LOG` inside the STOP box. That log is still the thing to
ask a student for; it is not deleted on exit.

`--no-cache` retries once only, deliberately — the retry exists because podman keeps
completed layers, which is exactly what `--no-cache` throws away.

#### The bar is two rows, and it names the step it is on

What a student watching `--rebuild` build something sees is one block. Bar, count and — during a
retry — a right-aligned `(retrying: 1/2)` on the first row; the name of the current step on the
second; and under those a box holding the last eight lines podman printed (next section). It ends
on a green `✓` with the caption row erased, or a red `✗` with the bar frozen where it stopped and
the failed step still named beneath it.

The cursor is hidden for the duration (`ESC[?25l`) and restored in `meter_stop` and again from
`transient_cleanup`. Without that it strobes between the two rows at 10 Hz on any terminal with
a blinking cursor — and `transient_cleanup` rather than the EXIT trap body is deliberate: it is
what `shell_teardown` and `rebuild_interrupted` call, so a Ctrl-C mid-build gives the cursor
back by the same route a clean exit does. If you ever add a path that leaves the meter running,
restore it there too: exiting with the cursor hidden leaves a student typing blind.

**The step names come from `####>` lines in the Containerfile**, each naming its own
instruction and every one after it until the next marker. The launcher parses them itself
(`CF_PARSE_AWK`), because there is no way to get them out of the build: podman emits no
comments, and it never re-runs a cached `RUN`, so an `echo` would go silent on exactly the
warm builds and retries where a student is most likely to be watching. Consequences worth
knowing before you touch either file:

- **Rewording a marker changes `cs193v.buildhash`** and so prompts every student to rebuild.
  Mostly cached, but a prompt all the same — batch a reword with a change that earns one.
- **`--dev-steps` prints the parse** (index, label, instruction). It is the seam the tests
  drive; `15-containerfile-parse.sh` pins the parsing rules against fixtures in under a
  second, and `00-release-gates.sh` diffs the parse against real podman's own `STEP` lines,
  which is the only check that can prove the two agree.
- **The labels are verified per step, not trusted.** podman echoes the instruction on each
  `STEP` line, so the launcher compares it with what it parsed and, on any disagreement,
  switches the labels off for the rest of the build and records why in `$BUILD_LOG`. A
  missing label is unhelpful; a wrong one is a lie. It never fails the build — the meter must
  not be able to stop an install — which is why the same disagreement is a hard failure in
  the release gate instead.
- **No heredocs and no `# escape=` in the Containerfile**, and no `\` followed by whitespace.
  The parse is line-based, so any of them would shift every label after it. `10-static.sh`
  forbids all three.

The download is step 1 rather than a preamble: podman resolves `FROM` by pulling and numbers
that step 1 itself. To have a bar during it — before podman has announced any total — the
launcher uses its own instruction count as a provisional denominator, and podman's number
overrides it at `STEP 1`.

A retry no longer prints anything. It used to print three lines of yellow prose per attempt,
which scrolled the meter up the screen and put a warning a student cannot act on in front of
a build that then succeeded. The marker says it in place, and the bar **holds at the step
that failed** while podman replays the cached steps ahead of it — that work is done and on
disk, so counting it again from zero would tell a student they had lost time they had not.

#### And under it, the last eight lines podman printed

The bar is honest and it is calm, and it is also **silent**: a bar, a count and a step name,
none of which change on a human timescale during the four minutes when apt, npm, Playwright and
Chromium are the ones doing the work. So the block ends in a dim, untitled box — eight rows of
whatever podman last said, refreshed three times a second. It is there for reassurance and for
interest. It is not the diagnosis: that is still `$BUILD_LOG` and the `tail -n 12` the STOP box
carries on failure.

**The animator tails the log; the reader does not feed it.** `tee` writes `$BUILD_LOG` before
`build_progress` reads the same stream, so `meter_tail_box` just runs `tail` on that file. The
alternative — a ring buffer inside `build_progress`'s awk — has to rewrite a state file on
*every* input line, because awk has no portable clock to throttle with (`systime()` is absent
from BSD awk) and going stale during a 90-second step is exactly the failure to avoid. It would
also need a sentinel against torn reads, and it could never learn a new width on `WINCH`.
Tailing the log costs two `exec`s per refresh and buys all three.

It also means **the box shows the base-image download chatter that the meter deliberately
hides**. `build_progress` collapses `Copying blob …` to a single note because podman emits a line
per layer per percentage; in the box those byte counts are the best thing on the screen, because
the download is the longest phase and the one with nothing else to look at.

Things worth knowing before changing any of it:

- **One process draws the block.** The animator owns the terminal at 10 Hz and overdraws anything
  else within 100 ms — the reason staff text goes to `$BUILD_NOTE` rather than to stdout. A
  second writer for the box would be that bug with a new name.
- **The body is printable ASCII only.** With no multibyte characters in it, awk's `length()` *is*
  the display width and `substr()` cannot slice a character in half, so none of `box()`'s
  `dw()`/`dsub()` arithmetic is needed in a renderer that runs three times a second. It costs a
  stray `✔` out of npm and it buys a box that seven third-party tools cannot break.
- **`box()` was not extended, deliberately.** It wraps rather than cuts, is as tall as its
  content, and is duplicated verbatim into `install-cs193v.sh` with `20-messages.sh` asserting
  the copies match. The live box cuts, is a height set by the terminal, and is redrawn in place.
  Both still emit every glyph from a `printf`, which is what `box:*-draws-the-box-in-one-place`
  checks — box art typed into a string anywhere else is the issue #21 bug growing back.
- **`box()` sanitises now too**, and that was a live bug rather than a tidy-up: it interpolates
  raw podman output through `err.build-failed`, and a colour sequence or a `\r` in those lines
  broke the right wall on every failure late enough to have one. ERRORS.md B19 has the detail.
  Both boxes strip the same two things for the same reason; only the live one is ASCII-only.
- **Exactly one kind of line is dropped**, and it is not podman's: anything starting `cs193v:`.
  `build_note_fold` appends those to the same log while the meter is still running, and they are
  addressed to staff — they report that the launcher's own parse of the Containerfile has drifted,
  which is neither something a student can act on nor something podman said. Blank lines get a row
  like anything else, so a row here and a line in `$BUILD_LOG` can still be counted against each
  other; the cost is that a line which was *only* a colour sequence now spends a row too.
- **Commit ids are deliberately NOT dropped.** They are 22 of the 134 lines of a warm build and
  keeping them costs half the window — eight rows reach back to `STEP 22` rather than `STEP 19`.
  That price was considered and paid: the box is a window onto what podman said, not an edited
  version of it, and a student reading a line out to staff has to be able to find that line in
  the log. `30-launcher-shim.sh :: tailbox:shows-podmans-*` pins both shapes podman prints them
  in, because a filter that came back would come back knowing only about the `--> ` one.
- **`build_image` clears `$BUILD_LOG` before starting the meter.** The log deliberately outlives
  the run that wrote it, so without that a student re-running `--build` after a failure would
  spend the first moment of the new build reading the end of the old one.
- **It shrinks before it goes.** `min(8, LINES - 8)` body rows, `min(BOX_W, COLS - 3)` wide, and
  no box at all below four rows or 44 columns — which is exactly the two-row block that shipped
  before it existed. The three-column margin rather than two is not arithmetic sloppiness: a box
  drawn to the last cell of a row leaves some terminals holding a pending wrap, and then the next
  frame's cursor move lands a row low and smears the block permanently.
- **Both endings erase it**, with the `ESC[J` that every frame already ends with. On success the
  block collapses past it to one line; on failure the same lines are about to appear inside the
  STOP box, wrapped rather than cut and with the rest of the log behind them. Two boxes saying
  nearly the same thing is worse than one.
- **It freezes for the last step.** Creating the container takes 10–60 s after `podman build` has
  returned, so the box sits on `COMMIT` / `Successfully tagged` while the caption says "Setting up
  the course container...". That reads as a build that is done, which it is, and it costs no
  ten-row collapse in the middle of the block.

The frame protocol changed to carry it, and the changes are the interesting part:

- **`METER_ROW` says where the cursor is**, and every frame steps up `METER_ROW - 1` rows to
  reach row 1. Still relative moves only: the block scrolls when it sits at the bottom of the
  screen, and absolute coordinates would keep pointing at where it used to be.
- **Every frame ends with `ESC[J`.** That is what makes the region self-healing — a resize that
  shrinks the box, or the box going away, would otherwise leave its old rows stranded below.
- **`meter_stop` waits for the animator instead of killing it.** The animator leaves the cursor
  on row 1 on its way out, which is the precondition for redrawing the closing frame. Killing it
  left the cursor wherever that frame had reached, and the `ESC[1A` that used to be there assumed
  the end of row 2 — a one-row error when it was wrong, survivable at two rows tall and an
  eleven-row one now.
- **A Ctrl-C parks the cursor below the block.** The EXIT trap kills the animator and then waits
  for it, so its `TERM` handler gets to run; without the wait the shell prompt wins the race and
  lands through the middle of the block.
- **`render_pty` had to learn `ESC[J`** or every new screen assertion would have passed
  vacuously, which is the same hazard `assert.sh` already records for `ESC[nA`. A replayer that
  drops it keeps every row the launcher just erased.

### One place that draws: `files/cs193v-ui.sh`

Colours, `box()`, `die()`, `celebrate()`, the arrow-key `menu()`, `msg()`, `run_timeout()`,
`meter_glyph()`, `run_step()` and `version_lt()` live in **one file**, and it is under `files/` so
that it is installed into the image as `/etc/cs193v/ui.sh`. The launcher sources it out of the
checkout; `setup-git` and any future `setup-*` source the installed copy, the way `cs193v-welcome`
and `cs193v-goodbye` already source `/etc/cs193v/strings.sh`.

That arrangement arrived with `setup-git`, which needed a menu and a box inside the container and
would otherwise have been a third copy of both. What it replaced was one copy per script; what is
left is **two** — `install-cs193v.sh` still carries its own, because it is curl-piped and
standalone and can source nothing at all. `20-messages.sh` diffs `box()` between the two and
`25-installer.sh` unit-tests `version_lt` in both.

Four things to know before touching it:

- **`menu()` is NOT byte-identical in the installer, deliberately**, so it has a *behavioural*
  drift check rather than a diff: the installer's copy prints two columns deeper and shortens its
  hint, because it lives inside an indented step list. What must not drift is which keys work, so
  `25-installer.sh` compares the `case` block alone. A diff of the whole function would fail
  forever on presentation, and the only way to make it pass would be to change how the installer
  looks.
- **The launcher is no longer self-contained**, so it carries a guard: an unreadable `ui.sh` gets a
  plain `printf` refusal, because a launcher with no `box()` cannot draw the box that would report
  it. This is less of a change than it sounds — `MESSAGES` has always pointed into `.private/`, so
  the launcher could never print a word without that directory.
- **`cs193v.buildhash` covers it**, since it sits under `files/`. A purely host-side tweak to
  `box()` therefore prompts every student to rebuild. Mostly cached, but a prompt — batch it with a
  change that earns one, the same rule the `####>` markers follow.
- **`run_timeout` has two spinner modes now.** `RT_SPIN` covers a wait and clears its line on the
  way out; `RT_ROW` leaves the row on the screen with a `✓` or `✗` where the spinner was, which is
  what `run_step` is and what `setup-git`'s two lists of commands are made of. Same loop, same
  glyphs, different ending — rather than a second animator with its own frame rate to drift.
- **And two ways of waiting, which is #38.** A call with nothing to draw — every probe, so nearly
  every call — blocks in `read -t` on a pipe the command's wrapper holds open, and so returns the
  moment the status lands instead of on the next tick of a 10 Hz poll. A call with a label keeps
  that poll loop, because a spinner needs a frame clock and bash 3.2 cannot `read -t 0.1`; the
  branch doubles as the fallback if `mkfifo` ever fails, so the exact path is never load-bearing.
  Two things there are load-bearing and easy to undo by tidying: the wrapper closes the pipe for
  the command itself (`9>&-`), or a conmon that outlives podman holds it open and an EOF becomes a
  hang; and the wrapper publishes the command's *own* pid, because `$!` there names a subshell
  rather than the command, so the ceiling would otherwise disown a hung `podman info` instead of
  killing it. `12-run-timeout.sh` pins all of it, including a twenty-probe latency guard — the
  regression #38 fixed was invisible to every other assertion in the suite.

The build's two-row bar is **not** part of this and was deliberately not unified with `run_step`:
it has a progress fraction over a stream of step events, a background animator (its reader is
blocked in `awk` and cannot animate), a state file, a `WINCH` refit and an eight-row log tail.
Teaching it a "list of independent rows" mode is the trade already rejected for `box()` versus the
tail box — the requirements are the opposite ones.

### Two people on one computer: `CS193V_INSTANCE`

By default every checkout on a machine shares the same container (`cs193v`), the same dev
image (`localhost/cs193v:local`) and the same six volumes. Two people developing at once
therefore collide, and not cleanly: whoever ran `--rebuild` last owns the container the
other is about to shell into, and either one's `--rebuild --logout` deletes the other's logins.

Set `CS193V_INSTANCE` to give yourself an independent set of all of them:

```
export CS193V_INSTANCE=yourname
./cs193v --rebuild                # builds localhost/cs193v:local-yourname
./cs193v doctor                   # reports container cs193v-yourname
```

It suffixes the container name, the dev image tag and all six volume names together —
partial suffixing would be worse than none, since `--rebuild --logout` would still cross
instances. `MOUNT_DST`, the workspace path and the `cs193v.dir` label are deliberately not
suffixed: those are already per-directory.

**Host ports are not namespaced by it, but you can move them.** Two instances still compete
for the same 46 host ports, because the ports themselves are a fixed list rather than
something derived from the instance name. What changed with the tunnel is that this is now
survivable rather than fatal: the losing instance no longer fails to *start*, it starts
normally and reports which ports it could not forward.

To get out of the way entirely, override `CS193V_PORTS` in `.config/local.args` (git-ignored,
and read **after** `container.args`, with the last occurrence winning — the same rule podman
applies to a repeated `-e`):

```
-e CS193V_PORTS=13000-13009,14173-14176,15173-15179,16173-16182,18000-18009,18080-18084
```

The launcher derives its `ssh -L` forwards from that value, so one line moves both the
forwards and the list the container is told about. This only works because there are no `-p`
lines left: `local.args` is *appended*, so a second set of `-p` flags used to add mappings
rather than replace them, and moving ports this way was impossible.

One gotcha when you bump `PLAYWRIGHT_VERSION`: the browser lives in the `cs193v-playwright`
volume, and podman seeds a volume from the image only while the volume is EMPTY. So a
rebuilt image does not refresh a volume you already have. Drop it first:

```
podman volume rm cs193v-$CS193V_INSTANCE-playwright
```

Nothing is lost — the image re-seeds it on the next create. A student never hits this,
because their first container is also their first volume.

The test suite honours `CS193V_INSTANCE` too, so `run-tests.sh` exercises your instance
rather than a colleague's. With the variable unset, every name is byte-identical to what it
was before — a student never sets it.

## Shipping a fix mid-quarter

1. Edit the `Containerfile` (or anything under `files/`); push to `main`.
2. Students run `./cs193v --rebuild`, which sees the moved recipe and builds. Anyone who
   doesn't gets prompted on their next launch.

**What makes step 2 work is `cs193v.buildhash`.** The launcher hashes the Containerfile
plus every file under `files/` and bakes it into the image as a label at build time; on
each launch it compares that label against the files on disk and offers a rebuild when
they differ. This is the replacement for the digest pin, and it is not merely an
equivalent — the image ID could not do this job. podman mints a new image ID on every
build, including a rebuild of byte-identical input, so an image ID says "rebuilt", not
"out of date". The recipe only moves when staff move it.

Two properties worth knowing:

* **A version bump is cheap for students — but only because of where the `ARG` sits.**
  Measured: bumping `CLAUDE_CODE_VERSION` costs **89 s and 95 MB**, with podman's cache
  holding through the vercel layer and only the last ten steps re-running.

  That is a fix, not a property that came for free. With the version `ARG`s declared in a
  block at the top of the Containerfile — the obvious, tidy arrangement — the same bump
  cost **250 s and 726 MB, re-running 18 of 23 steps**, i.e. nothing at all was saved.
  buildah folds every in-scope build arg into each step's cache key, so a top-level `ARG`
  invalidates everything after it and the layer ordering never gets a chance to help. Each
  version `ARG` is therefore declared immediately above the layer that uses it. **Moving one
  back to the top would silently cost every student a full rebuild for a one-line bump**,
  and no test would fail.
* **An unlabelled image never nags.** An image built before the label existed has none,
  and the check treats unknown as "don't prompt" — the same rule the confighash check
  follows. It self-corrects on the first rebuild.

Rollback is `git revert` on the Containerfile. There is no dated-tag safety net any more:
`git` is the only history, so a bad pin is recoverable only by reverting the commit.

## Before students arrive

**§A is now a test suite.** Run it rather than pasting shell:

```
.private/tests/run-tests.sh                  # every automatable check
.private/tests/run-tests.sh --tier static    # no podman or image needed — milliseconds
.private/tests/run-tests.sh --release        # the publishing blanks; fails until filled
CS193V_GH_TEST_TOKEN=github_pat_... \
  .private/tests/run-tests.sh --tier github  # setup-git against the real GitHub; skips without
.private/tests/run-tests.sh --list           # what exists, and in which tier
```

Zero dependencies beyond podman, python3 and shellcheck, and bash 3.2-compatible so it runs
on a Mac. Then work through **`.private/tests/MANUAL.md`** (what genuinely needs a human or another
platform) and read **`.private/ERRORS.md`** (what the first pass found, and what is still open).

`VERIFICATION.md` keeps the prose, because the reasoning per check is worth having — but ten
of its checks did not work as written and are corrected there and in the suite.

The reason this matters more than usual: **podman was never executed while this was
designed** (it wasn't installed in the authoring environment). Every runtime claim was
derived from source and issue trackers — and the very first runtime step turned out to be
broken, so the image had never built at all. See `ERRORS.md` A1.

§5 lists the questions research could not settle. **Answered on native Linux** (details and
measurements in `ERRORS.md` §D):

- does closing a terminal window kill a foreground server? — **It does now, because issue #41
  made it.** The measurement was **No**: all five shapes survived and stayed reachable, exactly
  as conmon's source suggested. That answer stands as a fact about podman and is still recorded
  (`ERRORS.md` D1, `sighup:tab-matrix-*`), but it is no longer the behaviour a student sees. #41
  judged "closing the window provably does nothing" to be the wrong default, so the launcher
  traps SIGHUP and stops the container. The measurement is now the *reason the host has to do
  it*: nothing inside the container can detect a closed window, since the client never dies.
- does `systemd=true` in WSL deliver cgroup delegation? — **still open**, but on native
  Linux the cap is enforced exactly (`memory.max` == `--memory`), an OOM is clean at exit
  137, and the container survives it.
- does host-side `inotify` fire? — **Yes on Linux**, as predicted. Expect not on macOS/WSL.
- is a loopback-bound server reachable from the host? — **Yes now, and that is the point.**
  It used to be No, which was the course's central ports lesson and the reason for
  `--host 0.0.0.0`. The launcher forwards the course ports into the container's own loopback
  over ssh, so all 46 reach a `127.0.0.1`-bound server, a `0.0.0.0`-bound one still works,
  and ports outside the set are still refused. `::1`-only is the one address left out.
- how much does the tunnel cost? — **latency, nothing** (12.1 ms per connection vs 12.6 ms
  for a published port), **throughput, about 8×** (322 MB/s vs pasta's 2.53 GB/s, so a 5 MB
  bundle costs ~15 ms). One ssh process carries all 46 forwards, which is why a new
  connection costs a channel rather than a 158 ms `podman exec`.
- does `podman start` really ignore new flags? — **Yes**, so the `cs193v.confighash`
  machinery is load-bearing rather than defensive.
- how much of a launch was the launcher waiting for itself? — **about a third of it**, and #38
  took it back. Two poll loops, both waiting for something that could have told us: `run_timeout`
  asked `kill -0` every 100 ms about **its own child**, and `tunnel_start` slept a flat 0.5 s
  between `ssh -O check` probes. Measured, before → after: a bare launch against the fake podman
  **3.55 s → 2.16 s** (14 podman calls, so ~100 ms of nothing each); `doctor` against real podman
  **4.04 s → 3.10 s**; tunnel bring-up against a real container **0.55 s → 0.086 s**.
  **`ssh -f` was rejected here and that decision is reversed.** The reason recorded against it was
  real — `-f` forks, so `$!` is a process that has already exited, and a pidfile holding a dead
  number would make `--reset-tunnel` silently decline to kill a wedged master while `doctor`
  reported it up. What it missed is that the pid need not come from `$!`: `ssh -O check` prints
  `Master running (pid=N)`, and the launcher already runs one on the next line. `-f` is also the
  more honest test — it returns after authentication *and* after forwarding is set up, whereas
  `-O check` answering proves only that the mux socket is listening, so the busy-ports report used
  to run while the 46 binds might still be in flight. This is the one wait in the launcher that
  could not simply be polled faster: the probe is a whole `ssh` process, not a builtin.

Still needing other hardware: libkrun vs applehv on Apple Silicon, whether podman 6 runs on
an Intel Mac, and WSL's `--name` support.

## Deliberately not here

So it isn't re-proposed: changing the terminal's background colour (Ptyxis, the Ubuntu 26.04
default, accepts `OSC 11`, reports success on query, and renders nothing — and macOS
Terminal.app ignores it, so it would be invisible on two of three platforms' default terminals
and undetectable on one); `--cap-drop` / `no-new-privileges`
(mutually exclusive with the sudo decision, and they would buy nothing since root owns
the tamper targets); a `serve` wrapper; ripgrep/fzf/bat/fd/delta; man pages;
terminal image viewers; egress filtering; `/etc/gitconfig`; a `cs193v install` verb;
`podman diff` tamper detection.

**No longer on this list: a browser.** "puppeteer and Chrome" was rejected and that decision
is now reversed — the course's test harnesses are browser tests, so `npm test` needs one. It
is Playwright with a Chromium *headless shell*, not puppeteer with Chrome, and the difference
is not cosmetic: Chrome for Testing publishes no linux-arm64 build at all, so the puppeteer
route downloads an x86-64 binary onto an Apple Silicon machine and installs it happily
(puppeteer#7740). Playwright ships its own arm64 build. The image checks the ELF
`e_machine` of what it got and takes a screenshot at build time, so a wrong-architecture or
unlaunchable browser fails the build instead of the student.

`--shm-size` stays rejected, but the reason in `container.args` had to be rewritten: it used
to be "Chrome is not installed", and now the honest reason is that Playwright puts
`--disable-dev-shm-usage` in its own default chromium arguments.

**Four ways of doing Python, all rejected (issue #44).** The image ships an interpreter, `pip`,
headers and `venv`, and no libraries — see the Containerfile's apt line for the rule and the open
item below for the set that was deferred. These are the branches that were measured and dropped, so
none is re-proposed:

| Rejected | The measurement that killed it |
| --- | --- |
| A student-owned venv first on `PATH` | Two pythons. `sudo python3` (via `secure_path`) and any `#!/usr/bin/python3` shebang silently miss the libraries. Installing into the student's **user site** instead gets the same "no sudo, no flags" ergonomics with one interpreter — verified: `/usr/bin/python3`, `#!/usr/bin/python3` and `#!/usr/bin/env python3` all see it. |
| apt libraries (`python3-pandas`, `python3-matplotlib`, …) | 209 MB for older versions than pip's (pandas 2.3.3 against 3.0.5), and 71 MB of that is `python3-sympy` + `unicode-data`, hard `Depends` of Debian's `python3-fonttools` and usable by nothing a student touches. |
| `rm /usr/lib/python3.14/EXTERNALLY-MANAGED` to disable PEP 668 | Identical to `PIP_BREAK_SYSTEM_PACKAGES=1` for pip, but **it does not survive**: the marker is a plain file (not a conffile) in `libpython3.14-stdlib`, and `apt reinstall libpython3.14-stdlib` restores it. A stdlib security update mid-quarter would silently re-break `pip`. |
| Moving `tldr` out of the root-owned `/usr/local/pipx` for uniformity | It would put tldr's dependency tree into the student's import set, where an ordinary `pip install -U` could break the only command help in an image with no `man`. Worse, the tldr gates test the *image*, not a student's later state, so that breakage would be invisible to the suite. |
| `python3-setuptools` on the apt line | PEP 517 build isolation downloads its own backend — a forced `psutil` source build worked with no system setuptools. Debian also de-vendors it into 11 packages. What that costs is small and exact: `pip install --no-build-isolation` fails with `BackendUnavailable`, and `import pkg_resources` / `setuptools` / `distutils` are all `ModuleNotFoundError` (in a fresh venv too — Python 3.12 bundles none of them). `pip3 install setuptools` fixes it in two seconds with no sudo. |

**The floor is free, measured.** `python3-dev` costs 39.2 MB of packages (mostly
`libpython3.14-dev`, plus the `libpython3.14` shared library this image did not previously have),
and removing `python3-numpy` freed 39.2 MB — 27 MB of numpy and 11.7 MB of the `libblas3`,
`liblapack3` and `libgfortran5` that Debian's numpy links against and nothing else here wanted.
Installed size moved by −20 KB, and the image came out **14.3 MB smaller** (2,165,775,565 against
2,180,064,389 bytes). Do not repeat the estimate this replaced: apt's "38 MB additional disk" for
`python3-dev` was measured on a container that lacked dependencies `build-essential` already
provides here.

`python3-numpy` was **removed** rather than kept: nothing in the image imported it
(`rewrite-window-title.py` imports `sys` alone), `apt remove` takes only it and
`python3-numpy-dev`, and one apt-managed library beside a pip-installed set is the state that
misleads — `pip list` reports a version pip cannot upgrade in place, and `pip install -U numpy`
leaves apt's copy shadowed but on disk. `50-image.sh` asserts its absence, so re-adding it fails a
test.

**No longer on this list: tmux, and the persistent frame it makes possible.** Both were
rejected, and both decisions were reversed deliberately. The frame was rejected because the
only portable escape-sequence route to one, a `DECSTBM` scroll region, was measured against
real VTE and **discards scrollback** — 40 lines in, 10 retained. tmux was rejected in the
same breath and "for the same class of cost", on the grounds that it breaks the terminal's
own scrollback and needs Shift to select text.

That second rejection was the wrong reading, and a prototype settled it by measurement
rather than argument. tmux does not *break* scrollback, it *replaces* it: 50,000 lines per
tab, kept by tmux instead of by the terminal, where the DECSTBM route genuinely discarded
lines. And Shift+drag is not a workaround imposed on the student, it is the escape hatch —
plain drag copies through OSC 52 and reaches the same system clipboard, with Shift+drag
still available for anyone who wants their terminal's own selection. So the frame is now
what the container actually has: a title bar and a tab bar, always on screen, which is what
issue #4 asked for and could not previously be built.

What did *not* get overruled is the rest of that prototype's cost, and it is worth knowing
what was paid. The configuration is 500 lines because all four key tables are emptied and
rebuilt: turning `mouse on` after `unbind -a -T root` leaves a session where the wheel
enters a modal copy mode with a dead keyboard and no key that exits, which is the worst
failure available to a beginner. `.private/files/tmux/tmux.conf` documents each trap where
it sits.

**No longer on this list: a VS Code-style port relay.** It was rejected, and that decision
was reversed deliberately — see the ports chapter of `CONTAINER-DESIGN.md`. Two of the three
original objections were addressed rather than overruled: the container is never asked which
ports to open (the forward list is fixed and comes from `CS193V_PORTS`), and the relay is one
ssh process rather than a supervised fleet. The third objection — that it hides the
bind-address distinction — was accepted as true and judged worth the cost.

**No longer on this list: stopping the container when the terminal closes.** The original design
deliberately did the opposite, and issue #41 reversed it. Four alternatives were considered and
rejected on the way, and each is worth recording because each looks better than it is:

- **Reference-counting live terminals**, so several windows could share one container and the last
  one out stopped it. Rejected on failure modes, not on effort. It needs the same "is anyone still
  there?" question answered, and it answers it from host-side state that can go stale — and the two
  wrong answers are not symmetric. A refcount that wrongly says "someone is still there" **leaks**
  a running container, which the next launch and `--stop` both recover from. A refusal that wrongly
  says it **locks a student out of their own container** with a message they know to be false. Given
  a choice about which way to be wrong, the leak wins. So multiple windows went away entirely, and
  a single `podman ps` check replaced ~40 lines of bookkeeping.
- **`podman run -it --rm`**, letting the container's life be the terminal's by construction, with no
  trap to get right. Rejected on three counts: `--rm` throws away the writable layer, so things
  installed with `sudo` would no longer survive until a rebuild; a second launch cannot `run` the
  same name, so the `exec` path is needed anyway and there would be two paths instead of one; and
  the tunnel's `ProxyCommand` needs the container already up, which a foreground `run` does not give.
- **`podman rm` instead of `stop`** on teardown. Cleaner in the abstract and it would make prompt
  injection unable to persist at all, but it silently redefines `--rebuild` as a no-op and breaks the
  documented promise that packages you install stay installed. `stop` keeps the writable layer, and
  the `exited → podman start` path was already written and tested.
- **A grace period** before stopping, so an accidental close could be undone. Rejected because it
  reintroduces precisely the confusion #41 removes: "closing the window stops things, except
  sometimes, for a while" is harder to hold in your head than either rule alone.

The cost that was accepted rather than solved: an accidental window close is **unrecoverable**. Every
tab, its scrollback and any `claude` session mid-task go with it, where the old design would have
handed them all back. That is stated plainly in `CONTAINER-DESIGN.md` rather than hidden. Also
accepted: a force-quit runs no trap, so it leaves a container up with nothing attached — tolerated
because it degrades to exactly the old behaviour, and both the refusal and `--stop` recover from it.

One thing NOT done, and available if the lost-work cost turns out to bite: `podman stop` sends
SIGTERM to PID 1 only, and every other process in the container is killed by the cgroup teardown.
So no student process gets a clean shutdown, and `nano`'s emergency-save on TERM never fires.
TERMing the container's own processes before the stop would fix that; it is a separate change.

Each rejection is documented where it would otherwise be tempting — the invariants block
in `.config/container.args`, and the comments in the `Containerfile`.

## Open items

### ~~Enforcing the bind rule~~ — resolved by the tunnel

**Closed.** This was the open item: enforcing bind-`0.0.0.0` was impossible to do properly,
because **vite reads no `HOST` environment variable at all** (verified against vite 8.1.5 —
`server.host` defaults to `localhost` and is settable only by config or `--host`) and
**Next.js reads `HOSTNAME`, not `HOST`**. So `ENV HOST=0.0.0.0` covered `react-scripts` and
little else, while vite owned two of the six ranges.

The ssh tunnel removes the requirement rather than enforcing it: its far end is the
container's own loopback, so `localhost`, `127.0.0.1` and `0.0.0.0` all work and there is
nothing left to enforce. Vite's default of `localhost` — the exact case that could not be
fixed — is now correct as it comes.

`HOST=0.0.0.0` and `FLASK_RUN_HOST=0.0.0.0` are **gone from the image** rather than left in
place as harmless leftovers. They only ever existed to push servers onto `0.0.0.0`, and with
nothing left to push they would be an unexplained environment variable silently changing what
a student's server binds to — the kind of thing that survives for years and then puzzles
whoever finds it. `50-image.sh` now asserts their absence, so re-adding one breaks a test.

### Python's library set — deferred, not refused (issue #44)

The image installs no Python library. On demand costs **11 s and 56 MB** for pandas, matplotlib,
requests and openpyxl, with no sudo and no flags, so the floor is genuinely sufficient for a student
who has network and does not rebuild. What preinstalling would buy is exactly three things, and each
is a real cost of not having it:

- **It survives `--rebuild`.** The design doc tells students to rebuild first when anything seems
  wrong, and staff say the same — and that throws away the writable layer, so it deletes their
  packages *and* pip's cache at the moment they are already confused.
- **It works offline.** Measured on a bare floor with `--network=none`: name-resolution failure and
  `No matching distribution found for pandas`. Everything else here is deliberately offline-capable
  — tldr's page cache is baked for this reason, Chromium is in the image, the npm globals are baked.
- **It pins one version for everybody.** This is the Containerfile's own red line ("TWO STUDENTS IN
  THE SAME LAB SECTION GET DIFFERENT SOFTWARE"), enforced by `00-release-gates.sh` §3 for every
  other input. An unpinned `pip install pandas` in week 6 walks straight into it, and a student's
  bug report stops being reproducible.

**Revisit when Python analysis becomes graded work**, which is the case where uniformity stops being
a nicety. The menu, measured in the student's user site so it is re-decidable without re-measuring:

| Set (cumulative) | User site | Install |
| --- | --- | --- |
| numpy + pandas + requests + openpyxl | 152 MB | 6 s |
| + matplotlib | 247 MB | 11 s |
| + scipy + scikit-learn + seaborn | 445 MB | 20 s |
| + ipython + jupyterlab/notebook | 652 MB | 38 s |

scipy is +139 MB of that third row on its own (it bundles its own OpenBLAS, as numpy does), seaborn
is +2 MB once matplotlib is there, and Jupyter's default port 8888 is **not** in `CS193V_PORTS` — so
notebooks need `jupyter lab --port 8000` or a change to the port list.

**Where the layer goes if it comes back:** between the Vercel layer and the Claude Code layer,
installed as `su student -s /bin/sh -c "pip3 install --user --no-cache-dir ..."` with `==` pins. That
is the only slot that gets both halves of the cache contract — a library bump does not re-run
Playwright and Chromium (224 s), and a `CLAUDE_CODE_VERSION` bump, the pin most often touched, does
not re-run the libraries. `--no-cache-dir` matters: pip's cache is 56 MB and would otherwise ship in
the layer, the same reason `npm cache clean --force` runs in-layer two steps up.

### Revisit PID 1: is rejecting `--init` still the right call?

`container.args` rejects `--init` because it bind-mounts the **host's** catatonit, which
Ubuntu's podman package only *Recommends* — so a host missing it cannot start the container
at all, which is a hard failure from a package we do not control. PID 1 is therefore a bash
keep-alive loop in `files/entrypoint.sh`, chosen because a shell's `SIGCHLD` handler reaps
any dead child it learns about.

That reasoning is worth re-examining, and the tunnel work turned up a concrete data point.
Measured while an ssh tunnel is up: the container holds **exactly one** `[sshd] <defunct>`,
steady-state, for the tunnel's whole lifetime, dropping to zero when the tunnel exits. Eight
tunnel cycles accumulated nothing, so there is no `pids.max` risk and nothing is broken.

One persistent zombie is a smell, so the process tree was measured against a live tunnel
rather than reasoned about:

```
  PID  PPID STAT  COMMAND
    1     0 Ss    /bin/bash /usr/local/bin/cs193v-entrypoint
    4     0 Ss    sshd-session: student [priv]
    5     4 Z     [sshd] <defunct>          <-- the zombie
    7     4 S     sshd-session: student
```

The zombie is pid 5, the original `sshd -i` that re-exec'd into `sshd-session`, and **its
parent is pid 4, which is alive** — sshd's own privilege-separation monitor, running inside
the container for as long as the tunnel does. A process is only reparented to PID 1 when its
parent *dies*, so while pid 4 lives nothing PID 1 does can reap pid 5. Bash and catatonit
would be equally powerless, and the zombie clears the moment the tunnel exits and pid 4 goes
with it — which is exactly the 1-while-up / 0-while-down measurement.

So this zombie is **not** evidence for or against `--init` in either direction; it is sshd's
internal business. The `--init` question stands on its own merits, and the more interesting
version of it is whether the rejection was aimed at the wrong target: the objection is
specifically to bind-mounting the *host's* catatonit, which shipping our own init binary in
the image would sidestep entirely while still giving PID 1 a real init.

`doctor` reports a zombie count, so the docs must say that **1 is expected while a tunnel is
up**, or a TA reads a healthy container as a faulty one.
