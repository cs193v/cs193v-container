#!/usr/bin/env bash
# TIER: shim
#
# The launcher's state machine and every refusal path, driven against a fake podman.
#
# This covers VERIFICATION.md §1.4, §1.5, §1.7, §2.1, §2.2, §2.5, §2.6, §2.7 and the
# §A.10 launcher checks, with no container created and nothing installed. That matters for
# two reasons: these are the paths that decide whether a student gets a comprehensible
# error or a raw podman one, and they are unreachable from a working machine — you cannot
# test "podman is too old" on a machine with a current podman.
#
# §A.10's own version of the verb loop hangs, because `cs193v` with no verb ends in
# `exec podman exec -it` and it left stdin on the terminal. Everything here closes stdin.

set -u
. "$(dirname -- "$0")/lib/assert.sh"
. "$(dirname -- "$0")/lib/podman-shim.sh"

require_cmd script "needed to drive the arrow-key menu through a pty"
trap 'shim_cleanup' EXIT
# ...and at START as well, because that trap cannot run if the suite is KILLED, which is
# ordinary here. See sweep_stale_tmpdirs in lib/assert.sh for the rest of the reasoning.
record "shim:leftover-dirs-from-an-earlier-run" "$(shim_sweep_stale)"

COPY="$(repo_copy)"
LAUNCHER_DIR="$COPY"

# ─── dispatch and usage ────────────────────────────────────────────────────────
shim_new
for v in --help -h help; do
    assert_eq "dispatch:$v-exits-0" "0" "$(launcher_rc "$v")"
done
out="$(launcher --help)"
assert_says "usage:mentions-doctor"  "cs193v doctor"  "$out"
assert_contains "usage:mentions-rebuild" "--rebuild"      "$out"
# INVERTED BY #41. This used to assert the "many windows are fine" promise, which was the thing
# students most needed up front. Closing a window now stops the container, so the two facts
# students most need up front are that leaving takes your dev server with it, and that a second
# place to work is a TAB rather than a window.
assert_says "usage:says-closing-the-window-stops-things" "stops the container" "$out"
assert_says "usage:points-at-tabs-not-windows" "CTRL+T" "$out"
assert_contains "usage:mentions-stop" "--stop" "$out"

assert_eq "dispatch:unknown-verb-exits-2" "2" "$(launcher_rc bogusverb)"
assert_says "dispatch:unknown-verb-prints-usage" "cs193v doctor" "$(launcher bogusverb)"
# A typo must not create anything.
assert_eq "dispatch:unknown-verb-creates-nothing" "0" "$(shim_count '^run ')"

# ─── --dev-print-command  (§1.7) ───────────────────────────────────────────────
# This is the first thing to ask a student for in a support thread, so it has to be
# trustworthy: every flag in the args files must appear, unmangled.
shim_new
assert_eq "print:exits-0" "0" "$(launcher_rc --dev-print-command)"
line="$(launcher --dev-print-command)"
# "$NAME", not the literal: under CS193V_INSTANCE the name is cs193v-<instance>, and
# "--name cs193v" is a SUBSTRING of that, so a literal here would keep passing while
# asserting nothing about the thing it names.
assert_contains "print:has-name"       "--name $NAME"  "$line"
assert_contains "print:has-detach"     "--detach"      "$line"
assert_contains "print:has-confighash" "cs193v.confighash=" "$line"
assert_contains "print:has-dir-label"  "cs193v.dir=$COPY"   "$line"
assert_contains "print:mounts-sibling-projects" "src=$COPY/projects,dst=/home/student/projects,rw" "$line"

# One-directional on purpose: the launcher legitimately ADDS --name, --detach, --label and
# --mount, so a plain diff would fail spuriously. What must be empty is the set of flags
# present in the args files but missing from the run line.
missing="$(LC_ALL=C comm -13 \
    <(printf '%s\n' "$line" | tr ' ' '\n' | grep -E '^--?[a-z]' | LC_ALL=C sort -u) \
    <(sed 's/#.*//' "$COPY/.config/container.args" "$COPY/.config/local.args" 2>/dev/null \
        | tr ' ' '\n' | grep -E '^--?[a-z]' | LC_ALL=C sort -u) | tr '\n' ' ')"
assert_eq "print:contains-every-args-file-flag" "" "$(printf '%s' "$missing" | sed 's/ *$//')"

# local.args is machine-specific and absent from a fresh clone; the memory cap must reach
# the run line once the installer has written it.
printf -- '--memory=2048m\n' > "$COPY/.config/local.args"
line="$(launcher --dev-print-command)"
assert_contains "print:includes-memory-cap"    "--memory=2048m"        "$line"
# local.args changing must change the hash, or the cap never reaches an existing container.
h_with="$(current_hash)"
rm -f "$COPY/.config/local.args"
assert_ne "print:memory-cap-changes-confighash" "$h_with" "$(current_hash)"

# A comment on the same line as a flag must not leak into the run line.
assert_not_contains "print:strips-trailing-comments" "#" "$(launcher --dev-print-command)"

# The launcher resolves its own location, so it mounts its own sibling projects/ no matter
# where it is invoked from — and through a symlink, which is how a student who adds it to
# their PATH will reach it.
( cd / && PATH="$SHIM:$PATH" "$COPY/cs193v" --dev-print-command 2>&1 ) > "$SHIM/fromroot"
assert_contains "print:works-from-any-cwd" "src=$COPY/projects" "$(cat "$SHIM/fromroot")"
ln -sf "$COPY/cs193v" "$SHIM/cs193v-link"
assert_contains "print:resolves-through-symlink" "src=$COPY/projects" \
    "$(PATH="$SHIM:$PATH" "$SHIM/cs193v-link" --dev-print-command 2>&1)"

# ─── --dev-args agrees with the run line  (issue #57) ──────────────────────────
# 16-args-parse.sh asserts everything about the args parse through `--dev-args`, so that verb
# has to be the SAME parse that reaches podman. Nothing else ties the two together: --dev-args
# prints ARGS and --dev-print-command prints RUN_ARGS, and load_args feeding both is an
# implementation detail a future edit could break while leaving the unit tier green — which
# would leave a whole suite asserting things about a verb nobody runs.
#
# The comparison is one-directional, like print:contains-every-args-file-flag above and for the
# same reason: build_run_args legitimately ADDS --name, --detach, the labels and the mounts, so
# every word of --dev-args must appear in the run line but not the reverse.
#
# JOINED WITH SPACES AND MATCHED AS ONE STRING, not word by word: that is what makes this
# sensitive to ORDER, which is the half a set comparison would throw away -- and order is what
# decides which of two conflicting flags podman honours.
dev_args_joined="$(launcher --dev-args | tr '\n' ' ' | sed 's/ *$//')"
assert_ne       "dev-args:prints-something"            ""                  "$dev_args_joined"
assert_contains "dev-args:every-word-reaches-run-line" "$dev_args_joined" \
                "$(launcher --dev-print-command)"
# One word per line is the contract 16-args-parse.sh relies on to see a word boundary at all.
assert_eq "dev-args:one-word-per-line" "0" \
    "$(launcher --dev-args | grep -c '[[:space:]]' || true)"
# local.args must reach it too, or the unit tier is only ever testing one of the two files.
printf -- '--memory=2048m\n' > "$COPY/.config/local.args"
assert_contains "dev-args:includes-local-args" "--memory=2048m" "$(launcher --dev-args)"
rm -f "$COPY/.config/local.args"

# ─── refuses to run as root  (§1.5) ────────────────────────────────────────────
shim_new
shim_fake_id 0 root
out="$(launcher)"
assert_contains "root:refused"              "STOP"          "$out"
assert_contains "root:message-mentions-sudo" "sudo"         "$out"
assert_eq       "root:exits-1"              "1"             "$(launcher_rc)"
assert_eq       "root:creates-nothing"      "0"             "$(shim_count '^run ')"
# It must refuse before even asking podman anything.
assert_eq       "root:asks-podman-nothing"  "0"             "$(shim_count '.')"

# ─── version floor  (§1.4) ─────────────────────────────────────────────────────
# version_lt compares numerically, field by field. A lexical compare would call 10.0.0
# older than the floor and refuse every future podman.
#
# THE NUMBERS HERE ARE MIN_PODMAN_LINUX's NEIGHBOURS, not arbitrary. This suite runs on Linux, so
# the floor it is testing is 4.9.0 — see the two-floor rationale in cs193v. Every version below is
# one a real distro actually ships, which is what makes an off-by-one here mean something:
#
#   refused   4.8.3  Alpine 3.19        4.3.1  Debian 12 bookworm   3.4.4  Ubuntu 22.04 LTS
#   accepted  4.9.0  the floor itself   4.9.3  Ubuntu 24.04 LTS     5.4.2  Debian 13 trixie
#
# 4.9.3 IS THE ONE THAT MATTERS MOST. It is what Ubuntu 24.04 LTS ships, and Linux Mint 22.x and
# Pop!_OS 24.04 are built on it — so an off-by-one that refused it would refuse the three most
# common desktop Linuxes at once. It is accepted on measurement, not on faith:
# 26-installer-sandbox.sh builds the entire course image on a real 4.9.3.
for v in 4.8.3 4.3.1 3.4.4 0.1.0; do
    shim_new; shim_set version "podman version $v"
    assert_eq "version:$v-refused" "1" "$(launcher_rc)"
    assert_eq "version:$v-creates-nothing" "0" "$(shim_count '^run ')"
done
shim_new; shim_set version "podman version 4.3.1"
out="$(launcher)"
assert_contains "version:refusal-shows-found"  "4.3.1" "$out"
assert_contains "version:refusal-shows-needed" "4.9.0" "$out"
assert_says "version:refusal-names-the-fix" "apt install" "$out"

# 4.9.0 is exactly MIN_PODMAN_LINUX, so "equal" must mean "acceptable" — an off-by-one here
# refuses a machine sitting precisely on the floor. 10.0.0 guards against a lexical compare, which
# would call it older than 4.9.0.
for v in 4.9.0 4.9.3 5.4.2 5.7.0 6.0.2 10.0.0; do
    shim_new; shim_set version "podman version $v"
    launcher >/dev/null 2>&1
    assert_eq "version:$v-accepted" "1" "$(shim_count '^run ')"
done

# ─── podman not responding  (§6.1) ─────────────────────────────────────────────
# After a Mac wakes from sleep, `podman info` hangs rather than failing
# (containers/podman#21675). Every probe is timeout-wrapped so the launcher says something
# instead of looking frozen. The point of this test is the elapsed time.
# ONE hanging launch, not two. The elapsed time IS the assertion here, so the wait itself is
# not negotiable — but it used to be paid twice, once for the clock and once again for the
# message, and a single run yields the elapsed time, the exit status and the output together.
# All three assertions below are unchanged; what is gone is the second eleven-second wait.
shim_new; shim_touch hang
T0="$(date +%s)"
out="$(launcher)"; rc=$?
T1="$(date +%s)"
ELAPSED=$((T1 - T0))
assert_eq "hang:exits-nonzero" "1" "$rc"
if [ "$ELAPSED" -lt 40 ]; then
    pass "hang:returns-in-seconds-not-minutes"
else
    fail "hang:returns-in-seconds-not-minutes" "took ${ELAPSED}s"
fi
record "hang:elapsed-seconds" "$ELAPSED"
assert_says "hang:message-says-not-responding" "not responding" "$out"

# ─── rootless and reachability ─────────────────────────────────────────────────
# --userns=keep-id is a HARD ERROR on a rootful connection, not a no-op, so this must be
# caught with an explanation rather than surfaced as a raw podman error.
shim_new; shim_set rootless false
out="$(launcher)"
assert_contains "rootful:refused"          "rootful" "$out"
assert_eq       "rootful:creates-nothing"  "0"       "$(shim_count '^run ')"

shim_new; shim_set info_rc 1
out="$(launcher)"
assert_says "unreachable:refused"         "cannot reach it" "$out"
assert_eq       "unreachable:creates-nothing" "0"               "$(shim_count '^run ')"

# ─── image resolution ──────────────────────────────────────────────────────────
# No pin and nothing built: the only actionable answer is "build it", and it has to name
# the command. There is no registry to fall back to.
shim_new; shim_set image_exists no
out="$(launcher)"
assert_says "image:nothing-built-refuses"      "has not been built" "$out"
assert_says "image:nothing-built-says-how"     "--rebuild"          "$out"
assert_eq   "image:refusal-creates-nothing" "0" "$(shim_count '^run ')"

# A locally built image is the NORMAL case now, not a staff-only escape hatch, so the
# launch must be silent about it. The old warn.dev-mode told any student who saw it to
# contact staff; left in place it would fire for every student on every launch, which is
# the fastest way to teach a class to ignore the launcher's warnings.
shim_new
out="$(launcher 2>&1)"
assert_says_not "image:local-image-does-not-warn"   "locally built" "$out"
assert_says_not "image:local-image-no-staff-scare"  "tell course staff" "$out"
assert_eq       "image:local-image-launches" "1" "$(shim_count '^run ')"

# ─── the launch says something before it does anything  (issue #57) ────────────
# A bare ./cs193v is SILENT on every path where it succeeds, and it is not quick: preflight's
# single `podman info` measures 536-1222 ms by itself (ERRORS.md D11) and the probes behind it
# take the rest of a second. A student typed a command and watched nothing happen for long
# enough to wonder whether they had typed it wrong.
#
# WHAT IS ASSERTED IS THE ORDER, not the presence of a sentence. A message printed after the
# probes would pass a `contains` check and fix nothing at all, so every case here pins the line
# to the FRONT of the output -- ahead of the first podman call, and ahead of the first way the
# launch can refuse.
#
# Piped throughout, deliberately: the announcement is a plain `info`, with no terminal branch
# and nothing animated, so a pty would test the harness rather than the launcher. That is the
# whole of what dropping the progress indicator bought.
shim_new
out="$(launcher)"
assert_says_key "entering:announced" status.entering "$out"
assert_eq "entering:is-the-first-line" "$(msg_text status.entering)" \
          "$(printf '%s\n' "$out" | head -1)"
# Once, not once per path through ensure_container -- a second call site added later would
# otherwise be invisible, since every other assertion here is satisfied by the first.
assert_eq "entering:said-once" "1" \
          "$(printf '%s\n' "$out" | grep -cF "$(msg_text status.entering)" || true)"

# Before the earliest refusal there is, which is the case the order matters most in: the box
# explains a launch the student can already see was attempted.
shim_new; shim_set version "podman version 5.6.0"
out="$(launcher)"
p_say="$(printf '%s\n' "$out" | grep -nF "$(msg_text status.entering)" | head -1 | cut -d: -f1)"
p_box="$(printf '%s\n' "$out" | grep -n 'STOP' | head -1 | cut -d: -f1)"
if [ -n "$p_say" ] && [ -n "$p_box" ] && [ "$p_say" -lt "$p_box" ]; then
    pass "entering:precedes-a-refusal"
else
    fail "entering:precedes-a-refusal" "sentence at line ${p_say:-none}, STOP box at ${p_box:-none}"
fi

# "Starting the course container..." is gone. It named an implementation detail at the one
# moment a student is already waiting, and the launch has announced itself in better words by
# the time this path is reached. The behaviour it used to describe must be untouched, which is
# the second assertion: the container is still STARTED rather than recreated.
shim_new
launcher >/dev/null 2>&1                       # create, so the config hash matches
shim_set state exited
shim_clear_log
out="$(launcher)"
assert_says_not "starting:message-is-gone"  "Starting the course container" "$out"
assert_eq       "starting:still-starts-it"  "1" "$(shim_count '^start ')"
assert_says_key "starting:still-announced"  status.entering "$out"

# No verb inherits it. Each of these prints its own first line already, and a second one saying
# a shell is being entered would be a lie in every case -- none of them opens one.
for v in doctor --rebuild --stop --dev-print-command; do
    shim_new
    assert_says_not_key "entering:verb-$v-says-nothing" status.entering "$(launcher $v)"
done

# ─── the state machine  (§2.1, §2.2) ───────────────────────────────────────────
shim_new
assert_eq "state:absent-creates-one" "1" "$(launcher_rc >/dev/null; shim_count '^run ')"

# §A.10 idempotency: twenty launches, still exactly one container. The fake flips to
# running and remembers the hash it was given, so the second launch takes the same path a
# real second launch would.
shim_new
i=0
while [ "$i" -lt 20 ]; do launcher >/dev/null 2>&1; i=$((i + 1)); done
assert_eq "state:20-launches-create-one-container" "1" "$(shim_count '^run ')"
assert_eq "state:20-launches-remove-nothing"       "0" "$(shim_count '^rm ')"

# Every launch after the first must open a shell rather than recreate. Driven through a pty,
# because open_shell now refuses without a terminal — so a piped launch never gets this far,
# which is exactly the behaviour the refusal is for.
shim_new
i=0
while [ "$i" -lt 3 ]; do launcher_pty >/dev/null 2>&1; i=$((i + 1)); done
assert_eq "state:pty-launches-create-one-container" "1" "$(shim_count '^run ')"
if [ "$(shim_count '^exec -it')" -ge 3 ]; then pass "state:every-pty-launch-opens-a-shell"
else fail "state:every-pty-launch-opens-a-shell" "only $(shim_count '^exec -it') exec sessions"; fi

# A stopped container is started, never recreated — recreating would silently discard
# anything the student installed inside it.
shim_new
launcher >/dev/null 2>&1                       # create, so the hash matches
shim_set state exited
shim_clear_log
launcher >/dev/null 2>&1
assert_eq "state:exited-is-started" "1" "$(shim_count '^start ')"
assert_eq "state:exited-is-not-recreated" "0" "$(shim_count '^run ')"

# ─── closing the terminal stops the container  (#41) ───────────────────────────
# The invariant every assertion in this group serves: A RUNNING CONTAINER IMPLIES AN OPEN
# TERMINAL. The shim is the cheap place to hold the state machine to that, because none of it
# needs a real container -- only that the launcher issues the right podman calls in the right
# order and refuses at the right times.
shim_state() { cat "$SHIM/state" 2>/dev/null; }

# A launch that finishes leaves nothing running. Driven through a pty, because a piped launch
# refuses at the tty check -- which stops the container too, but for a different reason, and
# asserting on that would prove the wrong thing.
shim_new
launcher_pty >/dev/null 2>&1
assert_eq "lifecycle:a-finished-session-leaves-nothing-running" "exited" "$(shim_state)"
if [ "$(shim_count '^stop ')" -ge 1 ]; then pass "lifecycle:the-launcher-stops-the-container"
else fail "lifecycle:the-launcher-stops-the-container" \
          "no podman stop was issued, so the container outlived its terminal"; fi
# -t bounds podman's OWN grace period, which defaults to 10 and would otherwise be spent
# waiting on a PID 1 that traps TERM and exits in milliseconds. -i so an already-removed
# container (a --rebuild from elsewhere) is not an error.
assert_says "lifecycle:the-stop-is-bounded-and-forgiving" "stop -t 3 -i" \
            "$(shim_log | tr '\n' ' ')"

# The refusal. Piped rather than through a pty on purpose: refuse_if_session_live runs BEFORE
# open_shell's tty check, so this is reachable without one -- and that ordering is what makes
# the message a student sees rather than a hang.
shim_new
launcher >/dev/null 2>&1
shim_set state running
shim_clear_log
out="$(launcher)"
assert_says "lifecycle:a-second-launch-refuses" "already have a CS193V session" "$out"
assert_says "lifecycle:the-refusal-names-the-way-out" "cs193v --stop" "$out"
# The crash caveat carries real weight: without it the message asserts something a student with
# no other window open knows to be false, and a message they have caught lying once is one they
# will not read again.
assert_says "lifecycle:the-refusal-admits-it-may-be-a-crash" "crash" "$out"
assert_eq "lifecycle:the-refusal-exits-nonzero" "1" "$(launcher_rc)"
assert_eq "lifecycle:the-refusal-creates-nothing" "0" "$(shim_count '^run ')"
assert_eq "lifecycle:the-refusal-removes-nothing" "0" "$(shim_count '^rm ')"
# ...and it must not stop the container it just refused to disturb. Getting this wrong would
# make a second launch a weapon: it would kill the session it was protecting.
assert_eq "lifecycle:the-refusal-stops-nothing" "0" "$(shim_count '^stop ')"

# Every maintenance verb refuses while a session is live, pointing at the same --stop, so there
# is ONE answer to "the container is busy" rather than one per verb.
#
# THE MODIFIERS ARE IN THIS LIST, not just the bare verb: --logout reaches remove_volumes and
# --no-cache reaches build_image, and the refusal has to come before either. A --logout that
# refused only AFTER deleting the login volumes would be the worst failure in this file.

# Name and argument list carried separately, so an assertion name stays a single word while the
# verb under test is two.
for spec in "rebuild:--rebuild" "rebuild-logout:--rebuild --logout" "rebuild-nocache:--rebuild --no-cache"; do
    name="${spec%%:*}"; v="${spec#*:}"
    shim_new
    launcher >/dev/null 2>&1
    shim_set state running
    shim_clear_log
    assert_says "lifecycle:$name-refuses-while-a-session-is-live" \
                "already have a CS193V session" "$(launcher $v)"
    assert_eq "lifecycle:$name-does-not-remove-a-live-container" "0" "$(shim_count '^rm ')"
    assert_eq "lifecycle:$name-does-not-remove-a-live-containers-volumes" \
              "0" "$(shim_count '^volume rm ')"
done

# ...and it stops the container when it finishes, because it is not a session and nobody is
# attached when it is done. This is what keeps the invariant above exact: without it, "running"
# would mean either "somebody is working" or "a rebuild happened at some point", and doctor
# could not tell a student which.
for spec in "rebuild:--rebuild" "rebuild-logout:--rebuild --logout"; do
    name="${spec%%:*}"; v="${spec#*:}"
    shim_new
    shim_clear_log
    launcher $v >/dev/null 2>&1
    assert_eq "lifecycle:$name-leaves-nothing-running" "exited" "$(shim_state)"
done

# ─── --stop ────────────────────────────────────────────────────────────────────
# The unified escape hatch, and the one command the refusal above names.
shim_new
launcher >/dev/null 2>&1
shim_set state running
shim_clear_log
# With no tty, menu() picks the SAFE default -- which for a verb that throws away a running
# session must be "cancel". A --stop that stopped things when driven from a script would be a
# footgun in exactly the place this project is most careful about.
out="$(launcher --stop)"
assert_eq "lifecycle:stop-defaults-to-cancel-without-a-tty" "running" "$(shim_state)"
assert_says "lifecycle:stop-warns-before-it-acts" "anything running inside it will stop" "$out"

# Down-arrow then ENTER selects the non-default, exactly as the stale-recipe test does.
shim_new
launcher >/dev/null 2>&1
shim_set state running
shim_clear_log
launcher_tty '\033[B\n' --stop >/dev/null 2>&1
assert_eq "lifecycle:stop-accepted-stops-the-container" "exited" "$(shim_state)"

# Idempotent, because the student most likely to run it is the one who has already run it: the
# refusal named --stop, they ran it, and they are trying again.
shim_new
shim_set state exited
assert_says "lifecycle:stop-on-a-stopped-container-says-so" "nothing to stop" "$(launcher --stop)"
assert_eq "lifecycle:stop-on-a-stopped-container-exits-0" "0" "$(launcher_rc --stop)"

# ─── losing the create race  (#41) ─────────────────────────────────────────────
# `podman run --name` IS the atomic test-and-set for absent -> running: name uniqueness is
# enforced under podman's own database lock, so of two simultaneous launches exactly one creates
# the container and the other gets this. Measured against podman 5.7.0 -- rc=125 and "the
# container name ... is already in use by <id>".
#
# What this pins is that the loser gets the REFUSAL and not err.create-failed with a wall of
# podman output, for something whose real meaning is "you already have a session open".
shim_new
shim_set run_rc 125
shim_set run_err 'Error: creating container storage: the container name "cs193v" is already in use by 15bb56cdbb36. You have to remove that container to be able to reuse that name: that name is already in use, or use --replace to instruct Podman to do so.'
out="$(launcher)"
assert_says "race:lost-create-is-reported-as-a-live-session" \
            "already have a CS193V session" "$out"
# BOTH negatives are flattened through _flatten, because these strings are inside the STOP box
# and a raw substring match would silently stop matching the moment the box re-wraps a line --
# an assert_not_contains that can no longer match is one that passes forever.
#
# The first spelling of this checked for "could not create", and err.create-failed actually says
# "could not BE created", so it was vacuous on the day it was written.
assert_not_contains "race:lost-create-is-not-reported-as-a-create-failure" \
                    "could not be created" "$(_flatten "$out")"
# The one that matters most: podman's own words must not reach the student here. err.create-failed
# interpolates {{OUT}}, so getting this wrong shows a novice "creating container storage: ...
# lchown ..." for something that means "you already have a window open".
assert_not_contains "race:lost-create-does-not-leak-podmans-output" \
                    "creating container storage" "$(_flatten "$out")"

# ─── interrupting the create window  (#41) ─────────────────────────────────────
# `podman run --detach` returns with a container UP, and verb_rebuild stops it on the next line.
# A Ctrl-C in between leaves one running with nobody in it -- and since #41 `state` = running IS
# the session test, so the cost is not just a stray container: the next `./cs193v` refuses to
# launch, naming a session that does not exist, and the student has to be told about --stop to
# get out of a hole the launcher dug.
#
# run_hold holds the window open until this test lets go, rather than racing a gap that is
# milliseconds wide against a poll. The signal goes to the launcher alone, not to a process group,
# so what is tested is the handler rather than podman's own response to Ctrl-C.
#
# SIGTERM, not the SIGINT a student actually sends, and the reason is a bash rule rather than a
# preference: a non-interactive shell sets SIGINT to SIG_IGN in every command it starts with `&`,
# and a signal ignored on entry cannot be trapped. So a backgrounded launcher CANNOT receive a
# Ctrl-C from this harness -- the first version of this test sent one and watched the launcher
# sit in run_timeout's 180s loop, having never run the handler. A student's Ctrl-C reaches a
# foreground job of an interactive shell, where SIGINT is not ignored. TERM and HUP are trapped
# by the same handler and are not special-cased by that rule, so this exercises the same path.
shim_new
shim_set state absent
shim_set run_hold 1
PATH="$SHIM:$PATH" "${LAUNCHER_DIR:-$REPO}/cs193v" --rebuild >/dev/null 2>&1 &
rb=$!
container_is_up() { [ "$(cat "$SHIM/state" 2>/dev/null)" = running ]; }
if wait_until 30 container_is_up; then
    kill -TERM "$rb" 2>/dev/null
    # Waited for ONCE and the status kept: a second wait on a reaped pid reports 127, which would
    # look like the launcher exiting on a missing command.
    wait "$rb" 2>/dev/null; rb_rc=$?
    assert_eq "interrupt:stops-the-container-it-created" "1" "$(shim_count '^stop ')"
    # 128+15, and it has to survive the handler: a teardown that swallowed the signal and exited 0
    # would tell a script that the rebuild succeeded. Per-signal, so a caller can still tell a
    # Ctrl-C (130) from a closed window (129).
    assert_eq "interrupt:exits-128-plus-the-signal" "143" "$rb_rc"
else
    kill "$rb" 2>/dev/null
    fail "interrupt:stops-the-container-it-created" "podman run never reported a container up"
    fail "interrupt:exits-128-plus-the-signal" "see above"
fi
rm -f "$SHIM/run_hold"

# ─── a container from a different copy of the course directory  (§2.7) ─────────
# Without this a student who re-downloads after breaking something silently gets the old
# container with the old mount, and their edits appear to vanish.
shim_new
shim_set state running
shim_set label_dir /somewhere/else/cs193v
out="$(launcher)"
assert_says "foreign-dir:refused"        "different folder" "$out"
assert_contains "foreign-dir:names-theirs"   "/somewhere/else/cs193v" "$out"
assert_contains "foreign-dir:names-yours"    "$COPY" "$out"
assert_contains "foreign-dir:offers-rebuild" "--rebuild" "$out"
assert_eq       "foreign-dir:creates-nothing" "0" "$(shim_count '^run ')"
assert_eq       "foreign-dir:opens-no-shell"  "0" "$(shim_count '^exec ')"

# ─── config drift  (§2.5) ──────────────────────────────────────────────────────
# `podman start` reuses the container's STORED config and ignores the image digest, the
# port list, keep-id and --memory alike. Without this check, every student's flags would be
# frozen at first run and edits to container.args would never reach anyone.
shim_new
launcher >/dev/null 2>&1                       # one container, hash recorded
shim_clear_log
echo '-p 127.0.0.1:9998:9998' >> "$COPY/.config/container.args"
out="$(launcher)"
assert_says "drift:prompt-shown"    "settings have changed" "$out"
assert_says "drift:explains-why"    "cannot apply new settings" "$out"
assert_says "drift:reassures-files" "Your files are safe" "$out"
assert_eq "drift:declined-keeps-container" "0" "$(shim_count '^run ')"
assert_eq "drift:declined-removes-nothing" "0" "$(shim_count '^rm ')"
# The new flag must be visible in the run line even before the recreate.
assert_contains "drift:visible-in-print-command" "9998" "$(launcher --dev-print-command)"

# Accepting it, through a pty, must actually recreate with the new flag.
shim_clear_log
out="$(launcher_tty '\033[B\n' | strip_ansi)"
assert_says "drift:accepted-selects-apply" "Apply the new settings" "$out"
assert_eq "drift:accepted-removes-old" "1" "$(shim_count '^rm ')"
assert_eq "drift:accepted-creates-new" "1" "$(shim_count '^run ')"
assert_contains "drift:new-container-has-the-flag" "9998" "$(shim_log | grep '^run ')"

# Restore, and confirm a matching config produces no prompt at all.
edit_remove "$COPY/.config/container.args" '9998'
shim_new
launcher >/dev/null 2>&1
shim_clear_log
out="$(launcher)"
assert_says_not "nodrift:no-prompt" "settings have changed" "$out"
assert_eq "nodrift:no-recreate" "0" "$(shim_count '^run ')"

# ─── a stale recipe  (the replacement for the digest pin, §2.6) ────────────────
# How a mid-quarter fix reaches a student who never runs --rebuild. With no registry there
# is no digest to change, and podman mints a new image ID on every build including a
# no-op one — so the IMAGE ID cannot answer "is this out of date". The recipe can.
shim_new
launcher >/dev/null 2>&1
shim_set image_buildhash "0000deadbeefnotthecurrentrecipe"
shim_clear_log
out="$(launcher)"
assert_says "stale-recipe:prompt-shown" "has been updated since" "$out"
assert_eq   "stale-recipe:declined-builds-nothing" "0" "$(shim_count '^build ')"
assert_eq   "stale-recipe:declined-keeps-container" "0" "$(shim_count '^run ')"

shim_clear_log
launcher_tty '\033[B\n' >/dev/null 2>&1
assert_eq "stale-recipe:accepted-rebuilds"  "1" "$(shim_count '^build ')"
assert_eq "stale-recipe:accepted-recreates" "1" "$(shim_count '^run ')"

# An image built before the label existed has none, and an UNKNOWN answer must not nag —
# the same rule the confighash check follows. Nagging on every launch with no way to
# silence it is how a class learns to click through prompts.
shim_new
launcher >/dev/null 2>&1
shim_clear_log
assert_says_not "stale-recipe:unlabelled-does-not-nag" "has been updated since" "$(launcher)"
assert_eq       "stale-recipe:unlabelled-builds-nothing" "0" "$(shim_count '^build ')"

# ─── --rebuild, and its two modifiers  (§2.3, §2.4) ────────────────────────────
#
# THE HASH GATE IS WHAT THIS SECTION IS FOR. The recipe decides whether --rebuild builds, so the
# two assertions that matter most are that it does NOT build when the recipe matches and DOES
# when it moved. If the first ever counts 1, a 2s recovery command has become a multi-minute one.
#
# "The recipe matches" is arranged BY BUILDING, which is what podman-fake's `build` arm exists
# for -- it records the cs193v.buildhash it was handed, so the next invocation sees an image
# labelled with the launcher's own current hash. Computing that hash here a second time would be
# a test that agreed with itself rather than with the launcher.
shim_new
launcher --rebuild --no-cache >/dev/null 2>&1
assert_eq "rebuild:no-cache-builds-anyway" "1" "$(shim_count '^build ')"
assert_contains "rebuild:no-cache-reaches-podman" "--no-cache" "$(shim_log | grep '^build ')"
assert_contains "rebuild:labels-the-recipe" "cs193v.buildhash=" "$(shim_log | grep '^build ')"

shim_clear_log
launcher --rebuild >/dev/null 2>&1
assert_eq "rebuild:removes-container" "1" "$(shim_count '^rm ')"
assert_eq "rebuild:creates-container" "1" "$(shim_count '^run ')"
assert_eq "rebuild:current-recipe-builds-nothing" "0" "$(shim_count '^build ')"
# --rebuild must keep logins: none of the seven volumes is touched.
assert_eq "rebuild:keeps-volumes" "0" "$(shim_count '^volume rm')"
out="$(launcher --rebuild)"
assert_says "rebuild:says-logins-kept" "logins are kept" "$out"
# ...AND IT MUST NOT CELEBRATE A BUILD IT DID NOT DO. One verb both builds and merely recreates,
# so the box is gated on $BUILT: a two-second recreate ending in "Build Successful!" would
# congratulate the launcher for nothing and send the student into an environment it did not
# prepare.
assert_says_not "rebuild:no-box-when-nothing-was-built" "Build Successful" "$out"
assert_says_not "rebuild:no-vibecoding-when-nothing-was-built" "Happy vibecoding" "$out"

# ...AND THE EXPENSIVE PATH HAPPENS WITHOUT BEING ASKED FOR. A moved recipe makes the same
# command build, with no prompt: the student typed the verb whose job is to make the container
# match the recipe, so building is the answer to what they asked rather than an interruption of
# it. Contrast the bare launch in the section above, which asks -- same predicate, opposite
# default, deliberately.
shim_new
launcher >/dev/null 2>&1
shim_set image_buildhash "0000deadbeefnotthecurrentrecipe"
shim_clear_log
out="$(launcher --rebuild)"
assert_eq "rebuild:moved-recipe-builds" "1" "$(shim_count '^build ')"
assert_eq "rebuild:moved-recipe-recreates" "1" "$(shim_count '^run ')"
assert_says_not "rebuild:moved-recipe-does-not-ask" "has been updated since" "$out"
# An unlabelled image is an UNKNOWN, not a stale one, and must not provoke a build here either
# -- the same rule the bare launch follows. This is the case a bare `podman build` produces.
shim_new
launcher >/dev/null 2>&1
shim_clear_log
launcher --rebuild >/dev/null 2>&1
assert_eq "rebuild:unlabelled-builds-nothing" "0" "$(shim_count '^build ')"

# --logout, which has NO PROMPT deliberately. That makes the non-tty behaviour the interesting
# case -- it ACTS rather than cancelling, so this would catch the modifier being wired to a menu.
shim_new
launcher >/dev/null 2>&1
shim_clear_log
out="$(launcher --rebuild --logout)"
assert_eq "logout:removes-container" "1" "$(shim_count '^rm ')"
# SIX, since setup-git: the git identity and the credential helper live in a volume of their own
# now, and --logout takes them with the tokens. Counted rather than named, so a volume added to
# container.args and forgotten in remove_volumes fails here.
if [ "$(shim_count '^volume rm')" -eq 7 ]; then pass "logout:removes-7-volumes"
else fail "logout:removes-7-volumes" "removed $(shim_count '^volume rm')"; fi
assert_says "logout:says-you-are-logged-out" "log in again" "$out"
# ...and it must NOT claim the thing it just deleted was kept: status.rebuilding says "logins are
# kept", which is the wrong announcement for this path.
assert_says_not "logout:does-not-promise-logins-kept" "logins are kept" "$out"

# A stray modifier is refused rather than ignored: with two modifiers that both matter, a typo
# that silently means "keep the volumes" is the failure worth being loud about.
assert_eq "rebuild:unknown-modifier-exits-2" "2" "$(launcher_rc --rebuild --lgout)"
shim_new
launcher >/dev/null 2>&1
shim_clear_log
launcher --rebuild --lgout >/dev/null 2>&1
assert_eq "rebuild:unknown-modifier-changes-nothing" "0" "$(shim_count '^rm ')"

# ...AND IT RAISES NO TUNNEL AT ALL. --rebuild stops the container it just created, so a tunnel
# raised for it is bound for a container nobody can be in and torn down having served nothing --
# while holding every forwarded host port meanwhile, which CS193V_INSTANCE does NOT namespace, so a
# recreate in one checkout could take them from a colleague's live session (CLAUDE.md).
#
# Asserted on the FILES rather than by watching `ss` during the run: an ssh that is never spawned
# cannot bind anything, which is the whole claim, and it needs no sampling to establish.
#
# THE LOG IS THE ONE THAT PROVES IT. Counting the control socket and pidfile is not enough and the
# first version of this made that mistake: tunnel_down rm -f's both, so a launcher that raised a
# tunnel and tore it down again leaves the same empty directory as one that never raised one, and
# the assertion passed against the very code it was written to catch. The log is created by the
# redirection on tunnel_start's `nohup ssh`, and NOTHING removes it except the next tunnel_start
# and --reset-tunnel -- so its absence means no ssh was ever spawned. $BUILD_LOG lives in the same
# directory and is not evidence of anything, hence the exclusion.
#
# shim_new gives the launcher a TMPDIR under $SHIM, so the answer is about THIS launch -- these
# files are named from a hash of the course directory, and the real /tmp holds this checkout's
# actual tunnel plus every other instance's. Deliberately NO shim_fake_ssh: a real ssh cannot
# reach fake podman's container, so an attempt would leave the log behind and warn, which is
# exactly what is being ruled out here.
shim_new
out="$(launcher --rebuild)"
assert_eq "rebuild:raises-no-tunnel" "0" \
    "$(ls "$SHIM"/tmp/cs193v-*.ctl "$SHIM"/tmp/cs193v-*.pid "$SHIM"/tmp/cs193v-*.log 2>/dev/null \
       | grep -v 'cs193v-build-' | wc -l | tr -d ' ')"
# ...and says nothing about one either. By KEY, so rewording the message cannot break this.
assert_says_not_key "rebuild:says-nothing-about-the-tunnel" warn.tunnel-failed "$out"

# ─── doctor ────────────────────────────────────────────────────────────────────
shim_new
out="$(launcher doctor)"
assert_contains "doctor:reports-platform"  "platform"     "$out"
assert_contains "doctor:reports-podman"    "5.7.0"        "$out"
assert_contains "doctor:reports-dir"       "$COPY"        "$out"
assert_contains "doctor:reports-container" "container"    "$out"
assert_says "doctor:asks-for-a-paste"  "Paste all of the above" "$out"
# doctor must never create or modify anything — it is what staff ask for first.
assert_eq "doctor:creates-nothing" "0" "$(shim_count '^run ')"
assert_eq "doctor:removes-nothing" "0" "$(shim_count '^rm ')"

# The positive case, and the one that was broken. A container created from the current
# container.args must be reported as matching it. verb_doctor hashed IMAGE="" because it
# never resolved the image, while the launch path hashed the resolved dev image — so with an
# empty IMAGE=, which is how the repo shipped, doctor called EVERY container stale and sent
# people chasing a recreate prompt that never appears. The pin that made those two answers
# differ is gone and IMAGE is a constant now, so this asserts a property that has become
# structural — which is the right direction for it to move, not a reason to delete it.
shim_new
launcher >/dev/null 2>&1
out="$(launcher doctor)"
assert_says "doctor:reports-a-matching-config-as-matching" "matches container.args" "$out"
assert_says_not "doctor:does-not-cry-stale-when-config-matches" "STALE" "$out"
# Whatever doctor says has to agree with what a real launch decides, or one of the two is
# lying to the student.
assert_says_not "doctor:agrees-with-the-launch-path" "settings have changed" "$(launcher)"

# And drift must still be reported when it is real.
shim_new
launcher >/dev/null 2>&1
shim_set label_hash STALE
assert_contains "doctor:reports-stale-config" "STALE" "$(launcher doctor)"

# doctor is "the report to paste when asking for help", so it has to answer the first
# question staff will ask about behaviour they cannot reproduce. That question used to be
# "what digest are you on"; with the image built on the student's own machine the
# answerable form is which image, when it was built, and whether it still matches the
# course files. VERIFICATION.md §A.1 calls doctor untrustworthy if it lies here.
shim_new
launcher >/dev/null 2>&1
out="$(launcher doctor)"
assert_says "doctor:names-the-image"      "localhost/cs193v:local" "$out"
assert_says "doctor:says-it-was-built-here" "built here"           "$out"
assert_says "doctor:dates-the-image"      "image built"            "$out"
assert_says "doctor:reports-the-recipe"   "image recipe"           "$out"

shim_new
launcher >/dev/null 2>&1
shim_set image_buildhash "0000deadbeefnotthecurrentrecipe"
assert_contains "doctor:reports-a-stale-recipe" "STALE" "$(launcher doctor | grep 'image recipe')"

# Nothing built yet: doctor must say so rather than printing a tag that does not exist,
# and must name the command that fixes it.
shim_new; shim_set image_exists no
out="$(launcher doctor)"
assert_says "doctor:says-when-nothing-is-built" "NOT BUILT" "$out"
assert_says "doctor:says-how-to-build"          "--rebuild" "$out"

# ─── terminal handling ─────────────────────────────────────────────────────────
# podman forces TERM=xterm and does not copy the client's value
# (containers/podman#25683), costing 256-colour support. But the image ships a limited
# terminfo set, so an exotic TERM cannot be forwarded verbatim or a full-screen editor
# fails to start. Whitelist, and fall back to a safe 256-colour entry.
# Driven through a pty: TERM is forwarded by open_shell, which now refuses without a
# terminal, so a piped launch never reaches the exec at all.
shim_new
TERM=xterm-256color launcher_pty >/dev/null 2>&1
assert_contains "term:known-term-forwarded" "TERM=xterm-256color" "$(shim_log)"
for exotic in kitty ghostty alacritty wezterm foot xterm-kitty; do
    shim_new
    TERM="$exotic" launcher_pty >/dev/null 2>&1
    assert_contains "term:$exotic-falls-back-to-256color" "TERM=xterm-256color" "$(shim_log)"
    assert_not_contains "term:$exotic-not-forwarded-verbatim" "TERM=$exotic" "$(shim_log)"
done
shim_new
TERM='' launcher_pty >/dev/null 2>&1
assert_contains "term:empty-term-gets-a-default" "TERM=xterm-256color" "$(shim_log)"

shim_new
out="$(NO_COLOR=1 launcher bogusverb)"
assert_not_match "no-color:emits-no-escapes" "$(printf '\033')" "$out"

# ─── opening a shell requires a terminal  (ERRORS.md B13) ──────────────────────
# `podman exec -it` allocates a pty, and a pty never delivers EOF the way a pipe does, so
# with a redirected stdin the container's `bash -l` used to wait forever and the launcher
# looked wedged with no output at all. It now refuses instead.
shim_new
out="$(launcher)"
assert_says "noterm:refuses-without-a-terminal" "could not open a shell" "$out"
assert_says "noterm:explains-why"               "not being run from a terminal" "$out"
# INVERTED BY #41: the container is no longer left running, because a running container with
# nothing attached is exactly the state the change exists to prevent -- so the message can
# promise it is set up, but not that it is up.
assert_says "noterm:says-the-container-is-set-up" "container is set up" "$out"
assert_says "noterm:says-it-was-stopped-again"    "has been stopped again" "$out"
# The message has to name what a script SHOULD use, or it is just a dead end.
assert_says "noterm:points-at-rebuild" "cs193v --rebuild" "$out"
assert_says "noterm:points-at-doctor"  "cs193v doctor"    "$out"
assert_says "noterm:points-at-podman-exec" "podman exec -it cs193v bash -lc" "$out"
assert_eq   "noterm:exits-nonzero" "1" "$(launcher_rc)"
# It must refuse, not hang. A wall-clock check, since hanging was the original bug.
T0="$(date +%s)"; launcher >/dev/null 2>&1; T1="$(date +%s)"
if [ "$((T1 - T0))" -lt 30 ]; then pass "noterm:refuses-promptly-instead-of-hanging"
else fail "noterm:refuses-promptly-instead-of-hanging" "took $((T1 - T0))s"; fi
# The work done before the shell is still real and idempotent — the message promises this.
assert_eq "noterm:container-was-still-created" "1" "$(shim_count '^run ')"
# And no shell was attempted.
assert_eq "noterm:no-exec-attempted" "0" "$(shim_count '^exec -it')"
# With a terminal, the very same invocation must go on to open the shell.
#
# The landing point is cs193v-shell, not `bash -l`: it puts the student inside tmux and
# picks a session to attach to. `bash -l` remains what the refusal message points scripts
# at, which is asserted separately above -- the two must not be conflated, because the
# whole point of that message is that it names the path which does NOT go through tmux.
shim_new
launcher_pty >/dev/null 2>&1
assert_contains "noterm:with-a-terminal-it-opens-a-shell" "cs193v-shell" "$(shim_log)"
# The failure path inside the container has to print an exact `podman exec` line, and only
# the launcher knows the container's name -- CS193V_INSTANCE may have suffixed it.
assert_contains "noterm:passes-the-container-name-in" "CS193V_CONTAINER=" "$(shim_log)"

# ─── the claim's terminal size is never degenerate  ────────────────────────────
# `tmux new-session -d` takes the size as -x/-y and the claim exec has no tty to read it from, so
# the launcher passes it in. A DIGITS-ONLY guard is not enough: a pty with nothing behind it --
# `script -q -c ... /dev/null`, which is exactly how this suite and 70-sighup.sh drive a launch --
# reports `0 0` from `stty size`. Both are numeric, so they pass a digit check, and tmux then
# refuses with "width too small": no session, cs193v-shell prints its fault box, the launch dies.
# Measured. Caught by the live tier, which costs five minutes; this costs none.
sz_bad=''
for kv in $(shim_log | tr ' ' '\n' | grep -E '^CS193V_(COLS|LINES)=' | sort -u); do
    sz_v="${kv#*=}"
    case "$sz_v" in ''|*[!0-9]*) sz_bad="$sz_bad $kv(non-numeric)" ; continue ;; esac
    case "${kv%%=*}" in
        CS193V_COLS)  [ "$sz_v" -ge 20 ] || sz_bad="$sz_bad $kv" ;;
        CS193V_LINES) [ "$sz_v" -ge 5 ]  || sz_bad="$sz_bad $kv" ;;
    esac
done
assert_eq "noterm:claim-never-passes-a-degenerate-size" "" "$sz_bad"

# The scriptable verbs must NOT be caught by the refusal — they are what the message tells
# people to use, so they have to work with a redirected stdin.
for v in --dev-print-command doctor --rebuild; do
    shim_new
    assert_says_not "noterm:verb-$v-still-works-piped" "could not open a shell" \
                    "$(launcher $v)"
done
shim_new
launcher --rebuild >/dev/null 2>&1
assert_eq "noterm:--rebuild-still-creates-a-container-piped" "1" "$(shim_count '^run ')"

# ─── warnings survive the shell being opened  (issue #19) ──────────────────────
# open_shell's last act is `exec podman exec -it ... cs193v-shell`, and cs193v-shell
# attaches tmux, which switches the terminal to its alternate screen — erasing everything
# printed before it. So every warning the launcher has was displayed and none of them was
# readable: the dev-image advisory, "the tunnel did not come up", "these ports are already
# in use". The launcher now stops for ENTER whenever it warned.
#
# The shim's launches warn with no arranging needed: the fake podman cannot serve an ssh
# tunnel, so the tunnel fails and warn.tunnel-failed is printed.
#
# This used to warn TWICE, the second being a dev-image advisory for an unpinned IMAGE.
# That warning is gone -- a locally built image is now the normal case, not a fault -- so
# the tunnel failure is the only warning left to hang this on. Any surviving warning would
# do; what is being tested is the ENTER gate, not which warning triggered it.
#
# exec_out makes the moment the container is opened visible in the transcript: it is what
# the fake prints for the final `podman exec -it`, and that is the only exec whose output
# is not captured or discarded by the launcher.
shim_new
shim_set exec_out "SHELL-OPENED"
out="$(launcher_tty '\nexit\n' | strip_ansi)"
assert_says "ack:a-warned-launch-asks-for-enter" "Press ENTER to continue" "$out"
# The warning itself has to still be on screen at that point — acknowledging a message you
# cannot see is no better than not being shown it.
assert_says_key "ack:the-warning-is-still-on-screen" warn.tunnel-failed "$out"
# ENTER goes on to open the shell rather than giving up.
assert_contains "ack:enter-then-opens-the-shell" "cs193v-shell" "$(shim_log)"
# And the prompt comes BEFORE the container is opened, not after it has already swallowed
# the screen. Line numbers from the transcript, so this asserts on order, not just presence.
p_ack="$(printf '%s\n' "$out" | grep -n 'Press ENTER to continue' | head -1 | cut -d: -f1)"
p_shell="$(printf '%s\n' "$out" | grep -n 'SHELL-OPENED' | head -1 | cut -d: -f1)"
if [ -n "$p_ack" ] && [ -n "$p_shell" ] && [ "$p_ack" -lt "$p_shell" ]; then
    pass "ack:prompt-comes-before-the-container-is-opened"
else
    fail "ack:prompt-comes-before-the-container-is-opened" \
         "prompt at line ${p_ack:-none}, shell opened at line ${p_shell:-none}:
$out"
fi

# It WAITS, rather than printing a prompt and carrying on regardless — which is the whole
# of the fix, and what an ordering check alone cannot tell apart. Driven with a terminal
# that stays open and says nothing, so nothing can be mistaken for an answer.
shim_new
shim_set exec_out "SHELL-OPENED"
launcher_pty_silent_start
if launcher_pty_silent_wait 30 'Press ENTER'; then
    pass "ack:prompt-reached-on-a-silent-terminal"
    assert_eq "ack:silence-does-not-open-the-shell" "0" "$(shim_count '^exec -it')"
else
    fail "ack:prompt-reached-on-a-silent-terminal" \
         "the launcher never asked, or exited without asking:
$(cat "$PTY_OUT" 2>/dev/null)"
    fail "ack:silence-does-not-open-the-shell" "no prompt was reached, so nothing was held"
fi
launcher_pty_silent_stop

# A launch with nothing to say must NOT stop for an acknowledgement. A pause on every
# single launch teaches a student to press ENTER without reading, which costs the fix its
# whole value — the prompt has to mean "there is something here".
#
# Two things are arranged so a shim launch has nothing to say: an ssh that succeeds, so the
# tunnel does not fail, and an image whose recipe label matches the files on disk, so the
# stale-recipe check has nothing to speak up about. A pinned IMAGE used to do that second job
# by skipping the check outright; there is no pin any more, so the image is BUILT, which is
# both how the label actually gets onto it and what a student's own machine does.
shim_new
shim_fake_ssh
shim_set exec_out "SHELL-OPENED"
launcher --rebuild --no-cache >/dev/null 2>&1
out="$(launcher_tty 'exit\n' | strip_ansi)"
# By KEY, and it had to change to keep meaning anything: this asserted on "NOTE:", the prefix of
# the dev-image advisory, which no longer exists anywhere in the launcher or messages.txt -- so it
# could not fail. The tunnel failure is the warning this arrangement actually suppresses.
assert_says_not_key "ack:a-quiet-launch-warns-about-nothing" warn.tunnel-failed "$out"
assert_says_not "ack:a-quiet-launch-does-not-stop" "Press ENTER to continue" "$out"
assert_contains "ack:a-quiet-launch-still-opens-the-shell" "SHELL-OPENED" "$out"

# Warning and prompting are separate: the verbs warn too, and they return to the student's
# own shell with their output intact, so stopping them would be a pause for nothing.
# Through a pty, or the acknowledgement would decline to prompt for want of a terminal and
# this would pass without asserting anything.
shim_new
out="$(launcher_tty '\n' --reset-tunnel | strip_ansi)"
assert_says "ack:a-verb-still-warns" "no container running" "$out"
assert_says_not "ack:a-verb-does-not-stop-to-be-acknowledged" "Press ENTER to continue" "$out"

# ─── malformed args files ──────────────────────────────────────────────────────
shim_new
assert_says "args:missing-file-refused" "container.args is missing" \
    "$(rm -f "$COPY/.config/container.args.bak"; mv "$COPY/.config/container.args" "$COPY/.config/container.args.bak"; \
       launcher; mv "$COPY/.config/container.args.bak" "$COPY/.config/container.args")"

# A container.args holding only comments leaves ARGS empty. Expanding an empty array under
# `set -u` is fatal on bash < 4.4 — every Mac — so this must produce our output, not a raw
# "ARGS[@]: unbound variable" from bash.
shim_new
cp "$COPY/.config/container.args" "$SHIM/ca.bak"
printf '# every line here is a comment\n# and nothing else\n' > "$COPY/.config/container.args"
out="$(launcher --dev-print-command)"
assert_not_contains "args:comment-only-no-unbound-variable" "unbound variable" "$out"
assert_not_contains "args:comment-only-no-bash-error"       "cs193v: line"     "$out"
assert_contains     "args:comment-only-still-prints-a-run-line" "podman run"   "$out"
out="$(launcher)"
assert_not_contains "args:comment-only-launch-no-bash-error" "unbound variable" "$out"
cp "$SHIM/ca.bak" "$COPY/.config/container.args"

# Blank lines, extra whitespace and inline comments must all be tolerated.
shim_new
cp "$COPY/.config/container.args" "$SHIM/ca.bak"
printf '\n   \n   --network=pasta   # trailing comment\n\n-e FOO=bar\n' \
    > "$COPY/.config/container.args"
line="$(launcher --dev-print-command)"
assert_contains "args:whitespace-tolerated" "--network=pasta" "$line"
assert_contains "args:second-flag-kept"     "-e FOO=bar"      "$line"
assert_not_contains "args:inline-comment-dropped" "trailing"  "$line"
cp "$SHIM/ca.bak" "$COPY/.config/container.args"

# ─── what a BUILD SHOWS a student  (issues #22, #23, #24) ──────────────────────
# The build is the longest thing this course asks a student's computer to do, and until
# now it reported itself entirely in podman's voice: every STEP line with the whole shell
# command in it, thousands of lines on a cold build, ending -- after `Setting up the course
# container...` -- with nothing at all. No indication it had worked.
#
# WHY NOTHING CAUGHT THIS. There was no coverage of the build's OUTPUT to miss it with. The
# shim tier asserted that the build verb calls `podman build` (shim_count '^build ') and the live
# tier asserted the image exists afterwards; both are about what the launcher DOES, and
# neither reads a line of what the student is shown. The fake podman helped hide it too --
# its `build` printed a single "Successfully tagged" line, so even a test that had looked at
# the output would have seen nothing resembling a real build. It emits real STEP lines now.
shim_new
shim_set state absent
COPY="$(repo_copy)"
LAUNCHER_DIR="$COPY"
out="$(launcher --rebuild --no-cache)"

# --- what it DOES, before what it shows ----------------------------------------
# These three moved here from the deleted --update tier, which is where they used to live.
# `--rebuild` is the only path to a new image now, so this is the only place they can live.
#
# The label is the load-bearing one: without it nothing downstream can tell a stale image from
# a current one — see ensure_container and doctor — and a bare `podman build` produces an
# image without it, which is exactly the hazard CLAUDE.md warns staff about.
assert_eq "build:builds"                  "1" "$(shim_count '^build ')"
assert_eq "build:creates-the-container"   "1" "$(shim_count '^run ')"
assert_contains "build:labels-the-recipe" "cs193v.buildhash=" "$(shim_log | grep '^build ')"

# --- #23: podman's own output must not be what the student reads ---------------
# The needle is the COMMAND TEXT, not the word STEP: it is the shell being echoed back --
# `RUN set -eux; apt-get install ...` -- that makes the real thing unreadable, and a
# progress line is entitled to say "step 12 of 23" in its own words.
assert_not_contains "build:no-raw-podman-commands" "apt-get install -y package-number" "$out"
assert_not_contains "build:no-raw-cache-lines"     "--> Using cache"                   "$out"
assert_says_not     "build:no-raw-commit-line"     "COMMIT localhost"                  "$out"

# ...but SOMETHING has to move, or this is just a four-minute silence with better manners.
# The last step must be reached: a progress display that stalls at 3/23 and then succeeds
# is worse than none, because it reads as a hang.
#
# Matched on the BAR, not on the bare count. "1/23" appears in podman's own `STEP 1/23:`
# line, so asserting that alone passes against the raw output this is meant to replace --
# which is exactly what it did when first written. The bracketed bar cannot.
assert_contains "build:draws-a-progress-bar"           "█"          "$out"
assert_match    "build:progress-starts-at-the-first-step" '\] +1/23'  "$out"
assert_match    "build:progress-reaches-the-last-step"    '\] +23/23' "$out"

# The prose that explains what is happening stays -- it is the only place a student is told
# this is normal and interruptible.
assert_says "build:still-explains-the-wait" "safe to run again" "$out"

# --- #22: it must say it worked ------------------------------------------------
assert_says "build:announces-success"        "Build Successful"      "$out"
assert_says "build:success-names-the-next-command" "./cs193v"        "$out"
assert_says "build:success-is-friendly"      "Happy vibecoding"      "$out"
# Drawn in the same box everything else is drawn in, and closed -- see 20-messages.sh, which
# owns box(). Asserted here too because this is the FIRST non-error thing ever put in one.
#
# THIS COMMENT USED TO CLAIM require_cmd COVERED IT, and the claim was the defect (#79). It said
# that swallowing box_problems' failure "would turn the checker could not run into a pass", which
# is true, and then guarded it with `command -v` -- which is satisfied by an interpreter that
# exists and cannot run a program. Measured: with a sabotaged python3 first on $PATH the guard
# passed and this assertion went vacuous anyway.
#
# What actually covers it is box_problems answering with $CHECKER_DIED, which every assertion
# below refuses. require_python3 is the other half: it runs a program rather than looking one up.
require_python3
probs="$(printf '%s\n' "$out" | box_problems)"
if [ -z "$probs" ]; then
    pass "build:success-box-is-closed"
else
    fail "build:success-box-is-closed" "$probs"
fi

# --- #24: the container-creation step must not go silent -----------------------
# `podman run` is given up to 180 seconds and, on a machine slow enough to need them, said
# nothing for all of them. The last line a student saw was "Setting up the course
# container..." -- which is exactly what an interrupted command looks like.
assert_says "build:creation-step-is-announced" "Setting up the course container" "$out"
assert_says "build:creation-step-reports-done" "Ready"                           "$out"

# --- the staff path keeps the raw output ---------------------------------------
# CS193V_BUILD_RAW is the staff switch for podman's raw output. A progress bar is the wrong
# instrument for debugging a build that HANGS -- the one failure $BUILD_LOG cannot be read for
# afterwards -- and having the switch is what makes hiding the output from a student affordable.
#
# --no-cache, NOT `shim_set state absent`. An absent CONTAINER does not make the launcher build:
# podman-fake reports image_exists=yes and carries no buildhash, so the hash gate reads
# "unknown, do not nag" and --rebuild recreates without building. There would then be no raw
# output to find, and -- worse -- the negative assertion below would pass VACUOUSLY.
shim_new
shim_set state absent
out="$(CS193V_BUILD_RAW=1 launcher --rebuild --no-cache)"
assert_contains "build-raw:keeps-raw-podman-output" "apt-get install -y package-number" "$out"
# ...and the default does NOT, which is the half that protects the student. Asserted here
# rather than trusted, because an env var read at the wrong moment defaults the wrong way
# silently -- there is no error, just a wall of shell at a first-year student.
shim_new
shim_set state absent
out="$(launcher --rebuild --no-cache)"
# The anti-vacuity guard for the assertion below: status.building is printed by build_image on
# both output paths, so this proves a build really was attempted and the absence of podman's
# words is a choice rather than an absence of anything to hide.
assert_says "build-raw:default-still-built-something" "Building the course container" "$out"
assert_not_contains "build-raw:default-hides-raw-podman-output" \
                    "apt-get install -y package-number" "$out"

# --- a FAILED build must still be diagnosable ----------------------------------
# The consequence of #23 that is easy to miss. err.build-failed said "Podman's own output is
# on the screen above this box, ending at the step that failed" -- true only for as long as
# the raw output WAS on the screen. Hiding it without changing this makes the launcher lie
# to a student at the exact moment they are stuck, so the failing output has to come back
# INSIDE the box.
shim_new
shim_set state absent
shim_set build_rc 1
shim_set build_out 'STEP 6/23: RUN curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key
curl: (6) Could not resolve host: deb.nodesource.com
Error: building at STEP "RUN curl -fsSL https://deb.nodesource.com/...": exit status 6'
out="$(launcher --rebuild --no-cache 2>&1)"
assert_contains "build-failed:shows-the-failing-step"   "STEP 6/23"                     "$out"
assert_contains "build-failed:shows-podmans-diagnosis"  "Could not resolve host"        "$out"
assert_says     "build-failed:says-it-is-safe-to-retry" "safe to run it again"          "$out"
assert_says_not "build-failed:no-longer-claims-output-is-above" "on the screen above"   "$out"
assert_eq       "build-failed:exits-nonzero" "1" "$(launcher_rc --rebuild --no-cache)"

# --- the terminal case, which is the one a student is in ----------------------
# Everything above runs with stdout redirected, where both indicators deliberately fall
# back to plain lines. The redraw-in-place behaviour only exists on a pty, so it can only
# be seen from one -- and it is the whole point of #23 and #24.
shim_new
shim_set state absent
# A DELAY ON `run`, for the reason the block below spells out at length: the creation caption is
# drawn by the meter's animator at 10 Hz, and the fake podman's `run` returns in milliseconds.
# Until #38 the WAIT supplied that delay by accident -- the poll loop inside run_timeout noticed
# a finished child only on its next 100ms tick, so there was always a frame in which to draw the
# caption. With the wait exact, the label can now be written and cleared between two frames, and
# what was asserted here was the polling rather than the animation.
shim_set run_delay 0.3
raw="$(launcher_tty '' --rebuild --no-cache)"

# "One line that moves" means the bar is drawn AFTER a carriage return -- without that it
# would be 23 bars scrolling past, which is not obviously better than 23 STEP lines.
#
# Asserted as "some \r-delimited segment contains a bar" rather than by matching a literal
# "\r  [". The prefix is not the property: the meter now draws an animation frame between
# the margin and the bracket, so a literal needle pinned the layout rather than the
# behaviour and broke on a change that kept the behaviour intact.
redrawn() {                           # redrawn NEEDLE  <- transcript on stdin
    python3 -c '
import sys, re
raw = sys.stdin.buffer.read().decode("utf-8", "replace")
needle = sys.argv[1]
segs = [re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", s) for s in raw.split("\r")[1:]]
print("yes" if any(needle in s for s in segs) else "no")' "$1"
}
assert_eq "build:bar-redraws-in-place-on-a-terminal" "yes" \
          "$(printf '%s' "$raw" | redrawn '[█')"
# The creation step animates rather than sitting silent. One frame is enough to prove it is
# wired up -- against the fake podman `run` returns at once, and a real one is what makes it
# spin. The frame is drawn before the first poll for exactly this reason.
assert_eq "build:creation-step-animates-on-a-terminal" "yes" \
          "$(printf '%s' "$raw" | redrawn 'Setting up the course container')"

# --- one line, and the setup step is part of it -------------------------------
# Asserted against the rendered SCREEN, not the byte stream. A \r-redrawn bar appears in the
# transcript once per step and on screen once, so counting occurrences in the raw bytes
# answers a different question from the one being asked here. See render_pty in lib.
#
# Both bugs below were shipped by the first version of the progress bar and neither was
# catchable by the assertions that came with it, because those all read the non-tty form --
# which has no \r, no overdrawing and therefore neither defect.
shim_new
shim_set state absent
# DELAYS ARE REQUIRED, not incidental. With every line available at once the download phase is
# over inside a millisecond, and creating the container returns instantly -- while the animator
# draws ten times a second. Both rows would then be asserted against a frame that may or may
# not have been drawn, which is a coin toss rather than a test.
shim_set build_delay 0.05
shim_set run_delay 0.3
# Real cold-build shape: podman pulls the base image before STEP 1 exists.
shim_set build_out 'Trying to pull docker.io/library/ubuntu:26.04...
Getting image source signatures
Copying blob sha256:aaaa
Copying blob sha256:bbbb
Copying config sha256:cccc
Writing manifest to image destination
STEP 1/3: FROM ubuntu:26.04
STEP 2/3: RUN apt-get install -y something
--> Using cache abcdef
STEP 3/3: LABEL x=y
COMMIT localhost/cs193v:local
Successfully tagged localhost/cs193v:local'
# Kept BOTH forms of one run: the rendered screen answers "what does the student end up
# looking at", the raw transcript answers "what was drawn in a single redraw". Neither
# question can be asked of the other's form.
raw="$(launcher_tty '' --rebuild --no-cache)"
screen="$(printf '%s' "$raw" | render_pty)"

# THE BLOCK IS TWO ROWS, and the step name has a row of its own directly under the bar. That
# reverses what this file used to assert, deliberately: once every step is named and a retry
# can be reported beside the bar, what the meter has to say no longer fits one line, and a
# line that wraps breaks \r redrawing outright -- the bar smears across two rows and never
# recovers, which is the failure the one-line form was always one long label away from.
#
# What must still hold is that the name belongs to the BLOCK: drawn in the same frame as the
# bar, on the row immediately below it, never stranded elsewhere on the screen.
#
# FRAMES ARE RECONSTRUCTED FROM THE TRANSCRIPT rather than read off the final screen, because
# a successful build collapses the block to its one finished line -- by the end there is no
# caption row left to look at.
# The caption is found by looking for the next segment that STARTS WITH A NEWLINE rather than
# by taking the one after the bar, and that is not fussiness: the pty is in cooked mode, so
# ONLCR turns the meter's \r\n into \r\r\n and leaves an empty segment between the two rows.
# Pinning the offset would make this assert something about the tty layer instead of about the
# launcher. The caption row is the one the line feed opens, whether or not it has any words in
# it -- an empty one is what "labels are switched off" looks like.
frame_pairs() {                       # transcript on stdin -> "BAR<TAB>CAPTION" per frame
    python3 -c '
import sys, re
raw = sys.stdin.buffer.read().decode("utf-8", "replace")
segs = [re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", s) for s in raw.split("\r")]
for i, s in enumerate(segs):
    if re.search(r"\]\s+\d+/\d+", s):
        cap = ""
        for t in segs[i + 1:i + 4]:
            if t.startswith("\n"):
                cap = t.strip(); break
        print(s.strip() + "\t" + cap)'
}
TAB="$(printf '\t')"
pairs="$(printf '%s' "$raw" | frame_pairs)"

# ISSUE 1. The download used to be a note printed with a trailing newline, which sent the
# bar's \r to the row below it and left the note stranded above a bar of its own. It is step 1
# of the meter now -- podman resolves FROM by pulling, and numbers that step 1 itself -- so it
# arrives with a bar and a name like every other step.
assert_match "build:download-is-step-one-with-a-bar" \
             "\] +1/[0-9]+$TAB""Downloading the base image" "$pairs"

bars="$(printf '%s\n' "$screen" | grep -c '\[█\|\[░' || true)"
assert_eq "build:exactly-one-progress-bar-on-screen" "1" "${bars:-0}"

# ISSUE 3. Creating the container is the slowest single step and was outside the meter, so
# the bar completed at 3/3 and the student then waited on an unmetered line. It counts as
# the n+1'th step now, and its name goes in the block like the rest.
assert_match "build:meter-counts-container-setup-as-a-step" '\] +4/4' "$screen"
# The count is not pinned here: the bar holds at the last step podman announced WHILE the
# container is being created and only completes when it returns, which is the honest reading of
# a step that is still running. What matters is that the name is in the block.
assert_match "build:setup-label-sits-in-the-meter-block" \
             "\] +[0-9]+/4$TAB""Setting up the course container" "$pairs"

# The finished block is ONE row: the caption is erased, the outcome takes the spinner's cell
# and the closing word moves up beside the bar. A student is not left looking at a spinner
# frame beside a build that has finished, which is what this did before.
assert_match "build:finished-block-collapses-to-one-row" '✓ .*\] +4/4  Ready' "$screen"
if printf '%s\n' "$screen" | grep -qxE ' *Setting up the course container\.\.\. *'; then
    fail "build:no-caption-row-survives-the-collapse" \
         "the caption row is still on the screen after the build finished:
$screen"
else
    pass "build:no-caption-row-survives-the-collapse"
fi


# --- ISSUE 2: something must move while a step is in progress ------------------
# The bar advances only when podman finishes a step, and the slow steps (Chromium,
# Playwright) hold one frame for minutes. A meter that sits perfectly still for that long
# reads as a hang, which is the thing the whole feature exists to prevent.
#
# NOT TESTABLE FROM THE NON-TTY FORM, and not testable from a build that finishes at once
# either -- with every line available immediately there is no interval during which a step
# is "in progress". build_delay makes podman dribble its output out so there is.
shim_new
shim_set state absent
shim_set build_delay 0.4
shim_set build_out 'STEP 1/2: FROM ubuntu:26.04
STEP 2/2: RUN something-slow
COMMIT localhost/cs193v:local
Successfully tagged localhost/cs193v:local'
raw="$(launcher_tty '' --rebuild --no-cache)"

# Braille, because the frames have to be distinguishable from each other at a glance and
# from the ASCII / - \ | spinner this replaced.
frames="$(printf '%s' "$raw" | python3 -c '
import sys
s = sys.stdin.buffer.read().decode("utf-8", "replace")
seen = []
for ch in s:
    if 0x2800 <= ord(ch) <= 0x28FF and ch not in seen:
        seen.append(ch)
print("".join(seen))')"
if [ -n "$frames" ]; then
    pass "build:animation-uses-braille-frames"
    record "build:frames-observed" "$frames"
else
    fail "build:animation-uses-braille-frames" "no U+2800-U+28FF glyph anywhere in the output"
fi

# The real assertion: it ADVANCES. One frame proves a character was printed; several
# distinct ones prove something is redrawing while podman is still working on a step.
nframes="$(printf '%s' "$frames" | python3 -c 'import sys; print(len(sys.stdin.read().strip()))')"
if [ "${nframes:-0}" -ge 3 ]; then
    pass "build:animation-advances-while-a-step-is-slow"
else
    fail "build:animation-advances-while-a-step-is-slow" \
         "only ${nframes:-0} distinct frame(s); a still meter is the failure being tested for"
fi

# And the ASCII spinner must be gone rather than merely unused -- a frame table left behind
# is what the next person copies.
assert_eq "build:no-ascii-spinner-frames-remain" "0" \
          "$(grep -c "ch='|'" "$REPO/cs193v" || true)"


# ─── the meter says what the build is DOING ────────────────────────────────────
# The side text used to be blank for the whole build: two labels existed, one for the download
# and one for creating the container, and between them a student watched a bar advance with no
# idea what it was working on. Every step is named now, from `####>` markers in the
# Containerfile, which the launcher parses because podman emits no comments and never re-runs
# a cached RUN.
#
# The fixture's STEP lines echo the REAL Containerfile's instructions, which is what makes the
# labels line up: the launcher checks each step's echoed text against what it parsed and
# switches labels off if they disagree. So this is also the test that the check does not
# misfire on a build that is telling the truth.
#
# ASSERTED ON THE PIPED FORM, deliberately, and this is the one place where that form is the
# better instrument. Piped output is one line per step, emitted BY the step -- so every step
# that podman announces is in it exactly once. The pty form is sampled by an animator running
# at a fixed rate, so which steps happen to be caught depends on how long each one took, and a
# label that is correct but held for 40ms would fail an assertion about a display that is
# working perfectly. Layout is what the pty form is for; content is what this is for.
shim_new
shim_set state absent
{ "${LAUNCHER_DIR:-$REPO}/cs193v" --dev-steps \
      | awk -F'\t' -v n=25 '{ printf "STEP %d/%d: %s\n", $1, n, $3 }'
  printf 'STEP 25/25: LABEL "cs193v.buildhash"="deadbeef"\n'
  printf 'COMMIT localhost/cs193v:local\nSuccessfully tagged localhost/cs193v:local\n'
} > "$SHIM/build_out"
# --no-cache is what FORCES the build, and it is not decoration. --rebuild is the only verb that
# builds now, and it builds only when the recipe moved or the image is missing -- podman-fake
# reports image_exists=yes, so without this it would recreate the container and never call
# `podman build` at all, and every assertion below would pass vacuously against no output.
out="$(launcher --rebuild --no-cache)"

# Named steps, spread across the build rather than only at its ends. The count is podman's own
# 25 here: the +1 for creating the container exists only where there is a meter to put it in.
assert_match "labels:names-the-node-step"      '\] +[0-9]+/25  Installing Node'           "$out"
assert_match "labels:names-the-chromium-step"  '\] +[0-9]+/25  Installing Chromium'       "$out"
assert_match "labels:names-the-vercel-step"    '\] +[0-9]+/25  Installing the Vercel CLI' "$out"
assert_match "labels:names-the-codex-step"     '\] +[0-9]+/25  Installing Codex'          "$out"
assert_match "labels:names-the-first-step"     '\] +1/25  Downloading the base image'     "$out"
# The tail of the file is ENV/USER/WORKDIR/ENTRYPOINT plus the LABEL podman synthesizes from
# our own --label flag. None of them has a marker of its own, and the last one has no line in
# the Containerfile at all, so all five inherit the closing marker rather than going blank.
assert_match "labels:tail-steps-inherit-the-closing-marker" '\] +25/25  Finishing up' "$out"
# EVERY step is named. The whole point is that the side text is never blank mid-build, so a
# step that reached the bar without a name is the regression to catch.
unnamed="$(printf '%s\n' "$out" | grep -cE '\] +[0-9]+/25 *$' || true)"
assert_eq "labels:no-step-is-left-unnamed" "0" "${unnamed:-0}"

# And on a terminal the same labels ride in the block, on the row under the bar. Layout only --
# see above for why the content assertions do not live here.
shim_set build_delay 0.05
raw="$(launcher_tty '' --rebuild --no-cache)"
pairs="$(printf '%s' "$raw" | frame_pairs)"
assert_match "labels:ride-in-the-block-on-a-terminal" \
             "\] +[0-9]+/26$TAB""Installing " "$pairs"
# 26 = 24 instructions + podman's injected LABEL step + creating the container. The count the
# meter commits to comes from podman; the parse only supplies it before podman has spoken.
#
# The instruction count moved by TWO when codex arrived, not one: `ARG CODEX_VERSION` is an
# instruction in its own right and gets its own step, which is worth knowing before assuming a
# new layer costs +1 here.
assert_match "labels:total-counts-every-step" '\] +26/26' "$(printf '%s' "$raw" | render_pty)"

# A step is never labelled with a guess. If podman echoes an instruction that is not the one
# the launcher parsed, its whole mapping is suspect -- so the labels stop rather than name the
# wrong step, and the build carries on. A missing label is unhelpful; a wrong one is a lie.
#
# The build log this asserts on is unambiguously the one THIS launch wrote, rather than whichever
# instance last built on this machine, because shim_new points the launcher's TMPDIR at $SHIM/tmp.
shim_new
shim_set state absent
shim_set build_out 'STEP 1/3: FROM something-the-containerfile-does-not-say
STEP 2/3: RUN neither-is-this
STEP 3/3: LABEL x=y
COMMIT localhost/cs193v:local
Successfully tagged localhost/cs193v:local'
raw="$(launcher_tty '' --rebuild --no-cache)"
screen="$(printf '%s' "$raw" | render_pty)"
pairs="$(printf '%s' "$raw" | frame_pairs)"
assert_says     "mismatch:build-still-succeeds"  "Build Successful" "$screen"
assert_match    "mismatch:bar-and-count-survive" '\] +4/4'          "$screen"
# No CONTAINERFILE label survives the mismatch. Two things deliberately still do, and naming
# them is the point of matching on the labels themselves rather than on "any caption":
#
#   * "Setting up the course container..." comes from messages.txt, not from the parse, so it
#     must keep working when the parsed labels are switched off;
#   * "Downloading the base image..." can appear BEFORE the first STEP line, because that is
#     the window in which podman has not said anything to contradict the parse yet. Showing a
#     name during the download at all requires trusting the parse until podman speaks, and it
#     stops the instant it does.
assert_not_match "mismatch:no-label-is-guessed" \
                 "$TAB""(Installing|Adding |Caching|Finishing|Creating the student)" "$pairs"
# ...and it is recorded where staff will find it, which is the log a stuck student is asked
# for. Not on the screen: on a terminal that belongs to the meter, and it is not something a
# student can act on.
notes="$(cat "$SHIM"/tmp/cs193v-build-*.log 2>/dev/null | grep -c 'not the instruction' || true)"
assert_ne "mismatch:recorded-in-the-build-log" "0" "${notes:-0}"
assert_says_not "mismatch:not-shown-to-the-student" "not the instruction" "$screen"


# ─── a retry is reported BESIDE the bar, not underneath it ─────────────────────
# What this replaces: three lines of yellow prose per attempt, printed under the meter, which
# scrolled the block up the screen and put a warning a student cannot act on in front of a
# build that then went on to succeed. STOP is the banner that means "stop"; a retry is not one.
#
# build_die_at fails the FIRST attempt only, after announcing the step that fails -- podman's
# own order, and the launcher depends on it: the step that failed is the last STEP line in the
# log, which is what it reads to hold the bar there.
#
# THE BUILD IS FORCED BY AN ABSENT IMAGE HERE, NOT BY --no-cache, and that is the one thing in
# this section that cannot be changed for tidiness. build_image sets tries=1 when it is handed
# --no-cache, because --no-cache throws away every cached layer and a retry would restart a
# twenty-minute build from zero -- so under --no-cache there is no second attempt, no retry, and
# `(retrying: 1/2)` can never be drawn. The assertions below would then fail for a reason that
# has nothing to do with the display they are about. An absent image forces the build and leaves
# tries=3 alone.
shim_new
shim_set state absent
shim_set image_exists no
shim_set build_steps 12
shim_set build_die_at 7
# THE DELAY IS WHAT MAKES THE MARKER CATCHABLE, and 0.15 was not enough. The marker is only in
# the state file from the start of the retry until the first step PAST the one that failed, and
# the cached steps ahead of it replay instantly -- so that window is one step's delay long, and
# at 0.15 it was a single frame out of twenty. That frame is missed whenever the machine is busy
# enough to stretch the animator's interval, which is exactly what running five suites at once
# does. Doubled, so the window spans three frames and the assertion is about the display rather
# than about the load average.
shim_set build_delay 0.3
raw="$(launcher_tty '' --rebuild)"
screen="$(printf '%s' "$raw" | render_pty)"
pairs="$(printf '%s' "$raw" | frame_pairs)"

assert_match "retry:marker-appears-beside-the-bar" '\(retrying: 1/2\)' "$pairs"
# RETRIES, not attempts: tries=3 means two of them, and a student who sees 2/2 has seen the
# last one rather than a budget with one still in hand.
assert_not_match "retry:marker-counts-retries-not-attempts" '\(retrying: [0-9]+/3\)' "$pairs"
assert_says "retry:build-still-succeeds" "Build Successful" "$screen"
assert_says_not "retry:no-yellow-prose-under-the-meter" "Trying again"     "$screen"
assert_says_not "retry:no-retry-warning-text"           "did not finish"   "$screen"

# THE BAR DOES NOT REWIND. A retried build re-runs from step 1 and replays every completed
# step from the layer cache in about a second; that work is done and on disk, so counting it
# again from zero would tell a student they had lost twenty minutes they had not lost.
steps="$(printf '%s' "$raw" | python3 -c '
import sys, re
raw = sys.stdin.buffer.read().decode("utf-8", "replace")
segs = [re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", s) for s in raw.split("\r")]
ns = [int(m.group(1)) for s in segs for m in [re.search(r"\]\s+(\d+)/", s)] if m]
print("monotonic" if all(b >= a for a, b in zip(ns, ns[1:])) else "rewound to %r" % (ns,))')"
assert_eq "retry:bar-never-goes-backwards" "monotonic" "$steps"

# And the marker goes once the step it describes has succeeded, so a build that recovered from
# one dropped connection does not carry the word "retrying" to its final frame.
assert_not_match "retry:marker-is-gone-by-the-end" 'retrying' "$screen"

# ─── the cursor does not strobe, and is always given back ──────────────────────
# The block redraws ten times a second and leaves the cursor wherever the last write ended --
# the bar row on one frame, the caption row on the next -- so a terminal that blinks its cursor
# flashes it between two positions. Invisible in a transcript, which is exactly why the first
# version of this shipped with it: every assertion in this file reads bytes, and the bytes were
# perfect. Found by someone running an install and looking at it.
#
# THE ASSERTION THAT MATTERS IS THE LAST ONE. Hiding the cursor is a nicety; failing to give it
# back leaves the student typing blind in that terminal afterwards, which is far worse than the
# strobe this fixes. So the test is not "does it hide" but "is the final cursor sequence in the
# whole transcript a SHOW", checked on success and on failure, since those exit by different
# routes -- meter_stop then a box, versus meter_stop then die.
cursor_last() {                       # transcript on stdin -> hidden | shown | none
    python3 -c '
import sys, re
raw = sys.stdin.buffer.read().decode("utf-8", "replace")
seq = re.findall(r"\x1b\[\?25([lh])", raw)
print("none" if not seq else ("hidden" if seq[-1] == "l" else "shown"))'
}

shim_new
shim_set state absent
shim_set build_steps 4
shim_set build_delay 0.1
raw="$(launcher_tty '' --rebuild --no-cache)"
assert_contains "cursor:hidden-while-the-meter-runs" "$(printf '\033')[?25l" "$raw"
assert_eq "cursor:restored-after-a-successful-build" "shown" "$(printf '%s' "$raw" | cursor_last)"

# Not a terminal -> nothing animates, so there is nothing to hide and no sequence to leak into
# a log file a student sends to staff.
out="$(launcher --rebuild --no-cache)"
assert_not_contains "cursor:no-escape-sequences-when-piped" "$(printf '\033')[?25" "$out"

shim_new
shim_set state absent
shim_set build_steps 6
shim_set build_rc 1
raw="$(launcher_tty '' --rebuild --no-cache)"
assert_eq "cursor:restored-when-the-build-fails" "shown" "$(printf '%s' "$raw" | cursor_last)"

# And the rendered screen must be free of them, or every other screen assertion in this file is
# reading cursor-control bytes as if they were something the student saw. render_pty strips
# private-mode sequences only because it was taught to; a class of [0-9;] alone does not.
screen="$(printf '%s' "$raw" | render_pty)"
assert_not_contains "cursor:sequences-do-not-reach-the-rendered-screen" "25l" "$screen"

# ─── a failed build stops where it stopped ─────────────────────────────────────
# The closing frame used to fill the bar to tot/tot regardless, so a student got a COMPLETED
# progress bar directly above the words "the course container could not be built".
shim_new
shim_set state absent
shim_set build_steps 6
shim_set build_rc 1
raw="$(launcher_tty '' --rebuild --no-cache)"
screen="$(printf '%s' "$raw" | render_pty)"
assert_match     "build-failed:marks-the-block-as-failed" '✗' "$screen"
assert_not_match "build-failed:bar-is-not-drawn-complete" '\] +7/7' "$screen"
assert_match     "build-failed:bar-stops-where-it-stopped" '✗ .*\] +6/7' "$screen"
assert_not_match "build-failed:no-spinner-frame-left-behind" '[⣾⣽⣻⢿⡿⣟⣯⣷] .*\] +6/7' "$screen"

# ─── the build's output box ────────────────────────────────────────────────────
# The block has a third element now: a dim box under the caption row holding the last eight lines
# podman printed. The meter was honest but SILENT -- a bar, a count and a step name, none of
# which change on a human timescale during the four minutes when apt, npm and Chromium are the
# ones doing the work.
#
# ASSERTED ON A MID-BUILD SCREEN, which needs its own helper: both endings take the box away, so
# the final screen -- the form every other screen assertion in this file reads -- cannot answer a
# single question about it. Frames end with ESC[J (see meter_draw), so the transcript can be cut
# at any frame boundary and replayed.
#
# WHICH FRAME, AND THIS PARAGRAPH USED TO ARGUE THE OTHER WAY. It said the frame to take was the
# one before the last ESC[J -- derived from the protocol "rather than by hunting for box art,
# which on the failure path would find the STOP box instead". The protocol does not in fact say
# how many frames follow the last boxed one (#56), and the objection it raised against searching
# for the box turned out to be answerable: the thing to search for is the TITLELESS lid, which no
# message box can produce. So the selection is content-derived now, and the reason the old
# argument gave for not doing that is what TAILBOX_LID is for.

# THE TITLELESS LID IS THIS BOX'S SIGNATURE, and it is what tells it apart from a message box on
# the same screen. box() draws "┏━━ STOP " and "┏━━ Build Successful! "; this one has no title, so
# a run of bars straight after the corner can only be this.
#
# DEFINED ABOVE render_pty_mid because that function now selects on it.
TAILBOX_LID='┏━━━━'

render_pty_mid() {                    # transcript on stdin -> the prefix through the last box frame
    run_checker python3 -c '
import sys
raw = sys.stdin.buffer.read()
mark = b"\x1b[J"
lid = sys.argv[1].encode("utf-8")
parts = raw.split(mark)
# THE LAST FRAME THAT ACTUALLY DREW THE BOX, found by looking for the lid rather than by counting
# back from the end. This was `parts[:-2]` -- "the frame before the last ESC[J" -- which is the
# boxed one only when EXACTLY ONE frame follows it, and how many follow is a matter of timing:
# meter_stop draws the closing frame, and anything that redraws between the last line of the build
# and that close adds another. So a shift of one in the trailing count changed WHICH box six
# assertions were reading, and the wrong answer is a correctly drawn box that is simply older --
# which is why nothing downstream can notice it. See the group below for what that group of tests
# does and does not claim about the flake #56 reports.
#
# parts[i] is the text between mark i-1 and mark i, so joining parts[:i+1] and re-adding the mark
# reproduces the transcript through the frame that ended at mark i. parts[-1] is left out of the
# search: it is whatever followed the final mark, and no mark terminates it.
boxed = [i for i, part in enumerate(parts[:-1]) if lid in part]
if boxed:
    keep = parts[:boxed[-1] + 1]
else:
    # NO FRAME DREW A BOX AT ALL, which is a real answer rather than a failure: three assertions
    # here run the launcher in a terminal too small for the box and need a mid-build screen to
    # show that it is absent. Fall back to the positional rule so those read what they always did.
    keep = parts[:-2] if len(parts) > 2 else parts[:1]
sys.stdout.buffer.write(mark.join(keep) + mark)' "$TAILBOX_LID"
}

# ─── render_pty_mid picks the frame by content, not by position (#56) ──────────
# The selector is the shared dependency of six assertions at three call sites, and it is worth
# testing directly because the thing it can get wrong is invisible in all six: it returns a
# perfectly drawn box that is simply an OLDER one, and every assertion then reads a screen that
# looks right and predates the line it was asked about.
#
# SYNTHETIC TRANSCRIPTS, not a launcher run. The bug is a function of how many frames follow the
# last boxed one, and that is exactly what a real run will not hold still -- #56 records ten
# iterations standalone, ten under four CPU burners and ten on main, all of which passed, against
# one failure inside a full suite run. So the count is supplied here instead of raced for.
#
# WHAT THIS DOES AND DOES NOT CLAIM. It settles the selector's contract: given a transcript, the
# frame it returns is the last one that drew a box, whatever follows it. It does NOT reproduce the
# observed flake, and should not be read as having done so -- #56 could not force that failure in
# thirty attempts, and its other candidate mechanism is a last boxed frame whose CONTENT lagged the
# log, which no choice of frame can repair. That half is what the `run_delay 0.3` at all three call
# sites is for. Two independent mitigations for one observation, because the observation is a
# single data point and only one of the two can be tested deterministically.
#
# Two rows per frame, redrawn in place the way meter_draw does it: up two, carriage return, write
# both rows again, then ESC[J. That is the smallest thing render_pty will model as a block being
# overdrawn, which is what makes "the newest frame wins on screen" true at all.
MID_J="$(printf '\033[J')"
mid_frame() {                         # mid_frame ROW2 -> one two-row frame, cursor back at the top
    printf '\033[2A\rbar\n%s\n' "$1"
}
# oldest first: the box exists for three frames but its CONTENT only changes on the third, which
# is the every-third-frame refresh that makes the off-by-one selectable in the first place.
mid_boxed="$(mid_frame "$TAILBOX_LID STALE-BOX")$MID_J$(mid_frame "$TAILBOX_LID STALE-BOX")$MID_J$(mid_frame "$TAILBOX_LID FRESH-BOX")"
mid_close="$(mid_frame 'CLOSED')"
mid_extra="$(mid_frame 'CREATING')"
mid_tail='┏━━ Build Successful! ━━┓'

mid_screen() { printf '%s' "$1" | render_pty_mid | render_pty; }

# ONE trailing frame -- the shape the positional rule assumed, and the one it got right. Kept as
# the control: a fix that broke this would be trading one off-by-one for another.
one="$(mid_screen "$mid_boxed$MID_J$mid_close$MID_J$mid_tail")"
assert_contains "mid:with-one-frame-after-the-box-the-fresh-box-is-picked" "FRESH-BOX" "$one"
assert_not_contains "mid:with-one-frame-after-the-box-no-stale-box-survives" "STALE-BOX" "$one"

# TWO trailing frames -- the shape that produced the observed failure. The extra frame is not
# hypothetical: #38 made container creation an unlabelled run_timeout call returning in ~10ms
# where the old poll loop took ~100ms, which removed about one animator frame of slack.
two="$(mid_screen "$mid_boxed$MID_J$mid_extra$MID_J$mid_close$MID_J$mid_tail")"
assert_contains "mid:with-two-frames-after-the-box-the-fresh-box-is-still-picked" "FRESH-BOX" "$two"
assert_not_contains "mid:the-selected-screen-is-not-a-later-frame" "CREATING" "$two"
assert_not_contains "mid:the-selected-screen-is-never-the-closing-frame" "CLOSED" "$two"
# THE SAME SCREEN EITHER WAY, which is the property that makes the six assertions downstream
# independent of timing rather than merely lucky.
assert_eq "mid:the-trailing-frame-count-does-not-change-the-answer" "$one" "$two"

# AND WHEN NOTHING DREW A BOX, the fallback still answers with a mid-build screen rather than
# with the last one: tailbox:absent-on-a-very-short-terminal and its two siblings assert that no
# box is there, and they can only mean it about a frame from DURING the build.
none="$(mid_screen "$(mid_frame 'EARLY')$MID_J$(mid_frame 'MIDDLE')$MID_J$mid_close$MID_J$mid_tail")"
assert_contains     "mid:with-no-box-anywhere-it-falls-back-to-a-mid-build-frame" "MIDDLE" "$none"
assert_not_contains "mid:the-fallback-does-not-reach-the-closing-frame" "CLOSED" "$none"
# A transcript with no ESC[J at all takes the len(parts) > 2 arm and must not crash or come back
# empty -- the piped launcher draws no meter, and that is the transcript it produces.
assert_contains "mid:a-transcript-with-no-frames-comes-back-whole" "NOFRAMES" \
                "$(printf 'NOFRAMES' | render_pty_mid)"

# A 300-column line, built without seq or printf tricks so it reads the same on a Mac.
tailbox_long='LONG:'
while [ "${#tailbox_long}" -lt 300 ]; do tailbox_long="${tailbox_long}0123456789"; done

# THE LAST LINE IS NEVER EMITTED: shim_set writes the value with no trailing newline and the fake
# podman reads it with `while read`, which drops a final unterminated line. "Successfully tagged"
# is the deliberate sacrifice, and it leaves COMMIT as the newest line on the screen.
#
# The eight rows the box should end up holding are, oldest first: the tab line, a BLANK row, the
# coloured line, the progress line, the unicode line, the long line, the marker and COMMIT.
#
# NO SYNTHETIC `cs193v:` LINE IN HERE, and that is the point rather than an omission. This fixture
# already provokes a REAL one -- its `STEP 1/3: FROM ubuntu:26.04` is not the instruction the
# launcher parsed, so the label check fires and build_note_fold appends the genuine note to the
# log while the meter is still running. That is the only way those lines ever occur: appended at
# the END, behind a blank line the note itself supplies. An inline one, which is what this had at
# first, cannot be told apart from a blank podman printed and so tested the wrong thing.
tailbox_out="$(printf '%s\n' \
    'STEP 1/3: FROM ubuntu:26.04' \
    'Trying to pull docker.io/library/ubuntu:26.04...' \
    'Copying blob sha256:aaaa' \
    'STEP 2/3: RUN apt-get install -y something' \
    'STEP 3/3: LABEL x=y' \
    "$(printf 'a\ttab\tseparated\tline')" \
    '' \
    "$(printf '\033[1;32m+ apt-get install -y nodejs\033[0m')" \
    "$(printf 'Downloading |###   | 30%% of 167.7 MiB\rDownloading |######| 100%% of 167.7 MiB')" \
    'unicode ✔ check and ─ dash' \
    "$tailbox_long" \
    'ZZTOPMARKER is the newest line of the build' \
    'COMMIT localhost/cs193v:local' \
    'Successfully tagged localhost/cs193v:local')"

shim_new
shim_set state absent
shim_set build_delay 0.05
shim_set run_delay 0.3
shim_set build_out "$tailbox_out"
raw="$(launcher_tty '' --rebuild --no-cache)"
mid="$(printf '%s' "$raw" | render_pty_mid | render_pty)"

assert_contains "tailbox:appears-during-the-build" "$TAILBOX_LID" "$mid"
assert_contains "tailbox:shows-the-newest-line" 'ZZTOPMARKER is the newest line' "$mid"
# A BLANK LINE GETS A ROW rather than being swallowed to save one, so that a row here and a line
# in $BUILD_LOG can still be counted against each other. The window is full in this fixture, so an
# all-spaces body row can only be the blank line rendered -- it cannot be padding.
blanks="$(printf '%s\n' "$mid" | grep -c '^  ┃ *┃$' || true)"
assert_eq "tailbox:blank-lines-get-a-row-of-their-own" "1" "${blanks:-0}"

# --- what the sanitiser has to survive ----------------------------------------
assert_contains     "tailbox:tabs-become-spaces" 'a tab separated line' "$mid"
assert_contains     "tailbox:colour-is-stripped-but-not-the-words" '+ apt-get install -y nodejs' "$mid"
# The half that catches getting the ORDER wrong: filter the non-ASCII first and the ESC goes
# while its parameters stay, leaving a literal "[1;32mdone" on the screen.
assert_not_contains "tailbox:no-escape-parameters-survive" '1;32m' "$mid"
assert_contains     "tailbox:progress-line-shows-its-last-segment" '100% of 167.7 MiB' "$mid"
assert_not_contains "tailbox:progress-line-drops-what-it-overwrote" '30% of 167.7 MiB' "$mid"
assert_contains     "tailbox:non-ascii-is-dropped-not-mangled" 'check and' "$mid"
assert_not_contains "tailbox:no-multibyte-reaches-the-box-body" '✔' "$mid"
# Cut rather than wrapped. A 300-column line that became two rows would push every row above it
# up the screen, once per refresh.
assert_contains     "tailbox:long-lines-are-cut" '…' "$mid"

# --- what must not be in it ---------------------------------------------------
# The REAL note this fixture provokes, not a stand-in for one. It is the launcher talking about
# its own parse, addressed to staff, and it reaches them through the log either way.
assert_not_contains "tailbox:staff-notes-are-not-shown" \
                    'is not the instruction the launcher parsed' "$mid"
assert_not_contains "tailbox:staff-notes-leave-no-cs193v-prefix" 'cs193v: ' "$mid"
# AND NOT THE BLANK LINE THE NOTE BRINGS WITH IT. That newline is deliberate -- podman does not
# always terminate its last line, so without it the note would be glued onto podman output in the
# log staff read -- but it belongs to our text. Left in, it is the NEWEST line by the time
# build_note_fold has run, so the box would end on a blank row and give up a row of real content on
# every build where the check fires. Pinned by the row count above being 1 rather than 2.

# --- podman's own words, hashes included --------------------------------------
# COMMIT IDS STAY, and this is pinned rather than left to chance. They are 22 of the 134 lines of
# a warm build and keeping them costs half the window -- eight rows reach back to STEP 22 instead
# of STEP 19 -- but the box is a window onto what podman said rather than an edited version of it,
# and a student reading a line out to staff has to be able to find it in the log.
#
# BOTH SHAPES, because podman prints them two ways: "--> <hash>" between steps, and the finished
# image id on a line of its own at the end. A filter that came back would most likely come back
# knowing only about the arrow, which is exactly how the first version of this went.
#
# Its own fixture: the window in the one above is eight rows and already has eight things to say.
shim_new
shim_set state absent
shim_set build_delay 0.05
# A DELAY ON `run`, so the box this reads is one drawn from the COMPLETE log. render_pty_mid
# takes the frame before the last ESC[J, which assumes exactly one trailing frame after the last
# boxed one -- and how many the creation step produces is a matter of timing. Seven lines 50ms
# apart is barely one box refresh (the box redraws every third frame), so an off-by-one there
# selects a box drawn before podman printed the image id. Holding `run` open for 0.3s guarantees
# several complete box frames instead of exactly one, whichever frame is picked. Until #38 the
# poll loop inside run_timeout supplied that slack by accident: with a meter running the creation
# step is an UNLABELLED run_timeout call, so it now returns in ~10ms rather than ~100ms.
shim_set run_delay 0.3
shim_set build_out "$(printf '%s\n' \
    'STEP 1/2: FROM ubuntu:26.04' \
    'STEP 2/2: LABEL x=y' \
    '--> Using cache abcdef123456' \
    '--> 67c2a5fbf5f5' \
    'COMMIT localhost/cs193v:local' \
    'c78dcba8632d226f7d460bd4a70a14f856f5889dd0f5a490fcb686ea4e53462b' \
    'Successfully tagged localhost/cs193v:local')"
hashes="$(printf '%s' "$(launcher_tty '' --rebuild --no-cache)" | render_pty_mid | render_pty)"
assert_contains "tailbox:shows-podmans-short-commit-ids" '--> 67c2a5fbf5f5' "$hashes"
assert_contains "tailbox:shows-podmans-image-id" 'c78dcba8632d226f7d460bd4' "$hashes"
# On a warm build and during a retry's cache replay these are ALL there is, and they are what
# explains the bar racing back up to the step that failed.
assert_contains "tailbox:shows-cache-lines" '--> Using cache abcdef123456' "$hashes"

# --- it is a box, and it is part of the block ---------------------------------
# Eight rows whatever the log held, which is what keeps the two rows above it still.
rows="$(printf '%s\n' "$mid" | grep -c '^  ┃' || true)"
assert_eq "tailbox:is-eight-rows" "8" "${rows:-0}"
# One box, not one per frame: the block is redrawn in place, and this is the assertion that
# render_pty's ESC[nA and ESC[J modelling exists to make meaningful.
lids="$(printf '%s\n' "$mid" | grep -c '┏' || true)"
assert_eq "tailbox:exactly-one-box-on-screen" "1" "${lids:-0}"
assert_eq "tailbox:rows-line-up" "" "$(printf '%s\n' "$mid" | box_problems)"
# Two rows under the bar, with the caption row between them -- one block, not a box that happens
# to be somewhere on the same screen.
gap="$(printf '%s\n' "$mid" | awk '/\] +[0-9]+\/[0-9]+/ { bar = NR } /┏/ { lid = NR } END { print (bar && lid) ? lid - bar : "nothing found" }')"
assert_eq "tailbox:lid-sits-two-rows-under-the-bar" "2" "$gap"

# --- both endings take it away ------------------------------------------------
screen="$(printf '%s' "$raw" | render_pty)"
assert_not_contains "tailbox:gone-after-a-successful-build" "$TAILBOX_LID" "$screen"
assert_not_contains "tailbox:no-build-output-survives-the-collapse" 'ZZTOPMARKER' "$screen"
# The box that IS left is the green one, and it is still square: the ESC[J that erased eight rows
# had to stop at the right one.
assert_contains "tailbox:the-box-left-after-success-is-the-success-box" 'Build Successful' "$screen"
assert_eq "tailbox:success-box-is-intact" "" "$(printf '%s\n' "$screen" | box_problems)"

shim_new
shim_set state absent
shim_set build_delay 0.05
shim_set build_out "$tailbox_out"
shim_set build_rc 1
raw="$(launcher_tty '' --rebuild --no-cache)"
screen="$(printf '%s' "$raw" | render_pty)"
assert_not_contains "tailbox:gone-when-the-build-fails" "$TAILBOX_LID" "$screen"
assert_eq "tailbox:stop-box-is-intact" "" "$(printf '%s\n' "$screen" | box_problems)"
# AND THE FAILING LINES ARE STILL REPORTED. Taking the live box away on the failure path is only
# affordable because err.build-failed carries the tail of the log inside the STOP box -- wrapped
# rather than cut, and with the rest of the log behind it. If that ever stopped being true, this
# change would have removed the diagnosis rather than a duplicate of it.
assert_contains "tailbox:failing-lines-are-still-reported-in-the-stop-box" \
                'ZZTOPMARKER' "$screen"

# --- not a terminal, no box ---------------------------------------------------
# The piped form is what staff ask a student to send. A \r-redrawn box in it would be unreadable,
# and podman's raw voice is what issue #23 took out of it in the first place.
#
# A FRESH SHIM, and that is not tidiness: reusing the one above leaves build_rc at 1, the build
# fails, and err.build-failed then carries the tail of the log -- podman output, legitimately, in
# the STOP box. The assertion below would fail against a launcher that was behaving perfectly.
shim_new
shim_set state absent
shim_set build_out "$tailbox_out"
out="$(launcher --rebuild --no-cache)"
assert_not_contains "tailbox:not-drawn-when-piped" "$TAILBOX_LID" "$out"
assert_not_contains "tailbox:no-build-output-when-piped" 'ZZTOPMARKER' "$out"

# --- terminals too small for it ------------------------------------------------
# THE SIZE COMES FROM meter_fit's FALLBACK CHAIN, driven by a tput that fails. script starts its
# pty with no window size at all -- `stty size` reports 0 0 -- so tput answers from terminfo and
# every other test here silently gets 80x24. Breaking tput moves the answer to $LINES/$COLUMNS,
# which is the documented fallback and the only lever that works the same way on a Mac.
tailbox_at() {                        # tailbox_at ROWS COLS -> the mid-build screen
    shim_new
    shim_set state absent
    shim_set build_delay 0.05
    # THE THIRD CALL SITE, and until #56 the only one of the three without this. The selector above
    # no longer counts frames from the end, so a shift in the trailing count cannot move which box
    # is read -- but a build shorter than one box refresh can still produce NO complete box frame
    # at all, and then there is nothing for a content-derived selector to find and the fallback
    # returns a boxless screen. shrinks-to-fit-a-short-terminal asserts a row COUNT, so that would
    # read as 0 rows rather than as the wrong box. Cheap, and it makes all three sites agree.
    shim_set run_delay 0.3
    shim_set build_out "$tailbox_out"
    printf '#!/bin/sh\nexit 1\n' > "$SHIM/tput"
    chmod +x "$SHIM/tput"
    export LINES="$1" COLUMNS="$2"
    local t="$(launcher_tty '' --rebuild --no-cache)"
    unset LINES COLUMNS
    printf '%s' "$t" | render_pty_mid | render_pty
}

# 14 rows leaves room for six, not eight: the block stays half the screen rather than all of it.
mid="$(tailbox_at 14 80)"
rows="$(printf '%s\n' "$mid" | grep -c '^  ┃' || true)"
assert_eq "tailbox:shrinks-to-fit-a-short-terminal" "6" "${rows:-0}"

# Below four rows it goes entirely, and what is left is exactly the two-row block that shipped
# before it existed -- not a broken box, and not a block that has eaten the whole screen.
mid="$(tailbox_at 10 80)"
assert_not_contains "tailbox:absent-on-a-very-short-terminal" "$TAILBOX_LID" "$mid"
assert_match        "tailbox:bar-survives-a-very-short-terminal" '\] +[0-9]+/[0-9]+' "$mid"

# Same at the other edge: under 44 columns there is no text field worth drawing walls around.
mid="$(tailbox_at 24 46)"
assert_not_contains "tailbox:absent-on-a-narrow-terminal" "$TAILBOX_LID" "$mid"
assert_match        "tailbox:bar-survives-a-narrow-terminal" '\] +[0-9]+/[0-9]+' "$mid"
