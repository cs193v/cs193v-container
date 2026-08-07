# shellcheck shell=bash
#
# Helpers for driving tests/lib/podman-fake. Source after lib/assert.sh.
#
# MUST STAY BASH 3.2 COMPATIBLE.

# shim_new [DIR]  -> creates a shim, sets $SHIM, and puts it first on $PATH for `launcher`.
# A fresh shim per test keeps state from leaking between cases.
shim_new() {
    SHIM="$(mktemp -d "${TMPDIR:-/tmp}/cs193v-shim.XXXXXX")"
    export SHIM CS193V_SHIM="$SHIM"
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

# A pty makes the launcher turn colour on, so assertions need the escapes gone.
strip_ansi() {
    sed -e 's/'"$(printf '\033')"'\[[0-9;]*[A-Za-z]//g' -e 's/'"$(printf '\r')"'//g'
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
# from the shell; the file survives the process, so the socket does not need holding open —
# only the master does, for the `kill -0` in tunnel_start's wait loop.
shim_fake_ssh() {
    cat > "$SHIM/ssh" <<'EOF'
#!/bin/sh
case " $* " in
    *" -O check "*|*" -O exit "*) exit 0 ;;
esac
ctl=''; prev=''
for a in "$@"; do
    [ "$prev" = "-S" ] && ctl="$a"
    prev="$a"
done
[ -n "$ctl" ] && python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1)' "$ctl"
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
    d="$(mktemp -d "${TMPDIR:-/tmp}/cs193v-repo.XXXXXX")"
    # cp -a of the repo root, excluding .git, which is large and irrelevant here.
    ( cd "$REPO" && tar cf - --exclude=.git --exclude=./.private/tests . ) | ( cd "$d" && tar xf - )
    SHIM_DIRS="${SHIM_DIRS:-} $d"
    printf '%s' "$d"
}
