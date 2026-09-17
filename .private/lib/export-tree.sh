# shellcheck shell=bash
#
# What a student actually unpacks, materialised -- `git archive` of the working tree, honouring
# .gitattributes' export-ignore. Sourced by .private/tests/lib/assert.sh, by
# .private/tests/make-tarball.sh and by .private/release.sh.
#
# WHY IT IS OUT HERE AND NOT UNDER tests/lib/. It used to live in assert.sh, and the two callers
# that are not test suites paid for that: make-tarball.sh set CS193V_STANDALONE=1 and then ran
# `trap - EXIT` to undo the pass/fail summary it had bought by accident, with its own comment
# apologising for the line. release.sh would have needed the same apology. A function three
# things need, only one of which is a test, is not the harness's to own.
#
# IT DEPENDS ON NOTHING. mktemp, git, tar, find, sed, sort and bash's `local` -- no do_* shims
# from lib/portable.sh, no assertion helpers, no globals from a caller. That is what makes it
# sourceable by a release script that must not drag a test harness in behind it.
#
# THE REPO ROOT IS THE CALLER'S $REPO WHEN THERE IS ONE, AND THIS FILE'S OWN LOCATION OTHERWISE.
# Both halves are load-bearing and the first one is not laziness:
#
#   * release.sh sets no $REPO, so the module has to be able to find its own way home.
#   * 14-test-harness.sh sets `REPO="$FIX"` and then calls export_tree, DELIBERATELY: the only way
#     to test the staging itself -- what it excludes, that it carries no tunnel keys, that it is
#     small -- is to point it at a synthetic repository whose contents are known. A module that
#     ignored $REPO would quietly stage the real checkout there, and that assertion would compare
#     a nine-path fixture against the whole course tree. Measured, by writing it the other way.
#
# RESOLVED PER CALL AND NOT AT SOURCE TIME, because that harness sets $REPO long after assert.sh
# sourced this file.
#
# EXPORT-IGNORED BY THE BLANKET RULE, like everything else under .private/ that is not named in
# .gitattributes. Nothing here ships.
#
# MUST STAY BASH 3.2 COMPATIBLE -- see lib/assert.sh for why.

_ET_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
_et_repo() { if [ -n "${REPO:-}" ]; then printf '%s' "$REPO"; else printf '%s' "$_ET_HERE"; fi; }

# ─── what a student actually unpacks ───────────────────────────────────────────
# export_tree DST      -> the file set a student downloads, materialised at DST.
# would_ship_paths     -> the same, plus untracked files, as a sorted list of names.
#
# THIS IS `git archive`, NOT A COPY WITH EXCLUSIONS, and that is the whole point. GitHub builds
# its tarballs with `git archive`, which honours .gitattributes' export-ignore -- so the only
# fixture that cannot disagree with what a student receives is one git builds. The hand-written
# exclusion list this replaced had already drifted: it carried CLAUDE.md, which is export-ignored
# and has never been in the archive, and nothing noticed (#115).
#
# It also subsumes three things that list did by hand. .git, projects/* and .config/tunnel-* are
# all git-IGNORED, so the archive omits them by construction and the "exclude the directory, put
# its one tracked file back" dance goes away with them.
#
# FROM THE WORKING TREE, NOT HEAD. `git archive HEAD` would test committed code, so a red-first
# loop -- edit the launcher, run the suite, watch it fail -- would silently run the OLD launcher
# until you committed. Verified: an UNCOMMITTED .gitattributes edit is honoured here.
#
# ─── the two modes, and why they share one function ───────────────────────────
#
# `add -u` is the FIXTURE. An untracked file never reaches GitHub's archive, so putting one in a
# fixture would make it lie about what ships. Seeded from the REAL index rather than HEAD so a
# file you have `git add`ed is included.
#
# `add -A` is the GATE's second opinion: the same tree with untracked files folded in, i.e. what
# would ship if everything visible were committed. 11-export.sh subtracts the first from the
# second, and the difference is exactly the set of untracked paths that WOULD reach a student.
#
# ONE FUNCTION, TWO MODES, rather than two functions: the git plumbing below has three separate
# ways to be silently wrong (see the list) and two copies of it would eventually disagree about
# one of them -- which would make the gate's subtraction report a difference that is an artefact
# of the staging rather than a fact about the tree.
#
# THE SEED IS THE SAME FOR BOTH, deliberately, and that is why the gate checks ONE direction.
# With a HEAD seed for `add -A` the subtraction could invert -- a force-added ignored file is in
# the index but invisible to `add -A` -- so there would be a second, exotic difference to explain.
# Seeding both from the real index makes that direction structurally empty, so an assertion on it
# could not fail and has no business existing (#79).
#
# Five things that are easy to get wrong here, each measured rather than reasoned about:
#
#   * PIPEFAIL IS LOAD-BEARING. A failing `git archive` piped into `tar xf -` leaves rc 0 and an
#     empty destination -- measured, and the same trap install-cs193v.sh documents beside its own
#     download. In a subshell, so it stays local to this one pipeline. (The line number this note
#     used to carry pointed into the 1700-line installer #221 split up, and had been wrong for
#     longer than this module has existed; #237 is the standing cleanup for that class.)
#   * `cd "$(_et_repo)"` FIRST, then use --git-path's answer verbatim. It is relative to the current
#     directory in an ordinary checkout (.git/index) and ABSOLUTE inside a linked worktree
#     (/.../.git/worktrees/NAME/index) -- both measured -- so "$(_et_repo)/$(...)" is wrong in a
#     worktree. The alternates path is made absolute for the same reason.
#   * THE LINE-ENDING CONFIG IS PINNED, and this one is a fail-closed hazard rather than an
#     empty-fixture one. `git archive` runs the contents through the same conversion a checkout
#     would, so core.autocrlf=true -- which is Git for Windows' DEFAULT -- rewrites the archive.
#     Measured on this repo: 31 of the 40 exported files come out CRLF under it, cs193v and
#     course-install.sh among them. codeload builds its archives with neither setting, so an
#     unpinned call here would disagree with what a student downloads -- and once #232 hashes
#     that content, a release cut on such a checkout would refuse EVERY install on EVERY
#     platform. core.eol is pinned beside it for the day a shipped file gains a `text`
#     attribute; today none has one, so it is inert and cannot be measured.
#   * THE ALTERNATES PATH IS READ BEFORE GIT_OBJECT_DIRECTORY IS EXPORTED. `--git-path objects`
#     answers with GIT_OBJECT_DIRECTORY when it is set, so asking afterwards would point the
#     alternates at themselves and lose every object the repo already has.
#   * ANYTHING THAT READS THE REAL INDEX must run with GIT_INDEX_FILE unset, or it reads the
#     empty temp one and the archive comes out empty. Copying the index file rather than
#     rebuilding it with plumbing avoids that class entirely.
#
# core.excludesFile=/dev/null on the `add -A` arm: it is the only arm that consults ignore rules
# for untracked paths, and a developer's GLOBAL excludes would otherwise shrink the gate's second
# opinion and make it more permissive on their machine than on anyone else's.
#
# The temp index and object store are a throwaway directory, so nothing here writes to the
# developer's repository -- verified: .git/objects and .git/index are byte-unchanged, and the new
# blobs land in $work/odb. It is named with the suite's pid and swept by shim_sweep_stale,
# because a trap does not run when the process is KILLED and that is ordinary here.
_stage_tree() {                       # _stage_tree u|A DST -> 0 on success
    local mode="$1" d="$2" work rc=0
    work="$(mktemp -d "${TMPDIR:-/tmp}/cs193v-exp.$$.XXXXXX")" || return 1
    mkdir -p "$d" "$work/odb" || { rm -rf "$work"; return 1; }
    (
        cd "$(_et_repo)" || exit 1
        alt="$(git rev-parse --git-path objects)" || exit 1
        case "$alt" in /*) ;; *) alt="$(pwd -P)/$alt" ;; esac
        cp "$(git rev-parse --git-path index)" "$work/index" || exit 1
        export GIT_INDEX_FILE="$work/index" \
               GIT_OBJECT_DIRECTORY="$work/odb" \
               GIT_ALTERNATE_OBJECT_DIRECTORIES="$alt"
        case "$mode" in
            u) git add -u || exit 1 ;;
            A) git -c core.excludesFile=/dev/null add -A . || exit 1 ;;
            *) exit 1 ;;
        esac
        tree="$(git write-tree)" || exit 1
        set -o pipefail
        git -c core.autocrlf=false -c core.eol=lf archive "$tree" \
            | ( cd "$d" && tar xf - )
    ) || rc=1
    rm -rf "$work"
    return "$rc"
}

# The listing form, so an assertion can be an equality on names rather than a walk of a
# materialised copy. Same staging, so a listing and a fixture can never disagree.
_stage_paths() {                      # _stage_paths u|A -> one path per line, LC_ALL=C sorted
    local d rc=0
    d="$(mktemp -d "${TMPDIR:-/tmp}/cs193v-exp.$$.XXXXXX")" || return 1
    _stage_tree "$1" "$d" || rc=1
    [ "$rc" = 0 ] && ( cd "$d" && find . -type f | sed 's|^\./||' | LC_ALL=C sort )
    rm -rf "$d"
    return "$rc"
}

export_tree()      { _stage_tree  u "$1"; }
would_ship_paths() { _stage_paths A; }
