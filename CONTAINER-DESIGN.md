# The CS193V container: what it is, what it protects, and what it doesn't

This is course reading, not just documentation. A large part of what CS193V is about is
being able to reason accurately about the tools you are pointing at your own machine —
so this file tries to be precise, including where the news is bad.

---

## What it is

One command starts a Linux container on your computer:

```
cd ~/cs193v
./cs193v
```

You get a shell with node, python, git, the GitHub CLI, the Vercel CLI and Claude Code
installed. You can run `./cs193v` in as many terminal windows as you like; they all open
a shell in the **same** container. There is only ever one container.

Everything about how it starts is in two plain text files you can read: `container.args`
holds every flag, heavily commented, and `local.args` holds the one value that depends on
your particular machine. To see exactly what runs:

```
./cs193v --dev-print-command
```

That transparency is deliberate. The setup this replaced used VS Code's Dev Containers
extension, which passed a large, undocumented set of flags to podman on your behalf.

---

## The one shared folder

`~/cs193v/projects` on your computer is the same directory as `~/projects` inside the
container. It is the **only** thing shared between them.

That has two consequences, and they are equally important:

**Your work is safe.** `--rebuild` and even `--full-rebuild` never touch it, because it
lives on your computer, not inside the container. You can throw the container away as
often as you like.

**Your work is exposed.** Everything in `projects/` is readable and writable by anything
running in the container — including code an agent wrote and ran. So:

- Keep personal API keys out of `projects/`. Use throwaway or scoped keys for coursework.
- An agent working on one project **can read every other project** in `projects/`,
  including its `.env` files. This is a real consequence of using one container for
  everything, and it was chosen knowingly: separate containers per project cannot share
  the published port range, and they would still share your logins — so it would protect
  the cheaper secrets while leaving the valuable ones reachable anyway.

Worth separating two different harms. An agent **reading** another project's secrets is
irreducible here. An agent **corrupting** another project's code is recoverable, because
every project should be a git repository you push.

---

## What the container protects, and what it does not

Honest version, because a vague one is worse than none.

### Protected

- **Files outside `projects/`.** Your documents, photos, other code, your home directory
  — none of it is reachable. The container can only see what is mounted, and only
  `projects/` is mounted.
- **Your host system and installed software.** Nothing installed inside the container
  touches your real machine. This is the main reason the container exists: an agent that
  installs a compromised npm package compromises a container you can throw away.
- **Your SSH and GPG keys.** No agent forwarding is configured. The setup this replaced
  relayed both by default, which meant anything in the container could silently
  authenticate as you anywhere those keys are registered, and obtain signatures from your
  GPG key without a prompt. That is now simply gone.

The mechanism, briefly: podman runs **rootless**, so the container lives in a Linux user
namespace. Inside it, `root` is mapped to an unprivileged throwaway ID on your real
system that owns nothing and can do nothing. That mapping — not any list of permissions —
is what keeps the container off your machine.

### Not protected

- **Anything in `projects/`.** By design; see above.
- **Your Claude, GitHub and Vercel tokens.** They live in the container so you do not
  have to log in constantly, and **code running in the container can send them
  anywhere.** Network access is unrestricted, which it must be — agents fetch web pages,
  npm downloads packages, your projects call APIs. Once arbitrary HTTPS is allowed, a
  token can leave as a query parameter or a request body. **No allowlist can prevent
  this**, and any design that appears to would only be earning trust it hasn't got.
- **Other machines on your network.** Container code can reach your router, printer, and
  anything else on the same wifi.

So: the container protects your *computer*. It does not protect your *accounts*. Those
are different claims and it is worth keeping them separate in your head.

---

## Ports, and the one thing that will bite you

This is the part most worth understanding, because it is the difference between a
five-second fix and a lost afternoon.

### Only these ports reach your browser

```
3000-3009    4173-4176    5173-5179    6173-6182    8000-8009    8080-8084
```

Easy to remember as "the 173 family": **4173** vite preview, **5173** vite dev, **6173**
spare. A server on any other port is unreachable, full stop. Podman cannot add a port to
a container that is already running, so this set is fixed when the container is created.

### Your server must bind `0.0.0.0`, not `localhost`

A server does not listen on a *port*. It listens on an **(address, port) pair**, and the
address decides which network interfaces it will accept connections on:

| Bind address | Meaning |
| --- | --- |
| `127.0.0.1` (`localhost`) | only this machine can connect |
| `0.0.0.0` | any interface — anyone who can route here |

`0.0.0.0` is not an address you connect *to*. It is a wildcard meaning "don't restrict
me."

Now the part that matters: **the container is a separate machine from your browser.** It
has its own network stack, its own `lo`, its own `eth0`. The container's `127.0.0.1` is a
completely different loopback interface from your computer's — same name, unrelated
thing.

So when you publish a port, the forwarding path is:

```
   your browser  ──  http://localhost:3000
        │
   ┌────▼──── YOUR COMPUTER ──────────────────┐
   │  127.0.0.1:3000   ◀ only you can connect │
   │        │                                  │
   │        │  podman's port forwarder         │
   └────────┼──────────────────────────────────┘
            ▼
   ┌── THE CONTAINER (its own network stack) ──┐
   │  eth0:3000   ◀ the forwarder arrives HERE │
   │  lo:3000     ◀ ...never here              │
   │                                            │
   │  bound 0.0.0.0    → both  ✓ works          │
   │  bound 127.0.0.1  → lo only ✗ refused      │
   └────────────────────────────────────────────┘
```

A server bound to the container's `127.0.0.1` is listening at a door the forwarder never
knocks on. Your browser gets a connection refused — **while the server's log cheerfully
prints `Local: http://localhost:5173/`.** That log line is a lie, not a hint: it means
*its own* localhost, which nothing outside the container can ever reach.

So:

```
vite --host 0.0.0.0                  # vite reads NO host environment variable
next dev -H 0.0.0.0
python3 -m http.server --bind 0.0.0.0
flask run --host=0.0.0.0
uvicorn --host 0.0.0.0
```

For vite, also set `strictPort: true`. Without it, a busy port silently walks
5173 → 5174 → 5175, which can wander out of the published range — and then you get a
connection refused with nothing anywhere explaining why.

### Doesn't `0.0.0.0` expose my server to the world?

No, and the reason is worth following, because it is where two ideas people usually
conflate come apart.

There are **two addresses** in a published port, at opposite ends of the same pipe:

- On **your computer**, the host side is pinned to `127.0.0.1`. That is what stops the
  dorm network from reaching your server.
- Inside **the container**, the server binds `0.0.0.0`. That is what lets the forwarder
  deliver to it.

The "only this machine" guarantee is not lost; it moves to the boundary that actually
faces the network, instead of living in your application. Which is a better place for it,
and a decent lesson: **the app declares what it serves, the boundary declares who may
reach it.** The genuinely dangerous combination is `0.0.0.0` on the *host* side — which
is exactly what most tutorials on the internet will show you.

### When something isn't reachable

```
ports
```

It reads the kernel's own socket table, works out what each server is bound to, compares
that against the published set, and tells you the specific problem. Both of the failure
modes above are otherwise completely invisible from inside the container.

### Why the old setup didn't have this problem

VS Code's extension ran a relay **inside** the container, connecting over the container's
own loopback — so a `127.0.0.1`-bound server worked. It also watched for new listening
sockets and forwarded them automatically, which is why nobody ever had to think about it.

That is genuinely nicer, and it was considered. Reproducing it needs a background process
running on your computer for the whole session, and it re-introduces a channel where the
container tells your computer which ports to open. It also hides the distinction above,
which is worth learning. So it is deliberately not here.

---

## What survives what

| | your files in `projects/` | your logins | things installed in the container |
| --- | --- | --- | --- |
| closing your terminal | ✅ | ✅ | ✅ |
| `--rebuild` | ✅ | ✅ | ❌ |
| `--update` | ✅ | ✅ | ❌ |
| `--full-rebuild` | ✅ | ❌ | ❌ |

`--rebuild` is cheap and safe. It is the right first move when something is behaving
strangely, and staff will suggest it freely.

One caveat about long-running servers, with the honest state of knowledge attached.
**On Linux, closing a terminal window does not stop a server you started in it** — this was
measured, and a server left running in the foreground survives and stays reachable, though
its output goes nowhere. On **macOS and Windows this has not been confirmed**: the piece of
podman that your terminal talks to lives outside the virtual machine there, so the answer
may differ.

Until that is checked, the safe habit is the simple one: keep the window open while a server
should be running, and use a second window for other work. You can run `cs193v` in as many
windows as you like.

---

## `sudo` works, and what that costs

`sudo` needs no password inside the container. That is deliberate: the course would
rather you install a system package *inside* the container than on your own machine, so
you need to be able to.

Being honest about the cost. `sudo` cannot touch your real computer — container `root`
maps to a powerless ID out there. But it does give full control of the container's own
contents, which means code running here can replace `git`, `npm` or `node` with a
tampered version, add a certificate authority, or edit `/etc` — and those changes
**survive** stopping and starting, invisibly, until you rebuild.

The realistic way that happens is not sabotage but **prompt injection**: an agent reads a
web page, a README, or an npm package's docs containing instructions, and it has a shell.
That is not exotic. It is the central hazard of the whole practice this course teaches.

Which is why `--rebuild` matters: it restores the container to exactly the published
image. If anything ever feels off, rebuild rather than investigate.

For the same reason, the capability set is left at podman's defaults rather than
tightened. Tightening it would look reassuring and achieve nothing: `root` **owns**
`/usr/bin` and `/etc`, so it needs no special permission to modify them. And AppArmor is
not confining this container either — inside it, `/proc/self/attr/current` reads
`crun (unconfined)`, because an unprivileged user cannot load a profile. The protection
is the user namespace. It is worth knowing which of the things that *sound* protective
actually are.

---

## Small things that are true here

- **You always know you are inside.** Opening a shell clears the screen and shows a banner,
  the window title says `CS193V Development Environment`, and the prompt reads
  `student@cs193v-development`. Leaving prints a goodbye. A permanent border around the
  terminal was investigated and rejected: the only portable way to pin a header discards
  your scrollback, and changing the window's colours does nothing at all on the default
  terminals of Ubuntu and macOS.
- **`nano`** is the editor. `git commit` with no `-m` opens it. (Without this it would
  open `vim.tiny`, which is a genuinely bad first experience.)
- **git is completely stock.** There is no `/etc/gitconfig`, so the hints and errors you
  see are the real ones you will meet everywhere else. Your first commit needs
  `git config --global user.name` and `user.email`.
- **Ctrl-S is safe.** Normally it freezes a terminal — it sends an ancient "stop output"
  signal, and the recovery is Ctrl-Q, which nobody knows. That is turned off here.
- **No `man` pages** (the base image strips them). `tldr <command>` instead.
- **No browser.** Anything that would open one prints the URL for you to copy.
- **No `ripgrep`, `fzf`, `bat`, `fd` or `delta`.** Use `grep`, `find` and `git diff`.
- **`git diff` shows moved code differently from rewritten code**, which is useful when
  reviewing an agent's work. Turn it on with
  `git config --global diff.colorMoved zebra`.
- **Looking at what the agent built:** `projects/` is a real folder on your computer, so
  open a generated image or HTML file in whatever you normally use. On Windows it is at
  `\\wsl.localhost\CS193V\home\<your-linux-username>\cs193v\projects`.

---

## Commands

```
./cs193v                    open a shell
./cs193v ports              why can't my browser see my server?
./cs193v doctor             a report to paste when asking staff for help
./cs193v --rebuild          fresh container; files and logins kept
./cs193v --full-rebuild     fresh everything, including logging out
./cs193v --update           get the newest course container
```

Inside the container: `ports` and `am-i-in-a-container`.

---

## Known rough edges

Written down rather than discovered.

- **Editing files from your computer while a watcher runs.** If you edit a file in
  `projects/` using an editor on your own machine, a dev server's hot-reload may not
  notice on macOS or Windows. The shared-folder layer there does not deliver change
  notifications into the container. Editing from *inside* the container works — which is
  the normal case in this course.
- **macOS is case-insensitive; Linux and this container are not.** `import './Button'` can
  find `button.tsx` on your Mac and then fail in here, or on a Linux build server. On
  Windows your files live inside the WSL environment on an ext4 filesystem — the
  `\\wsl.localhost\CS193V\...` path mentioned above — so Windows students are
  **case-sensitive too**, and do not have this particular hazard.
- **A laptop that has slept can confuse podman.** On a Mac, commands may hang for a
  moment, and the container's clock can drift — which shows up as secure connections
  being rejected as "not yet valid," and looks exactly like a broken network.
  `./cs193v doctor` detects the clock problem and offers to fix it.
- **If Podman Desktop offers to delete volumes** while updating itself, say **no**. That
  is where your logins live. If it happens anyway, nothing is lost but time: run
  `claude /login` and `gh auth login` again. Your files are never at risk.
