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
        printf '%b' "$keys" | PATH="$SHIM:$PATH" script -q -c "$cmd" /dev/null 2>&1
    else
        # shellcheck disable=SC2086
        printf '%b' "$keys" | PATH="$SHIM:$PATH" script -q /dev/null $cmd 2>&1
    fi
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
    ( cd "$REPO" && tar cf - --exclude=.git --exclude=tests . ) | ( cd "$d" && tar xf - )
    SHIM_DIRS="${SHIM_DIRS:-} $d"
    printf '%s' "$d"
}
