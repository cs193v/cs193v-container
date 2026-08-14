#!/usr/bin/env bash
# TIER: live
#
# VERIFICATION.md §A.10, §A.13 and §A.14 — the launcher driving real podman.
#
# The shim tier already proves the state machine's logic. What only real podman can show is
# whether `podman start` really does reuse a stored config (the trap the whole confighash
# mechanism exists for), and whether a recreate really applies the new flag.
#
# §A.10's own verb loop hangs today, and NOT for the reason it looks like: `cs193v` with no
# verb ends in `exec podman exec -it`, and -t allocates a pty, which never delivers EOF. So
# `</dev/null` does not rescue it either. open_shell now REFUSES without a terminal rather
# than hanging (ERRORS.md B13), so a bare launch here is driven through a real pty via LB()
# and only the verbs use a plain pipe.
#
# Destructive: `--rebuild --logout` deletes all five volumes, four of which are where claude/gh/vercel
# logins live. That test is therefore gated behind CS193V_DESTRUCTIVE=1 and skipped
# otherwise, so running the suite can never log anybody out by surprise.

set -u
. "$(dirname -- "$0")/lib/assert.sh"
. "$(dirname -- "$0")/lib/podman-shim.sh"

require_image
cd "$REPO" || exit 1

TMP="$(new_tmpdir)"
# container.args is edited in place to provoke config drift, so restore it from the backup
# on ANY exit — an interrupted run must not leave the student's flag file modified.
cp $REPO/.config/container.args "$TMP/ca.orig"
restore() {
    if [ -f "$TMP/ca.orig" ] && ! cmp -s "$TMP/ca.orig" "$REPO/.config/container.args"; then
        cp "$TMP/ca.orig" "$REPO/.config/container.args"
        printf '  (restored $REPO/.config/container.args)\n'
    fi
    rm -rf "$TMP" /tmp/vt-copy 2>/dev/null
    # .vt-live and .vt-keep below are removed by inline rm lines that only run if the suite
    # gets that far. Without this, an interrupted live run leaks them into projects/ and the
    # next 60-container.sh run inherits them -- see clean_vt_fixtures for why that lies.
    clean_vt_fixtures
    # Exactly the same hole, one resource over: the :3000 server further down is reaped by an
    # inline pkill that only runs if the suite gets that far, so an interrupted run left a
    # listener on a FORWARDED port and the next 60-container.sh run measured it instead of its
    # own (#34).
    clean_vt_processes
    # And the 46 host ports, for the same reason one resource further out: a run that is
    # interrupted has still started tunnels, and leaving them bound hands the next developer a
    # failure they did not cause. Guarded because this trap can fire before release_tunnel is
    # even parsed -- require_image bails out above it.
    command -v release_tunnel >/dev/null 2>&1 && release_tunnel
    shim_cleanup
}
trap restore EXIT INT TERM
clean_vt_fixtures                     # ...and at START, which is the half a kill cannot skip
clean_vt_processes                    # a no-op while the container does not exist yet

# L() drives the VERBS, which never open a shell and so work fine with a redirected stdin —
# they are exactly what the refusal message tells scripts to use. Timeout-wrapped so a
# regression fails the suite instead of wedging it.
L() { printf 'exit\n' | timeout 90 ./cs193v "$@" 2>&1; }
L_rc() { printf 'exit\n' | timeout 90 ./cs193v "$@" >/dev/null 2>&1; printf '%s' "$?"; }

# LV() is L() for the verb that CHANGES something — --rebuild, with or without its modifiers. Since #41
# those refuse while a session is live, and this suite raises the container repeatedly so it can
# `podman exec` into it, so they have to be given the precondition a student actually has: nothing
# running.
#
# WITHOUT THIS THE SUITE LIES. A refused verb exits 1 having done nothing, so
# rebuild:container-filesystem-is-reset finds its marker file still there and fails for the wrong
# reason, and the twenty-launch idempotency loop becomes twenty refusals that still "pass" the
# do-not-recreate check. Both happened. Plain L() is kept for `doctor`, `ports` and
# --dev-print-command, which are read-only, exempt from the refusal, and in `ports`' case need the
# container UP.
LV() { release_container; L "$@"; }

# LB() is a BARE launch — one that goes on to open a shell. It needs a real terminal, since
# open_shell refuses without one, so it goes through script(1) with an `exit` fed in.
#
# The leading bare ENTER acknowledges any warning (issue #19). Which warnings a launch here
# produces is not fixed — the dev-image advisory that used to guarantee one is gone, and
# against real podman the tunnel usually comes up — so this must work whether or not the
# launcher stopped. It does: if there was a warning, this ENTER answers it, and without one
# the ENTER lands harmlessly on the container's own prompt. What it must not do is let the
# `exit` be eaten by the acknowledgement, which would leave tmux with nothing and park the
# test at a live shell until the 120-second timeout.
#
# It releases the container first, for the same reason LV() does: a bare launch against a live
# session is refused, and this suite holds the container up between groups.
LB() { release_container; launcher_tty_repo '\nexit\n' "$@"; }

# ─── a bare launch with no terminal refuses instead of hanging  (ERRORS.md B13) ─
# This used to hang forever against real podman: -t allocates a pty and a pty never
# delivers EOF, so the container's `bash -l` waited for input that could not arrive. Asserted
# against real podman as well as the shim, because the pty is the real thing here.
podman rm -f "$NAME" >/dev/null 2>&1 || true
T0="$(date +%s)"
out="$(./cs193v </dev/null 2>&1)"; rc=$?
T1="$(date +%s)"
if [ "$((T1 - T0))" -lt 60 ]; then
    pass "noterm:refuses-promptly-against-real-podman"
else
    fail "noterm:refuses-promptly-against-real-podman" "took $((T1 - T0))s — it may be hanging again"
fi
assert_says "noterm:explains-itself" "could not open a shell" "$out"
assert_eq   "noterm:exits-nonzero" "1" "$rc"
# INVERTED BY #41. The container is still CREATED, which is what the message promises -- but it is
# no longer left running, because a running container with nobody attached is the exact state the
# change exists to abolish. err.needs-a-terminal was reworded from "set up and running" to say it
# has been stopped again, and 30-launcher-shim.sh asserts that wording.
assert_eq "noterm:container-is-created-but-not-left-running" "exited" \
          "$(podman inspect "$NAME" --format '{{.State.Status}}' 2>&1)"
podman rm -f "$NAME" >/dev/null 2>&1 || true

# How many containers did OUR launcher leave running? `podman ps -q | wc -l` used to answer
# this, and it was wrong for the same reason cleanup:no-stray-containers was, further down:
# it counts every running container on the MACHINE, so a colleague's cs193v-<instance> — or
# anything else the user happens to be running — makes an idempotent launcher look like it
# created a second container. The leak detection is kept intact by counting our own instance
# by exact name and reporting any non-cs193v container alongside it, so a stray with a
# podman-generated name still shows up.
ours_running() {
    local mine strays
    mine="$(podman ps --format '{{.Names}}' | grep -cxF "$NAME" || true)"
    strays="$(podman ps --format '{{.Names}}' | grep -vxF "$NAME" | grep -vcE '^cs193v($|-)' || true)"
    printf '%s' "$(( ${mine:-0} + ${strays:-0} ))"
}

# The same count over containers in ANY state, which is what "did the launcher create a second
# one?" now has to ask. #41 means a finished launch leaves ours stopped, so ours_running would
# answer 0 for a perfectly healthy launcher and 0 again for one that created nothing at all --
# it can no longer tell those apart, and every idempotency assertion below depends on the
# distinction. ours_running is still the right question for "is something running that should
# not be", which is what the leak checks use it for.
ours_existing() {
    local mine strays
    mine="$(podman ps -a --format '{{.Names}}' | grep -cxF "$NAME" || true)"
    strays="$(podman ps -a --format '{{.Names}}' | grep -vxF "$NAME" | grep -vcE '^cs193v($|-)' || true)"
    printf '%s' "$(( ${mine:-0} + ${strays:-0} ))"
}

# With a real terminal the same invocation opens a shell and returns promptly.
T0="$(date +%s)"
out="$(LB)"
T1="$(date +%s)"
if [ "$((T1 - T0))" -lt 60 ]; then pass "live:pty-launch-opens-a-shell-and-returns"
else fail "live:pty-launch-opens-a-shell-and-returns" "took $((T1 - T0))s"; fi
record "perf:first-launch-seconds" "$((T1 - T0))"
# INVERTED BY #41, and this is the headline live assertion for it: LB() feeds `exit`, so the
# session really ended, and a session that has ended must leave nothing running. Against real
# podman rather than the shim because the trap has to survive a real pty teardown and a real
# `podman stop`.
assert_eq "live:a-finished-session-leaves-nothing-running" "exited" \
          "$(podman inspect "$NAME" --format '{{.State.Status}}' 2>&1)"
assert_eq "live:exactly-one-container" "1" "$(ours_existing)"
assert_eq "live:nothing-is-left-running" "0" "$(ours_running)"
# ...and the 46 host ports went back, which is the half that does NOT happen by itself: the tunnel
# is a HOST process and outlives the container unless the teardown takes it down deliberately.
# Waited on rather than sampled -- ssh unbinding is not instantaneous, and a bare check here would
# be a flake that looked like a leak. no_forwards lives in lib/assert.sh beside the port list.
wait_until 30 no_forwards || true
assert_eq "live:a-finished-session-releases-the-ports" "0" "$(count_forwards)"

# The mount really is the student's projects/ directory, on both sides. Inspect works on a stopped
# container, so this needs nothing raised.
assert_eq "live:workspace-is-the-sibling-projects-dir" "$REPO/projects" \
    "$(podman inspect "$NAME" \
       --format '{{range .Mounts}}{{if eq .Destination "/home/student/projects"}}{{.Source}}{{end}}{{end}}')"

# keep-id in practice: a file the container creates is owned by the student on the host.
# Removed FIRST: this stats whoever owns the file, so a leftover host-owned .vt-live from an
# earlier run would pass it with the container having written nothing at all (issue #30).
#
# hold_container because the launch above deliberately left the container stopped and `podman
# exec` needs it up. Every group below that execs into the container does the same; see
# hold_container in lib/assert.sh for why the suite raises it itself.
hold_container
rm -f "$REPO/projects/.vt-live"
podman exec "$NAME" sh -c 'echo live > /home/student/projects/.vt-live'
assert_eq "live:keep-id-maps-the-host-user" "$(id -u)" "$(stat -c %u "$REPO/projects/.vt-live")"
rm -f "$REPO/projects/.vt-live"

# ─── idempotency and concurrency  (§2.2, §A.10) ────────────────────────────────
before="$(podman inspect "$NAME" --format '{{.Id}}')"
i=0
while [ "$i" -lt 20 ]; do LB >/dev/null 2>&1; i=$((i + 1)); done
assert_eq "live:20-launches-still-one-container" "1" "$(ours_existing)"
# This one gets STRONGER under #41, not weaker. It used to prove twenty launches reused a
# container that never stopped; it now proves twenty stop/start cycles preserve the container's
# identity -- which is the real content of the promise that `podman stop` was chosen over `rm` so
# that things installed with sudo survive until a rebuild.
assert_eq "live:20-launches-do-not-recreate" "$before" "$(podman inspect "$NAME" --format '{{.Id}}')"
assert_eq "live:20-launches-leave-nothing-running" "0" "$(ours_running)"

# ─── the exited -> running race, which is the one podman cannot make atomic ─────
# This group used to assert that four simultaneous launches all got a shell in one container,
# because several windows sharing a container was the design. #41 allows one session, so what
# four concurrent launches must now produce is ONE winner and three refusals -- and this is the
# only test in the suite that can prove it, because it is a genuine race against real podman.
#
# It matters because `podman start` is idempotent and reports nothing (measured, 5.7.0), so the
# launcher's `state` check cannot win this on its own: all four can see `exited` and all four can
# start it. The tie is broken one layer down, by tmux refusing a duplicate session name inside the
# container. If that backstop regressed, this is where it shows up.
#
# `LB &`, not `( LB & )`, and then `wait`. The four still run concurrently, which is the whole
# point; what changes is that they are this shell's own children, so the kernel tells us when the
# last one is done instead of us guessing six seconds.
podman stop -t 3 -i "$NAME" >/dev/null 2>&1 || true
wait_until 20 sh -c "[ \"\$(podman inspect $NAME --format '{{.State.Status}}' 2>/dev/null)\" != running ]" || true
RACE_OUT="$(new_tmpdir)/race"
mkdir -p "$RACE_OUT"

# THE FOUR LAUNCHES MUST HOLD THEIR SESSIONS, and that is the whole difficulty of this test.
#
# NOT LB(), for two separate reasons, and the second one cost a flaky failure to find:
#
#   1. LB releases the container first. Four concurrent releases racing four concurrent starts
#      means a launcher that has just won the claim can be stopped by a sibling's release -- not
#      the race being measured. The single release above is the precondition instead.
#   2. LB feeds `exit`, so each launch finishes in about five seconds. Four of those SERIALIZE
#      more often than they collide: each creates a session, leaves, and stops the container
#      before the next arrives, and every one of them legitimately wins. The refusal count is
#      then nondeterministic -- measured at 3 of 4 on one run and 1 of 4 on the very next, from
#      identical code. An "exactly 3" assertion against that shape is wrong by construction, and
#      loosening it to a range would have hidden the regression it exists to catch.
#
# Feeding `sleep 600` makes all four hold their session, so exactly one CAN win. `$!` after a
# pipeline is its last element, which is script, so the kills at the end land on the right pids.
RACE_PIDS=''
for i in 1 2 3 4; do
    printf 'sleep 600\n' | timeout 120 script -q -c "$REPO/cs193v" /dev/null >"$RACE_OUT/$i" 2>&1 &
    RACE_PIDS="$RACE_PIDS $!"
done
refused_count() { grep -l 'already have a CS193V session' "$RACE_OUT"/* 2>/dev/null | grep -c . || true; }
three_refused() { [ "$(refused_count)" = 3 ]; }
# Wait for the losers to have given up rather than for the sleeps to expire. A timeout here is not
# the assertion -- the count is read and asserted below either way.
wait_until 90 three_refused || true
refused="$(refused_count)"
assert_eq "live:concurrent-launches-still-one-container" "1" "$(ours_existing)"
assert_eq "live:concurrent-launches-do-not-recreate" "$before" \
          "$(podman inspect "$NAME" --format '{{.Id}}')"
record "live:concurrent-launches-refused" "$refused of 4"
# THREE of four, and exactly three. Fewer means two sessions were handed out in one container, which
# is the thing #41 forbids; four means nobody could work at all. Which LAYER caught each loser is
# deliberately not asserted -- the state check and the tmux claim produce the same message, and
# which one fires depends on timing.
if [ "$refused" = 3 ]; then
    pass "live:exactly-one-of-four-concurrent-launches-wins"
else
    fail "live:exactly-one-of-four-concurrent-launches-wins" \
         "$refused of 4 launches were refused, want exactly 3. Fewer means two sessions were handed
out in one container -- most likely the tmux duplicate-session claim in cs193v-shell regressed, since
that is the only thing breaking the tie once two launches both see a stopped container. Four means
every launch was refused and nobody could work. Transcripts are in $RACE_OUT."
fi
# shellcheck disable=SC2086
[ -n "$RACE_PIDS" ] && kill -9 $RACE_PIDS 2>/dev/null
wait 2>/dev/null || true
release_container

# ─── the `podman start` config trap  (§2.5) ────────────────────────────────────
# Refuse to start if container.args is already dirty. An earlier interrupted run leaving a
# stray -p line in it made six later assertions fail in confusing ways, because the
# container was created WITH the flag before the drift test ever appended it.
if grep -q 9998 $REPO/.config/container.args; then
    fail "drift:$REPO/.config/container.args-is-clean-before-we-start" \
         "container.args already contains a 9998 test flag from an earlier interrupted run.
Run: git checkout -- $REPO/.config/container.args"
    edit_remove $REPO/.config/container.args '9998'
else
    pass "drift:$REPO/.config/container.args-is-clean-before-we-start"
fi
# This is the one that cannot be faked: podman start reuses the container's STORED config
# and ignores the port list entirely, so without the confighash check a student's flags
# would be frozen at first run forever.
cp $REPO/.config/container.args "$TMP/ca.bak"
# The drift vehicle is an ENV VAR, not a -p line. It used to be `-p 127.0.0.1:9998:9998`, and
# that is now a forbidden flag: -p and the tunnel's ssh -L both bind the same host port, so a
# static test forbids -p from appearing in container.args at all. Writing one here, even
# temporarily, would mean the suite itself produced the state it forbids -- and an interrupted
# run would leave it behind. An env var tests exactly the same thing: podman start reuses the
# container's STORED config, so an edit here must not take effect without a recreate.
echo '-e CS193V_DRIFT_TEST=9998' >> $REPO/.config/container.args
drift_applied() { podman inspect "$NAME" --format '{{json .Config.Env}}' | grep -q 9998; }

assert_contains "drift:new-flag-appears-in-print-command" "9998" "$(L --dev-print-command)"
# Declining must leave the container exactly as it was...
out="$(LB)"
assert_says "drift:prompt-is-shown" "settings have changed" "$out"
assert_eq "drift:declining-keeps-the-same-container" "$before" \
          "$(podman inspect "$NAME" --format '{{.Id}}')"
if drift_applied; then
    fail "drift:declining-does-not-apply-the-flag" "the new flag took effect without a recreate"
else
    pass "drift:declining-does-not-apply-the-flag"
fi
# ...and a plain `podman start` must NOT pick it up either, which is the trap itself.
podman stop "$NAME" >/dev/null 2>&1
podman start "$NAME" >/dev/null 2>&1
if drift_applied; then
    fail "drift:podman-start-ignores-new-flags" \
         "podman start DID apply the new flag — the confighash machinery may be unnecessary
on this podman version, which is worth knowing"
else
    pass "drift:podman-start-ignores-new-flags"
fi

# Accepting it must actually recreate with the flag. Down-arrow and ENTER for the menu,
# then a second ENTER for the warning acknowledgement, then `exit` for the shell itself.
#
# release_container first, and not via LB() because the keystrokes differ: a bare launch against a
# live session is refused before the drift prompt is ever reached, so without this the assertions
# below fail claiming the confighash machinery is broken when nothing was even attempted.
release_container
out="$(launcher_tty_repo '\033[B\n\nexit\n')"
if drift_applied; then
    pass "drift:accepting-applies-the-new-flag"
else
    fail "drift:accepting-applies-the-new-flag" \
         "the flag still is not applied after accepting the recreate — every student's flags
are frozen at first run and edits to $REPO/.config/container.args never reach them"
fi
assert_ne "drift:accepting-created-a-new-container" "$before" \
          "$(podman inspect "$NAME" --format '{{.Id}}')"

edit_remove $REPO/.config/container.args '9998'
if cmp -s "$TMP/ca.bak" $REPO/.config/container.args; then
    pass "drift:$REPO/.config/container.args-restored-exactly"
else
    fail "drift:$REPO/.config/container.args-restored-exactly" \
         "$(diff -u "$TMP/ca.bak" $REPO/.config/container.args | head -10)"
    cp "$TMP/ca.bak" $REPO/.config/container.args
fi
LV --rebuild >/dev/null 2>&1
# The container publishes nothing; the 46 forwards live on the host, in one ssh process.
assert_eq "drift:restored-config-publishes-nothing" "0" "$(podman port "$NAME" | wc -l | tr -d ' ')"

# INVERTED BY #41. This used to assert 46 forwards immediately after --rebuild, because a rebuild
# left the container running with a fresh tunnel. Maintenance verbs now stop what they built --
# nobody is attached when they finish -- so the honest assertion is that the rebuild hands the
# ports BACK, and that the next launch brings them up again.
#
# The underlying hazard the old assertion guarded is unchanged and still worth naming: a tunnel
# outliving its container keeps every course port bound against a dead pipe, so the replacement
# can bind none of them and a routine --rebuild becomes a total outage with no visible cause.
# Both halves below are that same property, read at the two moments it can break.
wait_until 30 no_forwards || true
assert_eq "drift:rebuild-hands-the-ports-back" "0" "$(count_forwards)"
assert_eq "drift:rebuild-leaves-nothing-running" "exited" \
          "$(podman inspect "$NAME" --format '{{.State.Status}}' 2>&1)"
# ...and the round trip: a launch after a rebuild really does get all 46 back. This is the
# assertion that would catch a teardown which released the ports but left something holding them.
LB >/dev/null 2>&1
hold_container
require_tunnel
assert_eq "drift:a-launch-after-a-rebuild-restores-the-forwards" "46" "$(count_forwards)"
assert_match "drift:doctor-reports-the-tunnel-up" 'tunnel +up' "$(L doctor)"

# ─── two copies of the course directory  (§2.7) ────────────────────────────────
rm -rf /tmp/vt-copy
cp -a "$REPO" /tmp/vt-copy
rm -rf /tmp/vt-copy/tests
assert_eq "live:second-copy-is-refused" "1" \
          "$(/tmp/vt-copy/cs193v >/dev/null 2>&1 </dev/null; printf '%s' "$?")"
assert_says "live:second-copy-explains-both-paths" "different folder" \
            "$(/tmp/vt-copy/cs193v </dev/null 2>&1)"
assert_eq "live:second-copy-created-nothing" "1" "$(ours_existing)"
rm -rf /tmp/vt-copy

# ─── --rebuild preserves logins  (§2.3) ────────────────────────────────────────
# A marker inside the ~/.claude volume stands in for a real login, so this can be checked
# without one.
#
# hold_container before every exec group in this section. #41 makes `--rebuild` end with the
# container stopped, so each of these `podman exec` calls would otherwise fail with "container is
# not running" -- and an assert_fail like rebuild:container-filesystem-is-reset would PASS for
# that reason instead of the one it is testing, which is the worst outcome available here.
hold_container
podman exec "$NAME" sh -c 'echo marker > /home/student/.claude/.vt-marker'
podman exec "$NAME" sh -c 'echo marker > /home/student/.config/gh/.vt-marker'
LV --rebuild >/dev/null 2>&1
hold_container
assert_eq "rebuild:claude-volume-survives" "marker" \
          "$(podman exec "$NAME" cat /home/student/.claude/.vt-marker 2>&1)"
assert_eq "rebuild:gh-volume-survives" "marker" \
          "$(podman exec "$NAME" cat /home/student/.config/gh/.vt-marker 2>&1)"
# ...and things installed IN the container do not, which is the point of --rebuild.
podman exec "$NAME" sh -c 'echo x > /tmp/.vt-ephemeral'
LV --rebuild >/dev/null 2>&1
hold_container
# Guarded, because this is an assert_fail and those are the ones that pass for free when the
# precondition is wrong. If the container is not up, `test -f` fails because exec failed.
if [ "$(podman inspect "$NAME" --format '{{.State.Status}}' 2>/dev/null)" != running ]; then
    fail "rebuild:container-filesystem-is-reset" \
         "could not raise the container, so this would have passed without testing anything"
else
    assert_fail "rebuild:container-filesystem-is-reset" \
                sh -c "podman exec ${NAME} test -f /tmp/.vt-ephemeral"
fi
# projects/ is on the host, so it is untouched by construction — assert it anyway.
echo keep > "$REPO/projects/.vt-keep"
LV --rebuild >/dev/null 2>&1
assert_eq "rebuild:projects-untouched" "keep" "$(cat "$REPO/projects/.vt-keep")"
rm -f "$REPO/projects/.vt-keep"

# The policy files live in /etc, in the image layer, precisely so a rebuild restores them —
# unlike anything under ~/.claude, which is a volume seeded once and never refreshed.
hold_container
assert_ok "rebuild:claude-policy-survives" \
          sh -c "podman exec ${NAME} test -f /etc/claude-code/CLAUDE.md -a -f /etc/claude-code/managed-settings.json"

# ─── --rebuild --logout  (§2.4, §9.2) — destructive, opt-in ────────────────────
#
# NO PTY HARNESS ANY MORE. This used to be `printf '\033[B\n' | script -q -c ...`, feeding a
# down-arrow and a newline to the menu --full-rebuild put in the way. --logout carries no
# confirm, so the verb is a plain call and the keystrokes were the only reason `script` was
# here. What that costs is stated plainly: there is no longer a non-tty run that changes
# nothing, because there is no prompt to default to "cancel" -- which is exactly why this whole
# block stays gated behind CS193V_DESTRUCTIVE=1.
if [ "${CS193V_DESTRUCTIVE:-0}" = 1 ]; then
    hold_container
    podman exec "$NAME" sh -c 'echo marker > /home/student/.claude/.vt-marker' 2>/dev/null || true
    LV --rebuild --logout >/dev/null 2>&1
    hold_container
    assert_fail "logout:volume-contents-are-gone" \
                sh -c "podman exec ${NAME} test -f /home/student/.claude/.vt-marker"
    # INVERTED BY #41: like every maintenance verb, this leaves nothing running. Read BEFORE the
    # hold_container above would confuse it, so this samples the state the verb itself left --
    # which is why it re-stops first rather than trusting where we happen to be.
    podman stop -t 3 -i "$NAME" >/dev/null 2>&1 || true
    LV --rebuild --logout >/dev/null 2>&1
    assert_eq "logout:leaves-nothing-running" "exited" \
              "$(podman inspect "$NAME" --format '{{.State.Status}}' 2>&1)"
    # It must not have taken the slow path to get here. --logout says nothing about the image, so
    # with the recipe unchanged this is a volume drop and a recreate -- and the assertion is worth
    # making against real podman because the hash gate is the one thing standing between a
    # two-second logout and a multi-minute one.
    assert_says_not "logout:does-not-rebuild-a-current-image" \
                    "Building the course container" "$(LV --rebuild --logout)"
else
    skip "logout:volume-contents-are-gone" \
         "destructive — it deletes the claude/gh/vercel login volumes. Re-run with CS193V_DESTRUCTIVE=1"
    skip "logout:leaves-nothing-running" "see above"
    skip "logout:does-not-rebuild-a-current-image" "see above"
fi

# ─── building a newer image  (§9.1) ────────────────────────────────────────────
# Deliberately not forced here even though it would work: with the recipe unchanged --rebuild
# does not build at all, which is the point of the hash gate and is asserted just above; with
# --no-cache it is a full multi-minute build, and a tier that creates real containers should
# not sometimes take twenty minutes. The forced build is the release gate's job
# (build:no-cache-build-succeeds), and what the verb DOES either way is covered in the shim
# tier (rebuild:moved-recipe-builds and friends), which is where that logic lives.
#
# There is no longer a second branch to choose between: --update and its pull are gone, so
# this tier no longer has to read container.args to find out which one it would exercise.
skip "build:rebuilds-and-recreates" "would trigger a real image build; covered in 30-launcher-shim.sh"

# ─── doctor against a real container ───────────────────────────────────────────
# Most of what doctor prints -- the in-container uid, the memory limit, zombies, the tmux and
# tunnel sections, the clock skew -- is guarded on the container actually RUNNING, because none of
# it can be read from a stopped one. Since #41 the preceding groups leave it stopped, so the report
# has to be given something to report on. Without both of these, five assertions below fail against
# a perfectly correct doctor that simply had nothing to look at.
hold_container
require_tunnel
out="$(L doctor)"
assert_contains "doctor:reports-the-real-podman-version" "5." "$out"
# ERRORS.md B14, fixed, kept as the regression test for it. verb_doctor called load_args but
# never resolved the image, so it hashed IMAGE="" while every other path hashed the resolved
# one — and doctor then reported "config STALE" for a container that matched perfectly, telling
# staff to go and accept a recreate prompt that never appears. doctor is the report staff ask
# for first, so it must not lie.
#
# The image reference is a constant now that the pin is gone, so every path hashes the same
# value by construction. This assertion has become structural rather than a fix that could
# quietly come undone, which is a reason to keep it cheap, not a reason to drop it.
assert_says "doctor:reports-config-matches" "matches container.args" "$out"
assert_match "doctor:reports-the-in-container-uid" 'in-container uid *1000:1000' "$out"
# doctor's tunnel section replaced a `podman port` count, and it is now the ONLY place
# host-side forwarding state is visible: the in-container `ports` command reads /proc and
# cannot see whether a forward exists out here. That makes these two lines load-bearing for
# support rather than decorative.
assert_match "doctor:reports-the-tunnel-is-up" 'tunnel +up \(pid [0-9]+\)' "$out"
assert_match "doctor:counts-forwarded-ports" 'tunnel ports +46 of 46' "$out"
assert_match "doctor:reports-clock-skew" 'clock skew' "$out"
assert_match "doctor:reports-zombies" 'zombies' "$out"
# Exactly one zombie is EXPECTED while a tunnel is up: sshd's own re-exec'd process, whose
# parent is sshd's privsep monitor inside the container, so it is never reparented to PID 1 and
# no PID 1 could reap it. Recorded rather than asserted because the count is 0 with no tunnel
# and this file must not turn a documented fact into a flaky test. See README.md's --init item.
record "doctor:zombie-count-with-a-tunnel-up" "$(printf '%s' "$out" | sed -n 's/.*zombies *\([0-9]*\).*/\1/p')"
record "doctor:full-output" "$(printf '%s' "$out" | tr '\n' '|')"

# ─── ports verb against a real container ───────────────────────────────────────
# `ports` requires a running container and does not start one -- correctly, since it is a
# read-only report. Under #41 that means the suite has to raise it first.
hold_container
assert_contains "ports-verb:runs-the-in-container-tool" "forwarded:" "$(L ports)"

# ─── the tunnel's own lifecycle ────────────────────────────────────────────────
# Each of these is a way the tunnel can strand a student with a container that looks perfectly
# healthy and a browser that cannot reach anything.
# The port list itself lives in lib/assert.sh, spelled out once for all three tiers.
count_fwd() { count_forwards; }

# Ask the LAUNCHER which tunnel is ours, rather than globbing TMPDIR. The control socket and
# pidfile are named by a hash of (course directory, instance), so a glob picks up every other
# checkout's and instance's files too -- including stale ones whose process is long dead. That
# is not hypothetical: it made the two --reset-tunnel assertions below skip with "no pidfile"
# while a perfectly good tunnel was running, which is worse than failing.
tunnel_pid() { L doctor | sed -n 's/.*tunnel  *up (pid \([0-9]*\)).*/\1/p' | head -1; }
# And take the control socket from that process's own command line, so it cannot disagree.
tunnel_ctl() {
    local p; p="$(tunnel_pid)"
    [ -n "$p" ] || return 0
    ps -p "$p" -o args= 2>/dev/null | sed -n 's/.*-S \([^ ]*\).*/\1/p' | head -1
}
# The tunnel has to be up before we can ask which one is ours. Since #41 the groups above end with
# it deliberately down -- a stopped container has no tunnel -- so this is the common case here now,
# and without it tunnel_pid finds nothing and the forward-direction assertions below fail with "no
# control socket found" rather than testing anything.
require_tunnel
CTL="$(tunnel_ctl)"
record "tunnel:control-socket" "${CTL:-<none>}"

# ─── giving the 46 host ports back ─────────────────────────────────────────────
# This tier is the only thing in the suite that STARTS tunnels, and it used to finish with all
# 46 of them bound -- which the assertions here require while they run, and which is a hostile
# thing to leave behind once they have. CS193V_INSTANCE does not namespace the forwarded ports
# (CLAUDE.md), so a held tunnel means the next developer to run these tests gets none of them
# and watches their run fail for a reason they did not cause. "Whoever tested last still owns
# the ports" is exactly the slow collision CLAUDE.md warns about, produced by the suite itself.
#
# SCOPED TO OUR OWN TUNNEL, by asking the launcher through tunnel_pid rather than globbing
# TMPDIR or matching on `ssh`: doctor honours CS193V_INSTANCE, so a colleague's tunnel is
# invisible to it and cannot be killed by accident. Do not "simplify" this to a pkill.
#
# A plain kill, not `ssh -O exit`. The pid came from the launcher itself, SIGTERM makes the
# master release its listening sockets and unlink its control socket, and if a stale socket
# ever did survive, tunnel_start rm -f's it before starting the next one. Waiting for the
# ports to actually go is the point -- a kill that has not taken effect yet is indistinguishable
# from one that never will, and the assertion below would then be measuring the wrong instant.
#
# The CONTAINER is deliberately left running: it is what the developer goes on to use, and the
# next `./cs193v` brings the tunnel back in about a second.
release_tunnel() {
    local p
    p="$(tunnel_pid)"
    [ -n "$p" ] || return 0
    kill "$p" 2>/dev/null || true
    wait_until 15 no_forwards
}

# THE test: a server bound to the container's OWN loopback, which was unreachable by design
# before this change, must answer from the host.
#
# Swept FIRST, so 3000 is provably free and a 200 can only have come from the server started
# here. A leftover wildcard-bound server -- what 70-sighup.sh leaves if it is killed -- passed
# this assertion while proving the opposite of what it says, since wildcard is the case that
# always worked (#34). Then poll instead of sleeping: python's http.server writes its "Serving
# HTTP on ..." line to a discarded stderr, so its readiness is not otherwise observable.
clean_vt_processes
# Both halves of this test's precondition, made explicit: a running container to serve from, and
# the 46 forwards to reach it through. Neither survives a maintenance verb any more, and without
# this the assertion below would fail with 000 and read like a broken tunnel.
require_tunnel
podman exec -d "$NAME" python3 -m http.server 3000 --bind 127.0.0.1 >/dev/null 2>&1
srv_code=000
srv_answered() {                      # 0 once anything at all comes back from :3000
    srv_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:3000/)"
    [ "$srv_code" != 000 ]
}
wait_until 5 srv_answered || true
# One last attempt with the original's patience, so a 2 s timeout cannot be what fails this.
[ "$srv_code" = 200 ] || \
    srv_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:3000/)"
assert_eq "tunnel:loopback-bound-server-is-reachable" "200" "$srv_code"
container_pkill 'http.server 3000'

# A remote forward inverts the direction the whole design rests on, and the SERVER refuses it
# -- so this holds even if the launcher were changed to ask for one.
if [ -n "$CTL" ]; then
    out_r="$(ssh -S "$CTL" -O forward -R 127.0.0.1:19999:127.0.0.1:3000 student@cs193v-tunnel 2>&1 || true)"
    assert_contains "tunnel:remote-forward-is-refused" "forwarding request failed" "$out_r"
    assert_eq "tunnel:refused-forward-creates-no-listener" "0" \
              "$(ss -ltn 2>/dev/null | grep -c ':19999' || true)"
    # ...and it must not be usable as a proxy to anywhere but the container's own loopback.
    ssh -S "$CTL" -O forward -L 127.0.0.1:13999:1.1.1.1:80 student@cs193v-tunnel >/dev/null 2>&1 || true
    assert_eq "tunnel:cannot-proxy-off-box" "000" \
              "$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://127.0.0.1:13999/)"
else
    fail "tunnel:remote-forward-is-refused" "no control socket found in ${TMPDIR:-/tmp}"
fi

# A wedged tunnel is the case --reset-tunnel exists for, so it is tested wedged: SIGSTOP means
# -O exit can never be answered, and a reset that waited for it would hang forever.
TPID="$(tunnel_pid)"
if [ -n "$TPID" ] && kill -STOP "$TPID" 2>/dev/null; then
    L --reset-tunnel >/dev/null 2>&1
    assert_fail "reset-tunnel:kills-a-stopped-tunnel" sh -c "kill -0 $TPID 2>/dev/null"
    assert_eq "reset-tunnel:restores-all-46-forwards" "46" "$(count_fwd)"
else
    skip "reset-tunnel:kills-a-stopped-tunnel" "no tunnel pidfile to stop"
    skip "reset-tunnel:restores-all-46-forwards" "see above"
fi

# A tunnel that outlives its container would hold all 46 host ports against a dead pipe. It
# must notice and let go, or the next container gets none of them.
podman kill "$NAME" >/dev/null 2>&1
i=0
while [ "$i" -lt 15 ]; do
    [ "$(count_fwd)" = 0 ] && break
    sleep 1; i=$((i + 1))
done
assert_eq "tunnel:releases-its-ports-when-the-container-dies" "0" "$(count_fwd)"
record "tunnel:seconds-to-release-ports" "$i"
# --reset-tunnel must be safe to suggest even then, rather than erroring at a stopped container.
assert_says "reset-tunnel:says-so-when-nothing-is-running" "no container running" "$(L --reset-tunnel)"
# INVERTED BY #41: a rebuild used to end with a fresh tunnel and all 46 forwards up. It now ends
# with the container stopped and the ports handed back, so what has to be true is that the next
# LAUNCH brings them back -- which is the property that actually matters, since a tunnel that could
# not be re-established after a rebuild would leave the student with no forwarding at all.
LV --rebuild >/dev/null 2>&1
wait_until 30 no_forwards || true
assert_eq "tunnel:a-rebuild-hands-the-ports-back" "0" "$(count_fwd)"
LB >/dev/null 2>&1
hold_container
require_tunnel
assert_eq "tunnel:comes-back-after-a-rebuild" "46" "$(count_fwd)"

# ─── §A.14 cleanup assertions ──────────────────────────────────────────────────
containers="$(podman ps -a --format '{{.Names}}' | LC_ALL=C sort | tr '\n' ' ')"
record "cleanup:containers" "$containers"
# This used to assert that the ONLY container on the machine was cs193v, which is how it
# caught a leak: every throwaway container the suite starts uses --rm and gets a
# podman-generated name, so a stray shows up as an extra entry. That breaks the moment a
# second CS193V_INSTANCE exists on the machine, because a colleague's cs193v-<instance> is
# then legitimately present and is not this suite's leak to report. So exclude the cs193v
# family and assert the remainder is empty — same leak detection, no false alarm.
strays="$(podman ps -a --format '{{.Names}}' | grep -vxF "$NAME" \
          | grep -vE '^cs193v($|-)' | LC_ALL=C sort | tr '\n' ' ')"
assert_eq "cleanup:no-stray-containers" "" "$(printf '%s' "$strays" | sed 's/ *$//')"
assert_ok "cleanup:the-container-under-test-exists" sh -c "podman container exists '$NAME'"

vols="$(podman volume ls --format '{{.Name}}' | LC_ALL=C sort | tr '\n' ' ')"
record "cleanup:volumes" "$vols"
# Same scoping. The five are asserted by exact name so a MISSING one still fails, and the
# instance suffix comes from $NAME so the expectation tracks whichever instance is running.
mine="$(podman volume ls --format '{{.Name}}' \
        | grep -xE "$NAME-(claude|claude-json|gh|vercel|playwright)" | LC_ALL=C sort | tr '\n' ' ')"
assert_eq "cleanup:exactly-the-five-cs193v-volumes" \
          "$NAME-claude $NAME-claude-json $NAME-gh $NAME-playwright $NAME-vercel" \
          "$(printf '%s' "$mine" | sed 's/ *$//')"
stray_vols="$(podman volume ls --format '{{.Name}}' | grep -vE '^cs193v($|-)' \
              | LC_ALL=C sort | tr '\n' ' ')"
assert_eq "cleanup:no-stray-volumes" "" "$(printf '%s' "$stray_vols" | sed 's/ *$//')"

# ─── §A.13 performance baselines — recorded, never asserted ────────────────────
T0="$(date +%s%N)"; L --dev-print-command >/dev/null 2>&1; T1="$(date +%s%N)"
record "perf:launcher-overhead-ms" "$(( (T1 - T0) / 1000000 ))"
hold_container
T0="$(date +%s%N)"; podman exec "$NAME" true; T1="$(date +%s%N)"
record "perf:podman-exec-overhead-ms" "$(( (T1 - T0) / 1000000 ))"
T0="$(date +%s)"; LV --rebuild >/dev/null 2>&1; T1="$(date +%s)"
record "perf:rebuild-seconds" "$((T1 - T0))"
T0="$(date +%s)"; release_container; L >/dev/null 2>&1; T1="$(date +%s)"
record "perf:subsequent-launch-seconds" "$((T1 - T0))"

# ─── hand the ports back  (must be last: everything above needs the tunnel up) ─
# Asserted rather than done quietly, because "the suite gave the ports back" is a promise the
# next developer's run depends on, and a release that silently did not happen looks identical
# to one that did until their run fails instead. The EXIT trap calls this too, for the runs
# that never reach this line.
release_tunnel
assert_eq "cleanup:the-46-forwards-are-released" "0" "$(count_fwd)"
# Leave the container stopped as well, which since #41 is the honest resting state rather than a
# courtesy: a running container is supposed to mean somebody has a terminal open on it, and a
# suite that walks away leaving one up is asserting an invariant it just broke. Whichever suite
# needs it next raises it through hold_container.
podman stop -t 3 -i "$NAME" >/dev/null 2>&1 || true
record "cleanup:tunnel-released" \
       "the ports are back and the container is stopped; the next ./cs193v brings both up"
