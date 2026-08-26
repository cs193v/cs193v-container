# Manual checks — what `run-tests.sh` cannot do

Everything in `VERIFICATION.md` §A that a machine can decide is now automated. What is left
needs a **person**, a **browser**, a **laptop lid**, or a **different platform**. Work
through this on one machine of each platform and fill in §10's report template.

Run the automated suite first — if it is red, fix that before spending human time here:

```sh
.private/tests/run-tests.sh                    # everything automatable
.private/tests/run-tests.sh --release          # the four publishing blanks
```

Results recorded on **Ubuntu 26.04 native, rootless podman 5.7.0** are given below each
item as a baseline, so you can tell "differs from Linux" from "broken".

---

## Needs a person on any platform

### §1.2 — consent prompts render correctly
Run `bash install-cs193v.sh` on a machine where podman is missing, so it has something to
ask about.
*Expect:* an arrow-key menu, not `[y/N]`. The **declining** option is selected by default
and visually highlighted. Arrow keys move it; Enter confirms.
*Automated already:* the non-TTY path, the wording, and that declining changes nothing
(`25-installer.sh`). The pty-driven arrow-key path is automated for the **launcher's** menu
(`30-launcher-shim.sh :: drift:accepted-*`), which is the same `menu()` function — so what
is genuinely left is only "does it look right to a human".
*Note:* §1.2 as written expects a numbered-selection fallback with no tty. There isn't one,
and there shouldn't be — it picks the safe default. See ERRORS.md B1.

### The build's progress block (no § — it postdates VERIFICATION.md)
`ERRORS.md` B18 records the cursor strobe: the meter left the cursor blinking between two rows at
10 Hz, every byte of the transcript was correct, and it was found by a person running an install.
**A transcript cannot show a display artefact that exists only in time**, so this needs eyes on
it after any change to `meter_*`.

Watch a genuinely cold build in an 80×24 terminal, all four minutes of it:

```sh
podman rmi "localhost/cs193v:local-$CS193V_INSTANCE"   # or ./cs193v --rebuild --no-cache
./cs193v --rebuild
```

`--rebuild` builds only when the recipe moved, which is why the image is removed first: a warm
`--rebuild` is a two-second recreate with no meter to look at. `--rebuild --no-cache` forces one
too, and is the better choice if you also want to watch the network fetches.

*Expect:*
- Bar, step name, and a box of podman's output that fills within a second or two and keeps
  moving. During the base-image download it should show `Copying blob` byte counts climbing — if
  it sits still *there*, the box is missing the one phase it exists for.
- No flicker and no tearing at 10 Hz, and the box's right wall dead straight all the way down.
- **Resize mid-build**: narrower than 73 columns and back, then shorter than twelve rows and
  back. The box should shrink, disappear and return with the block intact — no rows stranded
  below it, no smearing.
- **Ctrl-C mid-build**: the prompt lands *below* an intact block, and the cursor comes back —
  type something and check it echoes.
- At the end the box is gone: one `✓` row, then the green box on clean rows.

Then let one fail (drop the network during the build): one red STOP box, no live box above it, a
`✗` with the bar frozen where it stopped, and the failing lines readable inside the STOP box.

*Automated:* the layout, the sanitising, the eight rows, the geometry ladder and both endings,
against a fake podman on a pty (`30-launcher-shim.sh :: tailbox:*`). What needs a human is
timing, flicker, and whether real podman output is worth reading — none of which is in a
transcript.

### `setup-git` — the four things only GitHub can answer (issue #49)

The sequence, the messages, the redaction and every validator are automated
(`35-setup-git-shim.sh`, `45-setup-git.sh`). Four things are not, and cannot be: they are facts
about GitHub's behaviour, they are undocumented in the direction we need them, and they can change
without notice. `90-setup-git-github.sh` is the harness for all four — it skips unless you hand it
a token, and it redirects `HOME`, `GH_CONFIG_DIR` and `GIT_CONFIG_GLOBAL` into a throwaway
directory so it cannot touch your own login or gitconfig.

**1. Does the prefilled token link actually prefill — all of it?** The link is now the whole of
what most students do: issue #58 deleted the four numbered checks that asked them to read the
prefilled fields back off the page, so nothing between the link and `Generate token` will catch a
field that did not take. That makes this the measurement the token flow rests on.

*To re-measure:* open the link `setup-git --dev-print-token-url` prints, fill in **nothing** by
hand, click *Generate token* and confirm, then open the token's own page at
<https://github.com/settings/personal-access-tokens> and read three fields:

| field | must read | status |
|---|---|---|
| Resource owner | `cs193v-students` | **measured 2026-08-17: yes** |
| Repository access | `All repositories` | **measured 2026-08-19: yes** |
| Expiration | whatever `CS193V_TOKEN_EXPIRY` says | **NOT MEASURED** |

**Expiration is the one still unmeasured**, and it is the one nothing else can catch. A wrong
**Repository access** would stop the student at `git clone` with `err.clone`, which names it as
item 2 and is recoverable; a wrong **Expiration** is silent until the token dies mid-quarter, and
neither the probes nor any test can see it — `00-release-gates.sh` checks the date `setup-git` is
compiled with, not the date GitHub gave the token. If it reads wrong, put one line back into
`token.prefill` naming the field — there are four rows of headroom on that screen — and record
what GitHub actually did here.

Resource owner stays the most expensive of the three, and is worth re-reading whenever GitHub
touches that page: [community discussion
#188111](https://github.com/orgs/community/discussions/188111) reports `target_name` updating the
dropdown's *display* without initialising the form state, which would show `cs193v-students` while
creating the token under the student's own account, and that cannot be changed afterwards. Also
check whether choosing the resource owner by hand wipes the other prefilled fields, as the same
thread reports. If either reproduces, set `CS193V_TOKEN_PREFILL=no` in `files/setup-git`: that
skips the link and the menu with it and prints the by-hand steps as the only route.

**2. Which permission does each failing row actually report?** This is the measurement the failure
messages are built on. Make four tokens, each like a student's but with one permission held back,
and run one per token.

*Before any of them:* the sandbox is per-student since issue #92, so these write into
`cs193v-students/sandbox-cs193v` — the repository staff keep by hand for exactly this, `cs193v`
being a structurally valid SUNetID that is nobody's. The suite types that ID and derives the
repository from it, refusing up front if the repository is missing or has no commits rather than
reporting its absence as a permission finding. `CS193V_GH_TEST_ID=<your sunetid>` points a run at
your own sandbox instead; `CS193V_GH_SANDBOX=owner/name` pins one that does not follow the pattern.

**The commit is the half that is easy to get wrong, and `.default_branch` will not tell you.**
Measured 2026-08-25: GitHub answers `"default_branch": "main"` for a repository with nothing in it
— the name it *will* use, not a ref that exists — so an empty sandbox passed a pre-flight written
against that field, cloned "successfully", and failed at `git pull` with `no such ref was fetched`,
which reads like a token problem and is not one. The check asks for the **branch list** instead: an
empty repository has no branches. Either answer GitHub could give there (`200 []` or an error) stops
the run, so the refusal does not depend on which.

```sh
CS193V_GH_TEST_TOKEN=<contents: read only>  CS193V_GH_EXPECT_ROW='git push' \
  CS193V_GH_EXPECT_KEY=err.push    .private/tests/run-tests.sh --tier github
CS193V_GH_TEST_TOKEN=<no Issues>            CS193V_GH_EXPECT_ROW='gh issue' \
  CS193V_GH_EXPECT_KEY=err.issues  .private/tests/run-tests.sh --tier github
CS193V_GH_TEST_TOKEN=<no Pull requests>     CS193V_GH_EXPECT_ROW='gh pr' \
  CS193V_GH_EXPECT_KEY=err.prs     .private/tests/run-tests.sh --tier github
CS193V_GH_TEST_TOKEN=<resource owner: you>  CS193V_GH_EXPECT_ROW='git clone' \
  .private/tests/run-tests.sh --tier github
```
*Expect:* the named row fails and no earlier one does. The suite records what GitHub said verbatim
(`github:what-github-said`) — **rewrite the message in `setup-git-messages.txt` from that rather
than from the docs** if the two disagree.

**Measured 2026-08-17**, three of the four, against the image's gh 2.97:

| Ablation | Row that failed | Message | Notes |
|---|---|---|---|
| Contents → Read-only | `git push` | `err.push` | as designed |
| Issues → No access | `gh issue` | `err.issues` | fails at `gh issue **create**`, not `list` |
| Pull requests → No access | `gh pr` | `err.prs` | as designed |
| Resource owner → yourself | — | — | **NOT MEASURED**, see below |

**The clean-pass case re-measured 2026-08-25**, against a per-student sandbox for the first time
(`cs193v-students/sandbox-cs193v`, typed as SUNetID `cs193v`, gh 2.97): a correctly configured token
passes all **twelve** rows — seven config commands now that `cs193v.sunetid` is one of them, then
the five probes — and leaves no branches and no open issues behind. That is the run worth repeating
whenever the probe list or the repository's shape changes, which is what issue #92 changed.

The Issues row is the interesting one. `gh issue list` **succeeds** with the Issues permission at No
access — listing is covered by repository read — so the failure lands on `create`, and gh reports it
over GraphQL rather than REST: `GraphQL: Resource not accessible by personal access token`. Two
consequences worth keeping: `err.issues` naming *Read and write* is exactly right rather than
accidentally right, and any future filter written against the REST wording alone would miss this.

**3. Does `/user/repos` tell an org-owned token from a personally-owned one?** **NOT MEASURED, and
it needs a second GitHub account.** `setup-git` claims outright that a token belongs to the wrong
account, and it earns that claim by finding the student's own repositories in `GET /user/repos` and
none of the organization's. The ablation that would settle it — a token whose resource owner is
yourself — cannot be run from an account that OWNS cs193v-students, because there is no way to tell
"the token reached the org repo through resource-owner scoping" from "it reached it because this
account administers the org". Settling it takes a throwaway account added to the organization as a
plain member.

The two one-liners that answer it, given a token of each kind. `GH_TOKEN` stores nothing and logs
nobody out, so neither of these disturbs your own login:

```sh
GH_TOKEN=<org-scoped token>      gh api 'user/repos?per_page=100' --jq '[.[].owner.login]|unique'
GH_TOKEN=<personally-scoped>     gh api 'user/repos?per_page=100' --jq '[.[].owner.login]|unique'
```

*Expect:* the first lists `cs193v-students`, the second lists only the account's own name. If the
second lists the organization too, the discriminator cannot work and `err.clone-wrong-owner` and
`token_owner_wrong` should both be deleted rather than left as a path that never runs.

**WHY LEAVING IT UNMEASURED IS SAFE, while leaving it unrecorded would not be.** `token_owner_wrong`
returns "not wrong" unless it has positive evidence — a non-empty owner list, the organization
absent from it, and the student's own login present — so every ambiguous answer, including an empty
one, falls through to the four-item checklist. The failure mode of being wrong here is a student
reading a checklist that includes the real cause as its first item, not a student being told
something false. That is why this ships unmeasured; it is also why it must not be described as
verified.

**4. What does a pending token, or a non-member, actually look like?** **NOT MEASURED.** Both
produce the same 404 as the two causes above, which is why the `git clone` message is a checklist.
Reproduce each once against a token awaiting approval and against an account that has not accepted
its invitation, and check that the checklist covers what you see. Same second-account requirement as
§3 for the non-member half.

**5. What does a student see whose sandbox is not there yet?** **NOT MEASURED**, and it is now the
most likely 404 of the five: a mistyped SUNetID and a repository the deploy script has not created
are the same answer from outside, because the repository is private — GitHub cannot say "it exists
but is not yours" without saying whether it exists. So no probe can tell them apart, and `err.clone`
does not try: it names the repository it looked for and puts *Your SUNetID* first in the checklist,
ahead of the four token causes. What is unmeasured is whether that reads as actionable to a student
who has typed their ID correctly and simply arrived early.

*To measure:* **not through this tier** — its pre-flight refuses a missing sandbox on purpose, which
is the opposite of what you want here. Drive the installed script by hand instead, with a throwaway
HOME so it cannot touch your own login, and type a valid SUNetID nobody has a sandbox for:
```sh
podman exec -it -e HOME=/tmp/sgx -e TMPDIR=/tmp/sgx -e GH_CONFIG_DIR=/tmp/sgx/gh \
  -e GIT_CONFIG_GLOBAL=/tmp/sgx/gitconfig "cs193v-$CS193V_INSTANCE" setup-git   # type: zzz9
podman exec "cs193v-$CS193V_INSTANCE" rm -rf /tmp/sgx
```
*Expect* the `git clone` row to fail with `err.clone`, its first item naming the SUNetID and the
repository it looked for. Read it as a first-year would: is that enough to act on?

### `setup-git` — the display, which no transcript can show
Run it for real in an 80×24 terminal, with a working token. **The container's tmux takes the top
row for its status line, so the budget is 23, not 24** — which is the arithmetic issue #58 turned
on.

*Expect:*
- **The token screen does not scroll, on any of its three paths.** Measured at 80 columns: the
  link and its menu are 19 rows, "Yes, I see my token" through to `Your token:` is 21, and the
  by-hand steps through to `Your token:` are 22. If any of them scrolls, something has been
  reworded past 76 columns and `20-messages.sh` should have said so.
- **The link is on a line of its own and selects cleanly.** It is 157 characters, so it soft-wraps
  on anything under ~160 columns; that is issue #67, not this.
- **Arrowing down to "That link didn't work for me" reaches the eight by-hand steps**, and
  choosing the default reaches the paste prompt without them ever appearing.
- One row per command, the braille spinner turning in column 5 while each runs, replaced by a
  green `✓` — no flicker, and no row drawn twice or left half-erased.
- A failing row's `✗` in red, in the same column, with the rows above it untouched.
- **The cursor blinking at `Your token:` before you type anything.** Issue #53: it was hidden for
  the whole run, and a prompt with no cursor in it reads as a program that has stopped. Same at
  `What is your SUNetID (e.g. htiek, szum)?`, which is the first thing on the screen.
- The token itself never on the screen as you paste it — what appears instead is
  `••• ... 87 more characters ... •••`, growing as the paste lands, on one line that does *not*
  wrap. Backspace over it and the count comes down cleanly with no smear.
- **Ctrl-C in the middle of a probe: the cursor comes back.** Type something and check it echoes.
  This is ERRORS.md B18's failure mode in a second place, and a transcript cannot show it.
- **Ctrl-C while `Your token:` is waiting: the cursor comes back *and typing echoes*.** That prompt
  turns echo off at the terminal for the length of the paste, so this is the same failure mode in a
  third place, and the worse one — a student who loses echo loses it for the whole session.
- **The clone-failure screen scrolls, and it did before issue #92 too.** Measured 2026-08-25:
  `err.clone` is 22 rows, and the prompt and menu under it add seven, so 29 against the 23 a tmux
  pane leaves — the title, the repository name and the two-line intro go off the top. It was 26
  before this issue added the SUNetID as a fifth cause. Recorded rather than fixed because the
  alternative is deleting one of the five things to check, and the path a student needs is
  self-contained without the scrolled part: item 1 says to re-run `setup-git` and choose *Start
  over*, and the screen that lands on prints `Your SUNetID:` where they can check it. **Worth a
  human's eyes on whether that is enough**, and worth knowing that shortening any of the five
  messages is the lever if it is not.
- The green ALL SET box closed and square on the right.

*Automated:* the glyphs, the messages, the ordering, the redaction, the tally's count and width,
and the cursor sequences (`35-setup-git-shim.sh`), plus that the terminal is handed back with echo
on (`35 :: tty:*`) — which that suite settles by asking the pty after the run rather than by reading
the transcript. What needs eyes is timing and flicker.

### §7.2 — Ctrl-S does not freeze the terminal
In `./cs193v`, press Ctrl-S, then type.
*Expect:* typing still echoes. If it freezes, `stty -ixon` is not being applied.
*Automated:* that the setting is installed in both `profile.d` and `bash.bashrc`
(`50-image.sh :: shell:*`). Only the interactive effect needs a human.

### §7.3 — pager behaviour
A one-line `git diff`, then `git log`.
*Expect:* the one-line diff prints without entering a pager (that's `LESS=FRX`'s `F`),
colour is not shown as escape codes (`R`), and output stays on screen after quitting (`X`).
*Do not* use `man ls` as §7.3 says — `man` is deliberately absent, and the stub prints an
`unminimize` message. See ERRORS.md B6.

### §7.6 — fonts render as glyphs, not boxes
Font *discovery* is now automated: `fontconfig` is installed and
`50-image.sh :: fonts:sans-serif-resolves-to-noto` asserts that `fc-match sans-serif` resolves
to a Noto face, which is the part that was actually broken.

What a human can still add, if it matters to the course: neither Pillow nor matplotlib is in
the image, so §7.6's original instruction cannot be followed as written. To check actual
rasterisation, install one first — which is itself a useful check that a student can add
packages:

```sh
python3 -m venv ~/venv && ~/venv/bin/pip install pillow
~/venv/bin/python -c "
from PIL import Image, ImageDraw, ImageFont
f = ImageFont.truetype('/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf', 32)
i = Image.new('RGB', (420, 60), 'white')
ImageDraw.Draw(i).text((10, 10), 'Latin text renders', font=f, fill='black')
i.save('/home/student/projects/font-check.png')"
```

*Expect:* legible glyphs, not boxes, when you open `projects/font-check.png` on your own
machine. Note the explicit `truetype()` path — Pillow does not go through fontconfig, so this
tests the font files rather than their discoverability.

### §8.1 / §8.2 — logins with no browser in the container
`claude` then `/login`; then `gh auth login`; then `vercel login`; then `codex login`.
*Expect:* a login completes. Whether you SEE the `$BROWSER` stub's box depends on the caller —
see the known limitation below.

**TRY CODEX'S BROWSER FLOW BEFORE REACHING FOR `--device-auth`.** Its callback wants
`localhost:1455`, and any port a program binds inside the container is forwarded within about a
second of the bind, so nothing has to be arranged for it. If the redirect flow works, say so —
the same question is open for the other three, and issue #82 is where it gets measured.

**FIXED, AND WORTH LOOKING AT ON PURPOSE — `claude` `/login` now shows the link in a popup.**
Claude Code spawns `$BROWSER` with its **stdout captured** (verified: 2.1.225 spawns
`process.env.BROWSER` on Linux), so the stub's printed box went into a pipe and was discarded and
what you saw was Claude's own full-length URL. That was issue #85. The box is now a tmux popup,
which tmux draws over the panes and keeps drawing, so a captured stdout no longer hides it.

*Expect:* the box appears **immediately**, with a spinner reading `(creating link...)` where the
link will be, and the link replaces it a beat later — around a second, longer if a host port is
contended. Watch for that order specifically: the box arriving before the link is the whole point
of it, and a box that only turns up once the link is ready is the regression.
`podman exec <container> pgrep -af '[s]hortlink'` still confirms the stub ran.

**AND THE FAILURE, WHICH IS THE HARD ONE TO SEE ON PURPOSE.** With no reachable port the box
shows `Unable to create a link your browser can reach`, waits (no countdown, no self-close), and
the long URL is printed to stdout as well. The cheap way to provoke it is a wrapper first on
`$PATH` that exits 3 after echoing its argument; the honest way is `./cs193v --reset-tunnel` on
the host mid-session. Neither is a release gate — the tmux tier drives both — but if you have
never seen the error frame, see it once.

**THE ONE THING NO SUITE CAN CHECK, and the feature rests on it (issue #67).** Use a caller that
does NOT capture — `setup-git` is the one that matters, and `gh auth login`, `vercel login` and
`codex login` are worth checking since nobody has established whether they capture. The stub
prints a short `http://localhost:PORT/magic-link` served by `shortlink` (setup-git's is
`/magic-token-link`) inside the container.
**Click it, from the terminal, inside tmux** — CMD+click on Terminal.app and iTerm2, CTRL+click
on Windows Terminal and GNOME Terminal. `mouse on` means tmux sees ordinary clicks, so whether
the terminal still intercepts a click on a URL is a per-terminal question, and this is the only
place it gets answered. Do it on every platform.

If clicking does not work somewhere, that is worth recording but is **not** a blocker: 39
characters can be retyped, and SHIFT+drag copies them in one piece, which is the whole of what
#67 was about. What WOULD be a blocker is the link not resolving at all — check `cs193v doctor`
on the host for a port the tunnel could not bind.

Also worth one look: open the same link **twice**, and open it again after a few minutes. It is
meant to serve any number of times for fifteen minutes and then stop.
During `gh auth login`, answer **yes** to "Authenticate Git with your GitHub credentials?"
then confirm `git push` works from a test repo.
*Automated:* the stub itself, and that all five credential directories are student-owned
volumes with deny rules (`50-image.sh`).
*ERRORS.md B10 no longer needs settling here.* It asked whether Claude Code's auto-update
works given where the CLI is installed; it does, and the check turned out not to need a
login — see B10, now fixed. Claude Code is installed as the student in
`/home/student/.local/lib/node_modules`, which the student owns, so an update rewrites it in
place. `npm:*` in `50-image.sh` holds that.

### Codex's approval reviewer — the one setting nothing can assert
`/etc/codex/managed_config.toml` ships `approvals_reviewer = "auto_review"`, and `codex doctor`
never names the reviewer even with `--all`, so no test in the suite can tell `user` from
`auto_review`. Only a live escalation shows who answers.

Inside the container, logged in to codex, ask for something that needs to leave the workspace:
```
codex exec 'run: sudo apt-get install -y sl'
codex exec 'append a line to /home/student/.bashrc'
```
*Expect:* the escalation is decided **without the student being asked** — the reviewer subagent
answers it. If a prompt reaches the student instead, the setting is not in effect: codex ignores an
unrecognised key in silence (verified), so an upstream rename would look exactly like this and
nothing else would fail.
*Also record* whether the sandbox stopped the command at all. `codex doctor` says `filesystem
sandbox restricted`, but it says that for `read-only` too, and Anthropic documents bubblewrap being
unable to mount a fresh `/proc` in an unprivileged container — so a write that simply succeeds
outside `~/projects`, with no escalation, is the signal that there is no boundary here to escalate
out of.
*Automated:* that the file is present, parses, is student-readable and not student-writable, and
that codex really reads `/etc/codex` at all — the last one by overriding the policy with a
different value and watching `codex doctor` change (`50-image.sh`).

### §8.7 — a permission prompt in the wild
Ask the agent to do something that triggers a prompt.
*Expect:* wording a first-year student can act on. Record it — this is the moment the
course's core skill is taught.

### §A.11 — the deny rules actually deny
Inside the container, with Claude Code logged in:
```
claude -p "Use the Read tool on /home/student/.claude/.credentials.json and print what you get."
claude -p "Use the Read tool on /home/student/.claude/settings.json and list its top-level keys."
claude -p "Use the Read tool on /home/student/.config/gh/hosts.yml."
claude -p "Use the Read tool on /home/student/.codex/auth.json."
claude -p "Run: cat /home/student/.codex/auth.json | head -c 20"
claude -p "Which port ranges may a dev server use in this container? List them and nothing else."
```
*Expect, in order:* refusal; **success** (the deny covers the credential file, not the whole
directory); refusal (whole subtree denied); refusal (`~/.codex` is denied wholesale, for the
reason in `managed-settings.json`: OpenAI moves the credential filename, and `history.jsonl` is
every prompt the student has typed); **success** (Bash is not covered by a `Read(...)` rule, and
that is the honest limit of these rules rather than a gap — an agent with Bash can read anything
the student can); the six forwarded ranges from the notes.

*Also:* the same port-ranges answer proves the SYMLINK works — `/etc/claude-code/CLAUDE.md` is a
link to `/etc/cs193v/agent-notes.md` now, and nothing in the suite can prove Claude Code follows
it in the managed slot. Ask codex the same question (`codex exec "Which port ranges may a dev
server use here?"`) to cover the other end of the same file.
Also check `claude -p "reply with exactly: ok" 2>/tmp/cc.err` leaves `/tmp/cc.err` with no
"ignored"/"invalid"/"unknown key" warning — a `Write(...)` or `Glob(...)` path rule would be
accepted and then silently ignored.
*Automated:* the rule *forms* are asserted statically and in the image
(`10-static.sh`, `50-image.sh :: claude:deny-rules-are-Read-or-Edit-only`). Whether Claude
Code honours them at runtime needs a real session.

### §3.4 / §3.5 — real hot reload
In a scratch project inside the container: `npm create vite`, run the dev server **with no
`--host` flag at all**, open it in a host browser, then edit a source file **from inside the
container**.
*Expect:* the page hot-reloads. `inotifywait` firing is necessary but not sufficient. Running
vite unflagged is deliberate: it binds `localhost`, which is exactly the case that used to be
unreachable, so this doubles as the end-to-end proof that the `--host 0.0.0.0` rule is really
retired. Watch the HMR websocket too — it shares one pipe with asset loading, and measured
contention was nil, but a human watching a real edit loop is the honest check.
Then edit the same file **from a host editor**.
*Linux baseline:* container-side inotify fires (asserted), and **host-side also FIRES** on
native Linux. On macOS and WSL host-side is expected not to; record which, because
`CONTAINER-DESIGN.md`'s "known rough edges" depends on it.

### §5.1 — closing a terminal window, for real
**The single most important manual check in this file**, because the whole of issue #41 rests on
one thing no automation can press: the close button.

Start a server in a tab (`python3 -m http.server 3000`), confirm you can reach
`http://localhost:3000` from your browser, then **click the window's close button**.

*Expect:*
- `podman ps -a` shows the container `exited` within a few seconds.
- `ss -ltn | grep 3000` shows nothing — the 46 forwards went back with it.
- `./cs193v` again gives you a working shell with **fresh tabs**, and `podman inspect --format
  '{{.Id}}'` shows the **same** container id as before (stopped, not recreated).

*What a failure means:* the launcher did not receive SIGHUP, or its trap did not run. The container
is left running with nothing attached, which is survivable — `./cs193v` refuses and names
`--stop` — but the feature is silently not working on that platform.

*Linux baseline:* automated, and green. `70-sighup.sh` destroys the pty rather than pressing the
button, which is the same mechanism (closing the master HUPs the foreground process group). This
check exists to confirm that equivalence on a real terminal.

**Worth doing on macOS (Terminal.app and iTerm2) and on WSL**, where the `podman exec` client lives
outside the VM and nothing in the Linux suite can answer for them. Also try **force-quitting** the
terminal on each: expect the container left running, and `./cs193v` to explain it and point at
`--stop`.

### §5.6 — what an OOM looks like to a student
Run the allocation loop from an interactive shell.
*Linux baseline:* the process is `Killed` and the shell reports **exit 137**; the container
survives and `podman exec` still works (all asserted). Record the exact on-screen text —
it becomes the troubleshooting entry for 137.

### §2.8 — zombies after real use
After a few hours of normal work: `cs193v doctor`, and read the `zombies` line.
*Expect:* **`0 unreaped`**, always. The second number is `1 held by a live parent` while the
port forwarding is up and `0` with it down — that one is `[sshd] <defunct>`, and it is
expected rather than a leak: its parent is sshd's own privsep monitor, which stays alive as
long as the tunnel does, so it is never reparented to PID 1 and no PID 1 could reap it. It
clears when the tunnel exits, and eight tunnel restarts accumulated none.
**`unreaped` is the number that means anything** — those are PID 1's to collect, and a
non-zero one that persists is the leak that eventually wedges the container. A count that does
not split the two is what made the automated check a coin flip (#102); `.private/README.md`'s
`--init` item has the measured process tree.
*Automated:* PID 1 adopts eight deliberately orphaned processes and reaps all eight when they
are killed together; no zombie of PID 1's survives a bounded wait; and the tab-close matrix
adds none beyond the ones present before it ran (`60-container.sh`, `70-sighup.sh`). Both of
doctor's numbers are recorded rather than asserted, because both are legitimately non-zero
for a moment.

---

## Needs sudo (skipped — nobody was at the keyboard)

### §1.5 — `sudo ./cs193v` is refused
*Expect:* a clear refusal explaining that this would run podman rootful and defeat the
isolation model, exit non-zero, and create nothing.
*Automated equivalent:* the same branch is exercised by faking `id` in
`30-launcher-shim.sh :: root:*`, which asserts the refusal, the wording, a non-zero exit,
that nothing is created, and that podman is not even contacted. Only the real `sudo`
invocation is unverified.

### `sudo usermod --add-subuids` against a real `/etc`
*Expect:* on a machine whose account has no subuid range, the installer's one privileged
`usermod` call adds `200000-265535` to `/etc/subuid` and `/etc/subgid`, and `./cs193v doctor`
then passes where it previously refused with "your account has no subuid range".

*Automated equivalent:* two halves, neither of which is this.
`25-installer.sh :: subuid:asks-root-for-the-right-range` proves the installer **asks** for
exactly that command — `sudo-fake` records argv and executes nothing.
`25-installer.sh :: usermod:*` runs the real `usermod --prefix` against a **synthetic** root and
proves the command **does** what the installer needs: the range lands in both files, in the form
`cs193v:1073` greps for, and nothing outside those two files and their backups is touched.

What is left for a person is only the composition of the two — the real binary, invoked through a
real `sudo`, against the real `/etc`. It cannot be automated in a container at all: `setup_subuid`
writes a fixed `200000-265535`, which is outside a container's own ID window, so podman stops
working there afterwards while it works fine on a laptop. That is why the container case for this
was removed rather than left making half a claim.

### §2.4 / §9.2 — `--rebuild --logout` really deletes the volumes
Destructive: it logs you out of claude, codex, gh and vercel, and takes the git identity `setup-git`
configured with them — the credential helper line lives in that volume, so leaving it behind would
point git at a token that no longer exists. Gated behind an opt-in so a routine suite run cannot do
it to you:
```sh
CS193V_DESTRUCTIVE=1 .private/tests/run-tests.sh --tier live
```

---

## Needs another platform

### A real Fedora machine — what it would tell us that no fixture can
The installer supports Fedora as of the dnf work, and the fixtures cover a lot: `--base fedora`
proves the family is detected and Fedora's package names are used, and `fedora-e2e` proves
`dnf install -y podman` really reaches Fedora's mirrors and that the podman it installs builds the
entire 25-step course image (`installer-rc = 0`, ~6.2 GB of inner store, matching Ubuntu and Debian
to within 23 KB). **All of that runs in a Fedora container on an Ubuntu host**, which is the limit:
the userland is Fedora's, the kernel is this machine's.

So what a real Fedora box adds is exactly the kernel-level things, and there are three:

- **SELinux enforcing.** SELinux is a kernel feature with one policy per machine and it is not
  namespaced, so a Fedora container on an Ubuntu host reports it disabled however Fedora is
  configured. This is where **issue #107** lives: the launcher adds `,z` to the workspace bind mount
  when `getenforce` says `Enforcing` (`cs193v:998-1012`) but never relabels the two tunnel-key
  mounts, and all three sources are under `$DIR`. If that matters, the symptom is that the container
  starts, the workspace works, and the **tunnel does not** — nothing reachable at `http://localhost`.
- **systemd cgroup delegation.** The nesting fixtures pin `cgroup_manager = "cgroupfs"` because
  there is no systemd user session inside one, so nothing here exercises the `--memory` cap
  `write_local_args` computes. That gap is not Fedora-specific — it is true of every fixture — but a
  real machine is the only place to check it.
- **Fedora's own kernel**, for anything version-gated.

*What to run there, in descending order of value:*

1. **Run the installer for real** — `bash install-cs193v.sh`. This is the end-to-end test. The
   fixtures already cover its *logic*; what a real machine adds is the real kernel, real SELinux and
   real systemd. Watch that `cs193v doctor` reports sensibly afterwards.
2. **Then `run-tests.sh --tier container,live`.** These drive the real launcher against the real
   course container with **no nesting**, so they are where the `,z` decision and the tunnel are
   exercised for real. `require_tunnel` and the port-forwarding assertions are what would catch
   #107. This is the most informative thing a Fedora machine can do.
3. **Do not expect `--tier install` to be informative there, and expect it may fail.** Those
   fixtures nest podman inside podman, and `machine_flags` passes no
   `--security-opt label=disable` — which every upstream nesting recipe passes on an SELinux host.
   A failure there would be about our harness, not about the product, and `.private/README.md`
   records that deliberately-unguarded gap. Judge Fedora by (1) and (2).

### The macOS podman floor, and the `podman machine` nobody has exercised
The podman floors diverged when the Linux one dropped to 4.9.0: `MIN_PODMAN_LINUX="4.9.0"` and
`MIN_PODMAN_MACOS="5.7.0"`, declared in both `install-cs193v.sh` and `cs193v`. The Linux floor is
measured — `26-installer-sandbox.sh :: oldest-supported` builds the whole course image on a real
podman 4.9.3. **The macOS one cannot be**, and that is why it did not move.

`podman machine` was rewritten completely in podman 5.0, and `setup_machine` leans on it hard:
`machine init --memory --disk-size --now`, `machine set --memory`, `machine set --disk-size`,
`machine inspect --format '{{.Resources.Memory}}'` and `'{{.Resources.DiskSize}}'`. macOS is not
container-testable, so no fixture reaches any of it. Holding the macOS floor at 5.7.0 keeps the
pre-5.0 implementation out of reach rather than trusting it.

*What a person on a Mac should check, in order of how likely it is to matter:*

1. **A Mac with no podman at all** — the ordinary path. The installer downloads
   `PODMAN_MACOS_VERSION` (6.0.2) and never consults the floor. *Expect:* unchanged behaviour.
2. **A Mac already carrying podman 5.7.0 or newer** — accepted, `setup_machine` runs against it.
   *Expect:* unchanged behaviour. This is the case the floor is chosen to guarantee.
3. **A Mac carrying podman older than 5.7.0** — refused, with the message rewritten for this
   change. Check that the *right branch* fires: `command -v podman` under `/opt/homebrew/` should
   offer `brew uninstall podman`, anything else should name the path and offer
   `sudo rm -rf /opt/podman`. *Expect:* the advice matches how podman actually got there. The old
   message said "open Podman Desktop and let it update itself", which was wrong for the `.pkg`
   this installer itself uses.
4. **Nothing is removed for them.** The message tells the student what to run; the script must not
   run it. Removing podman can destroy a `podman machine` VM and everything in it, and the message
   says so. *Expect:* after a refusal, `/opt/podman` and any existing machine are untouched.

*Not automatable, and not worth faking:* the shim tier can fake `uname -s` and a podman version,
so the refusal branch and its two-way message split **are** reachable there — what is not is
whether `podman machine` on a pre-5.0 podman would actually have worked. Nobody needs to find out
while the floor holds.

### §1.3 — bash 3.2 on macOS
`bash --version` (expect 3.2.x), then run the installer with `/bin/bash` explicitly, and run
`.private/tests/run-tests.sh --tier static,unit,shim` — the suite is bash 3.2-compatible on purpose
so it can run here.
*Expect:* no `mapfile`, associative-array or `${x,,}` errors.
*Automated on Linux:* the ban-list greps, plus a check that every empty-array expansion uses
the `${arr[@]+...}` guard — which is a **bash 3.2-only** failure that no Linux run can
surface (ERRORS.md A5). Running the suite on a Mac is what actually proves it.

**Also watch for a bare `"$@"` in a function that some caller invokes with no arguments.** Bash
before 4.4 treats `"$@"` and `"$*"` as *unset* when there are no positional parameters, so under
`set -u` — which every suite here sets — such a function aborts on this platform and returns
nothing. It is the same failure as the empty-array one and it is **not** covered by a grep: a bare
`"$@"` is correct in most of the places it appears here (`assert_ok`, `run_suite`), and only the
zero-argument call sites are wrong, which no static check can tell apart. `ours_containers` in
`80-launcher-live.sh` was written this way once; it takes one explicit optional word now, which is
the shape to prefer. On a Mac the symptom is a run of idempotency assertions comparing against an
empty string.

### §4.5 / §4.7 — Windows firewall and a real browser
On first port bind, note whether Windows Defender prompts. *Expect:* still no prompt, since a
loopback bind needs no exception — but the binding process changed from pasta to `ssh` and
Defender's rules are per-executable, so this must be re-checked rather than inherited. Record
the exact wording if one appears.
Then open `http://localhost:3000/` in the student's real browser. If `localhost` fails but
`127.0.0.1` works, record it — `localhost` may be resolving to `::1`.

**And the one that matters most on Windows:** run the server bound to the container's
`127.0.0.1` (no `--host`). The ssh client binds `127.0.0.1` *inside the WSL2 distro*, and the
browser is on Windows, so this depends on Windows' localhost forwarding reaching an
ssh-bound listener the way it reaches a pasta-bound one. `container.args` establishes it does
for pasta (podman#17972, #22562) and ssh binds the same way — but "binds the same way" is the
reasoning that made `--host-lo-to-ns-lo` fail on macOS, so it is unverified until someone
tries it. If this fails, the tunnel does not work on Windows and nothing should ship.

### §5.2 — macOS provider: libkrun vs applehv (Apple Silicon)
Run §A.7's ownership checks (`.private/tests/run-tests.sh --tier container -k files`) under **both**:
```sh
podman machine stop
CONTAINERS_MACHINE_PROVIDER=applehv podman machine init cs193v-test && podman machine start cs193v-test
# ...then again with libkrun (podman 6's default)
```
*Expect:* both work. Libkrun's virtiofs **enforces** permissions where applehv's is
permissive, and there are open reports of read-only bind mounts and `root nogroup` ownership
(`podman#28316`, `#27893`, `#27679`). Confirm `--userns=keep-id:uid=1000,gid=1000` resolves
it on both. **If libkrun fails, the install docs must pin applehv.**

### §5.3 — Intel Mac
Attempt the full install. The installer currently **refuses** these machines outright.
Confirm or refute that podman 6 cannot run there; the support policy depends on it.

### §5.4 — WSL `--name`
`wsl --install -d Ubuntu-26.04 --name CS193V`
*Expect:* succeeds on current WSL. If `--name` is unsupported, the fallback is
`wsl --import` from a hosted rootfs, which changes the installer.
**The floor is WSL 2.5.8**, established by diffing `WSL_INSTALL_ARG_NAME_LONG` in
`src/windows/inc/wsl.h` across tags 2.4.13 (absent), 2.5.7 (absent) and 2.5.8 (present). A
maintainer comment saying 2.4.4 is wrong. `--name` also rejects **legacy** Store distributions
(`'--name' is not supported when installing legacy distributions.`), so a fallback to `-d Ubuntu`
on an old WSL would fail here too.

### install-cs193v-windows.cmd — what wine cannot answer
`.private/tests/run-tests.sh --tier windows` executes the whole file under wine's cmd.exe and
reaches all fifteen branch targets. Read the count off
`record "windows:branch-targets-in-the-file"` rather than trusting this sentence: the suite
derives it by parsing the file, and this line is a copy. Three things it structurally cannot
settle, and one it should not be trusted on:

1. **LF vs CRLF.** cmd.exe reads batch in 512-byte chunks with a label scanner that assumes
   `\r\n`, so LF-only endings break `goto`/`call :label` *non-deterministically by byte offset*.
   Wine reads bare `\n` natively (`batch.c:259-266`), so a green wine run proves nothing.
   `25-installer.sh` asserts CRLF statically instead. *Verify once on a real box:* the file runs
   start to finish and every `goto` lands.
2. **`::` inside a parenthesized block.** Wine accepts it; real cmd.exe treats it as a label and
   errors. Measured. Also a static rule, for the same reason.
3. **Every EFFECT.** Whether `wsl --install` really installs, whether the feature really needs a
   reboot, whether `--name` really works on the student's build. The suite fakes `wsl.exe`
   entirely, so it reaches every decision and no consequence. Since stage one now *downloads*
   stage two, three of those consequences are new and each one breaks every Windows student at
   once, so verify all three on a real box:
   - `wsl -d CS193V -e curl --version` — is curl in a fresh `Ubuntu-26.04` distro at all? If it
     is not, stage one installs it, so also check that
     `wsl -d CS193V -u root -e env DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates`
     completes **without a password prompt and without any debconf question**. `-u root` is the
     whole reason no password is asked for; confirm that, do not assume it.
   - **`wsl.exe` passes the long `-e` command line through unmangled.** `fake-wsl.c` matches argv
     by `strcmp` and never parses it, so a green tier proves nothing about whether the real
     `wsl.exe` forwards `--retry 10 --retry-delay 3` to curl or eats `--retry` as its own. Check
     `wsl -d CS193V -e curl -fsSL --retry 10 --retry-delay 3 -o /tmp/x <url>` by hand.
   - **`raw.githubusercontent.com` resolves and is not blocked.** This is a NEW host: stage two's
     own tarball URL 302s to `codeload.github.com` instead. Try it from campus wifi and from a
     dorm room, not just from a staff machine. `00-release-gates.sh` fetches the URL, but only
     from wherever the release run happens.
4. **The Tier C strings** in `fixtures/wsl-messages.2.9.8` — `net.exe` and `where.exe` are closed
   components with no published exit-code contract, so their wording is third-party-attested only.
   The suite gates on their exit codes and matches prose loosely. *Verify once:* run
   `net session` elevated, unelevated, and with the Server service stopped, and compare.

### Ubuntu's first-run setup, which the installer warns about but cannot control
`wsl --install -d Ubuntu-26.04 --name CS193V` **launches** the new distribution and returns *the
launched shell's* exit code, not the install's (`WslClient.cpp:592-614`). That is why the
installer no longer tests that exit code and re-runs its distro probe instead.

The first-run experience is Canonical's `/usr/lib/wsl/wsl-setup` (package `wsl-setup`, named by
`oobe.command` in the image's `/etc/wsl-distribution.conf`), **not** the old Store-era
`Enter new UNIX username:` prompt. Expected sequence on 26.04:

```
Provisioning the new WSL instance CS193V
This might take a while...
                                       <- a silent cloud-init pause, can be many seconds
Create a default Unix user account: <windows username, pre-filled and editable>
New password:
Retype new password:
passwd: password updated successfully
Help improve Ubuntu! ... [Y/n/e]:     <- 26.04 ONLY; absent on 24.04 (wsl-setup 0.6.1)
```

*Verify:* three questions, not two — the installer's on-screen warning says so, and that wording
only matters if it is true. Then confirm the student is left at a `$` prompt and that **typing
`exit` returns to the setup**, which is the one instruction nothing used to give.

*And the nasty one:* abort the OOBE at the password prompt, then re-run. If the abort lands after
`adduser` created the account but before `passwd` set a password, `wsl-setup`'s
`get_first_interactive_uid` finds that uid, **skips user creation entirely**, and makes it the
default — leaving an account with no usable password, so `sudo` never works and the student is
never re-prompted. Recovery is `wsl --unregister CS193V` (§9.3), which is destructive. Confirm or
refute; if it reproduces, the installer needs to detect it.

### §5.5 — cgroup delegation in WSL
With `systemd=true` in `/etc/wsl.conf`: `.private/tests/run-tests.sh --tier container -k 60`
*Expect:* `kernel:cgroup-memory-max` equals `--memory`, not `max`. If it reads `max` the
memory cap is **not enforced** and the protection is illusory.
*Linux baseline:* enforced exactly — `memory.max` = 1073741824 for `--memory=1024m`.

### §6.1 / §6.2 / §6.3 — sleep, wake and clock drift (macOS, Windows)
Sleep the laptop for hours — ideally two days — then:
```sh
./cs193v                                              # must give a status in seconds, not hang
echo "host=$(date +%s) container=$(podman exec cs193v date +%s)"
```
*Expect:* a clear status within seconds; `podman info` is known to hang rather than fail
after a Mac wakes (`podman#21675`). Clocks within a couple of seconds; if minutes apart,
confirm `cs193v doctor` detects it and the offered VM restart fixes it. Also record whether
podman **self-corrected** on resume — if it does, the check may be unnecessary.
Then check `gvproxy` CPU: there are reports of ~400% after sleep (`podman#27279`).

**AND THE PORT SUPERVISOR, WHICH THIS IS THE ONLY PLACE TO TEST.** It calls `read -t 5` on the
watcher's stream and treats **six consecutive timeouts** as a fatal protocol violation, on the
reasoning that a timeout is something a *running* process generates — so an hour asleep should
produce at most one, not twelve hundred. That reasoning rests on an assumption about bash that
only a real sleeping laptop can settle, and a Mac is the case that matters because the podman
machine VM's resume behaviour is the variable:

```sh
podman exec cs193v cs193v-portwatch --show    # must work, not report a dead supervisor
./cs193v doctor | grep dynamic                # must not say "not running"
podman exec -d cs193v python3 -m http.server 21500 --bind 127.0.0.1; sleep 5
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:21500/    # expect 200
```
*Expect:* no spurious `no-frames` state after the wake, and a port bound after it still becomes
reachable. If it did fire, the supervisor's log (`cs193v --dev-tunnel` names it as `suplog`) says
so, and the threshold in `TUNNEL_SUP_SILENCE_MAX` is what needs raising.

Separately, and it is the underlying question rather than a symptom: block a `read -t 30` on an
empty fifo across a real lid close and record whether it fires on wake.
```sh
mkfifo /tmp/f; exec 3<>/tmp/f
time read -t 30 -u 3     # sleep the laptop NOW, wake it after an hour
```
*Expect, if the assumption holds:* it is still waiting on wake, or has just timed out once —
**not** that it timed out an hour ago. That settles whether bash's `read -t` charges suspended
time, which is what the six-timeout threshold rests on.

*Automated:* that every probe is timeout-wrapped and a hanging podman returns in ~14s with a
"not responding" message rather than looking frozen (`30-launcher-shim.sh :: hang:*`).

### §7.8 — terminal variety
Repeat §7.2, §7.3 and the colour check under macOS Terminal.app, iTerm2, Windows Terminal
and GNOME Terminal.
*Automated:* `TERM` whitelisting for kitty/ghostty/alacritty/wezterm/foot, and that a
forwarded `TERM` yields 256 colours where the bare `podman exec` yields 8.

### §7.9 — the tab keys, per terminal
**This is the one thing about the multiplexer that automation cannot settle**, because it is
a property of the student's terminal, not of the container. `65-tmux.sh` proves the
container *responds* to each key by injecting the bytes directly; it cannot prove the
terminal *sends* them.

In each of macOS Terminal.app, iTerm2, VS Code's terminal, Windows Terminal, GNOME
Terminal/Ptyxis:

| | Expect |
|---|---|
| `CTRL+T` | new tab. A plain control byte — should work everywhere, no exceptions |
| `SHIFT+LEFT` / `SHIFT+RIGHT` | switch tabs. Needs the terminal to send `CSI 1;2D`/`1;2C` rather than a bare arrow |
| click `+ NEW TAB` | new tab |
| click a tab | switches to it |
| `ALT+T`, `ALT+LEFT/RIGHT` | work only where Option/Alt sends Meta — see below |

**ALT is expected to fail on macOS out of the box**, and that is why it is not the only
key for anything. Terminal.app composes Option (Option+T types `†`) unless "Use Option as
Meta key" is ticked per profile; iTerm2 defaults left Option to Normal; VS Code needs
`terminal.integrated.macOptionIsMeta`; Ghostty, WezTerm and Alacritty all compose by
default. Record which of these still hold — the list was compiled from documentation, not
from hardware.

If `SHIFT+arrow` turns out not to be transmitted somewhere, that terminal is degraded but
not broken: `CTRL+T` still opens tabs and clicking still switches them. Note it here rather
than treating it as a release blocker.

### §7.10 — SHIFT+drag, per terminal (#61)
**This one cannot be automated even in principle**, and the reason is the mechanism itself: holding
Shift makes the terminal suppress mouse reporting and select the glyphs it has already drawn, so
nothing reaches tmux and there are no bytes for `65-tmux.sh` to inject. Its absence from the suite is
the feature working. What the suite *can* prove, and does, is the other half: no tmux gesture copies
anything and no clipboard sequence is ever emitted (`tmux-harness/clipprobe.py`).

Selection is the terminal's job because tmux can only reach a clipboard through OSC 52, and a
terminal is free not to implement it. **The machine this course is developed on does not** — measured
by hand, no container involved:

```sh
printf '\033]52;c;%s\a' "$(printf CLIPTEST | base64)"   # then check the clipboard
```

In each of macOS Terminal.app, iTerm2, VS Code's terminal, Windows Terminal, GNOME
Terminal/Ptyxis:

| | Expect |
|---|---|
| plain drag in the pane | nothing is selected, and the amber hint names SHIFT+drag |
| `SHIFT`+drag | the terminal's own selection appears |
| ...then that terminal's copy key (`CTRL+SHIFT+C`, `⌘C`) | the text pastes into another app |
| wheel back, then `SHIFT`+drag | selects the scrolled-back text on screen — **the gesture the whole design rests on** |
| plain drag inside `claude`, and inside `nano` | reaches the app; no hint appears |
| the `printf` above | record whether this terminal implements OSC 52 at all |

**The modifier is the risk, and it is a real one.** The hint says `SHIFT`, which is what xterm, VTE,
kitty, Alacritty, WezTerm and Ghostty use to bypass mouse reporting — but `Fn` and `Option` are both
used in the wild, and this list was compiled from documentation rather than from hardware. If any
mainstream terminal needs a different modifier, that is not a degraded case to note and move on
from: the hint is now the *primary* instruction for copying text, so either `@copy-hint` in
`files/tmux/tmux.conf` or the student paragraph in `CONTAINER-DESIGN.md` has to carry the exception.

Also worth recording per terminal: a selection made by the terminal returns a soft-wrapped line
**with** a newline at the wrap, because the terminal copies what it drew. tmux's own copy used to
return one unbroken line. Nothing can be done about that from inside the container.

### §7.11 — Claude Code scrolls itself, and does not claim a copy it cannot deliver (#77)

The only part of #77 that cannot be automated, and it needs a **logged-in** session: everything
before Claude Code's REPL — sign-in, and the "Accessing workspace:" trust prompt — renders on the
main screen no matter which renderer is configured, so a probe run against a fresh container
measures the wrong thing. That confound cost two false readings while #77 was being diagnosed.

`./cs193v`, then in a tab: `claude`, `/login` if needed, and ask it for 100 lines of output.

| | Expect |
|---|---|
| the wheel, over Claude Code | **Claude Code's** conversation scrolls |
| the amber "SCROLLED BACK" banner | never appears while Claude Code is in front |
| Claude Code's own drawing | fills the pane, not a third of it |
| a plain drag inside Claude Code | selects nothing, and **no "copied … to tmux buffer" toast** |
| `SHIFT`+drag inside Claude Code | the terminal's own selection, exactly as at a shell prompt |
| clicking a link or a button inside Claude Code | still works — only motion reporting is off |
| resize the window mid-session | no flicker, no stale layout |

The toast is the one to watch for. `copyOnSelect` defaults to **true** in the fullscreen renderer
and writes over OSC 52; measured, the message reads *"copied N chars to tmux buffer · paste with
&lt;prefix&gt;p"*, and this configuration has no prefix key. `CLAUDE_CODE_DISABLE_MOUSE_CLICKS=1` in the
Containerfile is what suppresses it. **If that toast ever comes back, the variable has stopped
being honoured** — it is internal and undocumented, Claude Code auto-updates in this image, and
nothing in the automated tiers can see it (there is no non-interactive readout of the renderer or
the mouse mode: `claude config` is not a subcommand and `claude doctor` reports installation health
only).

Then the same wheel test with `codex`, where the expectation is the **opposite** and that is not a
bug: tmux scrolls, the banner does appear, and codex uses part of the pane. Its TUI is inline by
design at 0.148 — measured, `tui.alternate_screen` governs only the transcript overlay — so its
output really is in the 50,000-line scrollback and copy mode is the right way to read it.

**Known, filed separately as #83:** `CTRL+T` is bound to "new tab", so Codex's own *"ctrl + t to
view transcript"* never reaches it. Do not report that as a failure of this section.

*Linux baseline (Ubuntu 26.04 native, rootless podman 5.7.0):* **every row above passes.** Two of
them were the reasons to doubt this change at all and are the ones to watch on another platform:
no flicker, which was the open question about running an alt-screen renderer under this tmux, and
no "copied … to tmux buffer" toast, which is the entire job of
`CLAUDE_CODE_DISABLE_MOUSE_CLICKS=1`.

**The wheel row is why this section exists**, because it is the one part of #77 that no test
reaches. `alt=1 mouse=1` off the shipped image proves tmux *forwards* the event and stops there;
"…and Claude Code then scrolls its own transcript" has no automated equivalent, so it has to be
re-checked by a person after a Claude Code update — and Claude Code auto-updates in this image.
Codex's opposite behaviour, described just above, is measured rather than merely expected: on a
live logged-in session its pane reports `alt=0 mouse=0` and it draws 14 rows of 34.

### §9.3 — WSL teardown
`wsl --unregister CS193V`
*Expect:* removes the distro without touching any other. Confirm a pre-existing distro
still works.
