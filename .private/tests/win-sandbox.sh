#!/usr/bin/env bash
#
# Drop into a throwaway machine where install-cs193v-windows.cmd RUNS -- under wine's cmd.exe,
# against fakes for wsl.exe and friends. For driving stage one BY HAND: watching what a Windows
# student sees, changing one answer at a time, and reading what the .cmd actually called.
#
# NOT A TEST. It asserts nothing and reports no results. Its whole job is to put you in front of
# the installer with a chosen machine shape and get out of the way. 27-installer-windows.sh is
# the tier that asserts.
#
# It reuses that tier's fixture image rather than inventing a second one, so the machine you poke
# at by hand is the machine the suite asserts against, and they cannot drift.
#
# WHY THIS IS WORTH HAVING. The suite can tell you a message appears. It cannot tell you the
# message READS well, that the three questions Ubuntu asks are described accurately, or that
# "type exit to carry on" lands where a student is looking. Those need a person, and until now
# there was nowhere to be one -- MANUAL.md's Windows items all required a Windows machine.
#
# EVERYTHING WORKS BY DEFAULT, and the knobs BREAK things. With no flags you get the end-to-end
# success case, so asking for a failure is something you do on purpose rather than something a
# machine name does to you -- the same principle as install-sandbox.sh's two axes.
#
# NOTHING IT DOES REACHES THIS COMPUTER: --network=none, no writable mount, no podman socket.
# WSL is faked entirely, so this reaches every DECISION the .cmd takes and no EFFECT.
#
# MUST STAY BASH 3.2 COMPATIBLE -- see lib/assert.sh for why.

set -u

DIR0="$(cd -- "$(dirname -- "$0")" && pwd -P)"
CS193V_STANDALONE=1; export CS193V_STANDALONE
# shellcheck source=/dev/null
. "$DIR0/lib/assert.sh"
# shellcheck source=/dev/null
. "$DIR0/lib/sandbox.sh"
# shellcheck source=/dev/null
. "$DIR0/lib/wine.sh"

# assert.sh installs a standalone EXIT trap that prints a pass/fail summary. This tool asserts
# nothing, so that line is noise -- and on the paths that exit early it is the ONLY thing that
# prints, which reads like a test run that did nothing.
trap - EXIT

WINE_MSG_VERSION=2.9.8

usage() {
    cat <<EOF
Usage: tests/win-sandbox.sh [OPTIONS] [-- COMMAND]

  Puts you on a throwaway machine where install-cs193v-windows.cmd runs under wine, with
  wsl.exe / net.exe / where.exe / powershell.exe / reg.exe faked. Type \`wincmd\` once you
  are in for what you can do there.

  With NO OPTIONS everything works and the installer runs to "Done." The options below
  break one thing each.

WHAT THE MACHINE IS LIKE
  --dir NAME           the folder the student downloaded into (default Downloads).
                       The interesting ones are the ones batch chokes on:
                       'cs193v (1)' is what a browser names a second copy, and it used
                       to kill the block outright with "Syntax error: unexpected ("
  --no-curl            curl is not in the distro, so watch stage one install it
  --not-admin          the elevation probe says no
  --no-wsl             no wsl.exe on PATH: the install-WSL-and-reboot arm
  --wsl-broken [RC]    wsl.exe is there but --status fails (default -1, which is what it
                       really returns -- and what \`if errorlevel 1\` could not see)
  --no-distro          nothing registered yet, so it creates the environment
  --old-wsl            WSL older than 2.5.8: no --name, so creation fails

  A MACHINE THAT CANNOT START A VIRTUAL MACHINE -- issues #112 and #114. There is no pre-flight
  any more; two were tried and removed, and .private/README.md has why. The failure is diagnosed
  where it happens, out of what wsl.exe itself said, so what these flags arrange is a real
  failure rather than a probe's answer. Use --rev to watch the old wrong messages.
  --no-vm              every call needing the utility VM fails, and \`wsl --status\` says
                       virtualisation is why -- firmware off, the Virtual Machine Platform off,
                       hypervisorlaunchtype Off and a nested guest all look like this. Add
                       --no-distro for the first-install site; leave the environment in place
                       for the second one, where #112's fix never reached
  --no-vm-quiet        the same machine with \`wsl --status\` saying nothing useful, which is what
                       firmware-disabled looks like. The diagnosis MISSES, deliberately, and the
                       refusal has to fall back to naming no cause rather than guessing one
  --createvm-fails     the probes all say the machine is fine and \`wsl --install -d\` still
                       fails at CreateVm, which is a real box (WSL#12894). Watch that the
                       refusal does not pretend to know why
  --reboot-required    \`wsl --install -d\` enables a component, prints the reboot notice,
                       installs NOTHING and exits ZERO. The shape that made "it exited 0"
                       and "the environment is there" look like the same claim
  --shell-rc N         the exit code of the shell \`wsl --install\` LAUNCHES. Not the
                       install's own, which is the point: N=1 must NOT read as a failure
  --apt-fails [RC]     \`apt-get install\` fails (default -1) while installing curl
  --apt-lies           apt exits 0 and curl is still absent, which only the re-probe catches
  --download-fails [RC] the download fails (default 22, an HTTP error under curl -f)
  --truncated          the download exits 0 but serves a cut-short body, the way a wifi
                       sign-in page does. The sentinel check is what has to refuse it
  --probe-fails [RC]   the distro probe cannot run (default 9009, powershell missing).
                       "cannot tell" is not "absent" and must not become "create it"
  --stage2-rc N        what install-cs193v.sh exits with
  --update-fails [RC]  \`wsl --update\` fails
  --feature-fails [RC] \`wsl --install --no-distribution\` fails

WHICH COPY OF THE INSTALLER
  --rev REV            take the .cmd from a git revision instead of the working tree.
                       This is how you watch the defects for yourself:
                         --rev dd01f28^   the version before any of this was fixed

OPTIONS
  --keep               leave the container behind on exit
  --list               print the knob vocabulary and exit
  -h, --help           this

  Anything after -- is run instead of an interactive shell.

EXAMPLES
  tests/win-sandbox.sh                              # the success case, end to end
  tests/win-sandbox.sh --no-distro                  # watch it create the environment
  tests/win-sandbox.sh --dir 'cs193v (1)'           # the folder name that used to break it
  tests/win-sandbox.sh --old-wsl --no-distro        # the --name refusal
  tests/win-sandbox.sh --probe-fails                # "cannot tell" vs "absent"
  tests/win-sandbox.sh --no-vm --no-distro          # issues #112 and #114, at the create
  tests/win-sandbox.sh --no-vm                      # ...and at the second site, where the environment exists
  tests/win-sandbox.sh --no-vm-quiet                # nothing to read: it must not guess a cause
  tests/win-sandbox.sh --rev accfb1b --createvm-fails   # the wrong message, as it shipped
  tests/win-sandbox.sh --no-curl                    # watch it install curl first
  tests/win-sandbox.sh --truncated                  # a wifi sign-in page instead of the script
  tests/win-sandbox.sh --download-fails 6           # no such host
  tests/win-sandbox.sh --rev dd01f28^ --wsl-broken  # see the old errorlevel bug bite
  tests/win-sandbox.sh -- wincmd run                # non-interactive, just the transcript
EOF
}

DLNAME=Downloads
REV=''
KEEP=no
CMD=''
KNOBS=''                              # accumulated "name=value" pairs, applied below
DISTROS='CS193V'

die_usage() { printf '%s\n\n' "$1" >&2; usage >&2; exit 2; }
setk() { KNOBS="$KNOBS $1=$2"; }

# `--flag [VALUE]` where the value is optional: consume the next argument only if it is not
# another flag.
#
# SETS GLOBALS rather than printing, and that is not a style choice: the printing version had to
# be called in a command substitution, which runs it in a SUBSHELL, so the "did I consume an
# argument" flag never made it back to the caller and every one of these flags died on
# `SHIFTED: unbound variable`. Found by running the tool, which is what it is for.
# A flag whose value is REQUIRED must say so when it is missing. Without this, `--dir --` ate
# the `--`, set the folder name to "--", and then blamed the command after it: three steps from
# the actual mistake.
needval() {                           # needval FLAG VALUE
    # A NEGATIVE NUMBER IS A VALUE, not a flag. -1 is the whole point here: it is what wsl.exe
    # really returns, and the code `if errorlevel 1` could not see. Rejecting it would make the
    # most interesting exit code the one you cannot ask for.
    case "${2:-}" in
        -[0-9]*) return 0 ;;
        ''|-*)   die_usage "$1 needs a value" ;;
    esac
}

OPTVAL=''; OPTSHIFT=0
optval() {                            # optval DEFAULT NEXT -> sets OPTVAL, OPTSHIFT
    OPTVAL="$1"; OPTSHIFT=0
    case "${2:-}" in
        -[0-9]*) OPTVAL="$2"; OPTSHIFT=1 ;;   # see needval: -1 is a value
        ''|-*)   ;;
        *)       OPTVAL="$2"; OPTSHIFT=1 ;;
    esac
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dir)            needval --dir "${2:-}"; shift; DLNAME="$1" ;;
        --dir=*)          DLNAME="${1#--dir=}" ;;
        --no-curl)        setk wsl.curl.missing 1 ;;
        --apt-fails)      setk wsl.curl.missing 1
                          optval -1 "${2:-}"; [ "$OPTSHIFT" = 1 ] && shift
                          setk wsl.apt.install.rc "$OPTVAL" ;;
        --apt-lies)       setk wsl.curl.missing 1; setk wsl.apt.nomarker 1 ;;
        --download-fails) optval 22 "${2:-}"; [ "$OPTSHIFT" = 1 ] && shift
                          setk wsl.curl.rc "$OPTVAL" ;;
        --truncated)      setk wsl.curl.truncated 1 ;;
        --not-admin)      setk reg.query.rc 1 ;;
        --no-wsl)         setk where.wsl.exe 0; DISTROS='' ;;
        --wsl-broken)     optval -1 "${2:-}"; [ "$OPTSHIFT" = 1 ] && shift
                          setk wsl.status.rc "$OPTVAL"
                          setk wsl.status.msg MessageWslOptionalComponentRequired ;;
        --no-distro)      DISTROS='' ;;
        # ONE FLAG, because the installer no longer branches on which cause it was. The
        # wsl.status.novirt knob rides along because a machine in this state really does print
        # that line on stdout and still exit 0, which is the trap #112 fell into.
        --no-vm)          setk wsl.vm.cannotstart 1; setk wsl.install.novirt 1; setk wsl.status.novirt 1 ;;
        --no-vm-quiet)    setk wsl.vm.cannotstart 1; setk wsl.install.novirt 1 ;;
        --createvm-fails) setk wsl.install.novirt 1; DISTROS='' ;;
        --reboot-required) setk wsl.install.rebootrequired 1; DISTROS='' ;;
        --old-wsl)        setk wsl.name.unsupported 1; DISTROS='' ;;
        --shell-rc)       needval --shell-rc "${2:-}"; shift; setk wsl.install.rc "$1" ;;
        --shell-rc=*)     setk wsl.install.rc "${1#--shell-rc=}" ;;
        --probe-fails)  optval 9009 "${2:-}"; [ "$OPTSHIFT" = 1 ] && shift
                          setk ps.rc "$OPTVAL" ;;
        --stage2-rc)      needval --stage2-rc "${2:-}"; shift; setk wsl.bash.rc "$1" ;;
        --stage2-rc=*)    setk wsl.bash.rc "${1#--stage2-rc=}" ;;
        --update-fails)  optval -1 "${2:-}"; [ "$OPTSHIFT" = 1 ] && shift
                          setk wsl.update.rc "$OPTVAL" ;;
        --feature-fails)  optval -1 "${2:-}"; [ "$OPTSHIFT" = 1 ] && shift
                          setk wsl.feature.rc "$OPTVAL" ;;
        --rev)            needval --rev "${2:-}"; shift; REV="$1" ;;
        --rev=*)          REV="${1#--rev=}" ;;
        --keep)           KEEP=yes ;;
        --list)           sed -n '/^  reg.query.rc/,/^  wsl.list/p' "$DIR0/lib/wine-guest.sh"; exit 0 ;;
        -h|--help)        usage; exit 0 ;;
        --)               shift; CMD="$*"; break ;;
        *)                die_usage "unknown option: $1" ;;
    esac
    shift
done

# STRICT, and refused rather than warned about, for the reason install-sandbox.sh records: a
# silently-ignored value would have you conclude the installer took a branch it never took.
case "$DLNAME" in
    ''|*/*) die_usage "--dir must be a single folder name, not a path: $DLNAME" ;;
esac

require_podman || { printf 'podman is required.\n' >&2; exit 1; }

WINE_TMP="$(new_tmpdir)"
SB_TMP="$WINE_TMP"                    # fixture_build logs its build output here
trap 'rm -rf "$WINE_TMP"; rm -f "${CS193V_RESULTS:-}"' EXIT

printf 'Building the wine machine (cached unless its recipe moved; ~3.45 GB the first time)...\n'
fixture_build wine >/dev/null || { printf 'could not build the wine machine\n' >&2; exit 1; }

# The case tree, built the same way lib/wine.sh builds one, so what you drive by hand and what
# the suite asserts against have the same shape.
CASE="$WINE_TMP/case"
DL="$CASE/$DLNAME"
mkdir -p "$DL"
if [ -n "$REV" ]; then
    git -C "$REPO" show "$REV:.private/install-cs193v-windows.cmd" > "$DL/install-cs193v-windows.cmd" \
        || die_usage "could not read the .cmd at revision: $REV"
else
    cp "$PRIVATE/install-cs193v-windows.cmd" "$DL/"
fi
cp "$FIXTURE_DIR/wsl-messages.$WINE_MSG_VERSION" "$CASE/messages"
# What the fake's curl arm serves: the real install-cs193v.sh, exactly as lib/wine.sh does it.
cp "$PRIVATE/install-cs193v.sh" "$CASE/stage2.src"
: > "$CASE/wsl.list"
for d in $DISTROS; do printf '%s\n' "$d" >> "$CASE/wsl.list"; done
for kv in $KNOBS; do printf '%s\n' "${kv#*=}" > "$CASE/${kv%%=*}"; done
# The fixture runs as a non-root user, so a 0700 mktemp directory is unreadable inside: rootless
# podman maps container-root to you, but not container-uid-1000.
chmod -R a+rX "$CASE"

# cs193v.sandbox, NOT cs193v.test: the live tier's cleanup:no-stray-containers filters on
# label=cs193v.test=$NAME, so a --keep container carrying that label would redden somebody's
# test run with nothing wrong in their change.
NAME_SB="cs193v-winsandbox-$$"
set -- --label "cs193v.sandbox=${USER:-unknown}" -i --name "$NAME_SB" --network=none
[ -t 0 ] && set -- "$@" -t
[ "$KEEP" = no ] && set -- "$@" --rm
set -- "$@" -e XDG_RUNTIME_DIR=/tmp/xdg -e "SB_DL=$DLNAME"
set -- "$@" -v "$CASE:/work:ro"
set -- "$@" -v "$DIR0/lib/wine-guest.sh:/usr/local/bin/wincmd:ro"
set -- "$@" "$(fixture_tag wine)"

printf 'Download folder: %s   installer: %s\n' "$DLNAME" \
       "$( [ -n "$REV" ] && printf 'from %s' "$REV" || printf 'working tree' )"
printf 'Registered distros: %s\n' "${DISTROS:-none}"
printf 'Knobs: %s\n' "${KNOBS:- none (everything works)}"
cat <<'BANNER'

  wincmd state      what the installer is about to see -- read this first
  wincmd run        run it under wine cmd.exe
  wincmd log        what it actually called, in order
  wincmd knobs      everything you can change, and why each one matters
  wincmd cmd        an interactive cmd.exe, for poking at batch yourself

BANNER
printf 'Ctrl-D leaves%s.\n\n' \
       "$( [ "$KEEP" = yes ] && printf ' (container kept: %s)' "$NAME_SB" )"

# `wincmd init` FIRST in both paths, so the tree exists and the fakes are in place on your first
# command rather than after it.
if [ -n "$CMD" ]; then
    podman run "$@" bash -lc "wincmd init; $CMD"
else
    podman run "$@" bash -lc 'wincmd init; wincmd state; exec bash -l'
fi
rc=$?

if [ "$KEEP" = yes ]; then
    printf '\nKept: %s\n' "$NAME_SB"
    printf 'Remove it:  podman rm -f %s\n' "$NAME_SB"
fi
exit "$rc"
