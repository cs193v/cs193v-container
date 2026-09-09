# Working on the CS193V container

Read this before running `./cs193v` or the test suite.

## Set `CS193V_INSTANCE` before developing

```sh
export CS193V_INSTANCE=yourname   # letters, digits, - and _ only
```

Several people develop this container on one machine.
The variable suffixes the **container name, the dev image tag, and all seven volumes
together**. `.private/tests/lib/assert.sh` mirrors the same suffix, so
`.private/tests/run-tests.sh` follows automatically.

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

## Port collisions

The cs193v launcher watches what your container is listening on and opens the
matching port on your own loopback about a second later.

If you and another developer each run vite, you both want 5173, and the second one to bind
loses the host port. That failure is per-port and reported via `cs193v doctor`:

```
$ cs193v doctor
  dynamic ports    1 forwarded: 3000
  dynamic ports    1 busy: 5173 — another program on this computer holds those
```

`busy` is the one refusal that clears itself: quit the other program, or start yours on a
different port, and the next tick picks it up. The rest — `capped`, `v6lo`, `loalt`, `eth` and
`below-floor` — need you to change something, and doctor prints what alongside each one. From
inside the container, `cs193v-portwatch --show` answers the same question.

Closing your terminal window stops your container *and* takes its tunnel down,
handing its ports back.

## Where things live

`.private/README.md` is the staff guide — layout, development loop, and the decisions this
project has deliberately made and un-made. Read it before proposing anything structural;
several tempting ideas are recorded there as already tried and rejected, with the
measurement that killed them.

## How to run tests

`.private/tests/run-tests.sh` is the entry point. Narrow before you go wide:

```
.private/tests/run-tests.sh --list           # what exists, in which tier, in which lane
.private/tests/run-tests.sh --tier static    # no podman, no image, no network — milliseconds
.private/tests/run-tests.sh -k 16-args       # only suites whose filename matches
.private/tests/run-tests.sh                  # the default tiers: not release, github or windows
```

Don't reach for `--everything-but-github` to check your own work: it rebuilds first, budgets
about 15 GB and a long wall clock, and its last cost gate logs you out of claude, codex, gh
and vercel.

**Redirect the output to a file and read the file.** Don't pipe it through `head` or `tail` —
that's how a failure ends up scrolled past instead of read. Write the file outside the working
tree: `$TMPDIR`, or your scratchpad directory if you have one. Nothing in `.gitignore` covers
logs, so one dropped beside the tests shows up in `git status` and eventually in somebody's
commit. Delete it once you've read it.

The suite's own per-run directory — `$TMPDIR/cs193v-runlog.<pid>`, holding `results.tsv`,
`timings.tsv` and `crashes.tsv` — is not yours to clean up. It sweeps the leftovers of any run
whose process is gone, and a live one belongs to somebody's concurrent run.

If interleaved parallel output is what's making a failure hard to read, re-run the one suite
with `-k` before reaching for `--serial`.

## How to design tests

Always red-first with tests: write the tests, watch them fail, then confirm your fix causes the tests to pass.

After writing a new test or changing an existing test, always perform a mutation test by hand to make sure that your tests are non-vacuous and cover the correct behavior: break the behaviour the test claims to check, watch that test go red, then revert the mutation. Many GitHub issues filed on this project are the results of vacuous tests. If you find that an existing test is broken / vacuous this way, offer to file an issue on GitHub and to fix it as part of the PR you are working on.

## How to write commits and PRs

Previous commits and PRs were extremely verbose. That's unnecessary here. Be concise about what the commit or PR does; one paragraph max.

## Synchronization

Never sleep to synchronize with another process, job or thread — don't sleep for a container
to come up, a port to bind, or a file to appear. Wait for the thing itself: `wait_until SECS CMD`
in `.private/tests/lib/assert.sh` is the helper, and its ceiling is a failure bound rather than
a delay you pay on a passing run. A loop that ticks as the system's normal operation — portwatch
refreshing once a second — is not this; it isn't waiting for anything.

**Proving that nothing happened is the exception, and it keeps its fixed sleep.** Polling for an
absence succeeds the instant the thing is absent, which for something that was never there is
immediately — so a check that a killed server stayed dead, or that a stray key changed nothing,
has to wait a while and then look. Say so at the call site, the way the existing ones do.

## Cleaning up messes

Always offer to remove any podman containers, images, or volumes you create in the course of development work after you finish a task.
