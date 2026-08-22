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
# It reuses the install tier's fixture image rather than inventing a second one, so the machine
# you poke at by hand is the same machine 26-installer-sandbox.sh asserts against, and they
# cannot drift.
#
# EVERYTHING IS PRESENT BY DEFAULT, and the knobs SUBTRACT. Two axes, because there are two
# separate questions: --no-prereqs says what software the machine lacks, which decides WHICH
# INSTALL PATH runs; --no-caps says what the container is denied, which decides WHICH ERROR PATH
# runs. So with no flags at all you get the end-to-end success case, and asking for a failure is
# something you do on purpose rather than something a machine name does to you. The previous
# `--machine NAME` bundled both with the platform, which is how one name came to mean both
# "podman is absent" and "podman is installed but cannot run".
#
# NOTHING IT DOES REACHES THIS COMPUTER. No writable mount, no podman socket, and the course
# files arrive as a local tarball. The capabilities the default machine takes are what a nested
# podman needs; see fixtures/Containerfile.machine for what they cost and why.
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


usage() {
    cat <<EOF
Usage: tests/install-sandbox.sh [OPTIONS] [-- COMMAND]

  Puts you on a throwaway machine holding install-cs193v.sh and a local copy of the course
  files, and nothing else. Type \`sandbox\` once you are in for what you can do there.

  With NO OPTIONS you get a machine with everything present and every capability granted --
  the case where the install is expected to run all the way through. The options below take
  things away.

WHAT THE MACHINE IS MISSING
  --no-prereqs LIST    comma-separated, from: $MACHINE_PREREQ_NAMES
      podman   removed for real with apt, so the installer's own \`apt-get install\` runs
               against the machine's baked-in offline repository
      ssh      openssh-client removed; gated independently of podman (installer:486-488)
      subuid   your account's range emptied.  HAND-DRIVEN ONLY, and the reason is worth
               knowing: setup_subuid writes a fixed 200000-265535, which is outside this
               container's own ID window, so podman cannot work afterwards HERE even though
               it would on a student's machine.  Good for watching the step; no suite case
               can claim both halves

WHAT THE CONTAINER IS DENIED
  --no-caps LIST       comma-separated, from: $MACHINE_CAP_NAMES
      sysadmin SYS_ADMIN withheld, so newuidmap cannot write uid_map: podman is installed
               and cannot run.  The installer stops at "Could not ask podman how much memory
               is available", which is a real student failure -- a restrictive apparmor
               profile or a missing uidmap does the same thing on a laptop

OPTIONS
  --platform linux|wsl looks like WSL via a bind-mounted /proc/version (default linux)
  --wslconf STATE      absent | noboot | boot | systemd   (only with --platform wsl)
                       'boot' is the state nothing else reaches: a [boot] section with no
                       systemd=true, which is the only input that takes setup_wslconf's sed
  --sudo STATE         nopasswd (default) | password[:PW] | deny | absent
                       password makes sudo really prompt, which is what a student sees -- the
                       installer says "needs your password" in its consent text and this is
                       the only way to watch that land.  Default password is 'student'.
                       deny: sudo exists, you may not use it.  absent: no sudo at all
  --fake-podman        substitute lib/podman-fake, so nothing real is built.  A TEST
                       CONVENIENCE and neither axis: it is not an absence, not a capability,
                       and not a machine any student could have.  Makes a run take a second
  --base IMAGE         machine (default) | podman-old
                       podman-old is ubuntu:24.04, whose real podman is 4.9.3 against
                       MIN_PODMAN 5.7.0, so the installer refuses in the survey.  A VERSION
                       cannot be produced by subtracting from a 26.04 base, which is why this
                       one machine stays separate
  --dir PATH           set CS193V_DIR, so the installer does not ask where to put things
  --ask                leave CS193V_DIR unset, so choose_dir prompts.  Its typed-path,
                       empty-input and ~/ branches are only reachable this way
  --no-net             cut the container off from the network (--network=none).  ON by default
                       for a REAL podman, because the default machine's whole point is that the
                       install runs all the way through and the launcher's build reaches seven
                       origins -- offline it always stops at STEP 1/25 with a DNS error.  Off
                       by default with --fake-podman or --base podman-old, which build nothing
  --net                explicit form of the default; accepted so a habit does not break
  --keep               leave the container behind on exit instead of removing it
  --list               print the two vocabularies and exit
  -h, --help           this

  Anything after -- is run instead of an interactive shell.

EXAMPLES
  tests/install-sandbox.sh                                  # everything present: the success case
  tests/install-sandbox.sh --no-prereqs=podman              # apt really installs it, then builds
  tests/install-sandbox.sh --no-prereqs=podman,ssh          # two consent items
  tests/install-sandbox.sh --no-caps=sysadmin               # podman installed, cannot run
  tests/install-sandbox.sh --no-prereqs=subuid              # watch usermod by hand
  tests/install-sandbox.sh --platform wsl --wslconf boot --fake-podman
  tests/install-sandbox.sh --base podman-old                # the version refusal
  tests/install-sandbox.sh --ask                            # drive choose_dir's menu yourself
  tests/install-sandbox.sh --sudo password                  # what a student actually sees
EOF
}

BASE=machine
NOCAPS=''
NOPREREQS=''
PLATFORM=linux
FAKE=no
WSLCONF=''
SUDOK=''
SBDIR='/home/student/cs193v'
# EMPTY MEANS "NOT SAID", so the default can depend on the other flags rather than being a
# constant. Resolved below once --fake-podman and --base are known.
NET=''
KEEP=no
CMD=''

die_usage() { printf '%s\n\n' "$1" >&2; usage >&2; exit 2; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-caps)      shift; NOCAPS="${1:-}" ;;
        --no-caps=*)    NOCAPS="${1#--no-caps=}" ;;
        --no-prereqs)   shift; NOPREREQS="${1:-}" ;;
        --no-prereqs=*) NOPREREQS="${1#--no-prereqs=}" ;;
        --platform)     shift; PLATFORM="${1:-}" ;;
        --platform=*)   PLATFORM="${1#--platform=}" ;;
        --fake-podman)  FAKE=yes ;;
        --base)         shift; BASE="${1:-}" ;;
        --base=*)       BASE="${1#--base=}" ;;
        --sudo)         shift; SUDOK="${1:-}" ;;
        --sudo=*)       SUDOK="${1#--sudo=}" ;;
        --wslconf)      shift; WSLCONF="${1:-}" ;;
        --wslconf=*)    WSLCONF="${1#--wslconf=}" ;;
        --dir)          shift; SBDIR="${1:-}" ;;
        --dir=*)        SBDIR="${1#--dir=}" ;;
        --ask)          SBDIR='' ;;
        --net)          NET=yes ;;
        --no-net)       NET=no ;;
        --keep)         KEEP=yes ;;
        --list)         printf 'missing software  (--no-prereqs) : %s\nmissing capabilities (--no-caps) : %s\nbases (--base)                   : machine podman-old\n' \
                               "$MACHINE_PREREQ_NAMES" "$MACHINE_CAP_NAMES"; exit 0 ;;
        -h|--help)      usage; exit 0 ;;
        --)             shift; CMD="$*"; break ;;
        *)              die_usage "unknown option: $1" ;;
    esac
    shift
done

# STRICT, and refused rather than warned about. CLAUDE.md §2 records what a silently-skipped
# malformed value costs -- a set that quietly shrank and a developer who could not see why.
# Here the cost is worse: you would conclude the installer took a branch it never took.
#
# VALIDATED BY THE SUITE'S OWN machine_valid, so the vocabulary cannot differ between the tool
# you drive by hand and the tier that asserts. `--no-prereqs=pod man` has to be a hard failure
# in both, not a machine with podman still on it and a transcript you then misread.
if ! bad="$(machine_valid prereqs "$NOPREREQS")"; then
    die_usage "unknown --no-prereqs entry: $bad   (want: $MACHINE_PREREQ_NAMES)"
fi
if ! bad="$(machine_valid caps "$NOCAPS")"; then
    die_usage "unknown --no-caps entry: $bad   (want: $MACHINE_CAP_NAMES)"
fi
case "$PLATFORM" in
    linux|wsl) : ;;
    *) die_usage "unknown --platform: $PLATFORM (linux|wsl)" ;;
esac
case "$BASE" in
    machine|podman-old) : ;;
    *) die_usage "unknown --base: $BASE (machine|podman-old)" ;;
esac
# Strict, like every other value here. A silently-accepted sudo state would be the worst of
# them: you would watch a run with no prompt and conclude the installer never asks for one.
case "${SUDOK%%:*}" in
    ''|nopasswd|password|deny|absent) : ;;
    *) die_usage "unknown --sudo: $SUDOK (nopasswd|password[:PW]|deny|absent)" ;;
esac
case "$WSLCONF" in
    ''|absent|noboot|boot|systemd) : ;;
    *) die_usage "unknown --wslconf: $WSLCONF (absent|noboot|boot|systemd)" ;;
esac
if [ -n "$WSLCONF" ] && [ "$PLATFORM" != wsl ]; then
    die_usage "--wslconf only means anything with --platform wsl; the state would be arranged and never read"
fi
if [ "$PLATFORM" = wsl ] && [ -z "$WSLCONF" ]; then WSLCONF=noboot; fi

# THE NETWORK DEFAULT FOLLOWS FROM WHETHER ANYTHING REAL WILL BE BUILT, which is the same
# principle as the two axes: the default is the case that SUCCEEDS, and a failure is something
# you ask for. It used to be off always, and that made the default machine -- everything present,
# nothing denied -- guaranteed to fail at its very last step, in the launcher's build, with a DNS
# error from STEP 1/25. The tool printed a note about it before you had a prompt, which is
# minutes and a screenful before you type `sandbox run`; a warning nobody can see when it matters
# is the same as no warning.
if [ -z "$NET" ]; then
    if [ "$FAKE" = yes ] || [ "$BASE" = podman-old ]; then NET=no; else NET=yes; fi
fi
# REFUSED RATHER THAN QUIETLY IGNORED, for the same reason as the rest: podman-old is ubuntu:24.04
# with no local repository and no ID window of its own, so a --no-prereqs there would remove a
# package that cannot be put back and leave you debugging the fixture.
case ",$NOPREREQS," in
    *,podman,*) [ "$FAKE" = yes ] && die_usage "--fake-podman cannot combine with --no-prereqs=podman: the fake is bind-mounted over /usr/bin/podman, so apt cannot remove the file. Pick one" ;;
esac
if [ "$BASE" = podman-old ] && { [ -n "$NOPREREQS" ] || [ "$FAKE" = yes ]; }; then
    die_usage "--base podman-old takes neither --no-prereqs nor --fake-podman: its whole job is one refusal off a REAL podman 4.9.3, before anything is installed"
fi

SB_TMP="$(new_tmpdir)"
# Read by sandbox_cleanup in lib/sandbox.sh, which shellcheck cannot see from here.
# shellcheck disable=SC2034
SB_CASES="$BASE"
trap 'rm -rf "$SB_TMP"; rm -f "${CS193V_RESULTS:-}"' EXIT

printf 'Building the %s machine (cached unless its recipe moved)...\n' "$BASE"
# sb_work_init ships lib/sandbox-guest.sh as $SB_WORK/sandbox, which is what the suite's run.sh
# calls too -- so there is nothing to copy here any more, and no second copy to drift.
sb_work_init
fixture_build "$BASE" >/dev/null || { printf 'could not build the %s machine\n' "$BASE" >&2; exit 1; }

# cs193v.sandbox, NOT cs193v.test, and that matters rather than being tidy: the live tier's
# cleanup:no-stray-containers filters on label=cs193v.test=$NAME, so a --keep sandbox carrying
# that label would redden somebody's test run with nothing wrong in their change (#74's shape).
NAME_SB="cs193v-sandbox-$BASE-$$"
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
set -- "$@" -e "SB_NET=$NET"
[ -n "$SBDIR" ] && set -- "$@" -e "CS193V_DIR=$SBDIR"
[ -n "$WSLCONF" ] && set -- "$@" -e "SB_WSLCONF=$WSLCONF"
[ -n "$SUDOK" ] && set -- "$@" -e "SB_SUDO=$SUDOK"
set -- "$@" -e "SB_NO_PREREQS=$NOPREREQS" -e "SB_NO_CAPS=$NOCAPS"
# THE SAME DECLARATION THE SUITE USES. This file used to carry its own copies of the nested
# machine's capabilities and the wsl bind mount, which is how they came to disagree with the
# suite's -- see machine_flags in lib/sandbox.sh.
if [ "$BASE" = podman-old ]; then
    # No capabilities and no bind mounts: its whole job is one refusal in the survey, which
    # needs no namespace at all. Deliberately bare, so the refusal is measured on a machine
    # with no special privilege.
    :
else
    machine_flags "$NOCAPS" "$PLATFORM" "$FAKE"
    set -- "$@" ${MACHINE_FLAGS[@]+"${MACHINE_FLAGS[@]}"}
    set -- "$@" --mount type=tmpfs,destination=/var/tmp/shim
    set -- "$@" -e BUILDAH_LAYERS=false
    :
fi
# NOT exported: CS193V_INSTANCE. installer:775-777 names the unsuffixed image on purpose, and
# an instance in here would test something no student runs. Isolation is the container.
set -- "$@" "$(fixture_tag "$BASE")"

printf 'Machine: %s   platform: %s   podman: %s\n' "$BASE" "$PLATFORM" \
       "$( [ "$FAKE" = yes ] && printf 'FAKE (lib/podman-fake)' || printf real )"
printf 'Missing: %s   Denied: %s\n' "${NOPREREQS:-nothing}" "${NOCAPS:-nothing}"
printf 'dir: %s   net: %s   sudo: %s\n' \
       "${SBDIR:-<unset, choose_dir will ask>}" "$NET" "${SUDOK:-nopasswd}"
case "${SUDOK%%:*}" in
    password) pw="${SUDOK#password:}"; [ "$pw" = "$SUDOK" ] && pw=student
              printf 'sudo will PROMPT. The password is: %s\n' "$pw" ;;
esac
# SPELLED OUT, because "type sandbox" was not enough: you land in $HOME and the installer is
# bind-mounted at /work, so someone reasonably looks for it in the directory they are in and
# finds nothing. ~/install-cs193v.sh is a symlink to it, named the way a student's copy is.
cat <<'BANNER'

  sandbox state     what the installer is about to see -- read this first
  sandbox run       run it, or: bash ~/install-cs193v.sh
  sandbox diff      what changed since boot
  sandbox knobs     everything else

BANNER
printf 'Ctrl-D leaves%s.\n\n' \
       "$( [ "$KEEP" = yes ] && printf ' (container kept: %s)' "$NAME_SB" )"

# `sandbox init` FIRST, in both paths. It arranges any boot-time state, links the installer
# where a student would have it, and takes the baseline `sandbox diff` compares against -- all
# of which have to happen before you get a prompt, not on your first `sandbox` command.
if [ -n "$CMD" ]; then
    podman run "$@" sh -lc "sandbox init; $CMD"
else
    podman run "$@" bash -lc 'sandbox init; exec bash -l'
fi
rc=$?

if [ "$KEEP" = yes ]; then
    printf '\nKept: %s\n' "$NAME_SB"
    printf 'What it changed:  podman diff %s\n' "$NAME_SB"
    printf 'Remove it:        podman rm -f %s\n' "$NAME_SB"
fi
exit "$rc"
