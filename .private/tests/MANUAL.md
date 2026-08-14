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
`claude` then `/login`; then `gh auth login`; then `vercel login`.
*Expect:* a URL is **printed** by the `$BROWSER` stub and a device/paste-code flow
completes. No callback port is forwarded, so a redirect-only flow would fail — confirm it
does not need one.
During `gh auth login`, answer **yes** to "Authenticate Git with your GitHub credentials?"
then confirm `git push` works from a test repo.
*Automated:* the stub itself, and that all four credential directories are student-owned
volumes with deny rules (`50-image.sh`).
*ERRORS.md B10 no longer needs settling here.* It asked whether Claude Code's auto-update
works given where the CLI is installed; it does, and the check turned out not to need a
login — see B10, now fixed. Claude Code is installed as the student in
`/home/student/.local/lib/node_modules`, which the student owns, so an update rewrites it in
place. `npm:*` in `50-image.sh` holds that.

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
claude -p "Which port ranges may a dev server use in this container? List them and nothing else."
```
*Expect, in order:* refusal; **success** (the deny covers the credential file, not the whole
directory); refusal (whole subtree denied); the six forwarded ranges from the managed
`CLAUDE.md`.
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
After a few hours of normal work: `podman exec cs193v ps -eo stat --no-headers | grep -c Z`
*Expect:* **1** while the port forwarding is up, and 0 with it down. That one is `[sshd]
<defunct>` and it is expected, not a leak: it is the original `sshd -i` that re-exec'd into
`sshd-session`, and its parent is sshd's own privsep monitor, which stays alive as long as the
tunnel does — so it is never reparented to PID 1 and no PID 1 could reap it. It clears when
the tunnel exits, and eight tunnel restarts accumulated none. `cs193v doctor` reports this
count, so a TA reading "zombies 1" should not treat it as a fault.
What matters is that it does not **grow**, and that anything other than sshd is reaped.
*Automated:* zero non-sshd zombies right now, zero after an orphan is deliberately created,
and ≤2 after five killed exec clients (`60-container.sh`, `70-sighup.sh`). The sshd one is
recorded rather than asserted.

---

## Needs sudo (skipped — nobody was at the keyboard)

### §1.5 — `sudo ./cs193v` is refused
*Expect:* a clear refusal explaining that this would run podman rootful and defeat the
isolation model, exit non-zero, and create nothing.
*Automated equivalent:* the same branch is exercised by faking `id` in
`30-launcher-shim.sh :: root:*`, which asserts the refusal, the wording, a non-zero exit,
that nothing is created, and that podman is not even contacted. Only the real `sudo`
invocation is unverified.

### §2.4 / §9.2 — `--rebuild --logout` really deletes the volumes
Destructive: it logs you out of claude, gh and vercel. Gated behind an opt-in so a routine
suite run cannot do it to you:
```sh
CS193V_DESTRUCTIVE=1 .private/tests/run-tests.sh --tier live
```

---

## Needs another platform

### §1.3 — bash 3.2 on macOS
`bash --version` (expect 3.2.x), then run the installer with `/bin/bash` explicitly, and run
`.private/tests/run-tests.sh --tier static,unit,shim` — the suite is bash 3.2-compatible on purpose
so it can run here.
*Expect:* no `mapfile`, associative-array or `${x,,}` errors.
*Automated on Linux:* the ban-list greps, plus a check that every empty-array expansion uses
the `${arr[@]+...}` guard — which is a **bash 3.2-only** failure that no Linux run can
surface (ERRORS.md A5). Running the suite on a Mac is what actually proves it.

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

### §9.3 — WSL teardown
`wsl --unregister CS193V`
*Expect:* removes the distro without touching any other. Confirm a pre-existing distro
still works.
