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
| §A.5 | `ck apparmor "crun (unconfined)"` — that file is the **host's** LSM, so it is red on Fedora on a *better* value | `rec`, not `ck` |
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
# The image built on this machine, which is the only image there is: nothing in
# container.args names one and no environment variable overrides it. The suffix mirrors the
# launcher's, so this runs against your own instance — see .config/container.args.
IMAGE="localhost/cs193v:local${CS193V_INSTANCE:+-$CS193V_INSTANCE}"
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
# WHAT THE TWO GREPS ABOVE CANNOT DO is catch a construct that parses on bash 3.2 and 4+ alike
# but MATCHES DIFFERENT STRINGS. Shell patterns are where that lives, and nothing in the gates
# runs 3.2, so these two are a REPORT rather than a gate: each hit is a line that §1.3 has to be
# run on a Mac to clear. Hits are legitimate — do not "fix" them to get to zero.
#
# NO COMMENT STRIPPING HERE, unlike every check above, and that is not an oversight: `${var#"…"}`
# contains its own `#`, so `sed 's/#.*//'` truncates the construct being looked for and the grep
# then finds nothing. `case[^#]*` is what keeps the first pattern off the sed and grep SCRIPTS that
# legitimately hold `[[:space:]]` -- load_args' own trim, and the /etc/wsl.conf greps in the
# installer. Named by function rather than by line, because these two greps will outlive the numbers.
grep -nE 'case[^#]*\[:[a-z]+:\]'   "$DIR/cs193v" "$DIR/install-cs193v.sh"   # class in a case bracket
grep -nE '\$\{[A-Za-z_]+[#%]{1,2}"' "$DIR/cs193v" "$DIR/install-cs193v.sh"  # quoted nested pattern
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
grep -qxF 'projects/*' "$DIR/.gitignore" && echo gitignore-ok
#   -F, not bare -x: `projects/*` as a BRE is "project"+"s"+zero-or-more-"/", so it matched
#   "projects", "projects/", "projects//" — never the literal line. The check never fired.
# Containerfile layer order: node < gh < vercel < codex < claude-code, most volatile LAST.
# Codex sits before Claude Code on cost, not taste: they are the two biggest layers in the file
# (measured with `podman history`: codex 312 MB, Claude Code 298 MB), and Claude Code's pin is the
# one most often moved, so it is the one whose bump should not drag the other along.
grep -nE '^(FROM|RUN|ENV|COPY|USER|ENTRYPOINT|CMD)' "$DIR/Containerfile"
```

## A.2 Image assertions

```sh
# NOT a multi-arch manifest check. The image is built on this machine, so it is
# single-arch by definition and always will be. What is worth checking is that it came
# from the recipe on disk — the label that replaced the digest pin.
rec img-recipe              podman image inspect "$IMAGE" --format '{{index .Labels "cs193v.buildhash"}}'
rec img-built               podman image inspect "$IMAGE" --format '{{.Created}}'
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
# Layer sizes are recorded by nothing and gated by nothing. There was a "no layer over
# 400 MB" ceiling here for the resume-on-failure design; it was withdrawn rather than met —
# see ERRORS.md B9 / issue #7. Layer ORDER is still asserted, in §A.1.
```

## A.3 Image contents, via throwaway containers

```sh
ck  uid-gid        "1000 1000 student"   R 'echo $(id -u) $(id -g) $(id -un)'
rec passwd-student                       R 'getent passwd student'
ck  vol-owners     "student student student student student student" \
    R 'stat -c %U /home/student/.claude /home/student/.claude-json /home/student/.codex \
                  /home/student/.config/gh /home/student/.local/share/com.vercel.cli \
                  /home/student/.cache/ms-playwright | tr "\n" " " | sed "s/ $//"'
ckfail no-gitconfig                      R 'test -e /etc/gitconfig'      # vanilla git, by decision
ckx  sudo-works                          R 'sudo -n true'
ck  git-editor     nano                  R 'git var GIT_EDITOR'          # NOT vi
ckx  nanorc                              R 'test -f /home/student/.nanorc'
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
# The `2>/dev/null` this line used to carry is exactly what made the automated version
# vacuous. While the globals lived in root's prefix and the student's had no lib/ at all,
# `npm ls -g` exited 254 with an ENOENT — the redirect swallowed it, so anything matched
# against that output was being compared to the empty string and passed for the wrong
# reason. Check the exit status first, then record. Issue #13.
ckx  npm-ls-g-succeeds                   R 'npm ls -g --depth=0 >/dev/null'
rec  npm-globals                         R 'npm ls -g --depth=0'         # vercel + codex + claude-code + playwright, in the STUDENT's prefix
#   ^ puppeteer is deliberately NOT checked for here. The assertion that did was removed by
#     decision, so nothing enforces its absence any more — the rejection rests on the
#     argument in README's "Deliberately not here" alone.
ck  playwright-browser-runs ok            R 'playwright screenshot -b chromium about:blank /tmp/p.png >/dev/null 2>&1 && echo ok'
rec  versions                            R 'node -v; npm -v; python3 -V; gh --version|head -1; vercel --version; claude --version; codex --version'
#   Python is a floor, not a library set (issue #44): no library is preinstalled, so what is
#   checked is that a student can install any of them with no sudo and no flag.
ck   pip-needs-no-flags   ok             R 'pip3 install --no-index tabulate 2>&1 | grep -q externally-managed && echo BLOCKED || echo ok'
ck   sudo-pip-refuses     refuses        R 'sudo pip3 install --no-index tabulate 2>&1 | grep -q externally-managed && echo refuses || echo OPEN'
ck   no-apt-numpy         gone           R 'python3 -c "import numpy" 2>/dev/null && echo PRESENT || echo gone'
ckx  c-extension-headers                 R 'ls /usr/include/python3*/Python.h'
ck   venv-works-offline   ok             R 'python3 -m venv /tmp/v >/dev/null 2>&1 && /tmp/v/bin/pip --version >/dev/null && echo ok'
rec  python-user-site                    R 'python3 -c "import site;print(site.getusersitepackages())"'
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
rec mounts                 I '{{json .Mounts}}'                  # 6 volumes + 1 bind at <DIR>/projects
ckx config-hash-label      sh -c 'podman inspect cs193v --format "{{index .Config.Labels \"cs193v.confighash\"}}" | grep -q .'
rec container-env          I '{{json .Config.Env}}'              # TERM, COLORTERM; NO port list
rec pid1                   I '{{json .Config.Entrypoint}} {{json .Config.Cmd}}'
```

## A.5 Kernel and namespace assertions

```sh
rec uid-map                E 'cat /proc/self/uid_map'       # a line mapping container 1000 -> host uid
rec capbnd                 E 'grep CapBnd /proc/self/status'  # decodes to podman's default 11
ck  capeff-zero  "CapEff:	0000000000000000"  E 'grep CapEff /proc/self/status'
# RECORDED, not asserted. This file is whichever LSM the HOST has, not a property of the image,
# so no fixed expectation survives both platforms. It is AppArmor's on a Debian-family host,
# where it reads `crun (unconfined)` because an unprivileged user cannot load a profile; it is an
# SELinux context on Fedora/RHEL, measured `system_u:system_r:container_t:s0:c483,c562` on
# Fedora 44. In NEITHER case is it what isolates the container — that is the user namespace.
# NOT NAMED FOR EITHER LSM, deliberately: a token called `apparmor` reporting an SELinux context
# would be describing a different mechanism under a name nobody would question. lib/sandbox.sh's
# PROC_ATTR_CURRENT is the same value, recorded for the same reason.
# `tr -d "\0"` because the SELinux read carries a trailing NUL, which bash strips out of a
# command substitution with a warning on stderr.
rec lsm-label              E 'cat /proc/self/attr/current | tr -d "\0"'
ck  cgroup-pids  2048      E 'cat /sys/fs/cgroup/pids.max'
# NOT `findmnt -no FSTYPE /tmp`: /tmp is not a mountpoint (just a directory on the root
# overlay), and findmnt without -T only reports real mountpoints, so it printed NOTHING.
ck  tmp-not-tmpfs overlayfs E 'stat -f -c %T /tmp'             # NOT tmpfs
rec shm-mount              E 'findmnt -no SIZE,OPTIONS /dev/shm'
# corrects a claim in the design docs: seccomp does NOT block mount()
# RECORDED rather than asserted, as 60-container.sh's kernel:mount-in-nested-userns is: the
# answer is the point, and #119 measured that a nested mount is exactly the kind of thing an
# SELinux host adjudicates for itself. Both arms are positive tokens, so an empty value reads as
# neither one. Measured ALLOWED on Fedora 44 as well as on Ubuntu.
rec mount-in-nested-userns E 'unshare -U --map-root-user -m -- mount -t tmpfs none /mnt >/dev/null 2>&1 && echo ALLOWED || echo blocked'
ckfail setns-blocked       E 'unshare -U --map-root-user -- nsenter --target 1 --mount true'
rec inotify-watches        E 'cat /proc/sys/fs/inotify/max_user_watches'
# -e TERM is REQUIRED. podman forces TERM=xterm and does not copy the client's value
# (containers/podman#25683), so without this the probe reports 8 and FAILS on a correctly
# working system. The launcher forwards TERM in open_shell; so must this.
ck  colors  256            sh -c 'podman exec -it -e TERM=xterm-256color cs193v tput colors | tr -d "\r"'
rec env-in-exec            E 'printenv | sort'          # what an exec session actually inherits
ckx dns                    E 'getent hosts registry.npmjs.org'
```

## A.6 The port matrix, by bind address — no browser

There is no set of ports to walk any more: a port is forwarded because something inside the
container is listening on it, so what there is to verify is which KINDS of listener are carried
and which are refused, plus both ends of the lifecycle.

Bound to `127.0.0.1` on purpose wherever the address is not the subject: that is the case the
tunnel exists to make work, so testing the easy one would prove nothing about the change.

`sleep 3` after each bind rather than `sleep 1`: the forward does not exist when the server
starts. The supervisor has to see the new listener on its next tick and ask the master to open
the host port, so readiness is two events rather than one.

```sh
# a loopback-bound server inside MUST be reachable  (this expectation is deliberately
# inverted from what podman did: the ssh tunnel's far end is the container's own loopback, and
# reaching it is the entire point)
podman exec -d cs193v python3 -m http.server 21000 --bind 127.0.0.1; sleep 3
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:21000/)
[ "$c" = 200 ] && echo "PASS loopback-bound reachable" \
              || echo "FAIL loopback-bound UNREACHABLE ($c) — the tunnel is not working here"

# ...and a 0.0.0.0-bound one must STILL be reachable. The tunnel is a superset, so this is
# the no-regression half: it is what worked before the change.
podman exec -d cs193v python3 -m http.server 21001 --bind 0.0.0.0; sleep 3
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:21001/)
[ "$c" = 200 ] && echo "PASS wildcard-bound still reachable" \
              || echo "FAIL wildcard-bound REGRESSED ($c)"

# AND IT GOES AWAY AGAIN. The other half of the lifecycle, and the one a fixed list could not
# have: kill the server and the host port must be handed back. A few ticks, deliberately, so a
# restarting dev server does not flap.
podman exec cs193v pkill -f 'http.server 21000'; sleep 8
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:21000/)
[ "$c" = 000 ] && echo "PASS the host port was released" \
              || echo "FAIL 21000 still answers ($c) — a forward outlived its server"

# a port with NOTHING listening inside must be refused. Note this is the case that inverted:
# it used to be tested by binding a port OUTSIDE the declared set, which would now simply get
# it forwarded. Bind nothing.
for p in 21100 21101 21102; do
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$p/")
  [ "$c" = 000 ] && echo "PASS nothing-listening $p refused" || echo "FAIL $p reachable ($c)"
done

# ::1 alone is the one loopback address the tunnel cannot reach, since the far end is IPv4 --
# and the REASON must reach the student, which is the half that used to be missing.
podman exec -d cs193v python3 -c 'import http.server,socket,socketserver
class S(socketserver.TCPServer): address_family=socket.AF_INET6; allow_reuse_address=True
S(("::1",21002),http.server.SimpleHTTPRequestHandler).serve_forever()'; sleep 3
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:21002/)
[ "$c" = 000 ] && echo "PASS ::1-only is refused, as documented" \
              || echo "NOTE ::1-only is reachable ($c) — better than documented, update the docs"
podman exec cs193v grep -q '^refused	21002	v6lo' /tmp/cs193v/ports \
  && echo "PASS and the reason is recorded" || echo "FAIL no v6lo reason for 21002"
podman exec cs193v cs193v-portwatch --show      # expect 21002 under "Not reachable, and why"

# the direction invariant, tested rather than asserted: a remote forward must be REFUSED by
# the server, and must create no listener
CTL="$(ls "${TMPDIR:-/tmp}"/cs193v-*.ctl 2>/dev/null | head -1)"
ssh -S "$CTL" -O forward -R 127.0.0.1:21900:127.0.0.1:21001 student@cs193v-tunnel 2>&1 \
  | grep -q 'forwarding request failed' && echo "PASS -R refused" || echo "FAIL -R was ACCEPTED"
[ "$(ss -ltn | grep -c ':21900')" = 0 ] && echo "PASS no listener created" \
                                        || echo "FAIL something is listening on 21900"

# and the tunnel must not be usable as a proxy past the container's own loopback
ssh -S "$CTL" -O forward -L 127.0.0.1:21901:1.1.1.1:80 student@cs193v-tunnel 2>/dev/null
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:21901/)
[ "$c" = 000 ] && echo "PASS PermitOpen blocks off-box destinations" \
              || echo "FAIL the tunnel proxied to 1.1.1.1 ($c)"
ssh -S "$CTL" -O cancel -L 127.0.0.1:21901:1.1.1.1:80 student@cs193v-tunnel 2>/dev/null

# a busy HOST port must cost that port only, and must say so. Hold it out here first, then ask
# for it in there -- the refusal now arrives mid-session, per port, rather than at launch.
python3 -c 'import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("127.0.0.1",21200)); s.listen(1); time.sleep(60)' &
sleep 1; podman exec -d cs193v python3 -m http.server 21200 --bind 127.0.0.1; sleep 5
podman exec cs193v grep -q '^refused	21200	busy' /tmp/cs193v/ports \
  && echo "PASS the busy port is named, with a reason" || echo "FAIL busy port not reported"
"$DIR/cs193v" doctor | grep -q 'busy: 21200' \
  && echo "PASS doctor names it too" || echo "FAIL doctor missed it"
kill %1 2>/dev/null
podman exec cs193v pkill -f http.server

# `ss` inside the container must name the bind address, which is what a student has to be able
# to read to tell a reachable server from an unreachable one.
podman exec -d cs193v python3 -m http.server 21300 --bind 127.0.0.1
podman exec -d cs193v python3 -m http.server 21301 --bind 0.0.0.0
podman exec cs193v ss -ltn
   # expect: 127.0.0.1:21300  loopback-bound  -> reachable
   #         0.0.0.0:21301    wildcard-bound  -> reachable
   #         [::1]:PORT       the one address the tunnel cannot reach
   # what is forwarded is host-side, but the container can now see the verdict:
podman exec cs193v cs193v-portwatch --show
podman exec cs193v pkill -f http.server
podman exec cs193v pkill -f SimpleHTTP

# host side must be loopback-only, not LAN-exposed
podman exec -d cs193v python3 -m http.server 21400 --bind 0.0.0.0; sleep 3
(ss -ltn 2>/dev/null || netstat -an) | grep ':21400'   # expect 127.0.0.1:21400, NOT 0.0.0.0 or *
LANIP=$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://$LANIP:21400/")
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
#
# NO on-the-fly `apt-get install inotify-tools` here any more, and that line leaving is the point
# of #39: it was covering for the package being absent from the image, which is why the automated
# form of this check (60-container.sh) guarded itself out of existence and never ran once. The
# package is in layer 1 of the Containerfile now, so a missing inotifywait is a finding.
#
# AND STDERR GOES SOMEWHERE ELSE, with the event named rather than counted. Both redirects here
# used to be `2>&1` into the file `test -s` then examined, so with inotifywait missing the shell's
# own "not found" satisfied the check — measured, both halves passed and the host-side line
# reported FIRES off that one error string.
ckx inotifywait-installed  sh -c 'podman exec cs193v sh -c "command -v inotifywait"'
podman exec -d cs193v sh -c 'inotifywait -q -e modify /home/student/projects/.vt-c > /tmp/vt-in 2>/tmp/vt-in.err'
sleep 1; E 'echo x >> /home/student/projects/.vt-c'; sleep 1
ckx inotify-container-side  sh -c 'podman exec cs193v grep -q MODIFY /tmp/vt-in'

# inotify, HOST-side edit — expected to FAIL on macOS and WSL; RECORD which
E 'rm -f /tmp/vt-in /tmp/vt-in.err'
podman exec -d cs193v sh -c 'inotifywait -q -e modify /home/student/projects/.vt-c > /tmp/vt-in 2>/tmp/vt-in.err'
sleep 1; echo y >> "$DIR/projects/.vt-c"; sleep 2
podman exec cs193v grep -q MODIFY /tmp/vt-in && echo "host-side inotify: FIRES" \
                                             || echo "host-side inotify: DOES NOT FIRE"

# case sensitivity — determines whether a Mac student's import bug reproduces
E 'cd /home/student/projects && touch Aa && (ls aA >/dev/null 2>&1 && echo CASE-INSENSITIVE || echo case-sensitive)'

# quantify the bind-mount penalty per platform
time E 'mkdir -p /home/student/projects/.vt-many && cd /home/student/projects/.vt-many && for i in $(seq 1 2000); do : > f$i; done'
time E 'rm -rf /home/student/projects/.vt-many'
```

## A.8 The SIGHUP matrix — the disputed question, automated

> **REFRAMED BY ISSUE #41.** The matrix below still runs and still comes back `alive=yes` for every
> shape, but it no longer answers the question in this heading, and the simulation it uses is no
> longer the right one.
>
> Killing the `podman exec` client modelled a closed window only while the launcher `exec`'d into
> podman. It does not now: the launcher stays resident for the session, so a closing window signals
> the **launcher**, whose trap stops the whole container. Killing the client instead leaves the
> launcher alive and the container up — a real state (a force-quit) but not this one.
>
> So the probes below now measure what happens when a **tab** closes, inside a container that stays
> up, and they are recorded rather than asserted (`sighup:tab-matrix-*`). The window-closing question
> is answered by destroying the pty, which HUPs the foreground process group exactly as a terminal
> does; `70-sighup.sh` does that and asserts the container stops, the 46 forwards come back, and a
> server in a tab dies with it. The one thing still not automatable is the actual close button — see
> §5.1, which is now the most important manual check in `tests/MANUAL.md`.

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
for v in doctor --dev-print-command; do
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
                   <(sed 's/#.*//' "$DIR/container.args" 2>/dev/null \
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
```

## A.13 Performance baseline — record, do not assert

```sh
# Needs ~8 GB free; see ERRORS.md B5 for why that is nearly twice what the build retains.
# Reference baseline, x86-64 with fast network — a student on dorm wifi is bounded by the
# 728 MB rather than by the CPU, so expect wall time to scale with their link:
#     cold build + container create   224 s, 728 MB, 4.1 GB peak / 4.3 GB retained
#     CLAUDE_CODE_VERSION bump         89 s,  95 MB
#     --rebuild --logout                6 s,   0 MB   (re-seeds the 267 MB browser locally)
time "$DIR/cs193v" --rebuild --no-cache      # cold build; note wall time AND peak disk
time "$DIR/cs193v" --rebuild                 # container create only — the recipe has not moved
time "$DIR/cs193v" --dev-print-command       # launcher overhead, NO podman calls: expect ~60 ms
# WHY THAT NUMBER MOVED. It was 511 ms until #57, and all but ~60 ms of it was load_args forking
# `sed` once per line of container.args -- 239 forks for 11 lines that carry an argument. Count the
# forks rather than trusting the clock on a loaded machine; 16-args-parse.sh does this portably,
# through a shim, because a Mac has no strace.
strace -f -e trace=execve "$DIR/cs193v" --dev-print-command 2>&1 >/dev/null \
  | grep -c 'execve("/usr/bin/sed'          # expect 11 -- one per line with content, not per line
time podman exec cs193v true                 # exec overhead — relevant to the rejected relay design
time E 'cd /home/student/projects && npm init -y >/dev/null && npm i --silent lodash'
```

## A.14 Cleanup assertions

```sh
rec containers podman ps -a --format '{{.Names}}'          # expect only cs193v
rec volumes    podman volume ls --format '{{.Name}}'        # expect only the cs193v-* set
rec images     podman images --format '{{.Repository}}:{{.Tag}}'
rm -f "$DIR"/projects/.vt-*
echo "A-battery: PASS=$PASS FAIL=$FAIL"
```

## A.15 Vacuity audit — differential sabotage (run by hand; deliberately not a tier)

**What it answers:** which assertions PASS when the thing that computes their verdict never ran.
Reading for them does not work — three sweeps plus #78 missed the twenty-six this found in two
runs — because at the call site there is nothing to see. `assert_eq NAME "" "$(... |
box_problems)"` is correct code whose happy answer is the empty string, and a checker that dies
prints exactly that.

Put a fake `python3` first on `$PATH` and run the cheap lane twice, against a baseline:

* **death** — traceback to stderr, exit 1. What a crash looks like.
* **poison** — prints `SABOTAGEPOISON` to stdout, exit 0. What "the checker ran and disagreed"
  looks like.

`pass(death) ∩ fail(poison)` is then exactly the vacuous set: verdicts that *depend* on the
checker's output yet *pass* when it dies.

```sh
S=$(mktemp -d); mkdir -p "$S/death" "$S/poison"
printf '#!/bin/sh\nprintf "Traceback\\n" >&2\nexit 1\n' > "$S/death/python3"
printf '#!/bin/sh\necho SABOTAGEPOISON\nexit 0\n'         > "$S/poison/python3"
chmod 755 "$S"/*/python3

leg() {                               # leg NAME [DIR-TO-PREPEND-TO-PATH]
  export CS193V_RESULTS="$S/res-$1.tsv"; : > "$CS193V_RESULTS"
  for f in .private/tests/[0-9][0-9]-*.sh; do
    case "$(sed -n 's/^#[[:space:]]*TIER:[[:space:]]*\([a-z]*\).*/\1/p' "$f" | head -1)" in
      static|unit|shim) CS193V_SUITE="$(basename "$f")" PATH="${2:+$2:}$PATH" bash "$f" \
                            > "$S/log-$1-$(basename "$f" .sh).txt" 2>&1 ;;
    esac
  done
  printf '%-9s pass %-5s fail %s\n' "$1" \
         "$(grep -c '^PASS	' "$CS193V_RESULTS")" "$(grep -c '^FAIL	' "$CS193V_RESULTS")"
}
leg baseline; leg death "$S/death"; leg poison "$S/poison"

sel() { awk -F'	' -v s="$1" '$1 == s { print $2 "	" $3 }' "$S/res-$2.tsv" | LC_ALL=C sort -u; }
LC_ALL=C comm -12 <(sel PASS death) <(sel FAIL poison)      # THE VACUOUS SET — must be empty
```

**Measured on `740a14f`, before the fix (#79):**

| run | pass | fail |
| --- | --- | --- |
| baseline | 1167 | 0 |
| death | 1106 | 61 |
| poison | 1094 | 73 |

16 assertions in the difference, all confirmed by reading, across `20-messages.sh`,
`30-launcher-shim.sh` and `35-setup-git-shim.sh`. The classifier has a **measured blind spot**:
`assert_not_contains` never appears in `fail(poison)`, because no generic marker contains an
arbitrary needle — but 10 such assertions in `30-launcher-shim.sh` are fed by `render_pty` and
all 10 passed in the death run. **≥26 live vacuous passes in the cheap lane, from python3 alone.**

**Measured after the fix, same recipe:**

| run | pass | fail |
| --- | --- | --- |
| baseline | 1186 | 0 |
| death | 577 | 8 |
| poison | 577 | 8 |

Vacuous set: **empty**. The pass counts drop because `require_python3` now stops
`10-static.sh`, `20-messages.sh`, `30-launcher-shim.sh` and `35-setup-git-shim.sh` at the door
rather than letting them run on an interpreter that cannot answer.

**RUN IT WITH THE DOOR TAKEN OFF AS WELL, and this is the leg that answers the question.** Stub
`require_python3` to `return 0` in a copy of the tree and repeat: what is then measured is whether
each ASSERTION is protected, rather than whether the suite aborted before reaching it. This is the
number to compare against the 1106/61 above, since `require_python3` did not exist then.

| run | pass | fail |
| --- | --- | --- |
| death, no door | 1055 | 131 |
| poison, no door | 1081 | 105 |

Vacuous set with the door removed: **empty**.

**Some of the failures in each sabotage leg are the FIXTURE, not a checker**, and knowing which saves the
next person the hunt. `lib/podman-shim.sh` builds the launcher's control socket with python3, so
`ack:a-quiet-launch-*` in `30-launcher-shim.sh` cannot pass without one; and two assertions in
`14-test-harness.sh` — the control run and `python3:a-real-interpreter-passes-the-guard` — exist
precisely to check that a REAL interpreter still works, so a sabotaged `$PATH` is supposed to
redden them.

**Why it is not a tier.** `lane_of` in `run-tests.sh` routes any unrecognised tier to the
**podman** lane, so a `sabotage` tier would serialise behind a container it has nothing to do
with; `DEFAULT_TIERS` would have to exclude it, and an unrun gate is the same defect as
`60-container.sh`'s inotify assertion that had never once executed. The durable half is
`14-test-harness.sh`'s checker fixture — both shapes plus the poisoned interpreter, in
milliseconds, in the cheap lane, on every run.

**Do not extend the sabotage past python3.** `sed` poisons `tier_of`, so the two legs stop
containing the same suites; `grep` backs `count()`, which then reports `0 pass` and exits 0;
`awk` is the subject under test in three suites; and `jq` appears nowhere outside `gh --jq`.

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
with `/bin/bash` explicitly, and run `.private/tests/run-tests.sh --tier unit`.
*Expect:* no `mapfile`, associative-array, or `${x,,}` errors, and a green unit tier.

**GLOB AND PATTERN BEHAVIOUR CAN ONLY BE SETTLED HERE, and §A.1 cannot help.** That grep catches bash
4 *syntax* — a construct that is a parse error on 3.2. It is blind to one that parses on both and
**matches different strings**, and shell pattern matching is where that lives: a POSIX character class
inside a `case` bracket (`case "$line" in *[![:space:]]*)`), a quoted nested pattern
(`${line#"${line%%[![:space:]]*}"}`), and bracket expressions generally. Nothing in the gates runs bash
3.2 — the CI and every dev machine is Linux with bash 5 — so a construct like that ships on the
strength of an argument unless a person runs it on a Mac. Any change that adds or edits one needs this
check before it ships; §A.1 has the greps that find them.

Live example, for whoever reads this next: `load_args`' whitespace guard. Issue #57's measurement work
found the launcher forking `sed` once per line of `container.args` — 239 forks, ~700 ms of a ~1.8 s
startup — and the fix is a `case "$line" in *[![:space:]]*)` guard that skips the 228 comment and blank
lines. The class *semantics* were verified equivalent to `sed`'s on Linux (all 254 byte values × `C`,
`C.UTF-8`, `en_US.UTF-8`, zero disagreements), which is the easy half. Whether bash 3.2 reads
`[![:space:]]` inside a `case` bracket the same way is the half no Linux run can answer.

**1.4 — Version floor.** If podman < 5.7.0 is available, or via the shim in §A.10:
*Expect:* the launcher refuses, names the platform-specific fix, exits non-zero, and creates nothing.

**1.5 — Refuses to run as root.** `sudo ./cs193v`
*Expect:* a clear refusal explaining that this would run podman rootful and defeat the isolation model.

**1.6 — `/etc/subuid` populated.** `grep "^$(id -un):" /etc/subuid /etc/subgid`
*Expect:* a range for the current user. If absent, the installer should have offered to add it with
consent — confirm it did rather than failing with a raw podman error.

**1.7 — Flag parsing is faithful.** `./cs193v --dev-print-command`
*Expect:* every flag in `container.args` appears in the printed `podman run` line, with no flag
mangled by quoting. This is the first thing to ask a student for in any support thread, so it must
be trustworthy.

`./cs193v --dev-args` prints the same parse one word per line, which is what makes a word BOUNDARY
visible — `--dev-print-command` joins the words with spaces, so it cannot distinguish one word holding
a space from two words, and a word that is a bare `\r` does not show in it at all. That verb is the seam
`16-args-parse.sh` drives; it is automated there against a corpus of CRLF, whitespace-only, indented
comment and no-trailing-newline files, so the by-hand version is only worth running when the parse
itself is what you changed.
*Expect:* one word per line, no blank lines, and the words in `container.args` order.

---

## 2. Container lifecycle

**1.8 — podman installed but not on PATH (macOS only; issue #121).** In the terminal window the
installer ran in, without closing it: `./cs193v doctor`, then `./cs193v`
*Expect:* the podman version, a `podman path` line naming the binary, and the two notes
(`NOT on your PATH — cs193v added its directory itself`, and the `/etc/paths.d` explanation);
then a normal launch. **This is the case that shipped the bug** — before the fix it was the
`err.no-podman` STOP box, over an installation that had just reported success.

Then, in a *new* window, the same `doctor`: *expect* the same version and **no** notes, since
`path_helper` has run at login. And `zsh -c "$PWD/cs193v doctor"`: *expect* the notes back — a
non-login shell never reads `/etc/paths.d`, which is the student a new terminal never helps and
the reason the launcher repairs its own PATH rather than the installer printing advice.

Automated as far as it can be: `25-installer.sh :: probe:*` drives the repair's whole truth
table against both copies of `ensure_podman_path`, and `30-launcher-shim.sh :: probe:*` drives
`doctor` and a launch against a fabricated receipt, including the Linux case where the repair
must NOT fire. What no fixture can answer is whether the real `.pkg` still puts things where its
own receipt says — `tests/MANUAL.md` has that check, and it belongs to a
`PODMAN_MACOS_VERSION` bump.

**2.1 — First launch.** `./cs193v`
*Expect:* container created and a shell opens. Note wall-clock time to first prompt — and that
`Entering the CS193V development environment...` appears *immediately*, before that wait rather
than after it (issue #57). What is being timed is the gap between that line and the prompt.

**2.2 — Multiple shells.** Open three more terminals, run `./cs193v` in each.
*Expect:* all four attach to the **same** container. `podman ps` shows exactly one. No refusal — the
"second instance" refusal applies to a second *container*, not a second window.

**2.3 — `--rebuild` preserves logins.** Log in to `claude` and `gh`, then `./cs193v --rebuild`.
*Expect:* container recreated; both logins still valid; `projects/` untouched.

**2.4 — `--rebuild --logout` drops logins.** `./cs193v --rebuild --logout`
*Expect:* NO confirmation prompt — the modifier says what it does, which is why the prompt
`--full-rebuild` had was dropped with it. Afterwards both logins are gone and `projects/` is
still untouched.

**2.5 — Config-drift detection.** See §A.10. **This is a known podman behaviour trap** — `podman start`
reuses the container's stored config and ignores the image digest, ports and `keep-id` alike.
If this fails, every student's flags are frozen at first run and edits to `container.args` never
reach them.

**2.6 — Stale-image detection.** Touch the recipe — add a comment line to
`.private/Containerfile` — then `./cs193v`.
*Expect:* a prompt to rebuild rather than silently continuing on the old image. This is the
`cs193v.buildhash` label doing the job the digest pin used to do; the image ID cannot,
because podman mints a new one on every build including a no-op rebuild.

**2.7 — Two copies refused.** See §A.10.

**2.8 — PID 1 reaps.** After a few hours of normal use: `cs193v doctor`, `zombies` line.
*Expect:* `0 unreaped`. Ask the question by PARENT, not by count: a zombie reparented onto PID 1
is PID 1's to collect, and one whose parent is alive and is not PID 1 — sshd holds exactly one
while the tunnel is up — is not reachable by any init. The shell keep-alive loop is PID 1; if the
ones it owns accumulate they will eventually exhaust `pids.max` (2048) and **wedge** the container
so `podman exec` cannot get in. A bare `grep -c Z` cannot see that difference and reports a
healthy container as a faulty one.

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

**5.1 — Closing a terminal window, for real.** Since #41 this is the check the feature rests on, and
the full procedure now lives in `tests/MANUAL.md` §5.1. In short: start a server in a tab, reach it
from the browser, click the window's close button, and confirm the container goes to `exited`, the 46
forwards are released, and the next `./cs193v` reuses the same container with fresh tabs.

Automated and green on Linux, where `70-sighup.sh` destroys the pty — the same mechanism a terminal
uses. What no automation can do is press the button, and **what no Linux run can answer is macOS and
WSL**, where the `podman exec` client lives outside the VM. Do it on Terminal.app, iTerm2 and WSL, and
force-quit each of them too: expect a container left running, explained by the next `./cs193v` and
cleared by `--stop`.

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

**5.4b — Windows stage one, from one downloaded file (issue #93).** On a Windows box with **no
`install-cs193v.sh` anywhere on it**, download only `install-cs193v-windows.cmd`, right-click, Run
as administrator.
*Expect:* it prints the `raw.githubusercontent.com` URL, fetches stage two into the environment,
and hands off — no "could not find install-cs193v.sh next to this file", because that arm no
longer exists. Then check all four of these, because the whole suite fakes `wsl.exe` and can
reach none of them:
- `wsl -d CS193V -e curl --version` answers. If curl is absent, stage one apt-installs it: confirm
  that runs **without a password prompt and without a debconf question**.
- `wsl -d CS193V -e ls -l /tmp/install-cs193v.sh` — the script it ran is still there, and is the
  published one. `shasum -a 256` it against the course website's value.
- The long `-e` line is forwarded intact: `wsl -d CS193V -e curl -fsSL --retry 10 --retry-delay 3
  -o /tmp/x <url>` must fetch, not have `--retry` eaten by `wsl.exe` itself.
- `raw.githubusercontent.com` resolves **from campus wifi and from a dorm room**, not only from a
  staff machine. It is a different host from the `codeload.github.com` stage two itself uses.

**5.5 — cgroup delegation in WSL.** With `systemd=true` in `/etc/wsl.conf`, run §A.5's
`cgroup-pids` check.
*Expect:* a number, or `max`. An unreadable value means the rootless user got no delegated cgroup,
so podman is managing no resources at all and `--pids-limit` would be accepted and ignored.

**5.7 — The curl probe, on a Mac.** `survey` now probes curl the way it probes ssh, because curl is
absent from the Ubuntu **desktop** image (the 26.04 and 24.04 manifests carry `wget` and `libcurl4t64`
and no `curl`) while the WSL image and macOS both ship it. Only half of that is checkable off a Mac.
*Expect:* `✓ curl` in the survey, before the consent screen, and no consent item for it.
*Unmeasured, and it stays that way:* the refusal arm — "curl is missing from this Mac, which should not
be possible" — is the one installer line no tier can execute. The shim tier prepends to `PATH` and
cannot hide a real `/usr/bin/curl`; the machine where curl CAN be removed is Linux, where that arm is
not taken. It is in `tests/fixtures/coverage-allowlist` with that as its reason. If a Mac ever does
reach it, that is the interesting result and staff want to hear about the machine.

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
*Expect:* a URL is **printed** and a device/paste code flow completes. Nothing is *published* with
`-p`, deliberately, but the ssh tunnel forwards any port a program binds inside the container to
the same port on host loopback, so an OAuth callback on a random ephemeral port **is** reachable —
the claim that used to sit here, that a redirect-only flow must fail, stopped being true when the
tunnel landed (#82), and it is no longer limited to a declared set either. Known and measured, so do not re-diagnose it from a 298 MB binary: Claude Code consults
`$BROWSER` and really does run the stub, but captures its stdout, so the box is discarded and what
you see is Claude's own full-length URL. `podman exec <container> pgrep -af '[s]hortlink'` confirms
the stub ran. `tests/MANUAL.md` §8.1 is the fuller account.

**8.2 — `gh`, `vercel` and `codex` login.** `gh auth login`, then `vercel login`, then
`codex login`. Codex's callback on `localhost:1455` needs nothing arranged for it, so try its
browser flow before reaching for `--device-auth`. If the redirect flow completes, say so — that is
the measurement #82 asks for, and the same question is open for the other two.
*Expect:* all three complete with a printed URL or emailed code. During `gh auth login`, answer
**yes** to "Authenticate Git with your GitHub credentials?" and then confirm `git push` works from
a test repo.

**8.7 — A permission prompt in the wild.** Ask the agent to do something that triggers a prompt.
*Expect:* the prompt is comprehensible to a first-year student. Record the wording; this is the moment
the course's core skill is taught.

---

## 9. Teardown

**9.1 — Volumes survive an image update.** `./cs193v --rebuild` after editing the
Containerfile. *Expect:* the image rebuilds because the recipe moved, the container is
recreated, and logins are intact. Run it a second time with nothing edited and *expect* no
build at all — that is the hash gate, and it is what makes one verb serve both jobs.

**9.2 — Full reset is clean.** `./cs193v --rebuild --logout`; confirm `podman volume ls` shows all
`cs193v-*` volumes gone.

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

§1  install/preflight   1.1 __  1.2 __  1.3 __  1.4 __  1.5 __  1.6 __  1.7 __  1.8 __
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
  5.5 cgroup delegation — is a rootless cgroup delegated at all?

SURPRISES (passed, but not as expected):

TIMINGS: cold build ____ (peak disk ____)   first launch ____   subsequent launch ____   --rebuild ____
         (x86-64 reference: 224 s / 4.1 GB peak, 4.3 GB retained. Compare, do not assume.)
```
