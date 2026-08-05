# CS193V container — findings from the first verification pass

Written by a Claude Code instance working through `VERIFICATION.md` on **native Ubuntu
26.04**, 2026-08-05. This machine is the ideal native-Linux rig: Ubuntu 26.04 LTS,
rootless podman 5.7.0 (exactly `MIN_PODMAN`), pasta, crun, cgroup v2 with `cpu memory pids`
delegated to uid 1000, `/etc/subuid` populated, systemd as PID 1. **3.4 GB RAM**, which is
worth knowing because the installer's own formula declines to set a memory cap that low.

Every item below is reproducible with `tests/run-tests.sh`. Sections:

- **A. Fixed** — blocking or clearly-wrong things repaired during the pass.
- **B. Open, non-blocking** — real defects left for you to decide on.
- **C. Not run** — and why.
- **D. Answers to the disputed questions** in `VERIFICATION.md` §10.

---

## A. Fixed during this pass

> **Layout note (issue #16):** paths in this file predate the restructure. Build and
> maintenance files now live in `.private/`, flag files in `.config/`, and a student's course
> directory contains only `cs193v` and `projects/`. So `Containerfile` is
> `.private/Containerfile`, `messages.txt` is `.private/messages.txt`, `container.args` is
> `.config/container.args`, and the suite runs as `.private/tests/run-tests.sh`.


### A1. The image could not be built at all (BLOCKING)

`Containerfile` step 7 failed with exit 4:

```
groupadd: GID '1000' already exists
useradd: UID 1000 is not unique
Error: building at STEP "RUN groupadd -g 1000 student && useradd -u 1000 -g 1000 ...":
  while running runtime: exit status 4
```

Since 23.04 the Ubuntu base image ships **its own `ubuntu` user at uid *and* gid 1000**:

```
$ podman run --rm ubuntu:26.04 getent passwd 1000
ubuntu:x:1000:1000:Ubuntu:/home/ubuntu:/bin/bash
```

So `ARG NODE_VERSION` and everything after step 7 had never executed, and no image has ever
existed. This is the root cause of "podman was never run during the design research" being
so costly: the very first runtime step was broken.

**Fix applied:** delete whoever holds 1000 before creating `student`, guarded with `getent`
so it still works on a future base image that drops the default user, and assert the
resulting ids. Deleting rather than reusing is deliberate — the account name appears in
every path, prompt and error a student reads, and `--userns=keep-id:uid=1000,gid=1000` pins
the number, so the name has to be ours. Regression test:
`tests/10-static.sh :: containerfile:handles-base-image-uid-1000`.

### A2. `msg()` printed an empty STOP banner for any multi-line value (BLOCKING for support)

`cs193v:88` substituted placeholders with `sed`. sed's replacement text cannot contain a
newline, and `err.create-failed` / `err.pull-failed` both interpolate raw podman output,
which is always multi-line. The result:

```
sed: -e expression #1, char 64: unterminated `s' command

┏━━ STOP ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
```

An empty red box, on the two error paths a stuck student is most likely to reach.

**Fix applied:** literal split-and-rejoin using `${tail%%"$ph"*}` / `${tail#*"$ph"}`.

Worth recording why the obvious fix is wrong: **`${out//"$ph"/$v}` must not be used here.**
Bash 5.2+ expands `&` in the replacement to the matched text, the way sed does, while bash
3.2 treats it literally — so it would corrupt any podman message containing `&` on Linux
and not on macOS. Verified directly. Tests cover a value containing a newline *and*
`& | \ /`, plus a value containing `{{OUT}}` itself (which naive looping would spin on
forever).

### A3. `files/ports` printed 32 hex digits instead of an IPv6 address

The most common real failure this tool exists to explain — a server told to bind
`localhost` binds `::1` on a dual-stack container — rendered as:

```
5174   [00000000000000000000000001000000] UNREACHABLE  bound to [000000...] only; ...
```

which also destroyed the column alignment of every row after it.

**Fix applied:** a real `decode_v6()` (four little-endian 32-bit words, network word order),
unwrapping `::ffff:a.b.c.d` to its IPv4 form, `BOUND TO` widened to 15 columns.
`listeners()` also takes an injectable path now so the parser is testable against captured
`/proc` fixtures rather than only whatever happens to be listening.

### A4. `files/ports` counted system services as student problems

`systemd-resolved` on `:53` and cups on `:631` were reported as `NOT PUBLISHED — two
problems`, inflating the problem count and making the command exit non-zero on a healthy
container. No published port is below 3000 and rootless podman refuses to publish anything
under 1024 at all, so a privileged listener is never a student's dev server.

**Fix applied:** still listed, now as `system`, and not counted.

### A5. bash 3.2 landmine: empty-array expansion under `set -u`

`cs193v` expanded `"${ARGS[@]}"` and `"${RUN_ARGS[@]}"` unguarded. On bash < 4.4 — **every
Mac** — expanding an empty array under `set -u` is a fatal `unbound variable`. It triggers
when `container.args` contains no flag lines, which is exactly the mis-edited-file support
case, and it would have produced a raw bash error instead of the intended message.

**Fix applied:** the `${arr[@]+"${arr[@]}"}` idiom, verified to preserve elements containing
spaces (which matters for `--label cs193v.dir=/Users/me/My Course/cs193v`). The static tier
greps for any unguarded expansion so it cannot come back.

### A6. Installer could report success over a broken download

`fetch_files` piped `curl` into `tar` and checked only tar's status.

Measured, so the record is accurate: GNU tar exits 2 on both a truncated gzip stream and on
empty input, so those cases were *already* caught. The case that genuinely slipped through
is a **well-formed but incomplete archive** — tar extracts it and exits 0, so the installer
printed "Setup finished" over a directory with no launcher in it.

**Fix applied:** `set -o pipefail` in a subshell (so curl's failure is authoritative
regardless of which tar is installed — macOS ships a different one), plus an explicit
check that `cs193v`, `container.args`, `messages.txt` and `Containerfile` all arrived
non-empty. All three failure shapes are tested.

### A7. Every error message overflowed the STOP box

The box is 69 display columns; message bodies ran to 88. Text spilled past the border on
every single error.

**Fix applied:** the 26 over-wide lines in `die()`-routed messages rewrapped to ≤67
columns. Verified word-for-word identical afterwards — only line breaks changed, no wording
touched. The lint measures **display columns via python3, not `awk length()`**: Ubuntu's awk
is mawk, which is not multibyte-aware and reported the box border as 207 columns instead of
69. An earlier version of this check passed vacuously because of exactly that.

### A8. Node moved from a downloaded tarball to apt (requested during review)

`Containerfile` layer 2 unpacked a tarball from nodejs.org into `/usr/local`. Now installed
from **NodeSource's apt repository**, so `apt upgrade` inside the container can pick up Node
security fixes — a tarball in `/usr/local` cannot be patched by anything a student runs, so
every CVE would have needed an image rebuild and a `NODE_VERSION` bump.

NodeSource rather than Ubuntu's own `nodejs`, because Ubuntu 26.04 carries **22.22.1 with npm
9.2.0** — two majors behind on both — and de-bundles npm's vendored dependencies into ~70
separate `node-*` packages, which diverges from what every tutorial a student reads will do.
NodeSource's `nodistro` suite carries **amd64 and arm64**, so one repo line serves both legs
of the manifest, and it publishes exact patch versions, so the pin survives:

```
$ podman run --rm --entrypoint sh localhost/cs193v:dev -c 'dpkg-query -Wf "${Package} ${Version}" nodejs; node -v; npm -v'
nodejs 24.18.1-1nodesource1
v24.18.1
11.16.0
```

Deliberately **not** `apt-mark hold`'d — holding it would re-create the problem the switch was
meant to solve. The exact patch version is still pinned at build time for reproducibility.
Root-owned at `/usr/bin/node` with globals in `/usr/lib/node_modules`, so the
no-group-writable-tree property that ruled out nvm is preserved. Verified: no
`/usr/local/share/nvm`, nothing held, image size unchanged at 1.74 GB. The key is stored
armored as `.asc`, which apt reads directly, so this needs no `gnupg`.

### A9. The test suite interfered with itself across tiers

Running every tier together produced 14 failures that did not occur tier-by-tier. Cause: an
interrupted earlier run had left a stray `-p 127.0.0.1:9998:9998` in `container.args`, so the
live tier's container was created *with* the flag before the drift test appended it, and six
assertions then failed in ways that pointed nowhere near the real problem.

Fixed by making the live tier refuse to start against a dirty `container.args`, restore with
a verified `cmp` rather than a blind `cp`, and clean up on `INT`/`TERM` as well as `EXIT`.
Also made the installer's consent test deterministic: it assumed podman was *absent* (so that
something would need consent), which only held on a machine that happened not to have it. It
now fakes a username with no `/etc/subuid` entry, which drives the same branch anywhere.

### A10. Three dead `PLATFORM=` arguments

`err.no-podman`, `err.podman-too-old` and `err.podman-unreachable` were each passed
`PLATFORM=` but contain no `{{PLATFORM}}`. Harmless, but it signals the message was meant
to be platform-specific and is not — each currently prints advice for every platform at
once. **Fix applied:** dead arguments dropped. Whether these messages *should* branch on
platform is a wording call left to you; the placeholder-coverage test now catches a
`{{X}}` leaking to a student verbatim in either direction.

---

## B. Open and non-blocking — for you to decide

### B1. `VERIFICATION.md`'s own checks (corrected in the new suite, not yet in the doc)

Nine problems in the checklist itself. Several mean the checklist would have produced a
*misleading* report in both directions.

| § | Problem |
| --- | --- |
| A.1 | `grep -qx 'projects/*' .gitignore` — `*` is a BRE quantifier, so it matches `projects`, `projects/`, `projects//` and **never the literal line**. The check silently never fired. Needs `-F`. |
| A.1 | The `comm -3` message cross-reference aborts with `comm: file 1 is not in sorted order` under `en_US.UTF-8`, because sort and comm disagree about punctuation. Needs `LC_ALL=C`. It passes cleanly once fixed: 41 keys, zero orphans, zero missing. |
| A.3 | `nvm-not-group-writable` is **vacuous**. `/usr/local/share/nvm` does not exist by design, so `stat` fails, the case falls to the catch-all, and it prints `ok` while asserting nothing. |
| A.4 | Says `.Config.Env` should contain `TERM` and `COLORTERM`. Impossible — those are passed per-`exec`, never at create time. |
| A.5 | The 256-colour probe calls `podman exec -it` with **no `-e TERM`**, so TERM defaults to `xterm` and it reports 8. It **fails on a correctly working system**. The launcher forwards TERM in `open_shell`/`verb_ports`; the probe must too. |
| A.10 | The verb loop `for v in "" ports doctor ...` **hangs**: the empty verb reaches `exec podman exec -it` with stdin still on the terminal. Needs `</dev/null`. |
| A.12 | The installer idempotency check is **vacuous**. `bash install-cs193v.sh </dev/null` hits the consent menu, which with no tty picks the safe default ("Stop, do not change anything") and exits 0 before touching anything, so the before/after state hashes are trivially identical. |
| 1.2 | Claims non-TTY "falls back to numbered selection rather than hanging". It does not — it picks the default. The **code is right and the doc is wrong**; picking the safe default is better than either alternative. |
| 7.3 | Says to run `man ls`, while A.3 asserts `man` is deliberately absent. Self-contradictory. |

### ~~B2~~. `container.args` claimed a warning that does not exist — **FIXED**

The comment promised `cs193v doctor` warns when `CS193V_PORTS` drifts from the `-p` lines.
`verb_doctor` never compared them. Replaced with a pointer to
`tests/10-static.sh :: ports:CS193V_PORTS-matches--p-lines`, which enforces the invariant at
edit time — strictly better than a runtime warning, since it fails before a mismatch can
ship. Guarded by `claims:no-phantom-doctor-ports-warning`. GitHub issue #11.

### B2 (original diagnosis)

> `# Consumed by the in-container ports command. Kept in step with the -p lines above;`
> `# cs193v doctor warns if they disagree.`

`verb_doctor` never compares `CS193V_PORTS` against the `-p` lines. Either implement it or
drop the claim. The new static tier enforces the invariant at build time instead, which is
strictly better than a runtime warning — so dropping the sentence is the honest fix.

### ~~B3~~. The case-sensitivity claim was wrong for Windows — **FIXED**

Scoped to macOS, and Windows corrected: the shipped layout puts `projects/` on the WSL
distro's ext4 home, so Windows students are case-sensitive too and do **not** have the
`import './Button'` hazard. Measured on this machine as `case-sensitive`. Guarded by
`claims:windows-not-called-case-insensitive`. GitHub issue #12.

### B3 (original diagnosis)

> "macOS and Windows are case-insensitive; Linux is not."

On Windows this design puts `projects/` inside the WSL distro's **ext4** home
(`\\wsl.localhost\CS193V\home\<user>\cs193v\projects`), which **is** case-sensitive. The
sentence is right for macOS and wrong for the shipped Windows layout — and it matters,
because it is offered as the reason a Mac student's `import './Button'` bug appears later.

### B4. `am-i-in-a-container` does not check anything

It unconditionally prints "Yes, you are inside the CS193V container!". Deliberate per its
own comment, and the guides only ever run it inside — but the name is a question and the
answer is hardcoded, so a student who runs it on their host by mistake is actively
misinformed. A one-line `[ -f /run/.containerenv ] || [ -f /.dockerenv ]` guard would fix
it without changing the happy path.

### B6. `man git` exits 0 and tells students to run `unminimize`

`CONTAINER-DESIGN.md` and the managed `CLAUDE.md` both say man pages are not installed and
`tldr` stands in. True in effect, but Ubuntu's minimized image leaves a `/usr/bin/man` stub
that **exits 0** and prints:

```
This system has been minimized by removing packages and content that are
not required on a system that users do not log into.

To restore this content, including manpages, you can run the 'unminimize'
command. You will still need to ensure the 'man-db' package is installed.
```

For a first-year student that is worse than `command not found`: it reads as an
instruction, and following it bloats the container with something that vanishes on the next
`--rebuild`. Consider replacing `/usr/bin/man` with a two-line stub pointing at `tldr`.
`tests/50-image.sh` now asserts the property that matters (no real manual page) and records
the stub's behaviour.

### ~~B7~~. 271 Noto font files were installed but nothing could enumerate them — **FIXED**

`fontconfig` added explicitly to the apt line (it was only a *Recommends* of
`fonts-noto-core`, and the line uses `--no-install-recommends`). Now:

```
fc-match: present
NotoSans-Regular.ttf: "Noto Sans" "Regular"
```

Tests `fonts:fontconfig-is-installed` and `fonts:sans-serif-resolves-to-noto` pass. The Pillow
/ matplotlib half is handled by rewriting `tests/MANUAL.md` §7.6, which could not be followed
as written: it now automates the fontconfig resolution and gives a `pip install pillow`
recipe for the human rasterisation check, noting that Pillow bypasses fontconfig so it tests
the font files rather than their discoverability. GitHub issue #5.

### B7 (original diagnosis)

`fonts-noto-core` is present (42.5 MB installed) but **`fontconfig` is not**, so there is no
`fc-list` or `fc-match`:

```
$ podman run --rm --entrypoint sh localhost/cs193v:dev -c 'command -v fc-list'
(nothing)
```

`fonts-noto-core` only *Recommends* `fontconfig`, and the apt line uses
`--no-install-recommends`. Anything that resolves fonts through fontconfig — librsvg,
Pango, GD, ImageMagick — cannot find them. The Containerfile's stated reason for the
package ("anything that rasterizes text (Pillow, matplotlib, librsvg) needs one") also
names two libraries that **are not in the image at all**:

```
Pillow: NOT installed
matplotlib: NOT installed
```

So today the image pays ~42 MB for fonts that nothing present can use. Either add
`fontconfig` (a few MB, makes the existing files work) or drop the fonts. Note
VERIFICATION.md §7.6 asks a human to render text with Pillow or matplotlib — that check
cannot pass as written, because neither is installed.

### ~~B8~~. 295 MB of npm cache was baked into the image — **FIXED**

`npm cache clean --force` added to both `npm install -g` layers, in the *same* RUN — a file
deleted in a later layer still ships in the earlier one. Measured effect:

| | before | after |
| --- | --- | --- |
| image | 1.74 GB | **1.52 GB** |
| `/root/.npm` | 295 MB | **1 MB** |
| claude-code layer | 382 MB | **290 MB** |
| vercel layer | 377 MB | **250 MB** |

Test `img:npm-cache-not-baked-into-the-image`. GitHub issue #6.

### B8 (original diagnosis)

```
$ podman run --rm --entrypoint sh localhost/cs193v:dev -c 'sudo du -sh /root/.npm'
295M    /root/.npm
```

The two `npm install -g` layers leave root's npm cache behind. It is dead weight in a
**1.74 GB** image — 17% of the total, on top of `vercel` (175 MB) and
`@anthropic-ai/claude-code` (277 MB) themselves. Adding `&& npm cache clean --force` to each
npm layer would remove it. The apt layer already cleans `/var/lib/apt/lists` properly.

### B9. Layer sizes defeat the resume-on-failure design

`VERIFICATION.md` §A.2 wants no layer over 400 MB, because podman cannot resume a partial
layer download but does keep completed ones — so the layer split is what limits what a
student loses when dorm wifi drops. Measured:

| Layer | Size |
| --- | --- |
| apt system packages | **588 MB** |
| claude-code | **382 MB** |
| vercel | **377 MB** |
| node | 201 MB |
| everything else | < 15 MB each |

Three layers at or above the target, and the worst is 588 MB. `build-essential` dominates
the apt layer (gcc-15 alone is 76 MB installed, g++-15 another 41 MB). Worth deciding
whether `build-essential` is needed — it is there for native npm modules, but a student who
needs it could `sudo apt install` it, which is exactly what passwordless sudo is for.
Cleaning the npm cache (B8) would also bring both npm layers under 400 MB.

### B10. `npm ls -g` shows nothing, and Claude Code auto-update may not work

Build-time globals live in root-owned `/usr/local/lib/node_modules`, while the student's npm
prefix is `/home/student/.local`. Both are deliberate. The consequences are not obviously
intended:

- `npm ls -g --depth=0` prints nothing, though `vercel` and `claude` are installed.
- `managed-settings.json` deliberately leaves `autoUpdatesChannel` alone so "students always
  have current Claude Code" — but the student cannot write to
  `/usr/local/lib/node_modules/@anthropic-ai`, so an in-place npm update would need sudo.

Whether Claude Code's own updater handles this (it may install to `~/.local` and shadow the
root-owned copy via `PATH`, which does put `/home/student/.local/bin` first) needs checking
against a real login — see `tests/MANUAL.md`. If it does not, the stated "auto-update stays
enabled" benefit is not being delivered.

### ~~B11~~. `tldr --update` failure was silent (`|| true`) — **FIXED**

`|| true` removed, and the page count asserted in the SAME layer as the fetch so the build
cannot succeed with an empty or truncated cache. A `tldr tar` smoke check runs too. Since
`man` is deliberately absent, an empty cache means a student has no command-line help at
all, which is exactly the failure a CI network hiccup would have shipped silently.

Verified the guard has teeth rather than assuming: it returns non-zero against an empty
directory and the build log shows `test 7409 -gt 1000`. Static guards
`tldr:build-does-not-swallow-failure` and `tldr:build-asserts-the-cache-is-populated`.
GitHub issue #9.

### B11 (original diagnosis)

`Containerfile:183` is `RUN su student -s /bin/sh -c 'tldr --update' || true`. It works — the
built image has **7409 cached pages (30 MB)** and `tldr tar` succeeds under
`--network=none`, verified. But `|| true` means a network hiccup during a CI build ships an
image with an empty cache and nothing reports it. Since `man` is deliberately absent, a
student would then have *no* command-line help at all. Either drop the `|| true` or assert
the cache size in the build. `tests/50-image.sh` now asserts page count, ownership and
offline operation, so at least it is caught before release.

### B12. The Node-from-tarball decision is undocumented, and has an unstated cost

Raised during review: why not apt? The reasoning is sound but appears nowhere — the
Containerfile's comment argues only against **nvm**, never against apt. For the record, on
Ubuntu 26.04:

| | apt | image (tarball) |
| --- | --- | --- |
| node | 22.22.1 | **24.18.1** |
| npm | 9.2.0 | **11.16.0** |

Two majors behind on both. Ubuntu also de-bundles npm's vendored dependencies into ~70
separate `node-*` packages, which is a known source of divergence from what every tutorial
shows — bad in a course where "it worked in the video" matters.

The unstated cost of the tarball: **`apt upgrade` inside the container never updates Node**,
so a Node CVE requires an image rebuild and a `NODE_VERSION` bump. The middle option is
NodeSource's apt repo — the same pattern the `gh` layer already uses — which would give
apt-managed Node 24 with security updates in exchange for one more third-party repo to
trust. Worth a sentence in the Containerfile either way, so it is not re-litigated.

### ~~B13~~. `./cs193v` hung forever when stdin was not a terminal — **FIXED**

Fixed by refusing rather than by silently degrading. `open_shell` now checks `[ -t 0 ]` first
and, with no terminal, prints a STOP banner that names what a script should use instead:

```
┏━━ STOP ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃ cs193v could not open a shell, because it is not being run from a
┃ terminal — its input is coming from a file or another program rather
┃ than from your keyboard.
┃ ...
┃ Your container is set up and running; only the shell was not opened.
┃ These commands do not need a terminal, so they are the ones to use in
┃ a script:
┃
┃     cs193v --rebuild     make sure a fresh container exists
┃     cs193v ports         check whether your servers are reachable
┃     cs193v doctor        print the status report
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
```

Checked inside `open_shell` rather than in the dispatcher, deliberately: preflight, the drift
prompts and creating or starting the container are all useful and idempotent, so a script
that got this far has done real work and the message can honestly say the container is ready.
Exits 1. New message key `err.needs-a-terminal`.

`ports` and `doctor` also pass `-it`, but the commands they run exit on their own, so they
were never affected and remain scriptable — which matters, because the refusal message
points at them.

Regression tests: `tests/30-launcher-shim.sh :: noterm:*` (nine assertions, including a
wall-clock check that it refuses rather than hangs, that the container is still created, that
no exec is attempted, that a pty-driven launch *does* open a shell, and that the three verbs
named in the message still work with a redirected stdin) and
`tests/80-launcher-live.sh :: noterm:*` against real podman, where the pty is genuine.

Consequence for the test suite: bare launches now need a real terminal, so the shim and live
tiers drive them through `script(1)` (`launcher_pty` / `LB`). That is a more faithful model of
what a student does anyway.

### B13 (original diagnosis)

Found while automating §A.10. Measured:

```
A) bare launcher, stdin=/dev/null, stdout=pipe   HUNG (killed by timeout)
B) bare launcher, stdin=/dev/null, stdout=file   HUNG (killed by timeout)
C) bare launcher, stdin="exit"                   returned
D) verb --dev-print-command                      returned
E) verb doctor                                   returned
F) verb --rebuild                                returned
```

`open_shell` (`cs193v:404`) ends in `exec podman exec -it`. The `-t` allocates a pty, and a
pty **never delivers EOF the way a pipe does** — so `bash -l` sits waiting for input that
cannot arrive. Redirecting from `/dev/null` does not help; only sending a literal `exit`
does.

Why it matters beyond the tests: any support script, CI job or verification battery that
runs `./cs193v` non-interactively wedges. **`VERIFICATION.md` §A.10's own verb loop hangs on
this**, and the obvious `</dev/null` fix does not work — that correction has been made twice
in the doc now, and the second time is the right one.

Suggested two-line fix, which would make the launcher automatable without changing anything
a student sees:

```sh
# in open_shell, instead of a bare -it
if [ -t 0 ]; then TTY=-it; else TTY=-i; fi
exec podman exec $TTY -w /workspaces ... "$NAME" bash -l
```

With `-i` alone, stdin from `/dev/null` gives bash an immediate EOF and it exits cleanly.
Not applied, since it changes launcher behaviour and is not blocking — the suite works
around it by feeding `exit` and timeout-wrapping every call. `install-cs193v.sh`'s
`smoke_test` is unaffected: it only runs `--dev-print-command` and `doctor`.

### ~~B14~~. `cs193v doctor` always reported "config STALE" in dev mode — **FIXED**

Fixed in `config_hash` rather than in `verb_doctor`, so every caller agrees by construction
and no verb added later can reintroduce it:

```sh
 config_hash() {
+    local img="${IMAGE:-$DEV_IMAGE}"
-    { printf '%s\n' "$IMAGE" "$WORKSPACE"
+    { printf '%s\n' "$img" "$WORKSPACE"
       printf '%s\n' ${ARGS[@]+"${ARGS[@]}"}; } | sha_stdin
 }
```

A `local`, so `IMAGE` is not mutated and doctor's honest `<unset: dev mode>` line still
reads correctly. Now:

```
  pinned image     <unset: dev mode>
  config           matches container.args
```

Regression tests in `tests/30-launcher-shim.sh`: `doctor:reports-a-matching-config-as-matching`,
`doctor:does-not-cry-stale-when-config-matches`, `doctor:agrees-with-the-launch-path`, plus
`doctor:matching-config-with-a-pinned-image` — which **passed before the fix**, confirming
the bug was dev-mode-only exactly as diagnosed. `doctor:reports-stale-config` still passes,
so real drift is still reported. Original diagnosis kept below for the record.

### B14 (original diagnosis)

`doctor` is described as "a report to paste when asking staff for help", so it must not lie.
It currently does:

```
$ ./cs193v doctor
  pinned image     <unset: dev mode>
  config           STALE — run cs193v and accept the recreate prompt
```

...while every other path disagrees:

```
stored hash:           f73c90f027a7a7fa...
--dev-print-command:   f73c90f027a7a7fa...     (identical)
plain launch:          0 recreate prompts shown
```

`verb_doctor` (`cs193v:471`) calls `load_args` but **never `resolve_image`**, so with an
empty `IMAGE=` it feeds `IMAGE=""` into `config_hash`, while `verb_print_command` and the
launch path both resolve it to `localhost/cs193v:dev` first. The hashes therefore cannot
match, and doctor tells you to accept a prompt that will never appear.

Only manifests in dev mode — which is the state the repo ships in today and the state every
instructor dev loop is in. One-line fix, mirroring what `verb_print_command` already does:

```sh
    load_args
+   [ -z "$IMAGE" ] && IMAGE="$DEV_IMAGE"
```

Not applied (non-blocking). `tests/80-launcher-live.sh :: doctor:reports-config-matches` is
left **failing on purpose** so this is not forgotten.

### B15. shellcheck was never run; it finds two things

shellcheck was not installed in the authoring environment either, so it had never been run
despite §A.1 calling for it. Two findings, both now fixed as safe no-ops:

- `SC1087` in **both** `menu()` implementations: `"$ESC[A"`. Unbraced `$name[` reads as an
  array subscript. It happens to be **correct** here — the pattern is fully double-quoted so
  `[A` is literal, and the pty-driven menu tests confirm the arrow keys work — but it is a
  genuine trap for the next person to edit, so it is now `"${ESC}[A"`.
- `SC2034`: an unused `cap` local in `mac_vm_target_mb`. Removed.

The static tier now runs shellcheck on the launcher, the installer and the suite itself, so
it stays clean.

### B5. `REPO_OWNER="CHANGEME"`, empty `IMAGE=`, missing CI, `latest` build args

Tracked as release gates, not regressions: `tests/run-tests.sh --release`. Currently 5
failures, all four blanks. The consequential one is the **missing
`.github/workflows/build.yml`** — referenced by `README.md:27,38` and `Containerfile:4`.
Without it there is no multi-arch image, so `IMAGE=` can never be filled, so every student
runs permanently in dev mode and sees the "tell course staff — this line should not appear"
warning on every launch.

---

## C. Not run, and why

- **Anything needing `sudo`** — the instructor was away and could not authenticate. Nothing
  in the suite needs it; noted only because §1.5's *real* `sudo ./cs193v` check is
  unreachable. The launcher's root refusal is covered instead by faking `id` in the shim
  tier, which exercises the same branch. `unshare -r` is not usable here (writing
  `/proc/self/uid_map` is not permitted in this sandbox).
- **`--full-rebuild`'s volume deletion** — gated behind `CS193V_DESTRUCTIVE=1` so a normal
  run can never log anyone out. Re-run with that set to cover §2.4 and §9.2.
- **`--update`** — `IMAGE=` is empty, so there is nothing to update to. Covered against a
  fake registry in the shim tier.
- **Multi-arch manifest (§A.2)** — a local `--dev-build` is single-arch by definition. Moved
  to the release tier, where it belongs.
- **Everything needing another platform or a person** — §1.2's rendering, §1.3 (bash 3.2 on
  a Mac), §3.4/§3.5 (real HMR), §4.5/§4.7 (a browser, Defender), §5.1–§5.6, §6.x (sleep and
  wake), §7.2/§7.3/§7.6/§7.8, §8.x (real logins), §9.3. Consolidated into
  `tests/MANUAL.md`.

---

## D. Answers to the disputed questions

Measured on **Ubuntu 26.04 native, rootless podman 5.7.0, pasta, crun, cgroup v2**. These are
the questions `VERIFICATION.md` §10 and `README.md` say research could not settle. Reproduce
any of them with `tests/run-tests.sh --tier container` (every `REC` line) and
`tests/run-tests.sh -k sighup` (which prints the matrix as a table).

### D1. The SIGHUP matrix — does closing the window kill a server?

**No. Every shape survives on native Linux.**

```
foreground   alive=yes  http=200  ppid=0  fd1=/dev/pts/0
background   alive=yes  http=200  ppid=0  fd1=/dev/pts/0
nohup        alive=yes  http=200  ppid=0  fd1=/dev/pts/0
setsid       alive=yes  http=200  ppid=0  fd1=/dev/pts/0
no-tty       alive=yes
```

Simulated by killing the `podman exec` client, which is what closing a window does. The
server not only survives, it stays **reachable** (`http=200`) — even in the foreground case,
and even with no pty involved. `fd1` still points at the orphaned pty, so its output goes
nowhere, which matches what `README.md` predicted from conmon's source.

**Consequence for the docs.** `CONTAINER-DESIGN.md:226` and
`files/claude-code/CLAUDE.md:59-66` both warn that closing a terminal window "may stop a
server you started in it". On this platform that is simply not so. The hedge "may" keeps it
from being false, but it teaches students to keep windows open for no reason and it is the
one thing §5.1 was meant to settle. **Confirm on macOS and WSL before rewording** — the exec
client lives outside the VM there, so the answer may genuinely differ. §5.1 (closing a real
window by hand) is still worth doing to check the simulation models it.

### D2. Does seccomp block `mount()` in a nested user namespace?

**No — `ALLOWED`.** This confirms the correction the design docs already make against their
own earlier claim. `unshare -U --map-root-user -m -- mount -t tmpfs none /mnt` succeeds.
Escaping into PID 1's namespaces (`nsenter --target 1`) is blocked, which is the property
that actually matters.

### D3. Does host-side `inotify` fire?

**Yes, it FIRES** on native Linux — as predicted. Container-side firing is asserted;
host-side is recorded. Expect **DOES NOT FIRE** on macOS and WSL, where the shared-folder
layer does not deliver notifications inward. `CONTAINER-DESIGN.md`'s "known rough edges" is
correct as written for Linux.

### D4. Is a loopback-bound server reachable from the host?

**No — connection refused**, exactly as the course teaches. `podman port` publishes to the
container's `eth0` and the forwarder never touches its `lo`. The host side really is
loopback-only (`ss` shows `127.0.0.1:3000`, not `0.0.0.0:3000`), and it is not reachable
from the LAN. All 46 published ports are reachable from the host; the five unpublished ports
tested are all refused. The central ports lesson holds on this platform.

### D5. cgroup delegation — is `memory.max` the cap, or `max`?

**The cap, exactly.** `--memory=1024m` yields `memory.max = 1073741824`. The `pids` cap is
podman's default 2048 and is enforced (`sh: 0: Cannot fork` at `--pids-limit 64`). An OOM is
clean: the process is `Killed` with **exit 137**, the container stays `running`, and
`podman exec` still works. `--memory-swap` is set by podman to **2× memory** when unspecified,
so it is never equal to `--memory` — the thing `container.args` warns about.

This answers §5.5 for **Linux only**. WSL with `systemd=true` is the case that still needs
checking, and it is the one where the answer might be `max`.

### D6. AppArmor

`/proc/self/attr/current` reads exactly **`crun (unconfined)`**, confirming the design doc's
claim verbatim. AppArmor is not confining this container.

### D7. `/proc` is not cgroup-aware

`free=3398MB cgroup=1024MB`. Confirms why `CS193V_MEMORY_MB` has to be passed in — a student
running `free` inside sees the host's RAM, not their limit.

### D8. Does `podman start` really ignore new flags?

**Yes.** Added `-p 127.0.0.1:9998:9998`, then `podman stop && podman start`: the new port is
**not** published. So the whole `cs193v.confighash` mechanism is load-bearing, not
defensive — without it every student's flags would be frozen at first run. Accepting the
recreate prompt does apply it.

### D9. Other measurements worth having

| | |
| --- | --- |
| first launch | 2 s |
| subsequent launch | 2 s |
| `--rebuild` | 2 s |
| launcher overhead (`--dev-print-command`) | 511 ms |
| `podman exec` overhead | 158 ms |
| 2000 files created on the bind mount | < 1 s |
| case sensitivity | case-sensitive |
| `tput colors` with `-e TERM` forwarded | 256 |
| `tput colors` without forwarding | **8** — proves §A.5's original probe was broken |
| zombies after 5 killed exec clients | 0 |
| image size | 1.74 GB |
