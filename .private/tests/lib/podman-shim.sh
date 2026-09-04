# shellcheck shell=bash
#
# Helpers for driving tests/lib/podman-fake. Source after lib/assert.sh.
#
# MUST STAY BASH 3.2 COMPATIBLE.

# The real temporary directory, captured before shim_new starts redirecting TMPDIR at the
# launcher. Every mktemp in this file uses it, or the second shim would be created inside the
# first and shim_cleanup would delete a repo copy still in use.
# DELIBERATELY THE LOGICAL PATH, not `pwd -P`. Resolving it here was tried and reverted: $SHIM
# feeds the TMPDIR handed to the launcher under test, and TUNNEL_CTL is a UNIX SOCKET under that
# TMPDIR whose path is capped near 104 bytes on macOS (cs193v:903 says so). Measured: the logical
# form of a shim control socket is 101 bytes and binds; adding `/private` makes it 109 and fails
# with "AF_UNIX path too long", so the tunnel never came up and every launch warned. Only
# repo_copy's own directory is resolved -- see there.
SHIM_HOST_TMPDIR="${SHIM_HOST_TMPDIR:-${TMPDIR:-/tmp}}"

# The single snapshot repo_copy serves every copy from. A PATH rather than a variable, for the
# reason repo_copy's own comment gives; $$ is the SUITE's pid, so it also tells the sweep
# below and shim_cleanup which of these directories are ours and which a concurrent run's.
SHIM_SNAPSHOT="$SHIM_HOST_TMPDIR/cs193v-snap.$$"

# Whatever an earlier, KILLED run left here. See sweep_stale_tmpdirs in lib/assert.sh for why it
# goes by pid rather than by age, and why it is called at suite start and not only on exit.
shim_sweep_stale() {                  # -> how many directories it removed
    sweep_stale_tmpdirs "$SHIM_HOST_TMPDIR" cs193v-shim cs193v-repo cs193v-snap cs193v-last cs193v-farm
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
    # UNCONDITIONALLY, not only for the cases that assert on it. Every shim run then has a
    # sudo that cannot execute anything, so no case -- including one written later, and
    # including a PTY case that could really sit prompting for the developer's password --
    # can reach the four privileged calls in install-cs193v.sh.
    cp "$TESTS_DIR/lib/sudo-fake" "$SHIM/sudo"
    chmod +x "$SHIM/sudo"
    : > "$SHIM/sudo.log"
    : > "$SHIM/argv.log"
}

shim_set() {                          # shim_set KEY VALUE
    printf '%s' "$2" > "$SHIM/$1"
}

shim_touch() { : > "$SHIM/$1"; }      # for flag-style keys like `hang`

shim_log()  { cat "$SHIM/argv.log" 2>/dev/null; }
# What the installer WOULD have run as root, from the most recent installer_host run.
sudo_log()  { cat "$(cat "$SHIM_LAST" 2>/dev/null)/sudo.log" 2>/dev/null; }
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
    rm -rf "$SHIM_SNAPSHOT" "$SHIM_FARM" \
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
    # THE PTY COMES FROM lib/ptyrun.py, NOT script(1). This used to fork on
    # `script --version | grep util-linux`, and the BSD arm was wrong in a way no Linux run
    # could surface: `script -q /dev/null $cmd` unquoted word-splits $cmd and never invokes a
    # shell, so every quote in it survived as a literal and the run died at
    # `env: ': No such file or directory'`. BSD script cannot do this job at all -- it writes a
    # VEOF before forwarding piped stdin, so keystrokes arrive shifted by one. See ptyrun.py.
    printf '%b' "$keys" | PATH="$SHIM:$PATH" do_script 120 "$cmd" 2>&1
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
    # NO do_script AND NO TIMEOUT LAYER HERE, deliberately. $PTY_PID must be the pty OWNER so
    # launcher_pty_silent_stop can kill the session: a shell function backgrounded gives the
    # pid of the subshell running it, and `timeout` in front would insert a process level
    # exactly where 70-sighup.sh:213 and 60-container.sh:275 walk the tree with `pgrep -P`.
    # 60-container.sh:250 records the cost of getting this wrong -- "killing that leaves
    # script, podman and the tmux client happily alive, so the window was never really closed
    # and every assertion after it measures nothing."
    #
    # ptyrun.py also ACCEPTS THE FIFO, which BSD script refuses outright with
    # `tcgetattr/ioctl: Operation not supported on socket` -- and the fifo is the whole point
    # of this helper, per the comment above.
    PATH="$SHIM:$PATH" "$DO_PY" "$PT_LIB/ptyrun.py" "$cmd" < "$PTY_FIFO" > "$PTY_OUT" 2>&1 &
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
    printf '%b' "$keys" | do_script 120 "$cmd" 2>&1
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

# TRACED WHEN THERE IS SOMEWHERE TO PUT IT. With CS193V_RUN_DIR set -- which run-tests.sh
# exports -- every run records which of the installer's lines executed, so a later suite can
# union them and say what the whole suite reached. PS4 carries $LINENO and the trace goes to
# fd 9, so the installer's own output is untouched: verified, not assumed, because a trace
# leaking into stdout would corrupt every assert_says in this file.
#
# The line numbers are the ORIGINAL's, because edit_sub substitutes in place and 10-static.sh
# asserts the copy and the original have the same length. Without that the numbers would drift
# silently and the gate would measure nothing.
installer_trace_file() {
    [ -n "${CS193V_RUN_DIR:-}" ] || return 1
    mkdir -p "$CS193V_RUN_DIR/trace" 2>/dev/null || return 1
    # NAMED BY SUITE, not just by pid: the gate has to know WHICH producers reported, so that a
    # missing one is a named skip rather than a quietly smaller union. run-tests.sh exports
    # CS193V_SUITE per suite; a direct run of a suite has none, which is itself informative.
    printf '%s/trace/%s.%s' "$CS193V_RUN_DIR" "${CS193V_SUITE:-standalone}" "$$"
}

installer_host() {                    # installer_host SCRIPT [VAR=VALUE...] -> output
    local script="$1" tf; shift
    mkdir -p "$SHIM/home"
    printf '%s' "$SHIM" > "$SHIM_LAST"
    if tf="$(installer_trace_file)"; then
        # THE TRACE FD COMES FROM lib/shared.sh, and it is NOT 9 -- see the reasoning there. In
        # short: this variable is EXPORTED, so every descendant of the traced installer inherits
        # it, including programs the launcher runs; run_timeout owns fd 9 and closes it for its
        # command; and bash validates BASH_XTRACEFD at startup, so a child arrived naming a closed
        # fd and wrote a diagnostic into the output this captures.
        #
        # A SUBSHELL WITH AN `exec`, rather than a redirection on the env line, because
        # `exec $fd>>file` is not a redirection -- bash wants the number as a literal, so the open
        # has to go through eval. Only the OPEN does: the command stays a real argv, which is what
        # keeps "$@" and $script safe from a second round of word splitting.
        #
        # OPENED BEFORE BASH_XTRACEFD EXISTS, and the order is load-bearing: bash validates the
        # variable on assignment, so setting it first would make THIS shell print the very
        # diagnostic being avoided. Setting it through `env` keeps it out of this shell entirely.
        (
            eval "exec $CS193V_TRACE_FD>>\"\$tf\""
            env HOME="$SHIM/home" PATH="$SHIM:$PATH" PS4='+${LINENO} ' \
                BASH_XTRACEFD="$CS193V_TRACE_FD" "$@" \
                bash -x "$script" </dev/null 2>&1
        )
    else
        env HOME="$SHIM/home" PATH="$SHIM:$PATH" "$@" bash "$script" </dev/null 2>&1
    fi
}

installer_host_rc() {                 # installer_host_rc SCRIPT [VAR=VALUE...] -> rc
    installer_host "$@" >/dev/null 2>&1
    printf '%s' "$?"
}

# argv.log from the most recent installer_host run, whichever subshell it happened in.
installer_log() { cat "$(cat "$SHIM_LAST" 2>/dev/null)/argv.log" 2>/dev/null; }

# The same door, through a real pty. Needed because menu() deliberately takes the safe
# default when stdin or stdout is not a terminal, so with no tty ask_consent DECLINES and
# every step after it is unreachable -- which is why nothing had ever executed
# install_podman, setup_subuid or setup_wslconf.
#
# KEYS goes through printf %b: \033[B is down, \n is Enter. menu() also accepts a DIGIT,
# which selects and breaks in one keystroke (`[1-9]) sel=$((key-1)); break`), so a case that
# is not specifically about arrow keys should send "2" rather than an escape sequence.
#
# HOME= IS SPELT OUT AGAIN HERE rather than shared with installer_host, because a pty needs
# a command STRING and the other needs an argv. 10-static.sh asserts both doors set it --
# the same way this project handles version_lt and box() being duplicated between the
# launcher and the installer: assert the agreement rather than pretend there is one copy.
installer_tty() {                     # installer_tty KEYS SCRIPT [VAR=VALUE...]
    local keys="$1" script="$2"; shift 2
    local cmd a tf
    mkdir -p "$SHIM/home"
    printf '%s' "$SHIM" > "$SHIM_LAST"
    cmd="env HOME=$SHIM/home PATH=$SHIM:$PATH"
    for a in "$@"; do cmd="$cmd $a"; done
    if tf="$(installer_trace_file)"; then
        # No eval needed on this door: it is BUILDING a command string for `script -c`, so the fd
        # number interpolates like any other word. `$CS193V_TRACE_FD>>$tf` has to stay unspaced --
        # `8 >>file` is the number as an argument, not a redirection.
        cmd="$cmd PS4='+\${LINENO} ' BASH_XTRACEFD=$CS193V_TRACE_FD"
        cmd="$cmd bash -x $script $CS193V_TRACE_FD>>$tf"
    else
        cmd="$cmd bash $script"
    fi
    printf '%b' "$keys" | do_script 120 "$cmd" 2>&1
}

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

# ─── podman that is installed and invisible: issue #121 ────────────────────────
#
# THE ONE THING A SHIM CANNOT DO BY PREPENDING. Every other helper in this file works by
# putting something FIRST on PATH. These three need the opposite -- a PATH with no podman on
# it at all -- because that is the machine issue #121 describes: the .pkg put podman in a
# directory only /etc/paths.d names, and nothing has read /etc/paths.d in this shell.
#
# IT CANNOT BE SPELLED BY FILTERING THE REAL PATH. On Linux podman lives in /usr/bin, next to
# awk, sed, id, find, xargs, sha256sum and ssh, so dropping the directory that holds podman
# drops the launcher's whole toolbox with it. (On a Mac the filter WOULD work -- /opt/podman/bin
# holds only podman and its helpers -- and a fixture that behaved differently on the two
# platforms is how a case comes to pass for a reason nobody chose.)
#
# NOR CAN PODMAN BE HIDDEN IN PLACE. Measured on bash 3.2.57: `command -v` skips a
# non-executable file AND a directory of the same name and keeps searching, so no entry
# prepended to PATH can make a later executable invisible.
#
# So the PATH is BUILT rather than edited: one directory of symlinks to everything the real
# PATH offers, minus podman. Complete by construction, which is what a hand-maintained tool
# list would not have been -- a farm silently missing `sed` makes the launcher fail in a way
# that reads as a launcher bug rather than as a broken fixture.
SHIM_FARM="$SHIM_HOST_TMPDIR/cs193v-farm.$$"

# ONE `ln -s` PER PATH DIRECTORY, not one per file: 1387 links in 0.15s where the per-file
# loop took 2.46s, which is real money in the cheap lane. Collisions are the point rather
# than a problem -- without -f, an earlier PATH directory wins, which is exactly PATH
# precedence -- so ln's complaints about them go to /dev/null.
#
# MEMOISED like SHIM_SNAPSHOT and named from $$ for the same reasons: every case in a suite
# then gets the same farm, and shim_cleanup can tell ours from a concurrent run's.
shim_toolfarm() {                     # shim_toolfarm -> a directory of tools, minus podman
    local d old
    if [ ! -d "$SHIM_FARM" ]; then
        mkdir -p "$SHIM_FARM" || return 1
        old="$IFS"; IFS=:
        for d in $PATH; do
            IFS="$old"
            [ -d "$d" ] || continue
            ln -s "$d"/* "$SHIM_FARM/" 2>/dev/null
            IFS=:
        done
        IFS="$old"
        # AFTER the loop, not by skipping it: either of these could be reachable from more than
        # one PATH directory, and this way the farm cannot end up with whichever copy came second.
        #
        # TWO NAMES, AND pkgutil IS THE SECOND ON PURPOSE. It is the other binary these cases
        # control, through shim_fake_pkgutil. A real /usr/sbin/pkgutil left in the farm would be
        # shadowed by the fake whenever a case installs one -- and would silently answer from
        # the DEVELOPER'S OWN MACHINE for any case that forgot to. Nothing here wants the real
        # one, so the farm does not carry it.
        rm -f "$SHIM_FARM/podman" "$SHIM_FARM/pkgutil"
    fi
    printf '%s' "$SHIM_FARM"
}

# The fake podman, moved somewhere PATH does not name. $SHIM ITSELF STAYS FIRST ON PATH, so
# sudo-fake, argv.log and every other case's expectations are undisturbed -- what changes is
# that $SHIM no longer holds a podman. podman-fake reads its state out of $CS193V_SHIM, which
# shim_new exports, so it goes on answering `state`, `version` and the rest from where it is.
shim_offpath_podman() {               # shim_offpath_podman -> the directory it moved it to
    mkdir -p "$SHIM/offpath" || return 1
    mv "$SHIM/podman" "$SHIM/offpath/podman" || return 1
    printf '%s' "$SHIM/offpath"
}

# Fake `pkgutil`, which is how ensure_podman_path asks macOS where the .pkg put podman.
#
# ANSWERS ONLY THE IDENTIFIER IT WAS GIVEN, and exits 1 for any other -- the doctrine
# shim_fake_sysctl states above and for the same reason: a fake that returned an empty line
# for an unknown package would feed an empty string into the composition this exists to
# exercise, and the case would pass for the wrong reason.
#
# THE TWO-CALL SHAPE IS THE REAL ONE. `--pkg-info` answers a `location:` relative to the
# volume root with no leading slash (`opt`), and `--only-files --files` answers paths relative
# to THAT (`podman/bin/podman`); the caller composes them. BINDIR is split the same way so the
# composition under test is the same arithmetic on a fabricated pair as on a real receipt.
shim_fake_pkgutil() {                 # shim_fake_pkgutil ID BINDIR
    local loc rel
    # The leading slash comes back in the caller's "/$loc/...", so it is stripped here.
    loc="${2#/}"; loc="${loc%/*}"
    rel="${2##*/}/podman"
    cat > "$SHIM/pkgutil" <<EOF
#!/bin/sh
id=""
for a in "\$@"; do case "\$a" in --*) ;; *) id="\$a" ;; esac; done
[ "\$id" = "$1" ] || { echo "No receipt for '\$id' found at '/'." >&2; exit 1; }
case "\$1" in
    --pkg-info)   printf 'package-id: %s\nversion: 0.0.0\nvolume: /\nlocation: %s\n' "$1" "$loc" ;;
    --only-files) printf '%s\n%s\n' "$rel" "${rel%podman}podman-mac-helper" ;;
    *)            echo "pkgutil: unsupported in this fake: \$1" >&2; exit 1 ;;
esac
EOF
    chmod +x "$SHIM/pkgutil"
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
# THE TEMPORARY IS SEEDED WITH `cp -p`, WHICH IS THE WHOLE POINT OF THE LINE. Both of these
# write a new file and mv it over the original, so without this the result carries the default
# umask -- 644 -- and the original's mode is GONE. That was harmless for years because every
# caller edited container.args or an installer copy that is run as `bash "$script"`, and a mode
# is invisible to both. The first caller to edit a file that is then EXECUTED (the launcher, in
# 30-launcher-shim.sh's issue-#121 section) got `Permission denied` and exit 126 from every run
# afterwards, which reads as a launcher bug and is not one.
#
# `cp -p` RATHER THAN chmod --reference, which is GNU-only and would fail on the Macs this suite
# has to run on. The redirection truncates the copy without changing its mode.
edit_remove() {                       # edit_remove FILE ERE   — drop matching lines
    cp -p "$1" "$1.tmp" || return 1
    grep -vE "$2" "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}
edit_sub() {                          # edit_sub FILE ERE REPLACEMENT
    cp -p "$1" "$1.tmp" || return 1
    sed -E "s|$2|$3|" "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# The confighash the launcher would compute right now, read back out of its own printed
# run line rather than recomputed here — so a test cannot disagree with the launcher about
# what the hash is.
current_hash() {
    launcher --dev-print-command | do_tr ' ' '\n' \
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
    # PHYSICAL, because the launcher resolves its own directory with `pwd -P` and prints that in
    # cs193v.dir and in the foreign-directory refusal -- so a $COPY in /var/... could never match
    # a label in /private/var/... . Resolved HERE and not at SHIM_HOST_TMPDIR: this path is only
    # ever compared as a string, whereas $SHIM carries the tunnel's unix socket and cannot afford
    # the extra 8 bytes (see the note on SHIM_HOST_TMPDIR above).
    d="$(cd -- "$d" && pwd -P)"
    cp -a "$SHIM_SNAPSHOT/." "$d/"
    printf '%s' "$d"
}
