# CS193V course container.
#
# Build:   podman build -t localhost/cs193v:dev .
# CI:      see .github/workflows/build.yml (multi-arch, pushed to ghcr.io)
#
# LAYER ORDERING IS DELIBERATE. podman cannot resume a partial layer download, but it
# does keep completed layers — so a student whose wifi drops mid-pull loses at most one
# layer on retry. The most volatile software (claude-code) goes LAST, so bumping it
# invalidates only a small final layer instead of forcing a full rebuild.
#
# Everything below is deliberate; see CONTAINER-DESIGN.md for the reasoning.

FROM ubuntu:26.04

# Pin these in CI. `latest` is a placeholder so a local `podman build` works out of the
# box; a published image MUST be built with explicit versions or the digest pin is a lie.
ARG NODE_VERSION=24.18.1
ARG VERCEL_VERSION=latest
ARG CLAUDE_CODE_VERSION=latest

ARG DEBIAN_FRONTEND=noninteractive

# ─────────────────────────────────────────────────────────────────────────────
# Layer 1 — system packages
# ─────────────────────────────────────────────────────────────────────────────
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl wget \
      git build-essential \
      python3 python3-pip python3-numpy pipx \
      nano less sudo uidmap \
      procps psmisc file unzip zip xz-utils \
      locales tzdata \
      fonts-noto-core \
 && locale-gen en_US.UTF-8 \
 && rm -rf /var/lib/apt/lists/*
# fonts-noto-core, not fonts-dejavu-core: the base image ships no fonts at all, and
# anything that rasterizes text (Pillow, matplotlib, librsvg) needs one. Noto because a
# large share of the web uses it, so rendered output looks unremarkable rather than
# unmistakably-Linux. Terminal emoji and CJK come from the HOST terminal's fonts.

# ─────────────────────────────────────────────────────────────────────────────
# The student account. uid/gid 1000 is the Debian/Ubuntu convention for the first
# human user, which makes --userns=keep-id line up on Ubuntu and WSL without
# translation. Passwordless sudo is a deliberate course decision: CS193V trains
# students not to run commands on their host, so system changes must be possible
# from inside. See CONTAINER-DESIGN.md § "What sudo costs you".
#
# The pre-existing occupant of 1000 has to go first. Since 23.04 the Ubuntu base image
# ships its own `ubuntu` user at uid AND gid 1000, so a bare `groupadd -g 1000` fails
# with "GID '1000' already exists" and exits 4, which aborts the build. Deleting it is
# right rather than reusing it: the account is named in every prompt, path and error a
# student reads, and `--userns=keep-id:uid=1000,gid=1000` pins the number, so the name
# has to be ours.
#
# Guarded with getent rather than assumed, so this keeps working on a future base image
# that drops the default user — and userdel removes the primary group with the user when
# nothing else uses it, which is why the group check comes after and is separate.
# ─────────────────────────────────────────────────────────────────────────────
RUN set -eux; \
    if getent passwd 1000 >/dev/null; then \
      existing_user="$(getent passwd 1000 | cut -d: -f1)"; \
      userdel -r "$existing_user" 2>/dev/null || userdel "$existing_user"; \
    fi; \
    if getent group 1000 >/dev/null; then \
      groupdel "$(getent group 1000 | cut -d: -f1)"; \
    fi; \
    groupadd -g 1000 student; \
    useradd -u 1000 -g 1000 -m -s /bin/bash student; \
    printf 'student ALL=(root) NOPASSWD:ALL\n' > /etc/sudoers.d/90-student; \
    chmod 0440 /etc/sudoers.d/90-student; \
    test "$(id -u student)" = 1000; \
    test "$(id -g student)" = 1000

# ─────────────────────────────────────────────────────────────────────────────
# Layer 2 — Node, from NodeSource's apt repository.
#
# apt-managed on purpose, so `apt upgrade` inside the container picks up Node security
# fixes. A tarball unpacked into /usr/local cannot be updated by anything a student runs:
# every CVE would need an image rebuild and a NODE_VERSION bump, and until that shipped
# there would be no way to patch it from inside.
#
# NodeSource rather than Ubuntu's own nodejs, because Ubuntu 26.04 carries node 22.22.1
# with npm 9.2.0 — two majors behind on both — and de-bundles npm's vendored dependencies
# into ~70 separate node-* packages, which diverges from what every tutorial a student
# reads will do. NodeSource's nodistro suite carries amd64 and arm64, so one repo line
# serves both legs of the manifest.
#
# NOT nvm. The devcontainer's nvm tree is drwxrwsr-x vscode:nvm — group-writable AND
# setgid — so an agent can trojan the shared node/npm install with NO sudo at all, which
# makes it the quietest tampering path available. apt installs root-owned into /usr/bin and
# /usr/lib/node_modules, which removes that by construction.
#
# The exact patch version is pinned for a reproducible build, but the package is
# deliberately NOT apt-mark hold'd — holding it would re-create the problem the switch away
# from the tarball was meant to solve.
#
# The key is stored armored as .asc, which apt reads directly, so this needs no gnupg.
# ─────────────────────────────────────────────────────────────────────────────
RUN set -eux; \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      -o /etc/apt/keyrings/nodesource.asc; \
    chmod go+r /etc/apt/keyrings/nodesource.asc; \
    printf 'deb [signed-by=/etc/apt/keyrings/nodesource.asc] https://deb.nodesource.com/node_%s.x nodistro main\n' \
      "${NODE_VERSION%%.*}" > /etc/apt/sources.list.d/nodesource.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends "nodejs=${NODE_VERSION}-1nodesource1"; \
    rm -rf /var/lib/apt/lists/*; \
    test "$(node --version)" = "v${NODE_VERSION}"; \
    node --version; npm --version

# ─────────────────────────────────────────────────────────────────────────────
# Layer 3 — GitHub CLI
# ─────────────────────────────────────────────────────────────────────────────
RUN set -eux; \
    mkdir -p /etc/apt/keyrings; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
      "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh; \
    rm -rf /var/lib/apt/lists/*; \
    gh --version

# ─────────────────────────────────────────────────────────────────────────────
# Layer 4 — Vercel CLI
# ─────────────────────────────────────────────────────────────────────────────
RUN npm install -g "vercel@${VERCEL_VERSION}" && vercel --version

# ─────────────────────────────────────────────────────────────────────────────
# Layer 5 — Claude Code.  MOST VOLATILE: keep it last so a version bump
# invalidates only this layer and the small config layer after it.
# ─────────────────────────────────────────────────────────────────────────────
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" && claude --version

# ─────────────────────────────────────────────────────────────────────────────
# Layer 6 — course configuration
# ─────────────────────────────────────────────────────────────────────────────

# tldr, installed system-wide via pipx. Stands in for man pages, which the Ubuntu base
# image strips and which we deliberately do not restore.
#
# PIPX_HOME/PIPX_BIN_DIR are set INLINE, not as ENV: as ENV they would persist into the
# runtime and point a student's own `pipx install` at root-owned /usr/local, where it
# would fail.
RUN PIPX_HOME=/usr/local/pipx PIPX_BIN_DIR=/usr/local/bin \
    pipx install tldr \
 && tldr --version

COPY files/ /tmp/cs193v-files/

# NOTE ON STYLE: no `#` comments inside the RUN below. The Dockerfile parser does strip
# comment lines inside a line continuation, but relying on that is fragile — if it ever
# did not apply, a comment line would swallow the command after it and silently produce a
# broken image. So the explanation lives here and the RUN body stays comment-free.
#
# What it does, in order:
#
#  1. Installs the four helper commands: the $BROWSER stub, the milestone check, the
#     `ports` diagnostic, and the entrypoint.
#
#  2. Installs the Claude Code course policy into /etc/claude-code — deliberately NOT
#     under ~/.claude, which is a named volume: an image-provided file there is seeded
#     once on first mount and then never refreshed by a later image. /etc is in the image
#     layer, so --rebuild and every image update restore it. The JSON is parsed at build
#     time so a typo fails the build instead of a student's session.
#
#  3. Turns off XON/XOFF flow control for interactive shells, via both profile.d (login
#     shells) and bash.bashrc (interactive non-login). Ctrl-S is "save" in every GUI
#     editor; on a terminal it freezes all output with no echo, which looks exactly like
#     a crash, and the recovery (Ctrl-Q) is unknown to novices.
#
#  4. Installs the nanorc.
#
#  5. Pre-creates every volume mount point STUDENT-OWNED. This is the load-bearing part.
#     podman auto-chowns an EMPTY named volume to the container user on first mount, then
#     re-chowns it to match the image's directory at the mount target if that directory
#     exists — and a root-owned target both yields a root-owned volume AND permanently
#     disables further auto-chown. Getting this right here is what lets the entrypoint
#     run with no root phase and no sudo, which is what the devcontainer's five
#     `sudo chown -R` calls were working around.
#
#  6. Points npm's global prefix at the student's home, so `npm install -g` works without
#     sudo. Build-time globals stay in root-owned /usr/local.
#
#  7. Removes /etc/gitconfig if the base image has one. git stays completely stock so
#     students meet its real hints and errors. The `git commit` editor trap is closed by
#     EDITOR/VISUAL below, NOT by core.editor: git resolves
#     GIT_EDITOR -> core.editor -> VISUAL -> EDITOR -> vi.
RUN set -eux; \
    install -m 0755 /tmp/cs193v-files/open-url             /usr/local/bin/open-url; \
    install -m 0755 /tmp/cs193v-files/am-i-in-a-container  /usr/local/bin/am-i-in-a-container; \
    install -m 0755 /tmp/cs193v-files/ports                /usr/local/bin/ports; \
    install -m 0755 /tmp/cs193v-files/entrypoint.sh        /usr/local/bin/cs193v-entrypoint; \
    install -d -m 0755 /etc/claude-code; \
    install -m 0644 /tmp/cs193v-files/claude-code/managed-settings.json /etc/claude-code/managed-settings.json; \
    install -m 0644 /tmp/cs193v-files/claude-code/CLAUDE.md             /etc/claude-code/CLAUDE.md; \
    python3 -c "import json;json.load(open('/etc/claude-code/managed-settings.json'))"; \
    install -m 0644 /tmp/cs193v-files/profile.d/10-cs193v-shell.sh /etc/profile.d/10-cs193v-shell.sh; \
    cat /tmp/cs193v-files/profile.d/10-cs193v-shell.sh >> /etc/bash.bashrc; \
    install -o student -g student -m 0644 /tmp/cs193v-files/nanorc /home/student/.nanorc; \
    install -d -o student -g student -m 0700 /home/student/.claude; \
    install -d -o student -g student -m 0700 /home/student/.claude-json; \
    install -d -o student -g student -m 0755 /home/student/.config; \
    install -d -o student -g student -m 0700 /home/student/.config/gh; \
    install -d -o student -g student -m 0755 /home/student/.local; \
    install -d -o student -g student -m 0755 /home/student/.local/share; \
    install -d -o student -g student -m 0700 /home/student/.local/share/com.vercel.cli; \
    install -d -o student -g student -m 0755 /home/student/.local/bin; \
    install -d -o student -g student -m 0755 /workspaces; \
    su student -s /bin/sh -c 'npm config set prefix /home/student/.local'; \
    rm -f /etc/gitconfig; \
    rm -rf /tmp/cs193v-files

# Populate tldr's cache as the student so it works offline on first use.
RUN su student -s /bin/sh -c 'tldr --update' || true

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    PATH=/home/student/.local/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin \
    EDITOR=nano \
    VISUAL=nano \
    PAGER=less \
    LESS=FRX \
    HOST=0.0.0.0 \
    FLASK_RUN_HOST=0.0.0.0 \
    BROWSER=/usr/local/bin/open-url
# GIT_EDITOR is deliberately NOT set. With GIT_EDITOR, core.editor, VISUAL and EDITOR all
# unset, `git var GIT_EDITOR` returns `vi` and /usr/bin/vi is vim.tiny — so `git commit`
# with no -m strands a novice in a modal editor with no visible way out. The VS Code
# extension hides this today by exporting GIT_EDITOR=true; we fix it properly instead.
#
# LESS=FRX is git's own default (PAGER_ENV in git's Makefile): F quits if the output fits
# one screen, R passes ANSI colour through, X leaves output on screen instead of wiping
# it. Setting it here extends that to man, journalctl and a student's own `... | less`.
#
# HOST/FLASK_RUN_HOST are a partial measure only. Verified: vite reads NO host env var
# (server.host defaults to 'localhost', settable only by config or --host) and Next.js
# reads HOSTNAME, not HOST. Enforcing the bind-address rule is deliberately deferred;
# see CONTAINER-DESIGN.md § Ports.

USER student
WORKDIR /workspaces

ENTRYPOINT ["/usr/local/bin/cs193v-entrypoint"]
