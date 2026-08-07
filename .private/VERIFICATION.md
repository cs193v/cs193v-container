# CS193V container — verification

Run this on each target platform before the quarter starts. **Podman was never executed during the
design research** (it isn't installed in the authoring environment), so every runtime claim below is
source-derived and unproven. These are release gates, not a formality.

## How to use this

You are likely a Claude Code instance running on a machine that is *not* the instructor's. Work through
the sections in order — **§A first**, since it needs no human. For each check, run the command, compare
against **Expect**, and record `PASS` / `FAIL` / `N/A` with the actual output. Do not skip a check
because it "should" pass — several exist precisely because the expected behaviour is disputed.

Report at the end using the template in §10. Flag anything surprising even if it technically passed.

First, record the environment:

```sh
uname -srm
sw_vers 2>/dev/null || head -3 /etc/os-release
podman --version
podman info --format '{{.Host.OS}}/{{.Host.Arch}} rootless={{.Host.Security.Rootless}}'
podman info --format 'mem={{.Host.MemTotal}} cpus={{.Host.CPUs}} netcmd={{.Host.RootlessNetworkCmd}}'
podman machine list 2>/dev/null || echo "no podman machine (native Linux or WSL)"
```

---

# §A. Automated battery — run this FIRST

**§A is now a real test suite.** Everything below has been implemented in `tests/`, so run that
instead of pasting shell by hand:

```sh
.private/tests/run-tests.sh                  # every automatable check, all tiers
.private/tests/run-tests.sh --tier static    # no podman, no image needed — milliseconds
.private/tests/run-tests.sh --release        # the publishing blanks (expected to fail until filled)
.private/tests/run-tests.sh --list           # what exists, and in which tier
```

Then work through `.private/tests/MANUAL.md`, which is what is genuinely left for a human or another
platform, and `ERRORS.md`, which records what the first pass found.

The prose below is kept because the *reasoning* for each check is worth having. But **ten of the
checks as originally written did not work**, and several would have produced a misleading report in
both directions. Corrected here and in the suite; see ERRORS.md B1 for the full list. The ones that
mattered most:

| Where | Was | Is |
| --- | --- | --- |
| §A.1 | `grep -qx 'projects/*'` — `*` is a BRE quantifier, so it never matched the literal line | needs `-F` |
| §A.1 | `comm -3` aborts with "file 1 is not in sorted order" under `en_US.UTF-8` | needs `LC_ALL=C` |
| §A.3 | `nvm-not-group-writable` printed `ok` while asserting nothing — the path does not exist by design | assert its absence |
| §A.4 | expected `TERM`/`COLORTERM` in `.Config.Env` | impossible; they are per-`exec` |
| §A.5 | `tput colors` with no `-e TERM` reported 8 — it **failed on a working system** | forward `TERM` as the launcher does |
| §A.5 | `findmnt -no FSTYPE /tmp` returns **empty** — /tmp is not a mountpoint | `stat -f -c %T /tmp` |
| §A.10 | the verb loop **hangs** on the empty verb, and `</dev/null` does not fix it — a pty never delivers EOF | feed it `exit` |
| §A.12 | installer idempotency was **vacuous** — the consent menu declines with no tty and exits 0 first | drive it with a local tarball |
| §1.2 | expected a numbered-selection fallback with no tty | there is none; it picks the safe default, which is better |
| §7.3 | says to run `man ls`, while §A.3 asserts `man` is absent | use `git diff`/`git log` |

Everything in this section is machine-checkable with no human in the loop. Run it before §1–9, which
need a person (a browser, a laptop lid, a terminal window). Most defects will surface here, cheaply.

A harness so the report writes itself:

```sh
PASS=0; FAIL=0
ck() {   # ck <name> <expected> <command...>   — exact string match
  local n="$1" want="$2"; shift 2; local got; got="$("$@" 2>&1)"
  if [ "$got" = "$want" ]; then PASS=$((PASS+1)); printf 'PASS  %s\n' "$n"
  else FAIL=$((FAIL+1)); printf 'FAIL  %s\n  want: %s\n  got:  %s\n' "$n" "$want" "$got"; fi
}
ckx()    { local n="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); printf 'PASS  %s\n' "$n"
           else FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$n"; fi; }
ckfail() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then FAIL=$((FAIL+1)); printf 'FAIL  %s (expected failure)\n' "$n"
           else PASS=$((PASS+1)); printf 'PASS  %s\n' "$n"; fi; }
rec()    { printf 'RECORD %-28s %s\n' "$1" "$("${@:2}" 2>&1 | tr '\n' ' ')"; }

DIR="$HOME/cs193v"                        # or wherever the student put it
IMAGE="$(grep -oE 'ghcr\.io/[^ ]+' "$DIR/container.args" | head -1)"
E()  { podman exec cs193v sh -c "$1"; }                       # in the live container
R()  { podman run --rm --entrypoint sh "$IMAGE" -c "$1"; }     # throwaway
I()  { podman inspect cs193v --format "$1"; }
```

## A.1 Static checks — no podman needed

```sh
bash -n "$DIR/cs193v"; bash -n "$DIR/install-cs193v.sh"     # syntax
# bash 4+ constructs that break on macOS's bash 3.2 — expect NO matches.
# Comments are stripped first (the scripts document the ban, which would self-match) and
# `|&` requires surrounding whitespace so a sed character class like [&|\\] is not a hit.
sed 's/#.*//' "$DIR/cs193v" "$DIR/install-cs193v.sh" \
  | grep -nE 'declare -A|mapfile|readarray|\$\{[A-Za-z_]+,,\}|\$\{[A-Za-z_]+\^\^\}|[[:space:]]\|&[[:space:]]|&>>' \
  && echo "FAIL bash 4+ construct found" || echo "PASS bash 3.2 safe"
# `read -t` with a fractional timeout is bash 4+ only. Comments stripped first — the
# scripts document the ban, which would otherwise self-match.
sed 's/#.*//' "$DIR/cs193v" "$DIR/install-cs193v.sh" \
  | grep -nE 'read[^|]*-t *0?\.[0-9]' \
  && echo "FAIL fractional read -t" || echo "PASS no fractional read -t"
# No `#` comments inside a line-continued RUN in the Containerfile. The parser does strip
# them, but if that ever changed, a comment would swallow the command after it and
# silently produce a broken image.
awk '/\\$/{cont=1; next} cont && /^[[:space:]]*#/{print FILENAME":"NR": "$0; bad=1} {cont=0}
     END{exit bad?0:1}' "$DIR/Containerfile" \
  && echo "FAIL comment inside a continued RUN" || echo "PASS no comments inside continuations"
command -v shellcheck && shellcheck "$DIR/cs193v" "$DIR/install-cs193v.sh"
# messages.txt cross-reference: no orphan keys, no missing keys
# LC_ALL=C throughout: under en_US.UTF-8 sort and comm disagree about punctuation and
# comm aborts with "file 1 is not in sorted order", so this never actually ran.
LC_ALL=C comm -3 \
  <(grep -oE '^\[\[[a-z0-9._-]+\]\]' "$DIR/messages.txt" | tr -d '[]' | LC_ALL=C sort -u) \
  <(grep -ohE 'msg +[a-z0-9._-]+' "$DIR"/cs193v "$DIR"/install-cs193v.sh | awk '{print $2}' | LC_ALL=C sort -u)
grep -qxF 'local.args' "$DIR/.gitignore" && grep -qxF 'projects/*' "$DIR/.gitignore" && echo gitignore-ok
#   -F, not bare -x: `projects/*` as a BRE is "project"+"s"+zero-or-more-"/", so it matched
#   "projects", "projects/", "projects//" — never the literal line. The check never fired.
# Containerfile layer order: claude-code must be in the LAST software layer
grep -nE '^(FROM|RUN|ENV|COPY|USER|ENTRYPOINT|CMD)' "$DIR/Containerfile"
```

## A.2 Image assertions

```sh
podman manifest inspect "$IMAGE" | jq -r '.manifests[].platform | .os+"/"+.architecture'
                                          # expect linux/amd64 AND linux/arm64
ck  img-user       student  podman image inspect "$IMAGE" --format '{{.User}}'
rec img-size                podman image inspect "$IMAGE" --format '{{.Size}}'
rec img-layers              podman image inspect "$IMAGE" --format '{{len .RootFS.Layers}}'
podman image inspect "$IMAGE" --format '{{json .Config.Env}}' | jq -r '.[]' | sort
   # MUST contain: EDITOR=nano VISUAL=nano PAGER=less LESS=FRX
   #               BROWSER=/usr/local/bin/open-url
   # MUST NOT contain: GIT_EDITOR, HOST, FLASK_RUN_HOST
   #   HOST and FLASK_RUN_HOST were removed with the bind-0.0.0.0 rule. They pushed servers
   #   onto 0.0.0.0 because podman's forwarder never reached the container's loopback; the
   #   ssh tunnel does, so they nudge nothing and would only be an unexplained variable
   #   changing what a student's server binds to.
# no single layer should dominate — the resume-on-failure design
command -v skopeo && skopeo inspect --raw docker://"$IMAGE" | jq '[.layers[].size]|max'   # expect < 400 MB
```

## A.3 Image contents, via throwaway containers

```sh
ck  uid-gid        "1000 1000 student"   R 'echo $(id -u) $(id -g) $(id -un)'
rec passwd-student                       R 'getent passwd student'
ck  vol-owners     "student student student student student" \
    R 'stat -c %U /home/student/.claude /home/student/.claude-json \
                  /home/student/.config/gh /home/student/.local/share/com.vercel.cli \
                  /home/student/.cache/ms-playwright | tr "\n" " " | sed "s/ $//"'
ckfail no-gitconfig                      R 'test -e /etc/gitconfig'      # vanilla git, by decision
ckx  sudo-works                          R 'sudo -n true'
ck  git-editor     nano                  R 'git var GIT_EDITOR'          # NOT vi
ckx  nanorc                              R 'test -f /home/student/.nanorc'
ckx  identity-cue                        R 'am-i-in-a-container'
rec  open-url-stub                       R '/usr/local/bin/open-url https://example.com/x'
ckfail man-absent                        R 'man git'                     # deliberately not restored
ckx  tldr-present                        R 'command -v tldr'
# There must be NO nvm tree at all. The original form was vacuous: /usr/local/share/nvm
# does not exist by design (node comes from a root-owned install precisely so there is no
# group-writable tree to trojan with no sudo), so `stat` failed, the case fell to the
# catch-all, and it printed "ok" without asserting anything.
ckfail no-nvm-tree                       R 'test -e /usr/local/share/nvm'
ck  node-is-root-owned     root          R 'stat -c %U $(command -v node)'
# tools deliberately excluded
ck  no-extra-tools none                  R 'for t in rg fzf delta bat fd chromium google-chrome chrome; do command -v $t >/dev/null && echo $t; done; echo none'
#   ^ still none: a Chromium headless shell IS installed, but it lives in Playwright's cache
#     and is launched by Playwright, never typed. No browser is on $PATH.
rec  npm-globals                         R 'npm ls -g --depth=0 2>/dev/null'   # vercel + claude-code + playwright, NO puppeteer
ck  playwright-browser-runs ok            R 'playwright screenshot -b chromium about:blank /tmp/p.png >/dev/null 2>&1 && echo ok'
rec  versions                            R 'node -v; npm -v; python3 -V; gh --version|head -1; vercel --version; claude --version'
ckx  numpy                               R 'python3 -c "import numpy"'
rec  font-count                          R 'fc-list | wc -l'
rec  font-sans                           R 'fc-match sans-serif'         # expect a Noto face
# Claude Code policy files
ckx  managed-json-valid                  R 'python3 -c "import json;json.load(open(\"/etc/claude-code/managed-settings.json\"))"'
ck   claude-md-short  ok                 R '[ "$(wc -l < /etc/claude-code/CLAUDE.md)" -lt 200 ] && echo ok'
ck   deny-rule-forms  rules-ok           R 'python3 -c "
import json; d=json.load(open(\"/etc/claude-code/managed-settings.json\"))
bad=[x for x in d.get(\"permissions\",{}).get(\"deny\",[]) if not x.startswith((\"Read(\",\"Edit(\"))]
print(\"BAD:\"+str(bad) if bad else \"rules-ok\")"'
```

`deny-rule-forms` matters: `Write(...)` and `Glob(...)` path rules are accepted and then **silently
ignored with a startup warning** — a security control that does nothing is worse than none.

## A.4 Live container flag assertions

```sh
ck  net-pasta      pasta   I '{{.HostConfig.NetworkMode}}'
rec memory-cap             I '{{.HostConfig.Memory}}'          # compare to local.args
rec memory-swap            I '{{.HostConfig.MemorySwap}}'      # must NOT equal Memory
ck  pids-default   2048    I '{{.HostConfig.PidsLimit}}'
ck  no-cap-add     "[] []" I '{{json .HostConfig.CapAdd}} {{json .HostConfig.CapDrop}}'
rec security-opt           I '{{json .HostConfig.SecurityOpt}}'  # no no-new-privileges, no label=disable
ck  no-init        false   I '{{.HostConfig.Init}}'
rec tmpfs                  I '{{json .HostConfig.Tmpfs}}'        # expect no /tmp entry
rec shm-size               I '{{.HostConfig.ShmSize}}'           # podman default; playwright passes
#                                                                 # --disable-dev-shm-usage itself
# NO published ports at all. `-p` and `ssh -L` both bind host 127.0.0.1:<port>, so a -p line
# does not duplicate the tunnel, it takes the port away from it.
ck  no-port-bindings "{}"  I '{{json .HostConfig.PortBindings}}'
ck  port-count     0       sh -c 'podman port cs193v | wc -l | tr -d " "'
# The forwards live on the HOST, in one ssh process, and every one must be loopback-only.
# Loopback here is structural rather than a flag: the ssh client binds 127.0.0.1 itself.
ss -ltn | awk '{print $4}' | grep -cE '^127\.0\.0\.1:(300[0-9]|417[3-6]|517[3-9]|61(7[3-9]|8[0-2])|800[0-9]|808[0-4])$'
  # expect exactly: 46
ss -ltnp | grep -E ':(300[0-9]|517[3-9])' | grep -c 'users:(("ssh"'   # all owned by ssh
ss -ltn | awk '{print $4}' | grep -E ':(300[0-9]|517[3-9])$' | grep -v '^127\.0\.0\.1:'
  # expect NO output — a 0.0.0.0 forward would expose a dev server to dorm wifi
# The two read-only key mounts must be present, or sshd has no host key and no authorized_keys
I '{{json .Mounts}}' | grep -c 'authorized_keys'                     # expect 1, and RO
ck  tunnel-up      "up"    sh -c '"$DIR/cs193v" doctor | sed -n "s/^  tunnel  *\(up\).*/\1/p"'
rec mounts                 I '{{json .Mounts}}'                  # 5 volumes + 1 bind at <DIR>/projects
ckx config-hash-label      sh -c 'podman inspect cs193v --format "{{index .Config.Labels \"cs193v.confighash\"}}" | grep -q .'
rec container-env          I '{{json .Config.Env}}'              # CS193V_PORTS, CS193V_MEMORY_MB, TERM, COLORTERM
rec pid1                   I '{{json .Config.Entrypoint}} {{json .Config.Cmd}}'
```

## A.5 Kernel and namespace assertions

```sh
rec uid-map                E 'cat /proc/self/uid_map'       # a line mapping container 1000 -> host uid
rec capbnd                 E 'grep CapBnd /proc/self/status'  # decodes to podman's default 11
ck  capeff-zero  "CapEff:	0000000000000000"  E 'grep CapEff /proc/self/status'
ck  apparmor  "crun (unconfined)"  E 'cat /proc/self/attr/current'   # AppArmor is NOT a layer here
rec cgroup-memory-max      E 'cat /sys/fs/cgroup/memory.max'   # MUST equal --memory, not "max"
ck  cgroup-pids  2048      E 'cat /sys/fs/cgroup/pids.max'
# NOT `findmnt -no FSTYPE /tmp`: /tmp is not a mountpoint (just a directory on the root
# overlay), and findmnt without -T only reports real mountpoints, so it printed NOTHING.
ck  tmp-not-tmpfs overlayfs E 'stat -f -c %T /tmp'             # NOT tmpfs
rec shm-mount              E 'findmnt -no SIZE,OPTIONS /dev/shm'
# corrects a claim in the design docs: seccomp does NOT block mount()
ck  mount-allowed mount-allowed  E 'unshare -U --map-root-user -m -- mount -t tmpfs none /mnt && echo mount-allowed'
ckfail setns-blocked       E 'unshare -U --map-root-user -- nsenter --target 1 --mount true'
rec inotify-watches        E 'cat /proc/sys/fs/inotify/max_user_watches'
# /proc is NOT cgroup-aware — this is why CS193V_MEMORY_MB is passed in
rec free-vs-cgroup         E 'echo "free=$(free -m | awk "/^Mem:/{print \$2}")MB cgroup=$(($(cat /sys/fs/cgroup/memory.max)/1048576))MB"'
# -e TERM is REQUIRED. podman forces TERM=xterm and does not copy the client's value
# (containers/podman#25683), so without this the probe reports 8 and FAILS on a correctly
# working system. The launcher forwards TERM in open_shell/verb_ports; so must this.
ck  colors  256            sh -c 'podman exec -it -e TERM=xterm-256color cs193v tput colors | tr -d "\r"'
rec env-persists           E 'printenv CS193V_PORTS CS193V_MEMORY_MB'   # proves -e reaches exec sessions
ckx dns                    E 'getent hosts registry.npmjs.org'
```

## A.6 The full port matrix — all 46, no browser

Bound to `127.0.0.1` on purpose throughout, not `0.0.0.0`: that is the case the tunnel
exists to make work, so testing the easy one would prove nothing about the change.

```sh
ALL="$(seq 3000 3009) $(seq 4173 4176) $(seq 5173 5179) $(seq 6173 6182) $(seq 8000 8009) $(seq 8080 8084)"
for p in $ALL; do
  podman exec -d cs193v python3 -m http.server "$p" --bind 127.0.0.1 >/dev/null 2>&1
done
sleep 2
for p in $ALL; do
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$p/")
  [ "$c" = 200 ] && echo "PASS port $p" || echo "FAIL port $p (http=$c)"
done
podman exec cs193v pkill -f http.server

# ports outside the forwarded set must be refused
for p in 4000 7000 8500 9100 3100; do
  podman exec -d cs193v python3 -m http.server "$p" --bind 0.0.0.0 >/dev/null 2>&1; sleep 0.5
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$p/")
  [ "$c" = 000 ] && echo "PASS unforwarded $p refused" || echo "FAIL unforwarded $p reachable ($c)"
done
podman exec cs193v pkill -f http.server

# the direction invariant, tested rather than asserted: a remote forward must be REFUSED by
# the server, and must create no listener
CTL="$(ls "${TMPDIR:-/tmp}"/cs193v-*.ctl 2>/dev/null | head -1)"
ssh -S "$CTL" -O forward -R 127.0.0.1:19999:127.0.0.1:3000 student@cs193v-tunnel 2>&1 \
  | grep -q 'forwarding request failed' && echo "PASS -R refused" || echo "FAIL -R was ACCEPTED"
[ "$(ss -ltn | grep -c ':19999')" = 0 ] && echo "PASS no listener created" \
                                        || echo "FAIL something is listening on 19999"

# and the tunnel must not be usable as a proxy past the container's own loopback
ssh -S "$CTL" -O forward -L 127.0.0.1:13999:1.1.1.1:80 student@cs193v-tunnel 2>/dev/null
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:13999/)
[ "$c" = 000 ] && echo "PASS PermitOpen blocks off-box destinations" \
              || echo "FAIL the tunnel proxied to 1.1.1.1 ($c)"

# a busy host port must cost THAT port only, not the container
python3 -c 'import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("127.0.0.1",3005)); s.listen(1); time.sleep(60)' &
sleep 1; "$DIR/cs193v" --reset-tunnel 2>&1 | grep -q 3005 \
  && echo "PASS busy port is named" || echo "FAIL busy port not reported"
"$DIR/cs193v" doctor | grep -q 'NOT: 3005' \
  && echo "PASS doctor names it too" || echo "FAIL doctor missed it"
kill %1 2>/dev/null; "$DIR/cs193v" --reset-tunnel >/dev/null 2>&1

# a loopback-bound server inside MUST be reachable  (this expectation is deliberately
# inverted from what it was: the ssh tunnel's far end is the container's own loopback, and
# reaching it is the entire point of the change)
podman exec -d cs193v python3 -m http.server 3000 --bind 127.0.0.1; sleep 1
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:3000/)
[ "$c" = 200 ] && echo "PASS loopback-bound reachable" \
              || echo "FAIL loopback-bound UNREACHABLE ($c) — the tunnel is not working here"

# ...and a 0.0.0.0-bound one must STILL be reachable. The tunnel is a superset, so this is
# the no-regression half: it is what worked before the change.
podman exec -d cs193v python3 -m http.server 8080 --bind 0.0.0.0; sleep 1
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8080/)
[ "$c" = 200 ] && echo "PASS wildcard-bound still reachable" \
              || echo "FAIL wildcard-bound REGRESSED ($c)"

# ::1 alone is the one bind address the tunnel cannot reach, since the far end is IPv4.
podman exec -d cs193v python3 -c 'import http.server,socket,socketserver
class S(socketserver.TCPServer): address_family=socket.AF_INET6; allow_reuse_address=True
S(("::1",5177),http.server.SimpleHTTPRequestHandler).serve_forever()'; sleep 1
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:5177/)
[ "$c" = 000 ] && echo "PASS ::1-only is refused, as documented" \
              || echo "NOTE ::1-only is reachable ($c) — better than documented, update the docs"

# cs193v ports must diagnose what is LEFT to diagnose. The bind address is no longer one of
# them for IPv4, so the states are: forwarded, not forwarded, and ::1-only.
podman exec -d cs193v python3 -m http.server 4000 --bind 0.0.0.0     # not forwarded
"$DIR/cs193v" ports
   # expect: 3000 127.0.0.1  -> OK  (was "restart with --host 0.0.0.0")
   #         8080 0.0.0.0    -> OK
   #         5177 ::1        -> UNREACHABLE, names 127.0.0.1 as the fix
   #         4000 listening, NOT FORWARDED -> suggests an in-range port
   #         and a closing pointer at `cs193v doctor` for what it cannot see
podman exec cs193v pkill -f http.server
podman exec cs193v pkill -f SimpleHTTP

# host side must be loopback-only, not LAN-exposed
podman exec -d cs193v python3 -m http.server 3000 --bind 0.0.0.0; sleep 1
(ss -ltn 2>/dev/null || netstat -an) | grep ':3000'    # expect 127.0.0.1:3000, NOT 0.0.0.0:3000 or *:3000
LANIP=$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://$LANIP:3000/")
[ "$c" = 000 ] && echo "PASS not LAN-reachable" \
              || echo "FAIL reachable on LAN ($LANIP) — student servers are exposed"
podman exec cs193v pkill -f http.server
```

## A.7 Files, ownership and watching

```sh
# ownership round-trip, both directions
E 'umask 022; echo hi > /home/student/projects/.vt-c'
rec owner-of-container-write   stat -c '%u %g %a' "$DIR/projects/.vt-c"   # expect host uid/gid, 644
echo hi > "$DIR/projects/.vt-h"
ckx container-can-write-host-file  sh -c 'podman exec cs193v sh -c "echo more >> /home/student/projects/.vt-h"'
E 'chmod 600 /home/student/projects/.vt-c'
ck  mode-preserved 600  stat -c %a "$DIR/projects/.vt-c"
E 'ln -s /etc/hostname /home/student/projects/.vt-link'
rec symlink-readable   readlink "$DIR/projects/.vt-link"

# inotify, CONTAINER-side edit — the case that matters (writer is always inside)
E 'command -v inotifywait || sudo apt-get install -y inotify-tools >/dev/null 2>&1'
podman exec -d cs193v sh -c 'inotifywait -q -e modify /home/student/projects/.vt-c > /tmp/vt-in 2>&1'
sleep 1; E 'echo x >> /home/student/projects/.vt-c'; sleep 1
ckx inotify-container-side  sh -c 'podman exec cs193v test -s /tmp/vt-in'

# inotify, HOST-side edit — expected to FAIL on macOS and WSL; RECORD which
E 'rm -f /tmp/vt-in'
podman exec -d cs193v sh -c 'inotifywait -q -e modify /home/student/projects/.vt-c > /tmp/vt-in 2>&1'
sleep 1; echo y >> "$DIR/projects/.vt-c"; sleep 2
podman exec cs193v test -s /tmp/vt-in && echo "host-side inotify: FIRES" \
                                      || echo "host-side inotify: DOES NOT FIRE"

# case sensitivity — determines whether a Mac student's import bug reproduces
E 'cd /home/student/projects && touch Aa && (ls aA >/dev/null 2>&1 && echo CASE-INSENSITIVE || echo case-sensitive)'

# quantify the bind-mount penalty per platform
time E 'mkdir -p /home/student/projects/.vt-many && cd /home/student/projects/.vt-many && for i in $(seq 1 2000); do : > f$i; done'
time E 'rm -rf /home/student/projects/.vt-many'
```

## A.8 The SIGHUP matrix — the disputed question, automated

"Closing the terminal window" is simulatable: kill the local `podman exec` **client** process. This turns
the single most important open question into a repeatable matrix.

```sh
probe() {  # probe <label> <command-to-run-inside>
  script -q -c "podman exec -it cs193v sh -c '$2'" /dev/null >/dev/null 2>&1 & CLIENT=$!
  sleep 2
  kill -9 "$CLIENT" 2>/dev/null            # <-- simulates the window being closed
  sleep 2
  alive=$(podman exec cs193v sh -c 'pgrep -f "http.server 3000" >/dev/null && echo yes || echo no')
  ppid=$(podman exec cs193v sh -c 'p=$(pgrep -f "http.server 3000" | head -1); [ -n "$p" ] && awk "{print \$4}" /proc/$p/stat')
  fd1=$(podman exec cs193v sh -c 'p=$(pgrep -f "http.server 3000" | head -1); [ -n "$p" ] && readlink /proc/$p/fd/1')
  http=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:3000/)
  printf '%-12s alive=%-3s ppid=%-6s http=%-3s fd1=%s\n' "$1" "$alive" "$ppid" "$http" "$fd1"
  podman exec cs193v pkill -f 'http.server 3000' 2>/dev/null
}
S='python3 -m http.server 3000 --bind 0.0.0.0'
probe foreground  "$S"
probe background  "$S & sleep 60"
probe nohup       "nohup $S >/tmp/s.log 2>&1 & sleep 60"
probe setsid      "setsid $S >/tmp/s.log 2>&1 & sleep 60"

# repeat WITHOUT -it, to isolate whether pty teardown is the mechanism
probe_no_tty() { podman exec cs193v sh -c "$1" & sleep 2; kill -9 $! 2>/dev/null; sleep 2; \
                 podman exec cs193v sh -c 'pgrep -f "http.server 3000" >/dev/null && echo survived || echo died'; \
                 podman exec cs193v pkill -f 'http.server 3000' 2>/dev/null; }
probe_no_tty "$S"
```

Report the whole matrix verbatim. `fd1` also answers whether a backgrounded server's log is reachable by
name or points at a deleted or unpredictable path.

## A.9 Resource limits

```sh
# a clean container OOM: one process dies, the container survives, the host stays responsive
( while :; do s=$(date +%s%N 2>/dev/null || echo 0); sleep 1; done ) >/dev/null &
LAT=$!
E 'python3 -c "
b=[]
try:
  while True: b.append(bytearray(64*1024*1024))
except MemoryError: print(\"MemoryError\")"' ; echo "exit=$?"      # expect 137 or MemoryError
kill $LAT 2>/dev/null
ck  container-survived-oom running  I '{{.State.Status}}'

# pids limit: use a DISPOSABLE container. NEVER fork-bomb cs193v —
# pids exhaustion wedges it beyond podman exec's reach and does not self-heal.
podman run --rm --pids-limit 64 "$IMAGE" sh -c \
  'i=0; while sleep 30 & do i=$((i+1)); [ $i -gt 200 ] && break; done; echo "forks=$i"' 2>&1 | tail -2
```

## A.10 Launcher verbs and failure paths, using shims

```sh
# The empty verb ends in `exec podman exec -it`, which opens an interactive shell. This
# loop HANGS on it, and `</dev/null` does NOT help: -t allocates a pty, and a pty never
# delivers EOF the way a pipe does, so `bash -l` waits for input forever. Measured.
# Feed it an `exit` instead. (See ERRORS.md B13 for the two-line launcher fix that would
# make `</dev/null` work: pass -t only when stdin is a terminal.)
for v in ports doctor --dev-print-command; do
  "$DIR/cs193v" $v >/dev/null 2>&1 </dev/null; echo "verb '$v' -> $?"
done
printf 'exit\n' | timeout 60 "$DIR/cs193v" >/dev/null 2>&1; echo "verb '' -> $?"

# idempotency: 20 invocations, still exactly one container
for i in $(seq 1 20); do "$DIR/cs193v" --dev-print-command >/dev/null; done
ck one-container 1 sh -c 'podman ps -q | wc -l | tr -d " "'

# concurrency: four shells, one container
for i in 1 2 3 4; do (echo exit | "$DIR/cs193v" >/dev/null 2>&1 &) ; done; sleep 4
rec exec-sessions sh -c 'podman top cs193v | wc -l'
ck still-one-container 1 sh -c 'podman ps -q | wc -l | tr -d " "'

# --dev-print-command must contain every flag from the args files. One-directional on
# purpose: the launcher legitimately ADDS --name, --detach, --label and --mount, so a
# plain diff would fail spuriously. comm -13 shows only flags present in the args files
# but MISSING from the run line, which must be empty.
MISSING=$(comm -13 <("$DIR/cs193v" --dev-print-command | tr ' ' '\n' | grep -E '^--?[a-z]' | sort -u) \
                   <(sed 's/#.*//' "$DIR/container.args" "$DIR/local.args" 2>/dev/null \
                       | tr ' ' '\n' | grep -E '^--?[a-z]' | sort -u))
if [ -z "$MISSING" ]; then echo "PASS print-command contains every args-file flag"
else echo "FAIL these args-file flags are missing from the run line:"; echo "$MISSING"; fi

# failure paths, via a PATH shim faking podman
mkdir -p /tmp/vt-shim
printf '#!/bin/sh\n[ "$1" = "--version" ] && { echo "podman version 5.6.0"; exit 0; }\nexit 1\n' > /tmp/vt-shim/podman
chmod +x /tmp/vt-shim/podman
PATH=/tmp/vt-shim:$PATH "$DIR/cs193v"; echo "old-podman -> $? (expect nonzero, with a platform fix printed)"

printf '#!/bin/sh\nsleep 600\n' > /tmp/vt-shim/podman        # a HANGING podman
T0=$(date +%s); PATH=/tmp/vt-shim:$PATH "$DIR/cs193v"; RC=$?; T1=$(date +%s)
echo "hanging-podman -> rc=$RC after $((T1-T0))s (expect seconds, NOT minutes)"
rm -rf /tmp/vt-shim

ckfail refuses-as-root  sudo "$DIR/cs193v"
cp -a "$DIR" /tmp/vt-copy && ckfail refuses-second-copy /tmp/vt-copy/cs193v && rm -rf /tmp/vt-copy

# config-drift detection — the `podman start` trap
cp "$DIR/container.args" /tmp/vt-ca.bak
echo '-p 127.0.0.1:9998:9998' >> "$DIR/container.args"
"$DIR/cs193v" --dev-print-command | grep -q 9998 && echo "PASS drift visible in print-command"
"$DIR/cs193v"     # expect a recreate prompt. Decline -> unchanged. Accept -> then:
podman port cs193v | grep -q 9998 && echo "PASS recreated with the new flag" \
                                  || echo "FAIL flag never applied"
cp /tmp/vt-ca.bak "$DIR/container.args"; "$DIR/cs193v" --rebuild
```

## A.11 Claude Code assertions

```sh
rec claude-version E 'claude --version'
# settings must load with no warning about ignored rules
E 'claude -p "reply with exactly: ok" 2>/tmp/cc.err >/dev/null'; E 'cat /tmp/cc.err'
ckfail no-settings-warning E 'grep -iE "ignor|invalid|unknown key|warn" /tmp/cc.err'

# deny rules must actually deny — and must be narrowly scoped
E 'claude -p "Use the Read tool on /home/student/.claude/.credentials.json and print what you get."'
   # expect a permission refusal, NOT the file contents
E 'claude -p "Use the Read tool on /home/student/.claude/settings.json and list its top-level keys."'
   # expect SUCCESS — the deny covers the credential file, not the whole directory
E 'claude -p "Use the Read tool on /home/student/.config/gh/hosts.yml."'
   # expect refusal — whole subtree denied

# the managed CLAUDE.md must be in effect
E 'claude -p "Which port ranges may a dev server use in this container? List them and nothing else."'
   # expect the six ranges

# policy survives a rebuild (image layer, not the ~/.claude volume)
"$DIR/cs193v" --rebuild >/dev/null
ckx policy-survives-rebuild E 'test -f /etc/claude-code/CLAUDE.md -a -f /etc/claude-code/managed-settings.json'
rec claude-dir-contents E 'ls -a /home/student/.claude | head -20'
```

## A.12 Installer idempotency, by state hash

```sh
STATE() { find "$DIR" -type f -not -path '*/projects/*' -not -name '*.log' \
            -exec shasum -a 256 {} + 2>/dev/null | sort; }
STATE > /tmp/vt-s1
bash ./install-cs193v.sh </dev/null    # second run; empty stdin surfaces any unguarded prompt
STATE > /tmp/vt-s2
diff /tmp/vt-s1 /tmp/vt-s2 && echo "PASS installer is idempotent"
# published checksum must match
shasum -a 256 install-cs193v.sh   # compare against the value on the course website
# local.args must match the formula for THIS machine
rec podman-memtotal podman info -f '{{.Host.MemTotal}}'
cat "$DIR/local.args"             # recompute by the documented formula and compare
```

## A.13 Performance baseline — record, do not assert

```sh
time podman pull "$IMAGE"                    # cold pull; note the size actually transferred
time "$DIR/cs193v" --rebuild                 # container create
time "$DIR/cs193v" --dev-print-command       # launcher overhead
time podman exec cs193v true                 # exec overhead — relevant to the rejected relay design
time E 'cd /home/student/projects && npm init -y >/dev/null && npm i --silent lodash'
```

## A.14 Cleanup assertions

```sh
rec containers podman ps -a --format '{{.Names}}'          # expect only cs193v
rec volumes    podman volume ls --format '{{.Name}}'        # expect only the four cs193v-*
rec images     podman images --format '{{.Repository}}:{{.Tag}}'
rm -f "$DIR"/projects/.vt-*
echo "A-battery: PASS=$PASS FAIL=$FAIL"
```

---

## 1. Install and preflight

**1.1 — Installer is idempotent.** Run the installer twice on a clean machine.
*Expect:* the second run changes nothing, reports each step as already satisfied, and exits 0.
*Why:* a student whose wifi drops mid-pull must be able to simply re-run it.

**1.2 — Consent prompts render correctly.** Trigger a prompt (e.g. run the installer where podman is
already present).
*Expect:* an arrow-key menu, not `[y/N]`. The **declining** option is selected by default and visually
highlighted. Arrow keys move the selection; Enter confirms. In a non-TTY context it falls back to
numbered selection rather than hanging.

**1.3 — bash 3.2 compatibility.** On macOS: `bash --version` (expect 3.2.x), then run the installer
with `/bin/bash` explicitly.
*Expect:* no `mapfile`, associative-array, or `${x,,}` errors.

**1.4 — Version floor.** If podman < 5.7.0 is available, or via the shim in §A.10:
*Expect:* the launcher refuses, names the platform-specific fix, exits non-zero, and creates nothing.

**1.5 — Refuses to run as root.** `sudo ./cs193v`
*Expect:* a clear refusal explaining that this would run podman rootful and defeat the isolation model.

**1.6 — `/etc/subuid` populated.** `grep "^$(id -un):" /etc/subuid /etc/subgid`
*Expect:* a range for the current user. If absent, the installer should have offered to add it with
consent — confirm it did rather than failing with a raw podman error.

**1.7 — Flag parsing is faithful.** `./cs193v --dev-print-command`
*Expect:* every flag in `container.args` appears in the printed `podman run` line, with the memory cap
from `local.args` and no flag mangled by quoting. This is the first thing to ask a student for in any
support thread, so it must be trustworthy.

---

## 2. Container lifecycle

**2.1 — First launch.** `./cs193v`
*Expect:* container created and a shell opens. Note wall-clock time to first prompt.

**2.2 — Multiple shells.** Open three more terminals, run `./cs193v` in each.
*Expect:* all four attach to the **same** container. `podman ps` shows exactly one. No refusal — the
"second instance" refusal applies to a second *container*, not a second window.

**2.3 — `--rebuild` preserves logins.** Log in to `claude` and `gh`, then `./cs193v --rebuild`.
*Expect:* container recreated; both logins still valid; `projects/` untouched.

**2.4 — `--full-rebuild` drops logins.** `./cs193v --full-rebuild`
*Expect:* a confirmation prompt; afterwards both logins are gone and `projects/` is still untouched.

**2.5 — Config-drift detection.** See §A.10. **This is a known podman behaviour trap** — `podman start`
reuses the container's stored config and ignores the image digest, ports, `keep-id` and `--memory`
alike. If this fails, every student's flags are frozen at first run and edits to `container.args` never
reach them.

**2.6 — Stale-image detection.** Point `IMAGE=` at a different digest, then `./cs193v`.
*Expect:* a prompt to update rather than silently continuing on the old image.

**2.7 — Two copies refused.** See §A.10.

**2.8 — PID 1 reaps.** After a few hours of normal use:
`podman exec cs193v ps -eo stat --no-headers | grep -c Z`
*Expect:* 0, or a small number that does not grow. The shell keep-alive loop is PID 1; if zombies
accumulate they will eventually exhaust `pids.max` (2048) and **wedge** the container so `podman exec`
cannot get in.

---

## 3. Files, ownership and watching

Mostly automated in §A.7. What still needs a person:

**3.4 — Real HMR.** In a scratch project inside the container, `npm create vite`, run the dev server
**with no `--host` flag at all**, open it in a host browser, and edit a source file **from inside the
container**.
*Expect:* the page hot-reloads. Two things at once here: `inotifywait` firing (§A.7) is necessary but
not sufficient for HMR, and running vite unflagged — which binds `localhost` — is the case that used
to be unreachable. If this works, the whole chain works and the `--host 0.0.0.0` rule really is
retired. Also watch the websocket: HMR over the tunnel shares one pipe with asset loading, and
measured contention was nil, but a human watching a real editor loop is the honest check.

**3.5 — Host-side editing.** Edit the same file from a host editor with the page open.
*Expect:* on native Linux it reloads. On macOS and WSL it likely does **not**. Record which; this
determines what the docs must say.

---

## 4. Ports

Fully automated in §A.6. What still needs a person:

**4.5 — Firewall prompt (Windows only).** On first port bind, note whether Windows Defender prompts.
*Expect:* still no prompt, since a loopback bind needs no exception. But the binding process changed
from pasta to `ssh`, and Defender's rules are per-executable, so this needs re-checking rather than
inheriting the old answer. If a prompt appears, record the exact wording — it is safe to decline.

**4.6 — Windows localhost forwarding (Windows only).** This is the biggest unverified risk in the
tunnel design. Inside the WSL2 distro the ssh client binds `127.0.0.1:3000`; the browser is on
Windows. `container.args` establishes that Windows' localhost forwarding reaches a *pasta*-bound
listener there, citing podman#17972 and #22562, and ssh binds the same way — but "binds the same way"
is exactly the kind of reasoning that made `--host-lo-to-ns-lo` fail on macOS.
*Expect:* `http://localhost:3000` in a Windows browser reaches a server bound to the container's
`127.0.0.1`. If it does not, the tunnel does not work on Windows and this must be reported before
anything ships.

**4.7 — macOS (Mac only).** The other unverified leg. `podman exec` reaches the machine VM through
gvproxy's control channel, which is the same path `cs193v` already uses for a shell, so the tunnel
should work — but throughput through that channel is unmeasured, and macOS is where the previous
attempt silently failed.
*Expect:* a `127.0.0.1`-bound server inside is reachable from Safari. Record the throughput of a large
asset for comparison against the Linux figure of 322 MB/s, and check that the tunnel survives the Mac
sleeping and waking.

**4.7 — A real browser.** Open `http://localhost:3000/` in the student's actual browser, not `curl`.
*Expect:* loads. On Windows, if `localhost` fails but `127.0.0.1` works, record it — `localhost` may be
resolving to `::1`.

---

## 5. Disputed behaviours needing a human or specific hardware

**5.1 — Closing a terminal window, for real.** §A.8 simulates it by killing the exec client. Also do it
by hand — click the window's close button with a foreground server running — and confirm the result
matches the automated matrix. If they differ, the automated probe is not modelling the real case.

**5.2 — macOS provider behaviour (Apple Silicon only).** Run §A.7's ownership checks under **both**
providers:
```sh
podman machine stop
CONTAINERS_MACHINE_PROVIDER=applehv podman machine init cs193v-test && podman machine start cs193v-test
# ...then again with libkrun (podman 6's default)
```
*Expect:* both work. Libkrun's virtiofs *enforces* permissions where applehv's is permissive, and there
are open reports of read-only bind mounts and `root nogroup` ownership (`podman#28316`, `#27893`,
`#27679`). Confirm `--userns=keep-id:uid=1000,gid=1000` resolves it on both. **If libkrun fails, the
install docs must pin applehv.**

**5.3 — Intel Mac (Intel Macs only).** Attempt the full install.
*Expect:* unknown. The design assumes podman 6 does not run at all and refuses these machines. Confirm
or refute — the support policy depends on it.

**5.4 — WSL `--name`.** `wsl --install -d Ubuntu-26.04 --name CS193V`
*Expect:* succeeds on current WSL. If `--name` is unsupported, the fallback is `wsl --import` from a
hosted rootfs, which changes the installer.

**5.5 — cgroup delegation in WSL.** With `systemd=true` in `/etc/wsl.conf`, run §A.5's
`cgroup-memory-max` check.
*Expect:* the value passed as `--memory`, not `max`. If it reads `max`, the memory cap is **not being
enforced** and the protection is illusory.

**5.6 — What an OOM looks like to a student.** Run §A.9's allocation loop from an interactive shell.
*Expect:* record exactly what appears on screen. This becomes the troubleshooting entry for exit 137.

---

## 6. Sleep, wake and drift (macOS and Windows)

**6.1 — Preflight after sleep.** Sleep the laptop for at least a few hours — ideally two days — then run
`./cs193v`.
*Expect:* a clear status within seconds. It must **not** hang: `podman info` is known to hang rather
than fail after a Mac wakes (`podman#21675`), which is why every probe is `timeout`-wrapped.

**6.2 — Clock skew.** After the same sleep:
`echo "host=$(date +%s) container=$(podman exec cs193v date +%s)"`
*Expect:* within a couple of seconds. If minutes or hours apart, confirm `cs193v doctor` detects it and
offers the VM restart, and that the restart fixes it. Also record whether podman **self-corrected** on
resume — if it does, the check may be unnecessary.

**6.3 — gvproxy CPU (macOS).** After wake, check CPU usage of `gvproxy`.
*Expect:* idle. There are reports of ~400% CPU after sleep (`podman#27279`); if reproduced, the runbook
needs `podman machine stop` as the answer.

---

## 7. Tools and ergonomics

Mostly automated in §A.3 and §A.5. What still needs a person:

**7.2 — Ctrl-S does not freeze.** In an interactive container shell, press Ctrl-S then type.
*Expect:* typing still echoes. If the terminal freezes, `stty -ixon` is not being applied.

**7.3 — Pager behaviour.** `podman exec -it cs193v man ls`, and a one-line `git diff`.
*Expect:* the one-line diff prints without entering a pager; colour is not shown as escape codes;
output remains on screen after quitting.

**7.6 — Fonts.** Render text to an image inside the container (Pillow or matplotlib).
*Expect:* legible glyphs, not boxes, for Latin text.

**7.8 — Terminal variety.** Repeat 7.2, 7.3 and §A.5's colour check under macOS Terminal.app, iTerm2,
Windows Terminal and GNOME Terminal.
*Expect:* consistent. Record any terminal where colour or key handling differs.

**7.9 — The tab keys, per terminal.** See `tests/MANUAL.md` §7.9 for the matrix. This cannot be
automated in principle: `65-tmux.sh` injects the key bytes directly and so proves only that the
container responds to them, never that a given terminal emits them.
*Expect:* `CTRL+T`, clicking a tab and clicking `+ NEW TAB` work everywhere. `SHIFT+LEFT/RIGHT`
work wherever the terminal sends `CSI 1;2D`/`1;2C`. `ALT+…` is expected to fail on macOS unless
the student has enabled Option-as-Meta, which is precisely why every action also has a key or a
click that does not need it.

---

## 8. Claude Code

Mostly automated in §A.11. What still needs a person:

**8.1 — Login with no host browser.** `claude` then `/login` inside the container.
*Expect:* a URL is **printed** (via the `BROWSER` stub) and a device/paste code flow completes. No
callback port is published, so a redirect-only flow would fail — confirm it does not need one.

**8.2 — `gh` and `vercel` login.** `gh auth login`, then `vercel login`.
*Expect:* both complete with a printed URL or emailed code. During `gh auth login`, answer **yes** to
"Authenticate Git with your GitHub credentials?" and then confirm `git push` works from a test repo.

**8.7 — A permission prompt in the wild.** Ask the agent to do something that triggers a prompt.
*Expect:* the prompt is comprehensible to a first-year student. Record the wording; this is the moment
the course's core skill is taught.

---

## 9. Teardown

**9.1 — Volumes survive an image update.** `./cs193v --update` after a new digest is published.
*Expect:* logins intact.

**9.2 — Full reset is clean.** `./cs193v --full-rebuild`; confirm `podman volume ls` no longer lists the
four `cs193v-*` volumes.

**9.3 — WSL teardown (Windows).** `wsl --unregister CS193V`
*Expect:* removes the distro without touching any other WSL distro. Confirm any pre-existing distro
still works.

---

## 10. Report template

```
PLATFORM: (macOS 15.x arm64 / Windows 11 + WSL2 Ubuntu 26.04 / Ubuntu 26.04 native / Intel Mac)
HARDWARE: (model, RAM)
PODMAN:   (version, provider if applicable)
DATE:

§A  automated battery  PASS ____ / FAIL ____   (paste the full run output separately)
    A.1 static __   A.2 image __   A.3 contents __  A.4 flags __   A.5 kernel __
    A.6 ports __    A.7 files __   A.8 sighup __    A.9 limits __  A.10 launcher __
    A.11 claude __  A.12 install __  A.13 perf (record)  A.14 cleanup __

§1  install/preflight   1.1 __  1.2 __  1.3 __  1.4 __  1.5 __  1.6 __  1.7 __
§2  lifecycle           2.1 __  2.2 __  2.3 __  2.4 __  2.5 __  2.6 __  2.7 __  2.8 __
§3  files               3.4 __  3.5 __
§4  ports               4.5 __  4.7 __
§5  disputed            5.1 __  5.2 __  5.3 __  5.4 __  5.5 __  5.6 __
§6  sleep/drift         6.1 __  6.2 __  6.3 __
§7  ergonomics          7.2 __  7.3 __  7.6 __  7.8 __
§8  Claude Code         8.1 __  8.2 __  8.7 __
§9  teardown            9.1 __  9.2 __  9.3 __

BLOCKERS (a student could not do the assignment):

ANSWERS TO THE DISPUTED QUESTIONS — quote actual output verbatim:
  A.8 SIGHUP matrix (foreground / background / nohup / setsid / no-tty):
  A.5 mount() in a nested userns allowed?
  A.7 host-side inotify fires?
  A.6 loopback-bound server reachable from the host?
  5.2 macOS provider (libkrun vs applehv):
  5.3 Intel Mac — does podman run at all?
  5.5 cgroup delegation — is memory.max the cap, or "max"?

SURPRISES (passed, but not as expected):

TIMINGS: first pull ____   first launch ____   subsequent launch ____   --rebuild ____
```
