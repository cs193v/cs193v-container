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
    podman exec "$NAME" pkill -f cs193v-portprobe >/dev/null 2>&1 || true
    podman exec "$NAME" pkill -f inotifywait      >/dev/null 2>&1 || true
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
fwd_re='^127\.0\.0\.1:(300[0-9]|417[3-6]|517[3-9]|61(7[3-9]|8[0-2])|800[0-9]|808[0-4])$'
nfwd="$(ss -ltn 2>/dev/null | awk '{print $4}' | grep -cE "$fwd_re" || true)"
assert_eq "ports:46-forwards-on-the-host" "46" "${nfwd:-0}"
wild="$(ss -ltn 2>/dev/null | awk '{print $4}' \
        | grep -E ':(300[0-9]|417[3-6]|517[3-9]|61(7[3-9]|8[0-2])|800[0-9]|808[0-4])$' \
        | grep -v '^127\.0\.0\.1:' || true)"
assert_eq "ports:no-forward-is-lan-exposed" "" "$wild"

# One process for all 46 -- the multiplexing that makes a new connection cost a channel rather
# than a 158ms podman exec. If this ever became 46 processes, the design regressed.
nproc_fwd="$(ss -ltnp 2>/dev/null | grep -E '127\.0\.0\.1:(300[0-9])' \
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
for v in claude claude-json gh vercel; do
    assert_contains "mount:volume-cs193v-$v" "$NAME-$v" "$mounts"
done
nvol="$(podman inspect "$NAME" --format '{{json .Mounts}}' \
        | python3 -c 'import json,sys; print(sum(1 for m in json.load(sys.stdin) if m["Type"]=="volume"))')"
assert_eq "mount:exactly-four-volumes" "4" "$nvol"

assert_match "label:confighash-is-set" '.' "$(I '{{index .Config.Labels "cs193v.confighash"}}')"
assert_eq "label:dir-is-this-repo" "$REPO" "$(I '{{index .Config.Labels "cs193v.dir"}}')"
assert_contains "env:CS193V_PORTS-reaches-the-container" "CS193V_PORTS=" "$(I '{{json .Config.Env}}')"
record "pid1" "$(I '{{json .Config.Entrypoint}} {{json .Config.Cmd}}')"

# ─── identity: hostname, banner, goodbye  (#3, #4) ─────────────────────────────
# The hostname is what makes Ubuntu's default prompt read student@cs193v-development.
assert_eq "identity:hostname" "cs193v-development" "$(E 'hostname')"

# The banner needs a pty: it is guarded to interactive shells so that `podman exec <cmd>`
# and this suite's own non-interactive calls do not get a screenful of box drawing.
pty_login() {                     # pty_login KEYS -> everything the session printed
    printf '%b' "$1" | timeout 45 script -q -c "podman exec -it ${NAME} bash -l" /dev/null 2>&1
}

out="$(pty_login 'exit\n')"
n="$(printf '%s' "$out" | grep -ac 'Welcome to the CS193V' || true)"
assert_eq "identity:banner-appears-exactly-once" "1" "$(printf '%s' "$n" | head -1)"
assert_contains "identity:banner-has-the-title" "CS193V Development Environment" "$out"
assert_contains "identity:prompt-shows-the-hostname" "cs193v-development" "$out"
# The clear must come BEFORE the banner, or the banner scrolls away with the old content.
if printf '%s' "$out" | grep -aq $'\033\[3J'; then
    pass "identity:clears-scrollback-on-entry"
else
    fail "identity:clears-scrollback-on-entry" "no [3J in the session output"
fi
assert_contains "identity:goodbye-on-exit" "Goodbye" "$out"

# A nested shell must NOT repeat the banner. /etc/profile.d only runs for login shells, so
# this should hold for free -- but it is the difference between a helpful entry banner and
# noise every time a student or an agent starts a subshell.
out2="$(pty_login 'bash\nexit\nexit\n')"
n2="$(printf '%s' "$out2" | grep -ac 'Welcome to the CS193V' || true)"
assert_eq "identity:nested-shell-does-not-repeat-the-banner" "1" "$(printf '%s' "$n2" | head -1)"

# And a non-interactive exec must be completely silent -- this is how the rest of this
# suite, and any agent, runs commands in the container.
plain="$(E 'echo hi')"
assert_eq "identity:non-interactive-exec-is-silent" "hi" "$plain"
assert_not_contains "identity:non-interactive-has-no-banner" "Welcome to the CS193V" "$plain"
assert_not_contains "identity:non-interactive-has-no-goodbye" "Goodbye" "$plain"

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
          "$(podman exec -it -e TERM=xterm-256color "$NAME" tput colors 2>/dev/null | tr -d '\r')"
record "term:colours-without-forwarding" \
       "$(podman exec -it "$NAME" tput colors 2>/dev/null | tr -d '\r')"

# -e at create time must reach every later exec session, not just the first process.
assert_contains "env:CS193V_PORTS-visible-in-exec" "3000-3009" "$(E 'printenv CS193V_PORTS')"
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
sleep 2
assert_eq "pid1:reaps-orphans" "0" "$(zcount)"

# ─── §A.6 the full port matrix, all 46 ─────────────────────────────────────────
# One process binding every forwarded port, rather than 46 http.servers: faster, and it
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
podman cp "$TMP/portprobe.py" "$NAME":/tmp/cs193v-portprobe.py
# From CS193V_PORTS, which is now the single declaration the launcher also derives its
# forwards from -- there are no -p lines left to read.
SPEC="$(sed 's/#.*//' $REPO/.config/container.args \
        | sed -n 's/.*CS193V_PORTS=\([0-9,-]*\).*/\1/p' | tail -1)"
# Bound to 127.0.0.1, NOT 0.0.0.0. This is the whole point of the change: the container's own
# loopback used to be the one place the forwarder never reached, so testing the wildcard case
# here would pass just as well before the tunnel existed and prove nothing.
podman exec -d "$NAME" python3 /tmp/cs193v-portprobe.py "$SPEC" 127.0.0.1
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
    pass "ports:all-46-forwarded-ports-reach-a-loopback-bound-server"
else
    fail "ports:all-46-forwarded-ports-reach-a-loopback-bound-server" "unreachable:$badports"
fi

# Ports outside the forwarded set must be refused, whatever they are bound to. With the bind
# address no longer mattering, this is the ONLY failure mode left that is invisible from
# inside the container.
podman exec "$NAME" pkill -f cs193v-portprobe >/dev/null 2>&1 || true
sleep 1
podman exec -d "$NAME" python3 /tmp/cs193v-portprobe.py "4000,7000,8500,9100,3100" 0.0.0.0
sleep 2
reachable=""
for p in 4000 7000 8500 9100 3100; do
    c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$p/")"
    [ "$c" = 000 ] || reachable="$reachable $p($c)"
done
if [ -z "$reachable" ]; then
    pass "ports:unforwarded-ports-are-refused"
else
    fail "ports:unforwarded-ports-are-refused" "unexpectedly reachable:$reachable"
fi
podman exec "$NAME" pkill -f cs193v-portprobe >/dev/null 2>&1 || true
sleep 1

# THE assertion this change exists for, and it is deliberately the inverse of what it used to
# be. A 127.0.0.1-bound server inside was unreachable, because podman's forwarder delivers to
# the container's eth0 and never its lo; the tunnel's far end IS that lo, so it must now
# answer. The 46-port loop above already covers this, but it is asserted alone as well so a
# failure here is unambiguous rather than one line in a list of 46.
podman exec -d "$NAME" python3 /tmp/cs193v-portprobe.py "3000" 127.0.0.1
sleep 2
c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:3000/)"
if [ "$c" = 200 ]; then
    pass "ports:loopback-bound-server-IS-reachable"
else
    fail "ports:loopback-bound-server-IS-reachable" \
         "got HTTP $c — the ssh tunnel is not reaching the container's own loopback on this
platform, which is the entire premise of the current design. Check: cs193v doctor"
fi
podman exec "$NAME" pkill -f cs193v-portprobe >/dev/null 2>&1 || true
sleep 1

# ::1 alone is the one bind address still out of reach, since the forward's far end is IPv4.
# Recorded rather than asserted as a pass/fail of the design: if a future ssh reaches it, that
# is an improvement, and the docs are then what is wrong.
podman exec -d "$NAME" python3 -c 'import socket
s=socket.socket(socket.AF_INET6); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("::1",3001)); s.listen(4)
while True:
    c,_=s.accept(); c.recv(4096)
    c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"); c.close()' \
    >/dev/null 2>&1
sleep 2
c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:3001/)"
record "ports:ipv6-only-server-http" "$c"
if [ "$c" = 000 ]; then
    pass "ports:ipv6-only-is-refused-as-documented"
else
    fail "ports:ipv6-only-is-refused-as-documented" \
         "got HTTP $c — ::1-only IS reachable, which is better than documented. Update
CONTAINER-DESIGN.md, files/ports and ERRORS.md D4 rather than leaving them pessimistic."
fi
podman exec "$NAME" pkill -f 'AF_INET6' >/dev/null 2>&1 || true
sleep 1

# The host side must be loopback-only in reality, not just in the flag.
podman exec -d "$NAME" python3 /tmp/cs193v-portprobe.py "3000" 0.0.0.0
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

# The in-container `ports` command must diagnose what is LEFT to diagnose, against real
# sockets. Kill the 0.0.0.0 probe from the LAN check first, or 3000 is still wildcard-bound.
podman exec "$NAME" pkill -f cs193v-portprobe >/dev/null 2>&1 || true
sleep 2
podman exec -d "$NAME" python3 /tmp/cs193v-portprobe.py "3000" 127.0.0.1   # forwarded, loopback
podman exec -d "$NAME" python3 /tmp/cs193v-portprobe.py "5174" 0.0.0.0     # forwarded, wildcard
podman exec -d "$NAME" python3 /tmp/cs193v-portprobe.py "4000" 0.0.0.0     # not forwarded
sleep 3
pout="$(E 'ports || true')"
record "ports:diagnostic-output" "$(printf '%s' "$pout" | tr '\n' '|')"
assert_match "ports:diagnoses-forwarded-wildcard-as-OK" '5174 .*OK'            "$pout"
assert_match "ports:diagnoses-unforwarded"              '4000 .*NOT FORWARDED' "$pout"
# The one that had to change: loopback is now OK, and the old UNREACHABLE verdict here would
# be a lie that sends a student to fix something that is not broken.
assert_match "ports:diagnoses-forwarded-loopback-as-OK" '3000 .*OK'            "$pout"
assert_not_contains "ports:no-longer-demands-bind-all" "--host 0.0.0.0"        "$pout"
# And it must be honest about the half it cannot see: a missing forward or a downed tunnel are
# host-side facts that /proc/net/tcp does not contain.
assert_contains "ports:points-at-doctor-for-host-side-faults" "cs193v doctor"  "$pout"
podman exec "$NAME" pkill -f cs193v-portprobe >/dev/null 2>&1 || true

# ─── §A.7 files, ownership and watching ────────────────────────────────────────
# The ownership round trip is what makes the bind mount usable at all: a file the container
# writes must be owned by the student on the host, and vice versa.
E 'umask 022; echo hi > /home/student/projects/.vt-c'
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
    podman exec -d "$NAME" sh -c 'inotifywait -q -e modify /home/student/projects/.vt-c > /tmp/vt-in 2>&1'
    sleep 1; E 'echo x >> /home/student/projects/.vt-c'; sleep 2
    if E 'test -s /tmp/vt-in' >/dev/null 2>&1; then pass "files:inotify-fires-for-container-side-edits"
    else fail "files:inotify-fires-for-container-side-edits" \
              "no event — hot reload will not work even for edits made inside the container"; fi

    # Host-side edits are expected NOT to fire on macOS and WSL. Recorded, because it
    # decides what CONTAINER-DESIGN.md's "known rough edges" must say.
    E 'rm -f /tmp/vt-in'
    podman exec -d "$NAME" sh -c 'inotifywait -q -e modify /home/student/projects/.vt-c > /tmp/vt-in 2>&1'
    sleep 1; echo y >> "$REPO/projects/.vt-c"; sleep 3
    if E 'test -s /tmp/vt-in' >/dev/null 2>&1; then
        record "files:inotify-for-host-side-edits" "FIRES"
    else
        record "files:inotify-for-host-side-edits" "DOES NOT FIRE"
    fi
    podman exec "$NAME" pkill -f inotifywait >/dev/null 2>&1 || true
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
forks="$(podman run --rm --pids-limit 64 "${CS193V_TEST_IMAGE:-$TEST_IMAGE_DEFAULT}" sh -c \
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
