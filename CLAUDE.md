# Working on the CS193V container

Read this before running `./cs193v` or the test suite. Both hazards below cost real
debugging time and neither is visible from the code.

## 1. Set `CS193V_INSTANCE` first

```sh
export CS193V_INSTANCE=yourname   # letters, digits, - and _ only
```

Several people develop this container on one machine.
The variable suffixes the **container name, the dev image tag, and all six volumes
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

## 2. Move your ports in `.config/local.args`

`CS193V_PORTS` is **not** a shell variable — exporting it does nothing. It is a `-e` line in
the args files, and `.config/local.args` (git-ignored) is read after `container.args`, last
occurrence winning:

```
-e CS193V_PORTS=13000-13002,13005
```

`CS193V_INSTANCE` does not namespace host ports, so without this every instance competes for
the same set. Pick a small set that overlaps nobody — comma-separated ports and ranges, **at
least two**: `fwd_init` in `tests/lib/assert.sh` hard-fails the port-aware suites below that,
because assertions need a second port to hold while the first is bound. A malformed chunk is
warned about and skipped rather than fatal, so a typo silently shrinks your set.

**Recreate the container after moving them** (`./cs193v --rebuild`). `-e` is applied at create
time and `podman start` reuses the stored value, so an edit with no recreate leaves the
container naming one set while the tunnel forwards another. `60-container.sh` asserts they agree.

The tests follow the override automatically — they read the expanded list out of
`cs193v --dev-tunnel`, so no test names a port. If a port or ssh-forwarding test fails, check
what else is running on this machine before assuming the fault is yours.

Closing your terminal window stops your container *and* takes its tunnel down, handing its
ports back — so the usual cause of a phantom conflict, a tunnel from a session somebody
finished with hours ago, largely stops happening.

## Where things live

`.private/README.md` is the staff guide — layout, development loop, and the decisions this
project has deliberately made and un-made. Read it before proposing anything structural;
several tempting ideas are recorded there as already tried and rejected, with the
measurement that killed them.

## How to design tests

Always red-first with tests: write the tests, watch them fail, then confirm your fix causes the tests to pass.

## How to run tests

Don't pipe the tests through head or tail; you can't read all the results if there's a failure. Instead, redirect the output of the tests to a file, read that file, then clean it up when you're done.

## How to write commits and PRs

Previous commits and PRs were extremely verbose. That's unnecessary here. Be concise about what the commit or PR does; one paragraph max.
