# Working on the CS193V container

Read this before running `./cs193v` or the test suite. The first item is a hazard that costs
real debugging time and is not visible from the code. The second is here because it used to be
one, and the instructions it replaced are still in people's heads.

## 1. Set `CS193V_INSTANCE` first

```sh
export CS193V_INSTANCE=yourname   # letters, digits, - and _ only
```

Several people develop this container on one machine.
The variable suffixes the **container name, the dev image tag, and all seven volumes
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

## 2. You no longer have to move your ports

Nothing declares ports. The launcher watches what your container is listening on and opens the
matching port on your own loopback about a second later, so there is no list in `container.args`,
nothing to override in `.config/local.args`, and no recreate to remember.

**Two instances cannot collide the way they used to.** Overlap used to be total by construction —
every instance forwarded the same 46 ports whether or not anything was listening on them. Now a
port is only taken when something inside your container is actually serving on it, and the test
suite picks its ports from what is free at that moment (`dyn_free_port` in `tests/lib/assert.sh`),
so two suites running side by side step over each other automatically.

**What can still collide is software with a popular default.** If both of you run vite, you both
want 5173, and the second one to bind loses the host port. That failure is now per-port and
mid-session rather than at launch, and it is reported rather than silent:

```
$ cs193v doctor
  dynamic ports    1 forwarded: 3000
  dynamic ports    1 busy: 5173 — another program on this computer holds those
```

`busy` is the one refusal that clears itself: quit the other program, or start yours on a
different port, and the next tick picks it up. From inside the container, `cs193v-portwatch --show`
answers the same question.

Closing your terminal window stops your container *and* takes its tunnel down, handing its ports
back — so a tunnel left over from a session somebody finished with hours ago is not the cause.

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
