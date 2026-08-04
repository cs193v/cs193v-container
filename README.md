# CS193V container — staff README

Scaffolding for the CS193V course container. Students never read this file;
`CONTAINER-DESIGN.md` is the student-facing one.

This repo **is** the `~/cs193v` layout — students unpack it there, so the launcher and
its `projects/` directory are siblings.

```
cs193v                       the launcher (bash 3.2 compatible, one script, all platforms)
container.args               every podman flag, heavily commented
local.args                   machine-specific (memory cap); written by the installer, gitignored
Containerfile                the image
files/                       everything the image installs
  entrypoint.sh              PID 1 — keep-alive + reaps orphans
  ports                      the in-container port diagnostic
  open-url                   the $BROWSER stub
  am-i-in-a-container        the milestone check the install guides reference
  nanorc
  profile.d/                 stty -ixon
  claude-code/               managed-settings.json + CLAUDE.md
install-cs193v.sh            macOS / Ubuntu / WSL setup
install-cs193v-windows.cmd   Windows stage one, then hands off to the above
CONTAINER-DESIGN.md          student-facing: threat model, ports lesson, rough edges
VERIFICATION.md              release gates — hand to a Claude Code instance per platform
messages.txt                 all student-facing launcher strings
.github/workflows/build.yml  multi-arch build + push + smoke test
```

## Before this works

Four things need real values:

1. **`install-cs193v.sh`** — set `REPO_OWNER` (and `REPO_NAME` if you rename it).
2. **`container.args`** — the `IMAGE=` line is empty. Fill it with the **manifest-list**
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
2. Put that digest in `container.args`; commit.
3. Students run `./cs193v --update`. Anyone who doesn't gets prompted on their next
   launch, because the launcher compares the running container's image against the pin.

Rollback is `git revert` on the `IMAGE=` line. CI also tags every build with a dated,
immutable tag, so you always have a known-good one to point at.

## Before students arrive

Work through **`VERIFICATION.md`** on one machine of each platform. Start with **§A**,
which is fully automated and needs no human — hand it to a Claude Code instance on the
target machine and it will run itself.

The reason this matters more than usual: **podman was never executed while this was
designed** (it wasn't installed in the authoring environment). Every runtime claim is
derived from source and issue trackers. §5 lists the questions research genuinely could
not settle, and the answers change either the docs or the design:

- does closing a terminal window kill a foreground server? (`huponexit` is off, and
  conmon's source suggests the server survives with its output discarded)
- does libkrun's enforcing virtiofs break bind mounts where applehv's permissive one
  doesn't? (podman 6 made libkrun the macOS default; there are three open issues)
- does podman 6 run on Intel Macs at all? (the installer currently refuses them)
- does `systemd=true` in WSL actually deliver cgroup delegation, or is `--memory`
  silently unenforced?

## Deliberately not here

So it isn't re-proposed: puppeteer and Chrome; `--cap-drop` / `no-new-privileges`
(mutually exclusive with the sudo decision, and they would buy nothing since root owns
the tamper targets); a `serve` wrapper or tmux; ripgrep/fzf/bat/fd/delta; man pages;
terminal image viewers; egress filtering; `/etc/gitconfig`; a `cs193v install` verb;
`podman diff` tamper detection; a VS Code-style port relay.

Each rejection is documented where it would otherwise be tempting — the invariants block
in `container.args`, and the comments in the `Containerfile`.

## One open item

Enforcing the bind-`0.0.0.0` rule is deferred by decision. The gap, recorded so it isn't
forgotten: **vite reads no `HOST` environment variable at all** (verified against vite
8.1.5 — `server.host` defaults to `localhost` and is settable only by config or
`--host`), and **Next.js reads `HOSTNAME`, not `HOST`**. So `ENV HOST=0.0.0.0` covers
`react-scripts` and little else, while vite owns two of the six published ranges. The
managed `CLAUDE.md` rule and `ports` are doing the real work today.
