#!/usr/bin/env bash
# TIER: container
#
# VERIFICATION.md §A.4 (flags), §A.5 (kernel and namespaces), §A.6 (the full port matrix),
# §A.7 (files and watching) and §A.9 (resource limits), against a live cs193v container.
#
#     ./cs193v --rebuild        # then run this
#
# Two of §A.5's checks are corrected rather than copied:
#   * the 256-colour probe called `podman exec -it` with no -e TERM, so TERM defaulted to
#     xterm and it reported 8 colours — it FAILED on a correctly working system. The
#     launcher forwards TERM in open_shell, so the probe has to as well.
#   * §A.4's note that .Config.Env should hold TERM and COLORTERM is impossible: those are
#     passed per-exec, never at create time.
#
# Genuinely platform-dependent values are RECORDED, not asserted. Pinning an expectation to
# one kernel's answer would make the suite fail on a Mac for no good reason, and several of
# these exist specifically to find out what a platform does.

set -u
. "$(dirname -- "$0")/lib/assert.sh"

require_running
# WHICH PORTS: none, until this file makes some. There is no declared set to read any more, so
# every port assertion below runs against ports THIS RUN binds inside the container and waits for
# the tunnel to carry -- dyn_ports, which hard-fails if it never does. Established rather than
# read, which is strictly stronger: the old version could pass on a well-formed list while nothing
# was forwarded at all. Recorded, not asserted, so a results file says which ports ran.
fwd_init
# The port matrix below reaches the container's own loopback through the tunnel, and a
# back-to-back run arrives with the container up and the tunnel gone -- 80-launcher-live.sh
# releases it on purpose so a finished run does not sit on those ports. See require_tunnel.
require_tunnel
cd "$REPO" || exit 1

TMP="$(new_tmpdir)"
cleanup() {
    # Never leave stray servers or scratch files behind in the student's projects/.
    clean_vt_processes
    rm -rf "$TMP" 2>/dev/null || true
    clean_vt_fixtures
}
trap cleanup EXIT
# ...and again at START, because the trap above cannot run if this process is killed. Both
# halves of that, and for the same reason:
#   * clean_vt_fixtures -- the fixtures below are written with `>`, which keeps an existing
#     file's mode, so a leftover makes an assertion report on the wrong file (#30).
#   * clean_vt_processes -- a leftover LISTENER answers this run's requests, so the port
#     assertions passed with nothing of this run's bound at all (#34).
record "container:leftover-processes-from-an-earlier-run" "$(count_vt_processes)"
clean_vt_processes
clean_vt_fixtures

# ─── §A.4 the flags the container was actually created with ────────────────────
assert_eq "flag:network-is-pasta" "pasta" "$(I '{{.HostConfig.NetworkMode}}')"

MEM="$(I '{{.HostConfig.Memory}}')"
SWAP="$(I '{{.HostConfig.MemorySwap}}')"
record "flag:memory"      "$MEM"
record "flag:memory-swap" "$SWAP"
# local.args holds the cap the installer computed for this machine; the container must
# actually have it, or the protection is decorative.
if [ -f "$REPO/.config/local.args" ]; then
    want_mb="$(sed -n 's/^--memory=\([0-9]*\)m/\1/p' "$REPO/.config/local.args" | head -1)"
    if [ -n "$want_mb" ]; then
        assert_eq "flag:memory-matches-local.args" "$((want_mb * 1048576))" "$MEM"
    else
        record "flag:memory-matches-$REPO/.config/local.args" "local.args sets no cap on this machine"
    fi
else
    record "flag:memory-matches-local.args" "no local.args (installer not run here)"
fi
# The "--memory-swap equal to --memory" idiom is DOCKER's semantics; podman-run(1) requires
# strictly larger, so shipping it can make the container refuse to start.
assert_ne "flag:swap-not-equal-to-memory" "$MEM" "$SWAP"

# podman's default. A tighter limit does not kill the container, it WEDGES it: `podman exec`
# must fork into the same cgroup, so the launcher cannot get back in, and it does not
# self-heal.
assert_eq "flag:pids-limit-is-podman-default" "2048" "$(I '{{.HostConfig.PidsLimit}}')"

# Host isolation comes from the user namespace, not the capability set — root owns
# /usr/bin and /etc, so euid 0 inside needs no capability to tamper with the toolchain.
# What matters is that nothing was ADDED.
caps="$(I '{{json .HostConfig.CapAdd}}') $(I '{{json .HostConfig.CapDrop}}')"
record "flag:capabilities" "$caps"
assert_not_contains "flag:no-SYS_ADMIN" "SYS_ADMIN" "$caps"
assert_not_contains "flag:no-SYS_PTRACE" "SYS_PTRACE" "$caps"

sec="$(I '{{json .HostConfig.SecurityOpt}}')"
record "flag:security-opt" "$sec"
# no-new-privileges is mutually exclusive with the sudo decision: /usr/bin/sudo is setuid
# and no-new-privileges makes execve ignore setuid bits.
assert_not_contains "flag:no-new-privileges-absent" "no-new-privileges" "$sec"
# label=disable silently strips SELinux type enforcement for anyone on Fedora or RHEL.
assert_not_contains "flag:label-disable-absent" "label=disable" "$sec"
assert_not_contains "flag:seccomp-not-unconfined" "seccomp=unconfined" "$sec"

# --init bind-mounts the HOST's catatonit, which Ubuntu's podman package only Recommends,
# so a host missing it fails to start the container at all. PID 1 is a shell keep-alive
# loop in the image instead.
assert_eq "flag:init-is-off" "false" "$(I '{{.HostConfig.Init}}')"

tmpfs="$(I '{{json .HostConfig.Tmpfs}}')"
record "flag:tmpfs" "$tmpfs"
assert_not_contains "flag:no-tmpfs-on-tmp" '/tmp' "$tmpfs"
record "flag:shm-size" "$(I '{{.HostConfig.ShmSize}}')"

# The EXPLICIT uid=/gid= form, not bare --userns=keep-id: bare keep-id maps the host uid to
# the SAME number, which breaks on macOS (501) and on six-digit enterprise uids.
assert_contains "flag:userns-keep-id-explicit" "--userns=keep-id:uid=1000,gid=1000" \
                "$(./cs193v --dev-print-command </dev/null)"

# The container must publish NOTHING. A -p line does not supplement the ssh tunnel, it
# competes with it: both bind host 127.0.0.1:<port> and the loser gets EADDRINUSE. podman wins
# that race, because the container is created before the tunnel starts, so a stray -p line
# would silently take the port away from the student rather than double-serve it.
assert_eq "ports:container-publishes-nothing" "{}" "$(I '{{json .HostConfig.PortBindings}}')"
assert_eq "ports:no-podman-mappings" "0" "$(podman port "$NAME" | wc -l | tr -d ' ')"

# The forwards live on the HOST instead, in one ssh process. Loopback-only is now structural
# rather than a flag that could be forgotten -- the ssh client binds 127.0.0.1 itself -- but it
# is asserted anyway, because it is what keeps a dev server off dorm wifi.
# ESTABLISH TWO, and this line is where the whole port section gets its subject. dyn_ports binds
# them inside the container and waits for our master to carry them, so by the time it returns the
# feature has already been proved end to end once; everything below asks narrower questions about
# ports that are known to be up.
DYN2="$(dyn_ports 2)"
DYN1="$(printf '%s' "$DYN2" | awk '{print $1}')"
DYN2ND="$(printf '%s' "$DYN2" | awk '{print $2}')"
record "ports:the-ports-under-test" "$DYN2"
pass "ports:a-port-bound-inside-reaches-the-host"

# NOT LAN-EXPOSED, asked of everything our master holds rather than of a declared set. This is one
# of the three security properties the whole design rests on, and it got STRONGER with the change:
# there is no list to be checked against, so the question is now "is every port this tunnel has
# opened, whatever it is, on 127.0.0.1" -- and fwd_owned_ports only matches loopback binds, so the
# check is that our master holds nothing anywhere else.
mpid="$(tunnel_owner_pid)"
wild="$(ss -ltn 2>/dev/null | awk -v p="pid=$mpid," '$0 ~ p { print $4 }' \
        | grep -v '^127\.0\.0\.1:' || true)"
assert_eq "ports:no-forward-is-lan-exposed" "" "$wild"

# One process for every forward -- the multiplexing that makes a new connection cost a channel
# rather than a 158ms podman exec. If this ever became one process per port, the design regressed.
# NOT ownership-filtered, deliberately: filtering by our own pid first would make the answer 1
# by construction and the assertion vacuous. require_tunnel has already established that every
# one of these ports is ours, so a second pid here means ssh stopped multiplexing.
nproc_fwd="$(ss -ltnp 2>/dev/null | awk -v re="^127[.]0[.]0[.]1:($(printf '%s' "$DYN2" | tr ' ' '|'))\$" \
                 '$4 ~ re && /pid=/ { print }' \
             | sed -E 's/.*pid=([0-9]+).*/\1/' | sort -u | grep -c . || true)"
assert_eq "ports:one-ssh-process-carries-them-all" "1" "${nproc_fwd:-0}"

mounts="$(I '{{json .Mounts}}')"
# sshd cannot serve the tunnel without these, and they must be READ-ONLY so a compromised
# container cannot change who may log in.
assert_contains "tunnel:authorized_keys-is-mounted" "authorized_keys" "$mounts"
# Asked of the parsed JSON rather than by regex over one long line: the destination is
# "/home/student/.ssh/authorized_keys", so a pattern anchored on a quote before the filename
# silently never matches and the assertion passes for the wrong reason.
writable="$(printf '%s' "$mounts" | python3 -c 'import json,sys
print(" ".join(m["Destination"] for m in json.load(sys.stdin)
               if ("/.ssh/" in m["Destination"] or "cs193v_host" in m["Destination"])
               and m["RW"]))')"
assert_eq "tunnel:key-mounts-are-read-only" "" "$writable"
assert_contains "mount:workspace-bind-points-at-projects" "$REPO/projects" "$mounts"
# Base names, matching the launcher's remove_volumes: the instance suffix lives in $NAME, so
# these read cs193v-claude for a student and cs193v-<instance>-claude for a developer. The
# assertion NAME stays instance-free so results files compare across instances.
for v in claude claude-json codex gh vercel playwright git; do
    assert_contains "mount:volume-cs193v-$v" "$NAME-$v" "$mounts"
done
nvol="$(podman inspect "$NAME" --format '{{json .Mounts}}' \
        | python3 -c 'import json,sys; print(sum(1 for m in json.load(sys.stdin) if m["Type"]=="volume"))')"
assert_eq "mount:exactly-seven-volumes" "7" "$nvol"

assert_match "label:confighash-is-set" '.' "$(I '{{index .Config.Labels "cs193v.confighash"}}')"
assert_eq "label:dir-is-this-repo" "$REPO" "$(I '{{index .Config.Labels "cs193v.dir"}}')"
# NOTHING NAMES A PORT IN THE CONTAINER'S ENVIRONMENT, which is the create-time half of the
# no-declared-list invariant. 10-static.sh asserts the args file declares none; this asserts none
# reached the container, so a -e line added by any other route is caught too.
assert_not_contains "env:no-port-list-reaches-the-container" "CS193V_PORTS" \
                    "$(I '{{json .Config.Env}}')"
record "pid1" "$(I '{{json .Config.Entrypoint}} {{json .Config.Cmd}}')"

# ─── identity: hostname, banner, goodbye  (#3, #4) ─────────────────────────────
# The hostname is what makes Ubuntu's default prompt read student@cs193v-development.
assert_eq "identity:hostname" "cs193v-development" "$(E 'hostname')"

# The banner needs a pty: it is guarded to interactive shells so that `podman exec <cmd>`
# and this suite's own non-interactive calls do not get a greeting mixed into their output.
pty_login() {                     # pty_login KEYS -> everything the session printed
    printf '%b' "$1" | timeout 45 script -q -c "podman exec -it ${NAME} bash -l" /dev/null 2>&1
}

out="$(pty_login 'exit\n')"
n="$(printf '%s' "$out" | grep -acF "$CS193V_WELCOME" || true)"
assert_eq "identity:banner-appears-exactly-once" "1" "$(printf '%s' "$n" | head -1)"
assert_contains "identity:prompt-shows-the-hostname" "cs193v-development" "$out"
# The clear must come BEFORE the banner, or the banner scrolls away with the old content.
if printf '%s' "$out" | grep -aq $'\033\[3J'; then
    pass "identity:clears-scrollback-on-entry"
else
    fail "identity:clears-scrollback-on-entry" "no [3J in the session output"
fi
assert_contains "identity:goodbye-on-exit" "$CS193V_GOODBYE" "$out"

# A nested shell must NOT repeat the banner. /etc/profile.d only runs for login shells, so
# this should hold for free -- but it is the difference between a helpful entry banner and
# noise every time a student or an agent starts a subshell.
out2="$(pty_login 'bash\nexit\nexit\n')"
n2="$(printf '%s' "$out2" | grep -acF "$CS193V_WELCOME" || true)"
assert_eq "identity:nested-shell-does-not-repeat-the-banner" "1" "$(printf '%s' "$n2" | head -1)"

# And a non-interactive exec must be completely silent -- this is how the rest of this
# suite, and any agent, runs commands in the container.
plain="$(E 'echo hi')"
assert_eq "identity:non-interactive-exec-is-silent" "hi" "$plain"
assert_not_contains "identity:non-interactive-has-no-banner" "$CS193V_WELCOME" "$plain"
assert_not_contains "identity:non-interactive-has-no-goodbye" "$CS193V_GOODBYE" "$plain"

# ─── the tmux landing point ────────────────────────────────────────────────────
# Everything above drove `bash -l`, which is the path a SCRIPT takes and must keep working
# unchanged. This drives cs193v-shell, which is what a student gets.
#
# What this tier covers is session lifecycle -- create, reattach, stay independent -- which
# needs a real container and real podman exec clients. What the session LOOKS LIKE is
# 65-tmux.sh's job; it drives a real tmux under an instrument and reads rendered screens.
TM="tmux -L cs193v -f /etc/cs193v/tmux.conf"

pty_shell() {                     # pty_shell KEYS -> everything the session printed
    printf '%b' "$1" | timeout 45 script -q -c "podman exec -it -e CS193V_CONTAINER=${NAME} ${NAME} cs193v-shell" /dev/null 2>&1
}
tmux_kill_all() { E "$TM kill-server" >/dev/null 2>&1 || true; }

# ─── readiness, instead of a guess at how long readiness takes ─────────────────
# Every one of these replaced a fixed `sleep 6` or `sleep 1`, and they are all POSITIVE
# conditions -- a client attached, a pane drew something, the session count reached N. See
# wait_until in lib/assert.sh for why that distinction is the whole rule: a fixed sleep stays
# wherever the thing being proved is that nothing happened.
#
# These also fail FASTER than the sleeps did in the one case that matters. A client that died
# on the way up used to be measured six seconds later, against a container with nothing in it;
# now the wait runs out and the assertion names it.
# tmux_sessions_are and tmux_unattached went with #41's reattach group: one counted up to the
# second concurrent session that is now refused, the other waited for the pruning that no longer
# exists. Both would have sat here as helpers nothing called.
tmux_client_attached() { [ "$(E "$TM list-clients -F 1" | head -1)" = 1 ]; }
tmux_windows_are()     { [ "$(E "$TM list-sessions -F '#{session_windows}'" | head -1)" = "$1" ]; }
# A pane that has printed nothing yet is indistinguishable from one whose banner is missing,
# so the two absence assertions below have to wait for the pane to have drawn SOMETHING.
tmux_pane_drawn()      { [ -n "$(E "$TM capture-pane -p -t $1" | tr -d '[:space:]')" ]; }

# A terminal window that stays open, for the tests that then close it.
#
# Backgrounded as a PIPELINE, not as `pty_shell ... &`. `$!` after `f &` is the pid of the
# SUBSHELL running f, and killing that leaves script, podman and the tmux client happily
# alive -- so the window was never really closed and every assertion after it measures
# nothing. In `printf ... | script ... &`, `$!` is the last element of the pipeline, which is
# script itself. Defined once so no call site can get that wrong again.
start_client() {                  # start_client -> sets CLIENT_JOB (script's pid)
    printf 'sleep 600\n' | script -q -c "podman exec -it -e CS193V_CONTAINER=${NAME} ${NAME} cs193v-shell" /dev/null >/dev/null 2>&1 &
    CLIENT_JOB=$!
}

# Close it, and do not come back until it is REALLY gone (issue #32).
#
# The `podman exec` client is script's child, so that is what has to be killed to simulate the
# window going away in THIS harness -- which drives cs193v-shell directly and never runs the
# launcher. Note that this is no longer what closing a real window does: since #41 a real window
# closing signals the LAUNCHER, which stops the whole container. 70-sighup.sh models that, by
# destroying the pty instead; here the point is only to leave a session with a dead client behind.
#
# So kill the CHILD and wait for SCRIPT. Killing script first is what made this racy: SIGKILL
# is not propagated to descendants, so the client is orphaned onto a subreaper that may not
# be scheduled promptly, and its death becomes something a test can only sample and hope for.
# Done this way round the kernel does the synchronising for us -- script reaps the client
# before exiting, and `wait` returns only once script itself is reaped, so by the time this
# returns the client is out of the process table. No sleep, no polling, nothing to tune.
close_client() {                  # close_client SCRIPT_PID -> sets CLOSED_PID
    CLOSED_PID="$(pgrep -P "$1" | head -1)"
    if [ -n "$CLOSED_PID" ]; then
        kill -9 "$CLOSED_PID" 2>/dev/null
    else
        # No child to find. Fall back to the old behaviour rather than `wait` on a script
        # whose client is still running -- that would block for the full `sleep 600`.
        kill -9 "$1" 2>/dev/null
    fi
    wait "$1" 2>/dev/null || true
}

tmux_kill_all
out="$(pty_shell 'exit\n')"
# The banner belongs to tab one.
#
# NOT a count of occurrences in the pty stream, which is what the `bash -l` assertions above
# can safely do. tmux repaints the pane when a client attaches, re-emitting the banner text
# verbatim with a cursor-position escape in front of it -- so the raw stream legitimately
# contains it more than once and a count would fail on correct behaviour. The real property
# is "tab one has it, later tabs do not", and that is asserted against rendered panes below.
assert_contains "tmux:banner-appears-in-the-first-tab" "$CS193V_WELCOME" "$out"
# The tab count badge is how a student knows other tabs can exist at all -- but at ONE tab
# there are no other tabs for it to be telling them about, so it is not drawn (issue #26).
# This session opens exactly one tab, so what must be true here is the absence.
#
# "1 TAB" and not "TAB": the + NEW TAB chip below is the thing that stays, and is the route
# to the second tab that brings the badge back. 65-tmux.sh asserts that return; this tier
# only needs to know the chrome the launcher lands a student in is the quiet one.
assert_not_contains "tmux:no-tab-count-badge-at-one-tab" "1 TAB" "$out"
assert_contains "tmux:new-tab-button-is-drawn" "+ NEW TAB" "$out"
# exit in the last tab ends the session, leaves the container, and says goodbye once.
assert_contains "tmux:goodbye-on-exit" "$CS193V_GOODBYE" "$out"
n="$(printf '%s' "$out" | grep -ac 'Goodbye' || true)"
assert_eq "tmux:goodbye-appears-exactly-once" "1" "$(printf '%s' "$n" | head -1)"
# exit-empty on: no server may survive the last session.
assert_ok "tmux:no-server-survives-the-last-exit" \
          sh -c "! podman exec ${NAME} $TM list-sessions >/dev/null 2>&1"

# THE BANNER MUST NOT FIRE IN EVERY TAB. tmux runs the login shell in each one, so before
# the $TMUX guard went into /etc/profile.d/20-cs193v-welcome.sh, pressing CTRL+T cleared the
# pane and greeted again every time. Read from rendered panes, which is redraw-independent.
tmux_kill_all
start_client; bclient=$CLIENT_JOB
wait_until 30 tmux_client_attached
w1="$(E "$TM list-windows -F '#{window_id}'" | head -1)"
wait_until 20 tmux_pane_drawn "$w1"
E "$TM new-window -d" >/dev/null 2>&1
w2="$(E "$TM list-windows -F '#{window_id}'" | tail -1)"
wait_until 20 tmux_pane_drawn "$w2"
assert_contains "tmux:first-tab-has-the-banner" "$CS193V_WELCOME" \
                "$(E "$TM capture-pane -p -t $w1")"
assert_not_contains "tmux:a-new-tab-does-not-repeat-the-banner" "$CS193V_WELCOME" \
                    "$(E "$TM capture-pane -p -t $w2")"
# ...and closing a tab must not say goodbye, for the same reason: .bash_logout runs per tab.
assert_not_contains "tmux:a-new-tab-does-not-say-goodbye" "$CS193V_GOODBYE" \
                    "$(E "$TM capture-pane -p -t $w2")"
close_client "$bclient"
tmux_kill_all

# The lockdown, read from the live server rather than from the file.
tmux_kill_all
E "$TM new-session -d -x 80 -y 24 'sleep 120'" >/dev/null 2>&1
assert_eq "tmux:live-prefix-table-is-empty" "" "$(E "$TM list-keys -T prefix 2>/dev/null")"
assert_eq "tmux:live-copy-mode-vi-table-is-empty" "" "$(E "$TM list-keys -T copy-mode-vi 2>/dev/null")"
assert_eq "tmux:live-prefix-is-None" "None" "$(E "$TM show -gv prefix")"
assert_eq "tmux:live-destroy-unattached-is-off" "off" "$(E "$TM show -gv destroy-unattached")"
# The title bar, from the live server and NOT from the pty stream.
#
# `#{T:...}` expands the format tmux will actually render, so nothing the PANE printed can
# satisfy this. That distinction is the whole assertion: $CS193V_TITLE is a substring of
# $CS193V_WELCOME, so the same needle matched against a session capture is answered by the
# greeting and says nothing about whether a title bar exists at all.
assert_contains "tmux:title-bar-is-drawn" "$CS193V_TITLE" \
                "$(E "$TM display-message -p '#{T:status-format[0]}'")"
assert_eq "tmux:live-six-tab-bindings" "6" \
    "$(E "$TM list-keys -T root" | grep -cE ' (M-t|C-t|M-Left|S-Left|M-Right|S-Right) ')"
tmux_kill_all
# `E()` merges stderr, and tmux writes "table prefix doesn't exist" THERE when a table is
# empty -- which is the success case. Silence it inside the container or the assertion
# compares against an error message and fails on correct behaviour.

# ─── ONE SESSION, CLAIMED ATOMICALLY  (#41) ────────────────────────────────────
# This group used to test REATTACH: close the window, and the next launch lands back in the same
# session with the same tabs. That was the design, it was measured, and #41 removed it -- the
# container now stops when the terminal does, so there is never an orphaned session to return to.
# With it went the @cs193v_host_pid stamp, the launcher's stale-client pruning, and the promise
# that a second window gets its own tabs.
#
# What replaces it is the claim. cs193v-shell creates ONE session called `cs193v`, and a second
# attempt fails on the duplicate name rather than adopting anything.
tmux_kill_all
start_client; client=$CLIENT_JOB
wait_until 30 tmux_client_attached
E "$TM new-window -d" >/dev/null 2>&1
wait_until 10 tmux_windows_are 2
first="$(E "$TM list-sessions -F '#{session_name}'" | head -1)"
assert_eq "tmux:the-session-has-one-fixed-name" "cs193v" "$first"

# THE SECOND LAUNCH IS REFUSED, and this is the part the launcher's `podman ps` check cannot do.
# `podman start` is idempotent and reports nothing, so two launches that both find a stopped
# container both start it and both arrive here; tmux's session namespace is what breaks the tie,
# atomically, inside the container where it cannot go stale across a stop.
#
# Run WITHOUT a pty on purpose. `script` swallows the child's exit status unless given -e, and the
# status IS the assertion here -- the duplicate is detected by `new-session -d` before anything
# needs a terminal, so no pty is required to reach it.
podman exec "$NAME" cs193v-shell >/dev/null 2>&1
rc=$?
assert_eq "tmux:a-second-session-is-refused-with-the-agreed-status" "3" "$rc"
assert_eq "tmux:a-refused-launch-creates-no-second-session" "1" \
          "$(E "$TM list-sessions -F 1" | grep -c .)"
# ...and it left the first session's tabs alone. A claim that half-succeeded would be worse than
# one that failed outright.
assert_eq "tmux:a-refused-launch-leaves-the-first-session-intact" "2" \
          "$(E "$TM list-sessions -F '#{session_windows}'" | head -1)"

# close_client returns only once the client is out of the process table, so everything below is
# reasoning about a window that is definitively closed rather than probably closed by now (#32).
close_client "$client"

# THE CLIENT DOES NOT DIE WITH THE WINDOW. This is still true, still counter-intuitive, and now
# load-bearing for a different reason than before.
#
# conmon keeps the exec session's pty open after the host-side `podman exec` is gone, so the tmux
# client inside stays blocked on it and tmux reports the session as attached indefinitely. Both
# ptys still exist and are still writable, so NOTHING INSIDE THE CONTAINER CAN TELL THIS APART
# from a live client.
#
# It used to be the reason the launcher had to prune ghost clients. It is now the reason the HOST
# has to be what stops the container: no in-container mechanism -- not destroy-unattached, not
# tmux's own client tracking -- can detect a closed window, so the only party that can is the
# process the window actually kills. That is why open_shell traps HUP rather than leaving the
# container to notice its own abandonment.
#
# If this assertion ever starts failing, that is GOOD NEWS: clients would be dying on their own,
# and `destroy-unattached on` would become a viable second line of defence. Read it that way
# rather than "fixing" the test.
assert_eq "tmux:a-closed-window-leaves-the-client-attached-(conmon)" "1" \
          "$(E "$TM list-sessions -F '#{session_attached}'" | head -1)"

# And the session itself outlives its client, which is what destroy-unattached off buys. In real
# use nothing observes this any more -- the container is stopping -- but it is what makes closing
# a TAB harmless, and flipping the setting would silently make every tab close destroy the session.
assert_eq "tmux:the-session-outlives-its-client" "cs193v" \
          "$(E "$TM list-sessions -F '#{session_name}'" | head -1)"
assert_eq "tmux:destroy-unattached-did-not-take-the-windows" "2" \
          "$(E "$TM list-sessions -F '#{session_windows}'" | head -1)"
tmux_kill_all

# ─── §A.5 kernel and namespaces ────────────────────────────────────────────────
record "kernel:uid-map" "$(E 'cat /proc/self/uid_map')"
# --userns=keep-id:uid=1000,gid=1000 must map the HOST user to container 1000, so files the
# student creates on the bind mount are owned by them on both sides.
assert_eq "kernel:container-uid-is-1000" "1000" "$(E 'id -u')"
# The middle column of uid_map is in the PARENT namespace, and rootless podman's parent is
# already a user namespace in which the host user appears as 0 — so keep-id shows
# "1000 0 1", not "1000 1000 1". Asserting the latter (the obvious reading) fails on a
# correctly configured rootless container.
assert_match "kernel:container-1000-maps-to-the-owning-user" '^[[:space:]]*1000[[:space:]]+0[[:space:]]+1$' \
             "$(E 'cat /proc/self/uid_map')"
# The property that actually matters is functional, and it is asserted end-to-end below in
# §A.7: a file written inside appears owned by the real host user outside.

record "kernel:CapBnd" "$(E 'grep CapBnd /proc/self/status')"
# Running as non-root, the effective set is empty — which is the point: the isolation is
# the user namespace, not a capability list.
assert_match "kernel:CapEff-is-empty" "CapEff:[[:space:]]*0+$" "$(E 'grep CapEff /proc/self/status')"

# RECORDED, not asserted. The design docs claim this reads "crun (unconfined)", but the
# exact string depends on the runtime and on whether AppArmor is even loaded, and the claim
# being made is only "AppArmor is not confining this container".
record "kernel:apparmor-attr" "$(E 'cat /proc/self/attr/current 2>/dev/null || echo unavailable')"

# The memory cap must be real. If this reads "max", the cap is not being enforced and the
# protection is illusory — which is exactly what §5.5 suspects can happen in WSL without
# cgroup delegation.
cg_mem="$(E 'cat /sys/fs/cgroup/memory.max')"
record "kernel:cgroup-memory-max" "$cg_mem"
if [ -n "$MEM" ] && [ "$MEM" != 0 ]; then
    assert_eq "kernel:cgroup-enforces-the-memory-cap" "$MEM" "$cg_mem"
else
    record "kernel:cgroup-enforces-the-memory-cap" "no cap configured on this machine"
fi
assert_eq "kernel:cgroup-pids-max" "2048" "$(E 'cat /sys/fs/cgroup/pids.max')"

# /tmp on the writable layer, not a tmpfs: no RAM pressure, no size to tune, and --rebuild
# clears it anyway.
#
# NOT `findmnt -no FSTYPE /tmp`, which VERIFICATION.md §A.5 uses: /tmp is not a mountpoint
# here (it is just a directory on the root overlay), and findmnt without -T only reports
# actual mountpoints, so it prints NOTHING. That check cannot pass on any correctly built
# image. `stat -f` reports the filesystem containing the path, which is the question.
tmp_fs="$(E 'stat -f -c %T /tmp')"
record "kernel:tmp-filesystem" "$tmp_fs"
assert_ne "kernel:tmp-is-not-a-tmpfs" "tmpfs" "$tmp_fs"
assert_eq "kernel:tmp-is-on-the-container-overlay" "$(E 'stat -f -c %T /')" "$tmp_fs"
record "kernel:shm-mount" "$(E 'findmnt -no SIZE,OPTIONS /dev/shm')"

# This one CORRECTS a claim in the design docs, which say seccomp blocks mount(). Recorded
# either way, because the answer is the point.
record "kernel:mount-in-nested-userns" \
       "$(E 'unshare -U --map-root-user -m -- mount -t tmpfs none /mnt >/dev/null 2>&1 && echo ALLOWED || echo blocked')"
# Escaping into PID 1's namespaces must not work.
assert_eq "kernel:setns-into-pid1-is-blocked" "blocked" \
          "$(E 'unshare -U --map-root-user -- nsenter --target 1 --mount true >/dev/null 2>&1 && echo ALLOWED || echo blocked')"

record "kernel:inotify-max-user-watches" "$(E 'cat /proc/sys/fs/inotify/max_user_watches')"
# /proc is NOT cgroup-aware: a student running `free` inside the container sees the host's
# RAM, not their cap. Recorded because the discrepancy is the point.
record "kernel:free-vs-cgroup" \
       "$(E 'echo "free=$(free -m | awk "/^Mem:/{print \$2}")MB cgroup=$(($(cat /sys/fs/cgroup/memory.max)/1048576))MB"')"

# The corrected colour check. podman forces TERM=xterm and does not copy the client's value
# (containers/podman#25683), so the launcher forwards it explicitly — and so must this.
assert_eq "term:256-colours-with-forwarded-TERM" "256" \
          "$(podman exec -it -e TERM=xterm-256color "$NAME" tput colors 2>/dev/null | tr -d '\r')"
record "term:colours-without-forwarding" \
       "$(podman exec -it "$NAME" tput colors 2>/dev/null | tr -d '\r')"

# env:CS193V_PORTS-visible-in-exec IS DELETED, and nothing replaced it. It asserted that a value
# passed with -e at create time reaches every later exec session and not just the first process --
# a real property of `podman start` reusing a stored environment, and worth a test. It has no
# subject any more: container.args passes no -e flags at all, because the one it used to pass was
# the port list. Retargeting it at an ENV baked into the image would test a different mechanism
# and quietly claim to test this one. If an -e line is ever added back, this is the test to
# restore with it.
assert_ok "net:dns-resolves" sh -c "podman exec ${NAME} getent hosts registry.npmjs.org"
assert_ok "net:https-egress-works" sh -c "podman exec ${NAME} curl -fsS -o /dev/null --max-time 20 https://registry.npmjs.org/"

# PID 1 must be the reaping keep-alive loop, not `sleep infinity` — sleep never calls
# wait(), so every orphan becomes a permanent zombie holding a pid slot against pids.max.
record "pid1:cmdline" "$(E 'cat /proc/1/cmdline | tr "\0" " "')"
assert_not_contains "pid1:is-not-bare-sleep" "sleep infinity" "$(E 'cat /proc/1/cmdline | tr "\0" " "')"

# sshd's OWN zombie is excluded, and this is not a fudge -- it is a process PID 1 provably
# cannot reap. While the tunnel is up the container holds exactly one `[sshd] <defunct>`: the
# original `sshd -i` that re-exec'd into sshd-session. Measured `ps -o ppid`, its parent is
# sshd's privilege-separation monitor, which stays ALIVE for the tunnel's lifetime -- and a
# process is only reparented to PID 1 when its parent dies, so no PID 1, bash or catatonit,
# could collect it. It clears when the tunnel exits. Counting it here would make a healthy
# container fail, and asserting "at most 1" would let a real leak hide behind it; naming the
# exclusion keeps the test meaning what it says. See README.md's open item on --init.
zcount() { E 'ps -eo stat,comm --no-headers | awk "\$1 ~ /Z/ && \$2 != \"sshd\" {n++} END {print n+0}"'; }
record "pid1:zombie-count-including-sshd" "$(E 'ps -eo stat --no-headers | grep -c Z || true')"
assert_eq "pid1:no-zombies-right-now" "0" "$(zcount)"

# The reaping claim, tested rather than assumed: orphan a process and check PID 1 collects
# it instead of leaving a zombie.
E 'setsid sh -c "sleep 0.2 & exit" >/dev/null 2>&1' >/dev/null 2>&1
# A FIXED SLEEP ON PURPOSE, and one of the few left. The zombie count was already 0 one
# assertion ago, so `wait_until 10 <count is 0>` would return instantly -- before the orphan
# had even been created, let alone reaped -- and pass without testing anything. The wait has to
# outlast the thing appearing as well as the thing being collected, which only a duration can.
sleep 2
assert_eq "pid1:reaps-orphans" "0" "$(zcount)"

# ─── §A.6 the full port matrix, all 46 ─────────────────────────────────────────
# One process binding every forwarded port, rather than 46 http.servers: faster, and it
# cannot half-start.
cat > "$TMP/portprobe.py" <<'PY'
import socket, selectors, sys
# argv[1] is a comma list of ports and ranges; argv[2] is the address to bind them on.
ports = []
for chunk in sys.argv[1].split(","):
    if "-" in chunk:
        a, b = chunk.split("-"); ports += list(range(int(a), int(b) + 1))
    else:
        ports.append(int(chunk))
# A ":" in the address is what makes it IPv6. One probe for both families, so the ::1 case is
# not a second inline script with its own sleep and its own pkill pattern to remember.
fam = socket.AF_INET6 if ":" in sys.argv[2] else socket.AF_INET
sel = selectors.DefaultSelector()
bound = []
for p in ports:
    s = socket.socket(fam); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind((sys.argv[2], p)); s.listen(16); s.setblocking(False)
        sel.register(s, selectors.EVENT_READ); bound.append(p)
    except OSError:
        pass
# THE SUITE READS THIS LINE AND ASSERTS ON IT. It used to print "bound %d" into a discarded
# stdout -- every probe is started with `podman exec -d` -- so a probe that bound NOTHING
# looked exactly like one that bound all 46, and a leftover listener from a killed run
# answered the requests in its place (#34). Naming the ports it could not get turns that from
# a silent pass into a failure that says which port and therefore what to look for.
missing = [p for p in ports if p not in bound]
print("probe %s: %d/%d bound%s"
      % ("ready" if not missing else "INCOMPLETE", len(bound), len(ports),
         "" if not missing else ", missing " + " ".join(str(p) for p in missing)), flush=True)
while True:
    for key, _ in sel.select(timeout=60):
        try:
            c, _ = key.fileobj.accept()
            c.recv(4096)
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
            c.close()
        except OSError:
            pass
PY
podman cp "$TMP/portprobe.py" "$NAME":/tmp/cs193v-portprobe.py

# Start a probe and WAIT FOR ITS REPORT rather than for a fixed number of seconds. The report
# is printed after the last listen(), so its arrival is the readiness signal -- 0.24 s
# measured, where the `sleep 3` it replaces was a guess in both directions at once.
#
# Its own file per probe, because the listener listing below runs two at a time, and
# REMOVED FIRST: the file is the one thing here a previous run could have written, and reading
# a stale "probe ready" would be the very failure this is fixing.
PROBE_N=0
probe_reported() {                    # 0 once the probe has written its report line
    PROBE_REPORT="$(podman exec "$NAME" cat "$PROBE_OUT" 2>/dev/null)"
    case "$PROBE_REPORT" in probe*) return 0 ;; esac
    return 1
}
probe_start() {                       # probe_start SPEC ADDR -> $PROBE_REPORT
    PROBE_N=$((PROBE_N + 1))
    PROBE_OUT="/tmp/vt-probe.$PROBE_N"
    podman exec "$NAME" rm -f "$PROBE_OUT" >/dev/null 2>&1 || true
    podman exec -d "$NAME" sh -c \
        "python3 /tmp/cs193v-portprobe.py '$1' '$2' > $PROBE_OUT 2>&1" >/dev/null
    wait_until 10 probe_reported && return 0
    PROBE_REPORT="the probe never reported anything in 10 s"
    return 1
}

# Every probe start is now asserted, not assumed. A bind that fails is the one fault that used
# to be invisible from either side: the leftover holding the port answers the request, so the
# check passes while measuring the leftover instead of this run (#34).
assert_probe() {                      # assert_probe NAME SPEC ADDR
    probe_start "$2" "$3" || true
    case "$PROBE_REPORT" in
        "probe ready"*) pass "$1" ;;
        *) fail "$1" "$PROBE_REPORT
Something else in the container is holding those ports. The suite sweeps leftovers at start,
so this is either a real in-container conflict or a process that appeared during the run." ;;
    esac
}

probe_stop() { container_pkill cs193v-portprobe; }

# ─── what reaches the host, and what does not ──────────────────────────────────
# THE WHOLE MATRIX CHANGED SHAPE. It used to bind all 46 declared ports and curl each one, which
# asked "is the list forwarded". There is no list: a port is forwarded because something inside
# the container is listening on it, so the questions worth asking are per BIND ADDRESS -- which
# kinds of listener the tunnel carries and which it refuses -- plus the two directions of the
# lifecycle, a server appearing and a server going away.
#
# EVERY PROBE GETS A FRESH PORT, picked from what is free on the host at that moment. Reusing one
# across cases would mean the previous case's forward is still lingering when the next begins, and
# the supervisor holds a vanished port for five ticks before cancelling it -- so a "refused" case
# would read as reachable through the corpse of the one before it.
host_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$1/"; }
host_gets_200() { [ "$(host_code "$1")" = 200 ]; }
host_gets_000() { [ "$(host_code "$1")" = 000 ]; }
# What the container itself says about a port, which is the reason half of every refusal. Asserting
# on it turns "unreachable" from an absence into a diagnosis -- the difference between "the tunnel
# is broken" and "you bound ::1", which is the whole reason the state file carries a reason at all.
dyn_reason() {
    podman exec "$NAME" awk -F'\t' -v p="$1" \
        '$1 == "refused" && $2 == p { print $3; exit }' /tmp/cs193v/ports 2>/dev/null
}

# THE assertion this design exists for, and it is deliberately the inverse of what podman did. A
# 127.0.0.1-bound server inside was unreachable, because podman's forwarder delivers to the
# container's eth0 and never its lo; the tunnel's far end IS that lo, so it must answer.
PL="$(dyn_free_port)"
assert_probe "ports:probe-bound-a-port-on-loopback" "$PL" 127.0.0.1
if wait_until 30 host_gets_200 "$PL"; then
    pass "ports:loopback-bound-server-IS-reachable"
else
    fail "ports:loopback-bound-server-IS-reachable" \
         "got HTTP $(host_code "$PL") from 127.0.0.1:$PL — a server on the container's own
loopback did not become reachable from this host, which is the entire premise of the design.
  the container says: $(podman exec "$NAME" grep "	$PL	" /tmp/cs193v/ports 2>&1)
Check: cs193v doctor"
fi

# AND IT GOES AWAY AGAIN. The other half of the lifecycle, and the one nothing tested before,
# because with a fixed list a forward never went away while the tunnel lived. The supervisor holds
# a vanished port for a few ticks before cancelling -- deliberately, so a dev server restarting
# does not flap -- so this waits rather than samples.
probe_stop
if wait_until 30 host_gets_000 "$PL"; then
    pass "ports:a-server-that-stops-releases-the-host-port"
else
    fail "ports:a-server-that-stops-releases-the-host-port" \
         "127.0.0.1:$PL still answers HTTP $(host_code "$PL") after the server inside was killed.
A forward outliving its server holds a host port nothing can use and answers connections that
reach nothing, which is indistinguishable from a broken tunnel."
fi

# A PORT NOTHING IS LISTENING ON INSIDE MUST BE REFUSED. This used to read "a port outside the
# forwarded set", which no longer names anything -- and note the case INVERTED: the old version
# BOUND these ports inside the container to prove they were refused anyway, which under dynamic
# forwarding is precisely how you get them forwarded. Nothing is bound now, on purpose.
UNFWD="$(free_unforwarded_ports 3)"
nunfwd=0
for p in $UNFWD; do nunfwd=$((nunfwd + 1)); done
record "ports:the-unbound-ports-under-test" "$UNFWD"
if [ "$nunfwd" -lt 3 ]; then
    fail "ports:ports-with-nothing-listening-are-refused" "only $nunfwd free host ports were
available, so there is nothing to test with. See dyn_free_port in lib/assert.sh."
else
    reachable=""
    for p in $UNFWD; do
        c="$(host_code "$p")"
        [ "$c" = 000 ] || reachable="$reachable $p($c)"
    done
    if [ -z "$reachable" ]; then
        pass "ports:ports-with-nothing-listening-are-refused"
    else
        fail "ports:ports-with-nothing-listening-are-refused" "unexpectedly reachable:$reachable"
    fi
fi

# ::1 alone is the one loopback address still out of reach, since the forward's far end is IPv4.
# The probe binds it rather than nothing being there: "refused" is a `000` that looks identical
# whether ::1 is unreachable or nothing ever listened, and the bind report is the positive control
# that tells those apart. (Verified from inside, where `curl http://[::1]:PORT/` answers 200 while
# the host gets nothing.)
#
# AND THE REASON IS ASSERTED, which is new and is the point of the state file. Unreachable-with-
# no-explanation is what sent a student to office hours; unreachable-because-v6lo is a fix they
# can apply themselves.
PV="$(dyn_free_port)"
assert_probe "ports:probe-bound-a-port-on-ipv6-loopback" "$PV" "::1"
wait_until 15 sh -c "[ -n \"$(dyn_reason "$PV")\" ]" >/dev/null 2>&1 || true
c="$(host_code "$PV")"
record "ports:ipv6-only-server-http" "$c"
record "ports:ipv6-only-server-reason" "$(dyn_reason "$PV")"
if [ "$c" = 000 ]; then
    pass "ports:ipv6-only-is-refused-as-documented"
else
    fail "ports:ipv6-only-is-refused-as-documented" \
         "got HTTP $c — ::1-only IS reachable, which is better than documented. Update
CONTAINER-DESIGN.md and ERRORS.md D4 rather than leaving them pessimistic."
fi
assert_eq "ports:ipv6-only-is-refused-with-a-reason" "v6lo" "$(dyn_reason "$PV")"
probe_stop

# The wildcard is carried -- 0.0.0.0 includes the loopback the forward's far end resolves to --
# and the host side must STILL be loopback-only. Both checks below are only worth anything if
# something really is bound to 0.0.0.0 INSIDE: with nothing bound they pass on an absence, which
# is what a leftover loopback probe used to arrange (#34).
PW="$(dyn_free_port)"
assert_probe "ports:probe-bound-a-port-on-the-wildcard" "$PW" 0.0.0.0
if wait_until 30 host_gets_200 "$PW"; then
    pass "ports:wildcard-bound-server-IS-reachable"
else
    fail "ports:wildcard-bound-server-IS-reachable" "got HTTP $(host_code "$PW") — a server on
0.0.0.0 inside the container must be reachable too, since that includes its loopback."
fi
listen="$( (ss -ltn 2>/dev/null || netstat -an) | grep ":$PW" || true)"
record "ports:host-listen-line" "$listen"
assert_not_match "ports:host-does-not-listen-on-0.0.0.0" \
                 "0\.0\.0\.0:$PW|\*:$PW|\[::\]:$PW" "$listen"

LANIP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [ -n "$LANIP" ] && [ "$LANIP" != "127.0.0.1" ]; then
    c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$LANIP:$PW/")"
    if [ "$c" = 000 ]; then pass "ports:not-reachable-from-the-LAN"
    else fail "ports:not-reachable-from-the-LAN" \
              "reachable on $LANIP (HTTP $c) — student dev servers are exposed to the network"; fi
else
    record "ports:not-reachable-from-the-LAN" "no non-loopback address on this host"
fi
probe_stop

# `ss` is how a student -- or the agent answering their question -- finds out what a server is
# actually bound to, so it has to report real sockets from inside, not just exist. Two probes at
# once, on fresh ports, because the two lines are what a student has to be able to tell apart:
# one of them is why their browser cannot connect and the other is not.
PA="$(dyn_free_port)"
PB="$(dyn_free_port "$PA")"
assert_probe "ports:probe-bound-loopback-for-the-listing" "$PA" 127.0.0.1
assert_probe "ports:probe-bound-wildcard-for-the-listing" "$PB" 0.0.0.0
sout="$(E 'ss -ltn || true')"
record "ports:in-container-listener-listing" "$(printf '%s' "$sout" | tr '\n' '|')"
assert_match "ports:ss-shows-a-loopback-bind"  "127\.0\.0\.1:$PA" "$sout"
assert_match "ports:ss-shows-a-wildcard-bind"  "(0\.0\.0\.0|\*):$PB" "$sout"
probe_stop

# ─── shortlink, from the browser's side  (issue #67) ──────────────────────────
# THE ONE ASSERTION ONLY THIS TIER CAN MAKE. 50-image.sh proves the redirect inside a throwaway
# container, where every port is free and the curl runs beside the server -- which says nothing
# about whether a student's BROWSER can reach it. That needs a real container, a real tunnel and a
# curl on the host, and it is the whole premise of the feature: the short URL is worth nothing if
# the port it names is not carried out of the container.
#
# THE PORT IS NOT PREDICTABLE ANY MORE, and that is the change this group had to absorb.
# shortlink asks the kernel for a free port -- bind(0) -- so there is no highest-forwarded port to
# derive and nothing to compare against a declared list. What replaces the old equality is
# strictly stronger: read the port back out of the URL it printed, and prove the TUNNEL agrees
# that exact port is forwarded, from both sides of it.
container_pkill shortlink
sl_url="$(E 'shortlink https://example.com/e2e?a=1 token')"
sl_port="$(printf '%s' "$sl_url" | sed -n 's|^http://localhost:\([0-9]\{1,5\}\)/token$|\1|p')"
record "shortlink:port-under-test" "${sl_port:-none} (from $sl_url)"
if [ -n "$sl_port" ]; then
    pass "shortlink:prints-a-short-url-on-a-real-port"
else
    fail "shortlink:prints-a-short-url-on-a-real-port" \
         "shortlink printed \"$sl_url\", which is not http://localhost:PORT/token.
Exit 3 prints the long URL unchanged, so this is what a degradation looks like from here: it
could not get a port the tunnel would carry. Check:  cs193v doctor"
fi

# THE CONTAINER'S OWN VIEW AGREES. shortlink only prints a short URL after the state file says its
# port is up, so this is close to a tautology -- but it is the one assertion that would catch it
# printing on the strength of a stale or misread file, which is the failure the fuzzer cannot see
# because the fuzzer never touches a real one.
if [ -n "$sl_port" ] && E "grep -q '^up	$sl_port	' /tmp/cs193v/ports"; then
    pass "shortlink:the-tunnel-says-that-port-is-up"
else
    fail "shortlink:the-tunnel-says-that-port-is-up" \
         "/tmp/cs193v/ports does not list $sl_port as up:
$(E 'cat /tmp/cs193v/ports' 2>&1)"
fi

# THE END TO END. Headers kept, because the two things worth asserting are both in them, and
# curl'd from the HOST -- the same side of the tunnel a student's browser is on.
sl_head="$(curl -sD- -o /dev/null --max-time 5 "http://127.0.0.1:$sl_port/token")"
record "shortlink:host-side-headers" "$(printf '%s' "$sl_head" | tr -d '\r' | tr '\n' '|')"
if printf '%s' "$sl_head" | grep -qE '^HTTP/1[.]. 302'; then
    pass "shortlink:the-browser-gets-a-redirect"
else
    fail "shortlink:the-browser-gets-a-redirect" \
         "no 302 from http://127.0.0.1:$sl_port/token — the short link a student is told to
click does not reach the container. That is the premise of the feature, not a detail of it.
Check:  cs193v doctor"
fi
assert_match "shortlink:the-redirect-names-the-real-url" \
             "Location: https://example[.]com/e2e[?]a=1" "$sl_head"
# The path is not incidental: a student's own project may have served this origin before, and the
# browser keys its cache and any service worker on the origin rather than on what is listening.
# So the slug has to be the one thing nothing else routes, and `/` has to stay unserved.
c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$sl_port/")"
assert_eq "shortlink:bare-root-is-not-served-through-the-tunnel" "404" "$c"

# AND IT STAYS OUT OF THE WAY of a dev server -- the case that decides whether a student's own
# work and this can coexist. It used to be proved by holding the top of the list and asserting
# shortlink came down one; there is no list to walk now, and the property is met a layer lower:
# the kernel does not hand out a port something is already listening on, so a collision inside the
# container is not merely unlikely, it cannot be expressed. What is still worth asserting is the
# consequence -- both servers up at once, on different ports, both reachable from the host.
#
# THE FIRST SERVER GOES FIRST, and leaving that out is how this was written wrong once: the
# shortlink from the assertions above was still holding its port, so the probe could not bind and
# reported 0/1 -- which reads as a mysterious in-container conflict rather than as the suite
# competing with itself.
container_pkill shortlink
# A FIXED PORT, and deliberately not one derived from $FWD_PORTS: nothing about this case depends
# on a declared list any more, so naming one would only re-couple the test to something being
# removed. Chosen from 1024-32767, outside ip_local_port_range, so the probe cannot lose a race
# with an outbound socket that already holds it.
SL_BUSY=20777
assert_probe "shortlink:a-dev-server-holds-a-port" "$SL_BUSY" 127.0.0.1
sl_url2="$(E 'shortlink https://example.com/second token')"
sl_port2="$(printf '%s' "$sl_url2" | sed -n 's|^http://localhost:\([0-9]\{1,5\}\)/token$|\1|p')"
record "shortlink:coexists-on" "${sl_port2:-none} beside $SL_BUSY"
if [ -n "$sl_port2" ] && [ "$sl_port2" != "$SL_BUSY" ]; then
    pass "shortlink:coexists-with-a-dev-server"
else
    fail "shortlink:coexists-with-a-dev-server" \
         "with a server on $SL_BUSY, shortlink printed \"$sl_url2\" — it must take some other
port and still work, not fail and not take the one already in use."
fi
c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$sl_port2/token")"
assert_eq "shortlink:the-coexisting-link-is-reachable-too" "302" "$c"
# AND THE DEV SERVER IS STILL REACHABLE, which is the half a student actually cares about: their
# own work must not have been displaced by ours.
c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$SL_BUSY/")"
assert_eq "shortlink:the-dev-server-is-reachable-too" "200" "$c"
probe_stop
container_pkill shortlink

# NOTHING LEFT HOLDING A PORT. A leaked redirect server is a forwarded port a student's dev
# server cannot have, and it would sit there for the full fifteen minutes.
#
# `[s]hortlink` RATHER THAN `shortlink`, and this is not a flourish: E() runs its argument through
# `sh -c`, so the shell doing the counting has "shortlink" in its own command line and `pgrep -f`
# matched it. The count was 1 whatever was or was not running. The bracket makes the pattern match
# the string "shortlink" while the command line containing it does not.
assert_eq "shortlink:leaves-nothing-behind" "0" \
          "$(E 'pgrep -cf "[s]hortlink" || true' | tr -d ' \n')"

# ─── §A.7 files, ownership and watching ────────────────────────────────────────
# The ownership round trip is what makes the bind mount usable at all: a file the container
# writes must be owned by the student on the host, and vice versa.
#
# The 644 is about the file the container CREATES, which is why the container unlinks it
# first and umask -- not `install -m` -- decides the mode. `install -m` would chmod after
# creating, and a mode set explicitly inside the container is already what
# files:mode-changes-propagate proves below; nothing would then be left watching the
# creation path. That path is the one VERIFICATION.md §5.2 exists to compare across macOS
# providers, libkrun's virtiofs enforcing permissions where applehv's is permissive. If a
# platform ever legitimately answers something other than 644 here, downgrade this to
# record() -- do not make it self-fulfilling by setting the mode the assertion checks.
#
# The stale file is seeded ON PURPOSE. `>` truncates an existing file and PRESERVES its
# mode, so before the rm this assertion reported whatever the last run's `chmod 600` below
# had left -- green normally, red after any run that was killed before its cleanup (#30).
# Seeding the exact leftover proves the independence on every run instead of assuming it.
printf 'stale\n' > "$REPO/projects/.vt-c" && chmod 600 "$REPO/projects/.vt-c"
E 'rm -f /home/student/projects/.vt-c; umask 022; echo hi > /home/student/projects/.vt-c'
assert_eq "files:container-write-is-host-owned" "$(id -u) $(id -g) 644" \
          "$(stat -c '%u %g %a' "$REPO/projects/.vt-c")"
assert_eq "files:container-write-readable-on-host" "hi" "$(cat "$REPO/projects/.vt-c")"

echo "from-host" > "$REPO/projects/.vt-h"
assert_ok "files:container-can-write-a-host-created-file" \
          sh -c "podman exec ${NAME} sh -c 'echo more >> /home/student/projects/.vt-h'"
assert_eq "files:container-sees-host-content" "from-host" "$(E 'head -1 /home/student/projects/.vt-h')"
assert_eq "files:host-sees-container-append" "more" "$(tail -1 "$REPO/projects/.vt-h")"

E 'chmod 600 /home/student/projects/.vt-c'
assert_eq "files:mode-changes-propagate" "600" "$(stat -c %a "$REPO/projects/.vt-c")"

# -f, or a leftover link makes `ln` fail silently -- its error is not checked -- and the
# record below then reports the PREVIOUS run's target as if it were this run's (#30).
E 'ln -sf /etc/hostname /home/student/projects/.vt-link'
record "files:symlink-target-as-seen-from-host" "$(readlink "$REPO/projects/.vt-link")"

# Case sensitivity determines whether a Mac student's `import './Button'` bug reproduces
# here. Recorded, because the answer differs per platform and the docs must match it.
record "files:case-sensitivity" \
       "$(E 'cd /home/student/projects && touch .vt-Aa && (ls .vt-aA >/dev/null 2>&1 && echo CASE-INSENSITIVE || echo case-sensitive)')"

# inotify from INSIDE is the case that matters: in this course the writer is always inside
# the container, so this is what a dev server's hot reload depends on. CONTAINER-DESIGN.md tells
# students their dev server's hot reload works for edits made inside the container, and this is
# the only check of that claim anywhere.
#
# NO LONGER GUARDED ON THE TOOL BEING INSTALLED, which is the whole of #39. inotify-tools was not
# in the image, so this block took an `else` branch on every run since it was written: the
# assertion had never once executed, and the `record` standing in for it printed the same
# sentence every time -- which reads like coverage in the summary counts rather than like the
# absence of it. Found by mutation-testing #29's converted waits, when the mutant built to break
# this check could not break it.
#
# The package is in layer 1 of the Containerfile now, and 50-image.sh holds it there. So a
# missing inotifywait is a broken image rather than a machine this suite cannot ask, and this
# tier's rule is that a missing prerequisite fails loudly instead of quietly opting out -- see
# run-tests.sh's tier notes.
#
# THE PRECONDITION IS ITS OWN ASSERTION, and it is not a restatement of the behaviour below: the
# watch can fail to fire with the tool perfectly present (a kernel limit, the overlay, the bind
# mount), and those are different faults with different fixes. Named separately so the failure
# says which one happened, including on a bare `--tier container` run that never built the image.
# THE INNER `sh -c` IS LOAD-BEARING, and this was written without it first. `command` is a shell
# BUILTIN and podman exec runs its argv directly rather than through a shell, so
# `podman exec $NAME command -v x` asks crun for a binary called `command` and gets 127 --
# "executable file `command` not found in $PATH" -- whatever is or is not installed in there. It
# failed against an image that demonstrably had inotifywait in it, while the behaviour assertion
# below passed on a real event: a precondition check that cannot pass is worth no more than one
# that cannot fail. E() wraps every other in-container check this way for the same reason.
assert_ok "files:inotifywait-is-in-the-container" \
          sh -c "podman exec ${NAME} sh -c 'command -v inotifywait' >/dev/null 2>&1"

# THE EVENT FILE MUST NOT BE ABLE TO HOLD ANYTHING ELSE, and this is not a hypothetical: the
# redirect here was `2>&1`, so with inotifywait missing the SHELL's own
# `sh: 1: inotifywait: not found` landed in /tmp/vt-in and `test -s` was true. Measured on the
# unguarded first draft of #39 -- against an image with no inotify-tools in it,
# files:inotify-fires-for-container-side-edits PASSED and the host-side record said FIRES, both
# off that one error line. So stderr goes to a file of its own, and the assertion asks for the
# EVENT rather than for bytes: `-e modify` makes inotifywait print "<path> MODIFY", and nothing
# else it or the shell can say contains that word.
#
# The `sleep 1` before the write stays a duration: `-q` means inotifywait prints nothing
# when the watch is established, so there is nothing to poll for. The wait AFTER the write is a
# different matter: the event arriving is exactly the positive condition, and it is what the
# assertion then reads.
watch_fired() { E 'test -s /tmp/vt-in' >/dev/null 2>&1; }
watch_start() {                       # watch_start -> a fresh watch on .vt-c, stderr kept apart
    E 'rm -f /tmp/vt-in /tmp/vt-in.err'
    podman exec -d "$NAME" sh -c \
        'inotifywait -q -e modify /home/student/projects/.vt-c > /tmp/vt-in 2>/tmp/vt-in.err'
}
watch_start
sleep 1; E 'echo x >> /home/student/projects/.vt-c'; wait_until 5 watch_fired || true
fired="$(E 'cat /tmp/vt-in 2>/dev/null')"
case "$fired" in
    *MODIFY*) pass "files:inotify-fires-for-container-side-edits" ;;
    *) fail "files:inotify-fires-for-container-side-edits" \
            "no MODIFY event — hot reload will not work even for edits made inside the container
/tmp/vt-in:     ${fired:-<empty>}
its stderr:     $(E 'cat /tmp/vt-in.err 2>/dev/null')" ;;
esac

# Host-side edits are expected NOT to fire on macOS and WSL. Recorded, because it
# decides what CONTAINER-DESIGN.md's "known rough edges" must say -- and until #39 this
# record was never reached either, so that paragraph rested on no measurement from here.
watch_start
sleep 1; echo y >> "$REPO/projects/.vt-c"; wait_until 5 watch_fired || true
case "$(E 'cat /tmp/vt-in 2>/dev/null')" in
    *MODIFY*) record "files:inotify-for-host-side-edits" "FIRES" ;;
    *)        record "files:inotify-for-host-side-edits" "DOES NOT FIRE" ;;
esac
# A leftover watcher cannot fake an event -- its stdout is the fd of the /tmp/vt-in that
# the `rm -f` above unlinked, so what it writes goes to an orphaned inode, not to the file
# this run reads. What it does do is accumulate one inotify instance per killed run
# against the container's limit (max_user_instances = 128, measured), which is why the
# start-of-suite sweep covers inotifywait as well as the probe (#34).
container_pkill inotifywait

# Quantify the bind-mount penalty. Recorded per platform — this is the number that decides
# whether `npm install` is tolerable on a Mac.
# Cleared before the clock starts, like .vt-pw below: over a leftover directory this times
# 2000 truncations rather than 2000 creations, and clearing it inside the timed region would
# charge the delete to the create (#30).
E 'rm -rf /home/student/projects/.vt-many'
T0="$(date +%s)"
E 'mkdir -p /home/student/projects/.vt-many && cd /home/student/projects/.vt-many && for i in $(seq 1 2000); do : > f$i; done'
T1="$(date +%s)"
record "files:create-2000-files-on-the-bind-mount-seconds" "$((T1 - T0))"
T0="$(date +%s)"
E 'rm -rf /home/student/projects/.vt-many'
T1="$(date +%s)"
record "files:delete-2000-files-seconds" "$((T1 - T0))"

# ─── browser tests, in the container a student actually gets ───────────────────
# 50-image.sh proves the browser works in the IMAGE. Two things it structurally cannot
# reach are proved here instead, and both are how this feature would fail in the field.
#
# First: the volume. ~/.cache/ms-playwright is a named volume, so what the image put there
# is visible only if podman copied it up on first mount. If that ever stopped happening the
# image tests would still pass and every student would still have no browser.
seeded="$(E 'ls -d /home/student/.cache/ms-playwright/chromium_headless_shell-* 2>/dev/null | head -1')"
record "playwright:volume-holds" "$seeded"
assert_match "playwright:volume-was-seeded-from-the-image" 'chromium_headless_shell-' "$seeded"
assert_eq "playwright:volume-is-student-owned" "student" \
          "$(E 'stat -c %U /home/student/.cache/ms-playwright')"
# Student-writable is the whole reason the volume is student-owned: a project on another
# playwright version has to be able to install its browser without sudo.
assert_ok "playwright:volume-is-student-writable" \
          sh -c "podman exec ${NAME} sh -c 'touch /home/student/.cache/ms-playwright/.wtest && rm /home/student/.cache/ms-playwright/.wtest'"

# Second: the memory cap. The build runs uncapped, so a browser that only fits without
# --memory would ship green and die on the student's first `npm test`.
shot="$(E 'cd /tmp && timeout 180 playwright screenshot -b chromium about:blank /tmp/live.png >/dev/null 2>&1; wc -c < /tmp/live.png 2>/dev/null || echo 0' | tr -d ' \n')"
E 'rm -f /tmp/live.png' >/dev/null 2>&1
record "playwright:screenshot-bytes-under-the-memory-cap" "$shot"
if [ "${shot:-0}" -gt 1000 ]; then
    pass "playwright:chromium-runs-under-the-memory-cap"
else
    fail "playwright:chromium-runs-under-the-memory-cap" \
         "rendered $shot bytes inside the live container. The image tier renders fine, so
suspect the cgroup limit: cat /sys/fs/cgroup/memory.max in the container."
fi

# The round trip that matters, because it is the one the course sells: a project-local
# @playwright/test, matching the image's playwright, driving the volume's browser through
# `npm test`. Nothing above exercises the project-local resolution path at all.
PW_V="$(E 'playwright --version' | tr -dc '0-9.')"
E "rm -rf /home/student/projects/.vt-pw && mkdir -p /home/student/projects/.vt-pw" >/dev/null 2>&1
# package.json is written directly rather than with `npm init -y`, which refuses a directory
# whose name begins with a dot ("Invalid name: .vt-pw") — and the .vt- prefix is what this
# suite's own cleanup trap keys on, so the directory name is not free to change.
E "printf '%s' '{\"name\":\"cs193v-pw-probe\",\"version\":\"1.0.0\",\"private\":true,\"scripts\":{\"test\":\"playwright test\"}}' > /home/student/projects/.vt-pw/package.json" >/dev/null 2>&1
# setContent, not a dev server: this is a test of the browser and the project-local runner,
# and dragging a server into it would mean a port failure could masquerade as a browser one.
E "cd /home/student/projects/.vt-pw && printf '%s\n' \"import { test, expect } from '@playwright/test';\" \"test('renders', async ({ page }) => { await page.setContent('<h1>cs193v</h1>'); await expect(page.locator('h1')).toHaveText('cs193v'); });\" > probe.spec.ts" >/dev/null 2>&1
pwinst="$(E "cd /home/student/projects/.vt-pw && timeout 300 npm install --no-audit --no-fund -D @playwright/test@$PW_V 2>&1 | tail -4")"
npmout="$(E "cd /home/student/projects/.vt-pw && timeout 300 npm test 2>&1 | tail -15")"
record "playwright:npm-test-output" "$(printf '%s' "$npmout" | tr '\n' ' ' | cut -c1-300)"
case "$npmout" in
    *"1 passed"*) pass "playwright:npm-test-round-trip-with-a-project-local-runner" ;;
    *) fail "playwright:npm-test-round-trip-with-a-project-local-runner" \
            "a project-local @playwright/test@$PW_V could not drive the baked browser.
npm install said:
$(printf '%s' "$pwinst" | tail -4)
npm test said:
$(printf '%s' "$npmout" | tail -8)" ;;
esac
E 'rm -rf /home/student/projects/.vt-pw' >/dev/null 2>&1

# ─── §A.9 resource limits ──────────────────────────────────────────────────────
# A clean OOM: the greedy process dies, the container survives, and the launcher can still
# get in. What a student sees here becomes the troubleshooting entry for exit 137.
#
# HARD-GATED on a cap actually being in force. With no --memory, this loop does not stop at
# a cgroup boundary — it eats the whole host until the kernel OOM killer picks a victim,
# which on a small machine may well be something the user cares about. An unguarded version
# of this test is a hazard, not a test.
if [ -n "$MEM" ] && [ "$MEM" != 0 ] && [ "$cg_mem" != max ]; then
    oom="$(E 'python3 -c "
b = []
try:
    while True: b.append(bytearray(64*1024*1024))
except MemoryError:
    print(\"MemoryError\")" 2>&1; echo "rc=$?"')"
    record "limits:oom-behaviour" "$(printf '%s' "$oom" | tr '\n' ' ')"
    assert_match "limits:allocation-loop-is-stopped" 'MemoryError|rc=(137|1|139)' "$oom"
    assert_eq "limits:container-survives-an-oom" "running" "$(I '{{.State.Status}}')"
    assert_ok "limits:launcher-can-still-get-in-after-an-oom" sh -c "podman exec ${NAME} true"
else
    skip "limits:allocation-loop-is-stopped" \
         "no memory cap in force (cgroup memory.max=$cg_mem) — running an unbounded
allocation loop would exhaust the HOST, not the container"
    skip "limits:container-survives-an-oom" "no memory cap in force"
    skip "limits:launcher-can-still-get-in-after-an-oom" "no memory cap in force"
fi

# The pids limit, on a DISPOSABLE container. NEVER fork-bomb the live one: pids exhaustion wedges
# it beyond `podman exec`'s reach and does not self-heal, so this would take the rest of
# the suite down with it.
# Once the limit bites, the shell cannot fork to run `echo` either — so "Cannot fork" IS
# the success signal, and expecting a tidy "forks=N" report back from a shell that has run
# out of processes was never going to work.
forks="$($VT_RUN --rm --pids-limit 64 "${CS193V_TEST_IMAGE:-$TEST_IMAGE_DEFAULT}" sh -c \
    'i=0; while sleep 30 & do i=$((i+1)); [ $i -gt 200 ] && break; done; echo "forks=$i"' 2>&1 | tail -2)"
record "limits:pids-limit-outcome" "$(printf '%s' "$forks" | tr '\n' ' ')"
assert_match "limits:pids-limit-is-enforced" 'Cannot fork|forks=[0-9]+' "$forks"
n="$(printf '%s' "$forks" | sed -n 's/.*forks=\([0-9]*\).*/\1/p')"
case "$forks" in
    *"Cannot fork"*)
        pass "limits:pids-limit-actually-stops-forking" ;;
    *)
        if [ -n "$n" ] && [ "$n" -lt 200 ]; then
            pass "limits:pids-limit-actually-stops-forking"
        else
            fail "limits:pids-limit-actually-stops-forking" \
                 "reached ${n:-200+} forks with --pids-limit 64 — the limit is not being applied"
        fi ;;
esac
# And the real container must NOT be the one that hit the limit: pids exhaustion wedges a
# container beyond `podman exec`'s reach and does not self-heal.
assert_ok "limits:cs193v-itself-is-still-reachable" sh -c "podman exec ${NAME} true"
