#!/usr/bin/env bash
#
# Build a course tarball out of your working tree and print its path, so that CS193V_TARBALL has
# something to point at:
#
#     CS193V_TARBALL="$(.private/tests/make-tarball.sh)" bash .private/install-cs193v.sh
#
# NOT A TEST. It asserts nothing and reports no results. It exists because #280 gave the
# installers a supported way to install from a local tarball, and the thing nobody wants to
# re-derive by hand is what that tarball has to look like.
#
# SHAPED THE WAY GitHub's ARCHIVE ENDPOINT SHAPES IT -- one top-level directory, because the
# bootstrap unpacks with --strip-components=1. A flat archive extracts over the temp directory
# instead of under it, and the run then fails as "the course files arrived but
# .private/course-install.sh is missing", which reads like a truncated download.
#
# AND HOLDING WHAT THAT ENDPOINT HOLDS, by construction rather than by maintenance: export_tree
# IS `git archive`, so export-ignore decides what ships and this cannot drift from what a student
# downloads. 25-installer.sh builds its fixture with these same three lines.
#
# IT STAGES TRACKED EDITS, AND ONLY TRACKED EDITS. export_tree is `git add -u` against a throwaway
# index, so your uncommitted changes to files git already knows about are in -- and a file you
# have CREATED but not `git add`ed is NOT, silently. That is the one surprise this tool has; if a
# new file is missing from the install you are testing, `git add` it and run this again.
#
# THE DIRECTORY IS YOURS TO DELETE. It is left behind on purpose -- the path is the whole output,
# so it has to outlive this process -- and nothing sweeps it. It deliberately carries no pid in
# its name: sweep_stale_tmpdirs removes by "is that pid still alive", and no pid owns this.
#
# MUST STAY BASH 3.2 COMPATIBLE -- see lib/assert.sh for why.

set -u

DIR0="$(cd -- "$(dirname -- "$0")" && pwd -P)"

# ONE FUNCTION, NOT A HARNESS (#232). This used to source lib/assert.sh with CS193V_STANDALONE=1
# for the one function it wants, and then `trap - EXIT` to undo the pass/fail summary that bought
# -- a summary which would have landed on stdout, beside the one path this prints. export_tree
# lives in a module of its own now, so both lines are deleted rather than explained.
# shellcheck source=../lib/export-tree.sh
. "$DIR0/../lib/export-tree.sh" || {
    printf 'make-tarball.sh: cannot read %s\n' "$DIR0/../lib/export-tree.sh" >&2; exit 1; }

case "${1:-}" in
    -h|--help)
        sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
    '') ;;
    *)  printf 'make-tarball.sh: unexpected argument: %s\n' "$1" >&2; exit 2 ;;
esac

# EVERY DIAGNOSTIC GOES TO STDERR, because stdout is the path and a caller is reading it through
# a command substitution. A progress line on stdout would be substituted into CS193V_TARBALL.
out="$(mktemp -d "${TMPDIR:-/tmp}/cs193v-devtar.XXXXXX")" || {
    printf 'make-tarball.sh: could not create a temporary directory\n' >&2; exit 1; }

export_tree "$out/pkg/cs193v-main" || {
    printf 'make-tarball.sh: git archive of the working tree failed\n' >&2; exit 1; }
( cd "$out/pkg" && tar czf "$out/course.tar.gz" cs193v-main ) || {
    printf 'make-tarball.sh: could not build the tarball\n' >&2; exit 1; }
rm -rf "$out/pkg"

# THE CHECK THE BOOTSTRAP WOULD MAKE, MADE HERE. It refuses by name if a member is missing, and
# that refusal reads like a truncated download -- so an archive that could never have worked is
# worth catching where the reason is still visible. The list is the bootstrap's own.
for f in .private/course-install.sh .private/install-utils.sh \
         .private/course-install-messages.txt .private/files/cs193v-ui.sh; do
    tar tzf "$out/course.tar.gz" "cs193v-main/$f" >/dev/null 2>&1 || {
        printf 'make-tarball.sh: %s is not in the archive -- is it export-ignored?\n' "$f" >&2
        exit 1; }
done

printf '%s\n' "$out/course.tar.gz"
