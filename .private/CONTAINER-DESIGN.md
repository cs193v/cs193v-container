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

You get a shell with node, python, git, the GitHub CLI, the Vercel CLI, Claude Code, Codex and
Playwright with a headless Chromium installed, inside a tabbed terminal that tells you where
you are. You can run `./cs193v` in as many terminal windows as you like; each gets its own
set of tabs in the **same** container. There is only ever one container.

Everything about how it starts is in two plain text files you can read, in the `.config`
folder next to the launcher: `container.args` holds every flag, heavily commented, and
`local.args` holds the one value that depends on your particular machine. They are tucked
out of the way so your course folder stays uncluttered, not to hide them. To see exactly
what runs:

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

**Your work is safe.** `--rebuild`, even with `--logout`, never touches it, because it
lives on your computer, not inside the container. You can throw the container away as
often as you like.

**Your work is exposed.** Everything in `projects/` is readable and writable by anything
running in the container — including code an agent wrote and ran. So:

- Keep personal API keys out of `projects/`. Use throwaway or scoped keys for coursework.
- An agent working on one project **can read every other project** in `projects/`,
  including its `.env` files. This is a real consequence of using one container for
  everything, and it was chosen knowingly: separate containers per project cannot share
  the forwarded port range, and they would still share your logins — so it would protect
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

  One clarification, since the port forwarding uses ssh: that tunnel has its own dedicated
  key, generated on your computer for this purpose alone, and **your** keys are not involved
  and never enter the container. The direction is also the opposite of what would be
  dangerous — your computer connects *in*, and the container is configured to refuse the
  reverse. Nothing in the container can ask your computer to open a port or connect anywhere
  on its behalf.

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

### The bind address does not matter. The port does.

A server does not listen on a *port*. It listens on an **(address, port) pair**, and the
address decides which network interfaces it will accept connections on:

| Bind address | Meaning |
| --- | --- |
| `127.0.0.1` (`localhost`) | only this machine can connect |
| `0.0.0.0` | any interface — anyone who can route here |

`0.0.0.0` is not an address you connect *to*. It is a wildcard meaning "don't restrict
me."

Here is the part worth understanding: **the container is a separate machine from your
browser.** It has its own network stack, its own `lo`, its own `eth0`. The container's
`127.0.0.1` is a completely different loopback interface from your computer's — same name,
unrelated thing.

Two separate machines means something has to carry your browser's connection from one to the
other. That is `cs193v`'s job, and it does it with an **ssh tunnel**:

```
   your browser  ──  http://localhost:3000
        │
   ┌────▼──── YOUR COMPUTER ─────────────────────────┐
   │  127.0.0.1:3000   ◀ only you can connect        │
   │        │                                         │
   │        │  one ssh client, all 46 ports           │
   └────────┼─────────────────────────────────────────┘
            ▼  (not a network connection — see below)
   ┌── THE CONTAINER (its own network stack) ────────┐
   │  sshd connects to the container's OWN loopback   │
   │                                                  │
   │  lo:3000     ◀ the tunnel arrives HERE  ✓        │
   │  eth0:3000   ◀ and 0.0.0.0 covers lo too  ✓      │
   │                                                  │
   │  bound 127.0.0.1  ✓ works                        │
   │  bound 0.0.0.0    ✓ works                        │
   │  bound ::1 only   ✗ refused (see below)          │
   └──────────────────────────────────────────────────┘
```

Because the tunnel's far end is the container's *own loopback*, a server bound to
`127.0.0.1` works. And because `0.0.0.0` includes loopback, one bound that way works too.
**So there is no `--host` flag to remember.** `vite`, `next dev`, `flask run` and
`python3 -m http.server` all work as they come.

What still bites is the **port**. A server on anything outside the six ranges has nothing
carrying it out of the container, and the failure looks identical to a broken app: a
connection refused, **while the server's log cheerfully prints
`Local: http://localhost:5173/`.** That log line is not a lie any more, but it is not a
promise either — it describes a door that only exists inside.

For vite, set `strictPort: true`. Without it a busy port silently walks 5173 → 5174 → 5175,
which can wander out of the forwarded range — and then you get a connection refused with
nothing anywhere explaining why.

### The one address that still doesn't work: `::1`

The tunnel's far end is `127.0.0.1`, which is IPv4. A server bound **only** to `::1`, the
IPv6 loopback, is therefore still refused.

You are unlikely to hit this by accident. In this container `localhost` resolves to
`127.0.0.1` and nothing else — there is no `::1 localhost` line in `/etc/hosts` — so both
`python3 -m http.server --bind localhost` and node's `listen(port, "localhost")` bind IPv4.
Reaching `::1` takes asking for it by name.

### Is my server exposed to the dorm network?

No, and for a structurally better reason than before.

Your computer's end of the tunnel is a listening socket bound to `127.0.0.1` — the ssh
client binds it that way, so "only this machine" is not a flag anyone can forget or a
setting that could drift. It is what the tunnel *is*. Nothing on the network can reach it,
which was verified by trying from this machine's own LAN address and getting nothing.

And the useful lesson survives intact: **the app declares what it serves, the boundary
declares who may reach it.** The genuinely dangerous thing is exposing the *host* side to
the network, which is exactly what most tutorials on the internet will show you.

### When something isn't reachable

There are two halves to this, and they are checked in different places. Start inside the
container, with what your server is actually doing:

```
ss -ltn
```

That lists every port something is listening on, and — the column that matters — the address
each one is bound to. Check it against two things: that the port is one of the forwarded ones
(`echo $CS193V_PORTS`), and that the address is not `::1`, which is the one bind address the
tunnel cannot reach. `127.0.0.1`, `0.0.0.0` and `*` are all fine.

Claude is in here with you and can do this for you — "nothing can reach my dev server, what's
it bound to?" is a reasonable thing to ask it. `lsof -i` is also installed, if what you need
is *which process* has a port rather than what it is bound to.

If your server is listening on a forwarded port at a workable address and your browser still
cannot connect, the problem is on your own computer — most often another program already
holding that port. Nothing inside the container can see that. Run this **there**, not in the
container:

```
cs193v doctor
```

It reports whether the tunnel is up and names any port it could not forward.

If it says the tunnel is down, or things stop working after your computer sleeps:

```
cs193v --reset-tunnel
```

### Why this is an ssh tunnel, and not what came before

VS Code's extension ran a relay **inside** the container, connecting over the container's
own loopback, and watched for new listening sockets to forward automatically. That is why
nobody using it ever had to think about bind addresses.

This is the same idea, deliberately reintroduced, with two of its properties kept and one
dropped:

- **Kept:** a loopback-bound server just works, which is what made the old setup feel easy.
- **Kept:** your computer decides what it opens. The tunnel forwards a fixed list; the
  container is never asked which ports it would like.
- **Dropped:** automatic forwarding of *new* ports. That is the part that required the
  container to tell your computer what to open, and the fixed list is the reason it does
  not.

The earlier design fixed this at the network layer instead, and it is worth recording why
that failed: `podman`'s own `--host-lo-to-ns-lo` option does exactly the right thing on
Linux and is silently inert on macOS, where podman runs inside a virtual machine. That would
have made identical code work on Ubuntu and fail on Macs. The tunnel avoids the whole class
of problem by not touching the network at all — it runs over the same `podman exec` channel
that `cs193v` already uses to give you a shell, which necessarily works everywhere a shell
does.

---

## What survives what

The first row is the one to read carefully, because it is the one people get wrong.
**Closing your terminal window stops the container**, and anything that was running inside it
stops too. Your *files* are never at risk — they live on your own computer — but a dev server,
a `claude` session, an editor with unsaved changes: those go.

| | your files in `projects/` | your logins | things installed in the container | browsers you installed | things you were running | port forwarding |
| --- | --- | --- | --- | --- | --- | --- |
| closing your terminal | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ (back on next `cs193v`) |
| `exit` | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ (back on next `cs193v`) |
| `--rebuild` | ✅ | ✅ | ❌ | ✅ | ❌ | ❌ (back on next `cs193v`) |
| `--rebuild --logout` | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ (back on next `cs193v`) |
| restarting your computer | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ (back on next `cs193v`) |

Note what the first row does **not** say. Things you installed with `sudo` are still there when
you come back, and so are your logins. Closing the window stops the container; it does not throw
it away. Only `--rebuild` does that.

"Browsers you installed" is its own column because Playwright's browsers are the one
package cache kept in a volume. The Chromium the course uses is part of the image, so it is
always there — that column is about an *extra* one you downloaded by asking for a different
Playwright version. `--rebuild --logout` drops it, and the image's own Chromium comes straight
back, so the worst case is one more download and never a broken setup.

`--rebuild` is cheap and safe. It is the right first move when something is behaving
strangely, and staff will suggest it freely.

### Leaving, and coming back

`exit` and closing the window do the same thing, on purpose. There is no third way to leave that
means something different, and nothing keeps running in the background afterwards. When you come
back with `./cs193v` you get the same container — your packages, your logins — and a fresh set of
tabs.

**One window at a time.** Run `cs193v` while a session is already open somewhere and it will tell
you so rather than opening a second one. If you want another place to work, that is what tabs are
for: **CTRL+T**. The same message appears if a previous session ended badly — a force-quit, a
crash, a laptop that lost power — because from the outside those look identical. Either way the fix
is the same:

```
cs193v --stop
```

That stops the container so the next `cs193v` starts cleanly.

The port forwarding column needs a word of explanation. The tunnel is a program running on *your*
computer, not inside the container, so it is a separate thing that can be up or down. It is started
when you open a session with `cs193v`, and taken down whenever the container stops — including when
you close your window, which hands all 46 ports back. Maintenance commands like `cs193v --rebuild`
never raise one: they end with the container stopped, so a tunnel for it could serve nobody. That is deliberate: a tunnel left holding ports for a
container that is gone would stop the *next* one from working, and the symptom ("my browser cannot
reach my server") would point nowhere near the cause.

If you ever suspect it, `cs193v doctor` will tell you, and `cs193v --reset-tunnel` fixes it without
disturbing the container or anything running in it.

**Why it works this way.** The container used to outlive the window, and running `cs193v` again put
you back into the same tabs with the same servers still running. That is genuinely useful, and it
was given up on purpose: it meant a student could have work running that they had no idea was
running, in a container they had forgotten was up, and "closing the window" — the universal gesture
for *I am done* — quietly meant nothing at all. Being able to stop things by closing the window is
worth more than being able to resume them by reopening it.

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

Which is why `--rebuild` matters: it restores the container to exactly the image the
course container was built from. If anything ever feels off, rebuild rather than
investigate.

That property survives the fact that the image is built on your own computer rather than
downloaded. What tampering changes is the container's writable layer, not the image
underneath it — and `--rebuild` throws that layer away and starts a new container from the
image, without rebuilding or re-downloading anything. It takes about two seconds.

**One command not to use: `sudo pip3 install`.** Plain `pip3 install` needs no `sudo` — it writes
your own `~/.local` — and with `sudo` it is refused on purpose, because that would write into the
directory Ubuntu's package manager owns, and the two would then be fighting over the same files.
So if you ever see `error: externally-managed-environment`, the fix is to drop the `sudo`.

For the same reason, the capability set is left at podman's defaults rather than
tightened. Tightening it would look reassuring and achieve nothing: `root` **owns**
`/usr/bin` and `/etc`, so it needs no special permission to modify them. And AppArmor is
not confining this container either — inside it, `/proc/self/attr/current` reads
`crun (unconfined)`, because an unprivileged user cannot load a profile. The protection
is the user namespace. It is worth knowing which of the things that *sound* protective
actually are.

---

## Small things that are true here

- **You always know you are inside.** A title bar across the top of the terminal says
  `CS193V Development Environment` for as long as you are in the container, the window
  title says the same, and the prompt reads `student@cs193v-development`. Entering clears
  the screen and shows a banner; leaving prints a goodbye.

  Getting that permanent title bar took a second attempt. Pinning a header with escape
  sequences alone was tried first and abandoned, because the only portable mechanism for it
  throws away your scrollback — 40 lines of output in, 10 kept. Changing the window's
  background colour was tried too, and does nothing at all on the default terminals of
  Ubuntu and macOS. What works is a terminal multiplexer, which is what the tabs below are
  running on.
- **You get tabs.** The bar under the title shows one block per tab, labelled with whatever
  is running in it — `bash`, `python3`, `claude`, `git commit` — and a count on the left so
  it is obvious when other tabs exist. Click a tab to switch to it, or click `+ NEW TAB` on
  the right for another. `exit` closes a tab; exiting the last one leaves the container and stops
  it.

  With **one** tab open there is nothing to switch between, so the count and the single
  label are hidden and the bar carries only `+ NEW TAB`. Both appear the moment a second
  tab exists and go away again when it closes.

  | | |
  |---|---|
  | New tab | **CTRL+T** — or click `+ NEW TAB` |
  | Previous / next tab | **SHIFT+LEFT** / **SHIFT+RIGHT** — or click the tab |
  | Close a tab | `exit` |

  `ALT+T` and `ALT+LEFT` / `ALT+RIGHT` do the same things, if you prefer them. On a Mac
  they need one setting changed first: macOS terminals treat Option as a way to type
  accented characters, so `ALT+T` produces `†` until you turn that off. In Terminal.app it
  is Settings → Profiles → Keyboard → **Use Option as Meta key**; in iTerm2, Profiles →
  Keys → Left Option Key → **Esc+**. You never have to do this — `CTRL+T` and the arrow
  keys above work everywhere without it.

  **Nothing else is bound.** There is no prefix key, and the several hundred shortcuts a
  terminal multiplexer normally ships with have been removed rather than hidden, so there
  is no combination you can hit by accident that splits the screen, opens a menu, or leaves
  you somewhere you cannot get out of. If you already know tmux: `CTRL+B` does nothing here,
  and is passed through to your shell as an ordinary "move back one character".

  Your scrollback is 50,000 lines per tab and belongs to the container, not to your terminal
  — so it survives switching tabs and coming back.

  **To copy text, hold SHIFT while you drag**, then copy the way you always do in this
  terminal (`CTRL+SHIFT+C`, or `⌘C` on a Mac). Dragging without SHIFT does nothing on
  purpose: the container cannot reach your computer's clipboard, and holding SHIFT hands the
  selection to your terminal, which can. It works the same way when you have scrolled back,
  because your terminal is selecting what is on the screen in front of you.
- **Closing your terminal window stops everything in it.** A dev server running in a tab stops
  when the window closes, and so does anything else you had going. This is the one thing worth
  knowing that is different from a plain shell: closing the window is not just leaving the room,
  it is turning the lights off. `exit` does exactly the same thing. Your files are untouched
  either way — they are on your own computer, not in the container. See "Leaving, and coming
  back" above.
- **`nano`** is the editor. `git commit` with no `-m` opens it. (Without this it would
  open `vim.tiny`, which is a genuinely bad first experience.)
- **git is completely stock.** There is no `/etc/gitconfig`, so the hints and errors you
  see are the real ones you will meet everywhere else. Your first commit needs
  `git config --global user.name` and `user.email`.
- **Ctrl-S is safe.** Normally it freezes a terminal — it sends an ancient "stop output"
  signal, and the recovery is Ctrl-Q, which nobody knows. That is turned off here.
- **No `man` pages** (the base image strips them). `tldr <command>` instead — and typing
  `man git` tells you so and names the `tldr` page to try, rather than failing obscurely.
- **`claude`, `vercel` and `playwright` are ordinary global npm packages**, installed in your
  own prefix rather than system-wide — so `npm ls -g` lists them, `npm update -g` works, and
  `npm install -g <anything>` needs no `sudo`. Claude Code keeps itself up to date this way.
- **Python has an interpreter and `pip`, and no libraries.** Nothing beyond the standard library
  is preinstalled, and `pip3 install pandas` — or anything else — works with **no `sudo` and no
  flags**. It installs into `~/.local`, your own directory, the same place the npm packages above
  live. Installing pandas, matplotlib and requests together takes about 11 seconds.

  Four things follow from that:

  - Those packages are part of the container, so they survive `exit` and closing the window, but
    **`--rebuild` removes them**, along with everything else you installed. Getting them back
    needs the internet — so if you are about to work offline, install what you need first.
  - `python3 -m venv .venv` works exactly as it does on any other machine, if you would rather
    keep one project's packages to itself.
  - `pipx install <tool>` is the one for Python *programs* rather than libraries. It gives each
    tool its own private set of packages so they cannot break each other, and `tldr` is installed
    that way.
  - A C compiler and Python's own headers are both here, so a package with no prebuilt wheel for
    this Python still builds from source rather than failing.
- **`ssh`, `scp` and `telnet` are here.** Log into a remote machine, copy a file across, or
  talk to a web server by hand — `telnet example.com 80`, then type `GET / HTTP/1.0` and
  press Enter twice, and you see the raw reply. (Press Enter; do not try to type the `\r\n`
  yourself. telnet turns your Enter into the CRLF the protocol wants.)
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
./cs193v doctor             a report to paste when asking staff for help
./cs193v --rebuild          fresh container; files and logins kept. Builds a newer
                            course container first if there is one.
./cs193v --rebuild --logout fresh everything, including logging out
```

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
- **Browser tests are headless, and pinned to one Playwright version.** The container ships
  Playwright with a Chromium headless shell, so `npm test` can drive a real browser with
  nothing to install. Each Playwright release wants its *own* Chromium build, though, so a
  project that asks for a different version prints
  `Executable doesn't exist at …/ms-playwright/chromium_headless_shell-<number>`. That is not
  a broken container: run `npx playwright install chromium` and it downloads the one your
  version wants, once, and keeps it across rebuilds. To avoid the download entirely, run
  `playwright --version` and use that exact version in your project. There is no display in
  here, so `headless: false` cannot work.
- **A laptop that has slept can confuse podman.** On a Mac, commands may hang for a
  moment, and the container's clock can drift — which shows up as secure connections
  being rejected as "not yet valid," and looks exactly like a broken network.
  `./cs193v doctor` detects the clock problem and offers to fix it.
- **If Podman Desktop offers to delete volumes** while updating itself, say **no**. That
  is where your logins live. If it happens anyway, nothing is lost but time: run
  `claude /login` and `gh auth login` again. Your files are never at risk.
