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
# signals the LAUNCHER, and the launcher is what stops the container. So the probe here acts on the
# process owning the pty -- the actual mechanism rather than a stand-in for it.
#
# That is why this could not be a sed of the old file. Killing the exec client now leaves the
# launcher alive and the container up, which is a real state -- see the tab-close matrix -- but
# not the one a closed window produces.
#
# AND THERE ARE TWO WAYS TO ACT ON IT, which cost weeks to learn (#169). Destroying the pty owner
# closes the MASTER FIRST; the kernel then HUPs the SESSION LEADER ONLY, and it is the leader's
# exit that HUPs the foreground group and revokes the terminal. A real terminal does the opposite:
# measured in a Terminal.app window, it signals the FOREGROUND GROUP and keeps the master open
# until the child has gone, so the teardown's writes succeed. Those two orderings put fd 1 into
# different states and a launcher can pass one and fail the other. Group 1 uses close_window for
# the ordering students get; group 1b keeps force_quit_terminal for the one they get from a force
# quit, a crashed emulator, or a Mac losing power.
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
# NO require_cmd script: nothing here uses script(1) any more. lib/ptyrun.py replaced it because
# BSD script cannot deliver keystrokes and macOS has no GNU one to install -- so demanding it would
# refuse a machine over a tool the suite does not touch. ptyrun needs python3, which the preflight
# in run-tests.sh checks for every tier.
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
    # pty_start makes a fresh pidfile and keystroke feed per launch, and this file launches three
    # times. They are named with our pid so this glob cannot reach another run's.
    rm -f "${TMPDIR:-/tmp}"/cs193v-ptypid."$$".* "${TMPDIR:-/tmp}"/cs193v-ptyfeed."$$".* 2>/dev/null
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
launch_in_pty() {                     # launch_in_pty -> sets PTY_PID, and PTY_PIDFILE for §5
    # pty_start, NOT ptyrun.py by hand: it is what keeps $! the pty OWNER (a pipeline or a
    # function call in a subshell would not), quotes the interpolated path against a spacey
    # $HOME (#141), and runs the launcher through lib/pty-announce so §5 can learn the
    # launcher's OWN pid instead of guessing at the process tree. See lib/portable.sh.
    # CS193V_PTY_JOB, so that close_window below is actually polite. Without it ptyrun execs the
    # shell in the pty's SESSION LEADER, the leader is therefore in the foreground process group,
    # and signalling that group kills it -- whereupon the kernel revokes the controlling terminal
    # and the launcher's teardown writes to a terminal that is already gone. That is the RUDE
    # outcome arriving by the polite route, and it happens on exactly the hosts where /bin/sh
    # interposes (#151): green here, wrong on Ubuntu. Job mode gives the pty a leader that is not
    # in the job's group -- which is also, for the first time, the shape a student's terminal
    # builds: a login shell that stays, and the launcher as a foreground job beneath it.
    CS193V_PTY_JOB=1 pty_start 'sleep 600\n' "$REPO/cs193v" >"$LOG" 2>&1
    PTY_PID="$PTY_OWNER"
    PTY_PIDS="$PTY_PIDS $PTY_PID"
}

# ─── the two ways a window can go, and they are NOT the same event ─────────────
# MEASURED, single variable, unpatched launcher, three runs each: a polite close leaves the
# container `exited` and a rude one leaves it `running` (#169). Nothing else moved. So which of
# these a test calls decides what it is testing, and neither is a stand-in for the other.
#
# close_window is what a terminal does when you click the close button. Measured in a real
# Terminal.app window: it signals the FOREGROUND PROCESS GROUP and never touches the login shell,
# so the shell does not exit, the controlling terminal is never revoked, the master stays open, and
# every write the teardown makes succeeds. ptyrun.py does that on SIGUSR1; see _close_politely.
close_window() {                      # close_window PID
    kill -USR1 "$1" 2>/dev/null
    wait "$1" 2>/dev/null || true
}

# force_quit_terminal is the other ordering: the master goes first and nobody is signalled, so the
# kernel HUPs the session leader, and its exit HUPs the group and revokes the terminal. A force
# quit, a crashed emulator, a Mac losing power. This is what this file used to do for BOTH.
force_quit_terminal() {               # force_quit_terminal PID
    kill -9 "$1" 2>/dev/null
    wait "$1" 2>/dev/null || true
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
# THE MASTER ITSELF, read WHILE the launcher's record of it still exists -- tunnel_down's last
# statement deletes that record (cs193v:2113), so this is the only moment it can be had. It is what
# lets the teardown assertions below name a survivor instead of merely counting to zero, and it is
# the snapshot #159 asked for. What a snapshot could not fix is the five sibling assertions whose
# tunnel is born and dies inside a single launcher invocation, so they have no such moment; those
# are fixed one layer down, in fwd_owned_ports.
FWD_OWNER="$(tunnel_owner_pid)"
record "sighup:the-master-holding-them" "${FWD_OWNER:-none}"

# THE WINDOW CLOSING -- the polite ordering, which is what every macOS terminal measured so far
# actually does. The rude one gets its own group below; it used to be the only one here, and that
# is why this assertion was red on macOS for weeks against a launcher that was not at fault (#169).
close_window "$PTY_PID"

if wait_until 45 container_stopped; then
    pass "sighup:closing-the-window-stops-the-container"
else
    fail "sighup:closing-the-window-stops-the-container" \
         "the container is still $(st) 45s after the window closed. Either the launcher never
received SIGHUP, or its trap did not run -- and on this platform that is the whole of #41 not
working. First thing to check: that open_shell traps HUP and not only EXIT. bash's default action
for SIGHUP is to die WITHOUT running an EXIT trap, which would look exactly like this.
If the force-quit group below is ALSO red, suspect the teardown itself (#170) rather than the trap;
if only this one is, the polite close is not reaching the launcher at all."
fi

# The tunnel is a HOST process holding loopback ports, so it does not die with the container --
# it has to be taken down deliberately. Forgetting would mean the next launch could bind none of
# its ports, which is the failure remove_container documents; this is its test on the teardown path.
#
# THE SUBJECT IS ESTABLISHED BEFORE IT IS ASKED ABOUT, which is the whole of #159. With nothing
# forwarded while the session was open there is nothing to release, and both assertions below would
# pass whatever the teardown did -- the shape #34 and #46 taught this file to fear, and the shape
# the "was-not-reachable-first" record below covers for the server in the tab. Said out loud rather
# than banked: a pass with no subject is worth less than a red.
if [ -z "$FWD_OWNER" ] || [ "$FWD_BEFORE" = 0 ]; then
    fail "sighup:the-probe-had-a-tunnel-to-release" \
         "forwards=$FWD_BEFORE, master=${FWD_OWNER:-none of ours was identifiable}, with a session
open and a server in a tab answering $BEFORE_HTTP. Neither assertion below has a subject, so both
would pass however the teardown behaved.
Check:  ./cs193v doctor
        $FWD_SUPLOG"
    skip "sighup:closing-the-window-releases-the-forwarded-ports" "nothing was forwarded to release"
    skip "sighup:closing-the-window-kills-the-ssh-master" "no master of ours was identified"
else
    pass "sighup:the-probe-had-a-tunnel-to-release"
    if wait_until 30 no_forwards; then
        pass "sighup:closing-the-window-releases-the-forwarded-ports"
    else
        still="$(fwd_owned_ports | do_tr '\n' ' ')"
        # shellcheck disable=SC2086
        fail "sighup:closing-the-window-releases-the-forwarded-ports" \
             "$(count_forwards) forwards are still bound (there were $FWD_BEFORE while the session
was open). An ssh client outliving its container holds its host ports against a pipe with nothing
on the far end, so nothing it forwards can be reached and the ports are not free for anything else
either. Still held, and by whom:
$(fwd_squatters $still)"
    fi
    # ...AND THE MASTER IS GONE, which is the claim tunnel_down actually makes: it asks the master
    # to exit and escalates to tunnel_kill_pid when that is not answered, then deletes the pidfile
    # either way. Asserted separately from the ports because the two can part company in both
    # directions -- a master can drop its forwards and live, and the ports can come back with
    # nothing having killed it deliberately, since a container that stops EOFs the transport and
    # the master then exits on its own in about a second.
    #
    # NOT `kill -0`: it succeeds on a zombie, the trap 12-run-timeout.sh:135 records. The argv test
    # is the launcher's own (cs193v:2079) and survives pid reuse, which kill -0 does not.
    #
    # A TRANSITION, NOT AN ABSENCE, so wait_until is the right instrument here despite its own
    # prohibition: FWD_OWNER was identified as our live master a moment ago, above.
    master_gone() {
        case "$(ps -p "$FWD_OWNER" -wwo args= 2>/dev/null)" in *"$FWD_CTL"*) return 1 ;; esac
        return 0
    }
    if wait_until 30 master_gone; then
        pass "sighup:closing-the-window-kills-the-ssh-master"
    else
        fail "sighup:closing-the-window-kills-the-ssh-master" \
             "pid $FWD_OWNER is still running as this instance's ssh master 30s after the window
closed, holding: $(fwd_owned_ports | do_tr '\n' ' ')
tunnel_down deletes the pidfile whether or not the kill worked, so a master that survives this is
one nothing can find again except --reset-tunnel -- and every host port it holds stays bound."
    fi
fi

# ...and the server in the tab went with it. If it was never reachable the assertion below is
# weaker than intended, so say so rather than quietly banking a pass -- that is exactly how #34's
# self-matching pgrep made this file green through anything.
if [ "$BEFORE_HTTP" != 200 ]; then
    record "sighup:server-in-a-tab-was-not-reachable-first" \
           "http=$BEFORE_HTTP before the kill, so a-server-in-a-tab-dies proves less than it reads"
fi
assert_fail "sighup:a-server-in-a-tab-dies-with-the-window" srv_up

# ─── 1b. force-quitting the terminal: the other ordering ───────────────────────
# THE SAME SHAPE AS GROUP 1, DELIBERATELY -- launch_in_pty is job mode, so the launcher is a
# foreground job under a leader that survives, which is a student's tree. Only the CLOSE differs:
# the pty owner is destroyed, so the master goes first, nobody is signalled, and the kernel HUPs
# the leader whose exit then revokes the terminal. That is a force quit, a crashed emulator, or a
# Mac losing power.
#
# AN ASSERTION IS NOT AVAILABLE HERE YET, AND THE HONEST REASON IS NOT #170. Measured end to end in
# this shape, a rude close tears everything down correctly anyway -- container exited, ssh master
# dead, supervisor dead, no ports held, 4/4 -- because the launcher is a job, so its exit signals
# nobody and the `podman stop` that run_timeout disowns runs to completion. #170's buffer poison is
# real on this path and has no visible outcome on it. So a green here says the OUTCOME is right; it
# is not evidence about #170 in either direction, and it must not be read as any.
#
# WHAT WOULD MAKE IT ONE is an assertion about the thing #170 actually breaks -- the ssh master and
# the forwarded ports, measured from the process table rather than through the pidfile tunnel_down
# unlinks (#159). Until that exists this stays a record, because a record that cannot fail is
# better than an assertion that passes for a reason nobody checked.
#
# ITS OWN SETUP, and that is not tidiness. Group 1 leaves BEFORE_HTTP, FWD_BEFORE and its tab
# server behind, and reusing any of them would make this group's record describe group 1's session.
release_container
launch_in_pty
if ! wait_until 90 session_up; then
    fail "sighup:the-force-quit-probe-got-a-session" \
         "the launcher never reached a tmux session in 90s, so the force-quit ordering was not
measured at all. Launcher output: $(tail -5 "$LOG" 2>/dev/null)"
else
    pass "sighup:the-force-quit-probe-got-a-session"
    force_quit_terminal "$PTY_PID"
    if wait_until 45 container_stopped; then
        record "sighup:force-quitting-the-terminal-stops-the-container" "yes"
    else
        record "sighup:force-quitting-the-terminal-stops-the-container" \
               "no, still $(st) after 45s -- and that IS worth chasing, because in this shape it
tore down 4/4 when measured. Check the ssh master and the forwarded ports before the launcher."
    fi
fi

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
# NOT assert_fail, AND THAT IS THE ASSERTION (#149). The refusal carries the CLIENT's exit code --
# 255 local, 125 remote -- and 125 is inside assert_fail's could-not-be-RUN band, so this was red
# on every Mac against a launcher that was doing exactly the right thing. The message is the same
# on both; see assert_fail_saying in lib/assert.sh for the measured matrix.
assert_fail_saying "sighup:a-stopped-container-accepts-no-exec" \
                   "can only create exec sessions on running containers" \
                   podman exec "$NAME" true
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
    #
    # ASKED, NOT INFERRED (#151). This was `pgrep -P "$PTY_PID" | head -1`, which names the
    # command only when the `/bin/sh` inside ptyrun exec-optimises itself away. On Ubuntu, where
    # /bin/sh is dash 0.5.12, it does not -- and the pid then belonged to the interposed shell,
    # which pty.fork() had made the SESSION LEADER. `kill -9` on that did not run this experiment
    # at all: the kernel HUPed the launcher, its trap RAN, the container came down, and every
    # assertion in this group inverted. lib/pty-announce is how the launcher's own pid gets here.
    LAUNCHER_PID="$(pty_inner_pid)" || LAUNCHER_PID=''
    if [ -n "$LAUNCHER_PID" ] && ! pid_is_gone "$LAUNCHER_PID"; then
        kill -9 "$LAUNCHER_PID" 2>/dev/null
        sleep 2                        # A DURATION, deliberately: this asserts a NON-event.
        # THE CONTROL COMES FIRST, because everything after it is an assertion a BROKEN
        # INSTRUMENT PASSES. Kill a stale or wrong pid and nothing dies: the container is still
        # up, so `a-force-quit-leaves-the-container-up-as-designed` is green for precisely the
        # wrong reason, and the two assertions after it are green too because they only need SOME
        # running container to refuse and then stop. So this says the pid was alive before the
        # kill -- checked in the `if` above -- and is gone after it.
        assert_ok "sighup:the-force-quit-really-killed-the-launcher" \
                  pid_is_gone "$LAUNCHER_PID"
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
        # A `fail`, where this used to `record`. With the announce channel there is no host on
        # which the launcher legitimately declines to say what pid it is: no pid means the
        # instrument broke, and the four assertions this group would have made are lost.
        fail "sighup:force-quit" "the launcher never announced a pid through lib/pty-announce,
so there was nothing to force-quit and this whole group measured nothing."
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
ZBASE="$(zombie_pids | do_tr '\n' ' ')"
record "sighup:zombies-before-the-matrix" "${ZBASE:-none}"
# The pattern follows $SRV's port for the same reason $SRV does: this asks whether the process
# survived, and a pattern naming a port the server was never started on answers no every time.
probe() {                             # probe LABEL COMMAND
    container_pkill "http.server $SRV_PORT"
    # ${NAME} SINGLE-QUOTED (#141), like every other value interpolated into a string ptyrun
    # will have `/bin/sh -c` parse a second time. This site kills only the pty owner, so it wants
    # nothing from lib/pty-announce -- and it deliberately KEEPS its inner `sh -c`, because
    # 70-sighup's own note below relies on that shell's argv carrying the pattern.
    "$DO_PY" "$PT_LIB/ptyrun.py" "podman exec -it '${NAME}' sh -c '$2'" >/dev/null 2>&1 &
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
record "sighup:MATRIX" "$(printf '%s' "$MATRIX" | do_tr '\n' '|')"
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
    record "sighup:zombies-after-the-matrix" "$(zombies_outside_baseline $ZBASE | do_tr '\n' ';')"
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
design="$(do_tr 'A-Z' 'a-z' < "$PRIVATE/CONTAINER-DESIGN.md")"
assert_contains "sighup:CONTAINER-DESIGN-addresses-closing-the-window" "terminal window" "$design"
assert_match "sighup:CONTAINER-DESIGN-says-it-STOPS-things" \
             'clos[a-z]*( your| the)? terminal[^.]*stop|stop[^.]*clos[a-z]*( your| the)? terminal' \
             "$design"

# Leave the container stopped, which is now the honest resting state. hold_container will raise it
# for whichever suite needs it next, and leaving 46 ports bound for the next developer is exactly
# what #29 stopped doing.
release_container
