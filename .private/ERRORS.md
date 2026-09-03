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
every single error. (71 columns since B16, which is what gave the ≤67 wrapping done here a
right-hand border to line up against.)

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
| A.5 | The 256-colour probe calls `podman exec -it` with **no `-e TERM`**, so TERM defaults to `xterm` and it reports 8. It **fails on a correctly working system**. The launcher forwards TERM in `open_shell`; the probe must too. |
| A.10 | The verb loop `for v in "" doctor ...` **hangs**: the empty verb reaches `podman exec -it` with stdin still on the terminal. Needs `</dev/null`. |
| A.12 | The installer idempotency check is **vacuous**. `bash install-cs193v.sh </dev/null` hits the consent menu, which with no tty picks the safe default ("Stop, do not change anything") and exits 0 before touching anything, so the before/after state hashes are trivially identical. |
| 1.2 | Claims non-TTY "falls back to numbered selection rather than hanging". It does not — it picks the default. The **code is right and the doc is wrong**; picking the safe default is better than either alternative. |
| 7.3 | Says to run `man ls`, while A.3 asserts `man` is deliberately absent. Self-contradictory. |

### ~~B2~~. `container.args` claimed a warning that does not exist — **FIXED**

The comment promised `cs193v doctor` warns when the declared port list drifts from the `-p`
lines. `verb_doctor` never compared them. Replaced with a static check that enforced the
invariant at edit time — strictly better than a runtime warning, since it fails before a
mismatch can ship. Both the `-p` lines and the port list have since gone, so the invariant has
no failure left to catch and the check went with them; the guard against the *claim* coming
back is still there, as `claims:no-phantom-doctor-ports-warning`. GitHub issue #11.

### B2 (original diagnosis)

> `# Kept in step with the -p lines above; cs193v doctor warns if they disagree.`

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

### ~~B6~~. `man git` exits 0 and tells students to run `unminimize` — **FIXED**

Ubuntu's minimized image left a `/usr/bin/man` stub that **exits 0** and prints:

```
This system has been minimized by removing packages and content that are
not required on a system that users do not log into.

To restore this content, including manpages, you can run the 'unminimize'
command. You will still need to ensure the 'man-db' package is installed.
```

For a first-year student that is worse than `command not found`: it reads as an
instruction, and following it bloats the container with something that vanishes on the next
`--rebuild`.

`files/man` replaces it. It says manual pages are not installed here, names the `tldr` page
for whatever was asked about — the *last non-option* argument, so `man 3 printf` suggests
`tldr printf` rather than `tldr 3` — and **exits non-zero**, because `man git` genuinely did
not produce a manual page and `git commit --help`, which runs `man git-commit` underneath,
has to be able to tell.

It is installed over `/usr/bin/man` rather than shadowed from `/usr/local/bin`, or the
original would stay reachable by full path and to anything with a fixed `PATH`. The build
itself greps `man git` for `unminimize` and fails if it is still there, so a future base
image that reinstates the advice breaks CI rather than a student.

Guards: `man:*` in `tests/10-static.sh` and `tests/50-image.sh`, including one that checks
the page it names (`tldr git-commit`) really is in the offline cache. GitHub issue #8.

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

### ~~B9~~. Layer sizes defeat the resume-on-failure design — **WITHDRAWN**

The 400 MB per-layer ceiling is dropped as a requirement, and `img:no-layer-over-400MB` is
deleted from `tests/50-image.sh` along with the `img:largest-layer-mb` record that fed it.

It was never met, and three layers are over the line now rather than the one this section
originally reported. `podman history` against a current `--dev-build`:

| Layer | Size |
| --- | --- |
| apt system packages | **622 MB** |
| `npm install -g playwright` (incl. `install-deps chromium`) | **339 MB** |
| `npm install -g @anthropic-ai/claude-code` | 296 MB |
| `playwright install chromium` + smoke screenshot | 279 MB |
| `npm install -g vercel` | 248 MB |
| node, from the nodesource apt repo | 201 MB |
| the `ubuntu:26.04` base layer itself | 112 MB |
| gh, from the cli.github.com apt repo | 43 MB |

Playwright is what settles it. It arrived in daf749f, after this finding was written, and it
contributes **618 MB across two layers** — nearly the apt layer again. A browser binary
cannot be split, so no rearrangement of the Containerfile brings that under 400 MB; only
dropping Playwright would, and the course wants it. The apt layer's own options were to drop
`build-essential` (gcc-15 and g++-15 are ~120 MB of it, and it is there for native npm
modules) or to split apt across RUN steps that correspond to nothing a reader would
recognize. Neither is worth a download students do once.

What the design actually depends on is layer **order** — claude-code last, so a version bump
does not re-download node, gh and vercel. That is unchanged and still asserted by
`tests/10-static.sh :: containerfile:claude-code-is-last-software-layer`.

**B5 then removed most of what remained of the concern**, which is worth stating because it
is easy to read this withdrawal as merely giving up. Students build the image rather than
pulling it, so the premise the 400 MB ceiling rested on — "podman cannot resume a partial
layer *download*" — no longer describes what students do. A killed build resumes at the
failed RUN step, which is finer-grained than layer-level pull resume ever was, and layer
order now buys build-cache reuse instead: a `CLAUDE_CODE_VERSION` bump re-runs two small
layers rather than re-downloading ~300 MB. The residual cost is that a build interrupted
inside the 622 MB apt step redoes that step, which is a smaller and rarer loss than the one
this finding was about. Accepted rather than tested for, either way.

The measurement below is kept because it is the number any future revisit starts from.

### B9 (original diagnosis)

`VERIFICATION.md` §A.2 wanted no layer over 400 MB, because podman cannot resume a partial
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

### ~~B10~~. `npm ls -g` shows nothing, and Claude Code auto-update may not work — **FIXED**

The path in the original report was wrong, and worth correcting because it sent two other
documents the same way: the globals were in **`/usr/lib/node_modules`** (nodesource's apt
prefix). `/usr/local/lib/node_modules` never existed.

The cause was ordering. Layers 4–7 ran `npm install -g` as **root**, whose prefix is `/usr`,
while layer 8 — three layers later — pointed the *student's* prefix at `~/.local`. npm reads
exactly one global prefix, so the two never met.

Two consequences, one of them worse than reported:

- `npm ls -g --depth=0` did not "print nothing". It **exited 254** with an `ENOENT` on
  `/home/student/.local/lib` and six lines of npm error, because nothing had ever created
  that directory — the build pre-created `.local`, `.local/bin` and `.local/share`, but not
  `.local/lib`.
- **Auto-update worked**, which settles the question this entry parked for a human. Verified
  without a login: `claude doctor` reports `Running: npm-global`, and the updater's
  npm-global branch — read out of the shipped binary — runs `npm install -g <pkg>` with
  `cwd: homedir()` and **no `--prefix`**, so it resolved the *student's* prefix. Running
  exactly that as `student` produced a working, student-owned copy at `~/.local`, with
  `~/.local/bin/claude` winning on `PATH`. So the "auto-update stays enabled" benefit was
  real; it was just arriving as a second copy that shadowed the image's.

The fix moves the prefix setup into layer 2, beside Node, and runs all three
`npm install -g` calls under `su student`. `npm ls -g` now lists playwright, vercel and
Claude Code; an update rewrites the same directory instead of shadowing another one.

What the fix does **not** change: an update still writes ~283 MB into the container's
writable layer, because overlayfs copies a file up in full when it is modified. That cost is
recorded in `files/claude-code/managed-settings.json` rather than designed away.

It also turned up a vacuous test. The globals block in `tests/50-image.sh` matched against
`$(npm ls -g --depth=0 2>/dev/null)` — a command that errored, with its stderr discarded — so
every assertion in it was comparing against the empty string and passing for the wrong
reason. The block now asserts the command SUCCEEDS before matching anything on its output;
that ordering is the durable lesson, and the comment there says so.

The `absent:no-puppeteer` assertion that sat in that block was **removed by decision**, not
repaired — so nothing in the suite now fails if puppeteer is reintroduced as an npm global.
The rejection itself still stands and is still argued in the README's "Deliberately not
here"; it is documentation-only, and `VERIFICATION.md` §A.3 now says so at the point a TA
would otherwise assume the opposite. That line carried the same `2>/dev/null` as the
automated one and has been corrected the same way: exit status first, then record.

Guards: `npm:*` in `tests/50-image.sh` and `containerfile:*-installed-as-student` in
`tests/10-static.sh`. GitHub issue #13.

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
┃     cs193v doctor        print the status report
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
```

Checked inside `open_shell` rather than in the dispatcher, deliberately: preflight, the drift
prompts and creating or starting the container are all useful and idempotent, so a script
that got this far has done real work and the message can honestly say the container is ready.
Exits 1. New message key `err.needs-a-terminal`.

`doctor` also passes `-it`, but the commands it runs exit on their own, so it was never
affected and remains scriptable — which matters, because the refusal message points at it.

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

**RESOLVED, by removing three of the four rather than filling them in.** Down to 1 release
failure from 5, and the survivor is `REPO_OWNER` — website work, not engineering.

B5's diagnosis was right and its implied remedy was wrong. It read the missing
`.github/workflows/build.yml` as *the* consequential blank, because without CI there is no
multi-arch image, so `IMAGE=` can never be filled, so every student runs permanently in dev
mode and sees the "tell course staff — this line should not appear" warning on every
launch. All of that followed correctly from the premise that students **pull** the image.

The premise was the thing to question. Nothing had ever exercised the pull path — no
workflow on any branch or in any commit, no tags, `IMAGE=` empty, `pull_image()` a no-op
that printed "No course image has been published yet" and returned 0 — while `--dev-build`
had been the staff loop from the start and every test tier ran against the locally built
image. The repo had one tested way to obtain an image and one untested one, and it was
scaffolded to ship the untested one.

So the image is now built on each student's machine, and B5's four blanks resolve as:

| Blank | Outcome |
|---|---|
| `.github/workflows/build.yml` | **Gone.** No registry, so no multi-arch build to run, no digest to print, and no token to hold. |
| `IMAGE=` | **Gone.** It was kept for a while as an optional override that still pulled, then removed outright along with `CS193V_IMAGE`, `OVERRIDE_IMAGE` and `--update`'s pull branch. An override nothing exercised was not free: the stale-recipe check ran only when the resolved image equalled the locally built tag, so any value in any of them turned rebuild prompts off silently while `doctor` still said `STALE`. |
| `latest` build args | **Filled, and now enforced harder than CI would have.** A floating `ARG` used to mean CI drifted between runs while one artifact still reached everybody. It now means two students get different software, so `00-release-gates.sh` §3 pins `VERCEL_VERSION`, `CLAUDE_CODE_VERSION` and `PLAYWRIGHT_VERSION`, and the base image is digest-pinned as well. |
| `REPO_OWNER` | **Still open.** Unchanged by any of this. |

What the change costs, recorded so it is not rediscovered:

* **Nine build-time assertions moved from CI onto students.** `README.md:208-210` had it
  right — they exist so a wrong-architecture browser or an empty `tldr` cache fails the
  build instead of the student. They are kept rather than softened, because a student with
  no `tldr` and no `man` has no command-line help at all and would never know; `build_image`
  retries three times instead, which is cheap because podman keeps completed layers. The
  retry lives in the launcher, not the installer, so the red STOP box appears at most once.
* **Upstream rot is now a ten-week runtime dependency.** `nodejs=24.18.1-1nodesource1` is an
  exact apt version, and the pin survives only because NodeSource's nodistro suite retains
  the whole 24.x patch history back to 24.0.0 — checked with `apt-cache madison nodejs` and
  by `HEAD`-ing both arch `.deb`s, not assumed. A distro archive that drops superseded
  packages would have made this pin expire mid-quarter, for every new install at once.
* **`cs193v.buildhash` replaces the digest as the staleness signal**, and it had to: podman
  mints a new image ID on every build, including a rebuild of identical input, so an image
  ID distinguishes "rebuilt" from "not rebuilt" but never "current" from "out of date".

**Measured, on x86-64 with fast network** (a student on dorm wifi is bounded by the
728 MB, not by the CPU):

| | wall | transferred | disk |
|---|---|---|---|
| Cold `--build --no-cache`, nothing to a running container | 224 s | 728 MB | 4.1 GB peak, **4.3 GB retained** |
| `CLAUDE_CODE_VERSION` bump, warm cache | 89 s | 95 MB | — |
| The same bump with the version `ARG`s at the top of the file | 250 s | 726 MB | — |

Three things in that table are worth keeping.

**Retained exceeds peak**, which looks impossible until you see why: creating the container
costs roughly the image's size *again*, because `--userns=keep-id` makes podman write an
ID-mapped copy of every layer (the ~1.5 GB this document's D-series recorded; it is ~2.2 GB
now). That cost lands *after* the build's own peak. It is also a real student-facing failure
mode — a build can succeed and then the create fails with
`creating an ID-mapped copy of layer ...: lchown ...: no space left on device`, naming
neither the cause nor the fact that the build was fine. `err.create-no-disk` now catches it.

**The last two rows are the same bump, differing only in where four `ARG` lines sit.**
buildah folds every in-scope build arg into each step's cache key, so version `ARG`s
declared in a tidy block at the top invalidate the cache for everything below them and the
layer ordering never gets a chance to pay off. Declared at their point of use, the cache
holds through the vercel layer. This was found by measuring a claim that had already been
written down as fact in three places.

**`podman system df` is not a disk measurement.** It reported 2.177 GB where the store on
disk held 6.7 GB. Rootless layer directories are owned by mapped subuids, so a plain `du`
cannot descend into them and silently undercounts — `podman unshare du` is the way to read
them. Size disks from `df` deltas, never from a reported image size.

Still not measured, and now never will be: cold **pull** time.

### ~~B16~~. The STOP box had no right side — **FIXED** (issue #21)

`die()` drew `┏━━ STOP ━━┓` and `┗━━┛`, corners and all, then every body line as `┃ text`
and nothing further. Three walls, in both scripts, since they were written.

**Why nothing caught it.** Two checks in `20-messages.sh` looked like they should have, and
neither could:

- The width lint computed its limit as `box - 2`, which is `"┃ "` and no closing border. It
  encoded the bug as the specification, so the geometry could never fail it.
- `die:all-lines-inside-the-box` counted body lines with `grep -c '┃'`, which counts lines
  **containing** the character and never how many are on one. One wall scored exactly what
  two would.

A third consequence had gone unnoticed for the same reason: `install-cs193v.sh` drew the
box in two places — its `die()` and the Intel-Mac refusal heredoc — and the two had drifted
**a column apart** (69 vs 68). With no right edge there is no width to fail to line up.

**Fix applied:** one `box()` renderer, duplicated verbatim into the installer the way
`version_lt` already is (it is curl-piped and cannot source anything), with the borders
**generated** from a single `BOX_W` rather than typed out. Four hand-drawn copies became
none; `box:launcher-draws-the-box-in-one-place` fails if any grows back, and
`box:both-copies-identical` diffs the two.

Three things that made this more than a padding change:

- **Width is 71, not 69.** The 67-column text field is what A7 already hand-wrapped
  messages.txt to, so widening by two rewrapped **zero** messages. Keeping 69 would have
  meant a text field of 65 and re-breaking 10 lines of prose that a human had chosen the
  breaks for — A7's churn again, to save two columns of an 80-column terminal.
- **Long lines wrap now.** `err.create-failed` and `err.pull-failed` interpolate raw podman
  output, which is written to no width at all and cannot be hand-wrapped in messages.txt.
  A line that already fits is emitted untouched, so every hand-chosen break survives. A
  word with no space in it — a container id, a deep path — is broken hard, because the
  alternative is breaching the wall.
- **Padding is measured in display columns without a locale.** `${#s}` counts characters in
  a UTF-8 locale and **bytes** in the C locale (measured: 32 vs 34 on a line containing an
  em dash), so a student with `LC_ALL=C` would have seen every `—` and `§` line two columns
  short. `awk length()` is worse — mawk is not multibyte-aware and scores the border at 3×,
  which is how A7's first attempt passed vacuously. Stripping UTF-8 continuation bytes
  (`0x80-0xBF`) and counting the rest needs no locale at all; verified byte-identical
  output under gawk, mawk and busybox awk.

### ~~B17~~. `--build` reported itself in podman's voice, and never said it worked — **FIXED** (issues #22, #23, #24)

The longest thing this course asks of a student's computer, as it looked before:

```
STEP 6/23: RUN set -eux;     install -d -m 0755 /etc/apt/keyrings;     curl -fsSL https://deb...
--> Using cache fceef1716e32e78f6958efc4540010e24e49ee22b499a96c71e6a41789551f34
   ... 76 lines of this on a FULLY CACHED build; thousands on a cold one ...
Setting up the course container...
$
```

Three separate complaints, one cause — nobody had ever decided what this command should
print, so it printed podman's stdout and then stopped. Note the last line: the build had
**succeeded**, and the final thing on screen is a progress message with no completion, which
is precisely what an interrupted command looks like.

**Why nothing caught it.** There was no coverage of the build's *output* to miss it with.
The shim tier asserted `--build` calls `podman build` (`shim_count '^build '`) and the live
tier asserted an image exists afterwards; both are about what the launcher **does**, and
neither reads a line of what the student is **shown**. The fake podman helped hide it — its
`build` printed one `Successfully tagged` line, so even a test that had looked would have
seen nothing resembling a real build. It emits real `STEP i/N` lines now.

**Fixed as:** a bar rendered from podman's own step numbering, a spinner on the 180-second
`podman run`, and a green success box. Four things are worth recording beyond the UI:

- **Hiding output made an error message a lie.** `err.build-failed` said "Podman's own
  output is on the screen above this box, ending at the step that failed" — true only for
  as long as the raw output *was* on the screen. The failing tail now goes INSIDE the box.
  This is the half of #23 that is a correctness bug rather than a presentation one, and it
  is only reachable when a build fails, which is when it matters most.
- **Staff can still get the raw output.** Debugging a build needs podman's words as they
  arrive; a bar is the wrong instrument. That split is also what makes hiding the output from
  a student affordable at all. Reached by `--dev-build` at the time; the verb is gone and
  `CS193V_BUILD_RAW=1` is the switch now.
- **Not a terminal → no carriage returns.** A `\r`-redrawn bar in a CI log or a
  `| tee build.txt` is one unreadable line thousands of columns long — and that is the
  exact path a student uses when staff ask them to send the output. Piped, it prints one
  plain line per step.
- **The width lint had a hole the moment a second route into a box existed.** It collected
  its keys by matching `die "$(msg k)"`, so `msg k | celebrate` was unlinted, and the new
  message went in three columns too wide and wrapped mid-sentence ("Run the following
  command to enter the / development environment:"). Caught by eye, not by the suite;
  the lint now matches both routes.

### ~~B18~~. The bar moved but said nothing, and a retry buried it in prose — **FIXED**

B17 gave `--build` a bar. What it did not give it was anything to say. The side text had two
labels — the base-image download and creating the container — and between them, for the whole
build, the row beside the meter was blank. A student watched a bar advance for four minutes
with no idea what it was doing. Three smaller things in the same area:

- the download sat **outside** the bar. Not a decision: the total came from podman's
  `STEP n/N`, which does not arrive until the download has finished, and the meter drew no bar
  without a total. So the longest phase of a cold install on dorm wifi was the one phase with
  no bar;
- a failed step printed three lines of yellow prose **under** the meter, once per attempt,
  and started a fresh bar — leaving a finished-looking bar stranded above a warning about a
  build that usually went on to succeed;
- the closing frame kept a spinner glyph, so a completed install ended on `⣾`, and it filled
  the bar to `tot/tot` **even when the build had failed** — a 100% progress bar directly above
  the words "the course container could not be built".

**Fixed as:** a two-row block — bar, count and a right-aligned `(retrying: n/m)` on one row,
the name of the current step on the other — ending on `✓` with the caption erased, or `✗`
with the bar frozen where it stopped. Step names come from `####>` markers in the
Containerfile. What is worth recording beyond the UI:

- **The labels cannot come from the build output, and that is not a preference.** podman emits
  no comments, and a cache hit prints `--> Using cache` without running the command — so an
  `echo` inside a `RUN` would go silent on precisely the warm builds and retries where a
  student is most likely to be watching. The launcher parses the Containerfile itself, which
  means it numbers that file's instructions and has to agree with buildah about the answer.
- **So the mapping is verified rather than trusted.** podman echoes the instruction on every
  `STEP` line; the launcher compares it with what it parsed and, on any disagreement, drops
  the labels for the rest of the build and records both texts in `$BUILD_LOG`. Deliberately
  **not** fatal: a label is not load-bearing, and dying over one would block a student's
  install, minutes into a cold download, over side text. The disagreement is a hard failure in
  `00-release-gates.sh` instead, where real podman and staff are.
- **Only the first label is shown before podman can confirm it**, and unavoidably: naming the
  download means naming it while podman is still silent. If the parse is wrong the first
  `STEP` line takes every label away, so the exposure is bounded by the download itself.
- **`STEP 23/23` is podman's, not ours.** The Containerfile has 22 instructions; buildah adds
  a `LABEL` step synthesized from the launcher's own `--label cs193v.buildhash` flag. It lands
  *last*, which is why an index→label mapping built from the file is correct for 1-22 without
  the two totals ever having to match. Discovered by reading a real build log, after a count
  of the file said 22 and the meter said 24.
- **A retry holds the bar at the step that failed.** Retries are per-*run* — `build_image`
  re-runs the whole `podman build`, and buildah has no per-step retry — but the layer cache
  replays every completed step in about a second, so that work really is done and on disk.
  Rewinding the bar to 1 would tell a student they had lost twenty minutes they had not.
  Reading the failed step out of `$BUILD_LOG` depends on podman announcing a step *before*
  running it, which is also what made the first version of the fake's failure knob wrong.
- **THE CURSOR STROBED, AND NO TEST COULD HAVE FOUND IT.** The block redraws ten times a second
  and the terminal cursor comes to rest wherever the last write ended — the bar row on one
  frame, the caption row on the next — so a terminal that blinks its cursor flashed it between
  two positions at 10 Hz. The bytes were perfect; every assertion in the suite reads bytes.
  Found by a human running an install and looking at it, which is the entire lesson: a
  transcript cannot show you a display artefact that exists only in time.

  Fixed with `ESC[?25l` / `ESC[?25h` around the meter, and **the restore is the half that
  matters** — exiting with the cursor hidden leaves the student typing blind in that terminal
  afterwards, which is much worse than the strobe. Restored in `meter_stop` *before* the final
  frame (the failure path goes straight into `die` and never comes back) and again from the EXIT
  trap, which bash runs on INT, TERM and HUP as well as normal exit — verified, because Ctrl-C
  during a four-minute build is an ordinary thing to do. The test asserts the *last* cursor
  sequence in the transcript is a show, on both the success and failure routes, rather than
  asserting that hiding happens.

  It also caught a third hole in the same helpers: `render_pty` and `strip_ansi` matched
  `ESC[[0-9;]*[A-Za-z]`, which does not match a private-mode sequence like `ESC[?25l`. Both
  would have passed the sequences straight through into the "rendered screen" that assertions
  read as what the student saw.
- **The test harness had to learn a row cursor first, and this is the important one.**
  `render_pty` replayed `\r`, `\n` and `ESC[K` and silently dropped every other CSI sequence,
  so a meter emitting `ESC[1A` would have had its cursor moves discarded and its two rows
  replayed as unrelated lines. Every screen assertion in `30-launcher-shim.sh` would have gone
  on **passing** against a screen no student ever saw. Failing in the reassuring direction is
  the failure mode this project keeps finding in its own test lib; it is why the replayer grew
  a `(row, col)` cursor in the same change as the meter.
- **Two of those assertions were already passing vacuously** once the block collapsed on
  success: they forbade the label having a row of its own, and the finished block erases that
  row. Re-aimed to assert what the design now means — one bar row, the caption directly under
  it, drawn in the same frame.
- **Content is asserted on the piped form, layout on the pty.** The pty form is sampled by an
  animator at a fixed rate, so which steps get drawn depends on how long each took; a label
  that was correct but held for 40 ms failed an assertion about a display working perfectly.
  Piped output emits one line per step, by the step, so every step is in it exactly once.

### ~~B19~~. Four minutes of a bar that could not say what was *happening* — **FIXED**

B18 gave every step a name. What a student watching a cold build still had was a name that
changed a dozen times in four minutes over a bar that moved a dozen times: honest, calm, and
indistinguishable from a hang during the two-minute stretches when apt or Chromium own the
machine. Meanwhile podman was saying something every few hundred milliseconds, into
`$BUILD_LOG`, where nobody reads it until something has already gone wrong.

**Fixed as:** the block ends in a dim, untitled box holding the last eight lines podman printed,
refreshed three times a second. The animator tails `$BUILD_LOG` — `tee` already writes it before
`build_progress` reads the same stream — rather than being fed by the reader, which has no
portable clock to throttle a per-line state file with (`systime()` is absent from BSD awk) and
could never learn a new width on `WINCH`. The design is in `.private/README.md`.

Three things found on the way, all worth more than the feature:

- **The STOP box has been rendering broken since the failing output was moved inside it.** B17
  put `tail -n 12 "$BUILD_LOG"` into `err.build-failed`, which means `box()` interpolates *raw
  podman output* — and `box()` stripped tabs and nothing else. Fed a realistic build log it comes
  apart two ways: `dw()` measures a colour sequence as the columns its **bytes** would occupy, so
  a line carrying one is padded 11 columns short and drags the right wall in with it; and a `\r`
  sends the rest of the row back to column 0 on the way to the terminal, straight over the wall
  already drawn. apt, npm and the Playwright download all emit both, so this is the *normal* case
  for a build that failed late, not an exotic one. It survived because no line in `messages.txt`
  can contain either, so nothing anybody read by eye would ever show it — it needed a fixture
  built out of what podman actually prints. Both are stripped now, in both copies of `box()`,
  which also covers `err.create-failed` and `err.pull-failed` interpolating a whole failure.

- **`meter_stop` had been racing the animator all along.** It killed the animator and then
  emitted `ESC[1A`, which assumes the cursor is at the end of row 2 — true only when the kill
  landed while the animator was in its `sleep`, which is very nearly always. The rest of the time
  the closing frame went a row too high and overwrote whatever was above the block. Nobody had
  seen it because at two rows tall the damage was one row of a bar that was being redrawn anyway;
  at twelve rows it would be up to eleven rows of it. The animator now exits **cooperatively**
  when the state file goes and leaves the cursor on row 1 on the way out — a postcondition the
  parent can rely on without knowing how tall the block is. It cannot know: the height comes from
  the terminal size, `WINCH` is handled in the animator, and the parent is blocked inside podman
  for the entire four minutes during which a student might resize the window.
- **`render_pty` would have passed every new assertion vacuously, for the third time.** It models
  the sequences it has been taught and silently strips the rest, and the box is taken off the
  screen with `ESC[J`. Unmodelled, that erase does nothing to the replayed screen — so "the box is
  gone by the end" would have read a screen that still had it, and "how many boxes are on screen"
  would have quietly answered two. Failing in the reassuring direction, in the same file, in the
  same way as B18's `ESC[1A` and the two vacuous assertions before it. `ESC[J` is modelled now.

One deliberate reversal, recorded so that nobody later reads it as a slip: **the box shows the
`Copying blob` chatter that `build_progress` collapses to a single note.** Per-layer,
per-percentage lines are noise beside a bar, and they are also the only thing moving during the
base-image download — the longest phase of a cold install and the one with nothing else to watch.

---

## C. Not run, and why

- **Anything needing `sudo`** — the instructor was away and could not authenticate. Nothing
  in the suite needs it; noted only because §1.5's *real* `sudo ./cs193v` check is
  unreachable. The launcher's root refusal is covered instead by faking `id` in the shim
  tier, which exercises the same branch. `unshare -r` is not usable here (writing
  `/proc/self/uid_map` is not permitted in this sandbox).
- **`--rebuild --logout`'s volume deletion** — gated behind `CS193V_DESTRUCTIVE=1` so a normal
  run can never log anyone out. Re-run with that set to cover §2.4 and §9.2.
- **Multi-arch manifest (§A.2)** — a locally built image is single-arch by definition. Moved
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

> **SUPERSEDED AS ADVICE BY ISSUE #41, BUT NOT AS MEASUREMENT.** Everything below is still an
> accurate account of what conmon and podman do, and it is still what `70-sighup.sh` records.
> What changed is the conclusion drawn from it.
>
> The finding here — that nothing dies when the exec client goes away — was originally read as
> good news, and the design leaned on it: the container outlived every window and the next
> `./cs193v` reattached you to your tabs. #41 reversed that judgement. Closing a window is the
> universal gesture for "I am done", and a design where it provably means *nothing* leaves a
> student with servers running in a container they have forgotten is up.
>
> So the launcher now stops the container when its terminal goes away. The measurement below is
> **why that has to be done from the host**: nothing inside the container can detect a closed
> window at all. The client does not die, the pty stays open, and tmux reports the session
> attached indefinitely — so `destroy-unattached on` would not fire, and no in-container
> mechanism could substitute. The only party that can tell is the process the window actually
> kills, which is the launcher. See `open_shell`/`shell_teardown` in `cs193v`, and the rewritten
> `70-sighup.sh`.
>
> The four-shape matrix is still measured, now under `sighup:tab-matrix-*`, and still comes back
> `alive=yes` for all four. It answers "what happens when a TAB closes" rather than a window. The
> old `setsid`-survives assertion is **deleted**: advising a student to detach a server with
> `setsid` would be advising them to do something the container's own lifetime undoes.

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

**This measurement now has a second dependency, and it is a config setting.** The landing
point is tmux, so a student's server is a process inside a tmux pane rather than a direct
child of the `podman exec` client — and whether it survives is decided by
`destroy-unattached`, not by conmon. The prototype this configuration came from set it
**on**, which destroys a session the instant its last client goes away: that would have
killed every pane, and therefore every server, and turned the whole of D1 into "no, closing
the window kills your work" without anything in the tree recording that it had changed.

`files/tmux/tmux.conf` sets `destroy-unattached off` for exactly this reason, and says so
where it sits. `70-sighup.sh` asserts the tmux shape alongside the five original ones, so
flipping it back breaks a test rather than a student's afternoon. What the reattach design
adds on top is that the orphaned session is not merely alive but *recoverable*: the next
`./cs193v` attaches to it, because cs193v-shell prefers a session with no client.

**Post-#41 footnote on that last paragraph.** The reattach half is gone — `cs193v-shell` now
claims one fixed session name and refuses a duplicate — but `destroy-unattached` is still `off`,
and the reasoning above is *not* why any more. The current reason is narrower and easier to get
wrong: setting it `on` would not fire on a closed window (per the measurement at the top of this
entry, the client does not die), so it would buy nothing against the case it appears to address,
while newly breaking the case it does reach — closing one **tab** briefly leaves the session
unattached, and `on` would destroy the session and every other tab with it. The comment in
`files/tmux/tmux.conf` says this where it sits, so nobody re-derives the old argument and then
"simplifies" the setting on the strength of it.

### D0. systemd's prompt hook silently disabled every tab label

**Found by the ported screen suite, and it would have shipped.** `files/tmux/tabname.bash`
adds the second word to a tab label (`sudo apt install` rather than `sudo`) from a bash
`DEBUG` trap, armed once per prompt by a `PROMPT_COMMAND` entry so that only the command the
student actually typed can relabel. On Ubuntu 26.04 the arming flag was being spent before
the student's command ever arrived:

```
armed=0 cmd=[_cs193v_precmd]                    <- ours, arms the hook
armed=1 cmd=[__systemd_osc_context_precmdline]  <- systemd's, spends it
armed=0 cmd=[sudo python3 ...]                  <- the real command, disarmed
```

bash 5.1+ makes `PROMPT_COMMAND` an **array**, and this image ends up with two entries:

```
declare -a PROMPT_COMMAND=([0]="_cs193v_precmd" [1]="__systemd_osc_context_precmdline")
```

Ours is element 0 and can only ever be element 0, because `/etc/profile` sources
`/etc/bash.bashrc` — where the hook is wired — *before* the `profile.d` loop that brings in
systemd's shell integration. So systemd's entry always runs after ours.

The symptom was total and silent: every label fell back to tmux's one-word default, which is
also what you get with no hook at all, so nothing looked broken. The prototype never saw it
because it installed the hook with `default-command 'bash --rcfile … -i'` — a non-login
shell, which reads neither `/etc/profile` nor `profile.d`.

The fix skips any `$BASH_COMMAND` that is itself an entry in `PROMPT_COMMAND`, and skips it
*without* disarming. Matching against `PROMPT_COMMAND` rather than naming systemd's function
means the next release can ship a different prompt hook without this quietly breaking again.

Two things worth keeping from this. **A non-login shell and a login shell are not
interchangeable for testing shell integration** — `/etc/profile` and `profile.d` only run for
the latter, and that is what a student gets. And the same difference caused a second, separate
failure in the suite: Debian's `/etc/profile` **assigns** `PATH` rather than appending to it,
so a `PATH` exported into tmux's environment is gone by the time the first prompt appears.

### D1a. A closed window leaves the tmux client attached — forever

**Measured, and it is the more surprising half of D1.** Killing the host-side `podman exec`
client does not kill the tmux *client* inside the container. conmon keeps the exec session's
pty open, so the in-container client stays blocked reading it and tmux goes on reporting the
session as attached. Not for a few seconds — indefinitely; sessions from tests minutes
earlier were still `attached=1`.

```
  PID  PPID STAT TTY    COMMAND
  926     0 Ss+  pts/0  /bin/bash /usr/local/bin/cs193v-shell      <- host client long gone
  931   926 S+   pts/0  tmux ... new-session -s cs193v-1           <- the client, still attached
  933     1 Ss   ?      tmux ... (the server)
```

**Nothing inside the container can tell this apart from a live client.** Both were checked:
the pty still exists, is still readable, and is still *writable* (`printf "" > /dev/pts/0`
succeeds on the dead one), and `ppid` is 0 for a live and a dead one alike, because the
parent is outside the pid namespace either way.

Left alone this silently breaks the thing tabs exist for. `cs193v-shell` attaches to a
session only if it has no client, so it would never find one, every launch would build a
fresh session, and the student's real tabs would pile up unreachable behind a ghost — the
exact "invisible orphaned session" failure that `destroy-unattached on` was meant to prevent.

The fix *was* `prune_stale_tmux_clients` in `./cs193v`, and it had to live on the **host**
because the host is the only side that can tell: the client is a `podman exec` process it
started itself. `cs193v-shell` stamped each session with `@cs193v_host_pid`, and the next
launch detached any session whose recorded pid was gone (`kill -0` plus a `ps | grep podman`
guard against pid reuse).

**All of that is deleted, and issue #41 is why.** The prune existed to serve reattachment — it
made an orphaned session findable so the next launch could adopt it. Nothing reattaches now: the
container stops when the terminal does, so there is no orphaned session to prune, and the stamp,
the liveness check and the prune went together.

**The measurement above is not obsolete, though — it is now load-bearing for something else.**
Because nothing inside the container can distinguish a dead client from a live one, no
in-container mechanism can implement "stop when the window closes" *at all*: not
`destroy-unattached`, not tmux's client tracking, not a watchdog. That is precisely why the
teardown lives on the host, as a SIGHUP trap in `open_shell`. This entry is the reason that design
is not over-engineering.

`60-container.sh` still asserts the conmon behaviour itself — **if that assertion ever starts
failing it is good news**, because clients dying on their own would make `destroy-unattached on` a
viable second line of defence.

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

**Now YES — 200. This answer is deliberately the opposite of what it used to be.**

The original measurement stands as a description of `podman run -p`: connection refused,
because the forwarder publishes to the container's `eth0` and never touches its `lo`. That
was the central ports lesson, and it cost `--host 0.0.0.0` on every command for ten weeks.

The launcher now forwards the course ports over an ssh tunnel into the container's own
loopback instead, so the same test returns **200**, and a `0.0.0.0`-bound server still
returns 200 as well — the tunnel is a strict superset of what publishing did. The host side
is still loopback-only, now structurally rather than by flag: the ssh client binds
`127.0.0.1` itself. Verified unreachable from this machine's own LAN address (`10.0.2.15`).

The one bind address that is still refused is **`::1` alone** — the forward's far end is
IPv4. That is narrow in practice: `localhost` resolves to `127.0.0.1` and nothing else in
this image (no `::1 localhost` line in `/etc/hosts`), so both
`python3 -m http.server --bind localhost` and node's `listen(port, "localhost")` bind IPv4.
This also corrects a claim that was documented here for a while — that binding "localhost"
lands on `::1` — which was never true for this image.

### D4a. The tunnel, measured

Ubuntu 26.04 native, rootless podman 5.7.0, OpenSSH 10.2p1 on both ends.

**Does `sshd -i` work?** Yes, and **unprivileged**. `podman exec -i <ctr> /usr/sbin/sshd -i
-f <conf>` authenticates and runs as `student` with no `-u 0`. OpenSSH 9.8 split sshd into
`sshd`/`sshd-session` and 10.0 added `sshd-auth`; inetd mode survives it. `/run/sshd` comes
with the package and was not needed. This was the gate for the whole design — the fallback
was an sshd on a published TCP port — and it passed, so the fallback was never built.

| | |
| --- | --- |
| forwarded channel throughput | **322 MB/s** (300 MB in 0.98 s) |
| pasta published port, same server | 2.53 GB/s |
| ssh session channel over the same pipe | 363 MB/s |
| latency, 50 sequential connections, tunnel | **12.1 ms** each |
| latency, same, published port | 12.6 ms each |
| small requests while 300 MB is in flight | 11.2 ms (vs 11.4 ms idle) |
| 46 forwards, one connection | one ssh pid owns all 46; up in 570 ms |
| tunnel start, wall clock | ~600 ms |

Bulk transfer is ~8× slower than pasta and still 2.6 Gbit/s, so a 5 MB bundle costs ~15 ms.
**Latency is indistinguishable**, which is the number that matters and the reason this is ssh
rather than a socat relay: a new TCP connection becomes a new SSH channel over the existing
connection, not a new `podman exec` at 158 ms (D9). Head-of-line blocking was looked for and
not found — per-channel flow control does its job.

`MaxSessions` does **not** cap `direct-tcpip` forwards, so 46 is not near any limit.

**Security invariants, tested rather than asserted.** An attempted `-R` is refused with
`administratively prohibited` and creates **zero** listeners, enforced by
`AllowTcpForwarding local` in the server's own config rather than by the client's flags.
Forwarding to an off-box address is refused at channel-open by `PermitOpen 127.0.0.1:*`,
while the container's own direct egress to that same address still works (301) — so the
refusal is the config, not the network. The read-only `authorized_keys` mount cannot be
written (`EROFS`) or unlinked (`EPERM`) from inside.

**Lifecycle.** Killing the container underneath a live tunnel frees every host port in
**under 1 s**: the `podman exec` pipe closes and ssh exits, with no help from
`ServerAliveInterval` (which is kept for a *wedged* rather than closed pipe — a frozen
machine VM on macOS). A tunnel SIGSTOPped so it can never answer `-O exit` is recovered by
**every** teardown, not only `cs193v --reset-tunnel`: `tunnel_down` time-boxes the clean path
and forces when the box expires, so `--rebuild`, `--stop` and the end of a session all hand the
ports back. It did not always. Measured before that changed, with a master SIGSTOPped:
`--rebuild` spent 10 s in the timeout, deleted the pidfile without killing what it named, and
left `doctor` reporting the tunnel **down** while all 46 ports were still bound — with nothing
left for `--reset-tunnel` to force, and the student advised to look for another program on their
computer. The kill checks the process's own command line for the control socket first, because a
pidfile outlives its process and pids are reused. A host
port already held by another program costs **that port only**, named in the output, where
`podman run -p` used to fail outright and take the whole container with it.

**Zombies: exactly 1 while a tunnel is up, 0 with none, and 8 tunnel cycles accumulated
none.** `ps -o ppid` shows its parent is sshd's privsep monitor *inside* the container, alive
for the tunnel's lifetime — so it is never reparented to PID 1 and no PID 1 could reap it.
(It is a child that monitor forked, not the monitor itself: re-measured on OpenSSH 10.2p1, the
zombie carries `comm sshd` while its parent carries `comm sshd-session`, so the process that
re-exec'd is the parent. `README.md`'s `--init` item had this the wrong way round and now has
the tree.) **The ppid is the discriminator, not the count**: `doctor` reports
`0 unreaped, 1 held by a live parent`, and asking for a bare `grep -c Z` instead is what made
`pid1:no-zombies-right-now` fail on healthy containers (#102).

**Not verified, no hardware:** macOS (the gvproxy leg, where `--host-lo-to-ns-lo` silently
failed) and WSL2 (whether Windows' localhost forwarding reaches an ssh-bound `127.0.0.1`
listener the way it reaches a pasta-bound one — `container.args` establishes it does for
pasta, citing podman#17972 and #22562).

**Incidental, and it bit during this work:** `--userns=keep-id` makes podman create an
ID-mapped copy of the image layers (`storage-chown-by-maps`), and it does not appear to share
those between image tags that share layers. Each new tag therefore costs roughly another full
image (~1.5 GB), not a thin layer. This machine hit "no space left on device" at 95% full on
the first attempt to run a derived image.

### D5. cgroup delegation — is `memory.max` the cap, or `max`?

**The cap, exactly.** `--memory=1024m` yields `memory.max = 1073741824`. The `pids` cap is
podman's default 2048 and is enforced (`sh: 0: Cannot fork` at `--pids-limit 64`). An OOM is
clean: the process is `Killed` with **exit 137**, the container stays `running`, and
`podman exec` still works.

This answers §5.5 for **Linux only**. WSL with `systemd=true` is the case that still needs
checking, and it is the one where the answer might be `max`.

### D6. The LSM label — AppArmor on this machine, SELinux on the next one

`/proc/self/attr/current` reads exactly **`crun (unconfined)`**, confirming the design doc's
claim verbatim. AppArmor is not confining this container.

**Second platform, measured later — issue #131.** Fedora 44, podman 5.8.4, crun 1.28, SELinux
`Enforcing`, 2026-09-02: the same read returns **`system_u:system_r:container_t:s0:c483,c562`**,
with a trailing NUL after it. That file is whichever LSM the **host** has and not a property of
the image, so neither value is a measurement of the container — the claim above was true of the
machine this pass ran on. And `container_t` with MCS categories is real type enforcement, which
is *more* than the Ubuntu answer rather than less, so a check expecting the Ubuntu string went
red on the better value. Nothing asserts either string now: `60-container.sh` records
`kernel:lsm-label-applied` and `VERIFICATION.md` §A.5 records `lsm-label`.

### D7. `/proc` is not cgroup-aware

`free=3398MB cgroup=1024MB`. A student running `free` inside sees the host's RAM, not their
limit, so nothing in `/proc` can tell them what their cap actually is.

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
| launcher overhead (`--dev-print-command`) | 511 ms → **~60 ms** after D10 |
| `podman exec` overhead | 158 ms |
| 2000 files created on the bind mount | < 1 s |
| case sensitivity | case-sensitive |
| `tput colors` with `-e TERM` forwarded | 256 |
| `tput colors` without forwarding | **8** — proves §A.5's original probe was broken |
| zombies after 5 killed exec clients | 0 beyond the baseline |
| image size | 1.74 GB |

### D10. Where the launcher's 511 ms of "overhead" actually went

`--dev-print-command` makes **no podman calls at all** — it is `load_args`, `build_run_args` and a
`printf` — and it measured 583–781 ms. All but ~60 ms of that was one line.

`load_args` trimmed each line with `sed` in a command substitution, and it did the trim **before**
testing whether the line had anything on it:

```sh
line="${line%%#*}"                                    # a comment line is now empty
line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
[ -z "$line" ] && continue                            # ...but the test came AFTER the sed
```

`container.args` is 239 lines, of which **228 are a comment or blank and 11 carry an argument**, so a
launch forked `sed` 239 times to trim strings that were already empty. Counted with
`strace -f -e trace=execve`: exactly 239 `sed` execs per parse, now 11. Measured on the shipped file:

| form | wall clock | `sed` execs |
| --- | --- | --- |
| as written | 691–1137 ms | 239 |
| `[ -z "$line" ]` moved above the trim | 45–64 ms | 11 |
| **a `case "$line" in *[![:space:]]*)` guard above the trim** | **29–64 ms** | **11** |
| the trim replaced by pure bash, no fork | 18–20 ms | 0 |
| one `sed` for the whole file via `< <(sed …)` | 28–36 ms | 1 |

**Why the whitespace guard rather than moving `[ -z ]`.** Both leave 11 forks on the file as it
stands and both parse identically. `[ -z ]` skips only the *already empty* lines, so it holds only
while the comments start in column 1 — indenting that 228-line block, a reflow rather than a semantic
edit, puts **230** forks back. The whitespace test asks the question the code means, so the answer does
not depend on the file's layout. `16-args-parse.sh` has the case, and it fails on the `[ -z ]` variant.

**The trim was kept, and two things about it are worth writing down.**

*It is not what protects podman from a stray `\r`.* Deleting `[ -z "$line" ] && continue` outright,
changing nothing else, gives byte-identical output on a CRLF fixture holding a blank line, a
whitespace-only line, a column-1 comment and an indented comment. The trim removes the `\r`, and an
emptied `$line` then splits into zero fields. The guard is an optimisation, not a correctness gate —
which is why it should say what it means rather than test for emptiness.

*Default IFS is space, tab and newline ONLY,* so `\r`, `\v` and `\f` are **not** field separators.
An *untrimmed* `"\r"` splits into ONE field — a bare `\r` — where `"   "` splits into none:

| `$line` | fields from `for word in $line` |
| --- | --- |
| `"   "` | 0 |
| `""` | 0 |
| `"\r"` | **1** |
| `" \t\v\f\r "` | **1** |

Nothing depends on that today, because the trim always runs first. It is the trap waiting for whoever
replaces the `sed` with parameter expansion: a bash trim covering only space and tab would put a bare
`\r` on the `podman run` line for every blank line of a CRLF `local.args`, which is what a person
editing that git-ignored file on Windows produces. The replacement measured 18–20 ms and was rejected
for exactly this reason — ~30 ms is not worth owning `[[:space:]]`'s definition while `preflight` still
carries ~570 ms (D11).

**Also found, not fixed:** if `sed` is missing or broken, `load_args` yields an empty `ARGS` and the
container is created with no volumes, ports or memory cap, reporting nothing. Verified identical before
and after this change, so it is neither caused nor fixed here.

### D11. `podman info` costs ~570 ms, and 48 `dpkg` processes are why

`preflight` calls `pm info --format '{{.Host.Security.Rootless}}'`, which looks like a field lookup and
is not: podman builds the whole info struct regardless of `--format`, and on Debian/Ubuntu that means
asking `dpkg` which package owns each helper binary. From `strace -f -tt -e trace=execve`:

```
/usr/bin/dpkg -S /usr/lib/podman/netavark      -> 6 x dpkg-query --search + 1 dpkg-query -W
/usr/bin/dpkg -S /usr/lib/podman/aardvark-dns  -> same
/usr/bin/dpkg -S /usr/bin/slirp4netns          -> same
/usr/bin/dpkg -S /usr/bin/pasta                -> same
/usr/bin/dpkg -S /usr/bin/crun                 -> same
/usr/bin/dpkg -S /usr/bin/conmon               -> same
```

48 processes, and one `dpkg -S` alone measures 66–103 ms.

| probe | measured |
| --- | --- |
| `podman info --format '{{.Host.Security.Rootless}}'` | **536–1222 ms** |
| `podman info` unformatted | 564–623 ms — `--format` saves nothing |
| `podman --version` | 17–26 ms |
| `podman inspect … --format` | 25–63 ms |
| `podman image exists` | 21–37 ms |
| `podman system connection list` | 17–24 ms |

`podman info --help` offers only `--format`: there is no flag that skips the package lookup, so the
call has to move or be cached rather than tuned. **Not done** — the answers do not change between
launches, but `err.rootful` and `err.podman-unreachable` depend on it and a macOS machine can be
rootful, so it needs its own change. With `load_args` fixed this is the largest single item left in the
~1 s a bare `./cs193v` spends between announcing itself and opening a shell — and the launcher now
says `Entering the CS193V development environment...` before any of it, so what is left is a wait a
student can see rather than silence they have to interpret (issue #57). The number is still worth
taking, but nobody is now staring at a blank screen while it is paid.

Two smaller ones measured alongside it, also not done: `run_timeout` costs **21 ms per call** in
`mktemp` + `mkfifo` + two subshells + `cat` + `rm` before podman starts (217 ms for ten calls around
`true`, and a launch makes ~10 probes), and three probes are asked twice — `refuse_if_foreign_dir` from
both dispatch and `ensure_container`, `state()` likewise, and `podman image exists` from both
`require_image` and `recipe_moved`. One `podman inspect` returning state and both labels together
measures **34–37 ms** against **84–106 ms** for the three separate calls.
