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
# BACKGROUNDED CALLERS DO NOT USE THIS. Five sites read $! to kill the session and must have the
# pty owner's pid, so they invoke "$DO_PY" "$PT_LIB/ptyrun.py" directly with no timeout layer --
# see §2 of the plan and 60-container.sh:250.
do_script() {                         # do_script SECS CMD
    [ -n "$DO_PY" ] || _pt_fatal python3 'no python3 on PATH; lib/ptyrun.py needs it'
    [ -n "$DO_TIMEOUT" ] || _pt_fatal timeout 'no GNU timeout(1) (brew install coreutils)'
    "$DO_TIMEOUT" "$1" "$DO_PY" "$PT_LIB/ptyrun.py" "$2"
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
# KIND|NAME|WHY|MACOS_PKG|DEBIAN_PKG
#
#   cmd   present on PATH at all
#   gnu   a resolver above found a usable one (presence is NOT enough: `command -v stat` succeeds
#         on a Mac and then answers `illegal option -- c`)
#   any   one of several will do
#   run   present AND able to run a program
#
# NOT IN HERE, deliberately:
#   script(1)  nothing uses it any more -- lib/ptyrun.py replaced it, because BSD script cannot
#              deliver keystrokes and there is no GNU one to install on macOS.
#   tmux       65-tmux.sh:17-22 records the decision that the harness runs INSIDE the container,
#              so a host-side tmux would be a dependency nothing uses.
#   awk, sed, tr, mktemp, pgrep, grep
#              present and adequate on every platform this runs on; a row that cannot fail is
#              noise in a report whose whole value is that every line in it is actionable.
PT_REGISTRY='cmd|shellcheck|10-static.sh lints every shipped script with it|shellcheck|shellcheck
cmd|podman|the install, image, container and live tiers drive it|podman|podman passt uidmap crun
cmd|curl|reads a server inside the container back through a forwarded port|(ships with macOS)|curl
gnu|timeout|every pty drive and every long podman call is bounded by it|coreutils|coreutils
gnu|stat|the file mode and ownership assertions read `stat -c`|coreutils|coreutils
gnu|sha256sum|the release gates and the installer idempotency check hash with it|coreutils|coreutils
any|listeners|answers which host ports the tunnel is really carrying|(lsof ships with macOS)|iproute2
run|python3|lib/ptyrun.py drives every pty, and the box-art checks parse with it|(ships with macOS)|python3'

# pt_missing -> prints one `NAME|WHY|MACOS_PKG|DEBIAN_PKG` line per unsatisfied row; rc 1 if any.
#
# COLLECTS EVERYTHING rather than stopping at the first fault. A fresh Mac is missing several
# things at once, and a gate that makes you fix them one run at a time is worse than the disease.
#
# HEREDOC-FED, NOT PIPED. bash 3.2 has no `lastpipe`, so a `while` loop on the right of a pipe
# runs in a subshell and anything it accumulates is lost on return -- the same trap
# run-tests.sh:163 documents for CRASHES.
pt_missing() {
    local kind name why mac deb bad='' ok
    while IFS='|' read -r kind name why mac deb; do
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
        [ "$ok" = yes ] || bad="$bad$name|$why|$mac|$deb
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
