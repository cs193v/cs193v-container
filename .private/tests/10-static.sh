#!/usr/bin/env bash
# TIER: static
#
# VERIFICATION.md §A.1, plus the invariants the repo documents in prose but nothing
# enforces. No podman, no image, no network.
#
# Three §A.1 checks are corrected here rather than copied:
#   * the .gitignore greps need -F. `grep -x 'projects/*'` treats * as a BRE quantifier,
#     so it matches "projects", "projects/", "projects//" — never the literal line, and
#     the check silently never fired.
#   * the messages cross-reference needs LC_ALL=C. Under en_US.UTF-8, sort and comm
#     disagree about punctuation and comm aborts with "file 1 is not in sorted order".
#   * the ban-list greps must strip comments first, or the scripts' own documentation of
#     the ban matches itself.

set -u
. "$(dirname -- "$0")/lib/assert.sh"

cd "$REPO" || exit 1

# ─── syntax ────────────────────────────────────────────────────────────────────
assert_ok  "syntax:cs193v"            bash -n cs193v
assert_ok  "syntax:install"           bash -n $PRIVATE/install-cs193v.sh
assert_ok  "syntax:entrypoint"        bash -n $PRIVATE/files/entrypoint.sh
assert_ok  "syntax:profile.d"         bash -n $PRIVATE/files/profile.d/10-cs193v-shell.sh
assert_ok  "syntax:open-url"          sh -n $PRIVATE/files/open-url
assert_ok  "syntax:am-i-in-container"  sh -n $PRIVATE/files/am-i-in-a-container
assert_ok  "syntax:man"               sh -n $PRIVATE/files/man
assert_ok  "syntax:ports"             python3 -c "import ast;ast.parse(open('$PRIVATE/files/ports').read())"
assert_ok  "syntax:podman-fake"       sh -n $PRIVATE/tests/lib/podman-fake
assert_ok  "syntax:run-tests"         bash -n $PRIVATE/tests/run-tests.sh

assert_exec "exec:cs193v"             "$REPO/cs193v"
assert_exec "exec:install"            "$PRIVATE/install-cs193v.sh"

# ─── bash 3.2 compatibility ────────────────────────────────────────────────────
# macOS ships bash 3.2 and the launcher is the same script on every platform, so a bash 4
# construct is a Mac-only breakage that no Linux test run would ever surface.
BASH4='declare -A|mapfile|readarray|\$\{[A-Za-z_]+,,\}|\$\{[A-Za-z_]+\^\^\}|[[:space:]]\|&[[:space:]]|&>>'
hits="$(sed 's/#.*//' cs193v $PRIVATE/install-cs193v.sh | grep -nE "$BASH4" || true)"
assert_eq  "bash32:no-bash4-constructs" "" "$hits"

hits="$(sed 's/#.*//' cs193v $PRIVATE/install-cs193v.sh | grep -nE 'read[^|]*-t *0?\.[0-9]' || true)"
assert_eq  "bash32:no-fractional-read-t" "" "$hits"

# The test suite itself has to run on bash 3.2, since the TAs use it on Macs to settle
# VERIFICATION.md §5.2/§5.3. The BASH4= assignment below is excluded, or the ban list
# matches its own definition.
#
# THE GLOB IS `tests/*.sh`, TOP LEVEL ONLY, AND tests/tmux-harness/ IS EXEMPT ON PURPOSE.
# Do not widen it. That directory is copied into the container and run there, by the
# container's own bash 5 -- it never executes on the host, so bash 3.2 is not a constraint
# on it, and holding it to one would mean rewriting vendored code for a platform it will
# never see. Its host-side driver, 65-tmux.sh, IS top level and so IS covered here, which
# is the part that matters.
hits="$(sed 's/#.*//' $PRIVATE/tests/run-tests.sh $PRIVATE/tests/lib/assert.sh $PRIVATE/tests/lib/podman-shim.sh $PRIVATE/tests/*.sh \
        | grep -v 'BASH4=' | grep -nE "$BASH4" || true)"
assert_eq  "bash32:tests-are-bash32-safe" "" "$hits"

# Expanding an empty array under `set -u` is fatal on bash < 4.4. Every such expansion
# must be guarded with the ${arr[@]+"${arr[@]}"} idiom.
bare="$(grep -nE '"\$\{(ARGS|RUN_ARGS|NEEDS|NEEDS_WHY|opts)\[@\]\}"' cs193v $PRIVATE/install-cs193v.sh \
        | grep -vE '\+"\$\{' || true)"
assert_eq  "bash32:empty-array-expansions-guarded" "" "$bare"

# ─── Containerfile ─────────────────────────────────────────────────────────────
# A `#` line inside a line-continued RUN is stripped by the parser today, but if that ever
# changed the comment would swallow the command after it and silently produce a broken
# image. The Containerfile documents this rule; this enforces it.
bad="$(awk '/\\$/{cont=1; next} cont && /^[[:space:]]*#/{print FILENAME":"NR": "$0} {cont=0}' $PRIVATE/Containerfile)"
assert_eq  "containerfile:no-comments-in-continuations" "" "$bad"

# Whole-line comments blanked, line NUMBERS preserved, so an ordering check cannot match the
# Containerfile's own prose about the thing it is checking. Layer 2's comment contains the
# words "every `npm install -g` in this file depends on them", which is exactly that trap —
# the same one the ban-list greps at the top of this file have to dodge.
cf_code="$(sed 's/^[[:space:]]*#.*//' $PRIVATE/Containerfile)"
cf_grep() { printf '%s\n' "$cf_code" | grep -nE "$1" | head -1 | cut -d: -f1; }

# Layer order is load-bearing: podman cannot resume a partial layer download but does keep
# completed ones, so the most volatile software must come last. If claude-code moved
# earlier, every version bump would re-download node, gh and vercel too.
#
# Quote-agnostic: the install lines are wrapped in `su student -s /bin/sh -c "..."` now, so
# the package name is single-quoted inside a double-quoted string.
ln_node="$(cf_grep 'deb\.nodesource\.com')"
ln_gh="$(cf_grep 'cli\.github\.com/packages')"
ln_vercel="$(cf_grep "npm install -g [\"']vercel")"
ln_claude="$(cf_grep "npm install -g [\"']@anthropic-ai/claude-code")"
if [ -n "$ln_claude" ] && [ -n "$ln_vercel" ] && [ -n "$ln_gh" ] && [ -n "$ln_node" ] \
   && [ "$ln_claude" -gt "$ln_vercel" ] && [ "$ln_vercel" -gt "$ln_gh" ] && [ "$ln_gh" -gt "$ln_node" ]; then
    pass "containerfile:claude-code-is-last-software-layer"
else
    fail "containerfile:claude-code-is-last-software-layer" \
         "want node < gh < vercel < claude-code; got node=$ln_node gh=$ln_gh vercel=$ln_vercel claude=$ln_claude"
fi

# EACH VERSION ARG MUST SIT NEXT TO THE LAYER THAT USES IT, never in a tidy block at the
# top of the file. This is a performance contract, and it is invisible: buildah folds every
# in-scope build arg into each step's cache key, so an ARG declared above the RUN steps
# invalidates the cache for all of them. Measured — bumping CLAUDE_CODE_VERSION with the
# ARGs at the top cost 250 s and 726 MB (18 of 23 steps re-ran); with each declared at its
# point of use, 89 s and 95 MB. Nothing breaks if someone tidies them back into a block, so
# nothing would catch it. This does. See ERRORS.md B5.
cf_lines="$(sed 's/#.*//' $PRIVATE/Containerfile)"
for pair in NODE_VERSION:nodesource PLAYWRIGHT_VERSION:playwright@ VERCEL_VERSION:vercel@ CLAUDE_CODE_VERSION:claude-code@; do
    var="${pair%%:*}"; use="${pair#*:}"
    ln_arg="$(printf '%s\n' "$cf_lines" | grep -n "^ARG $var=" | head -1 | cut -d: -f1)"
    ln_use="$(printf '%s\n' "$cf_lines" | grep -nF "$use" | head -1 | cut -d: -f1)"
    if [ -z "$ln_arg" ] || [ -z "$ln_use" ]; then
        fail "containerfile:$var-declared-near-its-use" "could not locate ARG ($ln_arg) or use ($ln_use)"
    elif [ "$ln_arg" -lt "$ln_use" ] && [ $(( ln_use - ln_arg )) -le 12 ]; then
        pass "containerfile:$var-declared-near-its-use"
    else
        fail "containerfile:$var-declared-near-its-use" \
             "ARG $var is at line $ln_arg but is first used at line $ln_use ($(( ln_use - ln_arg )) lines later).
An ARG invalidates podman's build cache for every step below it, so declaring this one far
from its layer makes a one-line version bump cost every student a full rebuild. Move it to
sit directly above the RUN that uses it."
    fi
done

# Node is apt-managed, so `apt upgrade` inside the container can pick up security fixes —
# a tarball in /usr/local cannot be patched by anything a student runs. Authenticity comes
# from the signed repository rather than a hand-checked SHASUMS file.
assert_ok  "containerfile:node-from-signed-apt-repo" \
           grep -q 'signed-by=/etc/apt/keyrings/nodesource.asc' $PRIVATE/Containerfile
assert_ok  "containerfile:node-version-pinned-exactly" \
           grep -q 'nodejs=\${NODE_VERSION}-1nodesource1' $PRIVATE/Containerfile
assert_ok  "containerfile:node-version-asserted-at-build-time" \
           grep -q 'test "\$(node --version)" = "v\${NODE_VERSION}"' $PRIVATE/Containerfile
# Holding the package would re-create exactly the problem that moving off the tarball fixed.
assert_not_contains "containerfile:node-not-apt-mark-held" "apt-mark hold nodejs" \
                    "$(cat $PRIVATE/Containerfile)"
# No tarball left behind.
assert_not_contains "containerfile:no-node-tarball-download" "nodejs.org/dist" \
                    "$(cat $PRIVATE/Containerfile)"

# ─── the globals go in the STUDENT's npm prefix  (issue #13) ───────────────────
# Every `npm install -g` in the build must run as `student`. Installed as root they land in
# nodesource's /usr prefix while the student's is ~/.local — npm reads one prefix, so the
# tools become invisible to `npm ls -g` and updates write a second copy elsewhere on PATH.
#
# Asserted here, in milliseconds, rather than only in the image tier: reverting this costs a
# ~2 GB rebuild to discover otherwise.
for pkg in playwright vercel '@anthropic-ai/claude-code'; do
    line="$(printf '%s\n' "$cf_code" | grep -nE "npm install -g [\"']$pkg" | head -1)"
    case "$line" in
        *"su student"*) pass "containerfile:$pkg-installed-as-student" ;;
        '') fail "containerfile:$pkg-installed-as-student" "no 'npm install -g $pkg' line found" ;;
        *)  fail "containerfile:$pkg-installed-as-student" \
                 "installed as root — it must run under 'su student':
$line" ;;
    esac
done
# The prefix has to be configured BEFORE the first install, or that install silently uses
# root's and the ordering above buys nothing. Comment-stripped, or layer 2's own prose about
# `npm install -g` matches ahead of any actual install line.
ln_prefix="$(cf_grep 'npm config set prefix /home/student/\.local')"
ln_firstglobal="$(cf_grep 'npm install -g')"
if [ -n "$ln_prefix" ] && [ -n "$ln_firstglobal" ] && [ "$ln_prefix" -lt "$ln_firstglobal" ]; then
    pass "containerfile:npm-prefix-set-before-first-global-install"
else
    fail "containerfile:npm-prefix-set-before-first-global-install" \
         "want prefix < first install; got prefix=${ln_prefix:-none} first-install=${ln_firstglobal:-none}"
fi
# ~/.local/lib/node_modules must be pre-created, or `npm ls -g` on an untouched prefix exits
# 254 with ENOENT instead of printing an empty tree.
assert_ok "containerfile:student-node-modules-precreated" \
          grep -qE 'install -d -o student -g student .*/home/student/\.local/lib/node_modules' \
          $PRIVATE/Containerfile

args_live_early="$(sed 's/#.*//' $REPO/.config/container.args)"
# ─── identity: hostname, banner, title, goodbye  (issues #3 and #4) ────────────
# The hostname is the cheapest possible "you are somewhere else" signal: it lands in the
# default prompt on every line, survives nano, and costs nothing. Without it the prompt
# reads student@<random hex>, which tells a student nothing.
assert_contains "args:hostname-is-cs193v-development" "--hostname cs193v-development" \
                "$args_live_early"

assert_ok  "containerfile:installs-the-welcome-banner" \
           grep -q '20-cs193v-welcome.sh /etc/profile.d/' $PRIVATE/Containerfile
assert_ok  "containerfile:installs-bash-logout" \
           grep -qE 'bash_logout .*/home/student/.bash_logout' $PRIVATE/Containerfile

# ~/.bashrc sets the window title THROUGH PS1 and re-emits it every prompt, so a title set
# once at login is immediately overwritten. The image rewrites that one escape.
assert_ok  "containerfile:rewrites-the-bashrc-window-title" \
           grep -q 'CS193V Development Environment' $PRIVATE/Containerfile

# The banner runs INSIDE the container, which cannot reach messages.txt — only projects/ is
# mounted. So this text has to live in the image, and must not be "tidied" into messages.txt
# later, which would silently blank the banner.
#
# The TEXT lives in files/cs193v-welcome and the DECISION to print it lives in
# files/profile.d/20-cs193v-welcome.sh. They were split when tmux became the landing point:
# tmux runs the login shell in every tab, so profile.d fires per-tab, while the banner must
# appear once. The first tab gets it from cs193v-shell; profile.d now covers only the
# non-tmux path, `podman exec -it cs193v bash -l`.
# ─── the shared strings ────────────────────────────────────────────────────────
# The text the container prints is defined once, in files/cs193v-strings.sh, and read by
# the scripts that print it AND by this suite (lib/assert.sh sources it). So these check the
# DEFINITIONS are present and non-empty; the checks further down then use the values rather
# than repeating them, and rewording a string no longer reddens tests in three tiers.
assert_ok  "strings:file-exists" test -f $PRIVATE/files/cs193v-strings.sh
assert_ok  "strings:syntax"      sh -n $PRIVATE/files/cs193v-strings.sh
assert_ne  "strings:title-is-defined"   "" "${CS193V_TITLE:-}"
assert_ne  "strings:welcome-is-defined" "" "${CS193V_WELCOME:-}"
assert_ne  "strings:goodbye-is-defined" "" "${CS193V_GOODBYE:-}"
assert_ok  "containerfile:installs-the-strings" \
           grep -q 'cs193v-strings.sh  */etc/cs193v/strings.sh' $PRIVATE/Containerfile

assert_ok  "welcome:script-exists" test -f $PRIVATE/files/cs193v-welcome
# The script must SOURCE the shared definitions rather than carry its own copy, or the two
# drift and the tests go on passing against text nobody sees.
assert_contains "welcome:reads-the-shared-strings" '/etc/cs193v/strings.sh' \
                "$(cat $PRIVATE/files/cs193v-welcome)"
assert_contains "welcome:has-the-welcome-line" 'CS193V_WELCOME' \
                "$(cat $PRIVATE/files/cs193v-welcome)"
assert_not_contains "welcome:text-is-NOT-in-$PRIVATE/messages.txt" "$CS193V_WELCOME" \
                    "$(cat $PRIVATE/messages.txt)"
# [3J clears the SCROLLBACK too, which is what "prior commands are no longer visible" means.
assert_contains "welcome:clears-scrollback-not-just-screen" '[3J' \
                "$(cat $PRIVATE/files/cs193v-welcome)"
assert_ok  "welcome:syntax" sh -n $PRIVATE/files/cs193v-welcome

assert_ok  "welcome:hook-exists" test -f $PRIVATE/files/profile.d/20-cs193v-welcome.sh
# Interactive-only, matching 10-cs193v-shell.sh, so `podman exec cs193v <cmd>` and every
# non-interactive call in this suite stay silent.
assert_contains "welcome:guards-on-interactive-shell" 'case $- in' \
                "$(cat $PRIVATE/files/profile.d/20-cs193v-welcome.sh)"
# The $TMUX guard is what keeps the banner out of every new tab. Without it, CTRL+T clears
# the pane and redraws the box, which is the failure the split above exists to prevent.
assert_contains "welcome:hook-skips-inside-tmux" 'TMUX' \
                "$(cat $PRIVATE/files/profile.d/20-cs193v-welcome.sh)"
assert_ok  "welcome:hook-syntax" sh -n $PRIVATE/files/profile.d/20-cs193v-welcome.sh

assert_ok  "logout:script-exists" test -f $PRIVATE/files/cs193v-goodbye
assert_contains "logout:reads-the-shared-strings" '/etc/cs193v/strings.sh' \
                "$(cat $PRIVATE/files/cs193v-goodbye)"
assert_contains "logout:says-goodbye" 'CS193V_GOODBYE' "$(cat $PRIVATE/files/cs193v-goodbye)"
assert_ok  "logout:syntax" sh -n $PRIVATE/files/cs193v-goodbye
assert_ok  "logout:hook-exists" test -f $PRIVATE/files/bash_logout
# Same reason as the banner: .bash_logout fires once per TAB inside tmux, so the farewell
# would print into a pane that is closing, for something the student has not left.
assert_contains "logout:hook-skips-inside-tmux" 'TMUX' "$(cat $PRIVATE/files/bash_logout)"
assert_ok  "logout:hook-syntax" sh -n $PRIVATE/files/bash_logout

# ─── man  (issue #8) ───────────────────────────────────────────────────────────
# Manual pages are deliberately absent and tldr stands in, but Ubuntu's minimized base
# leaves a /usr/bin/man of its own that exits 0 and says to run `unminimize` — which a
# first-year student reads as an instruction, and which downloads hundreds of megabytes
# into a container the next --rebuild discards. Our stub replaces it.
#
# /usr/bin, not /usr/local/bin: shadowing would leave the original reachable by full path
# and to anything with a fixed PATH. If this assertion is ever "fixed" by moving the
# install to /usr/local/bin, the unminimize advice comes straight back.
assert_ok  "man:script-exists" test -f $PRIVATE/files/man
assert_ok  "man:containerfile-replaces-usr-bin-man" \
           grep -qE 'files/man +/usr/bin/man' $PRIVATE/Containerfile
# grep, not assert_not_contains: its needle is matched literally, so a `*` in it would
# assert nothing at all rather than acting as a wildcard.
assert_fail "man:not-shadowed-from-usr-local" \
            grep -qE 'files/man +/usr/local/bin' $PRIVATE/Containerfile
man_stub="$(cat $PRIVATE/files/man)"
assert_contains "man:points-at-tldr"      'tldr'   "$man_stub"
assert_contains "man:stub-exits-nonzero"  'exit 1' "$man_stub"
# The one word that must never reach a student from this container.
assert_not_contains "man:never-says-unminimize" "unminimize" "$(sed 's/#.*//' $PRIVATE/files/man)"
# And the build refuses an image whose `man git` still carries the base image's advice, so
# a base-image change that reinstates it fails CI rather than a student.
assert_ok  "man:build-checks-the-stub-took" \
           grep -q 'man git 2>&1 | grep -F unminimize' $PRIVATE/Containerfile

# ─── ssh, scp and telnet  (issue #2) ───────────────────────────────────────────
# These are course tools: logging into a remote machine, copying a file across, and typing
# an HTTP request at a web server by hand. They are named on the apt line rather than
# arriving as a dependency of something else — `ssh` and `scp` were in the image for a year
# only because openssh-server Depends on openssh-client, which is not a promise. If the
# tunnel ever stopped needing sshd, they would vanish and the only symptom would be a lab
# exercise that no longer works.
apt_line="$(sed -n '/^RUN apt-get update/,/rm -rf \/var\/lib\/apt\/lists/p' $PRIVATE/Containerfile)"
assert_contains "net:openssh-client-named-explicitly" "openssh-client" "$apt_line"
assert_contains "net:telnet-installed"                "inetutils-telnet" "$apt_line"
# `telnet` on Ubuntu 26.04 is a transitional dummy whose whole content is a dependency on
# inetutils-telnet, and transitional packages get removed. Naming it would work today and
# break on some future release for a reason nobody would connect to this line.
assert_not_match "net:not-the-transitional-telnet-package" \
                 '(^|[[:space:]])telnet([[:space:]]|\\|$)' "$apt_line"

# ─── tmux: the landing point ───────────────────────────────────────────────────
# `./cs193v` runs cs193v-shell, which puts the student inside tmux. These assertions cover
# the properties that are load-bearing and would fail SILENTLY: a student would still get a
# terminal, just not the locked-down one the course documents.
#
# Nothing here re-tests what the config DOES -- 65-tmux.sh drives a real tmux inside the
# container and asserts on rendered screens for that. This is the cheap tier: the files
# exist, the image installs them, and the handful of settings that no screen makes obvious
# are set.
tmux_conf="$(cat $PRIVATE/files/tmux/tmux.conf)"

assert_ok  "tmux:conf-exists"    test -f $PRIVATE/files/tmux/tmux.conf
assert_ok  "tmux:tabname-exists" test -f $PRIVATE/files/tmux/tabname.bash
assert_ok  "tmux:tabname-syntax" bash -n $PRIVATE/files/tmux/tabname.bash
assert_ok  "tmux:shell-exists"   test -f $PRIVATE/files/cs193v-shell
assert_ok  "tmux:shell-syntax"   bash -n $PRIVATE/files/cs193v-shell

assert_ok  "tmux:package-installed" \
           grep -qE '^ +tmux ncurses-term' $PRIVATE/Containerfile
# ncurses-term carries the tmux-256color terminfo entry and is only a Recommends, so
# --no-install-recommends drops it. Without it tmux does not start AT ALL, which with tmux
# as the landing point means nobody can open a shell.
assert_contains "tmux:ncurses-term-installed" "ncurses-term" "$(cat $PRIVATE/Containerfile)"

assert_ok  "tmux:containerfile-installs-conf" \
           grep -q 'tmux/tmux.conf     /etc/cs193v/tmux.conf' $PRIVATE/Containerfile
assert_ok  "tmux:containerfile-installs-tabname" \
           grep -q 'tmux/tabname.bash  /etc/cs193v/tabname.bash' $PRIVATE/Containerfile
for cmd in cs193v-shell cs193v-welcome cs193v-goodbye; do
    assert_ok "tmux:containerfile-installs-$cmd" \
              grep -qE "$cmd +/usr/local/bin/$cmd" $PRIVATE/Containerfile
done
# The hook must reach every tab, which /etc/bash.bashrc does and a tmux default-command
# does not -- that reaches tab one only, which is a silent half-working state.
assert_ok  "tmux:containerfile-wires-the-tabname-hook" \
           grep -q 'etc/cs193v/tabname.bash; fi' $PRIVATE/Containerfile
# A bad config is now a container nobody can get into, so it must fail the BUILD.
assert_ok  "tmux:containerfile-validates-the-config" \
           grep -q 'tmux -L cs193vbuild' $PRIVATE/Containerfile

# The disarm. Emptying all four tables is the whole basis of "only these actions exist";
# `unbind -a` without -T clears the prefix table alone, so each one is named.
assert_contains "tmux:no-prefix-key" "set -g prefix None" "$tmux_conf"
for tbl in prefix root copy-mode copy-mode-vi; do
    assert_contains "tmux:unbinds-$tbl" "unbind -a -T $tbl" "$tmux_conf"
done

# Six root bindings, because each of the three actions has an ALT key and a key that works
# without Meta. macOS terminals compose Option by default, so an ALT-only keymap would be
# unreachable for most of the class.
n="$(grep -cE '^bind -N ".*" +-n +(M-t|C-t|M-Left|S-Left|M-Right|S-Right) ' \
     $PRIVATE/files/tmux/tmux.conf || true)"
assert_eq  "tmux:six-root-tab-bindings" "6" "$n"
# ...and the same six inside copy mode, or the tab bar goes dead the moment the wheel is
# brushed, which is exactly when a confused student reaches for it.
n="$(grep -cE '^bind -T copy-mode (M-t|C-t|M-Left|S-Left|M-Right|S-Right) ' \
     $PRIVATE/files/tmux/tmux.conf || true)"
assert_eq  "tmux:six-copy-mode-tab-bindings" "6" "$n"
# The escape hatch out of copy mode. Without it a stray scroll leaves a dead keyboard.
assert_contains "tmux:copy-mode-any-key-escapes" "bind -T copy-mode Any copy-mode -q" "$tmux_conf"

# destroy-unattached MUST be off. `on` (which is what the upstream prototype sets) destroys
# a session the moment its last client goes, which kills every pane and therefore every
# server a student left running -- reversing the property measured in ERRORS.md D1 and
# asserted in 70-sighup.sh.
assert_contains "tmux:destroy-unattached-is-off" "set -g destroy-unattached off" "$tmux_conf"
# Stated rather than inherited: the prototype relied on `off` being the 3.6 default, so its
# regression test passed while the config had no opinion. Scrollbars on make nano flicker.
assert_contains "tmux:scrollbars-explicitly-off" "set -g pane-scrollbars off" "$tmux_conf"
# allow-rename off swallows the shell's OSC 0, so without set-titles the window title
# silently stops naming the course.
assert_contains "tmux:sets-the-window-title" "set -g set-titles on" "$tmux_conf"
assert_contains "tmux:title-bar-says-CS193V" "$CS193V_TITLE" "$tmux_conf"
# The prototype's title bar dropped the V. Everything else in this project has it.
assert_not_contains "tmux:title-bar-not-missing-the-V" "CS193 Development" "$tmux_conf"

# -f suppresses BOTH /etc/tmux.conf and ~/.tmux.conf. Installing to /etc/tmux.conf instead
# would let a student's own ~/.tmux.conf win and re-arm a prefix key.
assert_contains "tmux:shell-names-the-config-explicitly" '-f "$CONF"' \
                "$(cat $PRIVATE/files/cs193v-shell)"
assert_contains "tmux:shell-uses-a-dedicated-socket" '-L "$SOCKET"' \
                "$(cat $PRIVATE/files/cs193v-shell)"
# Reattach before create is what makes a closed window recoverable rather than lost.
assert_contains "tmux:shell-prefers-an-unattached-session" "session_attached" \
                "$(cat $PRIVATE/files/cs193v-shell)"
assert_contains "launcher:lands-on-cs193v-shell" '"$NAME" cs193v-shell' "$(cat $REPO/cs193v)"
# Closing a terminal window does NOT kill the tmux client inside the container -- conmon
# keeps the pty open and tmux reports the session attached forever (asserted live in
# 60-container.sh). Only the host can tell a stale client from a live one, so the launcher
# prunes them before attaching. Without it, "close the window, run cs193v again, get your
# tabs back" silently becomes a brand-new session every time.
assert_contains "launcher:prunes-stale-tmux-clients" "prune_stale_tmux_clients" \
                "$(cat $REPO/cs193v)"
assert_contains "launcher:passes-its-pid-so-the-prune-can-work" 'CS193V_CLIENT_PID=$$' \
                "$(cat $REPO/cs193v)"
assert_contains "tmux:shell-records-the-owning-client" "@cs193v_host_pid" \
                "$(cat $PRIVATE/files/cs193v-shell)"
# The tab-label hook arms itself once per prompt so that only the command the student typed
# can relabel. On Ubuntu 26.04 systemd's own PROMPT_COMMAND entry runs after ours and used
# to spend that arming flag, which disabled EVERY label silently -- the fallback looks
# exactly like having no hook at all. See ERRORS.md D0.
assert_contains "tmux:tabname-ignores-other-prompt-command-entries" 'PROMPT_COMMAND[@]' \
                "$(cat $PRIVATE/files/tmux/tabname.bash)"

# Since 23.04 the Ubuntu base image ships its own `ubuntu` user at uid AND gid 1000, so a
# bare `groupadd -g 1000` exits 4 with "GID '1000' already exists" and aborts the build.
# That is what stopped this image from ever building. The layer must clear 1000 first.
assert_ok  "containerfile:handles-base-image-uid-1000" \
           grep -q 'getent passwd 1000' $PRIVATE/Containerfile
assert_ok  "containerfile:handles-base-image-gid-1000" \
           grep -q 'getent group 1000' $PRIVATE/Containerfile
assert_ok  "containerfile:asserts-student-ids-at-build-time" \
           grep -q 'id -u student' $PRIVATE/Containerfile

# GIT_EDITOR must stay unset: git resolves GIT_EDITOR -> core.editor -> VISUAL -> EDITOR
# -> vi, and /usr/bin/vi is vim.tiny, which strands a novice on `git commit` with no -m.
env_block="$(sed -n '/^ENV /,/^$/p' $PRIVATE/Containerfile)"
for v in LANG EDITOR VISUAL PAGER LESS BROWSER; do
    assert_contains "containerfile:env-has-$v" "$v=" "$env_block"
done
assert_not_contains "containerfile:no-GIT_EDITOR" "GIT_EDITOR" "$(sed 's/#.*//' $PRIVATE/Containerfile)"
# HOST and FLASK_RUN_HOST are gone with the bind-0.0.0.0 rule, and must stay gone: with the
# tunnel reaching the container's loopback there is nothing for them to nudge, so all they
# could do is silently change what a student's server binds to for a reason that no longer
# exists. Comments are stripped first, or the Containerfile's own explanation of the removal
# matches itself and this passes while the ENV line is back.
env_live="$(sed 's/#.*//' $PRIVATE/Containerfile | sed -n '/^ENV /,/^$/p')"
for v in HOST FLASK_RUN_HOST; do
    assert_not_contains "containerfile:no-$v-env" "$v=" "$env_live"
done

# PIPX_HOME/PIPX_BIN_DIR must be inline on the RUN, never ENV: as ENV they persist into
# the runtime and point a student's own `pipx install` at root-owned /usr/local.
assert_not_match "containerfile:pipx-vars-not-ENV" '^ENV.*PIPX' "$(cat $PRIVATE/Containerfile)"

assert_ok  "containerfile:runs-as-student" grep -qx 'USER student' $PRIVATE/Containerfile

# The bind mount lands at ~/projects, INSIDE $HOME alongside the four credential volumes.
# The target must be pre-created student-owned in the image: podman auto-chowns an empty
# named volume, but a bind mount onto a missing directory gets created root-owned, and then
# nothing the student runs can write to their own work.
assert_ok  "containerfile:precreates-the-projects-mount-student-owned" \
           grep -qE 'install -d -o student -g student .*/home/student/projects' $PRIVATE/Containerfile
assert_ok  "containerfile:workdir-is-the-projects-mount" \
           grep -qx 'WORKDIR /home/student/projects' $PRIVATE/Containerfile
# The old path must be gone, not merely shadowed — two directories would be worse than one
# wrong one, because the docs would be right about a directory nobody is standing in.
assert_not_contains "containerfile:no-stale-workspaces-path" "/workspaces" \
                    "$(cat $PRIVATE/Containerfile)"

# WORKDIR, the launcher's -w and the mount destination must all name the same directory, or
# the student's shell opens somewhere other than their files.
wd="$(sed -n 's/^WORKDIR //p' $PRIVATE/Containerfile | head -1)"
assert_eq "launcher:mount-destination-matches-WORKDIR" "$wd" \
          "$(sed -n 's/^MOUNT_DST="\(.*\)"/\1/p' cs193v | head -1)"

# config_hash decides whether an existing container is stale. It must cover the mount
# DESTINATION, not just the source: when this moved from /workspaces to ~/projects, every
# container already on a student machine would otherwise have kept the old mount silently,
# because the destination was a constant baked into build_run_args and never hashed.
assert_contains "launcher:confighash-covers-the-mount-destination" "MOUNT_DST" \
                "$(sed -n '/^config_hash()/,/^}/p' cs193v)"


# ─── container.args invariants ──────────────────────────────────────────────────
# The block at the top of container.args lists these as "never add any of these". Host
# isolation comes from the user namespace, and each of these punches through it.
args_live="$(sed 's/#.*//' $REPO/.config/container.args)"
for bad_flag in --privileged --cap-add=SYS_ADMIN --cap-add=SYS_PTRACE --network=host \
                --pid=host --ipc=host --userns=host seccomp=unconfined unmask=ALL \
                label=disable docker.sock podman.sock; do
    assert_not_contains "invariant:no-$bad_flag" "$bad_flag" "$args_live"
done

# Each of these was considered and rejected for a documented reason; re-adding one should
# be a deliberate act that breaks a test, not a quiet edit.
for rejected in --memory-swap --init --tmpfs --pids-limit --cpus --shm-size \
                host-lo-to-ns-lo '-t,auto'; do
    assert_not_contains "rejected:no-$rejected" "$rejected" "$args_live"
done

# :Z relabels recursively and can break unrelated host services; the launcher adds :z
# narrowly and only where SELinux is enforcing.
assert_not_match "invariant:no-Z-relabel" ',Z' "$args_live"

assert_contains "args:userns-explicit-uid-gid" "--userns=keep-id:uid=1000,gid=1000" "$args_live"

# Every volume container.args CREATES must be one --full-rebuild REMOVES. That is two lists
# in two files -- the `-v cs193v-NAME:` lines here, and the `for v in ...` inside the
# launcher's remove_volumes -- and a name added to one but not the other leaks a volume that
# --full-rebuild silently keeps, which is precisely the state that verb exists to clear.
#
# This is a grep, which this file otherwise avoids when a behavioural test proves the same
# thing. Nothing here duplicates one. 30-launcher-shim.sh counts the `volume rm` calls
# --full-rebuild makes, which proves the launcher removes the volumes IT KNOWS ABOUT — it
# compares remove_volumes against the shim's own expectation, never against container.args,
# so a volume added to container.args alone passes it. MANUAL.md §2.4 is the only end-to-end
# check and it is deliberately human, because the honest automated version would delete a
# developer's real logins. That gap is what this grep covers.
args_vols="$(printf '%s\n' "$args_live" \
    | sed -n 's/.*-v cs193v-\([A-Za-z0-9_-]*\):.*/\1/p' | LC_ALL=C sort | tr '\n' ' ')"
launcher_vols="$(sed -n 's/^[[:space:]]*for v in \(.*\); do$/\1/p' cs193v \
    | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort | tr '\n' ' ')"
assert_eq "volumes:launcher-removes-every-volume-args-creates" "$args_vols" "$launcher_vols"
assert_contains "args:network-pasta"           "--network=pasta"                    "$args_live"

# ─── forwarded ports ───────────────────────────────────────────────────────────
# A -p line does not merely duplicate the tunnel, it BREAKS it. Both bind host
# 127.0.0.1:<port>, so whichever loses the race gets EADDRINUSE — and podman wins, because
# the container is created before the tunnel starts, which means re-adding a -p line here
# silently costs the student that port entirely. This is the strongest of the port
# invariants and it replaced the old "every -p must be loopback-prefixed" check: with no -p
# lines at all, the host side is loopback by construction, because the ssh client binds
# 127.0.0.1 itself.
published="$(printf '%s\n' "$args_live" | grep -E '^\s*-p( |$)' || true)"
assert_eq  "ports:no-p-lines-they-would-break-the-tunnel" "" "$published"

# The port set now comes from ONE declaration, CS193V_PORTS, which the launcher parses to
# build its ssh -L flags and also passes into the container for `ports` to read. Host and
# container side are therefore the same number by construction, so the old
# "host range != container range" check has no failure left to catch and is gone.
port_report="$(printf '%s\n' "$args_live" | python3 -c '
import re, sys
spec = ""
for line in sys.stdin:
    m = re.search(r"CS193V_PORTS=([0-9,\-]+)", line)
    if m:
        spec = m.group(1)      # last wins, exactly as tunnel_ports() in the launcher does
problems = []
total = 0
if not spec:
    problems.append("no CS193V_PORTS= line at all, so nothing would be forwarded")
for chunk in spec.split(","):
    if not chunk:
        continue
    if "-" in chunk:
        a, b = (int(x) for x in chunk.split("-", 1))
    else:
        a = b = int(chunk)
    if b < a:
        problems.append("range %s is backwards" % chunk)
        continue
    total += b - a + 1
    if a < 1024:
        problems.append("privileged port %d (an unprivileged ssh client cannot bind these)" % a)
    for reserved in (5000, 7000):
        if a <= reserved <= b:
            problems.append("port %d collides with macOS AirPlay Receiver" % reserved)
print("total=%d" % total)
print("\n".join(problems))
')"
assert_contains "ports:count-is-46" "total=46" "$port_report"
assert_eq  "ports:no-privileged-no-airplay-no-mismatch" "total=46" "$(printf '%s' "$port_report" | sed '/^$/d')"

# ports:CS193V_PORTS-matches--p-lines is DELETED, not rewritten. It guarded the agreement
# between CS193V_PORTS and a parallel set of -p lines; deriving the forwards from
# CS193V_PORTS makes that disagreement structurally impossible, so there is nothing left to
# assert. Enforcing an invariant by construction beats enforcing it by test.

# ports:CLAUDE.md-matches-CS193V_PORTS is DELETED, and nothing replaces it.
#
# By decision, NOTHING asserts on the CONTENT of the managed CLAUDE.md. Two attempts were made
# and both removed: an equality check against the port list, and a subset check over whatever
# ranges the prose still named. Both punish ordinary rewording — a correct edit that happens
# not to match the pattern fails the suite — and a test that fires on correct changes trains
# people to delete it rather than heed it, which is worse than not having it.
#
# What guards that file instead: it is short enough to read in full, and a human reads it. The
# suite still checks that it EXISTS and is readable in the image (50-image.sh), which is the
# part a machine can judge.

# ─── the tunnel's invariants ───────────────────────────────────────────────────
# Only the ones with NO behavioural equivalent are checked here. Six greps that used to live in
# this section were removed because a real test already proved the same thing, and a grep whose
# only job is to restate what a behavioural test proves is pure brittleness -- it breaks on
# refactors and buys nothing:
#
#   -R / RemoteForward in the launcher, and AllowTcpForwarding local in the config
#       -> 80-launcher-live.sh :: tunnel:remote-forward-is-refused actually attempts a remote
#          forward and asserts it is refused with zero listeners created.
#   PermitOpen 127.0.0.1:*
#       -> tunnel:cannot-proxy-off-box actually forwards to an off-box address and asserts the
#          connection fails.
#   ClearAllForwardings
#       -> ports:46-forwards-on-the-host would find 0 forwards if they had been cleared.
#   remove_container calling tunnel_down
#       -> tunnel:releases-its-ports-when-the-container-dies and tunnel:comes-back-after-a-
#          rebuild cover the consequence, which is what actually matters.
#
# What is left below either has no runtime symptom to test, or is a build-time structural fact.
launcher_live="$(sed 's/#.*//' $REPO/cs193v)"
assert_not_contains "tunnel:no-agent-forwarding" "ForwardAgent=yes" "$launcher_live"
# -F none, or the student's own ~/.ssh/config could redirect or decorate the connection. No
# runtime symptom: it only shows up on a machine whose ssh config happens to interfere.
assert_contains "tunnel:ignores-the-users-ssh-config" "-F none" "$launcher_live"
# setsid(1) does not exist on macOS, so backgrounding must go through nohup. The symptom would
# only appear on a Mac, which this suite cannot reach.
assert_contains "tunnel:uses-nohup-not-setsid" "nohup ssh" "$launcher_live"
assert_not_match "tunnel:no-setsid" '(^|[[:space:]])setsid[[:space:]]' "$launcher_live"

sshd_conf="$(sed 's/^#.*//' $PRIVATE/files/sshd_config)"
assert_contains "sshd:no-agent-forwarding"        "AllowAgentForwarding no"  "$sshd_conf"
assert_contains "sshd:no-x11"                     "X11Forwarding no"         "$sshd_conf"
assert_contains "sshd:no-passwords"               "PasswordAuthentication no" "$sshd_conf"
assert_contains "sshd:no-root-login"              "PermitRootLogin no"       "$sshd_conf"
# ONE authorized_keys path, not OpenSSH's default pair. A writable authorized_keys2 would let
# the container grant inbound access to itself.
assert_not_contains "sshd:no-second-authorized-keys-file" "authorized_keys2" "$sshd_conf"

# The image must carry the server, pre-create ~/.ssh student-owned, and validate the config at
# build time. ~/.ssh is load-bearing and was measured, not guessed: without it podman creates
# the bind mount's parent as ROOT (verified root:root 0755), which would lock a student out of
# writing their own keys there.
cf="$(cat $PRIVATE/Containerfile)"
assert_contains "sshd:image-installs-openssh-server" "openssh-server" "$cf"
assert_contains "sshd:image-precreates-dot-ssh" \
                "install -d -o student -g student -m 0700 /home/student/.ssh" "$cf"
assert_contains "sshd:config-is-validated-at-build-time" "sshd -t -f /etc/ssh/cs193v_sshd_config" "$cf"
# A host key baked into the image would be one private key shipped to every student.
assert_match "sshd:build-time-host-key-is-deleted" \
             'rm -f /etc/ssh/cs193v_host_ed25519_key' "$cf"

# ─── the tldr cache must not be able to fail silently  (#9) ────────────────────
# `man` is deliberately absent, so tldr IS the command-line help. The build step that
# populates its cache ended in `|| true`, which means a network hiccup during a CI build
# would ship an image with NO help at all and nothing would report it. The build must fail
# loudly instead.
tldr_layer="$(sed -n '/tldr --update/p' $PRIVATE/Containerfile)"
assert_not_contains "tldr:build-does-not-swallow-failure" "|| true" "$tldr_layer"
assert_contains "tldr:build-asserts-the-cache-is-populated" "cache/tldr" \
                "$(sed -n '/tldr --update/,+3p' $PRIVATE/Containerfile)"

# ─── documented claims must be true  (#11, #12, #14) ───────────────────────────
# A comment that promises behaviour which does not exist is worse than no comment: the next
# person to edit the port list will rely on it. container.args claimed `cs193v doctor` warns
# when CS193V_PORTS and the -p lines disagree. verb_doctor never compared them.
assert_not_contains "claims:no-phantom-doctor-ports-warning" "doctor" \
                    "$(sed -n '/Environment/,/CS193V_PORTS=/p' $REPO/.config/container.args)"
# The invariant itself is enforced statically instead, which is strictly better than a
# runtime warning -- it fails at edit time rather than after a student is already misled.
# (ports:CS193V_PORTS-matches--p-lines, above.)

# CONTAINER-DESIGN.md said "macOS and Windows are case-insensitive". On Windows this design
# puts projects/ inside the WSL distro's ext4 home, which IS case-sensitive -- and the doc
# gives that very path a few lines later.
assert_not_contains "claims:windows-not-called-case-insensitive" \
                    "macOS and Windows are case-insensitive" "$(cat $PRIVATE/CONTAINER-DESIGN.md)"

# Both docs warned that closing a window "may stop" a server. Measured on native Linux, all
# five shapes survive and stay reachable. The docs must now say what was measured and be
# explicit about which platforms are still unverified, rather than hedging vaguely.
#
# The claim has a second dependency now: with tmux as the landing point it is
# `destroy-unattached off` that keeps a pane alive, not conmon. That half is asserted where
# it can be asserted properly -- tmux:destroy-unattached-is-off above, and behaviourally in
# 70-sighup.sh -- rather than by matching more prose here.
assert_contains "claims:sighup-states-the-linux-measurement" "Linux" \
                "$(sed -n '/does not stop a server/,+8p' $PRIVATE/CONTAINER-DESIGN.md)"

# ─── .gitignore ────────────────────────────────────────────────────────────────
# -F, not -x alone: `projects/*` as a BRE is "project" + "s" + zero-or-more "/".
assert_ok  "gitignore:local.args-is-ignored" grep -qxF '.config/local.args' .gitignore
assert_ok  "gitignore:projects-contents" grep -qxF 'projects/*' .gitignore
assert_ok  "gitignore:keeps-gitkeep"     grep -qxF '!projects/.gitkeep' .gitignore
assert_file "gitignore:gitkeep-exists"   "$REPO/projects/.gitkeep"
# The bind-mount target must exist in a fresh clone or the mount creates a root-owned dir.
assert_ok  "gitignore:gitkeep-is-tracked" git -C "$REPO" ls-files --error-unmatch projects/.gitkeep
# local.args holds one machine's memory cap; committing it would ship it to everyone.
assert_ok  "gitignore:local.args-not-tracked" \
           sh -c "! git -C '$REPO' ls-files --error-unmatch $REPO/.config/local.args >/dev/null 2>&1"

# The tunnel's PRIVATE KEYS. These are generated per machine precisely so that no keypair is
# shared, and committing one would hand it to every student and every reader of the repo --
# undoing the entire reason the host key is not baked into the image. Asserted by asking git
# itself rather than by grepping .gitignore, so any spelling that actually works passes and
# any that silently does not fails.
for f in tunnel-key tunnel-key.pub tunnel-host-key tunnel-host-key.pub tunnel-known-hosts; do
    assert_ok "gitignore:$f-is-ignored" \
              git -C "$REPO" check-ignore -q ".config/$f"
    assert_ok "gitignore:$f-not-tracked" \
              sh -c "! git -C '$REPO' ls-files --error-unmatch '.config/$f' >/dev/null 2>&1"
done

# ─── Claude Code policy ────────────────────────────────────────────────────────
assert_ok  "claude:managed-settings-is-valid-json" \
           python3 -c "import json;json.load(open('$PRIVATE/files/claude-code/managed-settings.json'))"

# Write(...) and Glob(...) path rules are accepted and then silently ignored with a
# startup warning. A security control that does nothing is worse than none.
bad_rules="$(python3 -c '
import json
d = json.load(open("files/claude-code/managed-settings.json"))
bad = [x for x in d.get("permissions", {}).get("deny", [])
       if not x.startswith(("Read(", "Edit("))]
print(",".join(bad))
')"
assert_eq  "claude:deny-rules-are-Read-or-Edit-only" "" "$bad_rules"

# requiredMinimumVersion/requiredMaximumVersion cause a hard startup exit, which combined
# with a pinned image can manufacture a container that refuses to start at all.
for forbidden in requiredMinimumVersion requiredMaximumVersion; do
    assert_not_contains "claude:no-$forbidden" "$forbidden" \
        "$(python3 -c 'import json;print(json.dumps(json.load(open("files/claude-code/managed-settings.json"))["permissions"]))')"
done

lines="$(wc -l < $PRIVATE/files/claude-code/CLAUDE.md | tr -d ' ')"
if [ "$lines" -lt 200 ]; then pass "claude:CLAUDE.md-under-200-lines"
else fail "claude:CLAUDE.md-under-200-lines" "$lines lines"; fi

# NOTHING asserts on the CONTENT of the managed CLAUDE.md, or of CONTAINER-DESIGN.md, by
# decision. Assertions forbidding the old bind-0.0.0.0 imperatives lived in both places
# briefly and were removed: a test that matches on what prose SAYS fails whenever the prose is
# reworded, including when it is reworded correctly, and a test that fires on correct changes
# teaches people to delete it rather than heed it.
#
# What replaces them is behaviour. The claim "a loopback-bound server is reachable" is asserted
# against a real server and a real tunnel in 60-container.sh and 80-launcher-live.sh, which
# cannot pass while the docs' advice is wrong in a way that matters.

# Every credential store that gets a volume must also get a deny rule, or a login token
# lands in an agent transcript the first time it globs the home directory.
for store in .claude/.credentials.json .config/gh .local/share/com.vercel.cli; do
    assert_contains "claude:denies-$store" "$store" \
        "$(cat $PRIVATE/files/claude-code/managed-settings.json)"
done

# ─── shellcheck ────────────────────────────────────────────────────────────────
# Last, because require_cmd aborts the suite: a missing shellcheck should not hide the
# result of every check above it.
require_cmd shellcheck "Run: sudo apt install -y shellcheck"
assert_ok  "shellcheck:cs193v"  shellcheck --severity=warning cs193v
assert_ok  "shellcheck:install" shellcheck --severity=warning $PRIVATE/install-cs193v.sh
# The landing point and its two helpers. cs193v-shell is the only way a student gets a
# shell, so a quoting bug in it is a container nobody can enter.
assert_ok  "shellcheck:landing-point" shellcheck --severity=warning \
                                      $PRIVATE/files/cs193v-shell \
                                      $PRIVATE/files/cs193v-welcome \
                                      $PRIVATE/files/cs193v-goodbye
# The small /bin/sh helpers. `man` is here rather than left to the image tier because it
# runs as root-owned /usr/bin/man for every student: a quoting bug in it would turn every
# `man something` into a shell error on top of the missing manual page.
assert_ok  "shellcheck:helpers" shellcheck --severity=warning \
                                $PRIVATE/files/open-url \
                                $PRIVATE/files/am-i-in-a-container \
                                $PRIVATE/files/man
# tmux-harness/ is NOT shellchecked: it is vendored from the multiplexer prototype and is
# meant to stay diffable against it, so local style fixes would cost more than they buy.
# Its host-side driver is ours and is checked.
assert_ok  "shellcheck:tmux-driver" shellcheck --severity=warning --exclude=SC1090,SC1091 \
                                    $PRIVATE/tests/65-tmux.sh
assert_ok  "shellcheck:tests"   shellcheck --severity=warning --exclude=SC1090,SC1091 \
                                           $PRIVATE/tests/run-tests.sh $PRIVATE/tests/10-static.sh
