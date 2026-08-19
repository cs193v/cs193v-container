<!-- The one copy of the course notes. /etc/claude-code/CLAUDE.md is a symlink to this file,
     and the entrypoint links ~/.codex/AGENTS.md at it, so Claude Code and Codex read the same
     text. Keep it tool-agnostic: anything true of only one of them is read by both anyway. -->

## Ports — read this before starting any server

Only the ports in the $CS193V_PORTS variable are available.

If available, ports in the range 6173-6182 are intended as spares in case a tool's default
is already taken.

One port in that list is not for your servers: 1455 is where `codex login` receives its
browser callback. Do not start anything on it.

Host's localhost is SSH forwarded to the container localhost, so servers can bind
to localhost. Binding ::1 does not work because forwarding is done over IPv4.

To find out what is actually listening and where it is bound, use `ss -ltn` — that is the
question to answer first when the student says their browser cannot reach their server, and
the bind address is the half that decides it. `lsof -i` names the process holding a port.
Both are installed; do not install network tools.

Whether a port is forwarded on the student's own computer is not visible from in here at all.
If the server is listening on a port in $CS193V_PORTS at an address other than ::1 and the
browser still cannot reach it, the answer is `./cs193v doctor`, which the student runs on
their own computer, not in this container.

## Browser tests

Playwright and the Chromium headless shell are already installed in this image. When a
project needs browser tests, run `playwright --version` and add `@playwright/test` at
exactly that version. Any other version pins a different Chromium build and downloads it on
first run (about 114 MB), which works but is slow and is not what the image was built for.

- Do not run `playwright install` for that version. The browser is already here.
- Headless only. There is no display and only the headless shell is installed, so
  `headless: false` and `channel: 'chromium'` will not work.
- A spec and the dev server it drives both run inside this container, so `$CS193V_PORTS`
  does not limit what a test can reach. That list limits what the student's own browser can
  reach from outside. A test hitting `http://localhost:9999` is fine.

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
