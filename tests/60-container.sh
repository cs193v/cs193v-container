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
#     launcher forwards TERM in open_shell/verb_ports, so the probe has to as well.
#   * §A.4's note that .Config.Env should hold TERM and COLORTERM is impossible: those are
#     passed per-exec, never at create time.
#
# Genuinely platform-dependent values are RECORDED, not asserted. Pinning an expectation to
# one kernel's answer would make the suite fail on a Mac for no good reason, and several of
# these exist specifically to find out what a platform does.

set -u
. "$(dirname -- "$0")/lib/assert.sh"

require_running
cd "$REPO" || exit 1

TMP="$(new_tmpdir)"
cleanup() {
    # Never leave stray servers or scratch files behind in the student's projects/.
    podman exec cs193v pkill -f cs193v-portprobe >/dev/null 2>&1 || true
    podman exec cs193v pkill -f inotifywait      >/dev/null 2>&1 || true
    rm -rf "$TMP" "$REPO"/projects/.vt-* 2>/dev/null || true
}
trap cleanup EXIT

# ─── §A.4 the flags the container was actually created with ────────────────────
assert_eq "flag:network-is-pasta" "pasta" "$(I '{{.HostConfig.NetworkMode}}')"

MEM="$(I '{{.HostConfig.Memory}}')"
SWAP="$(I '{{.HostConfig.MemorySwap}}')"
record "flag:memory"      "$MEM"
record "flag:memory-swap" "$SWAP"
# local.args holds the cap the installer computed for this machine; the container must
# actually have it, or the protection is decorative.
if [ -f "$REPO/local.args" ]; then
    want_mb="$(sed -n 's/^--memory=\([0-9]*\)m/\1/p' "$REPO/local.args" | head -1)"
    if [ -n "$want_mb" ]; then
        assert_eq "flag:memory-matches-local.args" "$((want_mb * 1048576))" "$MEM"
    else
        record "flag:memory-matches-local.args" "local.args sets no cap on this machine"
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

# Every published port must bind loopback only. An unprefixed -p binds 0.0.0.0 inside the
# distro, exposes the student's dev server to dorm wifi, and triggers the Windows Defender
# prompt (declined by default on Public networks).
hostips="$(podman inspect cs193v --format '{{json .HostConfig.PortBindings}}' \
           | python3 -c 'import json,sys
d=json.load(sys.stdin)
print(" ".join(sorted({b["HostIp"] for v in d.values() for b in v})))')"
assert_eq "ports:host-side-is-loopback-only" "127.0.0.1" "$hostips"
assert_eq "ports:46-mappings" "46" "$(podman port cs193v | wc -l | tr -d ' ')"

mounts="$(I '{{json .Mounts}}')"
assert_contains "mount:workspace-bind-points-at-projects" "$REPO/projects" "$mounts"
for v in cs193v-claude cs193v-claude-json cs193v-gh cs193v-vercel; do
    assert_contains "mount:volume-$v" "$v" "$mounts"
done
nvol="$(podman inspect cs193v --format '{{json .Mounts}}' \
        | python3 -c 'import json,sys; print(sum(1 for m in json.load(sys.stdin) if m["Type"]=="volume"))')"
assert_eq "mount:exactly-four-volumes" "4" "$nvol"

assert_match "label:confighash-is-set" '.' "$(I '{{index .Config.Labels "cs193v.confighash"}}')"
assert_eq "label:dir-is-this-repo" "$REPO" "$(I '{{index .Config.Labels "cs193v.dir"}}')"
assert_contains "env:CS193V_PORTS-reaches-the-container" "CS193V_PORTS=" "$(I '{{json .Config.Env}}')"
record "pid1" "$(I '{{json .Config.Entrypoint}} {{json .Config.Cmd}}')"

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
# /proc is NOT cgroup-aware, which is the whole reason CS193V_MEMORY_MB is passed in: a
# student running `free` inside the container sees the host's RAM, not their cap.
record "kernel:free-vs-cgroup" \
       "$(E 'echo "free=$(free -m | awk "/^Mem:/{print \$2}")MB cgroup=$(($(cat /sys/fs/cgroup/memory.max)/1048576))MB"')"

# The corrected colour check. podman forces TERM=xterm and does not copy the client's value
# (containers/podman#25683), so the launcher forwards it explicitly — and so must this.
assert_eq "term:256-colours-with-forwarded-TERM" "256" \
          "$(podman exec -it -e TERM=xterm-256color cs193v tput colors 2>/dev/null | tr -d '\r')"
record "term:colours-without-forwarding" \
       "$(podman exec -it cs193v tput colors 2>/dev/null | tr -d '\r')"

# -e at create time must reach every later exec session, not just the first process.
assert_contains "env:CS193V_PORTS-visible-in-exec" "3000-3009" "$(E 'printenv CS193V_PORTS')"
assert_ok "net:dns-resolves" sh -c "podman exec cs193v getent hosts registry.npmjs.org"
assert_ok "net:https-egress-works" sh -c "podman exec cs193v curl -fsS -o /dev/null --max-time 20 https://registry.npmjs.org/"

# PID 1 must be the reaping keep-alive loop, not `sleep infinity` — sleep never calls
# wait(), so every orphan becomes a permanent zombie holding a pid slot against pids.max.
record "pid1:cmdline" "$(E 'cat /proc/1/cmdline | tr "\0" " "')"
assert_not_contains "pid1:is-not-bare-sleep" "sleep infinity" "$(E 'cat /proc/1/cmdline | tr "\0" " "')"
assert_eq "pid1:no-zombies-right-now" "0" "$(E 'ps -eo stat --no-headers | grep -c Z || true')"

# The reaping claim, tested rather than assumed: orphan a process and check PID 1 collects
# it instead of leaving a zombie.
E 'setsid sh -c "sleep 0.2 & exit" >/dev/null 2>&1' >/dev/null 2>&1
sleep 2
assert_eq "pid1:reaps-orphans" "0" "$(E 'ps -eo stat --no-headers | grep -c Z || true')"

# ─── §A.6 the full port matrix, all 46 ─────────────────────────────────────────
# One process binding every published port, rather than 46 http.servers: faster, and it
# cannot half-start.
cat > "$TMP/portprobe.py" <<'PY'
import socket, selectors, sys
# argv[1] is a comma list of ranges; bind every port in them on 0.0.0.0.
ports = []
for chunk in sys.argv[1].split(","):
    if "-" in chunk:
        a, b = chunk.split("-"); ports += list(range(int(a), int(b) + 1))
    else:
        ports.append(int(chunk))
sel = selectors.DefaultSelector()
bound = []
for p in ports:
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind((sys.argv[2], p)); s.listen(16); s.setblocking(False)
        sel.register(s, selectors.EVENT_READ); bound.append(p)
    except OSError:
        pass
print("bound %d" % len(bound), flush=True)
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
podman cp "$TMP/portprobe.py" cs193v:/tmp/cs193v-portprobe.py
SPEC="$(sed 's/#.*//' container.args | sed -n 's/.*-p 127\.0\.0\.1:\([0-9]*-[0-9]*\):.*/\1/p' | paste -sd, -)"
podman exec -d cs193v python3 /tmp/cs193v-portprobe.py "$SPEC" 0.0.0.0
sleep 3

ALL="$(printf '%s' "$SPEC" | tr ',' ' ' | tr '-' ' ' \
       | python3 -c 'import sys
xs=sys.stdin.read().split()
print(" ".join(str(p) for a,b in zip(xs[0::2],xs[1::2]) for p in range(int(a),int(b)+1)))')"
nports="$(printf '%s\n' $ALL | wc -l | tr -d ' ')"
assert_eq "ports:probe-covers-46-ports" "46" "$nports"

badports=""
for p in $ALL; do
    c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$p/")"
    [ "$c" = 200 ] || badports="$badports $p($c)"
done
if [ -z "$badports" ]; then
    pass "ports:all-46-published-ports-reach-the-container"
else
    fail "ports:all-46-published-ports-reach-the-container" "unreachable:$badports"
fi

# Ports outside the published set must be refused, whatever they are bound to. This is the
# second of the two invisible-from-inside failure modes.
podman exec cs193v pkill -f cs193v-portprobe >/dev/null 2>&1 || true
sleep 1
podman exec -d cs193v python3 /tmp/cs193v-portprobe.py "4000,7000,8500,9100,3100" 0.0.0.0
sleep 2
reachable=""
for p in 4000 7000 8500 9100 3100; do
    c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$p/")"
    [ "$c" = 000 ] || reachable="$reachable $p($c)"
done
if [ -z "$reachable" ]; then
    pass "ports:unpublished-ports-are-refused"
else
    fail "ports:unpublished-ports-are-refused" "unexpectedly reachable:$reachable"
fi
podman exec cs193v pkill -f cs193v-portprobe >/dev/null 2>&1 || true
sleep 1

# THE lesson the course teaches: a loopback-bound server inside is unreachable from the
# host, because podman's forwarder delivers to the container's eth0, never its lo — while
# the server's log still prints "Local: http://localhost:5173/".
podman exec -d cs193v python3 /tmp/cs193v-portprobe.py "3000" 127.0.0.1
sleep 2
c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:3000/)"
if [ "$c" = 000 ]; then
    pass "ports:loopback-bound-server-is-unreachable"
else
    fail "ports:loopback-bound-server-is-unreachable" \
         "got HTTP $c — a 127.0.0.1-bound server IS reachable on this platform, so the
course's central ports lesson and CONTAINER-DESIGN.md's diagram are wrong here"
fi
podman exec cs193v pkill -f cs193v-portprobe >/dev/null 2>&1 || true
sleep 1

# The host side must be loopback-only in reality, not just in the flag.
podman exec -d cs193v python3 /tmp/cs193v-portprobe.py "3000" 0.0.0.0
sleep 2
listen="$( (ss -ltn 2>/dev/null || netstat -an) | grep ':3000' || true)"
record "ports:host-listen-line" "$listen"
assert_not_match "ports:host-does-not-listen-on-0.0.0.0" '0\.0\.0\.0:3000|\*:3000|\[::\]:3000' "$listen"

LANIP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [ -n "$LANIP" ] && [ "$LANIP" != "127.0.0.1" ]; then
    c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$LANIP:3000/")"
    if [ "$c" = 000 ]; then pass "ports:not-reachable-from-the-LAN"
    else fail "ports:not-reachable-from-the-LAN" \
              "reachable on $LANIP (HTTP $c) — student dev servers are exposed to the network"; fi
else
    record "ports:not-reachable-from-the-LAN" "no non-loopback address on this host"
fi

# The in-container `ports` command must diagnose each state correctly against real sockets.
# Kill the 0.0.0.0 probe from the LAN check first, or 3000 is still wildcard-bound and the
# loopback diagnosis has nothing to diagnose.
podman exec cs193v pkill -f cs193v-portprobe >/dev/null 2>&1 || true
sleep 2
podman exec -d cs193v python3 /tmp/cs193v-portprobe.py "3000" 127.0.0.1   # published, loopback
podman exec -d cs193v python3 /tmp/cs193v-portprobe.py "5174" 0.0.0.0     # published, wildcard
podman exec -d cs193v python3 /tmp/cs193v-portprobe.py "4000" 0.0.0.0     # unpublished
sleep 3
pout="$(E 'ports || true')"
record "ports:diagnostic-output" "$(printf '%s' "$pout" | tr '\n' '|')"
assert_match "ports:diagnoses-published-wildcard-as-OK"  '5174 .*OK'            "$pout"
assert_match "ports:diagnoses-unpublished"               '4000 .*NOT PUBLISHED' "$pout"
assert_match "ports:diagnoses-loopback-as-unreachable"   '3000 .*UNREACHABLE'   "$pout"
assert_contains "ports:explains-why-0.0.0.0" "separate machine" "$pout"
podman exec cs193v pkill -f cs193v-portprobe >/dev/null 2>&1 || true

# ─── §A.7 files, ownership and watching ────────────────────────────────────────
# The ownership round trip is what makes the bind mount usable at all: a file the container
# writes must be owned by the student on the host, and vice versa.
E 'umask 022; echo hi > /home/student/projects/.vt-c'
assert_eq "files:container-write-is-host-owned" "$(id -u) $(id -g) 644" \
          "$(stat -c '%u %g %a' "$REPO/projects/.vt-c")"
assert_eq "files:container-write-readable-on-host" "hi" "$(cat "$REPO/projects/.vt-c")"

echo "from-host" > "$REPO/projects/.vt-h"
assert_ok "files:container-can-write-a-host-created-file" \
          sh -c "podman exec cs193v sh -c 'echo more >> /home/student/projects/.vt-h'"
assert_eq "files:container-sees-host-content" "from-host" "$(E 'head -1 /home/student/projects/.vt-h')"
assert_eq "files:host-sees-container-append" "more" "$(tail -1 "$REPO/projects/.vt-h")"

E 'chmod 600 /home/student/projects/.vt-c'
assert_eq "files:mode-changes-propagate" "600" "$(stat -c %a "$REPO/projects/.vt-c")"

E 'ln -s /etc/hostname /home/student/projects/.vt-link'
record "files:symlink-target-as-seen-from-host" "$(readlink "$REPO/projects/.vt-link")"

# Case sensitivity determines whether a Mac student's `import './Button'` bug reproduces
# here. Recorded, because the answer differs per platform and the docs must match it.
record "files:case-sensitivity" \
       "$(E 'cd /home/student/projects && touch .vt-Aa && (ls .vt-aA >/dev/null 2>&1 && echo CASE-INSENSITIVE || echo case-sensitive)')"

# inotify from INSIDE is the case that matters: in this course the writer is always inside
# the container, so this is what a dev server's hot reload depends on.
if E 'command -v inotifywait' >/dev/null 2>&1; then
    E 'rm -f /tmp/vt-in'
    podman exec -d cs193v sh -c 'inotifywait -q -e modify /home/student/projects/.vt-c > /tmp/vt-in 2>&1'
    sleep 1; E 'echo x >> /home/student/projects/.vt-c'; sleep 2
    if E 'test -s /tmp/vt-in' >/dev/null 2>&1; then pass "files:inotify-fires-for-container-side-edits"
    else fail "files:inotify-fires-for-container-side-edits" \
              "no event — hot reload will not work even for edits made inside the container"; fi

    # Host-side edits are expected NOT to fire on macOS and WSL. Recorded, because it
    # decides what CONTAINER-DESIGN.md's "known rough edges" must say.
    E 'rm -f /tmp/vt-in'
    podman exec -d cs193v sh -c 'inotifywait -q -e modify /home/student/projects/.vt-c > /tmp/vt-in 2>&1'
    sleep 1; echo y >> "$REPO/projects/.vt-c"; sleep 3
    if E 'test -s /tmp/vt-in' >/dev/null 2>&1; then
        record "files:inotify-for-host-side-edits" "FIRES"
    else
        record "files:inotify-for-host-side-edits" "DOES NOT FIRE"
    fi
    podman exec cs193v pkill -f inotifywait >/dev/null 2>&1 || true
else
    record "files:inotify" "inotify-tools not installed in the container; run: sudo apt-get install -y inotify-tools"
fi

# Quantify the bind-mount penalty. Recorded per platform — this is the number that decides
# whether `npm install` is tolerable on a Mac.
T0="$(date +%s)"
E 'mkdir -p /home/student/projects/.vt-many && cd /home/student/projects/.vt-many && for i in $(seq 1 2000); do : > f$i; done'
T1="$(date +%s)"
record "files:create-2000-files-on-the-bind-mount-seconds" "$((T1 - T0))"
T0="$(date +%s)"
E 'rm -rf /home/student/projects/.vt-many'
T1="$(date +%s)"
record "files:delete-2000-files-seconds" "$((T1 - T0))"

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
    assert_ok "limits:launcher-can-still-get-in-after-an-oom" sh -c "podman exec cs193v true"
else
    skip "limits:allocation-loop-is-stopped" \
         "no memory cap in force (cgroup memory.max=$cg_mem) — running an unbounded
allocation loop would exhaust the HOST, not the container"
    skip "limits:container-survives-an-oom" "no memory cap in force"
    skip "limits:launcher-can-still-get-in-after-an-oom" "no memory cap in force"
fi

# The pids limit, on a DISPOSABLE container. NEVER fork-bomb cs193v: pids exhaustion wedges
# it beyond `podman exec`'s reach and does not self-heal, so this would take the rest of
# the suite down with it.
# Once the limit bites, the shell cannot fork to run `echo` either — so "Cannot fork" IS
# the success signal, and expecting a tidy "forks=N" report back from a shell that has run
# out of processes was never going to work.
forks="$(podman run --rm --pids-limit 64 "${CS193V_TEST_IMAGE:-localhost/cs193v:dev}" sh -c \
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
assert_ok "limits:cs193v-itself-is-still-reachable" sh -c "podman exec cs193v true"
