#!/usr/bin/env bash
# TIER: shim
#
# #495: on a Mac whose podman VM is stopped -- which is what every Mac restart leaves -- the
# launcher starts the VM itself instead of refusing, and starts it so that it is NOT part of the
# launcher's process group. Everything here runs against lib/podman-fake with no VM anywhere.
#
# WHY THE PROCESS GROUP IS THE WHOLE STORY. podman launches krunkit and gvproxy with a bare
# exec.Cmd.Start(), so they join whatever group ran `podman machine start`. The launcher's group
# owns the terminal for the whole session, and measured on a real Mac (#495), closing the window
# or pressing Ctrl-C then power-cuts the VM -- 3/3 each, with XFS log recovery on every boot
# after. The launcher's answer is `set -m` (a group of its own) and `nohup` (SIGHUP ignored),
# in machine_start_detached in files/cs193v-ui.sh.
#
# THE MODES, one section each, every case asserting what podman was ASKED as well as what the
# student was told -- "zero `machine start` calls" is read out of argv.log, never assumed:
#   A  no VM running, nobody else starting it      E  the start itself fails or overruns
#   B  no VM running, somebody else starting it    F  a slept Mac: `podman info` hangs
#   C  our VM running but not answering            G  verbs and paths that must not start it
#   D  a VM running that is not ours / no target   H  timing and screen invariants
#   I  the VM must not belong to the launcher, with positive controls that prove the same
#      harness sees a naive start's VM die
#
# THE FAKE VM IS HONEST ABOUT SIGNALS because podman-fake applies Go's exec rule before launching
# lib/vm-fake.pl: what podman catches (INT, TERM, and Go's QUIT) the VM gets at default, what the
# caller ignored (SIGHUP under nohup) it inherits ignored. Measured on the real krunkit via sysctl.
#
# A REAL Terminal.app WINDOW IS OUT OF SCOPE here (Keith, 2026-10-12): it was measured by hand
# and is recorded in ERRORS.md. ptyrun.py's polite close is this harness's model of it.

set -u
. "$(dirname -- "$0")/lib/assert.sh"
. "$(dirname -- "$0")/lib/podman-shim.sh"

PTY_PIDS=''
pty_reap() { local p; for p in $PTY_PIDS; do kill "$p" 2>/dev/null || true; done; PTY_PIDS=''; }
HOLDERS=''
holders_reap() { local p; for p in $HOLDERS; do kill "$p" 2>/dev/null || true; done; HOLDERS=''; }
trap 'pty_reap; holders_reap; shim_cleanup' EXIT
record "shim:leftover-dirs-from-an-earlier-run" "$(shim_sweep_stale)"

COPY="$(repo_copy)"
LAUNCHER_DIR="$COPY"

# ─── helpers ───────────────────────────────────────────────────────────────────
# A Mac whose VM is in STATE. No STATE at all leaves machine_state absent -- podman-fake's old
# world, where `machine inspect` says the VM does not exist.
mac() {                               # mac [stopped|starting|running]
    shim_new
    shim_fake_uname Darwin arm64
    [ -n "${1:-}" ] && shim_set machine_state "$1"
    return 0
}
starts()        { shim_count '^machine start'; }
machine_calls() { shim_count '^machine '; }
# The launch got past preflight: it went on to create the container.
created()       { shim_count '^run '; }
vm_state()      { cat "$SHIM/machine_state" 2>/dev/null; }
# vm_pid, vm_snap, vm_alive, pgid_of and sid_of are lib/podman-shim.sh's, shared with 25-installer.sh.
vm_gone()       { ! vm_alive; }
vm_up()         { [ "$(vm_state)" = running ] && vm_alive; }
# Another window's start moving the state on, written atomically for the reason podman-fake's
# set_mstate gives: a launcher reading it mid-write would see "no machine".
vm_set()        { printf '%s' "$1" > "$SHIM/machine_state.t" && mv -f "$SHIM/machine_state.t" "$SHIM/machine_state"; }
# AN EMPTY NEEDLE NEVER MATCHES. grep -F with "" matches every line, so a wait on a message whose key
# is missing would return at once and the case after it would measure a race, not the launcher.
said()          { [ -n "$1" ] && grep -qF -- "$1" "$2" 2>/dev/null; }
# How many lines of TEXT carry PHRASE.
lines_with()    { printf '%s\n' "$2" | grep -cF -- "$1"; }

# THE TIMING KNOBS, set per case. Suite-wide they are generous rather than the real 60 s and
# 20 s, so a case that is not about timing cannot fail on a slow runner and cannot take a minute.
knobs() { export CS193V_MACHINE_DEADLINE="$1" CS193V_MACHINE_UPDATE_AT="$2"; }
knobs 20 10

STARTING="$(msg_text status.starting-machine)"
WAITING="$(msg_text status.waiting-machine)"
SLOW="$(msg_text status.machine-slow)"
for k in status.starting-machine status.waiting-machine status.machine-slow; do
    if [ -n "$(msg_text "$k")" ]; then pass "suite:needle-$k-exists"
    else fail "suite:needle-$k-exists" "no prose for $k, so every wait on it would time out"; fi
done

# THE MAC ADVICE THE UNREACHABLE REFUSAL USED TO END WITH. Everyone it still reaches -- Linux and
# WSL, a podman pointed elsewhere, a Mac with no machine -- is someone it is wrong for, now that a
# Mac's stopped VM is started rather than refused. A literal rather than a key, because the key
# stays and only this prose goes; and not `podman machine start`, which podman's own quoted error
# can contain.
OLD_MAC_ADVICE='On a Mac this almost always means'

# Somebody else holding podman's start lock while the VM still reads `stopped`: the moment
# between another window taking the lock and its start flipping the state. A sleeping process
# owns it so the fake's dead-owner takeover cannot steal it; the case releases it.
hold_start_lock() {
    sleep 600 &
    LOCK_HOLDER=$!
    HOLDERS="$HOLDERS $LOCK_HOLDER"
    mkdir "$SHIM/machine_start.lock"
    echo "$LOCK_HOLDER" > "$SHIM/machine_start.lock/pid"
}
release_start_lock() {
    rm -rf "$SHIM/machine_start.lock"
    kill "$LOCK_HOLDER" 2>/dev/null || true
}

# A launcher in the background, its transcript in $SHIM/l.out. $! of a backgrounded function is
# the subshell running it, and `wait` on it returns the launcher's status.
launch_bg() {                         # launch_bg -> a bare launch, sets LPID
    launcher > "$SHIM/l.out" 2>&1 &
    LPID=$!
}
launch_rc() { wait "$LPID" 2>/dev/null; }

# ─── the pty, with a student's Ctrl-C (I) ──────────────────────────────────────
# THE LAUNCHER HAS TO GET SIGINT AT DEFAULT, and lib/podman-shim.sh's SHIM_INTRESET is how: see it
# for why a harness cannot simply hand it on.
# A bare launch on a pty in JOB MODE -- a lingering leader above the launcher, the shape
# a Terminal window has -- whose stdin is a fifo this suite writes into: keystrokes are typed when
# the case decides, not up front. Transcript in $PTY_OUT; ptyrun's pid in $PTY_PID.
pty_launch() {                        # pty_launch -> a bare launch on a pty
    PTY_DIR="$LAUNCHER_DIR"
    local cmd="'$LAUNCHER_DIR/cs193v'"
    PTY_IN="$SHIM/pty.in"; PTY_OUT="$SHIM/pty.out"
    rm -f "$PTY_IN"; mkfifo "$PTY_IN"; : > "$PTY_OUT"
    CS193V_PTY_JOB=1 PATH="$SHIM:$PATH" \
        "$DO_PY" -c "$SHIM_INTRESET" "$DO_PY" "$PT_LIB/ptyrun.py" "$cmd" < "$PTY_IN" > "$PTY_OUT" 2>&1 &
    PTY_PID=$!
    PTY_PIDS="$PTY_PIDS $PTY_PID"
    # The writer, held open on fd 7 so the pty never sees EOF. Opened AFTER the background
    # started, so ptyrun does not inherit it, and its open is the rendezvous with ptyrun's.
    exec 7>"$PTY_IN"
}
# pty_type, pty_close, pty_end and pty_said are lib/podman-shim.sh's.
# The launcher itself, found as the process whose argv is our copy's cs193v -- the pty announces
# no pid in this shape, and ptyrun's tree is leader -> job shell -> launcher. AS BASH RUNS IT, which
# is `bash PATH` through its env shebang, and so is every subshell it forks. The bare path also
# matched ptyrun and the job shell, whose argv carry it quoted, so while the pty was open this
# never came back empty: every `wait_until 15 no_launcher` below waited its full fifteen seconds,
# and C5 reported the harness as a leftover launcher (#495 review).
launcher_pids() { pgrep -f "bash ${PTY_DIR:-$LAUNCHER_DIR}/cs193v" 2>/dev/null; }
no_launcher()   { [ -z "$(launcher_pids)" ]; }

# ═══ A. no VM running, nobody else starting it ══════════════════════════════════
mac stopped
out="$(launcher)"
assert_eq       "a1:starts-the-vm-exactly-once"        "1" "$(starts)"
assert_says_key "a1:says-it-is-starting-the-vm"        status.starting-machine "$out"
assert_eq       "a1:says-so-once"                      "1" "$(lines_with "$STARTING" "$out")"
assert_eq       "a1:the-vm-is-running-afterwards"      "running" "$(vm_state)"
assert_eq       "a1:the-launch-carries-on"             "1" "$(created)"
assert_says_key "a1:gets-as-far-as-the-shell"          err.needs-a-terminal "$out"
assert_says_not_key "a1:no-unreachable-refusal"        err.podman-unreachable "$out"
assert_says_not_key "a1:a-fast-start-shows-no-slow-line" status.machine-slow "$out"
for needle in 'machine set --rootful' 'podman-mac-helper' 'machine init' 'Cannot connect to Podman' \
              'started successfully' 'Starting machine'; do
    assert_not_contains "a1:shows-none-of-podmans-output:$needle" "$needle" "$out"
done
# ONE ANSWER AFTER THE START, NOT TWO (#495 review). The probe that heard podman answer ran in the
# launcher's own shell, so its answer IS preflight's rootless read; asking again cost a round trip
# on every launch that starts the VM.
after="$(awk '/^machine start/ { s = 1; next } s && $0 == "info --format {{.Host.Security.Rootless}}" { n++ }
              END { print n + 0 }' "$SHIM/argv.log")"
assert_eq "a1:asks-podman-once-after-the-start" "1" "$after"

# A2: the next launch finds it running and starts nothing.
shim_clear_log
out="$(launcher)"
assert_eq           "a2:a-second-launch-starts-nothing" "0" "$(starts)"
assert_not_contains "a2:and-says-nothing-about-it"      "$STARTING" "$out"
# The container exists now, so this launch STARTS it rather than creating it; reaching the shell
# is what says the launch got past preflight.
assert_says_key     "a2:and-still-gets-as-far-as-the-shell" err.needs-a-terminal "$out"

# A3: --rebuild with the VM stopped. The start line comes before the build, and the rebuild
# still succeeds. image_exists no forces a real build, so there is a bar to come after.
mac stopped
shim_set image_exists no
out="$(launcher --rebuild)"; rc=$?
assert_eq "a3:rebuild-starts-the-vm-once"  "1" "$(starts)"
assert_eq "a3:rebuild-succeeds"            "0" "$rc"
assert_eq "a3:rebuild-builds"              "1" "$(shim_count '^build ')"
first_start="$(printf '%s\n' "$out" | grep -nF -- "$STARTING" | head -1 | cut -d: -f1)"
first_step="$(printf '%s\n' "$out" | grep -nE 'STEP|[0-9]+/[0-9]+' | head -1 | cut -d: -f1)"
if [ -n "$first_start" ] && [ -n "$first_step" ] && [ "$first_start" -lt "$first_step" ]; then
    pass "a3:the-start-line-comes-before-the-build"
else
    fail "a3:the-start-line-comes-before-the-build" "start line ${first_start:-absent}, first build line ${first_step:-absent}"
fi

# A4: no terminal (the installer's --rebuild, a pipe): the label once as a plain line, no frames.
mac stopped
out="$(launcher)"
assert_eq "a4:no-tty-label-printed-once" "1" "$(lines_with "$STARTING" "$out")"
for glyph in '⣾' '⣽' '⣻' '⢿' '⡿' '⣟' '⣯' '⣷'; do
    assert_not_contains "a4:no-tty-no-spinner-frame:$glyph" "$glyph" "$out"
done
assert_not_contains "a4:no-tty-no-escape-codes" "$(printf '\033[')" "$out"

# A5: a start slower than the update threshold says so, once, after the start line.
mac stopped
shim_set machine_start_delay 3
knobs 20 1
out="$(launcher)"
knobs 20 10
assert_says_key "a5:a-slow-start-says-it-can-take-a-minute" status.machine-slow "$out"
assert_eq       "a5:says-so-once"                           "1" "$(lines_with "$SLOW" "$out")"
s_line="$(printf '%s\n' "$out" | grep -nF -- "$STARTING" | head -1 | cut -d: -f1)"
u_line="$(printf '%s\n' "$out" | grep -nF -- "$SLOW" | head -1 | cut -d: -f1)"
if [ -n "$s_line" ] && [ -n "$u_line" ] && [ "$s_line" -lt "$u_line" ]; then pass "a5:after-the-start-line"
else fail "a5:after-the-start-line" "start line ${s_line:-absent}, slow line ${u_line:-absent}"; fi
assert_eq "a5:and-the-launch-carries-on" "1" "$(created)"

# A6: the start returns before podman answers -- the boot window -- and the launch waits it out.
mac stopped
shim_set info_ok_after 3
out="$(launcher)"
assert_eq           "a6:started-once"                  "1" "$(starts)"
assert_eq           "a6:waits-out-a-late-answer"       "1" "$(created)"
assert_says_not_key "a6:without-calling-it-unreachable" err.machine-unreachable "$out"

# ═══ B. no VM running, somebody else starting it ════════════════════════════════
# B1: the VM reads `starting` because another start is in flight. We wait; we never start.
mac stopped
shim_touch machine_start_hold
PATH="$SHIM:$PATH" podman machine start </dev/null >/dev/null 2>&1 &
other=$!
HOLDERS="$HOLDERS $other"
if wait_until 10 sh -c "[ \"\$(cat '$SHIM/machine_state')\" = starting ]"; then
    before="$(starts)"
    launch_bg
    if wait_until 15 said "$WAITING" "$SHIM/l.out"; then pass "b1:says-it-is-waiting"
    else fail "b1:says-it-is-waiting" "$(cat "$SHIM/l.out")"; fi
    rm -f "$SHIM/machine_start_hold"
    launch_rc; rc=$?
    assert_eq "b1:starts-nothing-of-its-own"   "$before" "$(starts)"
    assert_eq "b1:carries-on-once-it-is-up"    "1" "$(created)"
    assert_says_not_key "b1:no-refusal"        err.machine-still-starting "$(cat "$SHIM/l.out")"
else
    fail "b1:says-it-is-waiting" "the other start never reached 'starting'"
fi
rm -f "$SHIM/machine_start_hold"

# B2: inspect reads `stopped`, but somebody else holds the start lock. Our start waits behind it,
# then hears "already running" -- which means "wait", not "fail".
mac stopped
hold_start_lock
launch_bg
if wait_until 15 sh -c "grep -q '^machine start' '$SHIM/argv.log'"; then
    vm_set running
    release_start_lock
    launch_rc; rc=$?
    l_out="$(cat "$SHIM/l.out")"
    assert_eq           "b2:tried-to-start-once"             "1" "$(starts)"
    assert_says_key     "b2:already-running-means-waiting"   status.waiting-machine "$l_out"
    assert_says_not_key "b2:not-a-start-failure"             err.machine-start-failed "$l_out"
    assert_eq           "b2:and-carries-on"                  "1" "$(created)"
else
    release_start_lock
    launch_rc
    fail "b2:tried-to-start-once" "the launcher never asked podman to start: $(cat "$SHIM/l.out")"
fi

# B3: two launchers at once, both finding the VM stopped. podman's lock serialises the starts: one
# succeeds, the other hears "already running" -- and both get past preflight.
mac stopped
shim_set machine_start_delay 2
launcher > "$SHIM/b3.1" 2>&1 & p1=$!
launcher > "$SHIM/b3.2" 2>&1 & p2=$!
wait "$p1" 2>/dev/null; wait "$p2" 2>/dev/null
o1="$(cat "$SHIM/b3.1")"; o2="$(cat "$SHIM/b3.2")"
assert_eq "b3:the-vm-ends-up-running" "running" "$(vm_state)"
n="$(starts)"
if [ "$n" -ge 1 ] && [ "$n" -le 2 ]; then pass "b3:at-most-one-start-each"
else fail "b3:at-most-one-start-each" "$n machine starts"; fi
# THE RECOVERY'S OWN REFUSALS ONLY. Two launchers racing for ONE fake container can still trip
# over each other after preflight -- ensure_container's unreadable-state refusal shares
# err.podman-unreachable's first line by design -- and that is not what this case is about. So
# the preflight refusal is told apart by its instruction, which only preflight prints.
for k in err.machine-start-failed err.machine-unreachable err.machine-still-starting \
         err.machine-other-active err.podman-unreachable.fix; do
    assert_says_not_key "b3:first-launcher-no-$k"  "$k" "$o1"
    assert_says_not_key "b3:second-launcher-no-$k" "$k" "$o2"
done
if vm_alive; then pass "b3:one-vm-is-running"; else fail "b3:one-vm-is-running" "no live vm-fake"; fi

# B4: the other start dies mid-wait (`starting` -> `stopped`): then we start it ourselves, once.
mac starting
launch_bg
if wait_until 15 said "$WAITING" "$SHIM/l.out"; then
    vm_set stopped
    launch_rc
    assert_eq "b4:starts-it-itself-exactly-once" "1" "$(starts)"
    assert_eq "b4:and-carries-on"                "1" "$(created)"
else
    launch_rc
    fail "b4:starts-it-itself-exactly-once" "never waited: $(cat "$SHIM/l.out")"
fi

# B5: the other start never finishes. At the deadline: try again in a minute, and -- the second
# time -- stop then start, as two commands.
mac starting
knobs 4 2
t0=$SECONDS
out="$(launcher)"; rc=$?
took=$((SECONDS - t0))
knobs 20 10
assert_says_key "b5:says-it-is-still-starting" err.machine-still-starting "$out"
assert_ne       "b5:exits-nonzero"             "0" "$rc"
assert_eq       "b5:starts-nothing"            "0" "$(starts)"
assert_match    "b5:names-machine-stop-on-its-own-line"  '(^|[[:space:]])podman machine stop$' \
                "$(printf '%s\n' "$out" | sed 's/[[:space:]]*┃[[:space:]]*$//; s/^[[:space:]]*┃//')"
assert_match    "b5:names-machine-start-on-its-own-line" '(^|[[:space:]])podman machine start$' \
                "$(printf '%s\n' "$out" | sed 's/[[:space:]]*┃[[:space:]]*$//; s/^[[:space:]]*┃//')"
if [ "$took" -ge 3 ] && [ "$took" -le 9 ]; then pass "b5:gives-up-at-the-deadline"; else fail "b5:gives-up-at-the-deadline" "took ${took}s for a 4s deadline"; fi
record "b5:seconds" "$took"

# B6: our start hears "already running" -- somebody else's start is in flight -- and then that
# start FAILS (`starting` -> `stopped`). Waiting will not bring the VM up now; our own start can.
mac stopped
hold_start_lock
launch_bg
if wait_until 15 sh -c "grep -q '^machine start' '$SHIM/argv.log'"; then
    vm_set starting
    release_start_lock
    if wait_until 15 said "$WAITING" "$SHIM/l.out"; then
        vm_set stopped
        launch_rc
        l_out="$(cat "$SHIM/l.out")"
        assert_eq           "b6:starts-it-itself-after-the-other-start-fails" "2" "$(starts)"
        assert_eq           "b6:and-carries-on"                               "1" "$(created)"
        assert_says_not_key "b6:without-calling-it-unreachable" err.machine-unreachable "$l_out"
    else
        launch_rc
        fail "b6:starts-it-itself-after-the-other-start-fails" "never waited: $(cat "$SHIM/l.out")"
    fi
else
    release_start_lock
    launch_rc
    fail "b6:starts-it-itself-after-the-other-start-fails" "never asked to start: $(cat "$SHIM/l.out")"
fi

# ═══ C. our VM running but not answering ════════════════════════════════════════
# C1: gvproxy died -- the VM says running, nothing answers. Wait, then stop-then-start.
mac running
shim_touch machine_unreachable
knobs 4 2
t0=$SECONDS
out="$(launcher)"; rc=$?
took=$((SECONDS - t0))
knobs 20 10
# WAITED FIRST: a VM reading `running` may be one somebody else is still booting.
if [ "$took" -ge 3 ]; then pass "c1:waits-out-the-deadline-first"; else fail "c1:waits-out-the-deadline-first" "refused after ${took}s"; fi
assert_says_key "c1:says-restart-the-vm"           err.machine-unreachable "$out"
assert_says_key "c1:gives-the-two-commands"        err.machine-unreachable.fix "$out"
assert_ne       "c1:exits-nonzero"                 "0" "$rc"
assert_eq       "c1:starts-nothing"                "0" "$(starts)"
assert_contains "c1:quotes-podman-info"            "connect: connection refused" "$out"
said_line="$(printf '%s\n' "$out" | grep -nF 'connection refused' | head -1 | cut -d: -f1)"
fix_line="$(printf '%s\n' "$out" | grep -nF 'podman machine stop' | tail -1 | cut -d: -f1)"
if [ -n "$said_line" ] && [ -n "$fix_line" ] && [ "$said_line" -lt "$fix_line" ]; then
    pass "c1:podmans-words-come-before-the-instruction"
else
    fail "c1:podmans-words-come-before-the-instruction" "podman line ${said_line:-absent}, instruction line ${fix_line:-absent}"
fi

# C2: running, but the first few answers are a booting VM's. Wait; never start.
mac running
shim_set info_ok_after 3
out="$(launcher)"
assert_eq       "c2:waits-for-the-answer" "1" "$(created)"
assert_eq       "c2:starts-nothing"       "0" "$(starts)"
assert_says_key "c2:says-it-is-waiting"   status.waiting-machine "$out"

# C3: our start returns 0, and podman never answers.
mac stopped
shim_touch machine_unreachable
knobs 4 2
out="$(launcher)"
knobs 20 10
assert_eq       "c3:started-once"                  "1" "$(starts)"
assert_says_key "c3:then-says-restart-the-vm"      err.machine-unreachable "$out"

# C4: THE REFUSAL QUOTES WHAT PODMAN SAYS NOW (#495 review), not the `info` that failed before the
# start, while the VM was still stopped. Stopped, the fake refuses the connection; started and
# never answering, it fails the handshake -- so each refusal says which one it quoted. Compared
# with the box and every space taken out, because the box wraps podman's line where it likes.
unboxed() { printf '%s' "$1" | sed -e 's/[┃┏┓┗┛━]//g' | do_tr -d '[:space:]'; }
mac stopped
shim_set info_ok_after 100000
knobs 4 2
out="$(launcher)"
knobs 20 10
assert_says_key     "c4:after-our-start-says-restart-the-vm"     err.machine-unreachable "$out"
assert_contains     "c4:quotes-what-podman-said-after-the-start" "ssh:handshakefailed" "$(unboxed "$out")"
assert_not_contains "c4:not-what-it-said-before-it"              "connectionrefused" "$(unboxed "$out")"
# ...and the same after a WAIT: the VM read `running` and refused, then went on failing the
# handshake for the whole of the wait.
mac running
shim_touch machine_unreachable
knobs 6 3
launch_bg
if wait_until 15 said "$WAITING" "$SHIM/l.out"; then
    shim_set info_ok_after 100000
    rm -f "$SHIM/machine_unreachable"
    launch_rc
    l_out="$(cat "$SHIM/l.out")"
    assert_says_key     "c4:after-a-wait-says-restart-the-vm"     err.machine-unreachable "$l_out"
    assert_contains     "c4:quotes-what-podman-said-during-the-wait" "ssh:handshakefailed" "$(unboxed "$l_out")"
    assert_not_contains "c4:not-what-it-said-before-it-after-a-wait" "connectionrefused" "$(unboxed "$l_out")"
else
    launch_rc
    fail "c4:after-a-wait-says-restart-the-vm" "never waited: $(cat "$SHIM/l.out")"
fi
knobs 20 10

# C5: CTRL-C WHILE WAITING ENDS THE WAITING TOO (#495 review). The wait is run_timeout's command, a
# `&` subshell, and a non-interactive shell hands those SIGINT ignored -- so a Ctrl-C that ended
# the launcher left that subshell asking podman twice a second until the deadline. It is a fork of
# the launcher, so it answers to the launcher's own command line.
mac starting
pty_launch
if wait_until 15 pty_said "$WAITING"; then
    pty_type '\003'
    if wait_until 10 no_launcher; then pass "c5:ctrl-c-while-waiting-leaves-nothing-asking-podman"
    else
        c5_left=''
        for p in $(launcher_pids); do
            c5_left="$c5_left [$(ps -o pid=,ppid=,pgid=,stat= -p "$p" 2>/dev/null) children: $(pgrep -lP "$p" 2>/dev/null | do_tr '\n' ',')]"
        done
        fail "c5:ctrl-c-while-waiting-leaves-nothing-asking-podman" \
             "still running:$c5_left; podman asked $(shim_count '^info ') times; last calls: $(tail -3 "$SHIM/argv.log" | do_tr '\n' '|')"
    fi
else
    fail "c5:ctrl-c-while-waiting-leaves-nothing-asking-podman" "never waited: $(tail -3 "$PTY_OUT")"
fi
pty_end

# C6: A STATE READ THAT HANGS NEAR THE DEADLINE leaves nothing behind (#495 review). The wait's own
# reads are clipped to what is left of it, so they finish inside the ceiling it is given; unclipped,
# a 5 s read outlived that ceiling, whose kill reaches the subshell but not the read it was waiting
# on -- and a hung read then runs for ever. The first state read is machine_recover's own; the
# second is the wait's.
#
# INTO A FILE, NOT A $( ). The hung read is a fork of the launcher and holds a copy of its stdout,
# so a `$(launcher)` never sees EOF and the suite hangs instead of failing -- measured, red-first.
mac starting
shim_set machine_inspect_hang_at 2
knobs 2 1
launch_bg
launch_rc
out="$(cat "$SHIM/l.out")"
knobs 20 10
hung="$(pgrep -f "$SHIM/podman machine inspect" 2>/dev/null | do_tr '\n' ' ')"
if [ -z "$hung" ]; then pass "c6:a-hung-state-read-does-not-outlive-the-launcher"
else
    fail "c6:a-hung-state-read-does-not-outlive-the-launcher" "still running: $hung"
    pkill -f "$SHIM/podman machine inspect" 2>/dev/null
fi
assert_says_key "c6:and-it-still-says-it-is-starting" err.machine-still-starting "$out"

# ═══ D. a VM running that is not ours, or no target at all ══════════════════════
# D1: another machine is up. Say which, at once -- there is nothing to wait for.
mac stopped
shim_set machine_other_active pmd-other
t0=$SECONDS
out="$(launcher)"; rc=$?
took=$((SECONDS - t0))
assert_says_sub "d1:names-the-other-machine"   err.machine-other-active "$out" "$PRIVATE/messages.txt" NAME=pmd-other
assert_contains "d1:quotes-podmans-reason"     "only one VM can be active at a time" "$out"
assert_ne       "d1:exits-nonzero"             "0" "$rc"
if [ "$took" -le 5 ]; then pass "d1:says-so-promptly"; else fail "d1:says-so-promptly" "took ${took}s"; fi
# ...and podman's other wording, for a machine on another provider.
mac stopped
shim_set machine_other_active pmd-other
shim_set machine_other_provider applehv
out="$(launcher)"
assert_says_sub "d1:names-it-on-another-provider-too" err.machine-other-active "$out" "$PRIVATE/messages.txt" NAME=pmd-other
# ...and a wording this cannot read the name out of: no `podman machine stop ?`, but the command
# that lists the machines, so the student can find the name themselves (#495 review).
mac stopped
shim_set machine_start_rc 125
shim_set machine_start_err 'Error: only one VM can be active at a time'
out="$(launcher)"
assert_says_key     "d1:an-unnamed-one-still-says-another-is-running" err.machine-other-active-unnamed "$out"
assert_says_key     "d1:an-unnamed-one-says-how-to-find-it"           err.machine-other-active-unnamed.fix "$out"
assert_contains     "d1:an-unnamed-one-names-machine-list"            "podman machine list" "$out"
assert_not_contains "d1:an-unnamed-one-names-no-placeholder"          "stop ?" "$out"

# D2: a machine exists, but not the default one: nothing to start.
mac
shim_set machine_list other-vm
shim_set info_rc 125
out="$(launcher)"
assert_says_key "d2:not-the-default-machine-refuses" err.podman-unreachable "$out"
assert_not_contains "d2:no-mac-advice"               "$OLD_MAC_ADVICE" "$out"
assert_eq       "d2:starts-nothing"                  "0" "$(starts)"
# THE STEP THAT FAILED IS THE ONE QUOTED (R6): `podman info`'s words, not the `machine inspect`
# asked afterwards -- whose "VM does not exist" is what a refusal built from the last read would
# quote, since every pmv clears RT_ERR.
assert_contains     "d2:quotes-podman-info"           "cannot connect to podman" "$out"
assert_not_contains "d2:not-the-inspect-asked-after"  "VM does not exist" "$out"

# D3: podman pointed somewhere else by the environment. Machine commands would boot the default
# VM regardless, so the launcher asks the machine nothing at all.
for var in CONTAINER_HOST CONTAINER_CONNECTION; do
    mac stopped
    out="$(env "$var=unix:///tmp/cs193v-elsewhere.sock" PATH="$SHIM:$PATH" "$LAUNCHER_DIR/cs193v" 2>&1 </dev/null)"
    assert_eq       "d3:$var-asks-the-machine-nothing" "0" "$(machine_calls)"
    assert_says_key "d3:$var-refuses-as-before"         err.podman-unreachable "$out"
    assert_not_contains "d3:$var-no-mac-advice"         "$OLD_MAC_ADVICE" "$out"
done

# D4: a rootful machine answers -- it is up -- and is refused exactly as before.
mac running
shim_set rootless false
out="$(launcher)"
assert_says_key "d4:rootful-is-still-err-rootful" err.rootful "$out"
assert_eq       "d4:starts-nothing"               "0" "$(starts)"

# D5: no machine at all.
mac
shim_set info_rc 125
out="$(launcher)"
assert_says_key "d5:no-machine-refuses-as-before" err.podman-unreachable "$out"
assert_not_contains "d5:no-mac-advice"            "$OLD_MAC_ADVICE" "$out"
assert_eq       "d5:starts-nothing"               "0" "$(starts)"

# ═══ E. the start itself fails or overruns ══════════════════════════════════════
# E1: podman cannot start it. Quote podman's error, and only that.
mac stopped
shim_set machine_start_rc 125
shim_set machine_start_err 'Error: failed to create the VM disk: no space left on device'
out="$(launcher)"; rc=$?
assert_says_key     "e1:says-the-vm-would-not-start"     err.machine-start-failed "$out"
assert_contains     "e1:quotes-podmans-error"            "no space left on device" "$out"
assert_not_contains "e1:not-podmans-progress-line"       'Starting machine' "$out"
assert_not_contains "e1:not-the-earlier-info-failure"    'connection refused' "$out"
assert_ne           "e1:exits-nonzero"                   "0" "$rc"

# E2: the start overruns the deadline. The launcher gives up; the start does NOT -- it finishes
# on its own afterwards, and the next launch finds the VM up.
mac stopped
shim_touch machine_start_hold
knobs 3 1
# STDOUT TO A PIPE WHOSE READER RECORDS EOF, not to a `$( )`. The detached start outlives this
# launcher by design, and the first helper leaked the launcher's stdout to a waiter that outlived
# it too -- so a `$( )` here deadlocked: no EOF until the start finished, and the start could not
# finish until this suite, blocked on the EOF, released the hold. Anything that reads the
# launcher's output to the end (a pipe, a log, the installer) would have hung the same way. The
# reader below turns that hang into a FAIL.
mkfifo "$SHIM/e2.pipe"
( cat "$SHIM/e2.pipe" > "$SHIM/e2.out"; : > "$SHIM/e2.eof" ) & HOLDERS="$HOLDERS $!"
t0=$SECONDS
launcher > "$SHIM/e2.pipe"; rc=$?
took=$((SECONDS - t0))
knobs 20 10
if wait_until 5 test -e "$SHIM/e2.eof"; then pass "e2:nothing-holds-the-launchers-output-after-it-exits"
else fail "e2:nothing-holds-the-launchers-output-after-it-exits" "no EOF on its stdout while the start is still held"; fi
out="$(cat "$SHIM/e2.out" 2>/dev/null)"
assert_says_key "e2:says-it-is-still-starting"   err.machine-still-starting "$out"
assert_ne       "e2:exits-nonzero"               "0" "$rc"
if [ "$took" -ge 2 ] && [ "$took" -le 8 ]; then pass "e2:gives-up-at-the-deadline"; else fail "e2:gives-up-at-the-deadline" "took ${took}s for a 3s deadline"; fi
# THE START ITSELF, NOT THE STATE FILE: a start killed at the ceiling leaves `starting` written
# behind it, so the state alone passed with the start dead (the mutation pass measured exactly
# that). podman-fake writes its pid into podman's start lock; that process must still be alive.
holder="$(cat "$SHIM/machine_start.lock/pid" 2>/dev/null | do_tr -d ' \n')"
if [ -n "$holder" ] && ! pid_is_gone "$holder"; then pass "e2:the-start-is-still-going"
else fail "e2:the-start-is-still-going" "no live start holds podman's lock (pid '${holder}')"; fi
rm -f "$SHIM/machine_start_hold"
if wait_until 10 vm_up; then pass "e2:and-finishes-on-its-own"; else fail "e2:and-finishes-on-its-own" "state $(vm_state)"; fi
shim_clear_log
out="$(launcher)"
assert_eq "e2:the-next-launch-starts-nothing" "0" "$(starts)"
assert_eq "e2:and-launches"                   "1" "$(created)"

# E3: the machine cannot even be inspected.
mac stopped
shim_set machine_inspect_rc 125
out="$(launcher)"
assert_says_key "e3:inspect-failure-refuses-as-before" err.podman-unreachable "$out"
assert_not_contains "e3:inspect-failure-no-mac-advice" "$OLD_MAC_ADVICE" "$out"
assert_eq       "e3:starts-nothing"                    "0" "$(starts)"
mac stopped
shim_touch machine_inspect_hang
out="$(launcher)"
assert_says_key "e3:inspect-hang-refuses-as-before"    err.podman-unreachable "$out"
assert_not_contains "e3:inspect-hang-no-mac-advice"    "$OLD_MAC_ADVICE" "$out"
assert_eq       "e3:hang-starts-nothing"               "0" "$(starts)"

# E4: a start that SUCCEEDS is always asked about at least once, however little of the deadline is
# left. A deadline of 0 makes that deterministic: the start still gets run_timeout's one-second
# floor and finishes inside it, and then there is no time left at all.
mac stopped
knobs 0 0
out="$(launcher)"
knobs 20 10
assert_eq           "e4:a-start-that-uses-up-the-deadline-still-launches" "1" "$(created)"
assert_says_not_key "e4:and-is-not-called-unreachable" err.machine-unreachable "$out"

# ═══ F. a slept Mac ═════════════════════════════════════════════════════════════
# F1: `podman info` hangs. That is the post-sleep refusal, at pm's ceiling, and the machine is
# not asked anything: no inspect, no start, no boot-window wait on top of a 20 s hang. (`--version`
# hanging is 30-launcher-shim.sh's hang:* cases.)
mac stopped
shim_touch info_hang
t0=$SECONDS
out="$(launcher)"
took=$((SECONDS - t0))
assert_says_key "f1:says-podman-is-not-responding" err.podman-hangs "$out"
assert_eq       "f1:asks-the-machine-nothing"       "0" "$(machine_calls)"
if [ "$took" -le 35 ]; then pass "f1:no-extra-wait-after-the-hang"; else fail "f1:no-extra-wait-after-the-hang" "took ${took}s"; fi
record "f1:seconds" "$took"

# ═══ G. verbs and paths that must not start the VM ══════════════════════════════
mac stopped
out="$(launcher --stop)"; rc=$?
assert_says_key     "g1:stop-with-the-vm-down-says-nothing-is-running" status.already-stopped "$out"
assert_eq           "g1:and-exits-0"                  "0" "$rc"
assert_eq           "g1:and-starts-nothing"           "0" "$(starts)"
assert_says_not_key "g1:and-asks-nothing"             prompt.stop "$out"

mac starting
out="$(launcher --stop)"; rc=$?
assert_says_key "g2:stop-while-starting-is-a-no-op" status.already-stopped "$out"
assert_eq       "g2:and-exits-0"                    "0" "$rc"
assert_eq       "g2:and-starts-nothing"             "0" "$(starts)"

# G3: --stop, and G3b --reset-tunnel, on a VM that says `running` and does not answer -- gvproxy
# gone. Neither verb waits or starts anything; both say what a bare launch says once its wait runs
# out, stop then start, because this is the one unreachable case left with something to do.
for verb in --stop --reset-tunnel; do
    case "$verb" in --stop) g=g3 ;; *) g=g3b ;; esac
    mac running
    shim_touch machine_unreachable
    t0=$SECONDS
    out="$(launcher "$verb")"
    took=$((SECONDS - t0))
    assert_says_key "$g:an-unreachable-vm-gets-the-stop-start-refusal" err.machine-unreachable "$out"
    assert_says_key "$g:with-the-two-commands"                         err.machine-unreachable.fix "$out"
    assert_eq       "$g:starts-nothing"                                "0" "$(starts)"
    if [ "$took" -le 5 ]; then pass "$g:without-waiting"; else fail "$g:without-waiting" "took ${took}s"; fi
done

mac stopped
shim_set image_exists no
dev="$(launcher --dev-tunnel)"
tpid="$(printf '%s\n' "$dev" | do_awk -F'\t' '$1 == "pid" { print $2 }')"
tlog="$(printf '%s\n' "$dev" | do_awk -F'\t' '$1 == "log" { print $2 }')"
tctl="$(printf '%s\n' "$dev" | do_awk -F'\t' '$1 == "ctl" { print $2 }')"
mkdir -p "$(dirname "$tpid")"
echo 999999 > "$tpid"; echo stale > "$tlog"; : > "$tctl"
shim_clear_log
out="$(launcher --reset-tunnel)"; rc=$?
assert_says_key     "g4:reset-tunnel-with-the-vm-down-says-not-running" warn.tunnel-reset-not-running "$out"
assert_eq           "g4:and-exits-0"                     "0" "$rc"
assert_eq           "g4:and-starts-nothing"              "0" "$(starts)"
assert_says_not_key "g4:and-does-not-demand-an-image"    err.no-image "$out"
assert_no_file      "g4:clears-the-stale-pidfile"        "$tpid"
assert_no_file      "g4:clears-the-stale-log"            "$tlog"
assert_no_file      "g4:clears-the-stale-socket-name"    "$tctl"

mac stopped
launcher doctor >/dev/null 2>&1
assert_eq "g5:doctor-starts-nothing" "0" "$(starts)"

# G8: doctor finding the container's clock off REPORTS it and stops there (#494). It used to offer
# to restart the VM, and measured on a real Mac (2026-10-16) that restart left the VM stopped
# whenever doctor's session leader exited: the kernel hangs up the foreground group, and the bare
# start had put the VM in it. So doctor runs here AS the session leader, on a pty, against a VM
# that is up and detached -- and if a menu appears anyway, it is answered `2`, the old restart, so
# that a menu coming back is counted in argv.log rather than left waiting.
mac stopped
PATH="$SHIM:$PATH" bash -c '. "$1"; machine_start_detached >/dev/null 2>&1' _ "$COPY/.private/files/cs193v-ui.sh"
# The fake VM writes its pid as it comes up, a moment after the start has returned.
wait_until 10 eval '[ -n "$(vm_pid)" ]'
vm0="$(vm_pid)"
shim_set state running
shim_set container_date "$(( $(date +%s) + 600 ))"
shim_clear_log
PTY_IN="$SHIM/g8.in"; PTY_OUT="$SHIM/g8.out"
rm -f "$PTY_IN"; mkfifo "$PTY_IN"; : > "$PTY_OUT"
CS193V_PTY_NOSHELL=1 PATH="$SHIM:$PATH" \
    "$DO_PY" "$PT_LIB/ptyrun.py" "$COPY/cs193v" doctor < "$PTY_IN" > "$PTY_OUT" 2>&1 &
g8pid=$!
PTY_PIDS="$PTY_PIDS $g8pid"
exec 7>"$PTY_IN"
PASTE="$(msg_text doctor.paste)"
OLDMENU='Restart the virtual machine to fix the clock'
wait_until 30 eval 'pty_said "$PASTE" || pty_said "$OLDMENU"'
pty_said "$OLDMENU" && { pty_type '2'; wait_until 30 pty_said "$PASTE"; }
exec 7>&-
wait "$g8pid" 2>/dev/null
# Proving an absence: the leader has exited, and its hangup has had time to land.
sleep 2
g8="$(cat "$PTY_OUT")"
assert_ne           "g8:the-vm-was-up-to-begin-with"       "" "$vm0"
assert_says_key     "g8:doctor-reports-the-clock-problem"  doctor.row.clock "$g8"
assert_says_key     "g8:and-says-how-to-fix-it"            doctor.clock.fix "$g8"
assert_contains     "g8:and-the-report-runs-to-the-end"    "$PASTE" "$g8"
assert_not_contains "g8:offers-no-restart"                 "$OLDMENU" "$g8"
assert_eq           "g8:stops-nothing"                     "0" "$(shim_count '^machine stop')"
assert_eq           "g8:starts-nothing"                    "0" "$(starts)"
assert_eq           "g8:the-same-vm-is-still-running"      "$vm0" "$(vm_pid)"
if vm_alive; then pass "g8:and-it-is-alive"; else fail "g8:and-it-is-alive" "doctor left the VM dead"; fi

mac stopped
launcher --dev-print-image >/dev/null 2>&1
launcher --dev-args >/dev/null 2>&1
assert_eq "g6:dev-verbs-ask-the-machine-nothing" "0" "$(machine_calls)"

# G7: not a Mac. The same failing podman gets today's refusal and no machine call -- WSL takes the
# same non-macOS arm, and cannot be faked by uname alone (platform() reads /proc/version).
shim_new
shim_fake_uname Linux x86_64
shim_set machine_state stopped
out="$(launcher)"
assert_says_key "g7:linux-refuses-as-before" err.podman-unreachable "$out"
assert_not_contains "g7:linux-gets-no-mac-advice" "$OLD_MAC_ADVICE" "$out"
assert_eq       "g7:linux-asks-no-machine"   "0" "$(machine_calls)"

# ═══ H. timing and screen invariants ════════════════════════════════════════════
# H1: the normal path adds nothing to the start itself.
mac stopped
shim_set machine_start_delay 2
t0=$SECONDS
launcher >/dev/null 2>&1
took=$((SECONDS - t0))
# ONLY A START THAT HAPPENED says anything about the start's cost: a launcher that refused at
# once would be fast for the wrong reason.
assert_eq "h1:it-really-started-the-vm" "1" "$(starts)"
if [ "$took" -ge 2 ] && [ "$took" -le 6 ]; then pass "h1:no-fixed-delay-on-top-of-the-start"; else fail "h1:no-fixed-delay-on-top-of-the-start" "took ${took}s for a 2s start"; fi
record "h1:seconds" "$took"

# H4: on a terminal, the spinner leaves a clean line behind and the cursor visible.
mac stopped
shim_fake_ssh
pty_launch
if wait_until 20 pty_said "$STARTING" && wait_until 20 vm_up; then
    pty_type 'exit\n'
    wait_until 15 no_launcher || true
    rows="$(render_pty < "$PTY_OUT")"
    srow="$(printf '%s\n' "$rows" | grep -F -- "$STARTING" | tail -1)"
    case "$srow" in
        *'⣾'*|*'⣽'*|*'⣻'*|*'⢿'*|*'⡿'*|*'⣟'*|*'⣯'*|*'⣷'*) fail "h4:the-start-line-is-left-clean" "$srow" ;;
        '') fail "h4:the-start-line-is-left-clean" "no rendered row carries the label" ;;
        *)  pass "h4:the-start-line-is-left-clean" ;;
    esac
    hide="$(grep -o "$(printf '\033')\[?25l" "$PTY_OUT" | wc -l | do_tr -d ' ')"
    last="$(do_tr -d '\n' < "$PTY_OUT" | grep -o "$(printf '\033')\[?25[lh]" | tail -1)"
    if [ "$hide" = 0 ] || [ "$last" = "$(printf '\033')[?25h" ]; then pass "h4:the-cursor-is-left-visible"
    else fail "h4:the-cursor-is-left-visible" "last cursor sequence hides it"; fi
else
    fail "h4:the-start-line-is-left-clean" "the launch never showed the start line: $(tail -5 "$PTY_OUT")"
fi
pty_end

# H6: the real defaults, read from the launcher rather than timed.
assert_contains "h6:deadline-defaults-to-60s" 'CS193V_MACHINE_DEADLINE:-60' "$(cat "$LAUNCHER_DIR/cs193v")"
assert_contains "h6:update-defaults-to-20s"   'CS193V_MACHINE_UPDATE_AT:-20' "$(cat "$LAUNCHER_DIR/cs193v")"

# ═══ I. the VM must not belong to the launcher ══════════════════════════════════
# THE SHAPES, run against the real helper and -- as positive controls -- against a copy whose
# helper is the naive `podman machine start`. A case the control does not fail is not measuring
# anything; I10 says so out loud.
NAIVE="$(repo_copy)"
ui="$NAIVE/.private/files/cs193v-ui.sh"
# THE NAIVE HELPER: see shim_naive_helper in lib/podman-shim.sh, which 25-installer.sh's controls
# are built with too.
naive_why="$(shim_naive_helper "$ui")"
if [ -z "$naive_why" ]; then pass "i10:the-naive-control-was-built"
else fail "i10:the-naive-control-was-built" "$naive_why"; fi

# I1 + I8: one start, with fds 5 and 8 held open on pipes by THIS suite. The snapshot says what the
# VM inherited; the readers say whether anything still holds the pipes once the launcher is gone.
shape_with_fds() {                    # shape_with_fds DIR -> sets HELD5_EOF HELD8_EOF
    local dir="$1"
    mkfifo "$SHIM/held5" "$SHIM/held8"
    ( cat "$SHIM/held5" >/dev/null; : > "$SHIM/held5.eof" ) & HOLDERS="$HOLDERS $!"
    ( cat "$SHIM/held8" >/dev/null; : > "$SHIM/held8.eof" ) & HOLDERS="$HOLDERS $!"
    LAUNCHER_DIR="$dir" launcher > "$SHIM/i1.out" 2>&1 5>"$SHIM/held5" 8>"$SHIM/held8"
}
mac stopped
shape_with_fds "$COPY"
if wait_until 10 vm_alive; then
    snap="$(vm_snap)"
    assert_contains "i1:the-vm-ignores-sighup"        "HUP=IGNORE" "$snap"
    assert_contains "i1:the-vm-takes-sigint-default"  "INT=DEFAULT" "$snap"
    # NOT THE CALLER'S DIRECTORY (#573): the VM holds the one it was started in for days, and a
    # drive holding a process's directory cannot be ejected.
    assert_contains "i1:the-vm-is-started-from-the-root-directory" " cwd=/ " "$snap"
    # 3..9 BY NUMBER: those are the helper's to close. Anything above that arrived from whoever
    # started this suite -- the launcher cannot name what it does not know about -- and a copy of
    # one of OUR pipes at a high number is i8's to catch, by EOF, below.
    low="$(printf '%s\n' "$snap" | sed -n 's/.*fds=//p' | do_tr ',' '\n' | awk '$1 >= 3 && $1 <= 9' | do_tr '\n' ' ')"
    assert_eq "i1:the-vm-inherited-no-fd-3-to-9" "" "$low"
    record "i1:fds-the-vm-inherited" "$(printf '%s\n' "$snap" | sed -n 's/.*fds=//p')"
    vp="$(vm_pid)"
    assert_ne "i1:the-vm-is-not-in-the-launchers-group" "$(pgid_of $$)" "$(pgid_of "$vp")"
    assert_eq "i1:but-is-in-the-same-session"           "$(sid_of $$)"  "$(sid_of "$vp")"
    if wait_until 5 test -e "$SHIM/held5.eof" && wait_until 5 test -e "$SHIM/held8.eof"; then
        pass "i8:held-pipes-reach-eof-while-the-vm-lives"
    else
        fail "i8:held-pipes-reach-eof-while-the-vm-lives" "a reader is still waiting; the VM holds fd 5 or 8"
    fi
    if vm_alive; then pass "i8:the-vm-is-still-alive-then"; else fail "i8:the-vm-is-still-alive-then" "vm gone"; fi
    # I7: SIGHUP sent straight to the VM's own group. Proving an ABSENCE, so a fixed wait.
    #
    # NEVER TO OUR OWN GROUP. If the VM is in this suite's process group -- exactly what a helper
    # that lost `set -m` produces -- that group is also run-tests.sh's and its caller's, and the
    # hangup takes the whole run down with it. Measured, by the mutation pass: it did, silently.
    # i1 above already says the VM is in the wrong group; this refuses rather than signalling.
    vg="$(pgid_of "$vp")"
    case "$vg" in
        ''|*[!0-9]*) fail "i7:sighup-to-its-group-does-not-kill-it" "could not read the VM's process group" ;;
        "$(pgid_of $$)") fail "i7:sighup-to-its-group-does-not-kill-it" \
                              "the VM is in this suite's own process group; refusing to hang it up" ;;
        *)  kill -HUP -- "-$vg" 2>/dev/null
            sleep 2
            if vm_alive; then pass "i7:sighup-to-its-group-does-not-kill-it"
            else fail "i7:sighup-to-its-group-does-not-kill-it" "it died"; fi ;;
    esac
else
    fail "i1:the-vm-ignores-sighup" "no fake VM came up: $(cat "$SHIM/i1.out")"
fi
holders_reap

# I2/I3 SHAPE: ^C or a polite close while "Starting the podman VM..." shows, the start held open.
during_start() {                      # during_start DIR ctrlc|close -> sets DS_RC DS_VM
    local dir="$1" how="$2"
    mac stopped
    shim_touch machine_start_hold
    LAUNCHER_DIR="$dir" pty_launch
    DS_VM=no
    if wait_until 20 pty_said "$STARTING" && wait_until 10 test -s "$SHIM/vm.pid"; then
        case "$how" in
            ctrlc) pty_type '\003' ;;
            close) pty_close ;;
        esac
        wait_until 15 no_launcher || true
        rm -f "$SHIM/machine_start_hold"
        # The VM must be up AND still alive: the start finished after the launcher had gone.
        wait_until 10 vm_up && DS_VM=yes
        # Proving an absence: a VM that survived the signal must still be alive a moment later.
        [ "$DS_VM" = yes ] && { sleep 1; vm_alive || DS_VM=died-late; }
    else
        DS_VM="never-started: $(tail -3 "$PTY_OUT")"
    fi
    rm -f "$SHIM/machine_start_hold"
    pty_end
}
during_start "$COPY" ctrlc
assert_eq "i2:ctrl-c-during-the-start-leaves-the-vm-starting-and-alive" "yes" "$DS_VM"
shim_clear_log
launcher >/dev/null 2>&1
assert_eq "i2:and-the-next-launch-starts-nothing" "0" "$(starts)"
during_start "$COPY" close
assert_eq "i3:closing-the-window-during-the-start-leaves-the-vm-alive" "yes" "$DS_VM"

# I4 SHAPE: a polite close MID-SESSION, the launcher held in its session by attach_hold.
mid_session() {                       # mid_session DIR -> sets MS_VM
    local dir="$1"
    mac stopped
    shim_fake_ssh
    shim_touch attach_hold
    LAUNCHER_DIR="$dir" pty_launch
    MS_VM=no
    if wait_until 30 sh -c "grep -q -- '--attach' '$SHIM/argv.log'" && vm_alive; then
        pty_close
        wait_until 15 no_launcher || true
        rm -f "$SHIM/attach_hold"
        # Proving an absence: the close has been and gone; the VM must still be there.
        sleep 2
        vm_alive && MS_VM=yes
        [ "$(shim_count '^stop ')" -ge 1 ] && MS_TEARDOWN=yes || MS_TEARDOWN=no
    else
        MS_VM="never-in-session: $(tail -3 "$PTY_OUT")"; MS_TEARDOWN=no
    fi
    rm -f "$SHIM/attach_hold"
    pty_end
}
mid_session "$COPY"
assert_eq "i4:closing-the-window-mid-session-leaves-the-vm-alive" "yes" "$MS_VM"
assert_eq "i4:and-the-launcher-still-tears-its-session-down"      "yes" "$MS_TEARDOWN"

# I5: the launcher exits normally first, then the window closes.
mac stopped
shim_fake_ssh
pty_launch
if wait_until 20 vm_up; then
    pty_type 'exit\n'
    wait_until 15 no_launcher || true
    pty_close
    # Proving an absence.
    sleep 2
    if vm_alive; then pass "i5:a-window-closed-after-the-session-leaves-the-vm-alive"
    else fail "i5:a-window-closed-after-the-session-leaves-the-vm-alive" "it died"; fi
else
    fail "i5:a-window-closed-after-the-session-leaves-the-vm-alive" "no VM came up: $(tail -3 "$PTY_OUT")"
fi
pty_end

# I6 SHAPE: the launcher IS the session leader (no login shell above it) and exits on its own --
# --rebuild, which needs no shell. Its exit hangs up the terminal for its whole foreground group.
as_leader() {                         # as_leader DIR -> sets AL_VM
    local dir="$1"
    mac stopped
    CS193V_PTY_NOSHELL=1 PATH="$SHIM:$PATH" \
        "$DO_PY" -c "$SHIM_INTRESET" "$DO_PY" "$PT_LIB/ptyrun.py" "$dir/cs193v" --rebuild \
        </dev/null > "$SHIM/i6.out" 2>&1
    # Proving an absence: the leader has exited and the hangup has been sent.
    sleep 2
    AL_VM=no
    [ -s "$SHIM/vm.snapshot" ] || AL_VM="never-started: $(tail -3 "$SHIM/i6.out")"
    vm_alive && AL_VM=yes
}
as_leader "$COPY"
assert_eq "i6:a-session-leader-launcher-exiting-leaves-the-vm-alive" "yes" "$AL_VM"

# I9: the helper alone, in a shell of our own: afterwards that shell has no job control.
mac stopped
m="$(PATH="$SHIM:$PATH" bash -c '. "$1"; machine_start_detached >/dev/null 2>&1; case $- in *m*) echo on ;; *) echo off ;; esac' _ "$COPY/.private/files/cs193v-ui.sh")"
assert_eq "i9:the-helper-ran-and-started-the-vm" "running" "$(vm_state)"
assert_eq "i9:the-helper-leaves-the-callers-job-control-alone" "off" "$m"

# I11: the helper called DIRECTLY, with a terminal on stdin -- as the installer calls it (#543). Through
# the launcher run_timeout's background job already hands it /dev/null (the mutation pass showed no
# case there could see `</dev/null` go), so only a direct call can. podman 6.0.2 asks a question on
# a terminal; from a background job that read stops it, and the start never finishes.
mac stopped
# IN $SHIM, so that what nohup would leave behind lands where this case can look for it -- and not
# in the checkout, which is where the mutation pass's guard-less helper put one.
PATH="$SHIM:$PATH" do_script 20 \
    "cd '$SHIM' && bash -c '. \"$COPY/.private/files/cs193v-ui.sh\"; machine_start_detached; echo helper-rc=\$?'" \
    </dev/null > "$SHIM/i11.out" 2>&1
assert_eq           "i11:a-direct-call-on-a-terminal-starts-the-vm" "running" "$(vm_state)"
assert_contains     "i11:and-returns-podmans-status"                "helper-rc=0" "$(cat "$SHIM/i11.out")"
assert_not_contains "i11:podman-was-never-asked-a-question" "default system connection" "$(cat "$SHIM/i11.out")"
# NO nohup.out WHERE IT RAN. Handed a terminal on stdout, nohup writes one into the current
# directory -- a student's course folder -- and the helper's guard is what stops it.
assert_no_file      "i11:no-nohup-out-left-where-it-ran"    "$SHIM/nohup.out"

# I10: THE POSITIVE CONTROLS. The same harness, a naive helper: the VM must die in every shape the
# real helper survives, or those cases above measured nothing.
# "no" EXACTLY, not merely "not yes": each shape reports "no" only when the VM came up and then
# died, and something else when it never came up at all -- which would be a control that
# controls nothing.
during_start "$NAIVE" ctrlc
assert_eq "i10:naive-start-dies-on-ctrl-c" "no" "$DS_VM"
mid_session "$NAIVE"
assert_eq "i10:naive-start-dies-on-a-mid-session-close" "no" "$MS_VM"
as_leader "$NAIVE"
assert_eq "i10:naive-start-dies-when-a-leader-launcher-exits" "no" "$AL_VM"
mac stopped
shape_with_fds "$NAIVE"
if wait_until 10 vm_alive; then
    if wait_until 3 test -e "$SHIM/held5.eof"; then
        fail "i10:naive-start-keeps-the-held-pipe-open" "EOF arrived -- the fd test cannot see a leak"
    else
        pass "i10:naive-start-keeps-the-held-pipe-open"
    fi
    assert_not_contains "i10:naive-start-vm-does-not-ignore-sighup" "HUP=IGNORE" "$(vm_snap)"
    assert_not_contains "i10:naive-start-vm-keeps-the-callers-directory" " cwd=/ " "$(vm_snap)"
else
    fail "i10:naive-start-keeps-the-held-pipe-open" "no VM came up in the naive copy"
fi
holders_reap
