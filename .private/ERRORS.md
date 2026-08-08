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
| `IMAGE=` | **Not a blank.** Empty is the normal state and means "build locally"; a value is an optional override that still pulls. |
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

The fix is `prune_stale_tmux_clients` in `./cs193v`, and it has to live on the **host**
because the host is the only side that can tell: the client is a `podman exec` process it
started itself. `cs193v-shell` stamps each session with `@cs193v_host_pid`, and the next
launch detaches any session whose recorded pid is gone (checked with `kill -0` plus a
`ps | grep podman` guard against pid reuse). `60-container.sh` asserts the whole chain,
including the conmon behaviour itself — **if that assertion ever starts failing it is good
news**, because it means clients die on their own now and the prune can be deleted.

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
This also corrects a claim `files/ports` used to make in its own docstring — that binding
"localhost" lands on `::1` — which was not true for this image.

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
machine VM on macOS). A tunnel SIGSTOPped so it can never answer `-O exit` is still
recovered by `cs193v --reset-tunnel`, which time-boxes the clean path and then kills. A host
port already held by another program costs **that port only**, named in the output, where
`podman run -p` used to fail outright and take the whole container with it.

**Zombies: exactly 1 while a tunnel is up, 0 with none, and 8 tunnel cycles accumulated
none.** It is sshd's own re-exec'd process, and `ps -o ppid` shows its parent is sshd's
privsep monitor *inside* the container, alive for the tunnel's lifetime — so it is never
reparented to PID 1 and no PID 1 could reap it. `doctor` reports a zombie count, so **1 is
expected** now rather than a fault. See `README.md`'s open item on `--init`.

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
