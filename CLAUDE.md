# Working on the CS193V container

Read this before running `./cs193v` or the test suite. Both hazards below cost real
debugging time and neither is visible from the code.

## 1. Set `CS193V_INSTANCE` first

```sh
export CS193V_INSTANCE=yourname     # letters, digits, - and _ only
```

Several people — and several Claude Code sessions — develop this container on one machine.
The variable suffixes the **container name, the dev image tag, and all five volumes
together**. `.private/tests/lib/assert.sh` mirrors the same suffix, so `run-tests.sh`
follows automatically.

Without it you share `cs193v`, `localhost/cs193v:local` and the volumes with whoever else is
working. The failure is not a clean collision but a slow one: whoever ran `--rebuild`
last owns the container you are about to shell into, and either person's `--rebuild --logout`
deletes the other's logins.

- Pick a name nobody is using — check `podman ps -a` and `podman images` for `cs193v-*`.
- Use `./cs193v --rebuild`, not a bare `podman build`. It suffixes the tag for you, and
  it is the only path that applies the `cs193v.buildhash` label the launcher checks for
  staleness; `podman build -t localhost/cs193v:local` clobbers the shared one and produces
  an unlabelled image that silently never prompts for a rebuild.
- **`--rebuild` builds only when the recipe moved.** It compares `cs193v.buildhash` against the
  Containerfile and `files/` on disk, so it is a two-second recreate when they agree and a full
  build when they do not. Force one with `--rebuild --no-cache`; watch podman's raw output
  instead of the progress bar with `CS193V_BUILD_RAW=1`.

## 2. Host ports are NOT namespaced, and that produces failures you did not cause

`CS193V_INSTANCE` does not suffix the 46 forwarded ports — they are a fixed list, the same
for every instance. The launcher's ssh tunnel binds `127.0.0.1:<port>` for each one, so
**the first instance to start wins and any other gets none of them**. The losing instance
still starts and works normally; it just cannot forward.

Every test that reaches a server through a forwarded port then fails, for that reason
alone, with nothing wrong in your change. This is the single most likely explanation for a
port or tunnel failure appearing "because of" an edit that could not possibly affect it.

**Check that before you blame your change:**

```sh
./cs193v doctor          # look at the "tunnel ports" line: "0 of 46 forwarded ...
                         # another program on this computer holds those"
ss -ltnp | grep :3000    # the ssh process's -i path names the checkout that owns them
```

Do not kill the other developer's tunnel. To get out of the way, override `CS193V_PORTS` in
`.config/local.args` (git-ignored, read **after** `container.args`, last occurrence wins):

```
-e CS193V_PORTS=13000-13009,14173-14176,15173-15179,16173-16182,18000-18009,18080-18084
```

That moves both the forwards and what the in-container `ports` command expects.

**This got a lot better with issue #41, but it did not go away.** Closing your terminal window now
stops your container *and* takes its tunnel down, handing all 46 ports back — so the usual cause of
this, a tunnel from a session somebody finished with hours ago, largely stops happening. Two
instances that are *both live right now* still collide exactly as described above.

Two related consequences for working here:

- **A container running with nothing attached to it is now an anomaly**, not the normal state.
  `./cs193v doctor` says so and points at `./cs193v --stop`. It means a terminal was force-quit, or
  a launcher was killed without its trap running.
- **A second `./cs193v` against your own live session is refused**, not given a second session. If
  you forget `CS193V_INSTANCE` while someone else is working, you now find out immediately instead
  of silently sharing their container.

## Also worth knowing

- **Disk is tight.** An interrupted `podman build` or `podman pull` fails loudly, but can
  leave damaged storage that outlives the failure. `podman system check --quick` is ~0.2 s
  and worth running if podman starts behaving strangely; the full check is slow and reports
  mtime-only false positives, so do not reach for `--repair` on its say-so.

## Where things live

`.private/README.md` is the staff guide — layout, development loop, and the decisions this
project has deliberately made and un-made. Read it before proposing anything structural;
several tempting ideas are recorded there as already tried and rejected, with the
measurement that killed them.
