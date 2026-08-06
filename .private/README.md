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
  CONTAINER-DESIGN.md          threat model, ports and the tunnel, rough edges — publish this
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

### Two people on one computer: `CS193V_INSTANCE`

By default every checkout on a machine shares the same container (`cs193v`), the same dev
image (`localhost/cs193v:dev`) and the same four volumes. Two people developing at once
therefore collide, and not cleanly: whoever ran `--dev-build` last owns the container the
other is about to shell into, and either one's `--full-rebuild` deletes the other's logins.

Set `CS193V_INSTANCE` to give yourself an independent set of all of them:

```
export CS193V_INSTANCE=yourname
./cs193v --dev-build              # builds localhost/cs193v:dev-yourname
./cs193v doctor                   # reports container cs193v-yourname
```

It suffixes the container name, the dev image tag and all four volume names together —
partial suffixing would be worse than none, since `--full-rebuild` would still cross
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
forwards and what `ports` expects. This only works because there are no `-p` lines left:
`local.args` is *appended*, so a second set of `-p` flags used to add mappings rather than
replace them, and moving ports this way was impossible.

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

**No longer on this list: a VS Code-style port relay.** It was rejected, and that decision
was reversed deliberately — see the ports chapter of `CONTAINER-DESIGN.md`. Two of the three
original objections were addressed rather than overruled: the container is never asked which
ports to open (the forward list is fixed and comes from `CS193V_PORTS`), and the relay is one
ssh process rather than a supervised fleet. The third objection — that it hides the
bind-address distinction — was accepted as true and judged worth the cost.

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
