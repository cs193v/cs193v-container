# shellcheck shell=bash
#
# Helpers for driving tests/lib/podman-fake. Source after lib/assert.sh.
#
# MUST STAY BASH 3.2 COMPATIBLE.

# The real temporary directory, captured before shim_new starts redirecting TMPDIR at the
# launcher. Every mktemp in this file uses it, or the second shim would be created inside the
# first and shim_cleanup would delete a repo copy still in use.
SHIM_HOST_TMPDIR="${SHIM_HOST_TMPDIR:-${TMPDIR:-/tmp}}"

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
    SHIM="$(mktemp -d "$SHIM_HOST_TMPDIR/cs193v-shim.XXXXXX")"
    export SHIM CS193V_SHIM="$SHIM"
    mkdir -p "$SHIM/tmp"
    export TMPDIR="$SHIM/tmp"
    cp "$TESTS_DIR/lib/podman-fake" "$SHIM/podman"
    chmod +x "$SHIM/podman"
    : > "$SHIM/argv.log"
    SHIM_DIRS="${SHIM_DIRS:-} $SHIM"
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

shim_cleanup() {
    local d
    for d in ${SHIM_DIRS:-}; do [ -n "$d" ] && rm -rf "$d"; done
    SHIM_DIRS=""
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
repo_copy() {                         # repo_copy -> prints the new directory
    local d
    d="$(mktemp -d "$SHIM_HOST_TMPDIR/cs193v-repo.XXXXXX")"
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
    if [ -z "${REPO_SNAPSHOT:-}" ]; then
        REPO_SNAPSHOT="$(mktemp -d "$SHIM_HOST_TMPDIR/cs193v-snap.XXXXXX")"
        SHIM_DIRS="${SHIM_DIRS:-} $REPO_SNAPSHOT"
        # tar, not cp -a: it is the form that can exclude .git, which is large and irrelevant.
        ( cd "$REPO" && tar cf - --exclude=.git --exclude=./.private/tests . ) \
            | ( cd "$REPO_SNAPSHOT" && tar xf - )
    fi
    cp -a "$REPO_SNAPSHOT/." "$d/"
    SHIM_DIRS="${SHIM_DIRS:-} $d"
    printf '%s' "$d"
}
