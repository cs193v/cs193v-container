#!/usr/bin/env bash
#
# CS193V container test runner.
#
#   tests/run-tests.sh                    the default tiers: not release, github or windows
#   tests/run-tests.sh --tier static      one tier (comma-separated, or repeat it, for several)
#   tests/run-tests.sh -k tmux            only suites whose filename CONTAINS this (same two forms)
#   tests/run-tests.sh --release          the "not shippable yet" gates
#   tests/run-tests.sh --everything-but-github
#                                         adds every tier but that one, with every cost gate set
#                                         and the image built first. Slow, and it logs you out.
#   tests/run-tests.sh --serial           one suite at a time, in file order
#   tests/run-tests.sh --list             what exists, in which tier, and in which lane
#
# --tier AND -k BOTH TAKE A LIST, AND REPEATING EITHER ADDS TO IT. `--tier static --tier unit` and
# `--tier static,unit` select the same two tiers; `-k a -k b` runs every suite matching either.
# Every tier flag adds and none of them narrows -- --release and --all included, and
# --everything-but-github unions its derived list into whatever else you asked for. NARROWING IS
# -k's JOB: it is a substring of the filename, not a glob, and it is applied within the tiers you
# selected. A tier no suite declares is refused, and so is a flag with nothing after it.
#
# Until #256 both flags ASSIGNED, so a repeat threw the previous one away in silence: `--tier
# static --tier unit --tier shim` ran one tier of three and printed a green count for it. The
# rule that came out of it is worth stating once -- A FLAG THIS SUITE SILENTLY IGNORES IS A
# MEASUREMENT NOBODY TOOK -- and it is the same shape as #158 (hand-enumerated shellcheck lists,
# so 17 files went unlinted) and #242 (a checker reading comments as call sites).
#
# MUST STAY BASH 3.2 COMPATIBLE — see tests/lib/assert.sh for why.
#
# Tiers, cheapest first. Each suite declares its own with a `# TIER:` line, so adding a
# suite needs no edit here.
#
#   static     no podman, no image, no network. Milliseconds.
#   unit       language-level unit tests (the Containerfile parser).
#   shim       the launcher's state machine against a fake podman on PATH. No containers.
#   install    install-cs193v.sh against machines that really lack podman, ssh or a subuid
#              range, in throwaway containers. Seconds, and cached after the first build.
#   windows    install-cs193v-windows.cmd under wine. NOT run by default: the fixture image
#              is 3.45 GB. Skips itself on arm64, where wine cannot execute.
#   image      assertions about the built image, via throwaway containers.
#   container  assertions about a live cs193v container: flags, kernel, ports, files.
#   live       the launcher driving real podman: idempotency, drift, cleanup.
#   release    release gates — NOT run by default. These fail until the repo is
#              shippable, which is a standing state of affairs, not a regression.
#   github     setup-git against the real GitHub API — NOT run by default, and skipped even
#              when asked for unless CS193V_GH_TEST_TOKEN is set. It needs a real credential
#              and it writes to a repository the whole class can see.
#
# --everything-but-github DERIVES that list from the suites rather than holding one, because a
# written-down list is how `--all` came to omit `windows` without anything going red. It also
# sets every gate the tiers above skip by default -- CS193V_INSTALL_NESTED,
# CS193V_INSTALL_NESTED_BUILD, CS193V_MINPODMAN_BUILD, CS193V_RELEASE_BUILD and
# CS193V_DESTRUCTIVE -- and runs ./cs193v --rebuild first, because require_image and
# require_running hard-fail without one. It leaves CS193V_GH_TEST_TOKEN alone, which is the
# github tier's own gate. It is the slow, destructive answer and it says so before it starts.
#
# IT ADDS, IT DOES NOT SUBTRACT, and since #256 that is the whole of how it composes. The skip
# above can decline to ADD the github tier; it cannot REMOVE one you named yourself. So
# `--everything-but-github --tier github` runs the github tier too, with the gates and the build,
# and CS193V_GH_TEST_TOKEN is then the only thing between you and a write to a repository the
# whole class can see -- which is exactly the gate that is deliberately not in the list above.
# The alternative was a precedence rule that silently un-asks for something you typed, and that
# is the shape #256 reported. NARROWING IS -k's JOB: `--everything-but-github -k 30-launcher`
# still runs one suite and still pays no build, because the rebuild below keys off the selected
# suites rather than off the tier list.
#:end-of-help
#
# image/container/live HARD-FAIL rather than skip when their prerequisite is missing, by
# project decision: a green run must mean the whole thing really ran.
#
# ARCHITECTURE IS THE ONE EXCEPTION to that, and it is not an erosion of it: a missing dependency
# is something the operator can install, an instruction set is not. The wine fixture and the Arch
# fixture SKIP on arm64 rather than failing -- see lib/wine.sh and 26-installer-sandbox.sh.
#
# ─── exit codes ────────────────────────────────────────────────────────────────
#   0   green
#   1   a test failed, or a suite died
#   2   you asked for something that does not exist (bad option, unknown tier, a flag with
#       nothing after it, or no suite matched)
#  78   THIS MACHINE CANNOT RUN THE TESTS -- the preflight refused. EX_CONFIG from sysexits.h,
#       chosen over an arbitrary number because a CI author can look it up (#124)
#  97   results were lost mid-run: see _emit in lib/assert.sh
# 130   interrupted
#
# ─── the two lanes ─────────────────────────────────────────────────────────────
# The tiers split cleanly by what they contend for, and the two halves share nothing:
#
#   cheap    static, unit, shim        a fake podman on PATH. No container, no ports.
#   podman   install, image, container, live
#                                       one container, one tunnel, the forwarded ports.
#            install is in this lane because an unrecognised tier lands here, which is the
#            right default -- but it shares nothing with the others, so it is a candidate
#            for a third lane once its cost is worth splitting.
#
# So they run at the same time. IMAGE, CONTAINER AND LIVE MUST STAY IN ONE LANE, and in file
# order: they share the container, and CS193V_INSTANCE does not namespace the forwarded
# host ports (see CLAUDE.md), so a second lane touching real podman would fight the first for
# them and produce failures that look exactly like real regressions. The cheap lane cannot:
# its launcher runs from a throwaway copy of the repo, and TUNNEL_ID is a hash of the
# launcher's own directory, so it could not reach the real tunnel's control socket if it tried.
#
# The podman lane runs in the FOREGROUND and streams live — it is the longer of the two and
# where the interesting failures are. The cheap lane runs in the background into its own log,
# printed in one block when it finishes, and dumped as far as it got if the run is interrupted.
# That last part is not a nicety: assert.sh prints per assertion, rather than summarising,
# specifically so that a hanging suite still shows you how far it got.

set -u

DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"

DEFAULT_TIERS="static unit shim install image container live"
TIERS=""
ASKED=""
FILTERS=""
PARALLEL=yes
EVERYTHING=no

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_BOLD=$(printf '\033[1m'); C_GRN=$(printf '\033[32m'); C_RED=$(printf '\033[1;31m')
    C_YEL=$(printf '\033[33m'); C_DIM=$(printf '\033[2m'); C_OFF=$(printf '\033[0m')
else
    C_BOLD=''; C_GRN=''; C_RED=''; C_YEL=''; C_DIM=''; C_OFF=''
fi

# SOURCED HERE, above the option loop, and NOT beside the gate call below. The loop uses do_tr to
# split `--tier a,b,c`, and those are the only wrapped-tool calls anywhere above the gate -- so
# placing this line at the gate would leave them unable to reach it. Sourcing and calling are
# independent: this file is inert at source time by its own rule, so it loads early and the GATE
# still runs where it has to.
#
# Two consequences worth knowing. `-h` and `--list` exit from inside that same loop, so they now
# pay the capability probes -- two or three `command -v` calls, and _pt_pick can neither print nor
# exit. And run-tests.sh now depends on lib/portable.sh staying inert, which is a stated rule that
# nothing enforces.
# shellcheck source=lib/portable.sh
. "$DIR/lib/portable.sh"

# READ TO A SENTINEL, not to a line number. This was `sed -n '3,30p'`, and 30 was the last line
# of the tier catalogue on the day it was written -- so the catalogue had already outgrown it and
# `--help` cut the github tier off mid-sentence. A range that has to be updated by hand every time
# the header grows is a range that will be wrong again.
usage() {
    do_awk 'NR >= 3 { if ($0 == "#:end-of-help") exit; sub(/^#? ?/, ""); print }' "$0"
    exit "${1:-0}"
}

# ─── the list flags accumulate (#256) ─────────────────────────────────────────
# BOTH OF THEM USED TO ASSIGN, so a repeat threw the previous one away without a word: `--tier
# static --tier unit --tier shim` ran one tier of three and printed a green count for it, and
# `-k a -k b -k c` re-checked one suite of three and was read as "did not reproduce". The comma
# form was documented and worked, so the two forms differed by two commas and by twelve suites.
#
# THE DE-DUPLICATION IS THE NO-ASSOCIATIVE-ARRAY IDIOM this project uses elsewhere -- see the
# --everything-but-github block and preflight below, which need it for the same reason: bash 3.2
# has no associative arrays. The one departure is `${TIERS:+$TIERS }` rather than that idiom's
# `TIERS="$TIERS $t"` followed by one `${TIERS# }` at the end: those two run to completion in a
# single loop and can strip the leading space afterwards, and an appender called from five option
# arms has no "afterwards" to put it in.
add_tiers() {                         # add_tiers LIST -> append to $TIERS; 1 if LIST held nothing
    local t seen=no
    # `set -f` BEFORE THE SPLIT, not after it. These are the operator's own strings, and without
    # it `--tier '*'` expands against whatever directory you ran from -- so the shape check below
    # would be handed filenames and would report one of those as the thing that is not a tier.
    set -f
    for t in $1; do
        # SHAPE-CHECKED HERE, which is what lets every later `for t in $TIERS` stay glob-safe with
        # no `set -f` of its own: tier_of's sed can only ever capture [a-z]*, so anything else
        # cannot be the name of a tier any suite declares.
        case "$t" in *[!a-z]*) set +f; printf 'not a tier name: %s\n' "$t" >&2; exit 2 ;; esac
        seen=yes
        case " $TIERS " in *" $t "*) ;; *) TIERS="${TIERS:+$TIERS }$t" ;; esac
    done
    set +f
    # SEEN, NOT ADDED. `--tier static --tier static` adds nothing on its second pass and must
    # not be an error -- that is the de-duplication working, not a value that named no tier.
    [ "$seen" = yes ]
}

# WHAT A HUMAN TYPED, kept apart from what the runner derived. Only this is checked against the
# declared tiers below -- DEFAULT_TIERS and --all are hand-written lists, and holding them to the
# same rule would mean that deleting the last install-tier suite makes the DEFAULT invocation
# refuse to run. That staleness is #160's complaint and not this one's.
ask_tiers() {                         # ask_tiers FLAG LIST -> add_tiers, remembering it was TYPED
    add_tiers "$2" || need_value "$1"
    ASKED="${ASKED:+$ASKED }$2"
}

add_filters() {                       # add_filters LIST -> append to $FILTERS; 1 if LIST held nothing
    local p seen=no
    set -f                            # same reason as add_tiers, and more sharply: -k '*' is a
    for p in $1; do                   # plausible thing to type and has always been a substring
        seen=yes
        case " $FILTERS " in *" $p "*) ;; *) FILTERS="${FILTERS:+$FILTERS }$p" ;; esac
    done
    set +f
    [ "$seen" = yes ]
}

# ASKED FOR SOMETHING AND GOT THE DEFAULTS. A trailing `--tier` fell through to the
# `|| TIERS="$DEFAULT_TIERS"` below and ran all seven default tiers -- the widest possible answer
# to the narrowest possible request -- and a trailing `-k` disabled filtering the same way.
#
# "NAMED NOTHING" RATHER THAN "WAS EMPTY", which is the whole reason this is reached through
# add_tiers' return value instead of a `[ -n "$1" ]` at the call site: `--tier ,` is not empty,
# but `,` splits to a single space, a `for` over that iterates zero times, and it fell through
# to the defaults exactly as a missing value did.
need_value() {                        # need_value FLAG -> refuse: this occurrence named nothing
    printf '%s needs a tier or pattern after it\n' "$1" >&2
    exit 2
}

LIST_ONLY=no
while [ "$#" -gt 0 ]; do
    case "$1" in
        --tier)    shift; ask_tiers --tier "$(printf '%s' "${1:-}" | do_tr ',' ' ')" ;;
        --tier=*)  ask_tiers --tier "$(printf '%s' "${1#--tier=}" | do_tr ',' ' ')" ;;
        --release) add_tiers release ;;
        --all)     add_tiers "$DEFAULT_TIERS release" ;;
        # EVERY tier the suites declare except one, plus the gates and the build those tiers
        # need -- see the header. NO PRECEDENCE RULE AND NO EVERYTHING=no, because every arm here
        # now ADDS: this flag unions its derived list into whatever else was asked for, and an
        # exception for it would be a special case to remember at exactly the wrong moment. The
        # arms USED to assign and the last one won, which is the bug #256 reported.
        --everything-but-github) EVERYTHING=yes ;;
        -k)        shift; add_filters "$(printf '%s' "${1:-}" | do_tr ',' ' ')" || need_value -k ;;
        -k*)       add_filters "$(printf '%s' "${1#-k}" | do_tr ',' ' ')" || need_value -k ;;
        --serial)  PARALLEL=no ;;
        --list)    LIST_ONLY=yes ;;
        -h|--help) usage 0 ;;
        *)         printf 'unknown option: %s\n\n' "$1" >&2; usage 2 ;;
    esac
    shift
done

# THE DEFAULT IS WHAT NOTHING-AT-ALL-ACCUMULATED MEANS, so it cannot be decided here any more:
# --everything-but-github adds its tiers below, and a fill-in that ran first would union the
# seven default tiers into every one of its runs. It used to be safe here only because both
# --everything-but-github and the derivation below re-assigned TIERS from empty. See below.

tier_of() {                           # tier_of FILE -> the declared tier, or 'static'
    local t
    t="$(sed -n 's/^#[[:space:]]*TIER:[[:space:]]*\([a-z]*\).*/\1/p' "$1" | head -1)"
    printf '%s' "${t:-static}"
}

wanted() {                            # wanted TIER -> 0 if it is in $TIERS
    local t
    for t in $TIERS; do [ "$t" = "$1" ] && return 0; done
    return 1
}

# ONE PATTERN OR SEVERAL, matched as an OR. `-k a -k b` reads as "either", and until #256 it read
# as "b". A SPACE-SEPARATED LIST LOSES NOTHING: these are matched against suite basenames, and the
# discovery glob below only ever yields NN-*.sh, which cannot contain a space.
matches_filter() {                    # matches_filter BASE -> 0 if no -k, or any pattern matches
    local p rc=1
    [ -n "$FILTERS" ] || return 0
    set -f                            # the operator's strings again -- see add_filters
    for p in $FILTERS; do
        case "$1" in *"$p"*) rc=0; break ;; esac
    done
    set +f
    return "$rc"
}

# Anything not named here is podman, on purpose: an unrecognised tier is serialised with the
# real container rather than run beside it, so a suite added later is slow by default and
# never wrong by default. (`release` lands there and that is correct — it greps podman for
# published images.)
lane_of() {                           # lane_of TIER -> cheap | podman
    case "$1" in
        static|unit|shim) printf 'cheap' ;;
        *)                printf 'podman' ;;
    esac
}

# ─── discover ──────────────────────────────────────────────────────────────────
SUITES=""
for f in "$DIR"/[0-9][0-9]-*.sh; do
    [ -f "$f" ] || continue
    SUITES="$SUITES $f"
done

# ─── every tier the suites declare ────────────────────────────────────────────
# DERIVED, NEVER WRITTEN DOWN, for the reason the flag below gives at length. Two readers now:
# that flag, and the refusal of a tier name no suite declares -- which is why this is computed
# here, where $SUITES exists, and read again well below the preflight.
#
# COMPUTED ONLY WHEN SOMETHING WILL READ IT. tier_of is a sed and a head per suite -- 72ms across
# this tree, measured -- and an ordinary run has no use for the SET, so a bare `run-tests.sh` must
# not pay for it. The selection loop below asks tier_of per suite either way.
KNOWN=""
if [ -n "$ASKED" ] || [ "$EVERYTHING" = yes ]; then
    for f in $SUITES; do
        t="$(tier_of "$f")"
        case " $KNOWN " in *" $t "*) ;; *) KNOWN="$KNOWN $t" ;; esac
    done
    KNOWN="${KNOWN# }"
fi

# ─── --everything-but-github, part one: the tier list (#160) ───────────────────
# DERIVED FROM THE SUITES, and that is the whole reason this is not one more string beside
# DEFAULT_TIERS. `--all` IS such a string, written when there were eight tiers, and it has
# silently omitted `windows` ever since that tier was added -- no suite ran, nothing went red,
# and the only way to find out was to read --list and compare by eye. The header's standing
# promise is that "adding a suite needs no edit here"; a hand-maintained list is how that
# promise gets broken, so this asks the files instead.
#
# HERE rather than in the option loop, because it needs $SUITES, and above --list because that
# path exits. --list does not read $TIERS, so ordering between them is free either way.
#
# The de-duplication is the no-associative-array idiom this project uses elsewhere -- see
# preflight below, which needs it for the same reason: bash 3.2 has no associative arrays.
if [ "$EVERYTHING" = yes ]; then
    for t in $KNOWN; do
        [ "$t" = github ] && continue
        add_tiers "$t"
    done
fi
[ -n "$TIERS" ] || TIERS="$DEFAULT_TIERS"

# ─── ...and part two: the gates those tiers skip by default ────────────────────
# THE SECOND WAY TO RUN LESS THAN YOU ASKED FOR. Selecting a tier is not the same as running it:
# five blocks inside the tiers above skip unless a variable is set, each for a good reason (cost,
# or destruction), and each announced as a named SKIP rather than silently. Getting the set
# right by hand means knowing all five in advance, which is #160's first complaint.
#
# PLAIN ASSIGNMENT, not `${VAR:=}`: this flag has one meaning and it overrides. The nesting is
# why they go together -- CS193V_INSTALL_NESTED_BUILD and CS193V_MINPODMAN_BUILD live INSIDE the
# CS193V_INSTALL_NESTED blocks (26-installer-sandbox.sh:558, :709, :843), so setting either one
# alone does nothing at all.
#
# CS193V_GH_TEST_TOKEN IS DELIBERATELY NOT HERE. It is the github tier's own gate, and a flag
# whose name promises to leave GitHub alone must not be the thing that supplies a credential.
if [ "$EVERYTHING" = yes ]; then
    CS193V_INSTALL_NESTED=1 CS193V_INSTALL_NESTED_BUILD=1 CS193V_MINPODMAN_BUILD=1
    CS193V_RELEASE_BUILD=yes CS193V_DESTRUCTIVE=1
    export CS193V_INSTALL_NESTED CS193V_INSTALL_NESTED_BUILD CS193V_MINPODMAN_BUILD
    export CS193V_RELEASE_BUILD CS193V_DESTRUCTIVE
fi

if [ "$LIST_ONLY" = yes ]; then
    printf '%slane    tier       suite%s\n' "$C_BOLD" "$C_OFF"
    for f in $SUITES; do
        t="$(tier_of "$f")"
        printf '%-7s %-10s %s\n' "$(lane_of "$t")" "$t" "$(basename "$f")"
    done
    exit 0
fi

# ─── the preflight, and why it is not a test (#124) ───────────────────────────
# PLACED HERE FOR EVERYTHING IT GETS FOR FREE. Nothing has forked yet, so this runs once in the
# parent on the real terminal with the colours above already set. It is above the tier and lane
# selection, so it is unconditional by construction. And it is above CS193V_RUN_DIR, the mkdir,
# the traps and the results file below -- so a refusal LEAVES NO RUN DIRECTORY AND NO RESULTS
# FILE, which is the cleanest available proof that it is not a test.
#
# `-h` and `--list` exit above it and stay ungated, deliberately: they answer questions about the
# repo, not about the machine, and a machine that fails the gate must still be able to read the
# help that explains the gate.
#
# NOT A TEST, and that is the whole point. It records no PASS/FAIL/SKIP, adds nothing to the
# tally, and is not a suite that died. A missing dependency does not mean an assertion was wrong,
# it means the suite cannot ask its questions -- so it aborts with a diagnosis and exit 78 rather
# than contributing to a 344-line failure list in which "your machine is wrong" and "the code is
# wrong" look identical.
preflight() {
    local missing name why mac deb fed plat verb pkgs fix seen=''
    missing="$(pt_missing)" && ! pt_bash_too_old && return 0

    printf '\n%sTHIS MACHINE CANNOT RUN THE TEST SUITE%s%*s(#124)\n\n' \
           "$C_RED$C_BOLD" "$C_OFF" 32 ''
    if pt_bash_too_old; then
        printf '  %-12s %s\n' bash "reports ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}, and 3.2 or newer is needed"
        printf '  %-12s %s\n\n' '' 'This is a FLOOR and never a ceiling -- see the note above.'
    fi

    # THREE FAMILIES, NOT DARWIN-AND-EVERYTHING-ELSE (#195). This was `Darwin) plat=mac ;; *)
    # plat=deb`, so every machine that was not a Mac read the Debian column and was told to run
    # apt -- on Fedora that is the wrong package manager, and then the wrong name in three rows.
    # The family comes from lib/portable.sh's pt_distro_family, which parses /etc/os-release the
    # way install-cs193v.sh:454-466 does, and the macOS fork stays HERE for the reason that file
    # keeps it there: platform() first, and the family only on the Linux arm.
    #
    # ONE VERB, RESOLVED ONCE. $plat was re-tested in three places -- the column pick, the per-row
    # `fix` line, and the `all of them:` summary -- and a family added to two of them and missed in
    # the third prints a report that names dnf twice and apt once. Two of those three were asking
    # the same question, so they are one $verb now and the column pick is the only other reader.
    case "$(uname -s)" in Darwin) plat=mac ;; *) plat="$(pt_distro_family)" ;; esac
    case "$plat" in
        mac)    verb='brew install' ;;
        fedora) verb='sudo dnf install -y' ;;
        *)      verb='sudo apt install -y' ;;
    esac

    # COLLECTED, then printed once. A fresh machine is missing several things at once, and a gate
    # that makes you fix them one run at a time is worse than the disease.
    pkgs=''
    while IFS='|' read -r name why mac deb fed; do
        [ -n "${name:-}" ] || continue
        case "$plat" in
            mac)    fix="$mac" ;;
            fedora) fix="$fed" ;;
            *)      fix="$deb" ;;
        esac
        printf '  %-12s %s\n' "$name" 'is missing, or is not the build this suite needs'
        printf '  %-12s why  %s\n' '' "$why"
        case "$fix" in
            '('*) printf '  %-12s note %s\n\n' '' "$fix" ;;
            *)    printf '  %-12s fix  %s %s\n\n' '' "$verb" "$fix"
                  # De-duplicated with the no-associative-array idiom this project uses
                  # elsewhere, because one package satisfies several rows.
                  case " $seen " in *" $fix "*) ;; *) seen="$seen $fix"; pkgs="$pkgs $fix" ;; esac ;;
        esac
    done <<PREFLIGHT_EOF
$missing
PREFLIGHT_EOF

    [ -z "$pkgs" ] || printf '  all of them:  %s%s\n\n' "$verb" "$pkgs"
    printf 'Nothing was run and nothing was recorded: this is not a test failure, it is a\n'
    printf 'machine that cannot ask the question.\n\n'
    exit 78
}
preflight

# ─── a tier nobody declares is a typo, not a selection (#256) ──────────────────
# `--tier static,unti` USED TO RUN THE STATIC SUITES AND EXIT 0 GREEN. An unrecognised tier simply
# matched no suite, and the good tier beside it kept the count non-zero -- so the typo cost you a
# tier and said nothing: the same subset-reported-as-the-whole the header's #256 note describes,
# wearing a smaller hat.
#
# ONLY WHAT WAS TYPED, which is what $ASKED is for. DEFAULT_TIERS and --all are hand-written
# strings, and holding them to this rule would mean that deleting the last install-tier suite
# makes the DEFAULT invocation refuse to run -- a tier the runner selects by default cannot be a
# tier the runner rejects by name. That staleness is #160's complaint, not this one's; a tier that
# is legitimate but declared nowhere still lands on "no suites matched" below.
#
# BELOW THE PREFLIGHT ON PURPOSE, and this is the one ordering in this block worth arguing.
# `unknown option` (in the loop above) refuses before --list, so argv errors precede everything --
# but the preflight is placed where it is so that it is "unconditional by construction", and an
# exit above it would make that false for one argv shape. A machine that cannot run the suite at
# all should say so before it comments on your spelling. It is still ABOVE CS193V_RUN_DIR and the
# mkdir below, so a refusal here leaves no run directory -- unlike the "no suites matched" exit,
# which is below them and always has been.
#
# AND --list STAYS UNGATED, which follows rather than being a second decision: it exits above the
# preflight, so it cannot reach this. That is the right answer anyway -- `--list` is how you look
# up the spelling you just got wrong.
for t in $ASKED; do
    case " $KNOWN " in *" $t "*) ;;
        *) printf 'unknown tier: %s\nknown tiers: %s\n' "$t" "$KNOWN" >&2; exit 2 ;;
    esac
done

# ─── run ───────────────────────────────────────────────────────────────────────
WALL_T0=$SECONDS
# ONE DIRECTORY PER RUN, AND IT IS KEPT. These files used to be loose mktemps deleted by the
# cleanup trap, so a run that hung and was killed destroyed the only evidence of where it got
# to -- which is the opposite of what assert.sh prints per assertion for. Named by pid so the
# sweep below can tell a finished run's leftovers from a concurrent run's live ones, the same
# reasoning lib/assert.sh gives for sweeping scratch directories by pid rather than by age.
CS193V_RUN_DIR="${TMPDIR:-/tmp}/cs193v-runlog.$$"
mkdir -p "$CS193V_RUN_DIR"
# An earlier run's directory, only if the process that made it is gone.
for _d in "${TMPDIR:-/tmp}"/cs193v-runlog.*; do
    [ -d "$_d" ] || continue
    _p="${_d##*.}"
    case "$_p" in ''|*[!0-9]*) continue ;; esac
    [ "$_p" = "$$" ] && continue
    kill -0 "$_p" 2>/dev/null && continue
    rm -rf "$_d" 2>/dev/null || true
done
RESULTS="$CS193V_RUN_DIR/results.tsv"; : > "$RESULTS"
export CS193V_RESULTS="$RESULTS"
TIMINGS="$CS193V_RUN_DIR/timings.tsv"; : > "$TIMINGS"
# Suites that exited without finishing, one per line. A FILE rather than a variable because the
# cheap lane runs inside a subshell, so a counter set there would never come back — the same
# thing that made repo_copy leak (#76).
CRASHES="$CS193V_RUN_DIR/crashes.tsv"; : > "$CRASHES"
CHEAPLOG=""
CHEAP_PID=""
CHEAP_FLUSHED=no

# Print the background lane's output, wherever we got to. Called once on the normal path and
# again from the trap, so it has to be idempotent — and called from the trap AT ALL because an
# interrupted run must still show what that lane had managed, rather than throwing it away.
flush_cheap() {
    [ "$CHEAP_FLUSHED" = no ] || return 0
    [ -n "$CHEAPLOG" ] && [ -s "$CHEAPLOG" ] || return 0
    CHEAP_FLUSHED=yes
    printf '\n%s─── the no-podman lane, which ran alongside the above ───%s\n' "$C_DIM" "$C_OFF"
    cat "$CHEAPLOG"
}

# Kill a background lane and everything under it. `kill $CHEAP_PID` on its own reaches only
# the subshell: bash gives a background job no process group of its own without job control,
# so there is no group to signal, and the suite the subshell was running is simply orphaned.
# Measured — a Ctrl+C'd run left 30-launcher-shim.sh going after the runner had exited, which
# for the podman lane would mean a suite still driving the container nobody is watching.
# Children first, so nothing is reparented and missed. pgrep -P is on macOS too.
kill_tree() {                         # kill_tree PID
    local kid
    for kid in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$kid"; done
    kill "$1" 2>/dev/null
    return 0
}

cleanup() {
    [ -n "$CHEAP_PID" ] && kill_tree "$CHEAP_PID"
    flush_cheap
    # DELIBERATELY NOT REMOVED. The run directory is the record of what happened, and it is
    # most wanted exactly when the run did not finish. Its path is printed below; the next run
    # sweeps it once this pid is gone.
    return 0
}
trap 'cleanup' EXIT
# INT and TERM as well as EXIT: bash runs an EXIT trap on both, but only after the handler for
# them returns, and without an explicit exit the script would carry on running suites after a
# Ctrl+C. 130 is the conventional status for SIGINT.
trap 'cleanup; exit 130' INT TERM

# ─── the clock ─────────────────────────────────────────────────────────────────
# `date +%N` is GNU-only — on a TA's Mac it prints a literal "N", so anything built on it
# reports garbage on exactly the platform VERIFICATION.md §5.2/§5.3 cares about. bash's own
# `time` keyword with TIMEFORMAT is millisecond-resolution, costs no subprocess, and has been
# in bash since long before 3.2.
#
# fd 3 and 4 are the real stdout and stderr. run_suite writes the suite's own output there,
# so the command substitution that captures time's report captures ONLY that report — the
# assertions still stream to the terminal as they happen, which is the property assert.sh is
# built around ("a hanging suite still shows you how far it got").
TIMEFORMAT='%3R'
exec 3>&1 4>&2

# A SUITE THAT DIES IS RECORDED, not shrugged off. This used to end in `|| true` and the whole
# verdict rested on the FAIL count in $RESULTS, so a suite that exited half way through — a
# `set -u` slip, a kill, or _emit finding the results file unwritable — cost the run its results
# and nothing else: the summary counted what had survived and reported `0 fail` (#76).
run_suite() {                         # run_suite FILE  — output goes to the real terminal
    bash "$1" 1>&3 2>&4 || printf '%s\t%s\n' "$?" "$(basename "$1")" >> "$CRASHES"
    return 0
}

run_lane() {                          # run_lane FILE...  — sequential, in the order given
    local f base tier elapsed
    for f in "$@"; do
        base="$(basename "$f")"
        tier="$(tier_of "$f")"
        printf '\n%s%s%s %s[%s]%s\n' "$C_BOLD" "$base" "$C_OFF" "$C_DIM" "$tier" "$C_OFF"
        CS193V_SUITE="$base"; export CS193V_SUITE
        elapsed="$( { time run_suite "$f"; } 2>&1 )"
        printf '%s\t%s\n' "$elapsed" "$base" >> "$TIMINGS"
        printf '  %s%ss%s\n' "$C_DIM" "$elapsed" "$C_OFF"
    done
}

# ─── select, and sort into lanes ───────────────────────────────────────────────
CHEAP=""
PODMAN=""
RAN=0
for f in $SUITES; do
    base="$(basename "$f")"
    tier="$(tier_of "$f")"
    wanted "$tier" || continue
    matches_filter "$base" || continue
    RAN=$((RAN + 1))
    if [ "$(lane_of "$tier")" = cheap ]; then CHEAP="$CHEAP $f"; else PODMAN="$PODMAN $f"; fi
done

if [ "$RAN" -eq 0 ]; then
    printf '\n%sno suites matched%s (tiers: %s, filter: %s)\n' "$C_YEL" "$C_OFF" "$TIERS" "${FILTERS:-none}" >&2
    exit 2
fi

# Two lanes only when there is something in both. A `-k` or `--tier` run that lands entirely
# in one lane gets no lane machinery and no buffering — which is most single-suite runs, and
# the case where seeing the output live matters most.
LANES=one
[ "$PARALLEL" = yes ] && [ -n "$CHEAP" ] && [ -n "$PODMAN" ] && LANES=two

# WHAT IS ABOUT TO BE MEASURED, IN FULL (#256). The tier list was here already; the suite count
# and the -k patterns were not, and those are what separate `--tier static,unit,shim` from
# `--tier static --tier unit` -- two commands that differed by two commas, by twelve suites, and
# by nothing at all on screen. Built once and printed twice: see the summary.
SUITEWORD=suites; [ "$RAN" -eq 1 ] && SUITEWORD=suite
SCOPE="$RAN $SUITEWORD, tiers: $TIERS"
[ -n "$FILTERS" ] && SCOPE="$SCOPE, -k: $FILTERS"
printf '%sCS193V container tests%s  %s(%s)%s\n' "$C_BOLD" "$C_OFF" "$C_DIM" "$SCOPE" "$C_OFF"
[ "$LANES" = two ] && printf '%stwo lanes: the podman tiers below, and static/unit/shim alongside them%s\n' \
                             "$C_DIM" "$C_OFF"
printf '%s\n' "-------------------------------------------------------------------"

# ─── ...and part two-and-a-half: which shell drove the ptys ───────────────────
# SAID, BECAUSE THE TWO RUNS LOOK IDENTICAL OTHERWISE. CS193V_PTY_SHELL makes every pty in the
# run interpose a shell between the pty owner and the command, which is how a Mac or a Fedora box
# reproduces the configuration #151 was reported from -- and a results file that did not mention
# it would leave "1750 pass" meaning two different things on two different days. Silent in the
# ordinary case, so it cannot become noise nobody reads.
if [ -n "${CS193V_PTY_SHELL:-}" ]; then
    printf '%spty shell%s\n' "$C_BOLD" "$C_OFF"
    printf '  %-13s %s\n' shell "$CS193V_PTY_SHELL"
    printf '  %-13s %s\n' means \
           'every pty runs its command under this instead of /bin/sh (#151)'
    printf '%s\n' "-------------------------------------------------------------------"
fi

# AND THE KNOB THAT MAKES THAT ONE INERT, announced for the same reason and rather more urgently.
# CS193V_PTY_NOSHELL is a per-call-site shape knob -- two suites set it around one launch each --
# and set for a whole RUN it removes the shell from every pty, so CS193V_PTY_SHELL stops meaning
# anything, lib/sh-fake cannot interpose, and the callers that hand ptyrun a shell command STRING
# (`test -t 0 && echo ISTTY`, `podman exec -it NAME sh -c '...'`) exec a path that does not exist.
# 14-test-harness.sh's two interposition controls are what turn that red rather than quiet; this is
# what tells a reader why, before they read 40 failures as a regression.
if [ "${CS193V_PTY_NOSHELL:-}" = 1 ]; then
    printf '%spty shell%s\n' "$C_BOLD" "$C_OFF"
    printf '  %-13s %s\n' shell 'none -- CS193V_PTY_NOSHELL=1 is set for this whole run'
    printf '  %-13s %s\n' means \
           'every pty execs its argv, so CS193V_PTY_SHELL is inert and string callers fail (#151)'
    printf '  %-13s %s\n' 'meant for' \
           'one call site at a time: 70-sighup.sh §1c and 12-run-timeout.sh, which set it themselves'
    printf '%s\n' "-------------------------------------------------------------------"
fi

# ─── ...and part three: say what this is, then build what it needs ─────────────
# SAID, NOT ASKED. A prompt would break the one thing #160 wanted -- "I just run that one
# command and everything goes" -- but this flag deletes the volumes five logins live in and
# runs three multi-GB builds, and a flag that does that without a word is worse than one that
# asks. So it is announced, on screen, above the run it is about to start.
if [ "$EVERYTHING" = yes ]; then
    printf '%severything but github%s\n' "$C_BOLD" "$C_OFF"
    printf '  %-13s %s\n' builds \
           './cs193v --rebuild first, then the nested, oldest-podman and no-cache builds'
    printf '  %-13s %s\n' destructive \
           'CS193V_DESTRUCTIVE=1 -- deletes the claude/codex/gh/vercel/git volumes'
    printf '  %-13s %s\n' needs 'about 15 GB free, and a long wall clock'
    # CLAUDE.md's hazard, and it earns a line HERE specifically because of the line above it:
    # with the volumes about to be deleted, an unset instance takes a colleague's logins too.
    [ -n "${CS193V_INSTANCE:-}" ] || printf '  %-13s %s\n' instance \
           'CS193V_INSTANCE is unset, so this is the SHARED container and volumes'
    printf '%s\n' "-------------------------------------------------------------------"
fi

# THE THIRD WAY TO RUN LESS THAN YOU ASKED FOR, and the loudest: require_image and
# require_running HARD-FAIL rather than skip when the image or the container is missing
# (lib/assert.sh), by a project decision stated at the top of this file. That decision is right
# and stays -- but it made "run everything on a machine you have just brought up" a two-command
# operation whose first command you had to already know about. So this runs it.
#
# CHEAP WHEN IT CAN BE. --rebuild compares cs193v.buildhash against the recipe on disk, so it is
# a two-second recreate when nothing moved and a full build when it did -- which is exactly the
# state a new platform is in. See CLAUDE.md.
#
# AFTER THE LANE SORT, so `[ -n "$PODMAN" ]` can skip it: --everything-but-github with a `-k`
# that lands entirely in the cheap lane must not pay for an image nothing is going to look at.
#
# ABORTS ON FAILURE rather than carrying on. verb_rebuild is safe to drive from here -- no
# confirm, no handover to a shell, it returns -- but it does refuse while a session is live, and
# letting that through would mean six podman-tier suites each rediscovering it as require:image,
# with the one line that explained it scrolled off the top.
if [ "$EVERYTHING" = yes ] && [ -n "$PODMAN" ]; then
    if ! ( cd "$DIR/../.." && ./cs193v --rebuild ); then
        printf '\n%s./cs193v --rebuild failed%s, so the image and container the image, container\n' \
               "$C_RED" "$C_OFF"
        printf 'and live tiers test against do not exist. Nothing below could measure anything,\n'
        printf 'so nothing below was run.\n'
        exit 1
    fi
    printf '%s\n' "-------------------------------------------------------------------"
fi

if [ "$LANES" = two ]; then
    CHEAPLOG="$CS193V_RUN_DIR/cheap-lane.log"; : > "$CHEAPLOG"
    # Everything the lane emits goes to its log, fd 3 and 4 included — those are where
    # run_suite sends each suite's own output, and in this lane the log IS the terminal.
    # shellcheck disable=SC2086
    ( exec >"$CHEAPLOG" 2>&1 3>&1 4>&1; run_lane $CHEAP ) &
    CHEAP_PID=$!
    # shellcheck disable=SC2086
    run_lane $PODMAN
    wait "$CHEAP_PID" 2>/dev/null || true
    CHEAP_PID=""
    flush_cheap
else
    # shellcheck disable=SC2086
    run_lane $CHEAP $PODMAN
fi

# ─── summarise ─────────────────────────────────────────────────────────────────
# grep -c prints 0 AND exits 1 when nothing matches, so `|| echo 0` would emit "0\n0".
# Take grep's output and ignore its status instead.
count() {
    local n
    n="$(grep -c "^$1	" "$RESULTS" 2>/dev/null)" || true
    printf '%s' "${n:-0}"
}
P="$(count PASS)"; F="$(count FAIL)"; S="$(count SKIP)"; R="$(count REC)"

printf '\n%s\n' "-------------------------------------------------------------------"

# Where the time went, slowest first. Printed above the counts rather than below them,
# because the counts are the verdict and should be the last thing on the screen.
# bash has no float arithmetic, so the sort and the total are one awk rather than a loop.
if [ "$RAN" -gt 1 ]; then
    sort -rn "$TIMINGS" | awk -v dim="$C_DIM" -v off="$C_OFF" '
        { total += $1; printf "  %s%8.1fs  %s%s\n", dim, $1, $2, off }
        END { printf "  %s%8.1fs  suite time, added up%s\n", dim, total, off }'
    # Wall clock separately, and it is the number that matters: with two lanes it is less than
    # the sum above, and how much less is the whole point of running them.
    printf '  %s%8ss  wall clock%s\n\n' "$C_DIM" "$((SECONDS - WALL_T0))" "$C_OFF"
fi

# Printed BEFORE the counts, because a suite that died makes the counts an undercount and the
# reader needs to know that before reading them. rc 97 is _emit's: see lib/assert.sh.
if [ -s "$CRASHES" ]; then
    printf '%sSUITES THAT DIED%s\n' "$C_RED" "$C_OFF"
    while IFS="	" read -r rc suite; do
        printf '  %s  exited %s without finishing\n' "$suite" "$rc"
        # 97 is _emit's, and it means the counts below are an undercount of a run that had
        # already stopped recording — a different thing from a suite that merely fell over.
        [ "$rc" = 97 ] && printf '  %s\n' \
            "      its results file could not be written, so results were LOST and every" \
            "      count below is an undercount"
    done < "$CRASHES"
    printf '\n'
fi

if [ "$F" -gt 0 ]; then
    printf '%sFAILURES%s\n' "$C_RED" "$C_OFF"
    grep "^FAIL	" "$RESULTS" | while IFS="	" read -r _st suite name; do
        printf '  %s  %s\n' "$suite" "$name"
    done
    printf '\n'
fi
printf '%s%s pass%s   ' "$C_GRN" "$P" "$C_OFF"
[ "$F" -gt 0 ] && printf '%s%s fail%s   ' "$C_RED" "$F" "$C_OFF" || printf '0 fail   '
printf '%s%s skip   %s recorded%s\n' "$C_DIM" "$S" "$R" "$C_OFF"
# AND WHAT THOSE COUNTS COVER, on the same screen as the counts themselves. Deliberately the same
# string the banner printed: by the time this line appears the banner is thousands of lines up,
# and it is this block that gets pasted into an issue. `2195 pass` and `919 pass` are both
# green-looking numbers, and #256 is the report of someone reading the second as the first.
printf '%sover %s%s\n' "$C_DIM" "$SCOPE" "$C_OFF"
# Where the record of this run is, said on every run rather than only on a bad one -- a path
# you only learn about when things went wrong is a path you have to go looking for at the worst
# moment. Holds results.tsv, timings.tsv, crashes.tsv and the no-podman lane's full output.
printf '%slog: %s%s\n' "$C_DIM" "$CS193V_RUN_DIR" "$C_OFF"

# A dead suite fails the run even with no FAIL line to its name: the point of the count is that
# it can be trusted, and it cannot be when a suite stopped early.
[ "$F" -eq 0 ] && [ ! -s "$CRASHES" ]
