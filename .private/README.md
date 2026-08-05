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
    ports                      the in-container port diagnostic
    open-url                   the $BROWSER stub
    am-i-in-a-container         the milestone check the install guides reference
    rewrite-window-title.py    points the terminal's title at the course
    nanorc
    bash_logout                the goodbye on exit
    profile.d/                 stty -ixon, and the entry banner
    claude-code/               managed-settings.json + CLAUDE.md
  messages.txt                 all student-facing launcher strings (script config, not reading)
  install-cs193v.sh            macOS / Ubuntu / WSL setup
  install-cs193v-windows.cmd   Windows stage one, then hands off to the above
  CONTAINER-DESIGN.md          threat model, ports lesson, rough edges — publish this
  VERIFICATION.md              release gates — hand to a Claude Code instance per platform
  ERRORS.md                    what the first verification pass found, and what is still open
  tests/                       the regression suite
.github/workflows/build.yml    multi-arch build + push + smoke test
```

Note `CONTAINER-DESIGN.md` is course *reading* but lives in `.private/` — publish it on the
course website rather than expecting students to find it in a hidden directory.

## Before this works

Four things need real values:

1. **`install-cs193v.sh`** — set `REPO_OWNER` (and `REPO_NAME` if you rename it).
2. **`.config/container.args`** — the `IMAGE=` line is empty. Fill it with the **manifest-list**
   digest the CI run prints, not a per-architecture digest. Until then the launcher runs
   in dev mode against a locally built image and says so.
3. **`.github/workflows/build.yml`** — pin `vercel_version` and `claude_code_version`
   rather than leaving them at `latest`, or the digest pin does not mean what it claims.
4. **The course website** — host `install-cs193v.sh` and `install-cs193v-windows.cmd`
   with their SHA-256 published next to the links.

## Your development loop

```
./cs193v --dev-build              # build localhost/cs193v:dev, recreate, drop into a shell
./cs193v --dev-build --no-cache   # prove the network fetches still work
./cs193v --dev-print-command      # see the exact podman run line
./cs193v --rebuild                # fresh container; logins kept
./cs193v --full-rebuild           # test the cold-start path a student sees
```

`--dev-build` needs no registry and no published image, so all of this works before
anything is pushed.

## Shipping a fix mid-quarter

1. Edit the `Containerfile`; push to `main`. CI builds both architectures and prints the
   digest to pin.
2. Put that digest in `.config/container.args`; commit.
3. Students run `./cs193v --update`. Anyone who doesn't gets prompted on their next
   launch, because the launcher compares the running container's image against the pin.

Rollback is `git revert` on the `IMAGE=` line. CI also tags every build with a dated,
immutable tag, so you always have a known-good one to point at.

## Before students arrive

**§A is now a test suite.** Run it rather than pasting shell:

```
.private/tests/run-tests.sh                  # every automatable check
.private/tests/run-tests.sh --tier static    # no podman or image needed — milliseconds
.private/tests/run-tests.sh --release        # the publishing blanks; fails until filled
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

- does closing a terminal window kill a foreground server? — **No.** All five shapes
  survive and stay reachable, exactly as conmon's source suggested. Both the design doc and
  the managed `CLAUDE.md` currently warn otherwise; confirm on macOS and WSL before
  rewording, since the exec client lives outside the VM there.
- does `systemd=true` in WSL deliver cgroup delegation? — **still open**, but on native
  Linux the cap is enforced exactly (`memory.max` == `--memory`), an OOM is clean at exit
  137, and the container survives it.
- does host-side `inotify` fire? — **Yes on Linux**, as predicted. Expect not on macOS/WSL.
- is a loopback-bound server reachable from the host? — **No**, so the course's central
  ports lesson holds. All 46 published ports work; unpublished ones are refused.
- does `podman start` really ignore new flags? — **Yes**, so the `cs193v.confighash`
  machinery is load-bearing rather than defensive.

Still needing other hardware: libkrun vs applehv on Apple Silicon, whether podman 6 runs on
an Intel Mac, and WSL's `--name` support.

## Deliberately not here

So it isn't re-proposed: a persistent border or status bar around the terminal (needs a pty
multiplexer; the one portable escape-sequence route, a `DECSTBM` scroll region, was measured
against real VTE and **discards scrollback** — 40 lines in, 10 retained); changing the
terminal's background colour (Ptyxis, the Ubuntu 26.04 default, accepts `OSC 11`, reports
success on query, and renders nothing — and macOS Terminal.app ignores it, so it would be
invisible on two of three platforms' default terminals and undetectable on one); puppeteer
and Chrome; `--cap-drop` / `no-new-privileges`
(mutually exclusive with the sudo decision, and they would buy nothing since root owns
the tamper targets); a `serve` wrapper or tmux; ripgrep/fzf/bat/fd/delta; man pages;
terminal image viewers; egress filtering; `/etc/gitconfig`; a `cs193v install` verb;
`podman diff` tamper detection; a VS Code-style port relay.

Each rejection is documented where it would otherwise be tempting — the invariants block
in `.config/container.args`, and the comments in the `Containerfile`.

## One open item

Enforcing the bind-`0.0.0.0` rule is deferred by decision. The gap, recorded so it isn't
forgotten: **vite reads no `HOST` environment variable at all** (verified against vite
8.1.5 — `server.host` defaults to `localhost` and is settable only by config or
`--host`), and **Next.js reads `HOSTNAME`, not `HOST`**. So `ENV HOST=0.0.0.0` covers
`react-scripts` and little else, while vite owns two of the six published ranges. The
managed `CLAUDE.md` rule and `ports` are doing the real work today.
