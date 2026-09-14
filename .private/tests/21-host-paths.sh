#!/usr/bin/env bash
# TIER: unit
#
# gui_projects_path(), one platform at a time. No podman, no container, no terminal.
#
# WHY THIS EXISTS AS ITS OWN SUITE, and why it is not folded into 13-term-class.sh. The reasoning
# there applies word for word -- a host fact the launcher resolves once and forwards, after which
# everything downstream is a lookup -- but that suite drives `cs193v --dev-term-class`, and this
# function is SOURCED out of files/cs193v-ui.sh instead. Same shape as 12-run-timeout.sh: the
# function has two consumers (the launcher's build_run_args and verb_doctor) and every property
# below is about the function rather than about either caller.
#
# WHAT IT DECIDES. Which string a student is handed for the folder that holds their own work.
# The container cannot work it out -- nothing in there knows the host path, or the platform, or
# the WSL distro name -- so the launcher renders it and forwards the finished string. Getting it
# wrong does not fail anything: it puts a path that does not exist on a student's screen, which
# is the whole of issue #257.
#
# THE ARGUMENTS ARE ARGUMENTS, not the environment, and that is what makes this suite cheap: all
# three platforms are reachable in one process with no `uname` stub and no podman. The launcher
# is what reads platform() and $WSL_DISTRO_NAME; this function only does string arithmetic.

set -u
. "$(dirname -- "$0")/lib/assert.sh"

cd "$REPO" || exit 1

# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=.private/files/cs193v-ui.sh
. "$PRIVATE/files/cs193v-ui.sh"

# ─── the two platforms whose GUI path is the path ─────────────────────────────
# A Mac's Finder and a Linux file manager both open the POSIX path, so there is nothing to
# render and the function must not invent anything.
assert_eq "gui:macos-is-the-path-unchanged" "/Users/alice/cs193v/projects" \
          "$(gui_projects_path macos /Users/alice/cs193v/projects '')"
assert_eq "gui:linux-is-the-path-unchanged" "/home/alice/cs193v/projects" \
          "$(gui_projects_path linux /home/alice/cs193v/projects '')"
# platform() can answer `other`, and an unknown platform must degrade to the path rather than to
# a guess or to nothing.
assert_eq "gui:an-unknown-platform-is-the-path-unchanged" "/opt/cs193v/projects" \
          "$(gui_projects_path other /opt/cs193v/projects '')"
assert_eq "gui:an-empty-platform-is-the-path-unchanged" "/opt/cs193v/projects" \
          "$(gui_projects_path '' /opt/cs193v/projects '')"

# ─── WSL, where the path a student can open is not the path the launcher is standing in ───────
# The launcher runs INSIDE the distro, so $WORKSPACE is a Linux path File Explorer cannot open.
# The form Explorer needs is the UNC one, which is what the installer already hands a student at
# the end of a Windows install -- see win_projects_path in course-install.sh. Same spelling, on
# purpose: a student who read the install sign-off and then runs doctor must see one answer.
assert_eq "gui:wsl-becomes-a-unc-path" \
          '\\wsl.localhost\CS193V\home\student\cs193v\projects' \
          "$(gui_projects_path wsl /home/student/cs193v/projects CS193V)"
# THE DISTRO IS THE ONE IT IS GIVEN. The launcher reads $WSL_DISTRO_NAME rather than assuming the
# installer's constant, because a student who installed by hand into a distro they already had is
# not in one called CS193V -- and a UNC path naming the wrong distro either does not resolve or
# points into somebody else's tree.
assert_eq "gui:wsl-uses-the-distro-it-is-given" \
          '\\wsl.localhost\Ubuntu-24.04\home\alice\cs193v\projects' \
          "$(gui_projects_path wsl /home/alice/cs193v/projects Ubuntu-24.04)"
# NO DISTRO IS NOT A GUESS. If the name is missing the function must fall back to the POSIX path:
# wrong-but-plausible is worse than plainly unhelpful, because only one of the two is obviously
# not an Explorer path when a student reads it.
assert_eq "gui:wsl-with-no-distro-falls-back-to-the-posix-path" \
          "/home/student/cs193v/projects" \
          "$(gui_projects_path wsl /home/student/cs193v/projects '')"
# A course folder is allowed spaces -- choose_dir validates nothing and cs193v's own comments say
# so -- and a space is legal in a Windows path, so it must survive rather than split the string.
assert_eq "gui:wsl-keeps-spaces-in-the-path" \
          '\\wsl.localhost\CS193V\home\a b\My Course\projects' \
          "$(gui_projects_path wsl '/home/a b/My Course/projects' CS193V)"
# ─── the three checks that would otherwise pass on nothing ────────────────────
# RENDERED ONCE AND GUARDED FIRST, because the two negatives below are satisfied by the empty
# string: with no function at all `grep -c` answers 0 and both would report PASS. Measured --
# they did, on the red run that preceded this helper existing. So the non-empty assertion is the
# vacuity guard for everything after it, in the shape 60-container.sh uses for its pty probe.
gui_unc="$(gui_projects_path wsl /home/student/cs193v/projects CS193V)"
assert_ne "gui:the-unc-render-produced-something" "" "$gui_unc"
# EVERY SEPARATOR IS CONVERTED, not just the leading one: a half-translated path is the failure
# that looks closest to working.
assert_eq "gui:no-forward-slash-survives-the-unc-form" "0" \
          "$(printf '%s' "$gui_unc" | grep -c '/' || true)"
# wsl.localhost AND NOT wsl$, which is a live distinction for a different reason than
# compatibility: both resolve on current Windows and neither is deprecated, but a bare `$` in a
# string an agent may echo through a shell expands to nothing and silently mangles the path. The
# repo standardised on wsl.localhost (27-installer-windows.sh pins it in the installer); this
# keeps the launcher agreeing with it.
assert_eq "gui:the-unc-prefix-names-wsl-localhost" "1" \
          "$(printf '%s' "$gui_unc" | grep -cF '\\wsl.localhost\' || true)"
assert_eq "gui:the-unc-prefix-does-not-name-wsl-dollar" "0" \
          "$(printf '%s' "$gui_unc" | grep -cF 'wsl$' || true)"
