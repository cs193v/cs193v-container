#!/usr/bin/env bash
#
# Drop into a throwaway machine that has install-cs193v.sh on it, and nothing else you did
# not ask for. For driving the installer BY HAND -- watching it, interrupting it, reading what
# it changed, and answering the questions the suite deliberately cannot: whether the consent
# menu looks right to a person (tests/MANUAL.md §1.2), and whether the build's progress block
# reads well on a real terminal.
#
# NOT A TEST. It asserts nothing and reports no results. Its whole job is to put you in front
# of the installer on a machine with a chosen shape, and get out of the way.
#
# It reuses the install tier's fixture images rather than inventing a second set, so the
# machine you poke at by hand is the same machine 26-installer-sandbox.sh asserts against, and
# they cannot drift. `--machine` IS the knob set: each fixture is a different starting shape.
#
# NOTHING IT DOES REACHES THIS COMPUTER. No writable mount, no podman socket, and the course
# files arrive as a local tarball. The one exception is deliberate: --machine nested asks for
# the capabilities a nested podman needs, which is the only shape that can really build the
# course image. See fixtures/Containerfile.nested for what that costs and why.
#
# MUST STAY BASH 3.2 COMPATIBLE -- see lib/assert.sh for why.

set -u

DIR0="$(cd -- "$(dirname -- "$0")" && pwd -P)"
CS193V_STANDALONE=1; export CS193V_STANDALONE
# shellcheck source=/dev/null
. "$DIR0/lib/assert.sh"
# shellcheck source=/dev/null
. "$DIR0/lib/podman-shim.sh"
# shellcheck source=/dev/null
. "$DIR0/lib/sandbox.sh"

# assert.sh installs a standalone EXIT trap that prints a pass/fail summary. This tool asserts
# nothing, so that line is noise -- and on the paths that exit early (--list, a rejected flag)
# it is the ONLY thing that prints, which reads like a test run that did nothing. Cleared here
# rather than left to be replaced by the real trap further down, which those paths never reach.
trap - EXIT

MACHINES="subuid wsl podman-old no-podman nested"

usage() {
    cat <<EOF
Usage: tests/install-sandbox.sh [OPTIONS] [-- COMMAND]

  Puts you on a throwaway machine holding install-cs193v.sh and a local copy of the course
  files, and nothing else. Type \`sandbox\` once you are in for what you can do there.

MACHINES  (--machine, default subuid)
  subuid       podman and ssh present; the account has NO subuid range, so the installer
               asks permission for exactly one thing and \`usermod\` really runs
  wsl          looks like WSL (a bind-mounted /proc/version), everything else in place, so
               /etc/wsl.conf is the only thing to change.  Pair with --wslconf
  podman-old   ubuntu:24.04, whose real podman is 4.9.3 against MIN_PODMAN 5.7.0, so the
               installer refuses.  Nothing to accept; it stops in the survey
  no-podman    no podman and no ssh client, with a local apt repository baked in, so
               \`apt-get install\` really runs with the network off
  nested       podman present AND able to build: the only machine where \`--rebuild\` can
               really assemble the course image.  Needs the capabilities in
               fixtures/Containerfile.nested; costs ~6 GB and several minutes

OPTIONS
  --machine NAME       one of the above
  --wslconf STATE      absent | noboot | boot | systemd   (only with --machine wsl)
                       'boot' is the state nothing else reaches: a [boot] section with no
                       systemd=true, which is the only input that takes setup_wslconf's sed
  --dir PATH           set CS193V_DIR, so the installer does not ask where to put things
  --ask                leave CS193V_DIR unset, so choose_dir prompts.  Its typed-path,
                       empty-input and ~/ branches are only reachable this way
  --net                allow outbound network.  Off by default
  --keep               leave the container behind on exit instead of removing it
  --list               print the machines and exit
  -h, --help           this

  Anything after -- is run instead of an interactive shell.

EXAMPLES
  tests/install-sandbox.sh                          # the one-consent-item machine
  tests/install-sandbox.sh --machine wsl --wslconf boot
  tests/install-sandbox.sh --machine nested         # can really build the image
  tests/install-sandbox.sh --ask                    # drive choose_dir's menu yourself
EOF
}

MACHINE=subuid
WSLCONF=''
SBDIR='/home/student/cs193v'
NET=no
KEEP=no
CMD=''

die_usage() { printf '%s\n\n' "$1" >&2; usage >&2; exit 2; }
known() { case " $MACHINES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --machine)  shift; MACHINE="${1:-}"; known "$MACHINE" || die_usage "unknown machine: ${MACHINE:-<empty>}" ;;
        --machine=*) MACHINE="${1#--machine=}"; known "$MACHINE" || die_usage "unknown machine: $MACHINE" ;;
        --wslconf)  shift; WSLCONF="${1:-}" ;;
        --wslconf=*) WSLCONF="${1#--wslconf=}" ;;
        --dir)      shift; SBDIR="${1:-}" ;;
        --dir=*)    SBDIR="${1#--dir=}" ;;
        --ask)      SBDIR='' ;;
        --net)      NET=yes ;;
        --keep)     KEEP=yes ;;
        --list)     printf 'machines: %s\n' "$MACHINES"; exit 0 ;;
        -h|--help)  usage; exit 0 ;;
        --)         shift; CMD="$*"; break ;;
        *)          die_usage "unknown option: $1" ;;
    esac
    shift
done

# STRICT, and refused rather than warned about. CLAUDE.md §2 records what a silently-skipped
# malformed value costs -- a set that quietly shrank and a developer who could not see why.
# Here the cost is worse: you would conclude the installer took a branch it never took.
case "$WSLCONF" in
    ''|absent|noboot|boot|systemd) : ;;
    *) die_usage "unknown --wslconf: $WSLCONF (absent|noboot|boot|systemd)" ;;
esac
if [ -n "$WSLCONF" ] && [ "$MACHINE" != wsl ]; then
    die_usage "--wslconf only means anything with --machine wsl; the state would be arranged and never read"
fi
if [ "$MACHINE" = wsl ] && [ -z "$WSLCONF" ]; then WSLCONF=noboot; fi

SB_TMP="$(new_tmpdir)"
# Read by sandbox_cleanup in lib/sandbox.sh, which shellcheck cannot see from here.
# shellcheck disable=SC2034
SB_CASES="$MACHINE"
trap 'rm -rf "$SB_TMP"; rm -f "${CS193V_RESULTS:-}"' EXIT

printf 'Building the %s machine (cached unless its recipe moved)...\n' "$MACHINE"
sb_work_init
cp "$DIR0/lib/sandbox-guest.sh" "$SB_WORK/sandbox"
chmod +x "$SB_WORK/sandbox"
fixture_build "$MACHINE" >/dev/null || { printf 'could not build the %s machine\n' "$MACHINE" >&2; exit 1; }

# cs193v.sandbox, NOT cs193v.test, and that matters rather than being tidy: the live tier's
# cleanup:no-stray-containers filters on label=cs193v.test=$NAME, so a --keep sandbox carrying
# that label would redden somebody's test run with nothing wrong in their change (#74's shape).
NAME_SB="cs193v-sandbox-$MACHINE-$$"
RM=--rm; [ "$KEEP" = yes ] && RM=''

# -t only when there IS a terminal. Asking podman for a pty with none attached is how a
# `-- COMMAND` run ends up misbehaving, and menu() cares about the answer: with no tty it takes
# the safe default, which for consent means declining.
set -- --label "cs193v.sandbox=${USER:-unknown}" -i --name "$NAME_SB"
[ -t 0 ] && set -- "$@" -t
[ -n "$RM" ] && set -- "$@" "$RM"
[ "$NET" = no ] && set -- "$@" --network=none
set -- "$@" --mount type=tmpfs,destination=/var/tmp/report
set -- "$@" -v "$SB_WORK:/work:ro"
set -- "$@" -v "$SB_WORK/sandbox:/usr/local/bin/sandbox:ro"
[ -n "$SBDIR" ] && set -- "$@" -e "CS193V_DIR=$SBDIR"
[ -n "$WSLCONF" ] && set -- "$@" -e "SB_WSLCONF=$WSLCONF"
if [ "$MACHINE" = wsl ]; then
    set -- "$@" -v "$SB_WORK/proc-version:/proc/version:ro"
fi
# The nested machine's departures, which are its whole point. Documented in its Containerfile.
if [ "$MACHINE" = nested ]; then
    set -- "$@" --cap-add=SYS_ADMIN --security-opt 'unmask=/proc/*' \
                --device /dev/fuse --device /dev/net/tun -e BUILDAH_LAYERS=false
    [ "$NET" = no ] && printf 'note: --machine nested cannot build without --net\n'
fi
# NOT exported: CS193V_INSTANCE. installer:775-777 names the unsuffixed image on purpose, and
# an instance in here would test something no student runs. Isolation is the container.
set -- "$@" "$(fixture_tag "$MACHINE")"

printf 'Machine: %s   dir: %s   net: %s\n' "$MACHINE" "${SBDIR:-<unset, choose_dir will ask>}" "$NET"
printf 'Type `sandbox` inside for what you can do. Ctrl-D leaves%s.\n\n' \
       "$( [ "$KEEP" = yes ] && printf ' (container kept: %s)' "$NAME_SB" )"

if [ -n "$CMD" ]; then
    podman run "$@" sh -lc "$CMD"
else
    podman run "$@" bash -l
fi
rc=$?

if [ "$KEEP" = yes ]; then
    printf '\nKept: %s\n' "$NAME_SB"
    printf 'What it changed:  podman diff %s\n' "$NAME_SB"
    printf 'Remove it:        podman rm -f %s\n' "$NAME_SB"
fi
exit "$rc"
