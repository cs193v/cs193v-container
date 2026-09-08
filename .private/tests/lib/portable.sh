# shellcheck shell=bash
# Userland portability for the test harness. Sourced by lib/assert.sh, and by run-tests.sh.
#
# MUST STAY BASH 3.2 COMPATIBLE -- see lib/assert.sh for why. Expanding an EMPTY array under
# `set -u` is fatal on bash < 4.4, so this file uses no arrays at all.
#
# WHY THIS FILE EXISTS. The suite was developed on Linux and reaches for GNU tools. On macOS a
# full run gave 1520 pass / 344 fail, and 343 of those were the harness rather than the product.
# The tools divide three ways, and only the middle group is a mere flag:
#
#   ABSENT ENTIRELY      timeout(1), ss(8)      -- nothing to wrap; resolve or substitute
#   DIFFERENT SIGNATURE  script(1), stat(1)     -- `-c %a` vs `-f %Lp` are two format LANGUAGES
#   SAME, BUT LOCALE     tr(1)                  -- a prefix is the whole cure
#
# So these are not one pattern applied five times, and the comments say which is which.
#
# PATH IS DELIBERATELY NOT TOUCHED. Putting coreutils' libexec/gnubin on PATH would fix the
# harness and break the point of running here: `cs193v` and `install-cs193v.sh` are the things
# under test, and they must meet the same BSD sed/awk/stat/mktemp a student's Mac has. Every
# wrapper below resolves an explicit binary instead.
#
# INERT AT SOURCE TIME: assignments, probes and function definitions only. No output, no traps,
# no exit -- the same rule files/cs193v-ui.sh:34 states, and what lets run-tests.sh source this
# above its option loop, before the gate has validated anything.

PT_LIB="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# ─── the fatal path, and what it is honestly worth ─────────────────────────────
# STDERR AND exit 96, not fail(). fail() is wrong because most wrappers are called from inside a
# `$( )` -- a transcript or a stat value is a VALUE handed to an assertion -- so a recorded FAIL
# would be a second result for one fault.
#
# BUT exit 96 DOES NOT STOP THE RUN, and it is worth being exact about that because an earlier
# draft of the plan assumed it did. Measured: from inside a `$( )` the caller keeps going, the
# substitution yields the empty string, and 96 is visible only to whoever checks $?. So this
# prints a diagnosis a human will see and nothing more. THE PREFLIGHT GATE in run-tests.sh is
# what actually prevents a half-equipped machine from running; this is the backstop for the case
# the gate somehow missed. Same limitation as _emit's rc 97 (lib/assert.sh:72), which escapes
# only because it is never called from a substitution.
_pt_fatal() {                         # _pt_fatal TOOL WHY
    printf '\nFATAL  %s is not usable on this machine: %s\n' "$1" "$2" >&2
    printf '       The preflight in run-tests.sh should have caught this.\n' >&2
    exit 96
}

# ─── resolution: by CAPABILITY, once, at source time ──────────────────────────
# PREFER THE g-PREFIXED NAME, fall back to the bare one, and VERIFY the one picked actually
# accepts the flag we need.
#
# An earlier draft asked `[ -d /proc/self ]` -- "is this a GNU userland". That asks about the
# KERNEL when the question is about THIS BINARY, and is wrong both ways: coreutils' gnubin on a
# Mac's PATH gives GNU stat with no /proc/self, while busybox on Linux gives /proc/self with a
# stat that has no GNU -c. It also created two sources of truth, the gate checking one thing and
# the resolver deciding another -- exactly what made an earlier `tr` row inconsistent.
#
# NOT LAZY, on purpose. Most wrappers are called inside `$( )`, so a cache written on first use
# is written in a subshell and thrown away -- the #76 shape. Two or three forks once is cheaper
# than re-probing forever.
#
# STDIN FROM /dev/null so a probe can never block waiting for input.
_pt_pick() {                          # _pt_pick GNU_NAME PLAIN_NAME TESTARGS...
    local c p
    for c in "$1" "$2"; do
        p="$(command -v "$c" 2>/dev/null)" || continue
        [ -n "$p" ] || continue
        if "$p" "${@:3}" >/dev/null 2>&1 </dev/null; then printf '%s' "$p"; return 0; fi
    done
    return 1
}

# timeout: ABSENT on macOS, so this is presence, not divergence. Homebrew's coreutils installs it
# UNPREFIXED (there is no BSD original to collide with) as well as as gtimeout, so a bare
# `timeout` on a Mac can only be GNU -- but probe anyway rather than reason about it.
DO_TIMEOUT="$(_pt_pick gtimeout timeout --version || true)"

# stat: PRESENT on macOS and BSD, which is worse than absent -- `command -v stat` succeeds and
# then answers `illegal option -- c`. Homebrew installs only gstat, because /usr/bin/stat exists.
DO_STAT="$(_pt_pick gstat stat -c %a / || true)"

# sha256sum: probed with a FILE argument, never bare, or the probe would read stdin. Modern macOS
# ships /sbin/sha256sum in GNU format (verified byte-identical to gsha256sum and shasum -a 256),
# so the old "a TA's Mac has shasum" note in lib/sandbox.sh was already stale.
DO_SHA256="$(_pt_pick gsha256sum sha256sum /dev/null || true)"

# awk: SOFT. Every host-side awk program in this tree was tested against BSD awk and works, and
# the documented Darwin hazard ($NF/$1 reset inside an END action) appears nowhere here. So this
# never fatals and gawk is NOT a dependency.
DO_AWK="$(_pt_pick gawk awk --version || command -v awk 2>/dev/null || true)"

# python3: load-bearing for ptyrun.py. macOS's own 3.9.6 is fine -- pty, select and os are
# ancient. Deliberately NOT a 3.11 floor: brew install python@3.13 would shadow /usr/bin/python3
# for the PRODUCT too, which is the PATH-cleanliness rule above.
DO_PY="$(command -v python3 2>/dev/null || true)"

# listeners: ss on Linux, lsof on macOS. NOT netstat -- macOS netstat has no pid option under any
# flag (-p is protocol) and prints 127.0.0.1.58877 rather than :58877.
DO_SS="$(command -v ss 2>/dev/null || true)"
DO_LSOF="$(command -v lsof 2>/dev/null || true)"

export DO_TIMEOUT DO_STAT DO_SHA256 DO_AWK DO_PY DO_SS DO_LSOF

# ─── the wrappers ─────────────────────────────────────────────────────────────

do_timeout() {                        # do_timeout SECS CMD...   (also --kill-after=N SECS CMD...)
    [ -n "$DO_TIMEOUT" ] || _pt_fatal timeout 'no GNU timeout(1); macOS ships none (brew install coreutils)'
    "$DO_TIMEOUT" "$@"
}

do_stat() {                           # do_stat -c FORMAT FILE...
    [ -n "$DO_STAT" ] || _pt_fatal stat 'no stat(1) accepting GNU -c (brew install coreutils)'
    "$DO_STAT" "$@"
}

# LC_ALL=C IS THE ENTIRE CURE, and it is an assignment PREFIX so it applies to this invocation
# only. Forcing it run-wide breaks 9 multibyte comparisons against messages.txt. No gtr: measured
# byte-identical to LC_ALL=C /usr/bin/tr on every form this tree uses, invalid UTF-8 included.
do_tr() { LC_ALL=C tr "$@"; }

do_awk() {
    [ -n "$DO_AWK" ] || _pt_fatal awk 'no awk(1) on PATH'
    "$DO_AWK" "$@"
}

do_sha256() {
    [ -n "$DO_SHA256" ] || _pt_fatal sha256sum 'no sha256sum(1) (brew install coreutils)'
    "$DO_SHA256" "$@"
}

# do_script SECS CMD -- a pty, with the timeout applied INSIDE so each caller keeps its own.
#
# script(1) IS NOT USED. BSD script writes a VEOF before forwarding piped stdin, so every read
# shifts by one and the last keystroke is never consumed, and it hard-errors on a fifo stdin --
# see lib/ptyrun.py's header for the measurements. There is nothing to install either: Homebrew's
# util-linux excludes script and scriptlive on Darwin.
#
# THE TIMEOUT GOES INSIDE. An earlier draft wrote `do_timeout 120 do_script "$cmd"`, which cannot
# run: timeout execvp()s and cannot see a shell function (rc 127, and the ~125 negative
# assertions behind these helpers then pass on an empty transcript). The literal 120 also
# discarded ${SG_TIMEOUT:-120} and the 600 at 90-setup-git-github.sh:178.
#
# BACKGROUNDED CALLERS DO NOT USE THIS. Six sites read $! to kill the session and must have the
# pty owner's pid, and `timeout` in front would insert a process level of its own. Three of them
# also need the pid of the command INSIDE the pty; they all use pty_start below. See
# 60-container.sh's close_client for what the pid being wrong costs.
do_script() {                         # do_script SECS CMD
    [ -n "$DO_PY" ] || _pt_fatal python3 'no python3 on PATH; lib/ptyrun.py needs it'
    [ -n "$DO_TIMEOUT" ] || _pt_fatal timeout 'no GNU timeout(1) (brew install coreutils)'
    "$DO_TIMEOUT" "$1" "$DO_PY" "$PT_LIB/ptyrun.py" "$2"
}

# ─── pty_start / pty_inner_pid: a backgrounded pty, and the pid of what is IN it ──────────────
#
# THE SIX BACKGROUNDED SITES USED TO HAND-ROLL THIS, and three of them then inferred the
# command's pid with `pgrep -P "$!" | head -1`. That inference is only correct when the `/bin/sh`
# ptyrun execs optimises itself away, which is not a property any shell specifies -- see the
# matrix in lib/ptyrun.py's header. #151 is what it costs when it is wrong: 70-sighup.sh killed
# the pty session leader instead of the launcher, so the kernel HUPed the launcher, its trap ran,
# and the assertion inverted; 60-container.sh's close_client killed the wrong pid and the three
# non-event assertions after it passed anyway.
#
# So the command announces its own pid through lib/pty-announce and nothing here reads the
# process table. See that file for why `$$` and `exec` are safe where the optimisation is not.
#
# KEYS, NOT A PIPE, and that is forced rather than stylistic. `printf ... | pty_start ...` would
# run this function in a SUBSHELL, so $! would never reach the caller -- the same trap
# 60-container.sh's close_client comment describes for `f &`. The keystrokes go to a file and
# ptyrun reads that; a regular file hits EOF exactly as the pipe did, and ptyrun's documented
# response to EOF on its stdin is to stop watching it without closing the master.
#
# CALLERS REDIRECT THE FUNCTION, e.g. `pty_start 'x\n' cmd >"$LOG" 2>&1`. A redirection on a
# function call does not create a subshell, so $! still propagates.
#
# A FRESH PIDFILE EVERY TIME, removed before the background starts. 70-sighup.sh launches three
# times and 60-container.sh twice; measured with one reused path, the second launch reads the
# FIRST launch's pid, which is dead or -- because pids are reused -- somebody else's. Then
# `kill -9` hits a stranger and every assertion after it measures nothing. `cs193v`'s
# tunnel_kill_pid states the same rule: "IDENTIFIED BEFORE KILLED. Pids are reused".
pty_start() {                         # pty_start KEYS CMD... -> sets PTY_OWNER, PTY_PIDFILE
    [ -n "$DO_PY" ] || _pt_fatal python3 'no python3 on PATH; lib/ptyrun.py needs it'
    local keys="$1"; shift
    local dir cmd a
    dir="${TMPDIR:-/tmp}"
    PTY_PIDFILE="$(mktemp "$dir/cs193v-ptypid.$$.XXXXXX")"
    PTY_FEED="$(mktemp "$dir/cs193v-ptyfeed.$$.XXXXXX")"
    rm -f "$PTY_PIDFILE" "$PTY_PIDFILE.tmp"
    printf '%b' "$keys" > "$PTY_FEED"
    # THE WRAPPER IS PREPENDED HERE, NOT ASKED OF THE CALLER. It was a caller's job for one
    # revision of this function and two of the three callers promptly forgot it -- reported by the
    # container tier as `the-client-announced-a-live-pid`, LOUDLY, because the silent
    # `else kill -9 "$1"` fallback it replaced is gone. The point of #151's fix is a pid channel
    # guaranteed by the interface rather than remembered at each site, so the interface guarantees
    # it. 10-static.sh asserts this line is still here.
    cmd="'$PT_LIB/pty-announce'"
    # EVERY INTERPOLATED ARGUMENT SINGLE-QUOTED (#141). This string is parsed a SECOND time, by
    # the `/bin/sh -c` inside ptyrun.py, so an unquoted path containing a space word-splits there.
    # Measured: an unquoted $REPO with a space dies with `/bin/sh: /.../Keith: No such file or
    # directory`, and that was true of all three of these call sites as they stood. Not exotic --
    # WSL's interop.appendWindowsPath is on by default and a spacey $HOME is ordinary.
    for a in "$@"; do cmd="$cmd '$a'"; done
    CS193V_PTY_PIDFILE="$PTY_PIDFILE" \
        "$DO_PY" "$PT_LIB/ptyrun.py" "$cmd" < "$PTY_FEED" &
    PTY_OWNER=$!
}

# pty_inner_pid -> prints the pid the COMMAND itself runs as; rc 1 and prints nothing if it never
# announced one. THE CALLER MUST TREAT THAT AS A FAILURE, not fall back to a pid it can guess:
# close_client's old `else kill -9 "$1"` arm is precisely how #151 stayed invisible there.
pty_inner_pid() {                     # pty_inner_pid -> PID on stdout, rc 0; else rc 1
    local i=0 max=$(( ${PTY_INNER_WAIT:-10} * 20 )) pid
    while [ "$i" -lt "$max" ]; do
        if [ -s "${PTY_PIDFILE:-/nonexistent}" ]; then
            pid="$(cat "$PTY_PIDFILE" 2>/dev/null | do_tr -d ' \n')"
            # ALL DIGITS, not merely non-empty. lib/podman-shim.sh's fake-sysctl comment states
            # the rule: a fixture that returns something unparseable must be an error, never a
            # value -- "an empty string into the installer's arithmetic".
            case "$pid" in
                ''|*[!0-9]*) : ;;
                *) printf '%s\n' "$pid"; return 0 ;;
            esac
        fi
        sleep 0.05
        i=$((i + 1))
    done
    return 1
}

# pid_is_gone PID -> 0 when that pid is no longer a running process.
#
# STATE, NOT `kill -0`, and 12-run-timeout.sh already paid for this lesson: "kill -0 succeeds on
# a zombie". A pid we have just killed is reaped by its parent, and until that happens it is still
# in the process table -- so a check built on `kill -0` would report the thing we killed as alive
# for as long as the reap took, which is a race whose failures look like real ones. `ps -o state=`
# is empty when the pid is gone and `Z` while it is a zombie, and both mean gone for our purposes.
# Portable as written: macOS and Linux both accept `-p PID -o state=`.
pid_is_gone() {                       # pid_is_gone PID
    case "$(ps -p "${1:-0}" -o state= 2>/dev/null | do_tr -d ' \n')" in
        ''|Z*) return 0 ;;
        *)     return 1 ;;
    esac
}

# pty_stop -> take the session down and collect the scratch files pty_start made.
#
# IT READS THE GLOBALS pty_start SET, so it belongs to the MOST RECENT pty_start and must be
# called before the next one. A caller that keeps two ptys alive at once -- 60-container.sh's
# start_client/close_client pair, which spans dozens of assertions -- saves $PTY_OWNER and
# $PTY_PIDFILE for itself and does its own teardown instead. 80-launcher-live.sh's race group,
# which runs four at once, does the same.
pty_stop() {                          # pty_stop [INNER_PID...]
    local p
    for p in "$@"; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done
    [ -n "${PTY_OWNER:-}" ] && kill -9 "$PTY_OWNER" 2>/dev/null
    [ -n "${PTY_OWNER:-}" ] && wait "$PTY_OWNER" 2>/dev/null
    rm -f "${PTY_PIDFILE:-}" "${PTY_PIDFILE:-}.tmp" "${PTY_FEED:-}"
    return 0
}

# ─── do_listeners: the one format every consumer parses ───────────────────────
# Emits, one per line:   ADDR:PORT<TAB>pid=NNN        (pid= empty when not visible to us)
#
# THIS EXISTS BECAUSE OF THE WORST FAILURE THIS SUITE HAS HAD. Twelve host-side sites read `ss`
# and swallowed its absence with `2>/dev/null` and `|| true`. macOS has no ss, so they yielded
# EMPTY and every consumer reported a confident zero: fwd_owned_ports found nothing,
# count_forwards was 0, no_forwards() was unconditionally TRUE -- so every "the forwards were
# released" assertion and every `wait_until N no_forwards` passed having measured nothing, while
# dyn_is_forwarded was unconditionally false. A missing tool must therefore be FATAL here, never
# empty.
#
# THE PID IS NOT OPTIONAL. fwd_owned_ports, fwd_squatters and 60-container.sh:134,143 all ask
# "is this listener OURS", which has no answer without it. That is why netstat is not a backend:
# macOS netstat cannot report one at all.
#
# lsof IS PARSED IN -F MODE, not columns: a command name containing a space shifts every column,
# and `Google Chrome` is a real listener on a developer's Mac. -Fpn emits `p<pid>` to open a
# process set and `n<name>` per socket, which cannot be shifted.
do_listeners() {
    if [ -n "$DO_SS" ]; then
        "$DO_SS" -ltnp 2>/dev/null | do_awk '
            $1 == "LISTEN" {
                pid = ""
                if (match($0, /pid=[0-9]+/)) pid = substr($0, RSTART + 4, RLENGTH - 4)
                printf "%s\tpid=%s\n", $4, pid
            }'
    elif [ -n "$DO_LSOF" ]; then
        "$DO_LSOF" -nP -iTCP -sTCP:LISTEN -Fpn 2>/dev/null | do_awk '
            /^p/ { pid = substr($0, 2); next }
            /^n/ { printf "%s\tpid=%s\n", substr($0, 2), pid }'
    else
        _pt_fatal listeners 'neither ss(8) nor lsof(8) is available; the tunnel cannot be measured'
    fi
}

# ─── the remaining GNU-only host-side uses ────────────────────────────────────
# `df -BG --output=avail` is GNU-only; BSD df spells it `-g` and has no --output.
do_df_avail() {                       # do_df_avail PATH -> whole gigabytes available
    df -g "$1" 2>/dev/null | do_awk 'NR == 2 { print $4; found = 1 }
                                     END { if (!found) exit 1 }' \
    || df -BG --output=avail "$1" 2>/dev/null | do_tr -dc '0-9'
}

# `hostname -I` is GNU-only and lists every address; BSD hostname has no -I.
do_host_ips() {                       # do_host_ips -> space-separated IPv4 addresses
    hostname -I 2>/dev/null && return 0
    ipconfig getifaddr en0 2>/dev/null && return 0
    do_listeners >/dev/null 2>&1      # keep the fatal path consistent if nothing works
    return 1
}

# ─── the dependency registry, and what the preflight reads (#124) ─────────────
# ONE LIST, shared with the resolvers above so the gate and the wrappers cannot disagree about
# what this machine has -- an earlier draft had the gate accept BSD `tr` on a presence check while
# the resolver refused to use it, and the run then died mid-suite.
#
# KIND|NAME|WHY|MACOS_PKG|DEBIAN_PKG|FEDORA_PKG
#
#   cmd   present on PATH at all
#   gnu   a resolver above found a usable one (presence is NOT enough: `command -v stat` succeeds
#         on a Mac and then answers `illegal option -- c`)
#   any   one of several will do
#   run   present AND able to run a program
#
# THREE COLUMNS AND NOT TWO (#195). The Debian column used to serve every machine that was not a
# Mac, so a Fedora developer whose machine failed this gate was told `sudo apt install -y iproute2`
# -- the wrong package manager, and then a spelling that distro does not have. The installer has
# had a real two-family table since #94 (install-cs193v.sh:487-504); this was the last place in
# the tree that guessed. A column whose first character is `(` is advice with no remedy rather
# than a package name, which is why the macOS column can say `(ships with macOS)`.
#
# THE FEDORA COLUMN WAS MEASURED IN fedora:43 -- the fixtures/Containerfile.fedora pin, run
# natively -- rather than read off a wiki, and none of these four is what a careful guess
# produces:
#   listeners       iproute           there is no `iproute2` package on Fedora at all
#   ssh             openssh-clients   and `openssh-client` singular does not exist. ssh-keygen
#                                     shares it: that FILE belongs to `openssh`, which
#                                     openssh-clients Requires by exact version, so one package
#                                     still covers both rows exactly as on Debian
#   podman          podman            `dnf install podman` pulls crun and passt as DEPENDENCIES
#                                     where apt only Recommends them, and the setuid helpers are
#                                     in shadow-utils, which owns usermod and cannot be absent --
#                                     install-cs193v.sh:501 sets PKG_UIDMAP="" for that reason
#   `shellcheck`    ShellCheck        the canonical spelling. dnf5 resolves the lowercase form
#                                     too, but a column that names a package should name it
#
# ssh AND ssh-keygen ARE `cmd` DELIBERATELY, and this is the row-kind decision somebody will try
# to improve. Presence CAN lie here -- a dropbear `ssh` answers none of -M, -S or -O -- but the
# gate's job for these two is to predict what the LAUNCHER will refuse, and its preflight asks
# exactly `command -v`. A deeper probe would refuse machines the launcher accepts, and refusing a
# sound machine costs the whole run -- exit 78, no results file -- where under-refusing costs a
# diagnosis. podman is the same split for the same reason: lib/sandbox.sh's PODMAN-WORKS note
# records that `command -v podman` lies, and that row is still `cmd`, because the version and
# rootless checks live in the product.
#
# NOT IN HERE, deliberately:
#   script(1)  nothing uses it any more -- lib/ptyrun.py replaced it, because BSD script cannot
#              deliver keystrokes and there is no GNU one to install on macOS.
#   tmux       65-tmux.sh:17-22 records the decision that the harness runs INSIDE the container,
#              so a host-side tmux would be a dependency nothing uses.
#   awk, sed, tr, mktemp, pgrep, grep
#              present and adequate on every platform this runs on; a row that cannot fail is
#              noise in a report whose whole value is that every line in it is actionable.
#   uname      UNREPRESENTABLE, which is a different reason from the group above rather than one
#              more member of it: run-tests.sh reads `uname -s` to choose WHICH COLUMN of a row
#              to print, so a row for uname would need a uname in order to report itself
#              missing. 14-test-harness.sh's gate fixture fakes one instead. /etc/os-release
#              joined it as an input in #195, and is unrepresentable for a second reason as
#              well: the machine that lacks that file is a Mac, which is not a machine with
#              something to install.
PT_REGISTRY='cmd|shellcheck|10-static.sh lints every shipped script with it|shellcheck|shellcheck|ShellCheck
cmd|podman|the install, image, container and live tiers drive it|podman|podman passt uidmap crun|podman
cmd|curl|reads a server inside the container back through a forwarded port|(ships with macOS)|curl|curl
cmd|git|the fixture copies of the course tree are built with git archive, the way GitHub builds them|(ships with Xcode CLT)|git|git
cmd|ssh|the shim, container and live tiers all drive a launcher that refuses to start without it|(ships with macOS)|openssh-client|openssh-clients
cmd|ssh-keygen|named separately by that same refusal, and the tunnel keypair is generated with it|(ships with macOS)|openssh-client|openssh-clients
gnu|timeout|every pty drive and every long podman call is bounded by it|coreutils|coreutils|coreutils
gnu|stat|the file mode and ownership assertions read `stat -c`|coreutils|coreutils|coreutils
gnu|sha256sum|the release gates and the installer idempotency check hash with it|coreutils|coreutils|coreutils
any|listeners|answers which host ports the tunnel is really carrying|(lsof ships with macOS)|iproute2|iproute
run|python3|lib/ptyrun.py drives every pty, and the box-art checks parse with it|(ships with macOS)|python3|python3'

# ─── which of the three columns this machine reads (#195) ─────────────────────
#
# PARSED, NOT SOURCED, and that is a deliberate refusal to use the obvious one-liner -- the same
# refusal install-cs193v.sh:436-439 states, and for the same reason: `. /etc/os-release` would let
# that file set ANY variable in the process that read it, and it is shell syntax by specification,
# which is exactly what makes sourcing it the wrong tool.
#
# THE PATH IS AN ARGUMENT, and PT_OS_RELEASE is the same seam one level up. `$PATH` can fake a
# command; it cannot fake a file (25-installer.sh:348-352), so a family arm reached only through
# the real /etc/os-release is an arm no Mac can ever test -- and this suite is developed on Macs.
# The variable has vt_selinux's shape: consulted only when nothing has set it, so the product
# reads /etc/os-release and 14-test-harness.sh's gate fixture reads the arm under test.
pt_os_release_field() {               # pt_os_release_field NAME [PATH] -> its value, unquoted
    sed -n "s/^$1=//p" "${2:-${PT_OS_RELEASE:-/etc/os-release}}" 2>/dev/null \
        | head -1 | tr -d '"' | tr -d "'"
}

# ID FIRST, THEN EACH WORD OF ID_LIKE, which is what makes the derivatives free: Linux Mint says
# ID_LIKE=ubuntu, Pop!_OS says "ubuntu debian", Nobara and Bazzite say fedora, Rocky and AlmaLinux
# say "rhel centos fedora". None of them needs naming here.
#
# NO `unsupported` ANSWER, WHICH IS WHERE THIS AND install-cs193v.sh's distro_family() PART
# COMPANY ON PURPOSE. The installer refuses an unsupported distro by name, because it is about to
# change that machine; this is a developer's dependency gate, so it hands over the closest thing
# it knows rather than refusing to say anything. Arch, NixOS, openSUSE and Alpine are not
# supported by this project at all, so anyone reading a Debian package name on one is already
# outside it and translating anyway. An arm of their own would be a column nobody can fill in.
#
# ANSWERS ABOUT LINUX ONLY. macOS is decided by `uname -s` in run-tests.sh, exactly where
# install-cs193v.sh:527-539 keeps the same fork -- platform() first, and the family only on the
# Linux arm. Reading `uname` here as well would make every unit assertion about this function
# answer `mac` on a Mac and `fedora` on Fedora, which is a test that measures the developer.
pt_distro_family() {                  # pt_distro_family [PATH] -> debian | fedora
    local id like w
    id="$(pt_os_release_field ID "${1:-}")"
    like="$(pt_os_release_field ID_LIKE "${1:-}")"
    # shellcheck disable=SC2086   # deliberately word-split: ID_LIKE is a space-separated list
    for w in $id $like; do
        case "$w" in
            fedora|rhel|centos) printf 'fedora'; return 0 ;;
        esac
    done
    printf 'debian'
}

# pt_missing -> prints one `NAME|WHY|MACOS_PKG|DEBIAN_PKG|FEDORA_PKG` line per unsatisfied row;
# rc 1 if any.
#
# COLLECTS EVERYTHING rather than stopping at the first fault. A fresh Mac is missing several
# things at once, and a gate that makes you fix them one run at a time is worse than the disease.
#
# HEREDOC-FED, NOT PIPED. bash 3.2 has no `lastpipe`, so a `while` loop on the right of a pipe
# runs in a subshell and anything it accumulates is lost on return -- the same trap
# run-tests.sh:163 documents for CRASHES.
pt_missing() {
    local kind name why mac deb fed bad='' ok
    while IFS='|' read -r kind name why mac deb fed; do
        [ -n "${kind:-}" ] || continue
        ok=yes
        case "$kind" in
            cmd) command -v "$name" >/dev/null 2>&1 || ok=no ;;
            gnu) case "$name" in
                     timeout)   [ -n "$DO_TIMEOUT" ] || ok=no ;;
                     stat)      [ -n "$DO_STAT" ]    || ok=no ;;
                     sha256sum) [ -n "$DO_SHA256" ]  || ok=no ;;
                 esac ;;
            any) case "$name" in
                     listeners) [ -n "$DO_SS" ] || [ -n "$DO_LSOF" ] || ok=no ;;
                 esac ;;
            run) if [ -z "$DO_PY" ]; then ok=no
                 # A POISONED interpreter is the case require_python3 was built for: one that
                 # exists, exits 0, and answers something other than what it was asked. Every
                 # box-art and pty-replay check reads the empty string as its happy answer, so
                 # carrying on would pass them all without measuring anything.
                 elif [ "$("$DO_PY" -c 'print(1)' 2>/dev/null)" != 1 ]; then ok=no
                 fi ;;
        esac
        [ "$ok" = yes ] || bad="$bad$name|$why|$mac|$deb|$fed
"
    done <<PT_REG_EOF
$PT_REGISTRY
PT_REG_EOF
    [ -n "$bad" ] || return 0
    printf '%s' "$bad"
    return 1
}

# pt_bash_too_old -> rc 0 if this bash is older than 3.2. A FLOOR AND NEVER A CEILING: demanding
# bash 4 or 5 would invert the reason 10-static.sh:78-96 exists, since bash 3.2 is what students
# have and what a macOS run is here to prove compatibility against. Forkless.
pt_bash_too_old() {
    [ "${BASH_VERSINFO[0]}" -gt 3 ] && return 1
    [ "${BASH_VERSINFO[0]}" -eq 3 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ] && return 1
    return 0
}
