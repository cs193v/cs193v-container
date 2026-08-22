#!/usr/bin/env bash
# TIER: image
#
# VERIFICATION.md §A.2 and §A.3 — what is actually inside the built image.
#
# Everything here runs in throwaway containers, so it needs the image but never the live
# cs193v container. Build it first:
#
#     ./cs193v --rebuild
#
# Two of §A.3's checks are corrected rather than copied:
#   * nvm-not-group-writable was vacuous. /usr/local/share/nvm does not exist by design —
#     node comes from the official tarball into root-owned /usr/local precisely so there is
#     no group-writable nvm tree to trojan — so `stat` failed, the case fell through to the
#     catch-all, and it printed "ok" while asserting nothing. Here it asserts the absence.
#   * the multi-arch manifest assertion moved to the release tier: a locally built image is
#     single-arch by definition, so asserting two architectures here can only ever fail.
#
# §A.2's per-layer size ceiling is deliberately NOT here. See issue #7 in ERRORS.md B9: the
# requirement that no layer exceed 400 MB was withdrawn, not met. Layer ORDER is still
# load-bearing and still tested, in 10-static.sh.

set -u
. "$(dirname -- "$0")/lib/assert.sh"

require_image
cd "$REPO" || exit 1

# ─── §A.2 image metadata ───────────────────────────────────────────────────────
assert_eq "img:runs-as-student" "student" \
          "$(podman image inspect "$TEST_IMAGE" --format '{{.User}}')"
record    "img:size-bytes"  "$(podman image inspect "$TEST_IMAGE" --format '{{.Size}}')"
record    "img:layer-count" "$(podman image inspect "$TEST_IMAGE" --format '{{len .RootFS.Layers}}')"
record    "img:architecture" "$(podman image inspect "$TEST_IMAGE" --format '{{.Architecture}}')"

env_json="$(podman image inspect "$TEST_IMAGE" --format '{{json .Config.Env}}')"
for want in "EDITOR=nano" "VISUAL=nano" "PAGER=less" "LESS=FRX" \
            "BROWSER=/usr/local/bin/open-url" "LANG=en_US.UTF-8"; do
    assert_contains "img:env-has-$want" "$want" "$env_json"
done
# HOST and FLASK_RUN_HOST must stay GONE. They existed only to push servers onto 0.0.0.0,
# because podman's forwarder never reached the container's loopback; the ssh tunnel does, so
# they nudge nothing and would only be an unexplained environment variable that quietly
# changes what a student's server binds to. Asserted as an absence for the same reason
# GIT_EDITOR is: the tempting change is to add it back, so that has to break something.
for forbidden in "HOST=" "FLASK_RUN_HOST="; do
    assert_not_contains "img:no-$forbidden" "$forbidden" "$env_json"
done
# GIT_EDITOR must stay unset. With GIT_EDITOR, core.editor, VISUAL and EDITOR all unset,
# `git var GIT_EDITOR` returns vi and /usr/bin/vi is vim.tiny, which strands a first-year
# student in a modal editor on `git commit` with no visible way out. It is fixed via
# EDITOR/VISUAL rather than GIT_EDITOR so git itself stays stock.
assert_not_contains "img:no-GIT_EDITOR" "GIT_EDITOR" "$env_json"

assert_contains "img:entrypoint-is-the-keepalive" "cs193v-entrypoint" \
                "$(podman image inspect "$TEST_IMAGE" --format '{{json .Config.Entrypoint}}')"
assert_eq "img:workdir-is-the-projects-mount" "/home/student/projects" \
          "$(podman image inspect "$TEST_IMAGE" --format '{{.Config.WorkingDir}}')"

# ─── §A.3 identity and ownership ───────────────────────────────────────────────
assert_eq "uid-gid-name" "1000 1000 student" "$(R 'echo $(id -u) $(id -g) $(id -un)')"
record    "passwd-student" "$(R 'getent passwd student')"
assert_eq "home-is-student" "/home/student" "$(R 'echo $HOME')"

# The load-bearing one. podman auto-chowns an EMPTY named volume to the container user on
# first mount, then re-chowns it to match the image's directory at the mount target if that
# directory exists — so a root-owned target yields a root-owned volume AND permanently
# disables further auto-chown. Getting these five right in the image is what lets the
# entrypoint run with no root phase and no `sudo chown -R`.
assert_eq "vol-targets-are-student-owned" "student student student student student student" \
    "$(R 'stat -c %U /home/student/.claude /home/student/.claude-json /home/student/.codex \
                     /home/student/.config/gh /home/student/.config/git \
                     /home/student/.local/share/com.vercel.cli \
          | tr "\n" " " | sed "s/ $//"')"
# And they must exist before any volume is mounted, or podman creates them root-owned.
for d in .claude .claude-json .codex .config/gh .config/git .local/share/com.vercel.cli .local/bin; do
    assert_ok "vol-target-exists:$d" sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'test -d /home/student/$d'"
done
assert_eq "projects-mount-is-student-owned" "student" "$(R 'stat -c %U /home/student/projects')"

# ─── tooling that must be present ──────────────────────────────────────────────
# stty is in that list because setup-git's token prompt turns echo off with it (issue #53). It comes
# from coreutils and cannot plausibly be missing — which is the argument for asserting it rather than
# assuming it, since a base image that dropped it would be discovered by a student pasting a
# credential onto a visible screen.
for cmd in node npm python3 git gh vercel claude codex nano less sudo tldr curl unzip ssh scp telnet stty shortlink; do
    assert_ok "have:$cmd" sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'command -v $cmd'"
done
record "versions" "$(R 'node -v; npm -v; python3 -V; gh --version | head -1; vercel --version; claude --version; codex --version' | tr '\n' ' ')"

# ─── ssh, scp and telnet really work  (issue #2) ───────────────────────────────
# Not just "the binary is on PATH". The course reason for each of these is a round trip:
# logging into a remote machine, copying a file across, and typing an HTTP request at a web
# server by hand. So each one is exercised for real, against a server started inside the
# same throwaway container — --network=none throughout, so nothing here needs the internet
# and every connection is over the container's own loopback.
#
# apt-mark comes first, because it is the assertion that says this is DELIBERATE. `ssh` and
# `scp` were in the image long before anyone chose them: openssh-server Depends on
# openssh-client, so they arrived as a dependency while the Containerfile said they were
# absent. `showmanual` is exactly the difference between "we asked for this" and "something
# else happened to need it", and only the first is a promise.
manual="$(R 'apt-mark showmanual 2>/dev/null')"
assert_contains "net:openssh-client-is-installed-on-purpose" "openssh-client"   "$manual"
assert_contains "net:telnet-is-installed-on-purpose"         "inetutils-telnet" "$manual"
# Same argument for the two that answer "what is my server actually listening on?". The base
# image ships neither, and without them the only way to see a listening socket is to decode
# /proc/net/tcp by hand -- which is not something to ask a student, or an agent, to do.
assert_contains "net:iproute2-is-installed-on-purpose"       "iproute2"         "$manual"
assert_contains "net:lsof-is-installed-on-purpose"           "lsof"             "$manual"
# And the packages have to have produced the COMMANDS. `ss -ltn` names the bind address, which
# is the half that decides whether the tunnel can reach it; `lsof -i` names the process, which
# is the half that says what to stop. ss is run for real rather than merely located, because it
# is the one a student is told to type; lsof exits non-zero when it matches nothing, so asking
# it to list sockets in an idle container would fail for the wrong reason.
assert_ok "net:ss-lists-listeners" \
          sh -c "$VT_RUN --rm --network=none --entrypoint sh '$TEST_IMAGE' -c 'ss -ltn'"
assert_ok "net:lsof-is-on-PATH" \
          sh -c "$VT_RUN --rm --network=none --entrypoint sh '$TEST_IMAGE' -c 'command -v lsof'"

# sshd runs UNPRIVILEGED here, as student, which is what the tunnel's own sshd does too
# (see files/sshd_config). It is not a stylistic choice: started as root it refuses the
# student account outright, because useradd left that account with no password and a root
# sshd reads a locked password field as "no login allowed".
#
# The Subsystem line is not optional either. OpenSSH 9 and later carry scp over SFTP, so
# without it `ssh` succeeds and `scp` fails with a bare "Connection closed" — which looks
# like a broken scp rather than a missing subsystem.
sshout="$(timeout 240 $VT_RUN --rm --network=none --entrypoint bash "$TEST_IMAGE" -c '
set -e
cd /tmp
ssh-keygen -q -t ed25519 -N "" -f hostkey && chmod 600 hostkey
ssh-keygen -q -t ed25519 -N "" -f userkey
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cp userkey.pub ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
{
  echo "Port 2222"
  echo "ListenAddress 127.0.0.1"
  echo "HostKey /tmp/hostkey"
  echo "AuthorizedKeysFile /home/student/.ssh/authorized_keys"
  echo "PasswordAuthentication no"
  echo "UsePAM no"
  echo "PidFile /tmp/sshd.pid"
  echo "AllowUsers student"
  echo "Subsystem sftp /usr/lib/openssh/sftp-server"
} > /tmp/sshd.conf
/usr/sbin/sshd -f /tmp/sshd.conf
sleep 1
OPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /tmp/userkey"
ssh -q $OPT -p 2222 student@127.0.0.1 "echo SSH-ROUND-TRIP-OK"
echo scp-payload > /tmp/src.txt
scp -q $OPT -P 2222 /tmp/src.txt student@127.0.0.1:/tmp/dst.txt
printf "SCP-GOT:%s\n" "$(cat /tmp/dst.txt)"
' 2>&1 || true)"
assert_contains "net:ssh-can-log-into-a-remote-machine" "SSH-ROUND-TRIP-OK"   "$sshout"
assert_contains "net:scp-can-copy-a-file-across"        "SCP-GOT:scp-payload" "$sshout"

# And telnet against a real web server, because seeing what an HTTP request looks like when
# you type it yourself is the whole reason it is installed.
#
# Two traps here, both of which cost this test a red run before it was right, and both of
# which a student scripting telnet will hit too:
#
#  * Send LF, NOT CRLF. telnet speaks NVT, where a bare CR must go out as CR NUL and only a
#    LF becomes CR LF on the wire. So `printf "GET / HTTP/1.0\r\n\r\n"` arrives at the
#    server as "GET / HTTP/1.0\x0d\x00" and is answered with 400 Bad request version.
#    Pressing Enter in an interactive telnet sends LF, which is why this works by hand and
#    fails in a pipe — write what the keyboard would send.
#
#  * Hold stdin open afterwards. telnet exits as soon as its input reaches EOF, and with a
#    plain `printf | telnet` that happens before the server's reply comes back, so the
#    output is the three connection lines and nothing else.
telout="$(timeout 120 $VT_RUN --rm --network=none --entrypoint bash "$TEST_IMAGE" -c '
python3 -m http.server 8099 --bind 127.0.0.1 >/dev/null 2>&1 &
i=0
while [ "$i" -lt 20 ]; do
    curl -s -o /dev/null http://127.0.0.1:8099/ && break
    sleep 0.5
    i=$((i + 1))
done
{ printf "GET / HTTP/1.0\n\n"; sleep 3; } | telnet 127.0.0.1 8099 2>&1
' 2>&1 || true)"
assert_contains "net:telnet-reaches-a-web-server"  "Connected to 127.0.0.1" "$telout"
# The status line is the point of the exercise: it is what a student is meant to SEE coming
# back when they type a request by hand.
assert_contains "net:telnet-shows-the-http-response" "HTTP/1.0 200 OK" "$telout"
# ─── Python: the floor works, and it is only a floor  (issue #44) ──────────────
# This section replaced a single `numpy-imports` assertion. numpy is gone — nothing in the image
# imported it, and one apt-managed library beside a pip-installed set is the state that misleads
# — so what has to be tested now is not which libraries are here but that a student can get any
# library they want, without sudo and without a flag.
#
# ALL OF IT RUNS --network=none, deliberately. `pip install <real package>` would test the
# internet as much as the image, and the suite's tldr tests already establish that offline is
# the standard for this file. --no-index makes pip do everything except reach an index, so the
# only two outcomes are the two this distinguishes.
pipout="$($VT_RUN --rm --network=none --entrypoint sh "$TEST_IMAGE" \
          -c 'pip3 install --no-index tabulate 2>&1' || true)"
# THE ASSERTION #44 IS ABOUT. Without PIP_BREAK_SYSTEM_PACKAGES in the image's ENV, Ubuntu's
# PEP 668 marker makes this — and `pip3 install --user` too — fail with an 11-line
# externally-managed-environment error, and the only ways forward are a venv or a flag named
# --break-system-packages. A student meeting that on their first `pip3 install` is the whole
# problem the ENV solves.
assert_not_contains "python:pip-install-needs-no-flags" "externally-managed" "$pipout"
# And pip must have got as far as looking for the package, or the assertion above passes for the
# wrong reason — any early failure would also contain no such message.
assert_contains "python:pip-reached-the-resolver" "Could not find a version" "$pipout"
# The other half, and it is deliberate rather than an oversight: sudo's env_reset strips the
# variable, so root's pip still honours the marker and the apt-managed tree stays protected.
# This also fails if someone "simplifies" the ENV away by deleting the marker file instead —
# which looks identical until `apt reinstall libpython3.14-stdlib` puts the file back.
sudopip="$($VT_RUN --rm --network=none --entrypoint sh "$TEST_IMAGE" \
           -c 'sudo pip3 install --no-index tabulate 2>&1' || true)"
assert_contains "python:sudo-pip-still-refuses" "externally-managed" "$sudopip"
# numpy's absence is asserted, not merely un-asserted: re-adding it to the apt line would
# restore exactly the mixed provenance this removed.
assert_fail "python:no-apt-managed-numpy" \
            sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'python3 -c \"import numpy\"'"
# python3-dev, checked by the artifact that matters rather than by the package name: without
# Python.h a source build dies at `fatal error: Python.h: No such file or directory`, and
# build-essential on its own does not fix it.
assert_ok "python:c-extension-headers-present" \
          sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'ls /usr/include/python3*/Python.h'"
# python3-venv is named on the apt line rather than inherited from pipx, and a venv has to work
# offline: `python3 -m venv` bootstraps pip from python3-pip-whl, so it needs no index at all.
venvout="$($VT_RUN --rm --network=none --entrypoint sh "$TEST_IMAGE" \
           -c 'python3 -m venv /tmp/v >/dev/null 2>&1 && /tmp/v/bin/pip --version' || true)"
assert_contains "python:venv-works-offline" "pip " "$venvout"
# Where a student's own installs land, and that they can be written with no sudo. ~/.local is
# also the npm prefix, so this directory being student-owned is load-bearing twice.
assert_ok "python:user-site-is-writable" \
          sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'test -w /home/student/.local'"
record "python:user-site" "$(R 'python3 -c "import site;print(site.getusersitepackages())"')"
record "python:pip-version" "$(R 'pip3 --version')"
# The two additions to the apt line are DELIBERATE, not inherited — the same argument as
# net:openssh-client-is-installed-on-purpose a few lines up. python3-venv in particular has been
# in every image ever built, purely because pipx depends on it.
assert_contains "python:dev-is-installed-on-purpose"  "python3-dev"  "$manual"
assert_contains "python:venv-is-installed-on-purpose" "python3-venv" "$manual"

# Passwordless sudo is a deliberate course decision: CS193V trains students not to run
# commands on their host, so system changes must be possible from inside.
assert_ok "sudo-works-without-a-password" sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'sudo -n true'"

# git stays completely stock so students meet its real hints and errors.
assert_fail "no-etc-gitconfig" sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'test -e /etc/gitconfig'"
assert_eq "git-editor-is-nano" "nano" "$(R 'git var GIT_EDITOR')"

# ─── where `git config --global` writes ────────────────────────────────────────
# THE ASSERTION THAT PINS THE WHOLE cs193v-git VOLUME. `git config --global` writes
# $XDG_CONFIG_HOME/git/config if that file EXISTS and ~/.gitconfig does not, and ~/.gitconfig
# otherwise. The Containerfile creates the first one empty for exactly that reason, so every
# --global write — setup-git's identity and `gh auth setup-git`'s credential helper — lands in the
# directory the volume mounts instead of in the writable layer that --rebuild throws away.
#
# Nothing about that is visible in either file, and getting it wrong fails NOWHERE: setup would
# work perfectly and a student would silently lose their identity the first time staff shipped a
# fix. So it is asserted by doing it and asking git where it went.
assert_ok "gitconfig:xdg-file-exists-empty" sh -c \
    "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'test -f /home/student/.config/git/config && ! test -s /home/student/.config/git/config'"
assert_fail "gitconfig:no-home-gitconfig" sh -c \
    "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'test -e /home/student/.gitconfig'"
assert_contains "gitconfig:global-writes-land-in-the-volume-path" \
    "/home/student/.config/git/config" \
    "$(R 'git config --global user.name Probe >/dev/null 2>&1; git config --global --show-origin user.name')"
assert_fail "gitconfig:global-write-does-not-make-a-home-gitconfig" sh -c \
    "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'git config --global user.name Probe >/dev/null 2>&1; test -e /home/student/.gitconfig'"

# ─── setup-git and the shared presentation layer ───────────────────────────────
# The container's copy of box(), menu() and msg(), plus the script and the prose that use them.
# Checked here rather than only statically because the install is where they can go missing: a
# forgotten line in the Containerfile is invisible in the checkout.
for f in /etc/cs193v/ui.sh /etc/cs193v/setup-git-messages.txt /usr/local/bin/setup-git; do
    assert_ok "setup-git:installed:$f" sh -c \
        "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'test -s $f'"
done
assert_ok "setup-git:is-executable" sh -c \
    "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'test -x /usr/local/bin/setup-git'"
assert_ok "setup-git:is-on-the-path" sh -c \
    "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'command -v setup-git >/dev/null'"
# The installed copies parse under the container's own bash, which is the one that will run them.
assert_ok "setup-git:installed-copy-parses" sh -c \
    "$VT_RUN --rm --entrypoint bash '$TEST_IMAGE' -n /usr/local/bin/setup-git"
assert_ok "setup-git:installed-ui-parses" sh -c \
    "$VT_RUN --rm --entrypoint bash '$TEST_IMAGE' -n /etc/cs193v/ui.sh"
# And it really reads the installed prose and the installed helper with no environment help,
# which is the one thing the host-side suites cannot check: they both override those paths.
assert_contains "setup-git:reads-the-installed-catalogue" "terminal" \
    "$(R 'setup-git </dev/null 2>&1 || true')"
assert_contains "setup-git:dev-seam-works-in-the-image" "target_name=cs193v-students" \
    "$(R 'setup-git --dev-print-token-url')"
assert_ok "nanorc-installed" sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'test -f /home/student/.nanorc'"
assert_eq "nanorc-is-student-owned" "student" "$(R 'stat -c %U /home/student/.nanorc')"

# npm's global prefix points at the student's home so `npm install -g` works without sudo,
# while build-time globals stay in root-owned /usr/local.
assert_eq "npm-prefix-is-in-home" "/home/student/.local" "$(R 'npm config get prefix')"
assert_ok "npm-install-g-needs-no-sudo" \
          sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'test -w /home/student/.local/bin'"

# THE STATE FILE THE TUNNEL WOULD HAVE WRITTEN, faked. Defined here rather than beside the
# shortlink cases below because open-url reaches shortlink too and needs it first.
#
# EVERY PORT MARKED UP, because shortlink asks the KERNEL for a port and no test can predict which
# one it gets. Marking the whole range means whatever it picks is confirmed, which is what these
# cases are about; the case where a port is NOT confirmed is asserted separately below.
FAKE_UP='mkdir -p /tmp/cs193v; { printf "state\thealthy\nfloor\t1024\n"; seq 1 65535 | awk "{print \"up\\t\" \$1 \"\\tlo\"}"; } > /tmp/cs193v/ports'

# ─── the $BROWSER stub ─────────────────────────────────────────────────────────
# Without it, `gh auth login` and `claude /login` leave a student
# staring at a prompt that never returns.
out="$(R '/usr/local/bin/open-url https://example.com/verify?code=ABCD')"
assert_contains "helper:open-url-prints-the-url" "https://example.com/verify?code=ABCD" "$out"
assert_contains "helper:open-url-explains-why"   "no browser" "$out"
assert_fail "helper:open-url-needs-an-argument" \
            sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c '/usr/local/bin/open-url'"
# THE STUB'S TWO ASSERTIONS ABOVE RUN WITH NO STATE FILE, and that is load-bearing rather than
# incidental: $VT_RUN is a bare `podman run` with no tunnel behind it, so /tmp/cs193v/ports does
# not exist, shortlink has nothing to tell it a port is reachable, degrades to printing its
# argument, and open-url prints exactly what it always did. That is the contract every caller of
# shortlink leans on to need no conditional of its own.
out="$(R "$FAKE_UP"' && /usr/local/bin/open-url https://example.com/verify?code=ABCD')"
assert_match "helper:open-url-shortens-when-a-port-is-forwarded" \
             "http://localhost:[0-9]+/magic-link" "$out"
assert_not_contains "helper:open-url-shortened-hides-the-long-url" \
                    "example.com/verify" "$out"
assert_contains "helper:open-url-shortened-says-it-expires" "15 minutes" "$out"

# ─── shortlink  (issue #67) ────────────────────────────────────────────────────
# ENTIRELY INSIDE ONE THROWAWAY CONTAINER, and that is not a shortcut: a fresh container has its
# own network namespace, so every port in it is free and the curl that proves the redirect can run
# beside the server that serves it. Nothing here needs the tunnel, which is what 60-container.sh
# is for -- the half only a real container and a real host can answer is whether the port is
# reachable from OUTSIDE, and it is the only shortlink assertion that lives there.
#
# `sl` runs a whole shell line with the state file the TUNNEL would have written already in place.
# There is no tunnel in a throwaway container and no way to raise one, but shortlink does not need
# a tunnel -- it needs to be told a port is forwarded, and that is a file. Faking the file is a
# great deal easier than faking the tunnel, and it is exactly the input the real thing supplies.
#
# EVERY PORT MARKED UP, because shortlink asks the KERNEL for a port and no test can predict which
# one it gets. Marking the whole range means whatever it picks is confirmed, which is what these
# cases are about; the case where a port is NOT confirmed is asserted separately below.
#
# THE ASSERTIONS THIS REPLACED WERE ABOUT A LIST -- highest-first, comma-separated, malformed
# chunk skipped. There is no list to parse any more, so they are gone rather than adapted; what
# took their place is the property they were standing in for, which is that the port shortlink
# prints is one it has been told is reachable.
sl() { R "$FAKE_UP; $1"; }

assert_ok "shortlink:help-answers" \
          sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c '/usr/local/bin/shortlink --help > /dev/null'"

# THE PORT IT PRINTS IS ONE IT WAS TOLD IS REACHABLE. "Any free port" on its own would be a bug
# rather than a simplification: a server on a port the tunnel did not carry looks exactly like a
# broken link. So the port is the kernel's choice, but printing it is the state file's decision.
out="$(sl 'l=$(/usr/local/bin/shortlink https://example.com/a token); echo "$l"; p=${l##*:}; grep -c "^up	${p%%/*}	" /tmp/cs193v/ports')"
assert_match "shortlink:prints-a-short-url" "http://localhost:[0-9]+/token" "$out"
assert_contains "shortlink:the-port-it-printed-was-confirmed" "1" "$out"

# AND IT WILL NOT PRINT ONE IT WAS NOT TOLD ABOUT. The mirror image, and the assertion that stops
# the group above passing for a shortlink that ignores the file entirely: with a state file that
# is present, healthy and simply never mentions the port, it must degrade rather than guess.
out="$(R 'mkdir -p /tmp/cs193v; printf "state\thealthy\nfloor\t1024\n" > /tmp/cs193v/ports; /usr/local/bin/shortlink https://example.com/unconfirmed; echo rc=$?')"
assert_contains "shortlink:an-unconfirmed-port-degrades"  "https://example.com/unconfirmed" "$out"
assert_contains "shortlink:an-unconfirmed-port-exits-3"   "rc=3" "$out"

# THE DEGRADATION, asserted in both of its shapes: no state file at all, and one that never
# confirms. Both print the input and exit 3, because a caller must be able to print the answer
# unconditionally.
out="$(R '/usr/local/bin/shortlink https://example.com/plain; echo rc=$?')"
assert_contains "shortlink:no-ports-prints-the-input" "https://example.com/plain" "$out"
assert_contains "shortlink:no-ports-exits-3" "rc=3" "$out"

# ─── the redirect itself ───────────────────────────────────────────────────────
# ONE SHELL LINE PER CASE because the server has to still be running when curl asks. -D- keeps the
# headers, which is where everything worth asserting is.
out="$(sl 'l=$(/usr/local/bin/shortlink "https://github.com/settings/personal-access-tokens/new?name=CS193V&contents=write" token); curl -sD- -o /dev/null --max-time 5 "$l"')"
assert_match "shortlink:answers-302"   "^HTTP/1[.]. 302" "$out"
assert_contains "shortlink:sends-the-location" \
                "Location: https://github.com/settings/personal-access-tokens/new?name=CS193V&contents=write" "$out"
# 302 AND NOT 301, and no-store beside it. A permanent redirect is remembered per origin and path
# for months, and these ports get reused -- by the next shortlink and by the student's own
# projects. A 301 here would silently send a later project's route to GitHub with nothing anywhere
# to explain it.
assert_not_match "shortlink:never-301" "^HTTP/1[.]. 301" "$out"
assert_contains  "shortlink:forbids-caching" "Cache-Control: no-store" "$out"

# SERVES REPEATEDLY, which is the whole reason it is not a one-shot. A browser opening one URL
# preconnects speculatively and asks for /favicon.ico, and a student double-clicks and presses
# Back -- a server that closed after its first response would spend it on none of those.
out="$(sl 'l=$(/usr/local/bin/shortlink https://example.com/a token); for i in 1 2 3; do curl -s -o /dev/null -w "%{http_code} " --max-time 5 "$l"; done')"
assert_eq "shortlink:redirects-every-time" "302 302 302" "$(printf '%s' "$out" | tr -s ' ' | sed 's/ *$//')"

# THE SLUG IS NEVER EMPTY, and `/` is the path it must never serve: the browser keys its cache and
# any service worker on the ORIGIN, which outlives whatever used to listen there, so the one path a
# student's own project is likely to have served is the one we stay off. Nothing routes /magic-link.
out="$(sl 'l=$(/usr/local/bin/shortlink https://example.com/a); echo "$l"; curl -s -o /dev/null -w " root=%{http_code}" --max-time 5 "${l%/*}/"; curl -s -o /dev/null -w " slug=%{http_code}" --max-time 5 "$l"')"
assert_match "shortlink:default-slug-is-magic-link" "http://localhost:[0-9]+/magic-link" "$out"
assert_contains "shortlink:bare-root-is-not-served"    "root=404" "$out"
assert_contains "shortlink:default-slug-redirects"     "slug=302" "$out"
out="$(sl 'l=$(/usr/local/bin/shortlink https://example.com/a token); curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${l%/*}/nope"')"
assert_eq "shortlink:unknown-path-is-404" "404" "$out"

# LOOPBACK ONLY. The tunnel's far end is the container's IPv4 loopback, so that is all that is
# needed; the wildcard would additionally publish the redirect on the container's eth0.
# The port is the kernel's, so the listening line is found by asking which port shortlink took
# rather than by naming one.
out="$(sl 'l=$(/usr/local/bin/shortlink https://example.com/a token); p=${l##*:}; ss -ltn | grep ":${p%%/*} "')"
assert_match     "shortlink:binds-loopback"    "127[.]0[.]0[.]1:[0-9]+" "$out"
assert_not_match "shortlink:binds-no-wildcard" "(0[.]0[.]0[.]0|\[::\]):[0-9]+" "$out"

# ─── what a caller needs to be true ───────────────────────────────────────────
# THE ONE BUG THAT PASSES EVERY CHECK MADE BY HAND. `link=$(shortlink ...)` reads the pipe until
# EOF and only then waits for the child, and EOF arrives when the LAST descriptor on the write end
# closes -- so a server that inherited fd 1 hangs the caller forever, whatever its parent does.
# Run at a prompt, stdout is a tty, nobody reads to EOF, and it returns instantly. This is the
# only place that difference is visible, so `timeout` is the assertion.
out="$(sl 'timeout 10 sh -c "l=\$(/usr/local/bin/shortlink https://example.com/a token); echo returned=\$l"')"
assert_match "shortlink:command-substitution-returns" "returned=http://localhost:[0-9]+/token" "$out"

# ITS OWN SESSION, so a Ctrl-C in the caller's foreground process group does not take the link
# down at the moment the student is about to click it. Compared against the shell that started it
# rather than to a literal: what matters is that they differ.
out="$(sl '/usr/local/bin/shortlink https://example.com/a --pidfile /tmp/sl.pid token > /dev/null; sleep 1; echo "daemon=$(ps -o sid= -p "$(cat /tmp/sl.pid)" | tr -d " ") caller=$(ps -o sid= -p $$ | tr -d " ")"')"
record "shortlink:sessions" "$out"
# The two numbers have to DIFFER, so the assertion is that the "they are equal" pattern matched
# nothing. Comparing them any other way would need the values in the suite, and they only exist
# inside the container.
assert_eq "shortlink:runs-in-its-own-session" "" \
          "$(printf '%s' "$out" | sed -n 's/.*daemon=\([0-9]*\) caller=\1$/SAME/p')"

# --pidfile, and the pid in it is one a caller can actually end -- which is what setup-git's
# sg_cleanup does rather than leaving a forwarded port held for the rest of the fifteen minutes.
# The file goes away with the process: a pidfile that outlives what it names is the trap the
# launcher documents at tunnel_kill_pid, since pids get reused.
out="$(sl 'l=$(/usr/local/bin/shortlink https://example.com/a --pidfile /tmp/sl.pid token); sleep 1; kill "$(cat /tmp/sl.pid)"; sleep 1; echo "gone=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "$l")"; test -e /tmp/sl.pid && echo pidfile=left || echo pidfile=removed')"
assert_contains "shortlink:pidfile-kill-stops-it"   "gone=000" "$out"
assert_contains "shortlink:pidfile-is-removed"      "pidfile=removed" "$out"

# AND IT LETS GO ON ITS OWN, so nothing depends on a caller remembering. --timeout 1 rather than
# waiting out the real 900s default.
out="$(sl 'l=$(/usr/local/bin/shortlink https://example.com/a --timeout 1 token); sleep 3; curl -s -o /dev/null -w "%{http_code}" --max-time 3 "$l"')"
assert_eq "shortlink:timeout-releases-the-port" "000" "$out"

# CONCURRENT CALLS CANNOT COLLIDE, because binding IS the free-port test -- never check and then
# bind, which two racing callers would both pass.
out="$(sl 'for s in one two three; do /usr/local/bin/shortlink https://example.com/$s $s; done')"
assert_eq "shortlink:three-callers-get-three-ports" "3" \
          "$(printf '%s' "$out" | grep -cE 'http://localhost:[0-9]+/')"
assert_eq "shortlink:those-ports-are-distinct" "3" \
          "$(printf '%s' "$out" | sed 's|.*localhost:||;s|/.*||' | sort -u | grep -c .)"

# ─── what it refuses ──────────────────────────────────────────────────────────
# THIS IS AN OPEN REDIRECTOR BY DESIGN and its argument reaches a response header, so the two
# things that must not get through are a scheme a browser should not be sent to and a newline,
# which would end the Location header and let the rest of the argument write headers of its own.
for bad in 'file:///etc/passwd' 'javascript:alert(1)' 'notaurl'; do
    assert_eq "shortlink:refuses-$bad" "2" \
              "$(R "/usr/local/bin/shortlink '$bad' > /dev/null 2>&1; echo \$?")"
done
assert_eq "shortlink:refuses-a-newline-in-the-url" "2" \
          "$(R "/usr/local/bin/shortlink \"\$(printf 'https://x.example/a\\r\\nX-Evil: 1')\" > /dev/null 2>&1; echo \$?")"
assert_eq "shortlink:refuses-a-slug-with-a-slash" "2" \
          "$(R "/usr/local/bin/shortlink https://example.com/a 'has/slash' > /dev/null 2>&1; echo \$?")"

# ─── Playwright and its browser ────────────────────────────────────────────────
# The course's test harnesses are browser tests, so the browser is part of the image rather
# than something `npm test` installs on first use. These assert the three things that can
# each ship a broken image while the build still goes green.
PW_CACHE=/home/student/.cache/ms-playwright

record "playwright:cli-version" "$(R 'playwright --version 2>&1')"
assert_ok "playwright:cli-is-installed" \
          sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'playwright --version'"

# The FLOOR is asserted, not the exact pin. 1.61.0 is the first playwright whose platform
# table knows ubuntu26.04; older ones resolve this base image to ubuntu24.04 and install a
# browser for a distribution this is not. The exact version is recorded rather than asserted
# because CI is expected to pin versions with --build-arg, and a test that fails on a
# deliberate pin is a test people learn to ignore.
pw_floor="$(R 'playwright --version 2>&1' | tr -dc "0-9.\n" | awk -F. '
    {maj=$1+0; min=$2+0}
    END {print (maj > 1 || (maj == 1 && min >= 61)) ? "ok" : "TOO OLD for ubuntu26.04"}')"
assert_eq "playwright:version-is-at-least-1.61-for-ubuntu26.04" "ok" "$pw_floor"

assert_ok "playwright:headless-shell-is-baked-in" \
          sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'ls -d $PW_CACHE/chromium_headless_shell-*'"
# --only-shell must hold. The full Chrome for Testing build is a further 184 MB download on
# top of the shell, and unusable here anyway: there is no display, so nothing runs headed.
assert_eq "playwright:no-full-chromium-only-the-shell" "" \
          "$(R "ls -d $PW_CACHE/chromium-[0-9]* 2>/dev/null || true")"
# Student-owned for the same reason the tldr cache is, plus one more: podman copies this
# directory into the cs193v-playwright volume on first mount, so root-owned content here
# would produce a volume the student cannot write to.
assert_eq "playwright:cache-is-student-owned" "student" "$(R "stat -c %U $PW_CACHE")"

# The puppeteer#7740 failure mode, checked in the image rather than only at build time: a
# browser for the wrong CPU unpacks, installs and passes every test except running.
arch_ok="$(R 'bin="$(find /home/student/.cache/ms-playwright -type f \( -name chrome-headless-shell -o -name headless_shell \) -perm -u+x | head -1)"; case "$(uname -m)" in x86_64) want=3e00 ;; aarch64) want=b700 ;; *) want=unsupported-arch ;; esac; got="$(od -An -t x1 -j 18 -N 2 -- "$bin" | tr -d " \n")"; if [ "$got" = "$want" ]; then echo match; else echo "got=$got want=$want bin=$bin"; fi')"
assert_eq "playwright:browser-arch-matches-the-image" "match" "$arch_ok"

# The one that proves the other three mean something. A missing shared library shows up
# nowhere else: the binary exists, it is the right architecture, and it still cannot start.
# --network=none for the same reason tldr:works-offline uses it — the browser is supposed to
# be IN the image, so nothing here may quietly download it.
shot="$($VT_RUN --rm --network=none --entrypoint sh "$TEST_IMAGE" -c \
        'timeout 120 playwright screenshot -b chromium about:blank /tmp/probe.png >/dev/null 2>&1; wc -c < /tmp/probe.png 2>/dev/null || echo 0' \
        2>/dev/null | tr -d ' \n')"
record "playwright:offline-screenshot-bytes" "$shot"
if [ "${shot:-0}" -gt 1000 ]; then
    pass "playwright:drives-chromium-offline"
else
    fail "playwright:drives-chromium-offline" \
         "rendered $shot bytes with no network. The browser is baked into the image, so this
must work with --network=none. A missing system library looks exactly like this."
fi

# ─── things deliberately NOT installed ─────────────────────────────────────────
# Each was considered and rejected; re-adding one should break a test rather than slip in.
#
# chromium/chrome stay on this list even though a Chromium build now ships: what is asserted
# is that no browser is on $PATH. The headless shell lives in the Playwright cache and is
# launched by Playwright, never typed by a student, and `code` is still absent entirely.
assert_eq "absent:no-extra-tools" "none" \
    "$(R 'for t in rg fzf delta bat fd chromium google-chrome chrome code; do command -v $t >/dev/null && echo $t; done; echo none')"
# man pages are stripped by the base image and deliberately not restored; tldr stands in.
manout="$(R 'man git 2>&1; echo "rc=$?"')"
record "absent:man-behaviour" "$(printf '%s' "$manout" | tr '\n' ' ')"
assert_not_contains "absent:no-real-man-page-for-git" "GIT(1)" "$manout"
assert_not_contains "absent:man-db-not-installed"     "GITHUB" "$manout"
assert_ok "absent:tldr-stands-in-for-man" \
          sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'tldr --version'"

# ─── what `man` says instead  (issue #8) ───────────────────────────────────────
# Ubuntu's minimized base leaves its OWN /usr/bin/man behind: a stub that exits 0 and
# prints "To restore this content, including manpages, you can run the 'unminimize'
# command". For a first-year student that is worse than "command not found", because it
# reads as an instruction — and following it downloads hundreds of megabytes into a
# container the next `cs193v --rebuild` throws away, so the manual pages it promised
# disappear again with nothing to explain why. It is replaced.
assert_not_contains "man:does-not-advertise-unminimize" "unminimize" "$manout"
assert_not_contains "man:does-not-say-the-system-was-minimized" "has been minimized" "$manout"
assert_says "man:says-man-pages-are-absent" "man pages are not installed" "$manout"
# Naming tldr is the whole point: "not installed" alone leaves a student with nowhere to go.
assert_says "man:points-at-the-tldr-page-for-what-was-asked-for" "tldr git" "$manout"
# It FAILS. `man git` genuinely did not produce a manual page, and `git commit --help` runs
# `man` underneath and has to be able to tell — exiting 0 is what made the base image's
# stub read as success.
assert_not_contains "man:exits-nonzero" "rc=0" "$manout"
# stderr, like man's own "No manual entry for": a pipeline must not collect our apology as
# though it were the page.
assert_eq "man:writes-nothing-to-stdout" "" "$(R 'man git 2>/dev/null')"

# A section argument must not become the suggestion — `man 3 printf` is `tldr printf`, not
# `tldr 3`. This is the one place the argument parsing can go quietly wrong.
sect="$(R 'man 3 printf 2>&1')"
assert_says "man:section-argument-suggests-the-page" "tldr printf" "$sect"
assert_says_not "man:section-argument-is-not-the-suggestion" "tldr 3" "$sect"
# No argument at all must still be useful rather than a bare error.
assert_says "man:no-argument-still-points-at-tldr" "tldr <command>" "$(R 'man 2>&1')"

# End to end, and the reason this is worth an image-tier test rather than a static one:
# `git commit --help` shells out to `man git-commit`, so what a student sees when they ask
# git for help is decided here — and the page it names has to be one tldr actually has,
# offline, from the cache baked into the image.
githelp="$(R 'git commit --help')"
assert_says "man:git-help-goes-through-the-stub" "tldr git-commit" "$githelp"
assert_contains "man:the-suggested-page-really-exists" "Commit files to the repository" \
    "$($VT_RUN --rm --network=none --user 1000:1000 --entrypoint sh "$TEST_IMAGE" \
       -c 'tldr git-commit 2>&1' || true)"

# tldr is the replacement for man, so its page cache has to be baked in. `tldr --update`
# does that at build time — but the Containerfile ends that line with `|| true`, so a
# network hiccup during CI would ship an image with no cache and nothing would say so.
# These assertions are what make that failure visible.
ncache="$(R 'find /home/student/.cache/tldr -type f 2>/dev/null | wc -l' | tr -d ' ')"
record "tldr:cached-page-count" "$ncache"
if [ "${ncache:-0}" -gt 1000 ]; then
    pass "tldr:cache-is-populated-at-build-time"
else
    fail "tldr:cache-is-populated-at-build-time" \
         "only ${ncache:-0} cached pages. $PRIVATE/Containerfile's `tldr --update` ends in '|| true',
so a failed fetch during the image build is silent and students meet an
empty tldr — with no man pages to fall back on."
fi
assert_eq "tldr:cache-is-student-owned" "student" \
          "$(R 'stat -c %U /home/student/.cache/tldr')"
# The whole point of pre-caching: it must work on first use with no network at all.
offline="$($VT_RUN --rm --network=none --entrypoint sh "$TEST_IMAGE" -c 'tldr tar 2>&1' || true)"
assert_contains "tldr:works-offline" "Archiving utility" "$offline"
assert_not_contains "tldr:offline-does-not-error" "Traceback" "$offline"
# NOT vacuous, unlike VERIFICATION.md §A.3's version: node comes from the official tarball
# into root-owned /usr/local specifically so there is no group-writable nvm tree, which is
# the quietest way to trojan a shared node/npm with no sudo at all.
assert_fail "absent:no-nvm-tree" sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'test -e /usr/local/share/nvm'"
assert_eq "absent:node-is-root-owned" "root" "$(R 'stat -c %U $(command -v node)')"
assert_eq "absent:node-not-group-writable" "ok" \
    "$(R 'case "$(stat -c %A "$(command -v node)")" in ?????w*) echo BAD;; *) echo ok;; esac')"
# The global module tree must be root-owned too, wherever apt put it.
assert_eq "absent:global-node-modules-root-owned" "root" \
    "$(R 'stat -c %U "$(dirname "$(dirname "$(readlink -f "$(command -v node)")")")/lib/node_modules" 2>/dev/null || echo root')"
# Node must be apt-managed, so a student can pick up security fixes from inside.
assert_ok "node:is-an-apt-package" \
          sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'dpkg -s nodejs >/dev/null'"
record "node:apt-package-version" "$(R 'dpkg-query -Wf "\${Version}" nodejs')"
assert_eq "node:not-apt-mark-held" "" "$(R 'apt-mark showhold' | tr -d ' \n')"
assert_eq "absent:usr-local-lib-root-owned" "root" "$(R 'stat -c %U /usr/local/lib')"
# ─── the student's global npm prefix  (issue #13) ──────────────────────────────
# playwright, vercel and Claude Code are installed AS THE STUDENT, into the student's own
# npm prefix, so `npm ls -g` answers the question a student is actually asking.
#
# They used to be installed as root. Root's prefix is nodesource's /usr and the student's is
# ~/.local, and npm reads exactly one of them — so the three tools were invisible to
# `npm ls -g`, and `~/.local/lib` did not exist at all, which made the command CRASH with
# ENOENT and six lines of npm error rather than print an empty tree.
#
# The success check is not ceremony, and it comes FIRST on purpose: an assertion that
# matches on the output of a command nobody checked is worth nothing. This block used to
# read `npm ls -g --depth=0 2>/dev/null` — a command that errored, with its stderr
# discarded — and then match against the empty string it produced. Anything asserted that
# way passes for the wrong reason and keeps passing forever.
assert_ok "npm:ls-g-succeeds" \
          sh -c "$VT_RUN --rm --network=none --entrypoint sh '$TEST_IMAGE' -c 'npm ls -g --depth=0 >/dev/null'"
globals="$(R 'npm ls -g --depth=0')"
record "npm-globals" "$(printf '%s' "$globals" | tr '\n' ' ')"
for pkg in "@anthropic-ai/claude-code" "@openai/codex" vercel playwright; do
    assert_contains "npm:ls-g-lists-$pkg" "$pkg" "$globals"
done

# Student-owned, so `npm update -g` and Claude Code's own updater work in place rather than
# writing a second copy somewhere else on PATH.
assert_eq "npm:globals-are-student-owned" "student student student student" \
    "$(R 'stat -c %U /home/student/.local/lib/node_modules/@anthropic-ai/claude-code \
                     /home/student/.local/lib/node_modules/@openai/codex \
                     /home/student/.local/lib/node_modules/vercel \
                     /home/student/.local/lib/node_modules/playwright' | tr '\n' ' ' | sed 's/ *$//')"
# And the prefix must be writable with no sudo — that is what the whole arrangement buys.
assert_ok "npm:student-prefix-is-writable-without-sudo" \
          sh -c "$VT_RUN --rm --network=none --entrypoint sh '$TEST_IMAGE' -c 'test -w /home/student/.local/lib/node_modules && test -w /home/student/.local/bin'"
for cmd in claude codex vercel playwright; do
    assert_eq "npm:$cmd-resolves-in-the-student-prefix" "/home/student/.local/bin/$cmd" \
              "$(R "command -v $cmd")"
done

# The `npm install -g` layers must not leave an npm cache in the image. It is pure dead
# weight in something students download over dorm wifi, and it inflates the layers that the
# resume-on-failure design cares about. The apt layer already cleans /var/lib/apt/lists;
# this is the same hygiene for npm.
#
# BOTH caches are measured. The installs run as the student now, so /home/student/.npm is
# the one that actually gets written — checking only /root/.npm would pass on an image
# carrying 150 MB of student cache.
for who in root student; do
    case "$who" in
        root) dir=/root/.npm ;;
        *)    dir=/home/student/.npm ;;
    esac
    cache_mb="$(R "sudo du -sm $dir 2>/dev/null | cut -f1" | tr -d ' \n')"
    record "img:$who-npm-cache-mb" "${cache_mb:-0}"
    if [ "${cache_mb:-0}" -lt 20 ]; then
        pass "img:npm-cache-not-baked-into-the-image:$who"
    else
        fail "img:npm-cache-not-baked-into-the-image:$who" \
             "$dir is ${cache_mb} MB. Add 'npm cache clean --force', as that user, to each npm layer."
    fi
done

# ─── fonts ─────────────────────────────────────────────────────────────────────
# The base image ships no fonts at all, and anything that rasterizes text (Pillow,
# matplotlib, librsvg) needs one. Noto because a large share of the web uses it, so
# rendered output looks unremarkable rather than unmistakably-Linux.
#
# Two separate things, which the original single check conflated: the font FILES being
# present, and them being DISCOVERABLE. fonts-noto-core only Recommends fontconfig, and the
# apt line uses --no-install-recommends, so the image currently has 271 Noto files and no
# way to enumerate them. See ERRORS.md B7.
nfonts="$(R 'find /usr/share/fonts -type f \( -name "*.ttf" -o -name "*.otf" \) 2>/dev/null | wc -l' | tr -d ' ')"
record "fonts:file-count" "$nfonts"
if [ "${nfonts:-0}" -gt 0 ]; then pass "fonts:files-are-installed"
else fail "fonts:files-are-installed" "no font files — anything rendering text yields boxes"; fi
assert_match "fonts:noto-is-the-family-installed" "[Nn]oto" \
             "$(R 'find /usr/share/fonts -type f -iname "*noto*" | head -1')"

if R 'command -v fc-match' >/dev/null 2>&1; then
    pass "fonts:fontconfig-is-installed"
    assert_match "fonts:sans-serif-resolves-to-noto" "Noto" "$(R 'fc-match sans-serif')"
else
    fail "fonts:fontconfig-is-installed" \
         "fc-list/fc-match are missing, so the 271 installed Noto files cannot be
discovered by anything that resolves fonts through fontconfig (librsvg, Pango,
GD, ImageMagick). fonts-noto-core only Recommends fontconfig and the apt line
uses --no-install-recommends. Either add fontconfig or drop the fonts; the
current state pays 60-odd MB for files nothing can enumerate. See ERRORS.md B7."
    skip "fonts:sans-serif-resolves-to-noto" "no fontconfig"
fi

# ─── locale ────────────────────────────────────────────────────────────────────
assert_eq "locale:generated" "en_US.UTF-8" "$(R 'echo $LANG')"
assert_match "locale:utf8-works" "UTF-8" "$(R 'locale charmap 2>/dev/null || echo none')"

# ─── shell ergonomics ──────────────────────────────────────────────────────────
# Ctrl-S is "save" in every GUI editor; on a terminal it freezes all output with no echo,
# which looks exactly like a crash, and the recovery (Ctrl-Q) is unknown to novices.
# Applied twice on purpose: profile.d for login shells, bash.bashrc for interactive
# non-login ones.
assert_ok "shell:profile.d-installed" sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'test -f /etc/profile.d/10-cs193v-shell.sh'"
assert_contains "shell:profile.d-disables-ixon" "stty -ixon" \
                "$(R 'cat /etc/profile.d/10-cs193v-shell.sh')"
assert_contains "shell:bashrc-also-disables-ixon" "stty -ixon" "$(R 'cat /etc/bash.bashrc')"

# ─── identity: hostname, banner, window title, goodbye  (#3, #4) ───────────────
assert_ok "identity:welcome-banner-installed" \
          sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'test -f /etc/profile.d/20-cs193v-welcome.sh'"
assert_eq "identity:welcome-banner-mode" "644" \
          "$(R 'stat -c %a /etc/profile.d/20-cs193v-welcome.sh')"
assert_ok "identity:bash_logout-installed" \
          sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'test -f /home/student/.bash_logout'"
assert_eq "identity:bash_logout-is-student-owned" "student" \
          "$(R 'stat -c %U /home/student/.bash_logout')"

# The window title must name the course...
assert_contains "identity:window-title-names-the-course" "CS193V Development Environment" \
                "$(R 'grep "e\]0;" /home/student/.bashrc')"
# ...and Ubuntu's original title escape must be gone, or it would be re-emitted every
# prompt and overwrite ours.
assert_not_contains "identity:ubuntu-title-escape-removed" 'u@\h: \w\a' \
                    "$(R 'grep "e\]0;" /home/student/.bashrc')"
# But the VISIBLE prompt must be byte-identical to Ubuntu's. The whole point of the
# hostname change is that the default prompt already carries the signal, so there is no
# reason to touch what the student actually reads.
# Ubuntu ships two visible PS1 assignments (a colour one and a plain fallback), neither of
# which we touch. Counting them is robust where matching the exact string is a quoting trap.
assert_eq "identity:both-visible-PS1-assignments-intact" "2" \
    "$(R 'grep -c "^[[:space:]]*PS1=.\\\$.debian_chroot" /home/student/.bashrc' | tr -d ' ')"
assert_contains "identity:visible-prompt-still-shows-user-at-host" 'u@' \
    "$(R 'grep "^[[:space:]]*PS1=.\\\$.debian_chroot" /home/student/.bashrc | head -1')"

# The banner text cannot come from messages.txt -- the container cannot see it -- so it has
# to be in the image. Assert it really is. The text lives in the cs193v-welcome COMMAND;
# /etc/profile.d/20-cs193v-welcome.sh only decides whether to call it.
assert_contains "identity:banner-text-is-in-the-image" "$CS193V_WELCOME" \
                "$(R 'cat /etc/cs193v/strings.sh')"

# ─── tmux: the landing point ───────────────────────────────────────────────────
# `./cs193v` runs cs193v-shell. Everything here is "is the image actually able to do that",
# as distinct from 65-tmux.sh, which drives a real session and asserts on what it looks like.
for cmd in cs193v-shell cs193v-welcome cs193v-goodbye; do
    assert_ok "tmux:$cmd-installed" \
              sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'test -x /usr/local/bin/$cmd'"
    assert_eq "tmux:$cmd-mode" "755" "$(R "stat -c %a /usr/local/bin/$cmd")"
done

assert_ok "tmux:conf-installed" \
          sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'test -f /etc/cs193v/tmux.conf'"
assert_eq "tmux:conf-mode" "644" "$(R 'stat -c %a /etc/cs193v/tmux.conf')"
assert_eq "tmux:conf-is-root-owned" "root" "$(R 'stat -c %U /etc/cs193v/tmux.conf')"
assert_ok "tmux:tabname-installed" \
          sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'test -f /etc/cs193v/tabname.bash'"
assert_eq "tmux:tabname-mode" "644" "$(R 'stat -c %a /etc/cs193v/tabname.bash')"

# NOT at tmux's default paths. cs193v-shell names the file with -f, which suppresses both
# /etc/tmux.conf and ~/.tmux.conf -- and it is the second one that matters, since tmux lets
# a student's own file win and re-arm the prefix key the config exists to remove.
assert_ok "tmux:no-etc-tmux-conf" \
          sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c '! test -e /etc/tmux.conf'"
assert_ok "tmux:no-user-tmux-conf" \
          sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c '! test -e /home/student/.tmux.conf'"

# Every interactive bash, and therefore every tab, must pick up the label hook. A tmux
# default-command would reach tab one only.
assert_contains "tmux:bashrc-sources-the-tabname-hook" "/etc/cs193v/tabname.bash" \
                "$(R 'cat /etc/bash.bashrc')"

assert_ok "tmux:binary-present" \
          sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'command -v tmux >/dev/null'"
record    "tmux:version" "$(R 'tmux -V')"
# THE TERMINFO GATE. default-terminal is tmux-256color, whose entry ships in ncurses-term,
# which is only a Recommends -- and this image builds with --no-install-recommends. Without
# it tmux exits with "missing or unsuitable terminal" and NOBODY can open a shell.
assert_ok "tmux:tmux-256color-terminfo-present" \
          sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'infocmp tmux-256color >/dev/null'"

# ─── inotify-tools ─────────────────────────────────────────────────────────────
# inotifywait is what 60-container.sh watches a container-side write with, and that assertion is
# the ONLY check of the hot-reload claim CONTAINER-DESIGN.md makes to students. The package was
# missing from the image until #39, so the check guarded itself out of existence on every run and
# recorded a sentence instead. Asserted HERE as well as exercised there, so a package that drops
# out of layer 1 fails at the tier that can say why rather than as a watch that did not fire.
assert_ok "files:inotifywait-present" \
          sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'command -v inotifywait >/dev/null'"

# ─── the course notes: ONE file, two agents ───────────────────────────────────
# /etc/claude-code/CLAUDE.md is a SYMLINK to /etc/cs193v/agent-notes.md, and the entrypoint
# links ~/.codex/AGENTS.md at the same file, so Claude Code and Codex cannot be told different
# things. Both live in /etc rather than in either tool's home, because those homes are named
# volumes: a file seeded there on first mount is never refreshed by a later image.
#
# WHAT THIS CANNOT PROVE is that Claude Code follows the symlink in its managed slot -- only a
# real session does, which is MANUAL.md §A.11's port-ranges prompt. What it proves is the half a
# machine can judge: one real file, both names reaching it, readable by the student.
assert_eq "notes:claude-managed-slot-is-a-link-to-the-one-file" "/etc/cs193v/agent-notes.md" \
    "$(R 'readlink -f /etc/claude-code/CLAUDE.md')"
assert_eq "notes:codex-global-slot-is-a-link-to-the-one-file" "/etc/cs193v/agent-notes.md" \
    "$(R 'cs193v-entrypoint true >/dev/null 2>&1; readlink -f /home/student/.codex/AGENTS.md')"
assert_eq "notes:readable-through-both-names" "ok" \
    "$(R 'cs193v-entrypoint true >/dev/null 2>&1
          test -r /etc/claude-code/CLAUDE.md && test -r /home/student/.codex/AGENTS.md && echo ok')"
# Not student-writable, or the course notes are advisory. Tested on the TARGET, since that is
# what a write would land on -- a writable symlink to a read-only file writes nothing.
assert_eq "notes:not-student-writable" "ok" \
    "$(R 'test ! -w /etc/cs193v/agent-notes.md && echo ok')"

# ─── Codex ─────────────────────────────────────────────────────────────────────
# AS THE STUDENT, which is the whole of what issue #71 asked for here: the wrapper installs into
# the student's own npm prefix, and this is the assertion that it is executable from the account
# that will run it rather than only from root. --network=none because a version check must not
# need the internet, and because a codex that phoned home on startup would be worth knowing about.
assert_ok "codex:runs-as-the-student-with-no-network" \
          sh -c "$VT_RUN --rm --network=none --entrypoint sh '$TEST_IMAGE' -c 'codex --version'"
record    "codex:version" "$(R 'codex --version 2>&1' | head -1)"
# The pin took effect. Asserted rather than recorded: a floating version means two students in
# one lab section get different software, which 00-release-gates.sh guards in the recipe and this
# guards in the artifact.
codex_want="$(sed -n 's/^ARG CODEX_VERSION=\(.*\)/\1/p' $PRIVATE/Containerfile | head -1)"
assert_contains "codex:installed-version-matches-the-pin" "$codex_want" "$(R 'codex --version 2>&1')"
# System bubblewrap. NOT a sandbox assertion: no sandbox policy is shipped, and Anthropic's own
# docs say bwrap cannot mount a fresh /proc in an unprivileged container. This is here because
# without the package codex prints "could not find system bubblewrap ... install bubblewrap with
# your package manager" at EVERY start, and a student can act on that advice with sudo and lose it
# again at the next --rebuild.
assert_ok "codex:system-bwrap-is-present" \
          sh -c "$VT_RUN --rm --network=none --entrypoint sh '$TEST_IMAGE' -c 'bwrap --version'"

# ─── the managed policy, and proof that codex actually reads it ────────────────
assert_ok "codex:managed-policy-present" \
          sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'test -f /etc/codex/managed_config.toml'"
assert_ok "codex:managed-policy-parses-in-the-image" \
          sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'python3 -c \"import tomllib;tomllib.load(open(1 and \\\"/etc/codex/managed_config.toml\\\",\\\"rb\\\"))\"'"
# Readable by the student, since codex runs as the student; not writable, or the policy is
# advisory. (sudo can still change it -- inherent to the sudo decision, and documented as such.)
assert_eq "codex:managed-policy-is-readable-by-student" "ok" \
    "$(R 'test -r /etc/codex/managed_config.toml && echo ok')"
assert_eq "codex:managed-policy-not-student-writable" "ok" \
    "$(R 'test ! -w /etc/codex/managed_config.toml && echo ok')"

# `codex doctor` reports the EFFECTIVE policy, so this is a functional check rather than a file
# check -- and it needs a positive control, because the two values the course ships are also
# codex's own defaults. On their own these assertions would pass just as well against an image
# carrying no policy at all, which is the "passes for the wrong reason" trap this suite records
# elsewhere.
# NO QUOTED PATTERNS in what R() runs: it hands the string to `sh -c`, so an inner "approval
# policy" arrives as two arguments and grep reads the second as a filename. `-e` twice, and a dot
# for the space, keeps the pattern a single shell word.
record    "codex:doctor-sandbox-line" \
          "$(R 'codex doctor 2>&1 | grep -e approval.policy -e filesystem.sandbox | tr -s " "' | tr '\n' ' ')"
assert_contains "codex:doctor-reports-the-shipped-approval-policy" "OnRequest" \
                "$(R 'codex doctor 2>&1 | grep -e approval.policy')"

# THE CONTROL. A managed file that says something DIFFERENT must change what doctor reports; if it
# does not, /etc/codex is not being read and the assertion above means nothing. Verified by hand
# before it was written here: untrusted surfaces as UnlessTrusted.
codex_probe="$(new_tmpdir)"
printf 'approval_policy = "untrusted"\n' > "$codex_probe/managed_config.toml"
assert_contains "codex:the-managed-policy-is-really-read" "UnlessTrusted" \
    "$($VT_RUN --rm --network=none -v "$codex_probe/managed_config.toml:/etc/codex/managed_config.toml:ro" \
       --entrypoint sh "$TEST_IMAGE" -c 'codex doctor 2>&1 | grep -E "approval policy"' 2>&1)"
rm -rf "$codex_probe"

# approvals_reviewer is NOT asserted here, and that is a limitation rather than an oversight:
# `codex doctor`, even with --all, never names the reviewer, so nothing in this suite can tell
# `user` from `auto_review`. Only a live escalation shows who answers it -- MANUAL.md carries that
# check. Worth knowing because codex ignores unknown keys in silence, so a future rename of this
# key would leave the course shipping a setting that does nothing.

# ─── Claude Code policy, in /etc so a rebuild restores it ──────────────────────
# Deliberately NOT under ~/.claude, which is a named volume: an image-provided file there
# is seeded once on first mount and then never refreshed by a later image.
assert_ok "claude:managed-settings-present" sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'test -f /etc/claude-code/managed-settings.json'"
# -f, not -e: it is a symlink now, and -f follows it, so this fails if the target went missing.
assert_ok "claude:CLAUDE.md-present"        sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'test -f /etc/claude-code/CLAUDE.md'"
assert_ok "claude:managed-settings-parses-in-the-image" \
          sh -c "$VT_RUN --rm --entrypoint sh '$TEST_IMAGE' -c 'python3 -c \"import json;json.load(open(1 and \\\"/etc/claude-code/managed-settings.json\\\"))\"'"
# INDEXED, NOT `.get`, AND AN EMPTY LIST IS NOT "ok" -- the same two corrections 10-static.sh's
# sibling check needed, and they matter MORE here: that file has an UNREADABLE guard and a
# forbidden-key check beside it, and this tier has neither, so this is the only assertion the
# image's copy of the policy has to get past.
#
# MEASURED THROUGH THIS IMAGE, not inferred from the static tier (#79). The three mutants were
# bind-mounted over /etc/claude-code/managed-settings.json in a throwaway -- the technique
# codex:the-managed-policy-is-really-read already uses a few lines up -- and the old form printed
# `rules-ok` for all three: an empty deny list, a renamed `deny`, and a renamed `permissions`.
# An empty list means Claude Code may read every credential store in the image.
#
# R() folds stderr into its answer, so a missing key arrives as a traceback rather than as
# silence, and this assertion fails on it. That is the guard idiom, paid for by the runner.
assert_eq "claude:deny-rules-are-Read-or-Edit-only" "rules-ok" \
    "$(R 'python3 -c "
import json
rules = json.load(open(\"/etc/claude-code/managed-settings.json\"))[\"permissions\"][\"deny\"]
bad = [x for x in rules if not x.startswith((\"Read(\", \"Edit(\"))]
print(\"NO-DENY-RULES\" if not rules else (\"BAD:\" + str(bad) if bad else \"rules-ok\"))"')"
# World-readable, since Claude Code runs as the student and must be able to read it.
assert_eq "claude:policy-is-readable-by-student" "ok" \
    "$(R 'test -r /etc/claude-code/managed-settings.json && test -r /etc/claude-code/CLAUDE.md && echo ok')"
# ...and NOT writable by the student, or the policy is advisory only. (sudo can still
# change it — that is inherent to the sudo decision and documented as such.)
assert_eq "claude:policy-not-student-writable" "ok" \
    "$(R 'test ! -w /etc/claude-code/managed-settings.json && echo ok')"

# ─── the two halves of #77 ──────────────────────────────────────────────────────
# The renderer, read out of the file the image actually ships rather than out of the repo copy
# 10-static.sh reads. Same sentinel discipline: "ABSENT" rather than the empty string, because
# an empty answer is also what a crashed python3 leaves behind.
assert_eq "claude:image-pins-the-fullscreen-renderer" "fullscreen" \
    "$(R 'python3 -c "import json;print(json.load(open(\"/etc/claude-code/managed-settings.json\")).get(\"tui\",\"ABSENT\"))"')"
# ...and the variable that keeps its copy-on-select from promising a paste route this container
# does not have. Asserted from a process's real environment rather than by reading the ENV line,
# so a layer ordering that dropped it would be caught.
#
# WHAT THIS DOES NOT PROVE, recorded rather than glossed: that Claude Code still honours the
# variable. It is internal and undocumented, there is no non-interactive readout of the renderer
# or the mouse mode, and the behavioural check needs a logged-in session. tests/MANUAL.md 7.11.
assert_eq "claude:image-turns-off-drag-selection" "1" \
    "$(R 'printf %s "$CLAUDE_CODE_DISABLE_MOUSE_CLICKS"')"

# ─── the entrypoint's ~/.claude.json symlink ────────────────────────────────────
# ~/.claude.json must be a FILE, and a single file cannot be a volume target, so the volume
# is a directory and the entrypoint symlinks into it. Idempotent, so it is safe on every
# start — assert that by running it twice.
assert_eq "entrypoint:creates-the-claude-json-symlink" "ok" \
    "$(R 'cs193v-entrypoint true >/dev/null 2>&1
          test -L /home/student/.claude.json && echo ok')"
assert_eq "entrypoint:symlink-points-into-the-volume" "/home/student/.claude-json/.claude.json" \
    "$(R 'cs193v-entrypoint true >/dev/null 2>&1; readlink /home/student/.claude.json')"
assert_eq "entrypoint:is-idempotent" "ok" \
    "$(R 'cs193v-entrypoint true >/dev/null 2>&1
          cs193v-entrypoint true >/dev/null 2>&1
          test -L /home/student/.claude.json && echo ok')"
assert_eq "entrypoint:seeds-valid-json" "ok" \
    "$(R 'cs193v-entrypoint true >/dev/null 2>&1
          python3 -c "import json;json.load(open(\"/home/student/.claude.json\"))" && echo ok')"
# Given a command it must exec it rather than entering the keep-alive loop, which is what
# lets `podman run IMAGE sh -c ...` work at all — including in these very tests.
assert_eq "entrypoint:execs-a-given-command" "handed-through" \
          "$($VT_RUN --rm "$TEST_IMAGE" sh -c 'echo handed-through' 2>&1)"
