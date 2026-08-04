# You are running inside the CS193V course container

This file is course-provided. It describes the environment you are in, and a few rules
that are easy to get wrong here in ways that are invisible until a student is stuck.

## Where things are

- **`/workspaces`** is the only directory shared with the student's own computer. It is
  their `projects/` folder, bind-mounted. Everything a student wants to keep goes here.
- Everything outside `/workspaces` lives only inside the container. It survives `stop`
  and `start`, but is **destroyed** by `cs193v --rebuild`, which recreates the container
  from the course image.
- `~/.claude`, `~/.config/gh` and the Vercel config directory are persistent volumes, so
  logins survive a rebuild. Nothing else in the home directory does.
- The student creates their own project directories under `/workspaces`. There is no
  pre-existing structure to conform to.

## Ports — read this before starting any server

Only these ports reach the student's browser. They are fixed when the container is
created and **cannot be added to a running container**:

```
3000-3009    4173-4176    5173-5179    6173-6182    8000-8009    8080-8084
```

`6173-6182` is the spare block — use it when a tool's usual port is taken.

**Every server must bind `0.0.0.0`, never `localhost` or `127.0.0.1`.**

This container is a separate machine from the student's browser. `127.0.0.1` means "only
this machine", which excludes their browser. The host's port forwarder delivers to the
container's `eth0`, never its loopback — so a loopback-bound server is refused, while its
log still prints `Local: http://localhost:5173/`. **That log line is a lie**, and it is
the single most common way to waste a student's afternoon.

The host side is separately pinned to `127.0.0.1`, so binding `0.0.0.0` inside does not
expose anything to the network. Both are needed; they are opposite ends of one pipe.

Concretely:

```
vite --host 0.0.0.0            # vite reads NO host env var; the flag is required
next dev -H 0.0.0.0
python3 -m http.server --bind 0.0.0.0
flask run --host=0.0.0.0
uvicorn --host 0.0.0.0
```

For vite, also set `strictPort: true` in the config. Without it a busy port silently
walks 5173 → 5174 → 5175 and can wander out of the published range, which produces a
connection refused with nothing anywhere explaining why.

**If a server is not reachable, run `ports`.** It reads the kernel's socket table and
names the specific problem — bound to the wrong address, or listening outside the
published set — rather than leaving anyone to guess.

## Long-running servers

Closing a terminal window may stop a server started in it. Tell the student to keep the
window open while a server should be running, and use a second window for other work —
`cs193v` can be run in as many windows as they like, and they all attach to this same
container.

If you background a server yourself, prefer your own background-execution mechanism over
a bare `&`, so you can still read its output on a later turn.

## What this container does and does not protect

Worth being accurate about, because the course is partly about this:

- The student's files **outside** `projects/`, their host system, and their SSH and GPG
  keys are not reachable from here. No agent forwarding is configured.
- Anything in `/workspaces` **is** reachable and writable, by design.
- Network access is **unrestricted**. The stored Claude, GitHub and Vercel tokens can be
  sent anywhere by any code that runs here. The container does not contain that risk.
- `sudo` works without a password. That is deliberate, so system packages can be
  installed from inside rather than on the student's own machine. It also means changes
  you make to `/usr` or `/etc` persist until the next `cs193v --rebuild`.

## Small things that are true here

- `nano` is the editor (`EDITOR`, `VISUAL`). `git commit` with no `-m` opens it.
- There is **no** `/etc/gitconfig`: git is completely stock, so its hints and errors are
  the real ones. A student's first commit needs `git config --global user.name` and
  `user.email`; that is expected and documented.
- `man` pages are not installed. `tldr <command>` is available instead.
- There is no browser. Anything needing one prints the URL for the student to copy.
- No `ripgrep`, `fzf`, `bat`, `fd` or `delta` — use `grep`, `find` and `git diff`.
- Puppeteer and Chrome are **not** installed.
