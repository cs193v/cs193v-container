# shellcheck shell=bash
#
# Helpers for driving tests/lib/podman-fake. Source after lib/assert.sh.
#
# MUST STAY BASH 3.2 COMPATIBLE.

# The real temporary directory, captured before shim_new starts redirecting TMPDIR at the
# launcher. Every mktemp in this file uses it, or the second shim would be created inside the
# first and shim_cleanup would delete a repo copy still in use.
SHIM_HOST_TMPDIR="${SHIM_HOST_TMPDIR:-${TMPDIR:-/tmp}}"

# The single snapshot repo_copy serves every copy from. A PATH rather than a variable, for the
# reason repo_copy's own comment gives; $$ is the SUITE's pid, so it also tells the sweep
# below and shim_cleanup which of these directories are ours and which a concurrent run's.
SHIM_SNAPSHOT="$SHIM_HOST_TMPDIR/cs193v-snap.$$"

# Whatever an earlier, KILLED run left here. See sweep_stale_tmpdirs in lib/assert.sh for why it
# goes by pid rather than by age, and why it is called at suite start and not only on exit.
shim_sweep_stale() {                  # -> how many directories it removed
    sweep_stale_tmpdirs "$SHIM_HOST_TMPDIR" cs193v-shim cs193v-repo cs193v-snap cs193v-last
}

# shim_new [DIR]  -> creates a shim, sets $SHIM, and puts it first on $PATH for `launcher`.
# A fresh shim per test keeps state from leaking between cases.
#
# THE LAUNCHER GETS A TMPDIR OF ITS OWN, and that is not tidiness. The tunnel's control socket,
# pidfile and log are named from a hash of (course directory, instance) under TMPDIR -- the same
# names the REAL tunnel for this checkout uses. So a shim launch of any verb that reaches
# tunnel_down (every --rebuild here) was reaching through the fake podman and shutting down the
# developer's actual tunnel, and, when run-tests.sh runs its two lanes at once, the live tier's
# as well. The cheap lane is supposed to touch no ports; without this it touched all 46.
shim_new() {
    SHIM="$(mktemp -d "$SHIM_HOST_TMPDIR/cs193v-shim.$$.XXXXXX")"
    export SHIM CS193V_SHIM="$SHIM"
    mkdir -p "$SHIM/tmp"
    export TMPDIR="$SHIM/tmp"
    cp "$TESTS_DIR/lib/podman-fake" "$SHIM/podman"
    chmod +x "$SHIM/podman"
    : > "$SHIM/argv.log"
}

shim_set() {                          # shim_set KEY VALUE
    printf '%s' "$2" > "$SHIM/$1"
}

shim_touch() { : > "$SHIM/$1"; }      # for flag-style keys like `hang`

shim_log()  { cat "$SHIM/argv.log" 2>/dev/null; }
shim_clear_log() { : > "$SHIM/argv.log"; }

# How many invocations matched an extended regex. Used for "exactly one container was
# created across twenty launches".
# grep -c prints 0 and exits 1 on no match, so take its output and drop its status.
shim_count() {                        # shim_count ERE
    local n
    n="$(grep -cE "$1" "$SHIM/argv.log" 2>/dev/null)" || true
    printf '%s' "${n:-0}"
}

# BY GLOB ON OUR OWN PID, NOT FROM A LIST OF DIRECTORIES. This kept a list, and both makers
# of these directories get called from inside a command substitution somewhere: repo_copy at
# every one of its call sites, and shim_new inside 25-installer.sh's run_with_tarball. The
# entry was appended in a subshell and never reached this function, which is what made a
# CLEAN run leak rather than only a killed one -- 350 MB of repo copies per run, plus three
# shims per installer run (#76). The pid in every name is what lets one glob find exactly
# ours and leave a concurrent run's alone.
shim_cleanup() {
    rm -rf "$SHIM_SNAPSHOT" \
           "$SHIM_HOST_TMPDIR"/cs193v-shim."$$".* \
           "$SHIM_HOST_TMPDIR"/cs193v-repo."$$".* \
           "$SHIM_HOST_TMPDIR"/cs193v-last."$$" 2>/dev/null || true
}

# Run the launcher with the fake podman first on PATH. stdin is closed: the real launcher
# ends in `exec podman exec -it`, and VERIFICATION.md §A.10's own verb loop hangs today
# precisely because it left stdin attached to the terminal.
launcher() {                          # launcher [ARGS...]  -> stdout+stderr, returns rc
    PATH="$SHIM:$PATH" "${LAUNCHER_DIR:-$REPO}/cs193v" "$@" 2>&1 </dev/null
}

launcher_rc() {                       # launcher_rc [ARGS...] -> prints rc, discards output
    PATH="$SHIM:$PATH" "${LAUNCHER_DIR:-$REPO}/cs193v" "$@" >/dev/null 2>&1 </dev/null
    printf '%s' "$?"
}

# Drive the launcher through a real pty, feeding keystrokes. This is the only way to reach
# the arrow-key menu — with no tty, menu() deliberately picks the safe default and returns.
# KEYS is passed through printf %b, so use \033[B for down and \n for Enter.
launcher_tty() {                      # launcher_tty KEYS [ARGS...]
    local keys="$1"; shift
    local cmd="${LAUNCHER_DIR:-$REPO}/cs193v" a
    for a in "$@"; do cmd="$cmd $a"; done
    # util-linux script takes -c CMD; BSD/macOS script takes the command as trailing words.
    if script --version 2>&1 | grep -qi util-linux; then
        printf '%b' "$keys" | PATH="$SHIM:$PATH" timeout 120 script -q -c "$cmd" /dev/null 2>&1
    else
        # shellcheck disable=SC2086
        printf '%b' "$keys" | PATH="$SHIM:$PATH" timeout 120 script -q /dev/null $cmd 2>&1
    fi
}

# A bare launch (no verb) through a pty. Needed because open_shell now REFUSES when stdin
# is not a terminal, so `launcher` alone can no longer reach the shell — which is the point
# of that refusal. `exit` is fed so the login shell terminates.
launcher_pty() {                      # launcher_pty [ARGS...]
    launcher_tty 'exit\n' "$@"
}

# A bare launch on a pty whose stdin stays OPEN and silent, started in the BACKGROUND.
#
# This is the only way to tell "the launcher is waiting for input" apart from "the launcher
# read end-of-input and carried on". Every other helper here feeds `script` from a printf
# pipe, and that pipe closes the moment it is drained — which a blocked `read` sees as EOF
# and returns from, so a launcher that never waited at all would look identical.
#
# A fifo held open by a writer that never writes is what keeps it from reaching EOF. Sets
# $PTY_OUT (the transcript, which grows as it goes), $PTY_PID and $PTY_HOLDER; stop it with
# launcher_pty_silent_stop, which must be called or the fifo's holder lives for two minutes.
launcher_pty_silent_start() {         # launcher_pty_silent_start [ARGS...]
    local cmd="${LAUNCHER_DIR:-$REPO}/cs193v" a
    for a in "$@"; do cmd="$cmd $a"; done
    PTY_FIFO="$SHIM/silent.fifo"; PTY_OUT="$SHIM/silent.out"
    rm -f "$PTY_FIFO" "$PTY_OUT"; mkfifo "$PTY_FIFO"
    : > "$PTY_OUT"
    sleep 120 > "$PTY_FIFO" &
    PTY_HOLDER=$!
    if script --version 2>&1 | grep -qi util-linux; then
        PATH="$SHIM:$PATH" script -q -c "$cmd" /dev/null < "$PTY_FIFO" > "$PTY_OUT" 2>&1 &
    else
        # shellcheck disable=SC2086
        PATH="$SHIM:$PATH" script -q /dev/null $cmd < "$PTY_FIFO" > "$PTY_OUT" 2>&1 &
    fi
    PTY_PID=$!
}

# Wait up to SECS for PHRASE to appear in the transcript. Returns 1 if the launcher exits
# first, so a launcher that does not wait fails in a second rather than after the timeout.
launcher_pty_silent_wait() {          # launcher_pty_silent_wait SECS PHRASE
    local i=0 n
    n=$(( $1 * 2 ))
    while [ "$i" -lt "$n" ]; do
        grep -q "$2" "$PTY_OUT" 2>/dev/null && return 0
        kill -0 "$PTY_PID" 2>/dev/null || return 1
        sleep 0.5
        i=$((i + 1))
    done
    return 1
}

launcher_pty_silent_stop() {
    kill "$PTY_PID" "$PTY_HOLDER" 2>/dev/null
    wait "$PTY_PID" 2>/dev/null
    wait "$PTY_HOLDER" 2>/dev/null
    rm -f "$PTY_FIFO"
}

# The same thing against the REAL launcher and real podman — no shim on PATH. Used by the
# live tier, where the whole point is that podman is genuine.
# KEYS should end with an `exit\n` when the launcher will go on to open a shell, since a
# pty never delivers EOF (see ERRORS.md B13).
launcher_tty_repo() {                 # launcher_tty_repo KEYS [ARGS...]
    local keys="$1"; shift
    local cmd="$REPO/cs193v" a
    for a in "$@"; do cmd="$cmd $a"; done
    if script --version 2>&1 | grep -qi util-linux; then
        printf '%b' "$keys" | timeout 120 script -q -c "$cmd" /dev/null 2>&1
    else
        # shellcheck disable=SC2086
        printf '%b' "$keys" | timeout 120 script -q /dev/null $cmd 2>&1
    fi
}

# A pty makes the launcher turn colour on, so assertions need the escapes gone. The `?` in the
# class catches private-mode sequences -- the meter's ESC[?25l / ESC[?25h cursor hiding -- which
# a class of only [0-9;] leaves behind in the middle of the text being matched.
strip_ansi() {
    sed -e 's/'"$(printf '\033')"'\[[?0-9;]*[A-Za-z]//g' -e 's/'"$(printf '\r')"'//g'
}

# Fake `id`, so the "refuses to run as root" branch is reachable without root. unshare -r
# is unavailable in many sandboxes (writing /proc/self/uid_map is not permitted), and the
# real `sudo ./cs193v` case stays a manual check in tests/MANUAL.md.
shim_fake_id() {                      # shim_fake_id UID NAME
    cat > "$SHIM/id" <<EOF
#!/bin/sh
case "\$1" in
    -u)  echo $1 ;;
    -un) echo $2 ;;
    -g)  echo $1 ;;
    -gn) echo $2 ;;
    *)   echo "uid=$1($2) gid=$1($2)" ;;
esac
EOF
    chmod +x "$SHIM/id"
}

# THE ONLY WAY THIS SUITE STARTS install-cs193v.sh. 10-static.sh asserts there is no
# second one, and asserts this body still does the two things below.
#
# HOME, not just CS193V_DIR, and that is the whole point of having a door at all. The
# installer runs for real here -- a fake podman, but real mkdir, real tar and real chmod in
# fetch_files -- and none of those three needs privilege. CS193V_DIR looks like it contains
# them, and it does, right up until a case needs choose_dir's MENU: choose_dir returns
# immediately when CS193V_DIR is set, so the typed path, the empty-input fallback and the
# ~/ expansion are only reachable with it UNSET, and DEFAULT_DIR is $HOME/cs193v. Until
# this function existed the only thing keeping the suite out of the developer's own home
# directory was that all four call sites happened to spell CS193V_DIR out by hand.
#
# The naming convention is load-bearing for the static rule: an installer copy must be
# named install* so that a call site written without this helper is greppable.
#
# THE SHIM PATH GOES TO A FILE. Every call site is `out="$(installer_host ...)"`, which is a
# subshell, so $SHIM set by a shim_new in there never reaches the assertion that wants to
# read argv.log -- it would silently read the PREVIOUS case's log, which is a pass. #76's
# mechanism, and the same one that cost repo_copy its memo.
SHIM_LAST="$SHIM_HOST_TMPDIR/cs193v-last.$$"

installer_host() {                    # installer_host SCRIPT [VAR=VALUE...] -> output
    local script="$1"; shift
    mkdir -p "$SHIM/home"
    printf '%s' "$SHIM" > "$SHIM_LAST"
    env HOME="$SHIM/home" PATH="$SHIM:$PATH" "$@" bash "$script" </dev/null 2>&1
}

installer_host_rc() {                 # installer_host_rc SCRIPT [VAR=VALUE...] -> rc
    installer_host "$@" >/dev/null 2>&1
    printf '%s' "$?"
}

# argv.log from the most recent installer_host run, whichever subshell it happened in.
installer_log() { cat "$(cat "$SHIM_LAST" 2>/dev/null)/argv.log" 2>/dev/null; }

# Fake `uname` and `sysctl`, which is what makes the macOS arm executable on Linux.
#
# platform() reads `uname -s` and survey() reads `uname -m` (the Intel-Mac stop), so between
# them these two flags decide four of the installer's branches. host_ram_mb then reads
# `sysctl -n hw.memsize` -- BYTES on a Mac, where /proc/meminfo is kB on Linux -- and
# mac_vm_target_mb does arithmetic on the result, so a missing sysctl fake does not fail
# cleanly: it makes `$(( $(host_ram_mb) / 1024 ))` a bash arithmetic error that reads like
# an installer bug. Set them together or not at all.
#
# The EFFECTS of the macOS arm cannot be faked honestly and are not faked here: `sudo
# installer -pkg -target /` and a real `podman machine` need a Mac. What these reach is
# every macOS DECISION, which is the part that drifts.
shim_fake_uname() {                   # shim_fake_uname SYSNAME [MACHINE]
    cat > "$SHIM/uname" <<EOF
#!/bin/sh
case "\$1" in
    -s)  echo $1 ;;
    -m)  echo ${2:-arm64} ;;
    -sm) echo "$1 ${2:-arm64}" ;;
    *)   echo $1 ;;
esac
EOF
    chmod +x "$SHIM/uname"
}

# Only hw.memsize is answered, and anything else is an error rather than an empty line: a
# sysctl that silently returns nothing would put an empty string into the installer's
# arithmetic, which is the failure this fake exists to avoid.
shim_fake_sysctl() {                  # shim_fake_sysctl TOTAL_BYTES
    cat > "$SHIM/sysctl" <<EOF
#!/bin/sh
[ "\$1" = -n ] && shift
case "\$1" in
    hw.memsize) echo $1 ;;
    *)          echo "sysctl: unknown oid '\$1'" >&2; exit 1 ;;
esac
EOF
    chmod +x "$SHIM/sysctl"
}

# A Mac the installer will accept: arm64, and enough RAM to want a 12 GB VM.
shim_fake_mac() {                     # shim_fake_mac [TOTAL_BYTES]
    shim_fake_uname Darwin arm64
    shim_fake_sysctl "${1:-17179869184}"
}

# Fake `ssh`, so a launch can reach open_shell having warned about NOTHING.
#
# Against the fake podman the tunnel can never come up — its ProxyCommand is
# `podman exec -i ... sshd -i`, and the fake serves no sshd — so every shim launch warns
# that the tunnel failed. That is realistic and worth keeping for every other test here,
# but it means the quiet path cannot be reached at all without this.
#
# It answers `-O check` and `-O exit` directly, and for the master it creates the control
# socket the launcher tests for with `[ -S ]`. python3 because a unix socket cannot be made
# from the shell; the file survives the process, so the socket does not need holding open.
#
# TWO THINGS HERE MODEL ssh FEATURES THE LAUNCHER DEPENDS ON, so they have to keep matching
# ssh(1) rather than matching the launcher:
#
#   * -f MUST RETURN. Real ssh forks after authenticating and setting its forwarding up, and
#     the foreground process exits 0 — which is the whole reason tunnel_start uses it (#38).
#     A fake that stayed in the foreground instead would sit there until run_timeout's ceiling
#     and report a tunnel failure, which is what this did before -f: the launcher backgrounded
#     it, so sleeping was free. Without -f it still sleeps, because a caller that backgrounds
#     this expects a master to stay alive.
#   * -O check PRINTS "Master running (pid=N)" ON STDERR, and tunnel_record_pid reads the
#     pidfile out of exactly that. A fake that only exited 0 would send it to its `ps` fallback,
#     which finds nothing here because no fake process carries the control socket on its
#     command line — so doctor would report "up (pid ?)" for a tunnel it can see.
shim_fake_ssh() {
    cat > "$SHIM/ssh" <<'EOF'
#!/bin/sh
case " $* " in
    *" -O check "*) echo "Master running (pid=$$)" >&2; exit 0 ;;
    *" -O exit "*)  exit 0 ;;
esac
ctl=''; prev=''; fork=no
for a in "$@"; do
    [ "$prev" = "-S" ] && ctl="$a"
    [ "$a" = "-f" ] && fork=yes
    prev="$a"
done
[ -n "$ctl" ] && python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1)' "$ctl"
[ "$fork" = yes ] && exit 0
sleep 30
EOF
    chmod +x "$SHIM/ssh"
}

# Portable in-place file edits. `sed -i` is NOT portable: GNU takes an optional suffix,
# BSD/macOS requires one, so `sed -i '/x/d' f` works on Linux and fails on a Mac.
edit_remove() {                       # edit_remove FILE ERE   — drop matching lines
    grep -vE "$2" "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}
edit_sub() {                          # edit_sub FILE ERE REPLACEMENT
    sed -E "s|$2|$3|" "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# The confighash the launcher would compute right now, read back out of its own printed
# run line rather than recomputed here — so a test cannot disagree with the launcher about
# what the hash is.
current_hash() {
    launcher --dev-print-command | tr ' ' '\n' \
        | sed -n 's/^cs193v\.confighash=\(.*\)/\1/p' | head -1
}

# A throwaway copy of the repo, so a test can mutate container.args without touching the
# working tree. Sets $LAUNCHER_DIR, which `launcher` honours.
#
# NEITHER THE MEMO NOR THE CLEANUP CAN LIVE IN A VARIABLE. Every call site is
# `COPY="$(repo_copy)"`, which is a subshell: the snapshot path and the cleanup entry were
# both assigned in it and neither ever reached the suite. So the memo never fired — every call
# re-tarred the whole tree — and shim_cleanup was never told about a single directory, which
# means a CLEAN run leaked all of them and not just a killed one. Measured at 51 copies and 51
# snapshots in a 3.7 GB tmpfs, 2.9 GB between them (#76). Both now live at paths named from
# $$, which is the suite's pid inside a command substitution as well as outside one.
repo_copy() {                         # repo_copy -> prints the new directory
    local d
    # SNAPSHOT ONCE, on the first call, and serve every later copy from that. Two reasons, and
    # the second is why it matters now that run-tests.sh runs two lanes:
    #
    #   * every copy this suite makes is then of the SAME tree, so a test late in the file
    #     cannot silently disagree with one early in it about what the repo contains;
    #   * 80-launcher-live.sh appends a drift flag to $REPO/.config/container.args and takes it
    #     away again, and it runs in the other lane. A copy taken during that window would
    #     capture the flag. Nothing in here currently asserts anything that would break — the
    #     launcher reads the same copied file, so the two agree — but "I could not find an
    #     assertion it breaks" is not the standard this suite holds itself to elsewhere.
    #
    # The first call happens in this suite's first half-minute, while the other lane is still
    # in the image tier; the live tier cannot start until image, container and tmux are done.
    [ -d "$SHIM_SNAPSHOT" ] || copy_course_tree "$SHIM_SNAPSHOT" || return 1
    d="$(mktemp -d "$SHIM_HOST_TMPDIR/cs193v-repo.$$.XXXXXX")"
    cp -a "$SHIM_SNAPSHOT/." "$d/"
    printf '%s' "$d"
}
