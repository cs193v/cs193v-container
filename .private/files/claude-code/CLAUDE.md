# You are running inside the CS193V course container

This file is course-provided. It describes the environment you are in, and a few rules
that are easy to get wrong here in ways that are invisible until a student is stuck.

## Where things are

- **`~/projects`** (`/home/student/projects`) is the only directory shared with the
  student's own computer. It is
  their `projects/` folder, bind-mounted. Everything a student wants to keep goes here.
- Everything outside `~/projects` lives only inside the container. It survives `stop`
  and `start`, but is **destroyed** by `cs193v --rebuild`, which recreates the container
  from the course image.
- `~/.claude`, `~/.config/gh` and the Vercel config directory are persistent volumes, so
  logins survive a rebuild. Nothing else in the home directory does.
- The student creates their own project directories under `~/projects`. There is no
  pre-existing structure to conform to.

## Ports — read this before starting any server

Only these ports reach the student's browser. The student's own computer forwards each one
into this container, and the set is fixed when the container is created:

```
3000-3009    4173-4176    5173-5179    6173-6182    8000-8009    8080-8084
```

`6173-6182` is the spare block — use it when a tool's usual port is taken.

**The port is what matters. The bind address does not.**

`localhost`, `127.0.0.1` and `0.0.0.0` all work, because the forward's far end is this
container's own loopback, and `0.0.0.0` includes loopback too. So there is no `--host` flag
to remember and no reason to add one.

The one exception, and it is narrow: a server bound **only to `::1`**, the IPv6 loopback, is
still unreachable, because the forward's far end is IPv4. Very little does this by default —
measured in this image, both `python3 -m http.server --bind localhost` and node's
`listen(port, "localhost")` bind `127.0.0.1` — so it takes asking for `::1` explicitly.
Don't.

What *will* break a student's afternoon is the **port**, not the address. A server on
anything outside the ranges above has nothing carrying it out of the container, and the
failure looks identical to a broken app: a connection refused with the server's own log
cheerfully printing `Local: http://localhost:5173/`.

For vite, set `strictPort: true` in the config. Without it a busy port silently walks
5173 → 5174 → 5175 and can wander out of the forwarded range, which produces exactly that
unexplained connection refused.

**If a server is not reachable, run `ports`.** It reads the kernel's socket table and names
the specific problem rather than leaving anyone to guess. Note its limit: it runs *inside*
the container, so it cannot see whether the forward exists on the student's own computer. If
it says `OK` and the browser still cannot connect, the problem is out there, and
`cs193v doctor` on the student's own machine is what shows it.

## Long-running servers

On Linux, closing a terminal window does **not** stop a server started in it: this was
measured, and the server survives and stays reachable, though its output is discarded. On
macOS and Windows it is unconfirmed, because the podman client the terminal talks to lives
outside the virtual machine there.

So do not promise the student either way. Suggest they keep the window open while a server
should be running and use a second window for other work — `cs193v` can be run in as many
windows as they like, and they all attach to this same container.

If you background a server yourself, prefer your own background-execution mechanism over
a bare `&`, so you can still read its output on a later turn.

## What this container does and does not protect

Worth being accurate about, because the course is partly about this:

- The student's files **outside** `projects/`, their host system, and their SSH and GPG
  keys are not reachable from here. No agent forwarding is configured. There *is* an sshd
  running here while the port forwarding is up, but it is reachable only from the student's
  own computer, it is configured to refuse remote forwarding, and its key is not theirs — so
  it is not a way back out to their machine.
- Anything in `~/projects` **is** reachable and writable, by design.
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
