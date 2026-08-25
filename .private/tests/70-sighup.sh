#!/usr/bin/env bash
# TIER: container
#
# WHAT CLOSING THE TERMINAL WINDOW DOES. Issue #41 inverted the answer, so this file is a
# rewrite rather than an edit, and it is worth saying plainly what changed and why.
#
# It used to assert the OPPOSITE, and its headline assertion was
# `sighup:server-in-a-tab-survives-the-window-closing`. The container outlived every window, tmux
# kept the session, and the measured result (ERRORS.md D1) was that a dev server survived and
# stayed reachable through its forwarded port. That was deliberate, documented and
# regression-tested here. #41 decided it was the wrong default for a novice: closing a window
# looks like leaving, so it should be leaving.
#
# THE SIMULATION ALSO HAD TO CHANGE, and this is the subtle part. The old file killed the
# `podman exec` CLIENT, on the grounds that that is what closing a window does. Under the new
# design that models nothing: the launcher no longer `exec`s into podman, so a closing window
# signals the LAUNCHER, and the launcher is what stops the container. So the probe here kills the
# `script` process owning the pty, which closes the master side and makes the kernel deliver
# SIGHUP to the foreground process group -- the actual mechanism rather than a stand-in for it.
#
# That is why this could not be a sed of the old file. Killing the exec client now leaves the
# launcher alive and the container up, which is a real state -- see the force-quit group -- but
# not the one a closed window produces.
#
# ERRORS.md D1's measurements are NOT deleted. They are still true about conmon and about
# processes inside a live container, and the four-shape matrix is still recorded at the end,
# demoted from advice to a record: "you can detach a server with setsid" stopped being useful
# guidance the moment the container stopped outliving the window.
#
# §5.1 still needs a human to close a real window, and it is the only way to ask this on macOS
# and WSL, where the exec client lives outside the VM.

set -u
. "$(dirname -- "$0")/lib/assert.sh"
. "$(dirname -- "$0")/lib/podman-shim.sh"

require_image
require_cmd script "needed to give the launcher a pty, as a real terminal would"
require_cmd curl "needed to read a server through a forwarded port"

# THE PORT IS PICKED, not written out: any port nothing on this host is listening on will do,
# because there is no declared set to belong to -- the tunnel forwards it because the server binds
# it. Written out, this file curl'd a port nothing was listening on and read the resulting 000 as
# "the server died with the window", an assertion that passed for the wrong reason (#46), and a
# fixed number is also how two developers' runs collide.
#
# CHOSEN BEFORE ANY CONTAINER EXISTS, which is why it is free_unforwarded_ports and not dyn_ports:
# this is the one suite that must start from a STOPPED container, so there is no tunnel yet to ask
# for a forwarded port. The wait on srv_up below is what establishes it, and that wait is now doing
# more work than it used to -- it covers the supervisor noticing the bind and opening the host port.
SRV_PORT="$(free_unforwarded_ports 1)"
[ -n "$SRV_PORT" ] || { fail "require:port" "no free host port to put a test server on"; exit 1; }
SRV="python3 -m http.server $SRV_PORT --bind 0.0.0.0"
TM="tmux -L cs193v -f /etc/cs193v/tmux.conf"
LOG="$(mktemp "${TMPDIR:-/tmp}/cs193v-sighup.XXXXXX")"

# ─── predicates, so every wait is on a condition rather than a duration ─────────
st() { podman inspect "$NAME" --format '{{.State.Status}}' 2>/dev/null; }
container_running() { [ "$(st)" = running ]; }
container_stopped() { case "$(st)" in running) return 1 ;; *) return 0 ;; esac; }
session_up() { podman exec "$NAME" $TM has-session -t '=cs193v' >/dev/null 2>&1; }
srv_up()     { curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$SRV_PORT/"; }

# THIS IS THE ONE SUITE THAT MUST NOT HAVE THE CONTAINER HELD UP.
#
# Every other suite in this tier calls require_running, which since #41 starts the container itself
# (see hold_container in lib/assert.sh). Here a running container is precisely what makes the
# launcher refuse, so each probe has to begin from a stopped one -- which is what release_container,
# hold_container's opposite number, is for. Without it this whole file would be asserting against
# err.session-in-use and proving nothing, while LOOKING like it worked: the failure mode #34 taught
# this suite to fear.

PTY_PIDS=''
cleanup() {
    # shellcheck disable=SC2086
    [ -n "$PTY_PIDS" ] && kill -9 $PTY_PIDS 2>/dev/null
    rm -f "$LOG"
    container_running && container_pkill "http.server $SRV_PORT"
    return 0
}
trap cleanup EXIT
clean_vt_processes

# Start a real launcher under a real pty, and return the pid whose death closes that pty.
#
# `sleep 600` is fed rather than nothing: with stdin at EOF the login shell in tab one exits
# immediately, which closes the tab, which ends the session -- so the probe would be measuring a
# container nobody was in. `$!` after a pipeline is its LAST element, which is script, and that is
# exactly the pid whose death has to look like a window closing.
launch_in_pty() {                     # launch_in_pty -> sets PTY_PID
    printf 'sleep 600\n' | script -q -c "$REPO/cs193v" /dev/null >"$LOG" 2>&1 &
    PTY_PID=$!
    PTY_PIDS="$PTY_PIDS $PTY_PID"
}

# ─── 1. closing the window stops the container ─────────────────────────────────
release_container
launch_in_pty
if ! wait_until 90 session_up; then
    fail "sighup:the-probe-got-a-session" \
         "the launcher never reached a tmux session in 90s, so nothing below would prove anything.
Launcher output: $(tail -5 "$LOG" 2>/dev/null)"
    exit 1
fi
pass "sighup:the-probe-got-a-session"

# A server in a tab: what a student actually has, and what the old file asserted must SURVIVE
# this. It must now die with the window.
podman exec "$NAME" sh -c "$TM new-window -d '$SRV'" >/dev/null 2>&1
wait_until 20 srv_up || true
BEFORE_HTTP="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$SRV_PORT/")"
FWD_BEFORE="$(count_forwards)"
# OURS, not anybody's: count_forwards is ownership-scoped now, so this records what this
# instance's own tunnel holds. It recorded "46 of 46" for a run that held none of them (#46).
record "sighup:forwards-while-a-session-is-open" "$FWD_BEFORE"

# THE WINDOW CLOSING. Killing script closes the pty master, and the kernel HUPs the foreground
# process group -- the launcher and its podman exec child.
kill -9 "$PTY_PID" 2>/dev/null
wait "$PTY_PID" 2>/dev/null || true

if wait_until 45 container_stopped; then
    pass "sighup:closing-the-window-stops-the-container"
else
    fail "sighup:closing-the-window-stops-the-container" \
         "the container is still $(st) 45s after the pty was destroyed. Either the launcher never
received SIGHUP, or its trap did not run -- and on this platform that is the whole of #41 not
working. First thing to check: that open_shell traps HUP and not only EXIT. bash's default action
for SIGHUP is to die WITHOUT running an EXIT trap, which would look exactly like this."
fi

# The tunnel is a HOST process holding loopback ports, so it does not die with the container --
# it has to be taken down deliberately. Forgetting would mean the next launch could bind none of
# its ports, which is the failure remove_container documents; this is its test on the teardown path.
if wait_until 30 no_forwards; then
    pass "sighup:closing-the-window-releases-the-forwarded-ports"
else
    fail "sighup:closing-the-window-releases-the-forwarded-ports" \
         "$(count_forwards) forwards are still bound (there were $FWD_BEFORE while the session
was open). An ssh client outliving its container holds its host ports against a pipe with nothing
on the far end, so nothing it forwards can be reached and the ports are not free for anything else
either."
fi

# ...and the server in the tab went with it. If it was never reachable the assertion below is
# weaker than intended, so say so rather than quietly banking a pass -- that is exactly how #34's
# self-matching pgrep made this file green through anything.
if [ "$BEFORE_HTTP" != 200 ]; then
    record "sighup:server-in-a-tab-was-not-reachable-first" \
           "http=$BEFORE_HTTP before the kill, so a-server-in-a-tab-dies proves less than it reads"
fi
assert_fail "sighup:a-server-in-a-tab-dies-with-the-window" srv_up

# ─── 2. `exit` stops it too, by the same path ──────────────────────────────────
# One teardown, not two: `exit` and a closed window both arrive as the podman exec child ending.
# If these two ever disagree, the trap is doing something the ordinary path is not.
release_container
out="$(launcher_tty_repo '\nexit\n' 2>&1)"
if wait_until 45 container_stopped; then
    pass "sighup:exiting-the-shell-stops-the-container"
else
    fail "sighup:exiting-the-shell-stops-the-container" "the container is still $(st)"
fi
assert_says "sighup:the-student-is-told-it-is-stopping" "Stopping the container" "$out"

# ─── 3. relaunching gets the same container, not a new one ─────────────────────
# `podman stop` and not `rm`, so the writable layer survives and things installed with sudo still
# persist until a rebuild -- which is what CONTAINER-DESIGN.md's "what survives what" table
# promises. A teardown that recreated here would silently break that promise, and nothing a
# student did would reveal it until they lost a package.
ID_BEFORE="$(podman inspect "$NAME" --format '{{.Id}}' 2>/dev/null)"
assert_fail "sighup:a-stopped-container-accepts-no-exec" sh -c "podman exec $NAME true"
launcher_tty_repo '\nexit\n' >/dev/null 2>&1
assert_eq "sighup:relaunching-reuses-the-same-container" "$ID_BEFORE" \
          "$(podman inspect "$NAME" --format '{{.Id}}' 2>/dev/null)"

# ─── 4. one session at a time, live ────────────────────────────────────────────
# The shim tier proves the refusal's logic cheaply. What only real podman shows is that it fires
# against a container genuinely running with a genuine tmux session in it.
release_container
launch_in_pty
if wait_until 90 session_up; then
    out="$(cd "$REPO" && ./cs193v 2>&1 </dev/null)"
    assert_says "sighup:a-second-launch-refuses" "already have a CS193V session" "$out"
    assert_says "sighup:the-refusal-names-the-way-out" "cs193v --stop" "$out"
    # It must not disturb the session it refused to touch. Getting this wrong would make a second
    # launch a weapon against the first.
    assert_ok "sighup:the-refusal-leaves-the-first-session-alone" \
              sh -c "podman exec $NAME $TM has-session -t '=cs193v'"
else
    fail "sighup:a-second-launch-refuses" "no session came up to refuse against"
fi

# --stop is what the refusal tells them to run, so it had better work from here. Down-arrow then
# ENTER, because menu() defaults to the safe option and the safe option is cancel.
launcher_tty_repo '\033[B\n' --stop >/dev/null 2>&1 || true
if wait_until 45 container_stopped; then
    pass "sighup:stop-clears-a-live-session"
else
    fail "sighup:stop-clears-a-live-session" "the container is still $(st) after --stop"
fi
kill -9 "$PTY_PID" 2>/dev/null; wait "$PTY_PID" 2>/dev/null || true

# ─── 5. the force-quit leftover, the one state that still leaks ────────────────
# SIGKILL runs no trap, so a force-quit leaves a container up with nothing attached. That is
# tolerated by design: it degrades to exactly the old behaviour, and both the refusal and --stop
# recover from it. But the recovery has to genuinely work, because a student who cannot get back
# in is worse off than one whose container merely stayed up.
release_container
launch_in_pty
if wait_until 90 session_up; then
    # The LAUNCHER, not the pty: no HUP, so no trap and no teardown.
    LAUNCHER_PID="$(pgrep -P "$PTY_PID" | head -1)"
    if [ -n "$LAUNCHER_PID" ]; then
        kill -9 "$LAUNCHER_PID" 2>/dev/null
        sleep 2                        # A DURATION, deliberately: this asserts a NON-event.
        if container_running; then
            pass "sighup:a-force-quit-leaves-the-container-up-as-designed"
        else
            record "sighup:force-quit-stopped-it-anyway" \
                   "the container stopped with no trap having run, which is not what killing the
launcher should do. Worth understanding before trusting the teardown path."
        fi
        # The refusal has to EXPLAIN this, not just refuse. A student who force-quit knows there
        # is no other window, so a message that only says "you have a session open" reads as
        # wrong, and a message they have caught lying once is one they stop reading.
        assert_says "sighup:a-leftover-container-is-explained-not-just-refused" "crash" \
                    "$(cd "$REPO" && ./cs193v 2>&1 </dev/null)"
        launcher_tty_repo '\033[B\n' --stop >/dev/null 2>&1 || true
        if wait_until 45 container_stopped; then
            pass "sighup:stop-recovers-a-force-quit-leftover"
        else
            fail "sighup:stop-recovers-a-force-quit-leftover" "still $(st) -- the student is stuck"
        fi
    else
        record "sighup:force-quit" "could not find the launcher under the pty in order to kill it"
    fi
fi
kill -9 "$PTY_PID" 2>/dev/null; wait "$PTY_PID" 2>/dev/null || true

# ─── 6. the tab-close matrix, kept as a RECORD ────────────────────────────────
# What these four shapes measure is still real: whether a process outlives the `podman exec`
# client that started it, inside a container that stays up. That is now the "a tab closed"
# question rather than the "a window closed" one, and it underpins no advice any more. The old
# `sighup:setsid-survives-so-there-is-a-way-to-detach` assertion is DELETED, because telling a
# student to setsid a server is telling them to do something the container's own lifetime undoes.
#
# Kept so ERRORS.md D1's table still has a live source rather than a frozen quotation.
release_container
podman start "$NAME" >/dev/null 2>&1
wait_until 20 container_running || true
MATRIX=""
# THE ZOMBIES ALREADY HERE, by pid, so the check below can tell what this matrix caused from what
# was already true. Empty in practice -- release_container took the tunnel with it, and sshd's
# unreapable one went too -- but read rather than assumed, because a suite run against a container
# somebody left a tunnel on must not read that as a leak.
ZBASE="$(zombie_pids | tr '\n' ' ')"
record "sighup:zombies-before-the-matrix" "${ZBASE:-none}"
# The pattern follows $SRV's port for the same reason $SRV does: this asks whether the process
# survived, and a pattern naming a port the server was never started on answers no every time.
probe() {                             # probe LABEL COMMAND
    container_pkill "http.server $SRV_PORT"
    script -q -c "podman exec -it ${NAME} sh -c '$2'" /dev/null >/dev/null 2>&1 &
    local client=$!
    wait_until 15 container_pgrep "http.server $SRV_PORT" || true
    kill -9 "$client" 2>/dev/null; wait "$client" 2>/dev/null || true
    sleep 2                           # A DURATION, deliberately: "still alive" is a non-event.
    local alive
    container_pgrep "http.server $SRV_PORT" && alive=yes || alive=no
    record "sighup:tab-matrix-$1" "alive=$alive"
    MATRIX="$MATRIX
  $(printf '%-12s alive=%s' "$1" "$alive")"
    # THIS TAKES THE WRAPPER SHELL WITH IT, which is not obvious and is why nothing else is
    # needed here. `pgrep -f` matches a full command line, and the three backgrounding shapes
    # run as `sh -c 'python3 -m http.server PORT ... & sleep 60'` -- the pattern is inside the
    # SHELL's argv too, so the whole exec session goes rather than just the server. Same
    # mechanism as the pgrep trap documented in lib/assert.sh, working in our favour for once.
    container_pkill "http.server $SRV_PORT"
}
probe foreground "$SRV"
probe background "$SRV & sleep 60"
probe nohup      "nohup $SRV >/tmp/s.log 2>&1 & sleep 60"
probe setsid     "setsid $SRV >/tmp/s.log 2>&1 & sleep 60"
record "sighup:MATRIX" "$(printf '%s' "$MATRIX" | tr '\n' '|')"
printf '\n  the tab-close matrix, for $PRIVATE/ERRORS.md D1:%s\n\n' "$MATRIX"

# Killing exec clients is still routine -- every closed tab is one -- so their leftovers must be
# reaped rather than pile up against pids.max (2048), which wedges the container beyond
# `podman exec`'s reach and does not self-heal.
#
# GROWTH, NOT A COUNT, and that is what the `<= 2` used to stand in for. A bare `grep -c Z` counts
# sshd's unreapable one and whatever `podman exec` payload happens to be mid-exit at that instant,
# so the tolerance was absorbing two things that are not leaks -- and hiding any leak smaller than
# three (#102). Asking instead which zombies are here that were NOT here before the matrix needs
# no tolerance at all: the number to beat is zero, whatever the ambient population is.
#
# MEASURED, because the obvious guess about what this matrix leaves is wrong. It leaves NOTHING:
# 20 samples across one probe's teardown found no zombie at any point. The wrapper shell reaps its
# own backgrounded server -- dash's wait for the foreground `sleep` is a waitpid(-1) and collects
# whatever comes back -- and `container_pkill` kills that shell along with the server anyway.
#
# AND NOT THE ppid == 1 RULE 60-container.sh uses, which follows from the same measurement: with
# nothing here ever reparented onto PID 1, that filter would have nothing to look at and would
# pass by finding none. This asks the wider question the check's name asks -- did anything at all
# survive four killed exec clients -- which keeps a conmon that fails to reap an exec payload in
# scope. Where PID 1's own reaping is PROVED is 60-container.sh, on orphans it creates itself.
#
# BOUNDED, NOT A FIXED `sleep 2`: the claim is that nothing SURVIVES, and a leaked pid never
# leaves the table however long you wait, so a timeout here is the failure and not a slow machine.
# shellcheck disable=SC2086
if wait_until 10 no_new_zombies $ZBASE; then
    pass "sighup:killed-clients-do-not-leak-zombies"
    record "sighup:zombies-after-the-matrix" "none beyond the baseline"
else
    # shellcheck disable=SC2086
    record "sighup:zombies-after-the-matrix" "$(zombies_outside_baseline $ZBASE | tr '\n' ';')"
    # shellcheck disable=SC2086
    fail "sighup:killed-clients-do-not-leak-zombies" \
         "these are still here 10 s after four killed exec clients, and were not before the
matrix -- each holds a pid slot against pids.max (ppid pid comm):
$(zombies_outside_baseline $ZBASE)"
fi

# ─── 7. the docs must describe the behaviour, not its opposite ────────────────
# Loose about wording, strict about the CLAIM. The old version checked only that
# CONTAINER-DESIGN.md mentioned "terminal window", which stayed green through a total reversal of
# what the doc said about it -- a check that survives the thing it exists to catch.
design="$(tr 'A-Z' 'a-z' < "$PRIVATE/CONTAINER-DESIGN.md")"
assert_contains "sighup:CONTAINER-DESIGN-addresses-closing-the-window" "terminal window" "$design"
assert_match "sighup:CONTAINER-DESIGN-says-it-STOPS-things" \
             'clos[a-z]*( your| the)? terminal[^.]*stop|stop[^.]*clos[a-z]*( your| the)? terminal' \
             "$design"

# Leave the container stopped, which is now the honest resting state. hold_container will raise it
# for whichever suite needs it next, and leaving 46 ports bound for the next developer is exactly
# what #29 stopped doing.
release_container
