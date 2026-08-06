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
# Destructive: --full-rebuild deletes the four volumes, which is where claude/gh/vercel
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
    shim_cleanup
}
trap restore EXIT INT TERM

# L() drives the VERBS, which never open a shell and so work fine with a redirected stdin —
# they are exactly what the refusal message tells scripts to use. Timeout-wrapped so a
# regression fails the suite instead of wedging it.
L() { printf 'exit\n' | timeout 90 ./cs193v "$@" 2>&1; }
L_rc() { printf 'exit\n' | timeout 90 ./cs193v "$@" >/dev/null 2>&1; printf '%s' "$?"; }

# LB() is a BARE launch — one that goes on to open a shell. It needs a real terminal, since
# open_shell refuses without one, so it goes through script(1) with an `exit` fed in.
LB() { launcher_tty_repo 'exit\n' "$@"; }

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
# The container was still created, which is what the message promises.
assert_eq "noterm:container-is-up-anyway" "running" \
          "$(podman inspect "$NAME" --format '{{.State.Status}}' 2>&1)"
podman rm -f "$NAME" >/dev/null 2>&1 || true

# With a real terminal the same invocation opens a shell and returns promptly.
T0="$(date +%s)"
out="$(LB)"
T1="$(date +%s)"
if [ "$((T1 - T0))" -lt 60 ]; then pass "live:pty-launch-opens-a-shell-and-returns"
else fail "live:pty-launch-opens-a-shell-and-returns" "took $((T1 - T0))s"; fi
record "perf:first-launch-seconds" "$((T1 - T0))"
assert_eq "live:container-is-running-after-first-launch" "running" \
          "$(podman inspect "$NAME" --format '{{.State.Status}}' 2>&1)"
assert_eq "live:exactly-one-container" "1" "$(podman ps -q | wc -l | tr -d ' ')"

# The mount really is the student's projects/ directory, on both sides.
assert_eq "live:workspace-is-the-sibling-projects-dir" "$REPO/projects" \
    "$(podman inspect "$NAME" \
       --format '{{range .Mounts}}{{if eq .Destination "/home/student/projects"}}{{.Source}}{{end}}{{end}}')"

# keep-id in practice: a file the container creates is owned by the student on the host.
podman exec "$NAME" sh -c 'echo live > /home/student/projects/.vt-live'
assert_eq "live:keep-id-maps-the-host-user" "$(id -u)" "$(stat -c %u "$REPO/projects/.vt-live")"
rm -f "$REPO/projects/.vt-live"

# ─── idempotency and concurrency  (§2.2, §A.10) ────────────────────────────────
before="$(podman inspect "$NAME" --format '{{.Id}}')"
i=0
while [ "$i" -lt 20 ]; do LB >/dev/null 2>&1; i=$((i + 1)); done
assert_eq "live:20-launches-still-one-container" "1" "$(podman ps -q | wc -l | tr -d ' ')"
assert_eq "live:20-launches-do-not-recreate" "$before" "$(podman inspect "$NAME" --format '{{.Id}}')"

# Four shells at once is legitimate and common — one per terminal window.
for i in 1 2 3 4; do ( LB >/dev/null 2>&1 & ) ; done
sleep 6
assert_eq "live:concurrent-launches-still-one-container" "1" "$(podman ps -q | wc -l | tr -d ' ')"
assert_eq "live:concurrent-launches-do-not-recreate" "$before" \
          "$(podman inspect "$NAME" --format '{{.Id}}')"
record "live:exec-sessions-after-four-shells" "$(podman top "$NAME" 2>/dev/null | wc -l | tr -d ' ')"

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

# Accepting it must actually recreate with the flag.
out="$(launcher_tty_repo '\033[B\nexit\n')"
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
L --rebuild >/dev/null 2>&1
# The container publishes nothing; the 46 forwards live on the host, in one ssh process. A
# rebuild has to tear the old tunnel down and bring a new one up, and getting that wrong is
# how a routine --rebuild becomes a total outage: a tunnel outliving its container keeps every
# host port bound against a dead pipe, so the replacement can bind none of them.
assert_eq "drift:restored-config-publishes-nothing" "0" "$(podman port "$NAME" | wc -l | tr -d ' ')"
fwd_re='^127\.0\.0\.1:(300[0-9]|417[3-6]|517[3-9]|61(7[3-9]|8[0-2])|800[0-9]|808[0-4])$'
nfwd="$(ss -ltn 2>/dev/null | awk '{print $4}' | grep -cE "$fwd_re" || true)"
assert_eq "drift:tunnel-is-rebuilt-with-46-forwards" "46" "${nfwd:-0}"
assert_match "drift:doctor-reports-the-tunnel-up" 'tunnel +up' "$(L doctor)"

# ─── two copies of the course directory  (§2.7) ────────────────────────────────
rm -rf /tmp/vt-copy
cp -a "$REPO" /tmp/vt-copy
rm -rf /tmp/vt-copy/tests
assert_eq "live:second-copy-is-refused" "1" \
          "$(/tmp/vt-copy/cs193v >/dev/null 2>&1 </dev/null; printf '%s' "$?")"
assert_says "live:second-copy-explains-both-paths" "different folder" \
            "$(/tmp/vt-copy/cs193v </dev/null 2>&1)"
assert_eq "live:second-copy-created-nothing" "1" "$(podman ps -q | wc -l | tr -d ' ')"
rm -rf /tmp/vt-copy

# ─── --rebuild preserves logins  (§2.3) ────────────────────────────────────────
# A marker inside the ~/.claude volume stands in for a real login, so this can be checked
# without one.
podman exec "$NAME" sh -c 'echo marker > /home/student/.claude/.vt-marker'
podman exec "$NAME" sh -c 'echo marker > /home/student/.config/gh/.vt-marker'
L --rebuild >/dev/null 2>&1
assert_eq "rebuild:claude-volume-survives" "marker" \
          "$(podman exec "$NAME" cat /home/student/.claude/.vt-marker 2>&1)"
assert_eq "rebuild:gh-volume-survives" "marker" \
          "$(podman exec "$NAME" cat /home/student/.config/gh/.vt-marker 2>&1)"
# ...and things installed IN the container do not, which is the point of --rebuild.
podman exec "$NAME" sh -c 'echo x > /tmp/.vt-ephemeral'
L --rebuild >/dev/null 2>&1
assert_fail "rebuild:container-filesystem-is-reset" \
            sh -c "podman exec ${NAME} test -f /tmp/.vt-ephemeral"
# projects/ is on the host, so it is untouched by construction — assert it anyway.
echo keep > "$REPO/projects/.vt-keep"
L --rebuild >/dev/null 2>&1
assert_eq "rebuild:projects-untouched" "keep" "$(cat "$REPO/projects/.vt-keep")"
rm -f "$REPO/projects/.vt-keep"

# The policy files live in /etc, in the image layer, precisely so a rebuild restores them —
# unlike anything under ~/.claude, which is a volume seeded once and never refreshed.
assert_ok "rebuild:claude-policy-survives" \
          sh -c "podman exec ${NAME} test -f /etc/claude-code/CLAUDE.md -a -f /etc/claude-code/managed-settings.json"

# ─── --full-rebuild  (§2.4, §9.2) — destructive, opt-in ────────────────────────
if [ "${CS193V_DESTRUCTIVE:-0}" = 1 ]; then
    podman exec "$NAME" sh -c 'echo marker > /home/student/.claude/.vt-marker' 2>/dev/null || true
    printf '%b' '\033[B\n' | script -q -c "./cs193v --full-rebuild" /dev/null >/dev/null 2>&1
    assert_fail "full-rebuild:volume-contents-are-gone" \
                sh -c "podman exec ${NAME} test -f /home/student/.claude/.vt-marker"
    assert_eq "full-rebuild:container-is-running-again" "running" \
              "$(podman inspect "$NAME" --format '{{.State.Status}}' 2>&1)"
else
    skip "full-rebuild:volume-contents-are-gone" \
         "destructive — it deletes the claude/gh/vercel login volumes. Re-run with CS193V_DESTRUCTIVE=1"
    skip "full-rebuild:container-is-running-again" "see above"
fi
# Whether or not it ran, --full-rebuild must refuse to proceed without an explicit yes.
out="$(L --full-rebuild)"
assert_says "full-rebuild:non-tty-changes-nothing" "Nothing was changed" "$out"

# ─── --update  (§9.1) ──────────────────────────────────────────────────────────
img="$(sed 's/#.*//' $REPO/.config/container.args | sed -n 's/^IMAGE=\(.*\)/\1/p' | tr -d ' ' | head -1)"
if [ -n "$img" ]; then
    assert_ok "update:pulls-and-recreates" sh -c "./cs193v --update </dev/null"
else
    # Not a failure: IMAGE= is empty until the course image is published, which is tracked
    # as a release gate. There is nothing to update to.
    skip "update:pulls-and-recreates" "IMAGE= is empty (dev mode); see $PRIVATE/tests/00-release-gates.sh"
    assert_says "update:refuses-in-dev-mode" "no published image" "$(L --update)"
fi

# ─── doctor against a real container ───────────────────────────────────────────
out="$(L doctor)"
assert_contains "doctor:reports-the-real-podman-version" "5." "$out"
# KNOWN BUG, documented as ERRORS.md B14: verb_doctor calls load_args but never
# resolve_image, so in dev mode (empty IMAGE=) it hashes IMAGE="" while every other path
# hashes the resolved dev image — and doctor therefore always reports "config STALE" and
# tells you to accept a recreate prompt that will never appear. Left failing on purpose:
# doctor is the report staff ask for first, so it must not lie.
if printf '%s' "$out" | grep -q 'matches container.args'; then
    pass "doctor:reports-config-matches"
else
    fail "doctor:reports-config-matches" \
         "doctor says the config is STALE while the launch path agrees it matches (0 recreate
prompts) and the stored hash equals --dev-print-command's. One-line fix in verb_doctor:
  load_args
+ [ -z \"\$IMAGE\" ] && IMAGE=\"\$DEV_IMAGE\"
See ERRORS.md B14."
fi
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
assert_contains "ports-verb:runs-the-in-container-tool" "forwarded:" "$(L ports)"

# ─── the tunnel's own lifecycle ────────────────────────────────────────────────
# Each of these is a way the tunnel can strand a student with a container that looks perfectly
# healthy and a browser that cannot reach anything.
fwd_re='^127\.0\.0\.1:(300[0-9]|417[3-6]|517[3-9]|61(7[3-9]|8[0-2])|800[0-9]|808[0-4])$'
count_fwd() { ss -ltn 2>/dev/null | awk '{print $4}' | grep -cE "$fwd_re" || true; }

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
CTL="$(tunnel_ctl)"
record "tunnel:control-socket" "${CTL:-<none>}"

# THE test: a server bound to the container's OWN loopback, which was unreachable by design
# before this change, must answer from the host.
podman exec -d "$NAME" python3 -m http.server 3000 --bind 127.0.0.1 >/dev/null 2>&1
sleep 2
assert_eq "tunnel:loopback-bound-server-is-reachable" "200" \
          "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:3000/)"
podman exec "$NAME" pkill -f http.server >/dev/null 2>&1 || true

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
L --rebuild >/dev/null 2>&1
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
# Same scoping. The four are asserted by exact name so a MISSING one still fails, and the
# instance suffix comes from $NAME so the expectation tracks whichever instance is running.
mine="$(podman volume ls --format '{{.Name}}' \
        | grep -xE "$NAME-(claude|claude-json|gh|vercel)" | LC_ALL=C sort | tr '\n' ' ')"
assert_eq "cleanup:exactly-the-four-cs193v-volumes" \
          "$NAME-claude $NAME-claude-json $NAME-gh $NAME-vercel" \
          "$(printf '%s' "$mine" | sed 's/ *$//')"
stray_vols="$(podman volume ls --format '{{.Name}}' | grep -vE '^cs193v($|-)' \
              | LC_ALL=C sort | tr '\n' ' ')"
assert_eq "cleanup:no-stray-volumes" "" "$(printf '%s' "$stray_vols" | sed 's/ *$//')"

# ─── §A.13 performance baselines — recorded, never asserted ────────────────────
T0="$(date +%s%N)"; L --dev-print-command >/dev/null 2>&1; T1="$(date +%s%N)"
record "perf:launcher-overhead-ms" "$(( (T1 - T0) / 1000000 ))"
T0="$(date +%s%N)"; podman exec "$NAME" true; T1="$(date +%s%N)"
record "perf:podman-exec-overhead-ms" "$(( (T1 - T0) / 1000000 ))"
T0="$(date +%s)"; L --rebuild >/dev/null 2>&1; T1="$(date +%s)"
record "perf:rebuild-seconds" "$((T1 - T0))"
T0="$(date +%s)"; L >/dev/null 2>&1; T1="$(date +%s)"
record "perf:subsequent-launch-seconds" "$((T1 - T0))"
