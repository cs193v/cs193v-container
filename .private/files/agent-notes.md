<!-- The one copy of the course notes. /etc/claude-code/CLAUDE.md is a symlink to this file,
     and the entrypoint links ~/.codex/AGENTS.md at it, so Claude Code and Codex read the same
     text. Keep it tool-agnostic: anything true of only one of them is read by both anyway. -->

## Ports — read this before starting any server

Any port works. Start a server on whatever port you like and it becomes reachable from the
student's browser about a second later — nothing has to be declared, reserved or restarted.

**The bind address is what matters, and it is the one thing that can go wrong.** The student's
localhost is SSH forwarded to this container's localhost over IPv4, so:

- `127.0.0.1` — works.
- `0.0.0.0` — works.
- `::1` — does **not** work. Forwarding is IPv4, so an IPv6-only listener is unreachable.
- another loopback address such as `127.0.0.53` — does not work either. The far end is
  `127.0.0.1` specifically.
- the container's eth0 address — does not work. Bind loopback or the wildcard instead.

**`cs193v-portwatch --show` answers "is my port reachable, and if not why"** from in here, which
is the first thing to run when the student says their browser cannot get to their server. It
lists each port with either `up` or the reason it was refused. `ss -ltn` shows what is actually
listening and at which address; `lsof -i` names the process holding a port. All are installed;
do not install network tools.

If `--show` says a port is `busy`, another program on the student's own computer is holding that
number — pick a different one, or have them quit it. For anything `--show` cannot explain, the
student runs `./cs193v doctor` on their own computer, not in this container.

## Browser tests

Playwright and the Chromium headless shell are already installed in this image. When a
project needs browser tests, run `playwright --version` and add `@playwright/test` at
exactly that version. Any other version pins a different Chromium build and downloads it on
first run (about 114 MB), which works but is slow and is not what the image was built for.

- Do not run `playwright install` for that version. The browser is already here.
- Headless only. There is no display and only the headless shell is installed, so
  `headless: false` and `channel: 'chromium'` will not work.
- A spec and the dev server it drives both run inside this container, so a test reaches its
  server directly and none of the bind-address rules above apply to it. A test hitting
  `http://localhost:9999`, or `http://[::1]:9999`, is fine.

## Nothing here outlives the terminal

This container is stopped when the student closes their terminal window, and everything running
in it stops with it. There is no way around this from inside — `nohup`, `setsid` and
backgrounding all die with the container.

So never tell the student to leave a server running and come back to it later, and never treat a
long-running process as something that will still be there next session. If work needs to
survive, it has to be a file in `~/projects` (which is on their own computer) rather than a
running process.

## Credentials

Never read or print the contents of these, and never copy a token into a file, into a commit,
or into your own output:

- `~/.claude/.credentials.json`
- `~/.codex/auth.json`
- `~/.config/gh/`
- `~/.local/share/com.vercel.cli/`

If a task seems to need a token, stop and ask the student to run the login command the tool
owning it provides. Some of these are denied outright rather than merely discouraged, and that
denial is expected — it is not a problem to work around.

## Miscellaneous

- `sudo` works without a password.
