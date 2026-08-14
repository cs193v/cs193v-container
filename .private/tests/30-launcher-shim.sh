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

COPY="$(repo_copy)"
LAUNCHER_DIR="$COPY"

# ─── dispatch and usage ────────────────────────────────────────────────────────
shim_new
for v in --help -h help; do
    assert_eq "dispatch:$v-exits-0" "0" "$(launcher_rc "$v")"
done
out="$(launcher --help)"
assert_says "usage:mentions-ports"   "cs193v ports"   "$out"
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
assert_says "dispatch:unknown-verb-prints-usage" "cs193v ports" "$(launcher bogusverb)"
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
# older than 5.7.0 and refuse every future podman.
for v in 5.6.0 5.6.9 4.9.3 0.1.0; do
    shim_new; shim_set version "podman version $v"
    assert_eq "version:$v-refused" "1" "$(launcher_rc)"
    assert_eq "version:$v-creates-nothing" "0" "$(shim_count '^run ')"
done
shim_new; shim_set version "podman version 5.6.0"
out="$(launcher)"
assert_contains "version:refusal-shows-found"  "5.6.0" "$out"
assert_contains "version:refusal-shows-needed" "5.7.0" "$out"
assert_says "version:refusal-names-the-fix" "apt install" "$out"

# 5.7.0 is exactly MIN_PODMAN and is what Ubuntu 26.04 ships, so the boundary is the case
# that actually matters — an off-by-one here refuses every student on a stock Ubuntu.
# 10.0.0 guards against a lexical compare, which would call it older than 5.7.0.
for v in 5.7.0 5.7.1 5.8.0 6.0.2 10.0.0; do
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
# --rebuild must keep logins: none of the five volumes is touched.
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
if [ "$(shim_count '^volume rm')" -eq 5 ]; then pass "logout:removes-5-volumes"
else fail "logout:removes-5-volumes" "removed $(shim_count '^volume rm')"; fi
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
# while holding all 46 host ports meanwhile, which CS193V_INSTANCE does NOT namespace, so a
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

# ─── ports and doctor ──────────────────────────────────────────────────────────
shim_new
shim_set state absent
assert_says "ports:refused-when-not-running" "not running yet" "$(launcher ports)"

shim_new
launcher >/dev/null 2>&1
# ...and put it back to running, which a bare launch no longer leaves behind (#41): that launch
# has no terminal, so it refuses and stops the container on the way out. Without this the fake
# is `exited` here and `ports` correctly refuses -- testing the line above instead of this one.
shim_set state running
shim_clear_log
out="$(launcher ports)"
assert_says "ports:execs-the-in-container-tool" "$NAME ports" "$(shim_log | tr '\n' ' ')"

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
# require_cmd, and no `|| true` on the call: box_problems measures display columns with
# python3, and swallowing its failure would turn "the checker could not run" into a pass,
# which is the vacuous-green this project hard-fails on elsewhere for the same reason.
require_cmd python3
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
      | awk -F'\t' -v n=23 '{ printf "STEP %d/%d: %s\n", $1, n, $3 }'
  printf 'STEP 23/23: LABEL "cs193v.buildhash"="deadbeef"\n'
  printf 'COMMIT localhost/cs193v:local\nSuccessfully tagged localhost/cs193v:local\n'
} > "$SHIM/build_out"
# --no-cache is what FORCES the build, and it is not decoration. --rebuild is the only verb that
# builds now, and it builds only when the recipe moved or the image is missing -- podman-fake
# reports image_exists=yes, so without this it would recreate the container and never call
# `podman build` at all, and every assertion below would pass vacuously against no output.
out="$(launcher --rebuild --no-cache)"

# Named steps, spread across the build rather than only at its ends. The count is podman's own
# 23 here: the +1 for creating the container exists only where there is a meter to put it in.
assert_match "labels:names-the-node-step"      '\] +[0-9]+/23  Installing Node'           "$out"
assert_match "labels:names-the-chromium-step"  '\] +[0-9]+/23  Installing Chromium'       "$out"
assert_match "labels:names-the-vercel-step"    '\] +[0-9]+/23  Installing the Vercel CLI' "$out"
assert_match "labels:names-the-first-step"     '\] +1/23  Downloading the base image'     "$out"
# The tail of the file is ENV/USER/WORKDIR/ENTRYPOINT plus the LABEL podman synthesizes from
# our own --label flag. None of them has a marker of its own, and the last one has no line in
# the Containerfile at all, so all five inherit the closing marker rather than going blank.
assert_match "labels:tail-steps-inherit-the-closing-marker" '\] +23/23  Finishing up' "$out"
# EVERY step is named. The whole point is that the side text is never blank mid-build, so a
# step that reached the bar without a name is the regression to catch.
unnamed="$(printf '%s\n' "$out" | grep -cE '\] +[0-9]+/23 *$' || true)"
assert_eq "labels:no-step-is-left-unnamed" "0" "${unnamed:-0}"

# And on a terminal the same labels ride in the block, on the row under the bar. Layout only --
# see above for why the content assertions do not live here.
shim_set build_delay 0.05
raw="$(launcher_tty '' --rebuild --no-cache)"
pairs="$(printf '%s' "$raw" | frame_pairs)"
assert_match "labels:ride-in-the-block-on-a-terminal" \
             "\] +[0-9]+/24$TAB""Installing " "$pairs"
# 24 = 22 instructions + podman's injected LABEL step + creating the container. The count the
# meter commits to comes from podman; the parse only supplies it before podman has spoken.
assert_match "labels:total-counts-every-step" '\] +24/24' "$(printf '%s' "$raw" | render_pty)"

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
shim_set build_delay 0.15
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
