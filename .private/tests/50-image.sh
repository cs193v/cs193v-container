#!/usr/bin/env bash
# TIER: image
#
# VERIFICATION.md §A.2 and §A.3 — what is actually inside the built image.
#
# Everything here runs in throwaway containers, so it needs the image but never the live
# cs193v container. Build it first:
#
#     ./cs193v --dev-build
#
# Three of §A.3's checks are corrected rather than copied:
#   * nvm-not-group-writable was vacuous. /usr/local/share/nvm does not exist by design —
#     node comes from the official tarball into root-owned /usr/local precisely so there is
#     no group-writable nvm tree to trojan — so `stat` failed, the case fell through to the
#     catch-all, and it printed "ok" while asserting nothing. Here it asserts the absence.
#   * the skopeo layer-size check was guarded by `command -v skopeo &&`, so it silently
#     did nothing on a machine without skopeo. It is now a real assertion.
#   * the multi-arch manifest assertion moved to the release tier: a local --dev-build is
#     single-arch by definition, so asserting two architectures here can only ever fail.

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

# No single layer should dominate: podman cannot resume a partial layer download but does
# keep completed ones, so a student on bad wifi loses at most one layer per retry. That is
# the whole reason for the layer ordering.
#
# `podman history`, not `skopeo inspect --raw containers-storage:`: the raw manifest is not
# available for a locally built image, so skopeo returns nothing and this check silently
# recorded "could not read" instead of asserting.
biggest="$(podman history --format '{{.Size}}' "$TEST_IMAGE" 2>/dev/null \
           | python3 -c 'import sys, re
best = 0
for line in sys.stdin:
    m = re.match(r"([0-9.]+)\s*([kKMGB]*B?)", line.strip())
    if not m:
        continue
    n = float(m.group(1))
    mult = {"B": 1, "kB": 1000, "MB": 1000**2, "GB": 1000**3}.get(m.group(2), 1)
    best = max(best, n * mult)
print(int(best))')"
if [ -n "$biggest" ] && [ "$biggest" -gt 0 ]; then
    record "img:largest-layer-mb" "$((biggest / 1048576))"
    if [ "$biggest" -lt 419430400 ]; then pass "img:no-layer-over-400MB"
    else fail "img:no-layer-over-400MB" \
              "largest layer is $((biggest / 1048576)) MB; a student whose wifi drops loses
that much on every retry, which is what the layer split exists to avoid"; fi
else
    fail "img:no-layer-over-400MB" "could not read layer sizes from podman history"
fi

# ─── §A.3 identity and ownership ───────────────────────────────────────────────
assert_eq "uid-gid-name" "1000 1000 student" "$(R 'echo $(id -u) $(id -g) $(id -un)')"
record    "passwd-student" "$(R 'getent passwd student')"
assert_eq "home-is-student" "/home/student" "$(R 'echo $HOME')"

# The load-bearing one. podman auto-chowns an EMPTY named volume to the container user on
# first mount, then re-chowns it to match the image's directory at the mount target if that
# directory exists — so a root-owned target yields a root-owned volume AND permanently
# disables further auto-chown. Getting these four right in the image is what lets the
# entrypoint run with no root phase and no `sudo chown -R`.
assert_eq "vol-targets-are-student-owned" "student student student student" \
    "$(R 'stat -c %U /home/student/.claude /home/student/.claude-json \
                     /home/student/.config/gh /home/student/.local/share/com.vercel.cli \
          | tr "\n" " " | sed "s/ $//"')"
# And they must exist before any volume is mounted, or podman creates them root-owned.
for d in .claude .claude-json .config/gh .local/share/com.vercel.cli .local/bin; do
    assert_ok "vol-target-exists:$d" sh -c "podman run --rm --entrypoint sh '$TEST_IMAGE' -c 'test -d /home/student/$d'"
done
assert_eq "projects-mount-is-student-owned" "student" "$(R 'stat -c %U /home/student/projects')"

# ─── tooling that must be present ──────────────────────────────────────────────
for cmd in node npm python3 git gh vercel claude nano less sudo tldr curl unzip; do
    assert_ok "have:$cmd" sh -c "podman run --rm --entrypoint sh '$TEST_IMAGE' -c 'command -v $cmd'"
done
record "versions" "$(R 'node -v; npm -v; python3 -V; gh --version | head -1; vercel --version; claude --version' | tr '\n' ' ')"
assert_ok "numpy-imports" sh -c "podman run --rm --entrypoint sh '$TEST_IMAGE' -c 'python3 -c \"import numpy\"'"

# Passwordless sudo is a deliberate course decision: CS193V trains students not to run
# commands on their host, so system changes must be possible from inside.
assert_ok "sudo-works-without-a-password" sh -c "podman run --rm --entrypoint sh '$TEST_IMAGE' -c 'sudo -n true'"

# git stays completely stock so students meet its real hints and errors.
assert_fail "no-etc-gitconfig" sh -c "podman run --rm --entrypoint sh '$TEST_IMAGE' -c 'test -e /etc/gitconfig'"
assert_eq "git-editor-is-nano" "nano" "$(R 'git var GIT_EDITOR')"
assert_ok "nanorc-installed" sh -c "podman run --rm --entrypoint sh '$TEST_IMAGE' -c 'test -f /home/student/.nanorc'"
assert_eq "nanorc-is-student-owned" "student" "$(R 'stat -c %U /home/student/.nanorc')"

# npm's global prefix points at the student's home so `npm install -g` works without sudo,
# while build-time globals stay in root-owned /usr/local.
assert_eq "npm-prefix-is-in-home" "/home/student/.local" "$(R 'npm config get prefix')"
assert_ok "npm-install-g-needs-no-sudo" \
          sh -c "podman run --rm --entrypoint sh '$TEST_IMAGE' -c 'test -w /home/student/.local/bin'"

# ─── the four helper commands ──────────────────────────────────────────────────
assert_ok "helper:am-i-in-a-container" sh -c "podman run --rm --entrypoint sh '$TEST_IMAGE' -c 'am-i-in-a-container'"
assert_contains "helper:identity-cue-says-yes" "you are inside" "$(R 'am-i-in-a-container')"
assert_contains "helper:identity-cue-explains-the-projects-dir" "/home/student/projects" "$(R 'am-i-in-a-container')"

# The $BROWSER stub: without it, `gh auth login` and `claude /login` leave a student
# staring at a prompt that never returns.
out="$(R '/usr/local/bin/open-url https://example.com/verify?code=ABCD')"
assert_contains "helper:open-url-prints-the-url" "https://example.com/verify?code=ABCD" "$out"
assert_contains "helper:open-url-explains-why"   "no browser" "$out"
assert_fail "helper:open-url-needs-an-argument" \
            sh -c "podman run --rm --entrypoint sh '$TEST_IMAGE' -c '/usr/local/bin/open-url'"

assert_ok "helper:ports-is-installed" sh -c "podman run --rm --entrypoint sh '$TEST_IMAGE' -c 'command -v ports'"
# Without CS193V_PORTS it must explain itself rather than crash or lie.
assert_contains "helper:ports-without-env-explains" "rebuild" "$(R 'ports 2>&1 || true')"
assert_contains "helper:ports-with-env-works" "forwarded:" \
                "$(R 'CS193V_PORTS=3000-3009 ports 2>&1 || true')"

# ─── things deliberately NOT installed ─────────────────────────────────────────
# Each was considered and rejected; re-adding one should break a test rather than slip in.
assert_eq "absent:no-extra-tools" "none" \
    "$(R 'for t in rg fzf delta bat fd chromium google-chrome chrome code; do command -v $t >/dev/null && echo $t; done; echo none')"
# man pages are stripped by the base image and deliberately not restored; tldr stands in.
#
# `man git` does NOT fail, though: Ubuntu's minimized image leaves a /usr/bin/man stub that
# exits 0 and prints "you can run the 'unminimize' command". So assert the property that
# actually matters — no real manual page is produced — and record the stub's behaviour,
# which is its own usability problem (see ERRORS.md B6: it points a novice at a command
# that bloats the container and does not survive a rebuild).
manout="$(R 'man git 2>&1; echo "rc=$?"')"
record "absent:man-behaviour" "$(printf '%s' "$manout" | tr '\n' ' ')"
assert_not_contains "absent:no-real-man-page-for-git" "GIT(1)" "$manout"
assert_not_contains "absent:man-db-not-installed"     "GITHUB" "$manout"
assert_ok "absent:tldr-stands-in-for-man" \
          sh -c "podman run --rm --entrypoint sh '$TEST_IMAGE' -c 'tldr --version'"

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
offline="$(podman run --rm --network=none --entrypoint sh "$TEST_IMAGE" -c 'tldr tar 2>&1' || true)"
assert_contains "tldr:works-offline" "Archiving utility" "$offline"
assert_not_contains "tldr:offline-does-not-error" "Traceback" "$offline"
# NOT vacuous, unlike VERIFICATION.md §A.3's version: node comes from the official tarball
# into root-owned /usr/local specifically so there is no group-writable nvm tree, which is
# the quietest way to trojan a shared node/npm with no sudo at all.
assert_fail "absent:no-nvm-tree" sh -c "podman run --rm --entrypoint sh '$TEST_IMAGE' -c 'test -e /usr/local/share/nvm'"
assert_eq "absent:node-is-root-owned" "root" "$(R 'stat -c %U $(command -v node)')"
assert_eq "absent:node-not-group-writable" "ok" \
    "$(R 'case "$(stat -c %A "$(command -v node)")" in ?????w*) echo BAD;; *) echo ok;; esac')"
# The global module tree must be root-owned too, wherever apt put it.
assert_eq "absent:global-node-modules-root-owned" "root" \
    "$(R 'stat -c %U "$(dirname "$(dirname "$(readlink -f "$(command -v node)")")")/lib/node_modules" 2>/dev/null || echo root')"
# Node must be apt-managed, so a student can pick up security fixes from inside.
assert_ok "node:is-an-apt-package" \
          sh -c "podman run --rm --entrypoint sh '$TEST_IMAGE' -c 'dpkg -s nodejs >/dev/null'"
record "node:apt-package-version" "$(R 'dpkg-query -Wf "\${Version}" nodejs')"
assert_eq "node:not-apt-mark-held" "" "$(R 'apt-mark showhold' | tr -d ' \n')"
assert_eq "absent:usr-local-lib-root-owned" "root" "$(R 'stat -c %U /usr/local/lib')"
# puppeteer would pull a whole Chrome; it is out, which is also why --shm-size is absent.
globals="$(R 'npm ls -g --depth=0 2>/dev/null')"
record "npm-globals" "$(printf '%s' "$globals" | tr '\n' ' ')"
assert_not_contains "absent:no-puppeteer" "puppeteer" "$globals"

# The build-time `npm install -g` layers must not leave root's npm cache in the image. It is
# pure dead weight in something students download over dorm wifi, and it inflates two of the
# three layers that the resume-on-failure design cares about. The apt layer already cleans
# /var/lib/apt/lists; this is the same hygiene for npm.
cache_mb="$(R 'sudo du -sm /root/.npm 2>/dev/null | cut -f1' | tr -d ' \n')"
record "img:root-npm-cache-mb" "${cache_mb:-0}"
if [ "${cache_mb:-0}" -lt 20 ]; then
    pass "img:npm-cache-not-baked-into-the-image"
else
    fail "img:npm-cache-not-baked-into-the-image" \
         "/root/.npm is ${cache_mb} MB. Add 'npm cache clean --force' to each npm layer."
fi

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
assert_ok "shell:profile.d-installed" sh -c "podman run --rm --entrypoint sh '$TEST_IMAGE' -c 'test -f /etc/profile.d/10-cs193v-shell.sh'"
assert_contains "shell:profile.d-disables-ixon" "stty -ixon" \
                "$(R 'cat /etc/profile.d/10-cs193v-shell.sh')"
assert_contains "shell:bashrc-also-disables-ixon" "stty -ixon" "$(R 'cat /etc/bash.bashrc')"

# ─── identity: hostname, banner, window title, goodbye  (#3, #4) ───────────────
assert_ok "identity:welcome-banner-installed" \
          sh -c "podman run --rm --entrypoint sh '$TEST_IMAGE' -c 'test -f /etc/profile.d/20-cs193v-welcome.sh'"
assert_eq "identity:welcome-banner-mode" "644" \
          "$(R 'stat -c %a /etc/profile.d/20-cs193v-welcome.sh')"
assert_ok "identity:bash_logout-installed" \
          sh -c "podman run --rm --entrypoint sh '$TEST_IMAGE' -c 'test -f /home/student/.bash_logout'"
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
# to be in the image. Assert it really is.
assert_contains "identity:banner-text-is-in-the-image" "Welcome to the CS193V" \
                "$(R 'cat /etc/profile.d/20-cs193v-welcome.sh')"

# ─── Claude Code policy, in /etc so a rebuild restores it ──────────────────────
# Deliberately NOT under ~/.claude, which is a named volume: an image-provided file there
# is seeded once on first mount and then never refreshed by a later image.
assert_ok "claude:managed-settings-present" sh -c "podman run --rm --entrypoint sh '$TEST_IMAGE' -c 'test -f /etc/claude-code/managed-settings.json'"
assert_ok "claude:CLAUDE.md-present"        sh -c "podman run --rm --entrypoint sh '$TEST_IMAGE' -c 'test -f /etc/claude-code/CLAUDE.md'"
assert_ok "claude:managed-settings-parses-in-the-image" \
          sh -c "podman run --rm --entrypoint sh '$TEST_IMAGE' -c 'python3 -c \"import json;json.load(open(1 and \\\"/etc/claude-code/managed-settings.json\\\"))\"'"
assert_eq "claude:deny-rules-are-Read-or-Edit-only" "rules-ok" \
    "$(R 'python3 -c "
import json
d = json.load(open(\"/etc/claude-code/managed-settings.json\"))
bad = [x for x in d.get(\"permissions\", {}).get(\"deny\", []) if not x.startswith((\"Read(\", \"Edit(\"))]
print(\"BAD:\" + str(bad) if bad else \"rules-ok\")"')"
# World-readable, since Claude Code runs as the student and must be able to read it.
assert_eq "claude:policy-is-readable-by-student" "ok" \
    "$(R 'test -r /etc/claude-code/managed-settings.json && test -r /etc/claude-code/CLAUDE.md && echo ok')"
# ...and NOT writable by the student, or the policy is advisory only. (sudo can still
# change it — that is inherent to the sudo decision and documented as such.)
assert_eq "claude:policy-not-student-writable" "ok" \
    "$(R 'test ! -w /etc/claude-code/managed-settings.json && echo ok')"

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
          "$(podman run --rm "$TEST_IMAGE" sh -c 'echo handed-through' 2>&1)"
