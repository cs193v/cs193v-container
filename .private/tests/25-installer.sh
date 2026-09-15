#!/usr/bin/env bash
# TIER: shim
#
# install-cs193v.sh — the student's first contact with the course, and the one script that
# is allowed to change their machine. Covers VERIFICATION.md §1.1, §1.2, §1.3, §1.6 and
# §A.12.
#
# §A.12's own idempotency check is vacuous as written: `bash install-cs193v.sh </dev/null`
# hits the consent menu, which with no tty deliberately picks the safe default ("Stop, do
# not change anything") and exits 0 before touching a thing. The state hash before and
# after is then trivially identical. Here the installer runs against a fake podman and a
# tarball served over file://, so every step really executes and the comparison means
# something.
#
# Nothing in here needs sudo, and nothing writes outside its own temp directory.

# SC2034 FOR THE WHOLE FILE, because it is a property of the whole file: this suite carves
# functions out of install-cs193v.sh (carve_func, lib/shared.sh:191) and sources them in a
# subshell, so every global those carvings read has to be set HERE, one `.` away from any use a
# linter can see. (Not spelled with the linter's own name at the start of a line: a comment that
# opens `# shellcheck <word>` is parsed as a DIRECTIVE, which is SC1072 rather than prose -- the
# same self-matching hazard 10-static.sh:377 assembles its needles tail-first to avoid.)
# PODMAN_PKG_ID is read by the podman-path probe, PM_REFRESH/PM_INSTALL and
# the five PKG_* by distro_packages. lib/shared.sh:196-207 makes this argument for a single line
# of one file; a suite built entirely out of carvings is the same argument at file scale.
# shellcheck disable=SC2034
set -u
. "$(dirname -- "$0")/lib/assert.sh"
. "$(dirname -- "$0")/lib/podman-shim.sh"

cd "$REPO" || exit 1
TMP="$(new_tmpdir)"
# The installer's own catalogue, for the assert_says*_key sites: the default is the launcher's,
# and 10-static.sh forbids a key appearing in both, so naming it is what makes an assertion say
# which catalogue it means.
ICAT="$PRIVATE/course-install-messages.txt"

# ─── which sign-off a run ends with  (#134) ────────────────────────────────────
# #218 made say_done the single closing message. #134 gave it something it can get WRONG: two of
# the steps ahead of it are advisory, so on the run where one of them warned, a sign-off that
# still says "open CS193V Development Environment" is telling a student to open something the
# same screen just said could not be created. The four arms are the whole of that decision, and
# nothing else asserts them.
#
# THE STUB PRINTS THE KEY AND THE COMPARISON IS EXACT. `assert_contains "finished"` would be
# satisfied by finished.macos as well -- these arms differ only by suffix, so a containment test
# cannot tell the fallback from the promise. Trimmed because say_done brackets its output in
# blank lines.
# ─── the three strings both halves of #134 have to agree about ─────────────────
# READ OUT OF THE INSTALLER, ONCE, AND HIGH ENOUGH UP THAT EVERY CASE BELOW CAN SEE THEM. The
# bundle name is also the Start Menu label and the string students are told to look for; the two
# fixed paths are the entire interface between course-install.sh and the .cmd. Spelling any of
# them in this file would be the copy that drifts.
MAC_LABEL="$(sed -n 's/^MAC_APP_LABEL="\([^"]*\)".*/\1/p' $PRIVATE/course-install.sh)"
WIN_SHIM_PATH="$(sed -n 's/^WIN_SHIM_NAME="\([^"]*\)".*/\1/p' $PRIVATE/course-install.sh)"
WIN_ICON_PATH="$(sed -n 's/^WIN_ICON_NAME="\([^"]*\)".*/\1/p' $PRIVATE/course-install.sh)"

# ─── "did not claim success" now means FOUR messages, not one ──────────────────
# Every failure case in this file asserts that the run did not print a sign-off, and until #134
# there was one sign-off to look for. There are now four, and a needle for `finished` alone is
# satisfied by a run that claimed success through finished.macos -- whose text diverges one word
# earlier, at "open", so it does not contain the other's needle. That would have quietly weakened
# roughly ten assertions on every Mac. One helper, so the list of arms lives in one place and the
# next arm added is a one-line edit here rather than ten silent holes.
# AND THE ARMS HAVE TO BE TELLABLE APART, which is a property of the PROSE and is asserted here
# because every keyed sign-off assertion in this file silently depends on it. msg_text stops at
# the first {{placeholder}}, so two arms that open identically share a needle -- and containment
# is enough to spoil it: if one arm's needle is a prefix of another's, a run printing the second
# matches an assertion about the first. Measured: finished.macos and finished.windows-shortcut
# were exactly that pair until the catalogue was reworded.
SIGNOFF_ARMS='finished finished.macos finished.windows finished.windows-shortcut'
overlap=''
for a in $SIGNOFF_ARMS; do
    for b in $SIGNOFF_ARMS; do
        [ "$a" = "$b" ] && continue
        na="$(msg_text "$a" "$ICAT")"; nb="$(msg_text "$b" "$ICAT")"
        case "$nb" in *"$na"*) overlap="$overlap $a-inside-$b" ;; esac
    done
done
assert_eq "signoff-arms:are-mutually-distinguishable" "" "$overlap"

assert_no_signoff() {                 # assert_no_signoff NAME TEXT
    local k needle
    for k in finished finished.macos finished.windows finished.windows-shortcut; do
        needle="$(msg_text "$k" "$ICAT")"
        if [ -z "$needle" ]; then
            fail "$1" "no prose for $k -- the arm list in assert_no_signoff has gone stale"
            return
        fi
        case "$2" in *"$needle"*)
            fail "$1" "claimed success: the output contains the $k sign-off"; return ;;
        esac
    done
    pass "$1"
}

carve_func $PRIVATE/course-install.sh say_done "$TMP/say_done.sh"
if [ -s "$TMP/say_done.sh" ]; then pass "extract:say-done"
else fail "extract:say-done" "could not carve say_done out of course-install.sh"; fi

run_say_done() {                      # run_say_done WINFLAG MACREADY WINREADY -> the key that fired
    (
        . "$TMP/say_done.sh"
        msg() { printf '%s' "$1"; }
        win_projects_path() { printf 'UNC'; }
        DIR=/course; WSL_DISTRO=CS193V; MAC_APP_LABEL="a label"
        CS193V_WINDOWS="$1"; MAC_APP_READY="$2"; WIN_SHIM_READY="$3"
        say_done
    ) | do_tr -d ' \n'
}

# THE KEY A SUCCESSFUL INSTALL ENDS WITH ON *THIS* MACHINE, derived from say_done rather than
# spelled out. Three end-to-end cases below assert that a run reached its sign-off, and before
# #134 there was only one sign-off to reach. Now which one depends on whether a bundle got made,
# so a test naming `finished` unconditionally is red on every Mac -- which is precisely the shape
# of #261, where podman-old:refused asserts the generic key on the branch that prints the macOS
# one. Asking say_done removes the second copy that could drift: the only thing forked here is
# "does this platform make a bundle", which is install_mac_app's own gate, and Darwin is what
# platform() keys its macos arm off.
if [ "$(uname -s)" = Darwin ]; then FINISHED_KEY="$(run_say_done '' yes '')"
else                               FINISHED_KEY="$(run_say_done '' '' '')"; fi
record "sign-off:the-key-a-clean-run-ends-with" "$FINISHED_KEY"
assert_ne "sign-off:that-key-was-derivable" "" "$FINISHED_KEY"


# The cheapest tripwire for the whole class of accident installer_host exists to prevent.
# $HOME here is the REAL one -- the door redirects it for the installer's process only --
# so if any case in this file ever writes the course tree into the developer's own home
# directory, the run that did it says so, rather than a colleague finding it weeks later.
#
# COMPARED AGAINST THE START, not asserted absent: a TA may legitimately have installed the
# course at the default location on this very machine, and a check that failed for them
# would be edited out rather than read. What must not happen is that it APPEARS during a run.
# Sampled at both ends because a killed run cannot reach its own EXIT trap.
home_state() { if [ -e "$HOME/cs193v" ]; then printf 'present'; else printf 'absent'; fi; }
HOME_AT_START="$(home_state)"
record "door:the-real-home-at-suite-start" "$HOME_AT_START"

door_check() { assert_eq "door:the-real-home-is-as-we-found-it" "$HOME_AT_START" "$(home_state)"; }
trap 'door_check; rm -rf "$TMP"; shim_cleanup' EXIT
# ...and at START as well, because that trap cannot run if the suite is KILLED, which is
# ordinary here. See sweep_stale_tmpdirs in lib/assert.sh for the rest of the reasoning.
record "shim:leftover-dirs-from-an-earlier-run" "$(shim_sweep_stale)"

# ─── the two pure functions, extracted and unit-tested ─────────────────────────
# ONE COPY SINCE #221. version_lt used to be duplicated in cs193v-ui.sh and the installer, and
# the reason this pair was unit-tested twice was that a disagreement meant a student told to
# upgrade by one and accepted by the other. course-install.sh sources the shared file now, so
# there is one implementation and the table below drives it once.
#
# carve_func (lib/shared.sh) is this sed, lifted out because three other places now need it;
# the reason it anchors on /^name()/ rather than the brace is recorded there.
carve_func $PRIVATE/files/cs193v-ui.sh version_lt "$TMP/vl_ui.sh"
if [ "$(wc -l < "$TMP/vl_ui.sh" | do_tr -d ' ')" -gt 3 ]; then pass "extract:vl_ui"
else fail "extract:vl_ui" "could not extract version_lt"; exit 1; fi
# AND NOBODY ELSE CARRIES ONE, which is the half that catches a copy coming back rather than
# the shared one going wrong.
assert_eq "version_lt:course-install-has-no-copy" "0" \
          "$(grep -c '^version_lt() {$' $PRIVATE/course-install.sh)"

# 5.7.0 vs 5.7.0 is the case that matters most: MIN_PODMAN is 5.7.0 and Ubuntu 26.04 ships
# exactly that, so "equal" must mean "acceptable" or every stock Ubuntu student is refused.
# 10.0.0 vs 5.7.0 guards against a lexical compare.
# source=/dev/null for the reason :187 gives for the same shape: the carving's path is built
# from an argument, so there is nothing for shellcheck to follow (SC1090).
# shellcheck source=/dev/null
run_vl() { ( . "$TMP/$1.sh"; version_lt "$2" "$3" ); }
for pair in "5.7.0 5.7.0 no" "5.6.0 5.7.0 yes" "5.6.9 5.7.0 yes" "5.7.1 5.7.0 no" \
            "10.0.0 5.7.0 no" "5.7 5.7.0 no" "5.7.0 5.7 no" "6 5.7.0 no" \
            "4.9.3 5.7.0 yes" "0.0.1 5.7.0 yes" "5.10.0 5.9.0 no" "5.9.0 5.10.0 yes"; do
    set -- $pair
    a="$1"; b="$2"; want="$3"
    assert_eq "version_lt:ui($a<$b)" "$want" "$(run_vl vl_ui "$a" "$b")"
done
# 5.10 vs 5.9 is the classic numeric-vs-lexical trap; asserted above for both copies.

# ─── and the two floors it is compared against ─────────────────────────────────
# ONE DECLARATION EACH SINCE #221, and this block reads it rather than comparing copies. The
# function and both numbers used to be declared separately in install-cs193v.sh and in cs193v,
# because a file downloaded on its own can source nothing, and the checks here existed to prove
# the copies agreed. They live in files/cs193v-ui.sh now, which course-install.sh and cs193v
# both source, so what is asserted below is that the installer declares NO floor of its own and
# that the shared numbers are the measured ones.
#
# TWO FLOORS EACH, SINCE THE PLATFORMS DIVERGED. On Linux the floor decides which distros work, so
# it is 4.9.0 (measured: 4.9.3, 5.4.2 and 5.7.0 all build the whole course image). On a Mac it
# decides nothing about distros and lowering it would admit the pre-5.0 `podman machine`, which no
# test can reach -- so it stays at 5.7.0. Four constants in two files.
#
# NOTHING CHECKED THAT THEY AGREE, and the consequence is worse than the version_lt one because
# the installer runs FIRST and the launcher runs LAST. Measured, not imagined: lowering only the
# installer's copy produces an install that passes its survey, downloads the course files,
# confirms podman works and the disk is big enough -- and then hands off to build_image, where the
# LAUNCHER draws a STOP box saying the podman is too old. Every reassuring step first, the refusal
# last, on a machine the installer just declared fit. A student would read that as the install
# having broken at the end.
#
# So this is the check that a fix to one floor cannot silently be half a fix.
# 26-installer-sandbox.sh's floor-skew case is the behavioural half of the same claim.
# ONE PAIR OF FLOORS SINCE #221, so "the two agree" is not a claim any more -- what is left is
# that the shared file declares each one exactly once, and that nothing else declares one at all.
# The consequence the old check existed for is unchanged and worth restating: the installer runs
# FIRST and the launcher runs LAST, so a floor either of them disagreed about produced an install
# that passed every reassuring step and then a STOP box from the launcher.
for plat in LINUX MACOS; do
    mp_lnch="$(sed -n "s/^MIN_PODMAN_$plat=\"\([^\"]*\)\".*/\1/p" $PRIVATE/files/cs193v-ui.sh)"
    # NON-EMPTY FIRST, and this is the guard rather than pedantry: a renamed constant or a changed
    # quoting style would make the sed match nothing, and an empty-vs-empty comparison passes
    # forever -- the exact trap this file records at its top for version_lt.
    assert_ne "min-podman:ui-declares-$plat"  "" "$mp_lnch"
    assert_eq "min-podman:course-install-declares-no-$plat-floor" "0" \
              "$(grep -c "^MIN_PODMAN_$plat=" $PRIVATE/course-install.sh)"
    record    "min-podman:$plat-floor" "$mp_lnch"
    # EXACTLY ONE DECLARATION IN EACH, because a second one later in either file would shadow the
    # first and the check above would read the wrong number. Counted rather than assumed: the sed
    # takes every match, so two lines would give "4.9.0\n5.7.0" and compare unequal by luck
    # rather than by design -- and two IDENTICAL extra lines would compare equal and hide it.
    assert_eq "min-podman:ui-declares-$plat-once"  "1" \
              "$(grep -c "^MIN_PODMAN_$plat=" $PRIVATE/files/cs193v-ui.sh)"
done
# AND THE MAC FLOOR IS NEVER THE LOWER OF THE TWO, which is the whole point of splitting them: the
# Linux floor exists to be lowered as distros are measured, and the macOS one exists to stay put.
# Someone lowering "the floor" and touching only the pair they noticed would invert that silently.
# Checked with the installer's own version_lt, already extracted above.
mp_lin="$(sed -n 's/^MIN_PODMAN_LINUX="\([^"]*\)".*/\1/p' $PRIVATE/files/cs193v-ui.sh)"
mp_mac="$(sed -n 's/^MIN_PODMAN_MACOS="\([^"]*\)".*/\1/p' $PRIVATE/files/cs193v-ui.sh)"
assert_eq "min-podman:mac-floor-is-not-below-the-linux-one" "no" \
          "$(run_vl vl_ui "$mp_mac" "$mp_lin")"

# ─── the PATH repair is the same code in both copies  (issue #121) ─────────────
# ensure_podman_path is the third function the installer has to carry rather than source, and
# it is the one where a disagreement is worst: this script runs FIRST, reports success, and
# hands the student a launcher that runs LAST. If the two ever answer differently about where
# podman is, the student sees "Setup finished" followed by "Podman is not installed" -- which
# IS issue #121, and is what it looked like the first time.
# ONE COPY SINCE #221. This used to read the installer's own PODMAN_PKG_ID and compare it with
# the launcher's, because a disagreement between them WAS issue #121 all over again -- the
# installer runs first and reports success, the launcher runs last and cannot find podman. There
# is one declaration now and both read it, so the comparison has nothing to compare; what is
# left is that the shared file declares it exactly once and that nothing else declares one.
pkg_lnch="$(sed -n 's/^PODMAN_PKG_ID="\([^"]*\)".*/\1/p' $PRIVATE/files/cs193v-ui.sh)"
# NON-EMPTY FIRST, both of them, for the reason the floors above give: empty-vs-empty passes
# forever, and a renamed constant makes the sed match nothing.
assert_ne "probe:ui-declares-the-package-id"  "" "$pkg_lnch"
record    "probe:package-id" "$pkg_lnch"
assert_eq "probe:course-install-declares-no-package-id" "0" \
          "$(grep -c '^PODMAN_PKG_ID=' $PRIVATE/course-install.sh)"
assert_eq "probe:ui-declares-the-package-id-once"  "1" \
          "$(grep -c '^PODMAN_PKG_ID=' $PRIVATE/files/cs193v-ui.sh)"

# AND THE BODIES, not just the constant. carve_func's own header explains why an empty carving
# is the trap here: sourced, it asserts nothing and passes.
carve_func $PRIVATE/files/cs193v-ui.sh ensure_podman_path "$TMP/probe_ui.sh"
assert_ok "extract:probe_ui"  test -s "$TMP/probe_ui.sh"
# AND NOBODY ELSE CARRIES ONE. The byte-for-byte diff that used to live here compared the
# installer's copy with the launcher's; this is the assertion that catches a copy coming back.
assert_eq "probe:course-install-has-no-probe" "0" \
          "$(grep -c '^ensure_podman_path() {$' $PRIVATE/course-install.sh)"

# ─── and what that code actually decides  (issue #121) ─────────────────────────
# Driven against BOTH carvings, so a divergence that somehow survived the diff above still
# fails here, and against a fabricated receipt rather than this machine's -- see PROBE_PKG_ID.
#
# THE CARVINGS NEED THREE NAMES FROM THEIR HOME SCRIPT: PODMAN_PKG_ID, PODMAN_PATH_ADDED and
# platform(). platform() is supplied here rather than carved, because the two files' copies of
# it DIFFER in the unsupported-OS arm (the installer dies, the launcher prints "other") while
# both answer "macos" on Darwin -- which is the whole reason the gate could be spelled
# identically in both. Substituting it also makes the platform axis a parameter of the test
# instead of a fake uname.
IPROBE_PKG_ID="com.example.cs193v-not-a-real-package"

# run_probe CARVING PLATFORM -> "rc|PODMAN_PATH_ADDED|PATH"
#
# PLATFORM IS A PARAMETER rather than a faked uname, because that is the axis under test and
# because platform() itself cannot be carved: the two files' copies differ in the
# unsupported-OS arm (the installer dies, the launcher prints "other") while both answer
# "macos" on Darwin -- which is exactly why the gate could be spelled identically in both.
#
# THE CARVING GETS ITS THREE NAMES EXPLICITLY: the two globals it reads, and platform(). A
# subshell, so nothing it exports reaches the next case.
run_probe() {
    local carving="$1" plat="$2"
    (
        PODMAN_PKG_ID="$IPROBE_PKG_ID"
        PODMAN_PATH_ADDED=""
        PROBE_PLAT="$plat"
        platform() { printf '%s' "$PROBE_PLAT"; }
        PATH="$SHIM:$IFARM"
        # shellcheck source=/dev/null
        . "$carving" || { printf 'CARVING-DID-NOT-SOURCE'; exit; }
        ensure_podman_path; rc=$?
        printf '%s|%s|%s' "$rc" "$PODMAN_PATH_ADDED" "$PATH"
    )
}
p_rc()    { printf '%s' "${1%%|*}"; }
p_added() { local t="${1#*|}"; printf '%s' "${t%%|*}"; }
p_path()  { printf '%s' "${1##*|}"; }

# ONE CARVING NOW (#221), and the loop is kept rather than unrolled: every assertion below is
# named "probe:$f-...", so unrolling would rename twenty of them for no gain, and the shape is
# what a second consumer would be added back into.
# shellcheck disable=SC2043   # deliberately a one-element list; see above
for f in ui; do
    CARV="$TMP/probe_$f.sh"

    # ── present, off PATH, on a Mac ──
    shim_new
    shim_set version 5.7.0
    IOFF="$(shim_offpath_podman)"
    IFARM="$(shim_toolfarm)"
    shim_fake_pkgutil "$IPROBE_PKG_ID" "$IOFF"
    # BOTH HALVES OF THE FIXTURE, because either alone passes vacuously.
    assert_eq "probe:$f-fixture-hides-podman"      "" "$(PATH="$SHIM:$IFARM" command -v podman)"
    assert_ne "probe:$f-fixture-keeps-a-toolbox"   "" "$(PATH="$SHIM:$IFARM" command -v awk)"
    before="$SHIM:$IFARM"
    r="$(run_probe "$CARV" macos)"
    assert_eq "probe:$f-finds-a-podman-off-PATH"    "0"     "$(p_rc "$r")"
    assert_eq "probe:$f-records-which-directory"    "$IOFF" "$(p_added "$r")"
    # APPENDED: the directory is the LAST element, and deliberately not the first.
    assert_eq "probe:$f-appends-that-one-directory" "$IOFF" "$(p_path "$r" | sed 's/.*://')"
    assert_ne "probe:$f-does-not-prepend-it"        "$IOFF" "$(p_path "$r" | sed 's/:.*//')"
    # AND NOTHING ELSE. The whole PATH is the old one plus exactly one entry, so a copy that
    # helpfully added /usr/local/bin as well would fail here rather than pass the two above.
    assert_eq "probe:$f-adds-nothing-but-that"      "$before:$IOFF" "$(p_path "$r")"

    # ── the same machine, but not a Mac ──
    # THE CROSS-PLATFORM REQUIREMENT. The receipt still answers -- pkgutil is a real name on
    # some Linuxes -- and the repair must still not fire.
    r="$(run_probe "$CARV" linux)"
    assert_eq "probe:$f-does-nothing-on-linux"        "1"      "$(p_rc "$r")"
    assert_eq "probe:$f-records-nothing-on-linux"     ""       "$(p_added "$r")"
    assert_eq "probe:$f-leaves-linux-PATH-untouched"  "$before" "$(p_path "$r")"
    r="$(run_probe "$CARV" wsl)"
    assert_eq "probe:$f-does-nothing-on-wsl"          "1"      "$(p_rc "$r")"

    # ── no receipt at all ──
    shim_fake_pkgutil com.example.some-other-package "$IOFF"
    r="$(run_probe "$CARV" macos)"
    assert_eq "probe:$f-refuses-with-no-receipt"       "1"       "$(p_rc "$r")"
    assert_eq "probe:$f-leaves-PATH-alone-with-no-receipt" "$before" "$(p_path "$r")"

    # ── a receipt naming a directory that holds no podman ──
    # ALSO THE STALE-RECEIPT CASE: podman removed by hand leaves its receipt behind, and the
    # probe's -f test is what refuses it rather than appending a dead directory.
    mkdir -p "$SHIM/empty"
    shim_fake_pkgutil "$IPROBE_PKG_ID" "$SHIM/empty"
    r="$(run_probe "$CARV" macos)"
    assert_eq "probe:$f-refuses-a-receipt-with-no-podman" "1" "$(p_rc "$r")"

    # ── a podman that is there but not executable ──
    # The -x half. A half-extracted .pkg leaves a mode-644 binary, and `[ -x somedir ]` being
    # true for a directory is why -f alone would not answer this either.
    mkdir -p "$SHIM/notexec"
    cp "$IOFF/podman" "$SHIM/notexec/podman"
    chmod 644 "$SHIM/notexec/podman"
    assert_ok  "probe:$f-the-unrunnable-fixture-is-a-file" test -f "$SHIM/notexec/podman"
    assert_fail "probe:$f-the-unrunnable-fixture-is-not-runnable" test -x "$SHIM/notexec/podman"
    shim_fake_pkgutil "$IPROBE_PKG_ID" "$SHIM/notexec"
    r="$(run_probe "$CARV" macos)"
    assert_eq "probe:$f-refuses-a-non-executable-podman" "1" "$(p_rc "$r")"

    # ── a healthy PATH is left completely alone ──
    # THE CONTROL, and the cheapest guard against the whole thing firing when it should not:
    # podman is on PATH here, so the receipt is never consulted at all.
    shim_new
    shim_set version 5.7.0
    IFARM="$(shim_toolfarm)"
    shim_fake_pkgutil "$IPROBE_PKG_ID" "$SHIM"
    before="$SHIM:$IFARM"
    assert_ne "probe:$f-healthy-fixture-really-has-podman" "" \
              "$(PATH="$SHIM:$IFARM" command -v podman)"
    r="$(run_probe "$CARV" macos)"
    assert_eq "probe:$f-accepts-a-healthy-PATH"        "0"       "$(p_rc "$r")"
    assert_eq "probe:$f-records-nothing-when-healthy"  ""        "$(p_added "$r")"
    assert_eq "probe:$f-leaves-a-healthy-PATH-alone"   "$before" "$(p_path "$r")"
done

# ─── the menu answers the same keys in both copies ─────────────────────────────
# menu() is the second function the installer has to carry rather than source, and it had no
# check at all until setup-git made cs193v-ui.sh the third consumer.
#
# NOT A BYTE-FOR-BYTE DIFF, unlike box() and version_lt, and the reason is worth stating so
# nobody "fixes" it into one: the installer's copy is deliberately NOT verbatim. Its output is
# nested two columns deeper than the launcher's and its hint reads "up and down arrows, then
# Enter" rather than the longer form, because it prints inside an indented step list. Diffing
# the whole function would fail on that presentation difference forever, and the only way to
# make it pass would be to change how the installer looks.
#
# What must not drift is which KEYS work. A student who learns j/k or the digit shortcuts from
# one script and finds them dead in the other has been taught something false, and that is the
# realistic drift: someone teaches one copy a new key and never touches the other. So this
# compares the case block alone, indentation stripped.
# ONE COPY SINCE #221, so the diff that used to live here has nothing to compare. The key table
# is still extracted and asserted non-empty, because the pty cases below drive it and an empty
# carving would let them pass having exercised nothing.
sed -n '/^menu() {/,/^}$/p' "$PRIVATE/files/cs193v-ui.sh" \
    | sed -n '/case "\$key" in/,/esac/p' | sed 's/^[[:space:]]*//' > "$TMP/keys.ui"
# Extraction asserted first, or an empty file would match an empty file and this would pass
# forever having read nothing — the trap this suite records for version_lt above.
if [ "$(grep -c '.' "$TMP/keys.ui")" -ge 5 ]; then pass "menu:key-table-extractable"
else fail "menu:key-table-extractable" "could not find menu()'s case block in cs193v-ui.sh"; fi
assert_eq "menu:course-install-has-no-copy" "0" \
          "$(grep -c '^menu() {$' "$PRIVATE/course-install.sh")"
# The four things that table has to answer, named individually so a deletion says which.
assert_contains "menu:arrow-up-works"   '${ESC}[A' "$(cat "$TMP/keys.ui")"
assert_contains "menu:arrow-down-works" '${ESC}[B' "$(cat "$TMP/keys.ui")"
assert_contains "menu:enter-selects"    'break'    "$(cat "$TMP/keys.ui")"
assert_contains "menu:digits-select"    '[1-9]'    "$(cat "$TMP/keys.ui")"

# The macOS VM sizing formula. A Mac's containers run in a fixed-size VM that does not scale
# with the host, and podman's default of 2048 MB is too small for this course.
cat > "$TMP/vm.sh" <<'EOF'
MAC_VM_SHARE_PCT=50
MAC_VM_MAX_GB=8
MAC_VM_MIN_GB=4
host_ram_mb() { printf '%s' "$FAKE_RAM_MB"; }
EOF
sed -n '/^mac_vm_target_mb()/,/^}$/p' $PRIVATE/course-install.sh >> "$TMP/vm.sh"
vm_for() { ( . "$TMP/vm.sh"; FAKE_RAM_MB="$1" mac_vm_target_mb ); }
#  4 GB: 50% = 2, floored at 4 -> 4 GB (the whole Mac; a machine this small is out of scope)
#  8 GB: 50% = 4 -> 4 GB
# 12 GB: 50% = 6 -> 6 GB
# 16 GB: 50% = 8 -> 8 GB
# 32 GB: 50% = 16, capped at 8 -> 8 GB
# 64 GB and up: capped at 8 GB
#
# THE 12 GB CASE IS THE ONLY ONE THE SHARE DECIDES ON ITS OWN, which is why it is here even
# though Apple ships no 12 GB Mac. Every other row is pinned by a clamp -- 4 and 8 by the floor,
# 32 and up by the ceiling, and 16 by both at once, since 50% of 16 is exactly MAC_VM_MAX_GB.
#
# WHAT IT ACTUALLY CATCHES, measured by mutating MAC_VM_SHARE_PCT rather than guessed: a share
# of 60% is caught by this row and by NOTHING else in the table. 66% is also caught by the 8 GB
# row, and dropping the share arithmetic entirely is caught by the floor rows -- so the gap this
# closes is a percentage drifting a little above 50, which is exactly the edit someone would
# make by hand. Integer division sets the floor of the gap: 55% of 12 is still 6, so a change
# that small is invisible to every row here and would need a 24 GB one to see.
assert_eq "mac-vm:4GB-host"  "4096"  "$(vm_for 4096)"
assert_eq "mac-vm:8GB-host"  "4096"  "$(vm_for 8192)"
assert_eq "mac-vm:12GB-host" "6144"  "$(vm_for 12288)"
assert_eq "mac-vm:16GB-host" "8192"  "$(vm_for 16384)"
assert_eq "mac-vm:32GB-host" "8192"  "$(vm_for 32768)"
assert_eq "mac-vm:64GB-host" "8192"  "$(vm_for 65536)"
assert_eq "mac-vm:never-exceeds-the-cap" "8192" "$(vm_for 131072)"

# ─── the course files, served from a local tarball  (§A.12 needs this too) ─────
# BUILT BEFORE THE CONSENT CASES, not beside the idempotency ones it was written for, and
# that ordering is the whole point: the run below that reaches fetch_files used to use the
# UNEDITED installer, whose TARBALL is the real GitHub URL. So the cheap lane -- whose own
# header says "no podman, no image, no network" -- made a live request on every run, with
# `|| true` hiding whatever came back. Driven, not read: it reaches "Getting the course
# files" and prints the "Could not download" box in about a second, because a 404 is not a
# --retry condition. It becomes thirty seconds the day GitHub is unreachable.
#
# Shaped the way GitHub's archive endpoint shapes it -- a single top-level directory, which is
# why the installer strips one component -- AND HOLDING WHAT THAT ENDPOINT HOLDS, which is now
# true by construction rather than by maintenance: export_tree IS `git archive`, so this fixture
# is the 30 files a student really downloads (#115), tests and staff documents included out. The
# hand-written excludes it replaced carried the developer's projects/ in, so this gzipped 58 MB
# (#76), and they had already drifted from the archive in the other direction too.
export_tree "$TMP/pkg/cs193v-main"
( cd "$TMP/pkg" && tar czf "$TMP/course.tar.gz" cs193v-main )
assert_file "install:test-tarball-built" "$TMP/course.tar.gz"
cp $PRIVATE/install-cs193v.sh "$TMP/installer.sh"
edit_sub "$TMP/installer.sh" '^REPO_OWNER=.*' 'REPO_OWNER="test"'
edit_sub "$TMP/installer.sh" '^TARBALL=.*'    "TARBALL=\"file://$TMP/course.tar.gz\""
assert_ok "install:test-copy-is-valid-bash" bash -n "$TMP/installer.sh"

# ─── the cases that need the installer's LINUX arm ─────────────────────────────
# platform() (install-cs193v.sh:361) reads the real `uname -s`, and the Linux arm it selects then
# reads FILES: /etc/os-release to name the package manager, /etc/subuid for DO_SUBUID,
# /proc/version for WSL. $PATH can fake a command; it cannot fake a file. Faking `uname` alone was
# measured and is not enough -- the installer reaches "linux on x86_64" and then STOPs with "a
# Linux we do not recognise", because macOS has no /etc/os-release.
#
# So on a Mac these cases have nothing to measure: the installer correctly takes its macOS arm,
# where DO_SUBUID is never set and there is no subuid range to ask permission for. They used to
# FAIL there, which said "the code is wrong" about a machine behaving perfectly.
#
# THE SAME GROUND IS COVERED ON A REAL LINUX, in 26-installer-sandbox.sh: sb-consent:* and
# sb-subuid:* run this exact arm in a container with --no-prereqs=subuid, and are STRONGER than
# what is skipped here -- that fixture has real passwordless sudo, so `usermod` actually runs and
# the resulting /etc/subuid is asserted, where the synthetic root below can only check the command
# string. sb-old:* likewise covers podman-old:* against a real podman 3.4.4.
#
# NAMED SKIPS, NOT A SILENT BRANCH. VERIFICATION.md §A.15 records that a gate outside the default
# run is the same defect as an assertion that never executed, so every name still appears in the
# results with its reason.
linux_arm() { [ "$(uname -s)" = Linux ]; }
skip_linux_arm() {                    # skip_linux_arm NAME...
    local n
    for n in "$@"; do
        skip "$n" "needs the installer's Linux arm (files, not commands) -- covered on a real Linux in 26-installer-sandbox.sh"
    done
}

# ─── consent: nothing changes without a yes  (§1.2) ────────────────────────────
# menu() with no tty picks the DEFAULT, which for consent is "Stop, do not change
# anything". VERIFICATION.md §1.2 claims it falls back to numbered selection; it does not,
# and the behaviour it actually has is the safer one. This asserts the real behaviour.
# Something has to NEED consent, or there is no prompt to test. On a machine that already
# has podman and a subuid range, nothing does — so fake a username with no /etc/subuid
# entry. That drives the real DO_SUBUID branch and works on any machine, whereas assuming
# podman is absent only worked on a machine that happened not to have it.
if linux_arm; then
shim_new
shim_fake_id 1000 nosuchuser-cs193v
rm -rf "$TMP/boot-consent"; mkdir -p "$TMP/boot-consent"
run_consent() {
    installer_host "$TMP/installer.sh" CS193V_DIR="$TMP/consent" TMPDIR="$TMP/boot-consent"
}
out="$(run_consent)"
# BY KEY, AND ONCE. These were "Nothing was changed" and "contact course staff", which are
# the first and last sentences of ONE message -- so #219's rewording of consent.declined
# reddened the second and left the first passing, which is the least useful of the three
# possible outcomes. The whole body is a stronger needle than either and names neither.
assert_says_key "consent:non-tty-declines" consent.declined "$out" "$ICAT"
# NOTE: this one PASSED on macOS, and vacuously -- with nothing needing consent the installer
# runs to the end and exits 0 for an unrelated reason. It belongs inside the guard.
assert_eq   "consent:non-tty-exits-0"       "0" \
            "$(run_consent >/dev/null 2>&1; printf '%s' "$?")"
assert_no_file "consent:declining-creates-no-directory" "$TMP/consent"
# It must say WHAT it wants permission for, and why, before asking.
assert_says_key "consent:names-what-it-wants" need.subuid "$out" "$ICAT"
assert_says_key "consent:explains-why"        need.subuid.why "$out" "$ICAT"
# AND IT MUST LEAVE NOTHING OF THE COURSE ON A MACHINE WHOSE OWNER SAID NO. That used to be
# asserted as "it never reaches the download", which the #221 split inverts: the bootstrap now
# fetches the tree before this script exists to ask anything, so the transcript DOES say
# "Getting the course files" on a run that changes nothing. The old assertion is retired rather
# than reworded, and it is worth knowing it would not have caught the leak either way -- it sat
# inside this linux_arm guard, so on a Mac it never ran at all.
#
# The claim that replaces it is stronger, because it looks at the disk rather than the words:
# no student tree (above) and no temp tree (here). 26-installer-sandbox.sh asserts the same pair
# on a real Linux machine through ===BOOT-TMP===.
assert_eq "consent:declining-leaves-no-temp-tree" "" \
          "$(ls -d "$TMP/boot-consent"/cs193v-install.* 2>/dev/null)"
else
skip_linux_arm "consent:non-tty-declines" "consent:non-tty-exits-0" \
               "consent:declining-creates-no-directory" "consent:names-what-it-wants" \
               "consent:explains-why" "consent:declining-leaves-no-temp-tree"
fi

# With podman already present and a subuid range already there, nothing needs consent at
# all and the installer should say so rather than asking a pointless question.
shim_new
out="$(installer_host "$TMP/installer.sh" CS193V_DIR="$TMP/noconsent" || true)"
assert_says_key "consent:nothing-to-change-when-already-set-up" step.nothing-to-change \
                "$out" "$ICAT"
# THE VERSION IS THE ASSERTION, so it is rendered in rather than quoted with the prose around it.
assert_says_sub "consent:reports-the-existing-podman" ok.podman "$out" "$ICAT" V=5.7.0


# ─── run as root: refused before it looks at anything  (#226) ──────────────────
# THE INSTALLER'S COUNTERPART TO cs193v:801, and 30-launcher-shim.sh :: root:* is the model
# this copies. `sudo bash install-cs193v.sh` used to run all the way to build_image before
# anything objected -- and what objected there was the LAUNCHER's refusal, by which point
# $HOME was /root, the subuid range had been granted to root, and apt had run.
#
# FAKED, not real. `shim_fake_id 0 root` is the same instrument the launcher's case uses and
# for the same reason: nobody can run this suite as root, and the real `sudo bash
# install-cs193v.sh` stays a by-hand check in tests/MANUAL.md.
#
# NO linux_arm GUARD. This refusal reads `id -u` and nothing else, so it is reachable on every
# platform -- unlike the subuid and apt cases below.
shim_new
shim_fake_id 0 root
out="$(installer_host "$TMP/installer.sh" CS193V_DIR="$TMP/asroot")"
assert_says "root:refused" "STOP" "$out"
# BY KEY, NOT BY QUOTED PROSE, and that is the difference between this case and a vacuous one.
# Written as assert_says "sudo", every assertion here PASSED before the gate existed --
# because the run got all the way to build_image and it was the LAUNCHER's err.running-as-root
# that said "STOP" and "without sudo" (measured; #226's own anatomy). Only the installer's own
# key can distinguish the two, and assert_says_key FAILs on a key that does not exist.
assert_says_key "root:says-why" err.as-root "$out" "$PRIVATE/course-install-messages.txt"
# BEFORE THE SURVEY PRINTS ITS STEP LINE, which is what makes "before it looks at anything"
# a claim about the code rather than about this transcript. Being root is a property of the
# invocation, not of the computer, so it is not something the "Looking at your computer" step
# has any business reporting.
assert_says_not_key "root:refuses-before-it-looks" step.survey "$out" "$ICAT"
assert_no_signoff "root:does-not-claim-success" "$out"
assert_eq "root:exits-1" "1" \
          "$(installer_host_rc "$TMP/installer.sh" CS193V_DIR="$TMP/asroot2")"
# The three claims the refusal makes implicitly: nothing of the course on the disk, nothing
# asked of root, and podman never contacted -- the last being what proves it did not get as
# far as build_image, which is where the objection used to come from. sudo-fake and
# podman-fake both record without executing, so two empty logs are the whole assertion.
assert_no_file "root:creates-no-directory" "$TMP/asroot"
assert_eq "root:asks-root-nothing"   ""  "$(sudo_log)"
assert_eq "root:asks-podman-nothing" "0" "$(shim_count '.')"

# ─── the refusals, and the one place a lie would be worst ──────────────────────
# Four `die`s and one guard that nothing reached. All of them are non-tty-reachable
# because none of them gets as far as needing consent -- survey refuses first.
#
# NO_COLOR IS NOT HERE ON PURPOSE. The colour block asks `[ -t 1 ] && [ -z "$NO_COLOR" ]`,
# and every run in this suite reads its output through a command substitution, so stdout is
# a pipe and colour is already off. An assertion that NO_COLOR suppresses colour would pass
# without NO_COLOR doing anything. It needs a pty, and it waits for one.

# An operating system this script does not support must say so and stop, rather than
# guessing that anything not-Darwin is Ubuntu.
shim_new
shim_fake_uname FreeBSD amd64
out="$(installer_host "$TMP/installer.sh" CS193V_DIR="$TMP/bsd")"
# RENDERED, not truncated. err.unsupported-os LEADS with {{OS}}, so msg_text's needle would be
# "We have detected your operating system as" and stop -- which is the half that says nothing
# about what the script supports, and the list is what this assertion is named for. assert_says_sub
# fills {{OS}} in with the same value shim_fake_uname reports, so one needle covers both.
assert_says_sub "unsupported-os:says-what-it-supports" err.unsupported-os "$out" "$ICAT" \
                OS=FreeBSD
# STILL SPELLED OUT, and legitimately: "FreeBSD" is what the fake uname says, not catalogue
# prose, and the point is that the refusal echoes the machine back rather than guessing.
assert_says "unsupported-os:names-what-it-found"   "FreeBSD" "$out"
assert_no_file "unsupported-os:changes-nothing" "$TMP/bsd"
assert_eq "unsupported-os:exits-1" "1" \
          "$(installer_host_rc "$TMP/installer.sh" CS193V_DIR="$TMP/bsd2")"

# A podman older than MIN_PODMAN. version_lt is unit-tested above over twelve pairs; what
# this adds is that the comparison is WIRED to a refusal, and that the refusal tells a
# student how to fix it on their own platform.
# 4.3.1 rather than 4.9.3, and the change of number IS the change of floor. MIN_PODMAN_LINUX is
# 4.9.0 now, so 4.9.3 -- Ubuntu 24.04 LTS's podman -- is an ACCEPTED machine and cannot be the
# refusal case any more. 4.3.1 is Debian 12 bookworm's, which is the oldest thing still plausibly
# under a student and is genuinely below the floor.
#
# THE REFUSAL IS FORKED THREE WAYS AND THIS RUNS ON THE REAL HOST, which is what the first
# version of these three assertions missed. installer_host runs the shipped installer here, on
# this machine: the podman VERSION is faked, but the PLATFORM and the DISTRO FAMILY are not, and
# both change what the refusal says.
#
#   debian family   the floor is MIN_PODMAN_LINUX and the fix is apt's --only-upgrade
#   fedora family   the same floor, and the fix is `sudo dnf upgrade podman`
#   macOS           a DIFFERENT floor (MIN_PODMAN_MACOS), and the answer is not upgrade at all --
#                   it is remove-and-rerun, because this script installs a pinned .pkg rather
#                   than whatever Podman Desktop ships this week
#
# So a literal `only-upgrade podman` was only ever green on a Debian-family Linux. It was red on
# Fedora, and red on a Mac -- the platform the suite exists to settle VERIFICATION.md §5.2/§5.3 on.
#
# THE EXPECTATIONS COME OUT OF THE INSTALLER, not out of this file. install-cs193v.sh sources
# nothing and cannot be sourced -- a student downloads that one file and checks its published
# SHA-256 -- so carve_func is how a test reads its values without keeping a second copy of them
# that can drift. Three functions rather than one, because distro_family needs os_release_field.
#
# OUT OF install-utils.sh SINCE #217, not course-install.sh. The table and the steps that need
# root moved there when the root pass that prepares a new CS193V WSL instance became a second
# reader of them -- which is the same reason this carve exists: one copy of a package name.
carve_func $PRIVATE/install-utils.sh os_release_field "$TMP/orf.sh"
carve_func $PRIVATE/install-utils.sh distro_family    "$TMP/df.sh"
carve_func $PRIVATE/install-utils.sh distro_packages  "$TMP/dp.sh"
for f in orf df dp; do
    if [ -s "$TMP/$f.sh" ]; then pass "extract:$f"
    else fail "extract:$f" "could not carve the distro helpers out of install-utils.sh"; fi
done
# The PM_/PKG_ globals are pre-set to empty because distro_packages leaves them untouched for a
# family it does not know, and this suite runs under `set -u`.
host_upgrade_cmd() {                  # host_upgrade_cmd -> $PM_UPGRADE for THIS machine
    (
        . "$TMP/orf.sh"; . "$TMP/df.sh"; . "$TMP/dp.sh"
        PM_REFRESH=''; PM_INSTALL=''; PM_UPGRADE=''
        PKG_PODMAN=''; PKG_UIDMAP=''; PKG_SSH=''; PKG_CURL=''; PKG_CA=''
        distro_packages "$(distro_family)"
        printf '%s' "$PM_UPGRADE"
    )
}

shim_new
shim_set version "podman version 4.3.1"
out="$(installer_host "$TMP/installer.sh" CS193V_DIR="$TMP/old")"
# Darwin is the same thing platform() keys its macos arm off, so this forks where it forks.
if [ "$(uname -s)" = Darwin ]; then
    po_floor="$(sed -n 's/^MIN_PODMAN_MACOS="\([^"]*\)".*/\1/p' $PRIVATE/files/cs193v-ui.sh)"
    po_key=err.podman-old-mac
    # THE REMEDY IS A NESTED MESSAGE ON THIS ARM rather than a table entry: the Mac branch picks
    # how-homebrew or how-pkg from where `command -v podman` found it, and under this fixture that
    # is the shim, so how-pkg. Read back out of the catalogue the way the Linux verb is read out of
    # the table -- the literal that used to sit here could not fail its own non-empty check.
    # THE TAIL of it, because the head holds {{WHERE}}, the one value this case cannot predict as
    # it will APPEAR -- see the needle below.
    po_fix="$(msg_text_tail err.podman-old-mac.how-pkg "$ICAT")"
else
    po_floor="$(sed -n 's/^MIN_PODMAN_LINUX="\([^"]*\)".*/\1/p' $PRIVATE/files/cs193v-ui.sh)"
    po_key=err.podman-old-linux
    po_fix="$(host_upgrade_cmd)"
fi
record "podman-old:the-branch-measured-here" "$(uname -s) / ${po_key}"
# Both non-empty first. An empty needle would make assert_says pass against any output at all,
# which is the trap this file's own header records for version_lt.
assert_ne "podman-old:the-floor-was-readable" "" "$po_floor"
assert_ne "podman-old:the-fix-was-readable"   "" "$po_fix"
# ONE RENDERED MESSAGE WHERE THERE WERE THREE QUOTES, and all three of the values stay: the floor
# and the remedy were already read out of the installer ($po_floor, $po_fix above) and 4.3.1 is
# what this case faked. What is gone is the prose between them.
#
# AND THE KEY IS FORKED WITH THE FLOOR, which is #261. check_podman's macOS arm prints
# err.podman-old-mac -- a different floor, and remove-and-rerun rather than upgrade -- so naming
# the linux key here built a needle no Mac run can print, down to a closing sentence about a Linux
# release being too old. The branch was already RECORDED above and the floor already forked; the
# key was the one thing left reading the other arm.
if [ "$po_key" = err.podman-old-mac ]; then
    # THE NEEDLE STOPS AT {{HOW}}, and that is box() rather than a concession. how-pkg
    # interpolates `command -v podman`, which under this fixture is the shim's temp directory --
    # 81 columns of it here, with no space to break at. box() breaks a token like that HARD at
    # column 67 (BOX_W less its walls) and _flatten turns the break into a space INSIDE the path,
    # so a needle carrying the unbroken path matches nothing. Measured both ways: the whole-message
    # spelling fails here and PASSES where TMPDIR is short enough to keep the line under 67, which
    # is green on some machines and red on others -- worse than either.
    #
    # Everything BEFORE {{HOW}} is hand-wrapped catalogue prose plus 4.3.1 and the floor, and it
    # carries the remove-and-rerun sentence, so the three values this case is about are all in it.
    po_needle="$(_flatten "$(msg_of_in "$ICAT" "$po_key" V=4.3.1 "MIN=$po_floor" 'HOW=@@CUT@@')")"
    po_needle="${po_needle%%@@CUT@@*}"; po_needle="${po_needle% }"
    # assert_says_sub's own two guards, which this arm does not go through: a key that vanished
    # must be REPORTED rather than searched for, and an empty needle passes against anything.
    case "$po_needle" in
        ''|*'(missing message'*|*'{{'*)
            fail "podman-old:refused" "no rendered prose for message key: $po_key" ;;
        *)  assert_says "podman-old:refused" "$po_needle" "$out" ;;
    esac
    # AND THE REMEDY, which the needle above stops short of. Nothing in this suite asserted
    # err.podman-old-mac or either of its how-* children before -- the only mention of the key in
    # the tree was a comment -- so this is the half of #261 that was never covered at all rather
    # than merely mis-keyed, and it is why a wrong key here went unnoticed.
    #
    # BY KEY AND NOT WITH $po_fix, though they build the same needle: assert_says takes an EMPTY
    # needle as a match, so deleting how-pkg made this pass while the-fix-was-readable carried the
    # whole failure. Measured -- the keyed form reports the key instead.
    assert_says_key_tail "podman-old:says-how-to-remove-it" err.podman-old-mac.how-pkg \
                         "$out" "$ICAT"
else
    assert_says_sub "podman-old:refused" "$po_key" "$out" "$ICAT" \
                    V=4.3.1 "MIN=$po_floor" "UPGRADE=$po_fix"
fi
assert_no_file "podman-old:changes-nothing" "$TMP/old"

# podman missing entirely is NOT here, and the reason is worth writing down rather than
# quietly dropping. The shim's whole job is to BE podman, and taking the fake away just
# exposes the REAL /usr/bin/podman that `command -v` then finds -- so the branch cannot be
# reached from a PATH shim at all, only from a machine that genuinely has no podman. That is
# a fixture container, so both consent wordings (the macOS "installs system-wide" fork and
# the Ubuntu "needs your password" one) wait for the install tier rather than being faked
# badly here.
#
# THE SAME SENTENCE NOW COVERS THREE MORE PREREQUISITES, and it is written out so nobody spends
# an afternoon trying to fake one here. curl, and the setuid newuidmap/newgidmap helpers, are
# probed with `command -v` exactly as podman is, so prepending a shim cannot hide the real ones
# either. Their cases are `no-prereqs=curl` and `no-prereqs=uidmap` in 26-installer-sandbox.sh,
# where apt really removes the package and the installer really puts it back.

# A destination it cannot create. Not a fake: a directory mode 555 is a real unwritable
# parent, which is what a student hits when they point this at somewhere they do not own.
shim_new
mkdir -p "$TMP/ro" && chmod 555 "$TMP/ro"
out="$(installer_host "$TMP/installer.sh" CS193V_DIR="$TMP/ro/sub")"
assert_no_signoff "unwritable-dest:does-not-claim-success" "$out"
assert_eq "unwritable-dest:exits-1" "1" \
          "$(installer_host_rc "$TMP/installer.sh" CS193V_DIR="$TMP/ro/sub")"
chmod 755 "$TMP/ro"

# podman INSTALLED BUT NOT WORKING, which is a different machine from podman absent and wants
# its own case rather than emerging from another one by accident. A person driving the install
# tier's no-podman fixture by hand hit this: apt installs podman, check_podman asks it a
# question, and it cannot answer -- and I described that as the only place the branch was
# reachable. It is not. podman-fake has had an info_rc knob all along, so the branch costs a
# millisecond here, deliberately, on any machine.
shim_new
shim_set info_rc 1
out="$(installer_host "$TMP/installer.sh" CS193V_DIR="$TMP/nopodman")"
# ONE ASSERTION, BY KEY. err.podman-mute is two lines -- the diagnosis and the Mac fix -- and
# these quoted one each, so a reworded second line would redden half of a message that printed
# perfectly. podman-mute:suggests-the-mac-fix is retired into this; the body carries both.
assert_says_key "podman-mute:refuses-to-continue" err.podman-mute "$out" "$ICAT"
assert_says_key "podman-mute:changed-nothing-more"  die.trailer "$out" "$ICAT"
assert_no_signoff "podman-mute:does-not-claim-success" "$out"
assert_eq "podman-mute:exits-1" "1" \
          "$(installer_host_rc "$TMP/installer.sh" CS193V_DIR="$TMP/nopodman2")"

# THE WORST POSSIBLE LIE, and the one smoke_test exists to prevent: a build that produced
# no image, reported over the words "Setup finished". The installer's own comment calls this
# ERRORS.md A6's shape -- a truncated download that passed.
shim_new
shim_set image_exists no
out="$(installer_host "$TMP/installer.sh" CS193V_DIR="$TMP/noimage")"
assert_says_key "no-image:refuses-to-claim-success" err.image-missing-after-build "$out" "$ICAT"
assert_no_signoff "no-image:does-not-say-finished" "$out"
# THE FAR SIDE OF {{DIR}}, which is where the command they are asked for sits. Quoted as
# "doctor" this matched the word anywhere in the transcript -- ok.doctor-runs says it too, on
# the success path -- so the needle is the catalogue's own tail rather than one word of it.
assert_says_key_tail "no-image:tells-them-what-to-send-staff" err.image-missing-after-build \
                     "$out" "$ICAT"

# ─── everything behind the consent menu  (§1.2's other half) ────────────────────
# menu() takes the safe default when stdin or stdout is not a terminal, so with no tty
# ask_consent DECLINES and returns -- which is why nothing in this suite had ever executed
# install_podman, setup_subuid, setup_wslconf or setup_machine's resize arm. A pty is not a
# nicety here, it is the only way past line one of every host-changing step.
#
# The resize is the vehicle for "consent accepted" rather than the subuid range, and that is
# deliberate: it needs consent, it executes a real branch on the far side, and it leaves the
# rest of the run intact. Forcing consent with a faked `id` instead makes the launcher's own
# preflight refuse later (the faked user has no /etc/subuid entry), so the run cannot reach
# the end and "Setup finished" stops being assertable.

# Down-arrow then Enter: the path a student actually takes, escape sequence and all.
shim_new; shim_fake_mac
# machine_list and machine_mem are shim FILES, not environment variables. An existing
# machine that is too small is the only thing on this host that needs consent AND leaves the
# rest of the run working -- but handed to installer_tty as env vars they did nothing, the
# survey found no machine, nothing needed permission, and the run sailed straight past the
# menu. "It finished" passed while every assertion about the resize failed.
shim_set machine_list podman-machine-default; shim_set machine_mem 4096
out="$(installer_tty '\033[B\n' "$TMP/installer.sh" CS193V_DIR="$SHIM/dest" | strip_ansi)"
assert_says_key "consent-yes:the-arrow-moved-the-selection" menu.consent.go "$out" "$ICAT"
# RENDERED, because 8192 is what the code decided rather than what the catalogue says.
# step.machine-resize is "Resizing podman's virtual machine to {{WANT}} MB", so the prose comes
# from the file and only the number is the assertion.
assert_says_sub "consent-yes:the-resize-ran" step.machine-resize "$out" "$ICAT" WANT=8192
assert_says_key "consent-yes:reports-the-resize" ok.machine-resized "$out" "$ICAT"
assert_says_key "consent-yes:finishes"           "$FINISHED_KEY" "$out" "$ICAT"
# The far side of the branch, in argv rather than prose. setup_machine must STOP the machine
# before setting memory -- podman refuses to change a running one -- and start it again.
assert_says "consent-yes:stopped-before-setting" "machine stop"              "$(installer_log)"
assert_says "consent-yes:set-the-memory"         "machine set --memory 8192" "$(installer_log)"
assert_says "consent-yes:started-again"          "machine start"              "$(installer_log)"
# Nothing on this path needs root, so the fake sudo must have been left alone entirely.
assert_eq "consent-yes:needed-no-privilege" "" "$(sudo_log)"

# Enter on its own leaves the default selected, which is the refusal.
shim_new; shim_fake_mac
shim_set machine_list podman-machine-default; shim_set machine_mem 4096
out="$(installer_tty '\n' "$TMP/installer.sh" CS193V_DIR="$SHIM/dest" | strip_ansi)"
assert_says_key "consent-no:declines-on-a-tty" consent.declined "$out" "$ICAT"
assert_says_not "consent-no:the-log-shows-no-resize" "machine set" "$(installer_log)"
assert_says     "consent-no:the-log-was-really-read" "machine list" "$(installer_log)"

# The digit shortcut. The key TABLE is diffed against the launcher's copy above, which proves
# the digits are listed; this proves they work in the installer's own copy.
shim_new; shim_fake_mac
shim_set machine_list podman-machine-default; shim_set machine_mem 4096
out="$(installer_tty '2' "$TMP/installer.sh" CS193V_DIR="$SHIM/dest" | strip_ansi)"
assert_says_key "consent-digit:selects-and-accepts" ok.machine-resized "$out" "$ICAT"

# ─── setup_subuid, executing for the first time ────────────────────────────────
# The one privileged call reachable from here. sudo-fake records it and runs nothing, so what
# is asserted is the command the installer WOULD have run as root -- the range included,
# because a wrong range is a silent failure much later, inside podman.
if linux_arm; then
shim_new; shim_fake_id 1000 nosuchuser-cs193v
out="$(installer_tty '2' "$TMP/installer.sh" CS193V_DIR="$SHIM/dest" | strip_ansi)"
assert_says_key "subuid:step-announced" step.subuid "$out" "$ICAT"
assert_says_sub "subuid:reports-success" ok.subuid "$out" "$ICAT" USER=nosuchuser-cs193v
assert_says "subuid:asks-root-for-the-right-range" \
            "usermod --add-subuids 200000-265535 --add-subgids 200000-265535 nosuchuser-cs193v" \
            "$(sudo_log)"
# This run cannot reach the end and that is correct rather than a gap: the faked account has
# no real /etc/subuid entry, so the launcher's own preflight refuses at --rebuild. Recorded
# so the reason is visible instead of looking like a missing assertion.
record "subuid:what-happens-after-a-faked-usermod" \
       "$(printf '%s' "$out" | grep -cF "$(msg_text "$FINISHED_KEY" "$ICAT")") finished-lines"

# ...and when root refuses. The die must name the account and tell them what to send staff.
shim_new; shim_fake_id 1000 nosuchuser-cs193v; shim_set sudo_fail usermod
out="$(installer_tty '2' "$TMP/installer.sh" CS193V_DIR="$SHIM/dest" | strip_ansi)"
# RENDERED WITH THE ACCOUNT, which is what this pair was really about: a refusal that names
# the wrong account, or no account, is the failure worth catching. The needle is the whole
# message with {{USER}} filled in, so it covers the sentence the old
# subuid-fails:says-what-to-send quoted as well -- that name is gone because #219 reworded the
# paragraph it pointed at and nothing about it was separately assertable afterwards.
assert_says_sub "subuid-fails:names-the-account" err.subuid-failed "$out" "$ICAT" \
                USER=nosuchuser-cs193v
assert_says_not_key "subuid-fails:does-not-claim-success" ok.subuid "$out" "$ICAT"
else
# subuid-fails:* is the one pair with NO container equivalent yet: it needs a sudo that works for
# everything except `usermod`, and SB_SUDO offers only nopasswd/password/deny/absent -- `deny`
# takes sudo away entirely and the installer would fail earlier for a different reason.
skip_linux_arm "subuid:step-announced" "subuid:reports-success" "subuid:asks-root-for-the-right-range" \
               "subuid-fails:names-the-account" "subuid-fails:does-not-claim-success"
fi

# ─── and the same usermod, EXECUTED, against a synthetic root ──────────────────
#
# WHY THIS IS HERE RATHER THAN IN A CONTAINER. `--no-prereqs=subuid` and "the install succeeded"
# are mutually exclusive inside a container and no flag design fixes it: setup_subuid writes a
# fixed 200000-265535 (installer:653), which lies outside the outer container's 1..65536 userns
# window, so podman cannot work afterwards THERE while it would on a student's laptop. A case
# that can only ever claim half a run is the shape that produced the no-podman conflation, so the
# container case was dropped -- and this is where the coverage it gave up went.
#
# WHAT IT ADDS over the argv assertion above: that one proves the installer ASKS for the right
# command. This one runs the real /usr/sbin/usermod and proves the command DOES what the
# installer needs -- which nothing had ever checked.
#
# --prefix, NOT --root, and measured both ways: --root chroots, which is Operation-not-permitted
# even under `bwrap --unshare-user --uid 0 --cap-add ALL`. --prefix edits the shadow files under a
# directory with no chroot at all -- and then needs NO privilege either, so this needs no bwrap,
# no sudo and no container. It writes only inside $TMP.
if ! command -v usermod >/dev/null 2>&1; then
    # A NAMED SKIP, not a silent pass: a TA's Mac has no shadow suite at all, and a skip that
    # says so is the difference between "not applicable here" and "quietly stopped testing".
    skip "usermod:really-adds-the-range" "no usermod on this machine (macOS has no shadow suite); tests/MANUAL.md covers it there"
else
UM="$TMP/fakeroot"
# SYNTHETIC, not a copy of this machine's /etc: the case then depends on nothing about the host
# and copies none of its accounts. uid 4242 so it cannot collide with anything real either.
mkdir -p "$UM/etc"
printf 'root:x:0:0:root:/root:/bin/sh\nstudent:x:4242:4242:,,,:/home/student:/bin/bash\n' > "$UM/etc/passwd"
printf 'root:x:0:\nstudent:x:4242:\n' > "$UM/etc/group"
printf 'root:!:20000:0:99999:7:::\nstudent:!:20000:0:99999:7:::\n' > "$UM/etc/shadow"
printf 'root:*::\nstudent:!::\n' > "$UM/etc/gshadow"
: > "$UM/etc/subuid"; : > "$UM/etc/subgid"

# THE RANGE IS PARSED OUT OF THE INSTALLER, not typed here, so changing the constant reddens
# this instead of leaving a test that agrees with a number nobody uses any more.
# READ AS THE CONSTANT IT IS NOW, not out of the usermod line (#217). The range used to be a
# literal inside setup_subuid, so this sed had to reach into the command; it is SUBUID_RANGE in
# install-utils.sh since the root pass became a second caller of the same step, and a named
# constant is what the two callers cannot disagree about.
UM_RANGE="$(sed -n 's/^SUBUID_RANGE="\([0-9]*-[0-9]*\)".*/\1/p' "$PRIVATE/install-utils.sh" | head -1)"
assert_match "usermod:the-range-came-from-the-installer" '^[0-9]+-[0-9]+$' "$UM_RANGE"
UM_START="${UM_RANGE%-*}"; UM_END="${UM_RANGE#*-}"
UM_COUNT=$(( UM_END - UM_START + 1 ))

# THE VACUITY GUARD, FIRST AND EXPLICITLY. Every assertion below reads a file that this case
# also writes, so "the range is in there" would pass on a run where usermod never executed and
# the fixture had simply been seeded with the answer. Asserted empty before, and a CONTROL root
# that usermod is never pointed at is asserted still empty after -- so a pass needs the command
# to have done it.
assert_eq "usermod:the-synthetic-root-starts-with-no-range" "" "$(cat "$UM/etc/subuid")"
mkdir -p "$TMP/control/etc"; : > "$TMP/control/etc/subuid"

if usermod --prefix "$UM" --add-subuids "$UM_RANGE" --add-subgids "$UM_RANGE" student \
       > "$TMP/usermod.out" 2>&1; then
    pass "usermod:exits-0"
else
    fail "usermod:exits-0" "$(cat "$TMP/usermod.out")"
fi

# 1. THE EFFECT the installer needs, in both files, as an exact value. A wrong range is a silent
#    failure much later, inside podman.
assert_eq "usermod:writes-the-range-into-subuid" "student:$UM_START:$UM_COUNT" "$(cat "$UM/etc/subuid")"
assert_eq "usermod:writes-the-range-into-subgid" "student:$UM_START:$UM_COUNT" "$(cat "$UM/etc/subgid")"
assert_eq "usermod:left-the-control-root-alone"  "" "$(cat "$TMP/control/etc/subuid")"

# 2. THE WRITTEN FORM IS WHAT THE LAUNCHER LATER GREPS FOR, and this is the one place both halves
#    are visible at once. setup_subuid writes the file; cs193v:1073 reads it back with
#    `grep -q "^$(id -un):"` and dies if it does not match. Nothing had ever checked that those
#    two agree -- a usermod that wrote "student 200000 65536" would satisfy every assertion above
#    and refuse every launch. THE PATTERN IS BUILT THE WAY THE LAUNCHER BUILDS IT, from a
#    checked-in grep rather than a copy of it, so a change to either side reddens here.
# THE LAUNCHER'S SIDE IS PINNED BY ITS EXACT TEXT rather than extracted with a regex, which is
# both simpler and stronger: if cs193v starts reading the file some other way, this reddens and
# somebody re-checks that the two still agree instead of the check silently passing on a pattern
# that no longer exists.
um_grep='grep -q "^$(id -un):" /etc/subuid'
if grep -qF "$um_grep" "$REPO/cs193v"; then
    pass "usermod:the-launcher-still-reads-it-back-this-way"
else
    fail "usermod:the-launcher-still-reads-it-back-this-way" \
         "cs193v no longer contains: $um_grep -- re-check that what usermod writes is what it accepts"
fi
if grep -q "^student:" "$UM/etc/subuid"; then
    pass "usermod:the-form-it-writes-is-the-form-the-launcher-accepts"
else
    fail "usermod:the-form-it-writes-is-the-form-the-launcher-accepts" \
         "the launcher greps ^USER: and this would not match: $(cat "$UM/etc/subuid")"
fi

# 3. THE BLAST RADIUS, which is what the dropped container case's expected-path set was the only
#    thing pinning. Measured rather than assumed: --add-subuids touches subuid and subgid and
#    their `-` backups, and NOT passwd, shadow, group or gshadow -- so a future usermod that
#    started rewriting the password database would redden here.
# BY THE FILE SET, not by mtime: usermod's `-` backups are copies that keep the original's
# timestamp, so `find -newer` reported neither of them and the audit missed two files it exists
# to notice.
um_files="$( cd "$UM" && find . -type f | LC_ALL=C sort | do_tr '\n' ' ' )"
assert_eq "usermod:created-only-the-two-backups" \
          "./etc/group ./etc/gshadow ./etc/passwd ./etc/shadow ./etc/subgid ./etc/subgid- ./etc/subuid ./etc/subuid- " \
          "$um_files"
# ...and the password database really is byte-identical, which is the half a file list cannot say
# and the half that would matter if a future usermod started rewriting more than it was asked to.
assert_eq "usermod:left-etc-passwd-byte-identical" \
          "root:x:0:0:root:/root:/bin/sh
student:x:4242:4242:,,,:/home/student:/bin/bash" "$(cat "$UM/etc/passwd")"
assert_eq "usermod:left-etc-shadow-byte-identical" \
          "root:!:20000:0:99999:7:::
student:!:20000:0:99999:7:::" "$(cat "$UM/etc/shadow")"
fi

# ─── choose_dir, which only exists on a tty ────────────────────────────────────
# CS193V_DIR IS DELIBERATELY UNSET for these four, which is the whole reason installer_host
# and installer_tty redirect HOME: with it unset, DEFAULT_DIR is $HOME/cs193v and the
# installer really does mkdir, untar and chmod there. Nothing on this path needs privilege,
# so HOME is the only thing standing between these cases and the developer's home directory.
# Each asserts the destination it landed on, so a case that escaped the door fails loudly.
shim_new
out="$(installer_tty '\n' "$TMP/installer.sh" | strip_ansi)"
assert_says "choosedir:enter-takes-the-default" "$SHIM/home/cs193v" "$out"
assert_ok   "choosedir:default-really-created"  test -x "$SHIM/home/cs193v/cs193v"
assert_says_key "choosedir:default-finishes"        "$FINISHED_KEY" "$out" "$ICAT"

shim_new
out="$(installer_tty "2$SHIM/typed\n" "$TMP/installer.sh" | strip_ansi)"
assert_says "choosedir:typed-path-is-used"   "$SHIM/typed" "$out"
assert_ok   "choosedir:typed-path-created"   test -x "$SHIM/typed/cs193v"

shim_new
out="$(installer_tty '2\n' "$TMP/installer.sh" | strip_ansi)"
assert_says "choosedir:empty-input-falls-back" "$SHIM/home/cs193v" "$out"
assert_ok   "choosedir:fallback-created"       test -x "$SHIM/home/cs193v/cs193v"

shim_new
out="$(installer_tty '2~/elsewhere\n' "$TMP/installer.sh" | strip_ansi)"
assert_says "choosedir:tilde-is-expanded"    "$SHIM/home/elsewhere" "$out"
assert_ok   "choosedir:tilde-target-created" test -x "$SHIM/home/elsewhere/cs193v"
# NOT asserted: that "~/elsewhere" is absent from the transcript. A pty echoes the keys this
# test feeds it, so the literal string is there whatever the installer did with it -- the
# assertion would have been reporting on its own input. The exact expanded path above, plus a
# launcher existing at it, is the evidence.

# ─── colour, which needs a terminal to mean anything ───────────────────────────
# Not asserted anywhere before now, and it could not be: every other run in this file reads
# its output through a command substitution, so stdout is a pipe, `[ -t 1 ]` is false and
# colour is already off. An assertion there would have passed with NO_COLOR doing nothing.
shim_new
# BEFORE "Building the course container", which is where the installer hands over to the
# launcher: what it prints past that point is cs193v's colour decision rather than this
# script's, and this assertion is about this script's.
#
# AND THE NEEDLE IS AN SGR SEQUENCE, not any ESC[ at all, which is what NO_COLOR actually
# governs. The window used to carry that job as well -- "the launcher's progress meter draws
# cursor escapes on a tty of its own accord" -- and that stopped working the moment the
# INSTALLER had a progress block of its own (#219), because cursor_hide and ESC[K fire whatever
# NO_COLOR says and now fire before the hand-over. Keying on `ESC[...m` says what was meant all
# along, and it keeps both halves honest: with colour on, step() emits ESC[36m, so the positive
# arm cannot be satisfied by a cursor move either.
pre() { sed -n '1,/Building the course container/p'; }
SGR="$(printf '\033')\[[0-9;]*m"
raw="$(installer_tty '\n' "$TMP/installer.sh" CS193V_DIR="$SHIM/dest" | pre)"
if printf '%s' "$raw" | grep -q "$SGR"; then pass "colour:on-with-a-terminal"
else fail "colour:on-with-a-terminal" "no colour sequences in a pty transcript"; fi
assert_says_key "colour:the-coloured-run-got-that-far" step.survey "$raw" "$ICAT"

shim_new
raw="$(installer_tty '\n' "$TMP/installer.sh" NO_COLOR=1 CS193V_DIR="$SHIM/dest" | pre)"
if printf '%s' "$raw" | grep -q "$SGR"; then
    fail "colour:NO_COLOR-suppresses-it" "colour sequences survived NO_COLOR=1"
else pass "colour:NO_COLOR-suppresses-it"; fi
# ...and the run really ran, so the check above is not passing on an empty transcript.
assert_says_key "colour:NO_COLOR-run-got-that-far" step.survey "$raw" "$ICAT"

DEST="$TMP/dest"
# A TMPDIR OF ITS OWN, so "did the bootstrap clean up after itself" is answerable (#221). The
# bootstrap unpacks the tree into `mktemp -d "${TMPDIR:-/tmp}/cs193v-install.XXXXXX"`, and the
# name is random -- so the only way to ask about it is to own the directory it goes in. The
# real /tmp cannot answer: any other run's leftovers would read as this run's leak.
BOOTTMP="$TMP/boot"; mkdir -p "$BOOTTMP"
boot_leftovers() { ls -d "$BOOTTMP"/cs193v-install.* 2>/dev/null; }
# AND TMPDIR IS REALLY THE ONE IT USES, proved through the refusal rather than by finding the
# directory afterwards. That distinction is the whole reason this assertion exists: a successful
# run is SUPPOSED to leave nothing behind, so "I looked and found no tree" is what a leak-free
# run and a run that unpacked somewhere else entirely both look like -- and the second would make
# the removal check below vacuously green. Pointing TMPDIR at something mktemp -d cannot create
# makes the bootstrap say so, which only a bootstrap that consulted it can do.
shim_new
assert_says "install:the-bootstrap-unpacks-under-TMPDIR" "temporary directory" \
            "$(installer_host "$TMP/installer.sh" CS193V_DIR="$TMP/nodest" \
                              TMPDIR="$TMP/no-such-tmpdir")"
assert_ok "install:and-that-run-created-no-course-directory" test ! -d "$TMP/nodest"

shim_new
run_installer() { installer_host "$TMP/installer.sh" CS193V_DIR="$DEST" TMPDIR="$BOOTTMP"; }
out1="$(run_installer)"
assert_says_key "install:first-run-finishes"     "$FINISHED_KEY"  "$out1" "$ICAT"
# AND THE TREE IS GONE. `exec` takes the bootstrap's EXIT trap with it, so from the hand-over on
# the only thing that can remove the unpacked tree is course-install.sh itself. A leak here is a
# full copy of the repo left in /tmp by every install anyone ever runs.
assert_eq "install:the-bootstrap-temp-tree-is-removed" "" "$(boot_leftovers)"
assert_says_key "install:first-run-fetched"      step.fetch    "$out1" "$ICAT"
assert_file "install:launcher-installed"     "$DEST/cs193v"
assert_exec "install:launcher-executable"    "$DEST/cs193v"
assert_file "install:args-installed"         "$DEST/.config/container.args"
assert_file "install:messages-installed"     "$DEST/.private/messages.txt"
assert_ok   "install:projects-dir-created"   test -d "$DEST/projects"
# THE FAR SIDE OF {{DIR}}, which is where the command a student types sits: [[finished]] is
# "cd {{DIR}} && ./cs193v", so msg_text stops before the command and msg_text_tail is the half
# that has it. Quoted as "./cs193v" this matched several other messages as well.
assert_says_key_tail "install:tells-them-how-to-start" "$FINISHED_KEY" "$out1" "$ICAT"
# ...and the UNIX run is the UNIX one: the Windows step must not leak into it.
assert_says_not_key "install:no-wsl-step-without-the-flag" finished.windows "$out1" "$ICAT"
assert_says_not_key "install:no-start-menu-step-without-the-flag" \
                    finished.windows-shortcut "$out1" "$ICAT"

# Now the actual §A.12 property. Everything except projects/ must be byte-identical: the
# second run recomputes nothing and rewrites nothing.
state_hash() {
    ( cd "$DEST" && find . -type f -not -path './projects/*' -not -name '*.log' \
        -exec sha256sum {} + 2>/dev/null | LC_ALL=C sort )
}
state_hash > "$TMP/s1"
# Something a student would have created between runs, which must survive.
mkdir -p "$DEST/projects/my-app" && echo 'my work' > "$DEST/projects/my-app/index.js"
out2="$(run_installer)"
state_hash > "$TMP/s2"

assert_says_key "install:second-run-finishes" "$FINISHED_KEY" "$out2" "$ICAT"
if diff -u "$TMP/s1" "$TMP/s2" > "$TMP/statediff" 2>&1; then
    pass "install:is-idempotent"
else
    fail "install:is-idempotent" "$(cat "$TMP/statediff")"
fi
assert_eq "install:student-work-survives-a-rerun" "my work" \
          "$(cat "$DEST/projects/my-app/index.js" 2>/dev/null)"
# Re-running must report already-satisfied steps rather than redoing them.
assert_says_key "install:reports-already-done" skip.suffix "$out2" "$ICAT"

# ─── the Windows sign-off, which is the same run with one variable set  (#218) ─
#
# THE COVERAGE HAS TO BE HERE, and that is a consequence of what each suite can see rather
# than a preference. A Windows install ends with ONE closing message now: the .cmd stopped
# printing instructions of its own, and course-install.sh prints the Windows sign-off in
# place of the UNIX one when CS193V_WINDOWS is set. 27-installer-windows.sh drives the real
# .cmd but FAKES wsl.exe, so the installer never runs there and nothing in that file can read
# this message; this suite runs the real installer and never runs the .cmd. So 27 asserts the
# variable is PASSED and this asserts what it DOES, and neither can be asked to do both.
#
# A DIRECTORY THAT IS NOT THE DEFAULT, AND THAT IS THE ASSERTION RATHER THAN HOUSEKEEPING.
# The message the .cmd used to print hardcoded `cd ~/cs193v` and a UNC path ending
# `home\student\cs193v` -- but choose_dir's menu runs on the Windows path too, so a student
# who picked anything else was handed two paths that did not exist. Only course-install.sh
# knows $DIR, and pointing this run somewhere else is what makes "the sign-off follows it" a
# thing a test can fail rather than a coincidence.
shim_new
WINDEST="$TMP/windest"
outw="$(installer_host "$TMP/installer.sh" CS193V_DIR="$WINDEST" TMPDIR="$BOOTTMP" \
                       CS193V_WINDOWS=1)"
# THE WHOLE SIGN-OFF, RENDERED WITH ALL FOUR VALUES, which is what makes one assertion out of
# four. They were win-signoff:finishes, :names-the-wsl-step, :the-cd-follows-the-chosen-dir and
# :the-unc-path-follows-it-too -- the sign-off quoted a phrase at a time, so rewording any of it
# reddened some of them and left the rest green. say_done (course-install.sh:199) supplies DIR,
# DISTRO, USER and UNC; this supplies the same four and asserts the result arrived entire, which
# covers every one of those claims including the two that were really about $WINDEST.
#
# THE UNC PATH IS STILL THE INTERESTING ONE and is still built here rather than quoted: its
# prefix is a constant that would match with the directory half wrong, which is the defect this
# case exists for. Supplying it as {{UNC}} means the needle can only match if the message and
# win_projects_path agree about it.
# finished.windows-shortcut RATHER THAN finished.windows (#134): install_win_shim runs on this
# path, so the arm that promises the Start Menu entry is the one say_done picks. The fallback arm
# is still asserted -- by sign-off:windows-without-a-shortcut-falls-back, against say_done
# directly, because reaching it end to end would mean arranging for the shim write to fail.
assert_says_sub "win-signoff:finishes" finished.windows-shortcut "$outw" "$ICAT" \
                "DIR=$WINDEST" DISTRO=CS193V "LABEL=$MAC_LABEL" \
                "UNC=$(printf '%s' "\\\\wsl.localhost\\CS193V$WINDEST/projects" | do_tr / '\\')"
# AND THE UNIX ENTRY WAS NOT THE ONE PRINTED, asserted on the one phrase that differs rather
# than on the advice, because nearly all of the advice is shared: both entries name the same
# directory, the same ./cs193v and the same reassurance about closing the window. "To start
# working:" belongs to [[finished]] and "To start:" to [[finished.windows]], so this is the
# thing that goes red if say_done ever stops choosing between them.
assert_says_not_key "win-signoff:is-not-the-unix-sign-off" finished "$outw" "$ICAT"

# ─── check_disk, which no mechanism could reach before ─────────────────────────
# check_disk asks podman for two Store fields (installer's check_disk), and podman-fake's
# info arm answered only Rootless and the host figures — every other --format fell through to
# `echo ''`. The installer's own guard then swallowed it:
#
#     case "$alloc" in ''|*[!0-9]*) return 0 ;; esac
#
# so the low-disk warning was unreachable, and a test asserting it would have been
# asserting against the empty-output early return instead. The #79 shape exactly: the
# happy answer and the never-ran answer were the same answer.
#
# Extracted rather than driven, like version_lt and mac_vm_target_mb above, because all
# six branches are decided by two numbers and a full install per case would cost five
# tarball extractions to prove arithmetic. ONE end-to-end run follows, whose whole job is
# to prove the new fake keys really feed it — an extracted function cannot tell us that.
cat > "$TMP/cd.sh" <<'EOF'
note() { printf 'NOTE %s\n' "$*"; }
ok()   { printf 'OK %s\n' "$*"; }
# check_disk's `out="$(podman info ...)" || return 0` reads BOTH the status and the text,
# so the stub has to be able to fail as well as answer.
podman() { [ "${FAKE_RC:-0}" -eq 0 ] || return "${FAKE_RC:-0}"; printf '%s\n' "$FAKE_OUT"; }
EOF
# THE REAL TEXT COMES WITH IT, since issue #116: check_disk's words are catalogue entries, so
# the carve needs a reader and the prose -- the multi-line advisory is one entry piped through
# notes() rather than three note calls. Carrying the real text rather than a stub is the point:
# the numbers below are asserted against what a student would actually read.
#
# A READER AND A FILE SINCE #221, not a carved accessor and a carved heredoc. msg() comes out of
# cs193v-ui.sh -- the same one the product uses -- and MESSAGES points at the real catalogue, so
# these assertions can no longer pass against a private copy of either that had drifted from it.
{
    printf 'MESSAGES="%s"\n' "$PRIVATE/course-install-messages.txt"
    sed -n '/^msg() {$/,/^}$/p'            $PRIVATE/files/cs193v-ui.sh
    sed -n '/^notes() {/p'                 $PRIVATE/course-install.sh
    sed -n '/^check_disk()/,/^}$/p'        $PRIVATE/course-install.sh
} >> "$TMP/cd.sh"
if [ "$(grep -c '.' "$TMP/cd.sh")" -gt 8 ]; then pass "extract:check_disk"
else fail "extract:check_disk" "could not extract check_disk"; fi

cd_for() {                            # cd_for ALLOC USED [RC] -> its note/ok lines
    ( . "$TMP/cd.sh"; FAKE_OUT="$1 $2" FAKE_RC="${3:-0}" check_disk )
}
#  10 GiB allocated, 6 used -> 4 GiB free, under the 8 GiB floor check_disk names.
# RENDERED WITH THE NUMBER, because the number is the assertion. note.low-disk and ok.disk-free
# both interpolate {{FREE}}, and ok.disk-free LEADS with it -- so msg_text returns nothing at all
# for one and stops before the arithmetic for the other, and a needle that cannot see the number
# passes whatever check_disk computed. That is the bug these four exist to catch.
# ONE LINE AT A TIME, and the reason is the stub above rather than the product: notes() calls
# note() once per line, and this carving's note() labels each one "NOTE " so the transcript
# shows which lines it produced. _flatten strips box GLYPHS, not words, so a whole-body needle
# arrives with "NOTE" spliced into the middle of it and matches nothing. The first line carries
# the arithmetic and the last carries the remedy, which is what these two names each claim.
low4="$(msg_of_in "$ICAT" note.low-disk FREE=4)"
assert_says "check-disk:warns-under-the-floor" \
            "$(printf '%s\n' "$low4" | sed -n 1p)" "$(cd_for 10737418240 6442450944)"
assert_says "check-disk:says-it-can-be-resumed" \
            "$(printf '%s\n' "$low4" | sed -n '$p')" "$(cd_for 10737418240 6442450944)"
# 100 GiB allocated, 10 used -> 90 free, comfortably over.
assert_says_sub "check-disk:reports-ample-room" ok.disk-free \
                "$(cd_for 107374182400 10737418240)" "$ICAT" FREE=90
# THE NEGATIVE KEEPS THE TRUNCATED NEEDLE, and here that is the right one rather than a
# concession: msg_text stops at {{FREE}}, so the needle is "Only about" -- the shortest phrase
# no other message says, which is exactly what a negative assertion wants.
assert_says_not_key "check-disk:ample-room-does-not-warn" note.low-disk \
                    "$(cd_for 107374182400 10737418240)" "$ICAT"
# The three silent early returns. Advisory by design: a wrong guess must not block an
# install that would have worked, so each of these says NOTHING rather than guessing.
assert_eq "check-disk:silent-when-podman-says-nothing"   "" "$(cd_for '' '')"
assert_eq "check-disk:silent-when-the-value-is-not-a-number" "" "$(cd_for bad 0)"
assert_eq "check-disk:silent-when-allocated-is-zero"     "" "$(cd_for 0 0)"
assert_eq "check-disk:silent-when-podman-info-fails"     "" "$(cd_for 1 1 1)"

# ...and the end-to-end run that proves the fake really answers the query the installer
# sends. Without this the six assertions above pass against a stub and the new keys could
# be misspelled forever.
shim_new
shim_set graph_alloc 10737418240
shim_set graph_used   6442450944
out="$(installer_host "$TMP/installer.sh" CS193V_DIR="$TMP/lowdisk")"
# THE WHOLE BODY HERE, unlike the carving above: this is the real note(), whose gutter is
# NOTE_INDENT -- four spaces -- and _flatten collapses whitespace.
assert_says_sub "check-disk:the-fake-really-feeds-it" note.low-disk "$out" "$ICAT" FREE=4
assert_says_key "check-disk:low-disk-is-not-fatal"    "$FINISHED_KEY"          "$out" "$ICAT"

# ─── the macOS virtual machine, which no mechanism could reach before ──────────
# `machine) echo ''; exit 0` was podman-fake's whole answer, so `podman machine list |
# grep -q .` was unconditionally false: DO_MACHINE_RESIZE could not be set, and neither
# grow_machine_disk nor grow_machine_disk_when_stopped could run at all. Four survey arms
# and eight lines of setup_machine were dead to every test.
#
# Driven end to end rather than extracted, because what was missing was the FAKE, and an
# extracted setup_machine with a stubbed podman would prove nothing about it.
#
# NOT reached here: setup_machine's resize EXECUTION. A resize is the one machine change
# that calls need(), so it waits on consent, and with no tty ask_consent takes the safe
# default and exits. The survey half -- that the resize is offered, and in what words --
# is asserted below; the execution half needs a pty.
mac_run() {                           # mac_run [KEY VALUE]... -> the installer's output
    shim_new
    shim_fake_mac                     # 16 GiB arm64 -> mac_vm_target_mb wants 8192 MB
    while [ "$#" -gt 1 ]; do shim_set "$1" "$2"; shift 2; done
    # The destination lives under the shim rather than a counter, because a counter
    # incremented in this subshell would be 1 for every case -- so all of them would share
    # one directory and every case after the first would take "already done" paths.
    installer_host "$TMP/installer.sh" CS193V_DIR="$SHIM/dest"
}
mac_rc() { mac_run "$@" >/dev/null 2>&1; printf '%s' "$?"; }
# The same door through a real pty, which is the only way the progress block draws at all --
# meter_start returns immediately when stdout is not a terminal. No keystrokes: CS193V_DIR is
# set so choose_dir does not prompt, and a machine that only needs INIT needs no consent, so
# there is no menu to feed. A case that grew one would hang rather than fail (ERRORS.md B13).
mac_tty() {                           # mac_tty [KEY VALUE]... -> the raw pty transcript
    shim_new
    shim_fake_mac
    while [ "$#" -gt 1 ]; do shim_set "$1" "$2"; shift 2; done
    installer_tty '' "$TMP/installer.sh" CS193V_DIR="$SHIM/dest"
}

# The gate on everything below: if this fails, every other assertion here is failing
# because the run is still on Linux, not because of anything to do with a machine.
out="$(mac_run)"
assert_says_sub "mac:platform-is-detected" ok.platform "$out" "$ICAT" PLAT=macos ARCH=arm64

# ─── nothing exists yet -> init  (survey's machine-list-empty arm) ─────────────
# init is announced with ok(), not need(), so it is the one machine change that needs no
# consent -- which is what makes this reachable with no tty at all.
assert_says_key "mac-init:announced-in-the-survey" ok.vm-will-be-created "$out" "$ICAT"
assert_says_sub "mac-init:names-the-size-it-will-use" step.machine-create "$out" "$ICAT" \
                WANT=8192 DISK=64
assert_says_key "mac-init:reports-success" ok.machine-created "$out" "$ICAT"
# The flags, not just the prose: --now matters (without it the machine is created stopped
# and every later podman call fails), and the two values must be the computed ones.
assert_says "mac-init:asks-for-the-computed-size" \
            'machine init --memory 8192 --disk-size 64 --now' "$(installer_log)"
assert_says_not_key "mac-init:does-not-also-resize" step.machine-resize "$out" "$ICAT"

out="$(mac_run machine_init_rc 1)"
assert_says_key "mac-init:failure-is-fatal" err.machine-create "$out" "$ICAT"
assert_no_signoff "mac-init:failure-does-not-claim-success" "$out"
assert_eq "mac-init:failure-exits-1" "1" "$(mac_rc machine_init_rc 1)"

# ─── the progress block around `machine init`  (#219) ──────────────────────────
# THE ONE ARM OF setup_machine THAT GETS A BLOCK, and the resize arm deliberately does not:
# grow_machine_disk prints a notes() block in the middle of that one, and the animator overdraws
# anything else within 100 ms.
#
# REACHABLE HERE, unlike the .pkg install beside it: podman-fake answers `machine init` and now
# prints what podman really prints, so the anchors have real line shapes to match. The .pkg needs
# a Mac and is in tests/MANUAL.md.
#
# PIPED FIRST, for the same reason the apt cases are: mac_run has no tty, so setup_phase prints
# one line per phase deterministically rather than being sampled by a 10 Hz animator.
macbox="$(mac_run)"
for mackey in meter.vm-downloading meter.vm-initializing; do
    assert_says_key "machinebox:piped-announces-[$mackey]" "$mackey" "$macbox" "$ICAT"
done
# THE SECOND PHASE IS ANCHORED ON PODMAN'S OWN WORDS, so this is the assertion that would catch
# an anchor aimed at a line podman does not print. Ordering, because both appearing proves
# nothing about which came first.
macdown="$(printf '%s\n' "$macbox" | grep -nF "$(msg_text meter.vm-downloading "$ICAT")" \
           | sed 's/:.*//' | head -1)"
macinit="$(printf '%s\n' "$macbox" | grep -nF "$(msg_text meter.vm-initializing "$ICAT")" \
           | sed 's/:.*//' | head -1)"
record "machinebox:the-phase-rows" "${macdown:-x}/${macinit:-x}"
assert_ok "machinebox:piped-phases-are-in-order" \
          sh -c "test -n '$macdown' && test -n '$macinit' && test '$macdown' -lt '$macinit'"

# AND PODMAN'S OUTPUT NO LONGER REACHES THE STEP LIST, which is the whole point of the change:
# `machine init` prints nine lines of image names and blob digests that a student cannot act on.
assert_says_not "machinebox:podmans-chatter-is-not-in-the-step-list" \
                "Copying blob sha256" "$macbox"

# ─── ...and on a terminal, where there is a box ────────────────────────────────
# FOUR BARS AFTER THE CORNER is the titleless lid; see the aptbox group for why that signature.
# machine_delay so that a frame is drawn while a phase is in progress -- without it the nine
# lines arrive inside one 100 ms tick and the animator may never see a mid-run state.
macraw="$(mac_tty machine_delay 0.08)"
assert_contains "machinebox:the-block-carries-an-output-box" "┏━━━━" "$macraw"
# ON A BOX ROW, not merely on the screen. Without the border in the needle this passed
# before the feature existed, because podman's output was on the terminal anyway. The row
# format is `┃ <text> ┃` and the dim escape precedes the border, so the two are contiguous.
assert_contains "machinebox:the-box-shows-what-podman-said" "┃ Copying blob sha256" "$macraw"
macscreen="$(printf '%s' "$macraw" | render_pty)"
assert_not_contains "machinebox:the-box-is-gone-at-the-end" "┏━━━━" "$macscreen"
assert_match "machinebox:the-bar-fills-only-at-the-end" '✓ .*\] +2/2' "$macscreen"
assert_says_key "machinebox:the-step-still-reports-success" ok.machine-created "$macscreen" "$ICAT"

# THE FAILURE ARM: the block closes before the STOP box rather than under it, and the refusal
# carries what podman said -- which it could not point at any more (ERRORS.md B17).
macfail="$(mac_run machine_init_rc 1)"
assert_says_key "machinebox:failure-still-refuses" err.machine-create "$macfail" "$ICAT"
assert_says "machinebox:failure-carries-podmans-words" "machine init failed" "$macfail"
assert_says "machinebox:failure-names-the-log" "cs193v-setup.log" "$macfail"

# ─── a machine that is too small -> the resize is OFFERED  (survey :384-387) ───
# 80% of 8192 is 6553, so 4096 is under it and 16384 is over.
out="$(mac_run machine_list podman-machine-default machine_mem 4096)"
assert_says_sub "mac-resize:offered-when-the-vm-is-small" need.vm-memory "$out" "$ICAT" \
                HAVE=4096 WANT=8192
assert_says_key "mac-resize:explains-why-a-mac-needs-it" need.vm-memory.why "$out" "$ICAT"
# EVERY NEGATIVE BELOW IS PAIRED WITH A POSITIVE OFF THE SAME VALUE. An empty argv.log --
# a wrong path, a run that never started -- satisfies `machine set is absent` perfectly,
# and VERIFICATION.md records assert_not_contains as a measured vacuity blind spot: ten of
# them passed in the sabotage run. The companion asserts a line that can only be there if
# the installer really asked podman about a machine.
# It needs permission, so with no tty it must change NOTHING -- including no init.
assert_says_key "mac-resize:no-tty-declines"  consent.declined "$out" "$ICAT"
assert_says     "mac-resize:the-log-was-really-read" 'machine list' "$(installer_log)"
assert_says_not "mac-resize:declining-touches-no-machine" 'machine set' "$(installer_log)"

# ─── a machine that is big enough -> skip  (survey's else arm) ─────────────────
out="$(mac_run machine_list podman-machine-default machine_mem 16384)"
assert_says_key "mac-ok:reasonable-size-is-left-alone" skip.vm-size "$out" "$ICAT"
assert_says_not_key "mac-ok:does-not-offer-a-resize" need.vm-memory "$out" "$ICAT"
assert_says_key "mac-ok:still-finishes" "$FINISHED_KEY" "$out" "$ICAT"

# inspect returning nothing must land in the SAME arm, not in the resize one: an empty
# value would make `[ "$vm_mb" -lt ... ]` an error, so the installer guards with -n first.
out="$(mac_run machine_list podman-machine-default machine_mem '')"
assert_says_key "mac-inspect-empty:treated-as-reasonable" skip.vm-size "$out" "$ICAT"
assert_says_not_key "mac-inspect-empty:does-not-offer-a-resize" need.vm-memory "$out" "$ICAT"

# ─── growing the disk, on the path where nothing else stopped the machine ──────
# grow_machine_disk_when_stopped, reached only through the skip arm above.
out="$(mac_run machine_list pmd machine_mem 16384 machine_disk 32)"
assert_says_sub "mac-disk:grows-a-disk-that-is-too-small" note.growing-disk "$out" "$ICAT" \
                HAVE=32 WANT=64
assert_says_key "mac-disk:says-it-costs-nothing-up-front" note.growing-disk "$out" "$ICAT"
assert_says "mac-disk:asks-podman-to-grow-it" 'machine set --disk-size 64' "$(installer_log)"

out="$(mac_run machine_list pmd machine_mem 16384 machine_disk 64)"
assert_says_not_key "mac-disk:a-big-enough-disk-is-left-alone" note.growing-disk "$out" "$ICAT"
assert_says     "mac-disk:the-log-was-really-read" 'machine inspect' "$(installer_log)"
assert_says_not "mac-disk:no-set-when-there-is-nothing-to-do" 'machine set' "$(installer_log)"

# podman refuses to SHRINK a machine disk, so a refusal here is expected rather than
# exceptional -- it must be a note and the install must go on.
out="$(mac_run machine_list pmd machine_mem 16384 machine_disk 32 machine_set_rc 1)"
assert_says_key "mac-disk:a-refused-grow-is-not-fatal" note.grow-failed "$out" "$ICAT"
assert_says_key "mac-disk:still-finishes-after-a-refused-grow" "$FINISHED_KEY" "$out" "$ICAT"

# A non-numeric DiskSize is podman's output changing shape, and the installer's own comment
# says the harmless direction is to stop growing rather than to guess.
out="$(mac_run machine_list pmd machine_mem 16384 machine_disk bad)"
assert_says_not_key "mac-disk:non-numeric-size-grows-nothing" note.growing-disk "$out" "$ICAT"
assert_says_key "mac-disk:non-numeric-size-still-finishes" "$FINISHED_KEY" "$out" "$ICAT"

# ─── survey does not reinstall a podman it cannot see  (issue #121) ────────────
# The second bug #121 caused, and the one that costs a student real money: re-running this
# script in the window that ran it the first time saw NO podman -- so it re-downloaded 75 MB,
# asked for the password again, and re-ran `sudo installer`, whose preinstall does
# `rm -rf /opt/podman` and takes the virtual machine and every container in it with it.
#
# A FABRICATED RECEIPT, and since #221 it takes a SECOND TARBALL to fabricate. The shipped
# identifier is REAL on a maintainer's Mac, which would make these pass for the wrong reason --
# but PODMAN_PKG_ID no longer lives in the file being copied. It lives in cs193v-ui.sh, which
# the installer proper sources out of the tree it downloads, so the fake has to be baked into a
# tree of its own. Same shape as lib/sandbox.sh's sb_work_skew, and for the same reason.
cp -a "$TMP/pkg" "$TMP/pkg-probe"
edit_sub "$TMP/pkg-probe/cs193v-main/.private/files/cs193v-ui.sh" \
         '^PODMAN_PKG_ID=.*' "PODMAN_PKG_ID=\"$IPROBE_PKG_ID\""
# ASSERTED BEFORE IT IS PACKED. edit_sub whose ERE matches nothing is a silent no-op --
# lib/sandbox.sh records the same trap -- and here the consequence is a case that interrogates
# the developer's real /opt/podman and passes without testing anything.
assert_eq "probe:the-probe-tree-names-the-fake-package" "1" \
          "$(grep -c "^PODMAN_PKG_ID=\"$IPROBE_PKG_ID\"\$" \
             "$TMP/pkg-probe/cs193v-main/.private/files/cs193v-ui.sh")"
( cd "$TMP/pkg-probe" && tar czf "$TMP/course-probe.tar.gz" cs193v-main )
assert_file "probe:the-probe-tarball-was-built" "$TMP/course-probe.tar.gz"

cp "$PRIVATE/install-cs193v.sh" "$TMP/install-probe.sh"
edit_sub "$TMP/install-probe.sh" '^REPO_OWNER=.*' 'REPO_OWNER="test"'
edit_sub "$TMP/install-probe.sh" '^TARBALL=.*'    "TARBALL=\"file://$TMP/course-probe.tar.gz\""
assert_eq "probe:the-installer-copy-names-the-probe-tarball" "1" \
          "$(grep -c 'course-probe\.tar\.gz' "$TMP/install-probe.sh")"
assert_ok "probe:the-installer-copy-is-valid-bash" bash -n "$TMP/install-probe.sh"

# THE PATH OVERRIDE RIDES ON THE DOOR'S OWN env LINE. installer_host runs
# `env HOME=... PATH="$SHIM:$PATH" "$@" bash "$script"`, and a duplicate assignment later in an
# env argv wins -- measured: `env A=1 A=2 sh -c 'echo $A'` prints 2. So no surgery on the door,
# and 10-static.sh's installer-door rules stay satisfied.
# TWO FUNCTIONS, AND THE SPLIT IS NOT STYLE. Every call site is `out="$(probe_survey ...)"`,
# which is a subshell -- so a fixture built inside it would set $SHIM, $IOFF and $IFARM in that
# subshell and NONE of them would reach the assertions, which would then compare against
# whatever an earlier case left behind. That is the "#76 shape" repo_copy's own comment
# records, and it cost this block one green-looking failure before it was split: the needle
# named one shim directory and the installer had run in another.
probe_setup() {                       # probe_setup present|absent   (in the CALLER's shell)
    shim_new
    shim_fake_mac
    shim_set version 5.7.0
    IOFF="$(shim_offpath_podman)"
    IFARM="$(shim_toolfarm)"
    case "$1" in
        present) shim_fake_pkgutil "$IPROBE_PKG_ID" "$IOFF" ;;
        # A receipt for a directory with no podman in it: podman genuinely absent, which is
        # what a first-time student's Mac looks like.
        absent)  mkdir -p "$SHIM/empty"
                 shim_fake_pkgutil "$IPROBE_PKG_ID" "$SHIM/empty" ;;
    esac
}
probe_survey() {                      # probe_survey -> the installer's output
    installer_host "$TMP/install-probe.sh" CS193V_DIR="$SHIM/dest" PATH="$SHIM:$IFARM"
}

# ── podman installed, invisible: found, reported, and NOT reinstalled ──
probe_setup present
out="$(probe_survey)"
# The gate: if this fails, everything below is failing because the run never got past survey.
assert_says_sub "probe:the-survey-run-reached-macos" ok.platform "$out" "$ICAT" \
                PLAT=macos ARCH=arm64
assert_says_sub "probe:the-installer-reports-the-podman-it-found" ok.podman "$out" "$ICAT" V=5.7.0
# ONE RENDERED MESSAGE FOR THE PAIR. probe:the-installer-explains-the-path was the other half --
# it asserted note.podman-path by key, which stops at {{DIR}} -- and this one quoted the prose in
# front of $IOFF. Rendered with the directory, one needle makes both claims: the note arrived,
# and it names the directory the repair really resolved.
assert_says_sub "probe:the-installer-says-where-it-found-it" note.podman-path "$out" "$ICAT" \
                "DIR=$IOFF"
# THE NEGATIVE, and its positive is the pair above. BY KEY, and the macOS key: probe_survey
# fakes a Mac, so need.podman-mac.why is the body this run could have printed. The two arms say
# the same thing today, which is why the old quoted needle needed no platform gate -- and is
# also why naming the key is the safer of the two, since nothing keeps them identical.
assert_says_not_key "probe:the-installer-does-not-reinstall-a-podman-it-cannot-see" \
                    need.podman-mac.why "$out" "$ICAT"
assert_says_not "probe:it-downloads-no-pkg" "podman-installer-macos" "$out"
assert_says_not "probe:it-runs-no-installer" "installer -pkg" "$(sudo_log)"
# AND IT REALLY RAN THAT PODMAN, rather than merely finding the file. This is what separates
# "the repair located it" from "the repair put it somewhere PATH can reach".
assert_says "probe:the-installer-really-ran-that-podman" "--version" "$(installer_log)"

# ── podman genuinely absent: the offer must survive ──
# THE CONTROL. It passed before the fix and must keep passing: a repair that swallowed this
# would leave a student with no podman and no offer to install one.
probe_setup absent
out="$(probe_survey)"
assert_says_sub "probe:the-survey-absent-run-reached-macos" ok.platform "$out" "$ICAT" \
                PLAT=macos ARCH=arm64
assert_says_key "probe:the-installer-offers-to-install-a-podman-that-really-is-absent" \
                need.podman-mac.why "$out" "$ICAT"
assert_says_not "probe:it-claims-no-directory-when-there-is-none" \
                "podman is installed in" "$out"


# ─── the password: satisfiable, and asked once  (#226) ─────────────────────────
# WHY THESE RIDE ON probe_setup absent. Every arm below needs `needs_root` to be TRUE, and on
# a Mac only one thing makes it so: podman absent. probe_setup gives exactly that -- a receipt
# for an empty directory, no podman anywhere on the composed PATH -- and its PATH override is
# what makes the arms reachable in the cheap lane at all: with $IFARM standing in for the real
# PATH, the only `sudo` the installer can find is sudo-fake, so nothing here can reach the
# developer's own sudo even by accident.
#
# THE ORDERING ASSERTION IS THE LINUX ONE, further down. This block proves the REFUSALS, which
# is what can be proven without letting install_podman's macOS arm fetch 75 MB from GitHub in
# the cheap lane -- so every arm here dies before it.
#
# sudo-fake exits 0 for anything not in sudo_fail, so the probe SUCCEEDS by default and these
# are the only cases that see the failure paths. `-n true` is the probe's exact argv and `-v`
# the prime's, so failing them separately is what separates "cannot answer" from "answered no".

# ── no sudo on the machine at all: refused at the survey, naming what wanted root ──
# A PRIVATE FARM, not `rm -f "$IFARM/sudo"`: shim_toolfarm builds $SHIM_FARM once and every
# later case shares it, so taking sudo out of it would silently disarm them all.
probe_setup absent
NOSUDO="$SHIM/farm-nosudo"; mkdir -p "$NOSUDO"
ln -s "$IFARM"/* "$NOSUDO/" 2>/dev/null
rm -f "$NOSUDO/sudo" "$SHIM/sudo"
assert_eq "password:the-no-sudo-farm-really-has-no-sudo" "" "$(ls "$NOSUDO/sudo" 2>/dev/null)"
out="$(installer_host "$TMP/install-probe.sh" CS193V_DIR="$TMP/nosudo" PATH="$SHIM:$NOSUDO")"
assert_says_key "password:no-sudo-says-why" err.no-sudo "$out" \
                "$PRIVATE/course-install-messages.txt"
# THE RENDERED LIST LINE, not the word "podman". The refusal has to say what it wanted the
# password FOR, and only root_wants() emits that list -- its "  - " prefix is the one thing
# nothing else in the transcript has, where a bare "podman" would also match the survey's own
# report of the machine. Measured red by making root_wants print nothing.
#
# IT USED TO MATTER MORE THAN THAT. While these doors ran the installer under `bash -x` for the
# coverage gate, xtrace put every EXPANDED argument in the transcript -- so the catalogue prose
# the script hands its helpers was in this output too, and "podman" matched the trace rather
# than the refusal. #231 deleted the tracing, so that reading is gone; the needle stays because
# it is the more precise of the two either way.
# THE LIST ITEM, which is root_wants()'s "  - " prefix and then the consent item's own label out
# of the catalogue. The prefix is this script's, so it stays spelled out; the label does not.
assert_says     "password:no-sudo-names-what-wanted-root" \
                "- $(msg_of_in "$ICAT" need.podman-mac)" "$out"
assert_says_not_key "password:no-sudo-asks-no-permission" step.consent "$out" "$ICAT"
assert_no_signoff "password:no-sudo-does-not-claim-success" "$out"
assert_no_file  "password:no-sudo-creates-no-directory" "$TMP/nosudo"

# ── sudo needs a password and there is no terminal to type it into ──
probe_setup absent
shim_set sudo_fail '-n true'
out="$(installer_host "$TMP/install-probe.sh" CS193V_DIR="$TMP/notty" PATH="$SHIM:$IFARM")"
assert_says_key "password:no-terminal-says-why" err.sudo-no-terminal "$out" \
                "$PRIVATE/course-install-messages.txt"
# BEFORE THE CONSENT SCREEN, which is the whole point of putting this in survey: a machine that
# cannot produce the password must be refused before it is offered a bargain it cannot keep.
assert_says_not_key "password:no-terminal-refuses-before-consent" step.consent "$out" "$ICAT"
assert_no_file  "password:no-terminal-creates-no-directory" "$TMP/notty"
# It asked, and it asked non-interactively. `-n` is what makes the probe a question rather
# than a prompt, so its presence in the log is the assertion.
assert_says "password:the-probe-never-prompts" "-n true" "$(sudo_log)"

# ── sudo answers no: refused after consent, before the first privileged command ──
probe_setup absent
shim_set sudo_fail "$(printf '%s\n%s' '-n true' '-v')"
out="$(installer_tty '2' "$TMP/install-probe.sh" CS193V_DIR="$TMP/sudono" PATH="$SHIM:$IFARM" | strip_ansi)"
assert_says_key "password:refused-says-why" err.sudo-refused "$out" \
                "$PRIVATE/course-install-messages.txt"
# ANNOUNCED FIRST, which is rule 2 of course-install.sh:20-28 and the thing #223 asks for.
assert_says_key "password:announced-before-it-is-asked" note.password-why "$out" \
                "$PRIVATE/course-install-messages.txt"
# BY KEY. Written with msg_text inline, an unknown key yields an EMPTY needle and assert_says
# passes on every input -- which is how this assertion passed before step.password existed.
assert_says_key "password:the-step-is-announced" step.password "$out" \
                "$PRIVATE/course-install-messages.txt"
assert_no_signoff "password:refused-does-not-claim-success" "$out"
# AND NOTHING WAS INSTALLED. The prime is the only privileged call in the log: no package
# manager, no .pkg. sudo-fake records without executing, so this reads what would have run.
assert_says     "password:the-prime-really-ran" "-v" "$(sudo_log)"
assert_says_not "password:refused-installs-no-pkg" "installer -pkg" "$(sudo_log)"
assert_says_not "password:refused-runs-no-package-manager" "install" "$(sudo_log)"

shim_new

# ── the ordering, and the control, both of which need a run that gets PAST ask_password ──
# NOT REACHABLE ON A MAC, and the reason is worth writing down rather than guarding silently.
# macOS has exactly one root-requiring step -- installing podman -- so any Mac run that clears
# ask_password goes straight into install_podman's arm and fetches 75 MB from GitHub, which the
# cheap lane must not do. On Linux, a faked account with no /etc/subuid entry needs root for
# setup_subuid alone: sudo-fake records the usermod and executes nothing, so the whole ordering
# is observable offline. 26-installer-sandbox.sh asserts both of these against a real sudo.
if linux_arm; then
# `-n true` fails and `-v` does not, which is the shape of every ordinary machine: a password
# is needed, and the student supplies it once.
shim_new; shim_fake_id 1000 nosuchuser-cs193v; shim_set sudo_fail '-n true'
out="$(installer_tty '2' "$TMP/installer.sh" CS193V_DIR="$SHIM/dest" | strip_ansi)"
assert_says_key "password:announced-on-the-linux-arm-too" step.password "$out" \
                "$PRIVATE/course-install-messages.txt"
# THE CLAIM #226 IS ABOUT, reduced to two words in order: the password is obtained BEFORE the
# first privileged command runs, not by that command prompting for it.
order="$(sudo_log | awk '/^-v$/{print "prime"} /usermod/{print "usermod"}' | tr '\n' ' ')"
assert_eq "password:asked-before-the-first-privileged-command" "prime usermod " "$order"

# THE CONTROL, and it has to be a run that reaches ask_password and returns from it -- a
# non-tty run declines at ask_consent and never gets there, which is a control that cannot
# fail. With sudo answering the probe, the announcement must not print: on a machine with
# passwordless sudo it would promise a prompt that never comes.
shim_new; shim_fake_id 1000 nosuchuser-cs193v
out="$(installer_tty '2' "$TMP/installer.sh" CS193V_DIR="$SHIM/dest" | strip_ansi)"
assert_says_not_key "password:silent-when-no-password-is-needed" step.password "$out" \
                    "$PRIVATE/course-install-messages.txt"
# ...and it really did get past it, rather than dying before the announcement would have been
# due. Without this the assertion above passes on any failure at all.
assert_says "password:the-control-ran-the-privileged-step" "usermod" "$(sudo_log)"
else
skip_linux_arm "password:announced-on-the-linux-arm-too" \
               "password:asked-before-the-first-privileged-command" \
               "password:silent-when-no-password-is-needed" \
               "password:the-control-ran-the-privileged-step"
fi

# A CLEAN SHIM LEFT BEHIND, DELIBERATELY. probe_setup runs in THIS shell rather than a subshell
# (it has to -- see its own comment), so it leaves $SHIM with podman moved out of it. Anything
# added after this block that reused that shim would see a machine with no podman and take
# install paths it did not ask for, which is a confusing way to inherit a bug. This block owns
# its mess.
shim_new

# ─── the Intel Mac stop, which is the other thing uname decides ────────────────
shim_new
shim_fake_uname Darwin x86_64
shim_fake_sysctl 17179869184
out="$(installer_host "$TMP/installer.sh" CS193V_DIR="$TMP/intel")"
assert_says_key "intel-mac:refused" err.intel-mac "$out" "$ICAT"
assert_no_file "intel-mac:changes-nothing" "$TMP/intel"

# ─── a bad download must never report success ──────────────────────────────────
# Three failure shapes, because they are caught by three different guards.
# Prints the installer's output; leaves its exit status in $TMP/rc, because the caller
# reads the output through a command substitution and a variable set in that subshell
# would never make it back.
# A TMPDIR OF ITS OWN, for the same reason the idempotency block above has one: these cases
# fail on both sides of the hand-over, and which side cleaned up is a question worth being able
# to ask. The bootstrap's own EXIT trap owns the tree until `exec`; course-install.sh owns it
# after. Emptied per case so one case's leftovers cannot be read as the next one's.
run_with_tarball() {                  # run_with_tarball FILE DEST
    cp "$TMP/installer.sh" "$TMP/installer-case.sh"
    edit_sub "$TMP/installer-case.sh" '^TARBALL=.*' "TARBALL=\"file://$1\""
    rm -rf "$TMP/boot-fail"; mkdir -p "$TMP/boot-fail"
    shim_new
    installer_host "$TMP/installer-case.sh" CS193V_DIR="$2" TMPDIR="$TMP/boot-fail"
    printf '%s' "$?" > "$TMP/rc"
}
last_rc() { cat "$TMP/rc"; }
fail_leftovers() { ls -d "$TMP/boot-fail"/cs193v-install.* 2>/dev/null; }

# 1. A truncated gzip stream. GNU tar exits nonzero here of its own accord; pipefail makes
#    that independent of which tar is installed.
head -c 3000 "$TMP/course.tar.gz" > "$TMP/truncated.tar.gz"
out="$(run_with_tarball "$TMP/truncated.tar.gz" "$TMP/broken-trunc")"
assert_no_signoff "truncated:does-not-claim-success" "$out"
assert_eq       "truncated:exits-nonzero"            "1" "$(last_rc)"
assert_says     "truncated:says-it-is-safe-to-retry" "safe to run this script again" "$out"
# THE BOOTSTRAP'S OWN TRAP, on the one side of the hand-over where it still runs. This case dies
# in tar, before the `exec`, so `trap ... EXIT` is live and the unpacked tree is its to remove.
assert_eq "truncated:leaves-no-temp-tree-behind" "" "$(fail_leftovers)"

# 2. A URL that is not there at all — what a wrong REPO_OWNER produces.
out="$(run_with_tarball "$TMP/no-such-file.tar.gz" "$TMP/broken-404")"
assert_no_signoff "missing-tarball:does-not-claim-success" "$out"
assert_eq       "missing-tarball:exits-nonzero"         "1" "$(last_rc)"

# 3. The one neither exit status can catch: a well-formed archive that is simply missing
#    files. tar extracts it happily and exits 0, so without an explicit per-file check the
#    install would print "Setup finished" over a directory with no launcher in it.
#
#    TWO CHECKS SINCE #221, AND THIS CASE SPLITS TO MATCH. The bootstrap checks the files it
#    needs in order to hand over at all -- five of them since #217; the installer proper checks
#    the files the STUDENT'S tree needs. They are different claims and they fail at different
#    moments, so an archive that satisfies the first and not the second has to be built on
#    purpose -- otherwise the second check is never reached and reads as covered while testing
#    nothing.

# 3a. Nothing the bootstrap can hand over to.
mkdir -p "$TMP/pkg2/cs193v-main"
cp "$PRIVATE/messages.txt" "$TMP/pkg2/cs193v-main/"
( cd "$TMP/pkg2" && tar czf "$TMP/incomplete.tar.gz" cs193v-main )
assert_ok "incomplete:archive-is-well-formed" tar tzf "$TMP/incomplete.tar.gz"
out="$(run_with_tarball "$TMP/incomplete.tar.gz" "$TMP/broken-partial")"
assert_no_signoff "incomplete:does-not-claim-success" "$out"
assert_eq       "incomplete:exits-nonzero"             "1" "$(last_rc)"
assert_says     "incomplete:names-the-missing-file"    "course-install.sh is missing" "$out"
assert_says     "incomplete:blames-the-transfer"       "cut short" "$out"
assert_says     "incomplete:says-it-is-safe-to-retry"  "safe to run this script again" "$out"
assert_no_file  "incomplete:creates-no-course-tree"    "$TMP/broken-partial"

# 3b. The half the bootstrap cannot see: everything IT needs is present, so it hands over --
#     and the tree the student was promised still has no launcher in it. Only install_files
#     catches this, and it catches it after the machine work, which is why the message talks
#     about unpacking rather than about downloading.
cp -a "$TMP/pkg" "$TMP/pkg3"
rm -f "$TMP/pkg3/cs193v-main/cs193v"
assert_ok "half-tree:the-fixture-really-lacks-the-launcher" \
          sh -c "! test -e '$TMP/pkg3/cs193v-main/cs193v'"
assert_ok "half-tree:but-still-has-what-the-bootstrap-needs" \
          test -s "$TMP/pkg3/cs193v-main/.private/course-install.sh"
( cd "$TMP/pkg3" && tar czf "$TMP/half-tree.tar.gz" cs193v-main )
out="$(run_with_tarball "$TMP/half-tree.tar.gz" "$TMP/broken-half")"
assert_says_not_key "half-tree:does-not-claim-success"   finished "$out" "$ICAT"
assert_eq       "half-tree:exits-nonzero"            "1" "$(last_rc)"
assert_says_sub "half-tree:names-the-missing-file" err.unpack-incomplete "$out" "$ICAT" \
                FILE=cs193v
assert_says_key     "half-tree:blames-the-unpacking"     err.unpack-incomplete "$out" "$ICAT"
# AND THE OTHER SIDE OF THE HAND-OVER. `exec` replaced the bootstrap and took its EXIT trap with
# it, so here the tree can only be removed by course-install.sh -- on a path that refuses, not
# just on the one that finishes. Paired with truncated:leaves-no-temp-tree-behind above so the
# two owners are asserted separately; one assertion could be satisfied by either.
assert_eq "half-tree:leaves-no-temp-tree-behind" "" "$(fail_leftovers)"

# ─── the progress block around the package manager  (#219) ─────────────────────
# WHY THIS DRIVES THE FUNCTIONS AND NOT THE INSTALLER. install_podman's apt arm needs the
# installer's LINUX arm -- /etc/os-release, which no PATH shim can fake, see linux_arm above --
# so on a Mac the whole step is unreachable and every case here would be a named skip. What is
# under test is not the distro dispatch though: it is the phase anchors and the fact that a box
# gets started at all, and both are reachable by sourcing the real cs193v-ui.sh beside the real
# wrapper and feeding it a recorded apt run. 26-installer-sandbox.sh drives the same anchors
# against a real apt on a real Debian, which is the half no fixture can answer.
#
# THE ASSEMBLY IS 20-messages.sh's, for its reason: the functions come out of course-install.sh
# with sed, so a rename fails aptbox:the-wrapper-is-extractable loudly rather than testing an
# empty file. The globals are declared by the harness AND asserted to exist in the source, the
# way this project handles every other place two files have to agree.
#
# NOT RE-TESTING THE RENDERER. meter_tail_box's eight rows, its geometry ladder, its sanitising
# and both of its endings are 30-launcher-shim.sh's tailbox:* group, against the same unchanged
# code. What is new here is that the installer passes a LOG to meter_start, so a box exists.
APTFIX="$PRIVATE/tests/fixtures/apt-install-podman.txt"
# WHICH FILE EACH HALF LIVES IN, and it is two of them since #217. The wrapper and the two
# package-manager readers are in install-utils.sh because root_step_packages is -- the block goes
# round the package manager, and the package manager is a root step shared with the WSL root
# pass. machine_phases stays in course-install.sh beside setup_machine, which only a Mac reaches.
#
# NAMED PER FILE RATHER THAN SEARCHED FOR IN BOTH, so a function that moves fails
# aptbox:the-wrapper-is-extractable loudly instead of being found by accident in its old home.
APT_WRAPPER_FNS="install-utils.sh:setup_meter_start install-utils.sh:setup_meter_stop
                 install-utils.sh:setup_phase       install-utils.sh:setup_say_phase
                 install-utils.sh:setup_run         install-utils.sh:setup_drain
                 install-utils.sh:setup_tail        install-utils.sh:apt_phases
                 install-utils.sh:dnf_phases        course-install.sh:machine_phases"
APTBOX="$TMP/aptbox.sh"
APTDRIVE="$TMP/aptdrive.sh"
APTLOG="$TMP/aptbox-setup.log"
assert_file "aptbox:the-fixture-is-there" "$APTFIX"

{
    printf 'NO_COLOR=1\n'
    printf 'MESSAGES=%s\n' "'$PRIVATE/course-install-messages.txt'"
    cat "$PRIVATE/files/cs193v-ui.sh"
    for aptsrc in $APT_WRAPPER_FNS; do
        # NO $ AFTER THE BRACE: every one of these headers carries a signature comment
        # after it, the way the rest of this file does, so an anchored pattern matched
        # none of them and the harness was a copy of cs193v-ui.sh and nothing else.
        sed -n "/^${aptsrc#*:}() {/,/^}\$/p" "$PRIVATE/${aptsrc%%:*}"
    done
    # The four the wrapper owns, set here because sed extracts functions and not the
    # assignments between them. aptbox:the-globals-are-declared is what keeps these honest.
    printf 'SETUP_LOG=%s\n' "'$APTLOG'"
    printf 'SETUP_RAW=""\nSETUP_TOTAL=0\nSETUP_PHASE=0\n'
} > "$APTBOX"

# EVERY FUNCTION, SEPARATELY. One `wc -l` over the whole file would be satisfied by four of the
# five arriving, and the missing one would then be tested by nothing at all.
aptmissing=''
for aptsrc in $APT_WRAPPER_FNS; do
    [ "$(grep -c "^${aptsrc#*:}() {" "$APTBOX")" = 1 ] || aptmissing="$aptmissing ${aptsrc#*:}"
done
assert_eq "aptbox:the-wrapper-is-extractable" "" "$aptmissing"
assert_ok "aptbox:the-harness-is-valid-bash" bash -n "$APTBOX"

# THE GLOBALS THE HARNESS SUPPLIES MUST REALLY BE THE SOURCE'S. Without this the harness could
# invent a name course-install.sh never declares, and every assertion below would pass while the
# installer itself ran with an unset variable under `set -u`.
aptundeclared=''
for aptvar in SETUP_LOG SETUP_RAW SETUP_TOTAL SETUP_PHASE; do
    grep -qE "^$aptvar=" "$PRIVATE/install-utils.sh" || aptundeclared="$aptundeclared $aptvar"
done
assert_eq "aptbox:the-globals-are-declared" "" "$aptundeclared"

# The replayer paces the fixture, which is podman-fake's build_delay for the same reason it has
# one: with every line available at once the run finishes in milliseconds and no phase is ever
# "in progress", so nothing could show whether the block animates. Column-0 `#` lines are staff
# notes in the fixture and never reach the stream.
cat > "$APTDRIVE" <<'DRIVE'
#!/usr/bin/env bash
set -u
. "$1"
APT_FIXTURE="$2"; APT_DELAY="$3"; APT_TOTAL="$4"; APT_RC="${5:-0}"
# The staff escape hatch, set AFTER the harness so it overrides the empty default it wrote.
SETUP_RAW="${APT_RAW:-}"
apt_replay() {
    local l
    while IFS= read -r l; do
        case "$l" in
            '#'*)      continue ;;
            'W: '*|'E: '*) printf '%s\n' "$l" >&2 ;;
            *)         printf '%s\n' "$l" ;;
        esac
        [ "$APT_DELAY" = 0 ] || sleep "$APT_DELAY"
    done < "$APT_FIXTURE"
    return "$APT_RC"
}
setup_meter_start "$APT_TOTAL" "$(msg meter.pm-refreshing)"
setup_run apt_phases apt_replay
apt_rc=$?
if [ "$apt_rc" -eq 0 ]; then setup_meter_stop ok; else setup_meter_stop bad; fi
printf 'RC=%s\n' "$apt_rc"
printf 'LOGLINES=%s\n' "$(grep -c . "$SETUP_LOG" 2>/dev/null || echo 0)"
DRIVE

apt_piped() {                         # apt_piped [RC] -> the non-tty output
    bash "$APTDRIVE" "$APTBOX" "$APTFIX" 0 4 "${1:-0}" 2>&1
}
apt_tty() {                           # apt_tty [DELAY] -> the raw pty transcript
    printf '' | do_script 60 "bash '$APTDRIVE' '$APTBOX' '$APTFIX' '${1:-0.05}' 4 0" 2>&1
}

# ─── the anchors, on the piped form  ───────────────────────────────────────────
# CONTENT ON THE PIPED FORM, LAYOUT ON THE PTY, which is the split 30-launcher-shim.sh records:
# a pty transcript is sampled by a 10 Hz animator, so which phases got DRAWN depends on how long
# each took, and a correct caption held for 40 ms fails an assertion about a display working
# perfectly. Piped, setup_phase prints one line per phase, by the phase, exactly once.
aptpiped="$(apt_piped)"
record "aptbox:the-piped-form" "$(printf '%s' "$aptpiped" | do_tr '\n' '|')"
for aptkey in meter.pm-refreshing meter.pm-downloading meter.pm-unpacking \
              meter.pm-configuring; do
    assert_says_key "aptbox:piped-announces-[$aptkey]" "$aptkey" "$aptpiped" "$ICAT"
done

# IN ORDER, and that is not implied by the four above: an anchor aimed at the wrong line shape --
# `Setting up` before `Unpacking`, say -- still makes all four appear.
#
# THE NEEDLES COME OUT OF THE CATALOGUE, not out of this file, so re-wording a caption does not
# red an assertion about ORDERING. An x marks a phase that never printed, and both assertions
# below reject it: `sort -c` on an empty list succeeds, so "in order" alone could pass a run
# that announced nothing, which is exactly how it passed before the feature existed.
aptorder=''
for aptkey in meter.pm-refreshing meter.pm-downloading meter.pm-unpacking \
              meter.pm-configuring; do
    aptat="$(printf '%s\n' "$aptpiped" | grep -nF "$(msg_text "$aptkey" "$ICAT")" \
             | sed 's/:.*//' | head -1)"
    aptorder="$aptorder${aptat:-x} "
done
aptsorted="$(printf '%s' "$aptorder" | do_tr ' ' '\n' | grep . | sort -n | do_tr '\n' ' ')"
record "aptbox:the-phase-rows" "$aptorder"
assert_not_contains "aptbox:piped-announces-all-four-phases" "x" "$aptorder"
assert_eq "aptbox:piped-phases-are-in-order" "$aptsorted" "$aptorder"

# EXACTLY ONCE EACH, which is the forward-only guard in setup_phase. This fixture holds six
# Unpacking lines and seven Setting up ones, so without the guard the caption would be rewritten
# per package -- invisible on a bar, six wasted rows in a piped transcript, and a claim that
# there are more phases than there are.
aptrepeats="$(printf '%s\n' "$aptpiped" | grep -cF "$(msg_text meter.pm-unpacking "$ICAT")")"
assert_eq "aptbox:piped-says-each-phase-once" "1" "$(printf '%s' "$aptrepeats" | do_tr -d ' ')"

# NO BAR IN A PIPE, the same claim tailbox:not-drawn-when-piped makes for the build: \r cannot
# overdraw a log file, and ten frames a second of it is what a student would be asked to send.
assert_not_contains "aptbox:piped-draws-no-bar" "█" "$aptpiped"

# ─── a warm cache, which is the fixture apt itself produces on a re-run ────────
# A student re-running the installer after a failure has the .debs already, so apt prints no
# `Get:` line at all and the download phase never opens. DERIVED from the one fixture rather
# than a second copy of it, so the two cannot drift.
grep -v '^Get:' "$APTFIX" > "$TMP/apt-warm.txt"
aptwarm="$(bash "$APTDRIVE" "$APTBOX" "$TMP/apt-warm.txt" 0 4 0 2>&1)"
assert_says_not_key "aptbox:warm-cache-skips-the-download-phase" \
                    meter.pm-downloading "$aptwarm" "$ICAT"
assert_says_key "aptbox:warm-cache-still-reaches-configuring" \
                meter.pm-configuring "$aptwarm" "$ICAT"

# AND THE LOG IS TRUNCATED BETWEEN STEPS, asserted HERE rather than on the first run because the
# first run cannot see it: three steps share one $SETUP_LOG, so what a missing `: >` costs is a
# box that opens on the tail of the step before -- and only the second run onwards can tell.
# This is the third invocation against this path, so without the truncation it would report all
# three. Mutation-tested: dropping the truncation reds this and nothing else.
aptwarmexpect="$(grep -v '^#' "$TMP/apt-warm.txt" | grep -c . | do_tr -d ' ')"
assert_says "aptbox:the-log-is-truncated-between-steps" "LOGLINES=$aptwarmexpect" "$aptwarm"

# ─── setup_run reports the COMMAND's status, not the pipeline's ────────────────
# The pipeline's own status is its last stage's, which is the phase reader and always 0. So
# without PIPESTATUS a failed apt would be indistinguishable from a successful one -- and the
# installer would carry on to `command -v podman` and refuse there, one step past the truth.
assert_says "aptbox:a-successful-command-reports-zero" "RC=0" "$aptpiped"
assert_says "aptbox:a-failed-command-reports-its-own-status" "RC=100" "$(apt_piped 100)"

# AND THE LOG REALLY HOLDS WHAT THE COMMAND SAID, which is what the failure box interpolates and
# what staff ask a student for. Asserted rather than assumed: `tee -a` into a path nothing
# created is the shape that silently writes nowhere.
assert_says "aptbox:the-log-holds-the-commands-output" "Setting up podman" "$(cat "$APTLOG")"
# STDERR TOO, which is a separate claim and the one with a failure mode: apt writes its W: and
# E: lines there, and a stream that skipped setup_run's pipe would land on the terminal the
# animator is redrawing -- so the symptom is not a lost line but a smeared block.
assert_says "aptbox:the-log-holds-stderr-as-well" "Failed to fetch a translation file" \
            "$(cat "$APTLOG")"
# DERIVED FROM THE FIXTURE, not written down: a line added to it must not need a number here
# changed by hand, which is how a count stops being checked. The staff notes are excluded the
# same way the replayer excludes them.
aptexpect="$(grep -v '^#' "$APTFIX" | grep -c . | do_tr -d ' ')"
assert_says "aptbox:the-log-is-the-whole-run" "LOGLINES=$aptexpect" "$aptpiped"

# ─── the staff escape hatch, on the installer's side  (#219) ──────────────────
# CS193V_SETUP_RAW_LOG is one switch over two blocks, and 30-launcher-shim.sh's build-raw group
# only ever exercised the launcher's half. What the installer's half has to do is the same three
# things: no block, no captions, and the command's own words on the screen as they arrive --
# which is the whole point on a step that HANGS, where the box shows nothing and a log written
# after the fact never exists.
aptraw="$(APT_RAW=1 apt_piped)"
assert_contains "aptraw:the-commands-own-output-is-on-the-screen" "Unpacking podman" "$aptraw"
assert_says_not_key "aptraw:no-phase-captions" meter.pm-unpacking "$aptraw" "$ICAT"
assert_says "aptraw:the-command-still-reports-its-status" "RC=0" "$aptraw"
# AND THE LOG IS STILL WRITTEN, which is not implied by the above and is the half a hung step
# needs: setup_run tees on both arms, so a staff member who Ctrl-Cs a raw run still has the file.
assert_says "aptraw:the-log-is-still-written" "Setting up podman" "$(cat "$APTLOG")"
# AND TRUNCATED, which the line above cannot see. This is the fifth run against this path, so
# without the `: >` the count would carry all five -- and a raw failure would then interpolate
# the PREVIOUS step's tail into its refusal. Found by reading the code rather than by a red:
# the truncation sat below the raw guard, where a raw run never reached it.
assert_says "aptraw:the-log-is-truncated-too" "LOGLINES=$aptexpect" "$aptraw"
# ...and on a terminal there is no block at all, which is the assertion that would catch the
# guard being dropped from setup_meter_start alone.
aptrawtty="$(printf '' | do_script 60 \
             "env APT_RAW=1 bash '$APTDRIVE' '$APTBOX' '$APTFIX' 0.02 4 0" 2>&1)"
assert_not_contains "aptraw:no-box-on-a-terminal-either" "┏━━━━" "$aptrawtty"
assert_contains "aptraw:the-raw-run-really-ran" "Unpacking podman" "$aptrawtty"

# ─── the block, on a pty ───────────────────────────────────────────────────────
# FOUR BARS AFTER THE CORNER. box() draws "┏━━ STOP " -- exactly two bars, then a space -- so a
# run of four can only be the titleless lid of the live output box. The same signature
# 30-launcher-shim.sh's TAILBOX_LID uses, and it is an assertion INPUT here rather than a second
# renderer, so it is a literal rather than a shared constant.
apttty="$(apt_tty)"
assert_contains "aptbox:the-block-carries-an-output-box" "┏━━━━" "$apttty"
assert_contains "aptbox:the-box-shows-what-the-command-said" "Unpacking podman" "$apttty"
aptscreen="$(printf '%s' "$apttty" | render_pty)"
assert_not_contains "aptbox:the-box-is-gone-at-the-end" "┏━━━━" "$aptscreen"
assert_contains "aptbox:the-block-ends-on-a-tick" "✓" "$aptscreen"
assert_match "aptbox:the-bar-fills-only-at-the-end" '✓ .*\] +4/4' "$aptscreen"
# AND NOT BEFORE IT, which is the other half and the one the arithmetic can get wrong. The bar
# counts phases COMPLETED, so the longest pass -- configure -- runs at 3/4; counting the phase
# that is RUNNING would put a full bar over a minute of work, which is ERRORS.md B18's
# complaint. A spinner frame beside 4/4 is what that looks like in a transcript.
assert_contains "aptbox:the-last-phase-runs-at-three-of-four" "3/4" "$apttty"
assert_not_match "aptbox:the-bar-does-not-fill-while-it-runs" \
                 '[⣾⣽⣻⢿⡿⣟⣯⣷] .*\] +4/4' "$apttty"

# ─── the sentinel the Windows installer checks for ─────────────────────────────
# Stage one downloads install-cs193v.sh over HTTPS and greps it for this token BEFORE running
# it. `curl -f` catches a 404 and a cut-off transfer, but not the case that matters on campus
# wifi: a captive portal answering 200 with its own login page. The bytes arrive, curl is
# happy, and `bash` would run the HTML. The token is what makes "these bytes are the installer"
# a checkable claim.
#
# TWO halves, and the second is the one that is easy to lose. Last-line-ness is what makes the
# token a completeness check as well as an identity one; without the occurs-once half, a token
# that also appeared near the TOP of the file would let a truncated download pass.
assert_ok "installer:sentinel-is-the-last-line" \
          sh -c "tail -1 '$PRIVATE/install-cs193v.sh' | grep -q 'CS193V-INSTALLER-COMPLETE'"
assert_eq "installer:sentinel-appears-once" "1" \
          "$(grep -c 'CS193V-INSTALLER-COMPLETE' "$PRIVATE/install-cs193v.sh")"

# ─── the Windows stage-one script ──────────────────────────────────────────────
# The .cmd cannot be EXECUTED here -- that is 27-installer-windows.sh, which drives it under
# wine in a container. What is checked here is the half wine structurally cannot check, because
# wine's cmd.exe is deliberately MORE PERMISSIVE than the real one in two measured places: it
# accepts `::` inside a parenthesized block, and it parses LF-only files that real cmd.exe
# misparses by byte offset. A passing wine run therefore proves nothing about either, so both
# are asserted statically instead.
#
# Every rule derives its work list by PARSING the file, so a call site or message added later is
# covered the day it lands rather than when someone remembers to extend a list.
W=$PRIVATE/install-cs193v-windows.cmd
assert_ok "windows:handles-utf16-wsl-output" grep -q 'WSL_UTF8' "$W"
# ─── stage one fetches stage two, and the contract that makes that safe ────────
#
# The old check here was `grep -q 'install-cs193v.sh' "$W"`, with a comment saying the two files
# are downloaded side by side. Both are now wrong, and the check is worse than wrong: the name
# still appears in the .cmd -- inside %INSTALLER_URL% and %STAGE2% -- so that grep CANNOT FAIL
# any more. It is deleted rather than kept, because a gate that cannot go red is an assertion
# only in appearance.
#
# CRLF: every read of the .cmd below strips \r first. Without that, a value extracted from it
# ends with a carriage return and compares unequal to the .sh's for a reason nothing prints.
cmd_get() {                           # cmd_get REGEX -> the \1 of the first match, \r stripped
    sed 's/\r$//' "$W" | sed -n "s/^$1\$/\1/p" | head -1
}
cmd_owner="$(cmd_get 'set "REPO_OWNER=\(.*\)"')"
cmd_name="$(cmd_get 'set "REPO_NAME=\(.*\)"')"
cmd_branch="$(cmd_get 'set "REPO_BRANCH=\(.*\)"')"
cmd_url="$(cmd_get 'set "INSTALLER_URL=\(.*\)"')"
cmd_sentinel="$(cmd_get 'set "SENTINEL=\(.*\)"')"

# The .cmd carries its own copy of the three repo values, so a mismatch with the .sh would fetch
# a DIFFERENT course's installer and nothing would notice until it ran. Compared as sorted
# triples rather than one at a time, so the failure message names which one drifted.
# Same shape as windows:names-the-same-distro-as-the-sh below.
triple_of_sh="$(sed -n 's/^REPO_\([A-Z]*\)="\(.*\)"$/\1=\2/p' "$PRIVATE/install-cs193v.sh" \
                | LC_ALL=C sort | do_tr '\n' ' ')"
triple_of_cmd="$(printf 'BRANCH=%s\nNAME=%s\nOWNER=%s\n' "$cmd_branch" "$cmd_name" "$cmd_owner" \
                 | LC_ALL=C sort | do_tr '\n' ' ')"
assert_eq "windows:names-the-same-repo-as-the-sh" "$triple_of_sh" "$triple_of_cmd"

# The URL, with the three values substituted in the way cmd.exe substitutes them. Two claims:
# it really points at this repo's copy of the script, and -- the load-bearing one -- every
# character in it is one that needs no quoting on either side of the Windows/Linux boundary.
# That is what lets the .cmd pass it to wsl.exe bare. A `&` here would break the line silently.
cmd_url_x="$(printf '%s' "$cmd_url" \
             | sed -e "s|%REPO_OWNER%|$cmd_owner|" -e "s|%REPO_NAME%|$cmd_name|" \
                   -e "s|%REPO_BRANCH%|$cmd_branch|")"
assert_match "windows:the-stage2-url-is-this-repo-s-installer" \
             "^https://raw\.githubusercontent\.com/.*/\.private/install-cs193v\.sh$" "$cmd_url_x"
assert_match "windows:the-stage2-url-needs-no-quoting" \
             '^https://[A-Za-z0-9._~/-]+$' "$cmd_url_x"

# ...and the same for the sentinel, which crosses the same boundary as a grep argument.
assert_match "windows:the-sentinel-needs-no-quoting" '^[A-Za-z0-9._-]+$' "$cmd_sentinel"

# The token the .cmd looks for must be the one the .sh actually ends with. Asserted against the
# .sh's LAST LINE rather than the whole file, so this cannot be satisfied by a passing mention
# somewhere in the middle. `test -n` first, or an empty extraction would grep for nothing and
# match every line.
assert_ok "windows:uses-the-same-sentinel-as-the-sh" \
          sh -c "test -n '$cmd_sentinel' \
                 && tail -1 '$PRIVATE/install-cs193v.sh' | grep -qF -- '$cmd_sentinel'"

# The download line itself, and that curl's own diagnostics are NOT redirected away: the
# `curl: (6) Could not resolve host ...` line belongs in the window a student pastes to staff.
# The first assertion is what keeps the second honest -- on a file with no download line at all,
# a "no redirection found" check would pass for free.
curl_line="$(sed 's/\r$//' "$W" | grep -n 'curl -fsSL' || true)"
assert_match "windows:downloads-the-shared-installer" \
             '\-u root \-e curl -fsSL --retry 10 --retry-delay 3 -o %STAGE2% %INSTALLER_URL%$' "$curl_line"
assert_not_match "windows:curl-diagnostics-reach-the-student" '>' "$curl_line"

# ORDER, which no wine run can prove absent: the downloaded script must be checked BEFORE it is
# handed to bash. Both line numbers must exist, so a rename on either side goes red rather than
# quiet.
sentinel_ln="$(sed 's/\r$//' "$W" | grep -n 'grep -q %SENTINEL%' | head -1 | cut -d: -f1)"
bash_ln="$(sed 's/\r$//' "$W" | grep -n -- '-e env CS193V_WINDOWS=1 bash %STAGE2%' | head -1 | cut -d: -f1)"
assert_ok "windows:checks-the-download-before-running-it" \
          sh -c "test -n '$sentinel_ln' && test -n '$bash_ln' && test '$sentinel_ln' -lt '$bash_ln'"


# ─── the Linux account this file creates, pinned the way the URL is  (#217) ────
# EVERY CHARACTER OF IT CROSSES INTO wsl.exe UNQUOTED, in `-u %LINUX_USER%`, `getent passwd
# %LINUX_USER%` and `/home/%LINUX_USER%` -- so the class here is the same argument the sentinel's
# is: a value that needs no quoting is stronger than a quote that has to survive cmd AND wsl.exe.
# The class is also a POSIX portable username, which is what useradd will accept.
cmd_user="$(cmd_get 'set "LINUX_USER=\(.*\)"')"
assert_match "windows:the-linux-user-needs-no-quoting" '^[a-z_][a-z0-9_-]{0,30}$' "$cmd_user"

# AND THE TWO FILES THAT USE IT MUST AGREE, the same shape as the distro-name check below: the
# .cmd hands the name to wsl.exe, wsl-provision.sh creates the account, and a mismatch would
# leave the .cmd probing for an account nothing ever made.
prov_user="$(sed -n 's/^WSL_USER="\(.*\)"$/\1/p' "$PRIVATE/wsl-provision.sh" | head -1)"
assert_ne "windows:the-root-pass-declares-a-user" "" "$prov_user"
assert_eq "windows:names-the-same-linux-user-as-the-root-pass" "$cmd_user" "$prov_user"

# THE SUCCESS MESSAGE IS NO LONGER IN THIS FILE TO READ (#218). Three assertions stood here and
# checked that the line a student copies into Explorer existed, named %LINUX_USER% rather than
# the old `[your-linux-username]` placeholder, and had not drifted from the account the root pass
# creates. The .cmd does not print that line any more -- course-install.sh does, from $DIR -- so
# all three would now be reading an empty string, and two of them were NEGATIVE assertions that
# pass for free against one. The property they were after is asserted for real by
# `win-signoff:finishes` above, which supplies that path as {{UNC}} and so can only match if
# the message and win_projects_path agree about it.

# ─── --no-launch, and the order of what follows it ─────────────────────────────
# THE CREATE IS ASKED FOR WITHOUT A LAUNCH, and its exit code is CHECKED -- which it could not be
# before, because the code belonged to the shell `wsl --install` started. Both halves are pinned:
# a version that dropped --no-launch would fire Ubuntu's first-run questions at a student, and one
# that dropped the check would carry on past a failed create.
install_line="$(sed 's/\r$//' "$W" | grep -n -- '--install -d %IMAGE_NAME%' | head -1)"
assert_match "windows:creates-the-environment-without-launching-it" '\-\-no-launch$' "$install_line"
install_ln="${install_line%%:*}"
next_line="$(sed 's/\r$//' "$W" | sed -n "$((install_ln + 1))p")"
assert_match "windows:checks-the-create-exit-code" '^if %errorlevel% neq 0 goto ' "$next_line"

# THE ORDER OF THE WHOLE PROVISIONING SEQUENCE, which no wine run can prove is complete: the
# first-run setup goes off before the download, the root pass runs before the restart, the restart
# before the handover check, and the handover check before the student's pass. Every one of those
# is a failure that would be silent -- the worst of them installs the course into /root.
ln_of() { sed 's/\r$//' "$W" | grep -n -- "$1" | head -1 | cut -d: -f1; }
mv_ln="$(ln_of '\-e mv /etc/wsl-distribution.conf')"
dl_ln="$(ln_of 'curl -fsSL')"
prov_ln="$(ln_of 'env CS193V_PROVISION=1 bash %STAGE2%')"
term_ln="$(ln_of '\-\-terminate %DISTRO%')"
own_ln="$(ln_of '\-e test -O /home/%LINUX_USER%')"
stage2_ln="$(ln_of '\-e env CS193V_WINDOWS=1 bash %STAGE2%')"
seq_have="$(printf '%s\n' "$mv_ln" "$dl_ln" "$prov_ln" "$term_ln" "$own_ln" "$stage2_ln" | grep -c .)"
assert_eq "windows:the-provisioning-sequence-was-found" "6" "$seq_have"
assert_eq "windows:the-provisioning-sequence-is-in-order" "sorted" \
          "$(printf '%s\n' "$mv_ln" "$dl_ln" "$prov_ln" "$term_ln" "$own_ln" "$stage2_ln" \
             | { sort -c -n 2>/dev/null && echo sorted || echo "out-of-order: $mv_ln $dl_ln $prov_ln $term_ln $own_ln $stage2_ln"; })"

# AND THE STUDENT'S PASS IS THE ONE THAT IS NOT ROOT. Everything before it runs `-u root`
# deliberately -- the download, so a re-run can overwrite its own root-owned file; the probes and
# the root pass, so they mean the same thing whichever way /etc/wsl.conf has been left. The last
# call must NOT, or the whole point of the split is gone.
stage2_full="$(sed 's/\r$//' "$W" | grep -- '-e env CS193V_WINDOWS=1 bash %STAGE2%' | head -1)"
assert_ne "windows:the-student-pass-line-is-there" "" "$stage2_full"
assert_not_contains "windows:the-student-pass-is-not-root" "-u root" "$stage2_full"
assert_contains "windows:the-root-pass-is-root" "-u root" \
                "$(sed 's/\r$//' "$W" | grep -- 'env CS193V_PROVISION=1 bash %STAGE2%' | head -1)"
assert_contains "windows:the-download-is-root" "-u root" \
                "$(sed 's/\r$//' "$W" | grep -- 'curl -fsSL' | head -1)"
assert_ok "windows:names-the-same-distro-as-the-sh"  \
          sh -c "grep -q 'DISTRO=CS193V' '$W' && grep -q 'WSL_DISTRO=\"CS193V\"' $PRIVATE/course-install.sh"
# A .cmd, not a .ps1, so a downloaded file just runs instead of teaching students to click
# past security warnings in a course about not trusting code.
#
# $PRIVATE, not a bare name: this file does `cd "$REPO"` at the top, so the relative form this
# check used to have looked in the repo root while the .cmd lives one directory down -- a
# .private/install-cs193v-windows.ps1 passed it.
assert_no_file "windows:is-cmd-not-ps1" "$PRIVATE/install-cs193v-windows.ps1"

# $TESTS_DIR, not `dirname "$0"`, and for the reason the assert_no_file above gives: this file
# does `cd "$REPO"` at the top. The two sources at the head of the file run BEFORE that cd and
# so a relative $0 resolves; this one runs after it, and resolved to $REPO/lib/cmdlint.sh --
# which does not exist. Via run-tests.sh $0 is absolute and it worked anyway, so the breakage
# only showed when the suite was run by hand from tests/, where it cost 19 windows:* assertions
# an `exit 127` apiece and read as the .cmd being broken rather than the source line.
. "$TESTS_DIR/lib/cmdlint.sh"

# CRLF is not a tidiness preference. cmd.exe reads a batch file in 512-byte chunks and its label
# scanner assumes a two-byte \r\n terminator, so under LF-only endings `goto`/`call :label` fails
# NON-DETERMINISTICALLY by byte offset -- inserting a byte anywhere earlier can make it appear or
# vanish, and duplicating labels does not fix it. Wine reads bare \n natively (batch.c:259-266),
# so no execution test can ever see this.
assert_eq "windows:has-crlf-line-endings" "" "$(run_checker cmdlint_line_endings "$W")"

# 7-bit ASCII only. Wine and real cmd.exe both decode batch as OEM with no BOM or UTF-8 support,
# and `chcp` cannot change it (batch.c:245), so a non-ASCII byte is mojibake on some machine.
assert_eq "windows:is-ascii-only" "" "$(run_checker cmdlint_non_ascii "$W")"

assert_eq "windows:every-goto-resolves" "" "$(run_checker cmdlint_labels "$W")"

# `echo` arguments must not contain cmd metacharacters. Redirection characters are extracted
# BEFORE echo runs, so the message is silently lost rather than mangled; and inside a block a
# bare `)` closes it early, which breaks even a balanced pair.
assert_eq "windows:messages-reach-the-student" "" "$(run_checker cmdlint_echo_specials "$W")"

# `::` inside a parenthesized block. Wine accepts it, real cmd.exe treats it as a label and
# errors, so this rule exists precisely because the wine tier would pass either way.
assert_eq "windows:no-comments-inside-blocks" "" "$(run_checker cmdlint_comments_in_blocks "$W")"

# Every external command must have its exit code checked, in a form that survives a NEGATIVE
# code. `if errorlevel N` is a >= test, so it is false for -1 -- which is exactly what wsl.exe
# returns for every failure (WslClient.cpp: `exitCode = -1`). Measured under wine: a program
# exiting -1 leaves `if errorlevel 1` unfired and `if %errorlevel% neq 0` fired.
assert_eq "windows:failures-are-detected" "" "$(run_checker cmdlint_unchecked_calls "$W")"

# A `for /f` capture must be initialised before and validated after. On empty output the loop
# body never runs, so the variable silently keeps whatever it held.
assert_eq "windows:captures-are-guarded" "" "$(run_checker cmdlint_captures "$W")"

# ─── two rules the file's own PROSE must not be able to trip or satisfy ────────
#
# Both of these ban a construct that the header also NAMES, in order to explain why it is
# banned. A grep over the raw file therefore flags the explanation -- measured twice while
# writing this, once for each rule. _cmdlint_commands drops comments, labels and blank lines and
# keeps the real line number in field 2, so the work list is the code and only the code.

# The sibling, the path translation and the scratch file are gone, not merely unused. Left in
# place they would be a second route to stage two that nothing drives.
#
# %TEMP% IS BANNED AGAIN, having been allowed for one commit. It was lifted when the virtualisation
# gate needed scratch space for a tarball; that gate is gone (see the .cmd's own header) and its
# replacement writes no files at all, so the third leg of the old route goes back under the ban.
# The point of banning it is not that %TEMP% is dangerous -- it is that stage two must have exactly
# one route, and a scratch file on Windows is how the second one grew last time.
assert_eq "windows:does-not-look-for-a-sibling" "" \
          "$(_cmdlint_commands "$W" \
             | awk -F'\t' '$4 ~ /%HERE%|wslpath|%TEMP%/ { print "line " $2 ": " $4 }')"

# ─── there is NO virtualisation pre-flight, and that is now the assertion ─────
#
# TWO OF THEM HAVE BEEN REMOVED FROM THIS FILE, and this rule is what stops a third arriving by
# habit. #112's fix asked Windows for a property (HypervisorPresent, with two more probes behind
# it to say which cause it was); #114's fix imported a throwaway distribution and asked whether it
# registered. The first was wrong on a VirtualBox guest, where a hypervisor is present but not one
# WSL2 can use. The second could never say yes at all -- `wsl --import` validates the rootfs before
# registering, and the payload was a tar of an empty directory -- so it refused every machine on
# earth, including one with a VM running, and both test tiers stayed green while it did.
#
# WHAT REPLACES THEM IS ASSERTED IN 27, not here: the create's own failure already carries
# Microsoft's message and its HCS scope chain, and the refusals now print that instead of talking
# over it. What is left for a STATIC rule is the absence -- nothing may ask about virtualisation
# before the work that needs it, because the answer is not knowable in advance and two attempts
# have now proved it the expensive way.
#
# Matched on the constructs, not on a label: a third attempt would not reuse these names, but it
# would have to interrogate the machine somehow, and these are the four ways tried so far.
assert_eq "windows:asks-nothing-about-virtualisation-in-advance" "" \
          "$(_cmdlint_commands "$W" \
             | awk -F'\t' '$4 ~ /HypervisorPresent|VirtualizationFirmwareEnabled|VirtualMachinePlatform|--import/ { print "line " $2 ": " $4 }')"

# ...and the diagnosis must come AFTER the thing it explains, which is the ordering that replaces
# the old "gate must precede the create" pair. Reading wsl.exe's message is only sound once
# something has already failed: as a pre-flight the same read would be a gate, and a wrong answer
# would refuse a working machine. Both line numbers must exist, so deleting either goes red.
create_ln="$(sed 's/\r$//' "$W" | grep -n -- '-d %IMAGE_NAME%' | head -1 | cut -d: -f1)"
vmfail_ln="$(sed 's/\r$//' "$W" | grep -n 'Command "%VMFAILPROBE%"' | head -1 | cut -d: -f1)"
assert_ok "windows:diagnoses-virtualisation-only-after-the-create" \
          sh -c "test -n '$create_ln' && test -n '$vmfail_ln' && test '$create_ln' -lt '$vmfail_ln'"

# The installer ASKS about the boot configuration and does not CHANGE it -- see the rule's own
# header in lib/cmdlint.sh for why that is a decision and not an omission.
assert_eq "windows:never-writes-the-boot-configuration" "" \
          "$(run_checker cmdlint_bcdedit_writes "$W")"

# ...AND THE RULE CAN GO RED, demonstrated rather than trusted. Every other rule in this section
# has a real violation in the file's history to point at. This one guards a decision that was
# never coded, so a typo in its regex would be indistinguishable from a clean file -- which is
# the same "a gate that cannot go red is an assertion only in appearance" the deleted
# install-cs193v.sh grep above was killed for.
# BOTH ROUTES, because the rule claims to reach both and a demonstration of one would leave the
# other as an assertion about a regex nobody ran. The direct call is the obvious way in; the
# PowerShell one is the likely way in, since three probes already go that way.
for route in 'bcdedit /set hypervisorlaunchtype Auto' \
             'powershell -NoProfile -Command "bcdedit /set hypervisorlaunchtype Auto"'; do
    violating="$TMP/bcdedit-violation.cmd"
    { sed 's/\r$//' "$W"; printf '%s\n' "$route"; } | sed 's/$/\r/' > "$violating"
    assert_ne "windows:the-boot-configuration-rule-catches-[$route]" "" \
              "$(run_checker cmdlint_bcdedit_writes "$violating")"
done

# ...and the file must not name bcdedit AT ALL any more, which is the opposite of what it used to
# be held to. It used to hand the command over as text, and the assertion here required that echo
# to exist -- the rule's own header still records that its first version flagged that message.
# Issue #114 replaced the four per-cause arms with one refusal that hands over nothing and directs
# the student to course staff, so the echo went, and the assertion pinning it went with it: a test
# describes intended behaviour, and this behaviour is no longer intended.
#
# Asserted rather than merely deleted, because "hands over no commands" is a DECISION and needs a
# keeper. The read-only `bcdedit /enum` probe is gone too, so the name should appear in no COMMAND.
#
# COMMANDS, NOT THE RAW FILE, and that distinction was measured the hard way twice. The first
# version of the rule in lib/cmdlint.sh flagged the message that handed the command over; the
# first version of THIS assertion flagged the .cmd's own header comment explaining which probes
# were removed and why. Both times the file was correct and the grep was too wide. A comment that
# records a retired approach is exactly what keeps the next person from re-adding it, so banning
# the word outright would delete the documentation to protect the decision it documents.
assert_eq "windows:hands-over-no-boot-configuration-command" "" \
          "$(_cmdlint_commands "$W" \
             | awk -F'\t' 'tolower($4) ~ /bcdedit/ { print "line " $2 ": " $4 }')"

# %HERE% was the only thing DEMONSTRATING the header's delayed-expansion ban: `Down!loads`
# silently became `Downloads` when %~dp0 was expanded under it. With %HERE% gone the rule needs
# its own keeper, or the ban becomes documentation with nothing behind it.
assert_eq "windows:never-enables-delayed-expansion" "" \
          "$(_cmdlint_commands "$W" \
             | awk -F'\t' 'tolower($4) ~ /enabledelayedexpansion|\/v:on/ { print "line " $2 ": " $4 }')"

# ─── the current-directory hole, and the three lines that close it (issue #125) ───
#
# install-cs193v-windows.cmd runs elevated -- its own instructions are "right-click and Run as
# administrator" -- so its working directory is the folder the student downloaded it into, normally
# Downloads. cmd.exe resolves an unqualified program name against THAT DIRECTORY BEFORE %PATH%, so
# a bare `wsl.exe` ran whatever copy was sitting there, with Administrator rights. Twelve call
# sites, one of them the handoff to stage two. lib/cmdlint.sh's own header carries the measurement.
#
# QUALIFYING THE CALLS IS THE FIX; the other two lines are ADDITIVE. That distinction is the whole
# reason each gets its own keeper. The environment variable protects only what FOLLOWS it and is
# invisible at the eighteen call sites relying on it, so a reader who finds it must not conclude a
# bare `wsl.exe` would now be safe, and a refactor that moves it must not quietly un-protect the
# file. Deleting a `%SYS32%\` is a visible change at the line; deleting the `set` is not.
assert_eq "windows:every-program-is-fully-qualified" "" \
          "$(run_checker cmdlint_unqualified_programs "$W")"

# The system directory must come FROM the system. A rule that only checks for the %SYS32%\ prefix
# is satisfied by `set "SYS32=."`, which would pass every check above while pointing the whole file
# back at the download folder. Matched anywhere in the command and not anchored, because the second
# definition sits behind `if defined PROCESSOR_ARCHITEW6432` and an anchored pattern would see one.
sys32_defs="$(_cmdlint_commands "$W" | awk -F'\t' 'tolower($4) ~ /set[ \t]*"?sys32=/ { print $4 }')"
assert_eq "windows:the-system-directory-is-defined-twice" "2" \
          "$(printf '%s\n' "$sys32_defs" | grep -c 'SYS32=' || true)"
assert_eq "windows:the-system-directory-comes-from-the-system" "" \
          "$(printf '%s\n' "$sys32_defs" | grep -vF -e '%SystemRoot%\System32' -e '%SystemRoot%\Sysnative' || true)"

# 32-BIT HOSTS ARE WHY Sysnative is there, and it is not theoretical. Measured from the real
# C:\Windows\SysWOW64\cmd.exe on Windows 11 26200: %SystemRoot%\System32\wsl.exe is MISSING there,
# because WOW64 redirects System32 to SysWOW64 and wsl.exe exists only in the native one, while
# %SystemRoot%\Sysnative\wsl.exe is found and launches. Without this arm the fix would not be
# insecure, it would be broken -- which is a worse failure and a harder one to attribute.
assert_eq "windows:a-32-bit-host-reaches-the-native-system-directory" "" \
          "$(_cmdlint_commands "$W" \
             | awk -F'\t' 'tolower($4) ~ /sysnative/ { found = 1 }
                           END { if (!found) print "no Sysnative arm: a 32-bit cmd.exe resolves %SystemRoot%\\System32 to SysWOW64, where wsl.exe does not exist" }')"

# THE TWO ADDITIVE LINES, each pinned so it cannot be dropped silently. `cd /d` is the only one of
# the three that also closes DLL planting: with SafeDllSearchMode on the current directory is
# searched AFTER the system directories, so a DLL named like a system one cannot win -- but one that
# is in no system directory can, and leaving Downloads is what removes that.
assert_ne "windows:the-current-directory-search-is-off" "" \
          "$(_cmdlint_commands "$W" \
             | awk -F'\t' '$1 == 0 && $4 ~ /NoDefaultCurrentDirectoryInExePath=1/ { print "line " $2 }')"
assert_ne "windows:leaves-the-download-folder" "" \
          "$(_cmdlint_commands "$W" \
             | awk -F'\t' '$1 == 0 && tolower($4) ~ /^[ \t]*cd[ \t]+\/d[ \t]+"?%systemroot%"?[ \t]*$/ { print "line " $2 }')"

# ...AND THE GUARD MUST COME FIRST, which is the half of it that is genuinely load-bearing.
# Measured in a real .cmd on Windows 11 26200: a bare exe invoked BEFORE the `set` still resolved
# from the current directory, the same call after it did not, and clearing the variable re-enabled
# the search. So cmd re-reads it per command in batch mode and ORDER is the whole contract -- note
# that this is NOT true of `cmd /c "a & b"`, where the search path is fixed once for the line, which
# is why the same measurement taken that way looks like the variable does nothing.
# Both numbers must exist, so renaming either side goes red rather than quietly comparing nothing.
guard_ln="$(_cmdlint_commands "$W" | awk -F'\t' '$4 ~ /NoDefaultCurrentDirectoryInExePath=1/ { print $2; exit }')"
firstext_ln="$(_cmdlint_commands "$W" \
               | awk -F'\t' -v builtins="$CMDLINT_BUILTINS" '
                 BEGIN { split(builtins, b, "|"); for (i in b) isb[b[i]] = 1 }
                 { w = $3; sub(/\.exe$/, "", w); if (!isb[w]) { print $2; exit } }')"
assert_ok "windows:the-guard-precedes-every-external-call" \
          sh -c "test -n '$guard_ln' && test -n '$firstext_ln' && test '$guard_ln' -lt '$firstext_ln'"

# ...AND THE RULE CAN GO RED, demonstrated per route rather than trusted. Same reason as the
# boot-configuration rule above: this one now guards a property the file has EVERYWHERE, so a typo
# in its regex would be indistinguishable from a clean file. THREE ROUTES, because the rule has two
# halves and the third case is the only thing the second half exists for -- a program named inside a
# string `set` builds and a later `powershell` call runs, where the first word is `set` and looking
# at first words is structurally blind. The middle route is the one that matters most for `where`:
# the PROGRAM is qualified and its ARGUMENT is the name actually being resolved.
for route in 'wsl.exe --status' \
             '"%SYS32%\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "wsl.exe -l -q"' \
             'set "P2=$env:WSL_UTF8=1; wsl.exe -l -q"'; do
    violating="$TMP/unqualified-violation.cmd"
    { sed 's/\r$//' "$W"; printf '%s\n' "$route"; } | sed 's/$/\r/' > "$violating"
    assert_ne "windows:the-qualification-rule-catches-[$route]" "" \
              "$(run_checker cmdlint_unqualified_programs "$violating")"
done

# ─── the macOS entry point: a prebuilt applet  (#134) ──────────────────────────
# WHAT CHANGED AND WHY THE ASSERTIONS MOVED. This used to be a bundle whose CFBundleExecutable
# was a /bin/sh script, and roughly ten assertions here read that script as text. Two measured
# defects killed that shape: Launch Services cannot read an architecture out of a script, so
# Apple Silicon offers Rosetta; and TCC attributes the Automation grant to the INTERPRETER, so
# the grant landed on /bin/sh -- meaning every shell script the student ever ran gained
# permission to control Terminal, and the usage string was never shown because the prompt did
# not name the app. A compiled applet is a real universal Mach-O with a real identity.
#
# THE APPLET IS BUILT AT AUTHORING TIME AND COMMITTED, for a reason a student's Mac cannot get
# around: `codesign` shells out to /usr/bin/codesign_allocate, which is a Command Line Tools
# shim, so on a Mac without the CLT it can verify but not sign. A bundle compiled there could
# not be re-sealed after its Info.plist was written, and a broken seal damages exactly the
# identity the applet exists to have. macapp/make-macapp.sh does that work; this file checks
# what it produced. Same trade as the icons (11-export.sh:68).
#
# WHAT STAYS PORTABLE, WHICH IS MORE THAN IT LOOKS. install_mac_app now COPIES a prebuilt
# bundle and writes one text file, so its behaviour is checkable on Linux exactly as before; and
# plist_get reads binary plists through python's plistlib, so the metadata is too. Only three
# questions genuinely need a Mac -- the Mach-O's architectures, the signature, and decompiling
# the script -- and those are gated below. The helper is a shell script, so the synchronisation
# it implements stays verifiable everywhere.

# ── the committed artifact ─────────────────────────────────────────────────────
MACAPP="$PRIVATE/macapp/CS193V.app"
assert_file "applet:source-is-committed"   "$PRIVATE/macapp/cs193v-app.applescript"
assert_file "applet:builder-is-committed"  "$PRIVATE/macapp/make-macapp.sh"
assert_file "applet:executable-is-there"   "$MACAPP/Contents/MacOS/applet"
assert_exec "applet:executable-is-executable" "$MACAPP/Contents/MacOS/applet"
assert_file "applet:icon-is-in-resources"  "$MACAPP/Contents/Resources/cs193v.icns"
assert_exec "applet:helper-is-in-resources" "$MACAPP/Contents/Resources/cs193v-run"
assert_file "applet:script-is-compiled"    "$MACAPP/Contents/Resources/Scripts/main.scpt"
# AND NOT osacompile's DROPLET ASSETS: Assets.car is 375 KB of template UI this applet never
# shows, and shipping it would mean raising the student tree's size ceiling to carry something
# nothing reads. Measured safe to drop -- the applet still runs and `display alert` still works.
assert_no_file "applet:carries-no-droplet-assets" "$MACAPP/Contents/Resources/Assets.car"
assert_no_file "applet:carries-no-template-icon"  "$MACAPP/Contents/Resources/applet.icns"

# plistlib, NOT plutil, so this runs on Linux -- the same reason the old plist_get gave. It
# reads the binary plist osacompile writes without caring that it is binary.
applet_plist() {                      # applet_plist KEY -> value | key-absent | sentinel
    python3 - "$MACAPP/Contents/Info.plist" "$1" <<'APLIST' 2>/dev/null || printf 'plist-unreadable'
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    print(plistlib.load(f).get(sys.argv[2], 'key-absent'))
APLIST
}
assert_eq "applet:plist-names-the-executable-that-is-there" "applet" "$(applet_plist CFBundleExecutable)"
assert_eq "applet:plist-display-name-is-the-label"   "$MAC_LABEL"   "$(applet_plist CFBundleDisplayName)"
assert_eq "applet:plist-name-is-the-label"           "$MAC_LABEL"   "$(applet_plist CFBundleName)"
assert_eq "applet:plist-carries-the-icon-file"       "cs193v.icns"  "$(applet_plist CFBundleIconFile)"
assert_eq "applet:plist-identifier-is-stable"        "edu.stanford.cs193v.launcher" \
          "$(applet_plist CFBundleIdentifier)"
# The identifier matters more than it looks: TCC keys its grant on it, so changing it silently
# re-prompts every student who had already allowed the app.
assert_ne "applet:plist-explains-the-automation-prompt" "key-absent" \
          "$(applet_plist NSAppleEventsUsageDescription)"
# AND THESE TWO MUST BE ABSENT, not merely unread. They existed only to tell Launch Services
# what a shell script could not; a universal Mach-O declares its own architectures. Keeping them
# would be dead weight that a reader would mistake for load-bearing.
assert_eq "applet:declares-no-architecture-priority" "key-absent" "$(applet_plist LSArchitecturePriority)"

# NO EXTENDED ATTRIBUTES INSIDE THE SEAL, and this is not hypothetical: cs193v.icns had picked up
# `com.apple.quarantine ... Preview` from somebody opening it while the artwork was worked on, and
# the builder copied it into the bundle. Git launders xattrs so it never shipped -- but quarantine
# on any file in a bundle can make Gatekeeper assess an app that otherwise never would be, and the
# builder is the one place that decides what is inside the signature. Darwin-only: xattr(1) is
# macOS's, and on Linux there is nothing to find.
if [ "$(uname -s)" = Darwin ]; then
    xa="$(xattr -lr "$PRIVATE/macapp/CS193V.app" 2>/dev/null)"
    record    "applet:extended-attributes-found" "${xa:-none}"
    assert_eq "applet:carries-no-extended-attributes" "" "$xa"
else
    skip "applet:carries-no-extended-attributes" "needs macOS: xattr(1) has no Linux equivalent here"
fi
assert_eq "applet:does-not-require-native-execution" "key-absent" "$(applet_plist LSRequiresNativeExecution)"

# ── the three questions that need a Mac ────────────────────────────────────────
if [ "$(uname -s)" = Darwin ]; then
    # A REAL MACH-O COVERING BOTH ARCHITECTURES is the whole Rosetta fix, and the `x86_64` half
    # is what keeps an Intel Mac working (MANUAL.md 5.3).
    assert_eq "applet:covers-both-architectures" "x86_64 arm64" \
              "$(lipo -archs "$MACAPP/Contents/MacOS/applet" 2>/dev/null)"
    # THE SEAL, checked after every edit the builder makes. This is the assertion that catches a
    # git round-trip mangling Info.plist or CodeResources -- measured: without a path-scoped
    # `binary` attribute those two are rewritten under core.autocrlf and codesign reports
    # `invalid Info.plist`. The app still LAUNCHES in that state, so nothing else would notice.
    assert_ok "applet:bundle-is-sealed" codesign --verify "$MACAPP"
    # AND THE COMPILED SCRIPT REALLY IS THE COMMITTED SOURCE. A binary is the one artifact a
    # reviewer cannot read, so the link between it and the readable source is asserted rather
    # than trusted. Compared on the substantive lines, because osadecompile reformats.
    decompiled="$(osadecompile "$MACAPP/Contents/Resources/Scripts/main.scpt" 2>/dev/null)"
    assert_ne       "applet:script-decompiles"                    "" "$decompiled"
    assert_contains "applet:script-asks-terminal-to-do-script"    "do script"       "$decompiled"
    assert_contains "applet:script-blocks-on-the-fifo"            "read -r v"       "$decompiled"
    assert_contains "applet:script-closes-only-on-success"        "if verdict is"   "$decompiled"
    assert_contains "applet:script-reads-the-course-dir-record"   "course-dir"      "$decompiled"
    # THE TYPED COMMAND `cd`s THE INTERACTIVE SHELL FIRST, and this is a defect found by hand on
    # a real Mac rather than a nicety. The helper's own `cd` runs in a CHILD, so without this the
    # tab's shell stays in $HOME -- and on a refusal the student reads `./cs193v --stop`, which
    # messages.txt says in twelve places and which fails from anywhere but the course directory.
    # `;` not `&&`, so a bad directory still reaches the helper's own `cd "$1" || exit 1`, which
    # is what reports it.
    assert_contains "applet:script-cds-before-running-the-helper" '"cd "' "$decompiled"
    # IT CHECKS FOR THE LAUNCHER, NOT JUST FOR THE RECORD. Found by hand: a record pointing at a
    # course folder the student had moved got no CS193V wording at all, just two raw shell errors
    # in a tab, because the only test was whether `cat` returned something. `test -x DIR/cs193v`
    # is what "installed" actually means, and it also covers a path that is not a course tree and
    # a directory on an unmounted volume.
    assert_contains "applet:script-checks-the-launcher-is-really-there" '"test -x "' "$decompiled"
    assert_contains "applet:script-tests-the-launcher-path"            '"/cs193v"'   "$decompiled"
    assert_contains "applet:script-cds-in-the-same-typed-command" '"; "'  "$decompiled"
    # No placeholder survived into the shipped artifact.
    assert_not_match "applet:no-placeholder-survived-the-build"   '@@[A-Z_]+@@'     "$decompiled"
else
    for k in covers-both-architectures bundle-is-sealed script-decompiles \
             script-asks-terminal-to-do-script script-blocks-on-the-fifo \
             script-closes-only-on-success script-reads-the-course-dir-record \
             script-cds-before-running-the-helper script-cds-in-the-same-typed-command \
             script-checks-the-launcher-is-really-there script-tests-the-launcher-path \
             no-placeholder-survived-the-build; do
        skip "applet:$k" "needs macOS: lipo, codesign and osadecompile have no Linux equivalent"
    done
fi

# ── the helper, which is a text file and therefore portable ────────────────────
# EVERY TOKEN HERE WAS MEASURED, and an earlier design that opened the fd in the typed command
# instead could block the waiter forever. Comments stripped first, because the helper documents
# its own rules and a substring search would match the documentation -- 10-static.sh:13.
helper_code="$(sed 's/#.*//' "$PRIVATE/macapp/cs193v-run" 2>/dev/null)"
assert_ne       "helper:code-survived-comment-stripping" "" "$(printf '%s' "$helper_code" | do_tr -d ' \n')"
assert_contains "helper:opens-the-fifo-read-write"   '9<>'  "$helper_code"
# AND IT OPENS THAT FIFO BEFORE ANYTHING THAT CAN FAIL, which is an ORDERING and so needs an
# ordering assertion rather than a containment one. The waiter blocks in open(2) until a writer
# appears, so any line above the open is a region where a failure here strands the applet FOREVER:
# it never becomes a writer, EOF never comes, and a live blocked applet makes every later launch a
# silent no-op (#274) -- the app is bricked until the process is killed.
#
# MEASURED, on a real Mac, with `cd` above the open: a course-dir record pointing at a folder the
# student had moved left the applet blocked 15 minutes on a fifo with ZERO holders. The
# synchronisation review missed this because it reasoned only about what happens after the
# launcher starts, and every containment assertion above stayed green throughout.
fifo_line="$(printf '%s\n' "$helper_code" | grep -n '9<>' | head -1 | cut -d: -f1)"
risky_line="$(printf '%s\n' "$helper_code" | grep -nE '^[[:space:]]*(cd|\./cs193v)' | head -1 | cut -d: -f1)"
record    "helper:fifo-open-and-first-fallible-line" "open=${fifo_line:-none} first-fallible=${risky_line:-none}"
assert_ne "helper:both-lines-were-found" "" "${fifo_line:-}${risky_line:-}"
if [ -n "${fifo_line:-}" ] && [ -n "${risky_line:-}" ] && [ "$fifo_line" -lt "$risky_line" ]; then
    pass "helper:opens-the-fifo-before-anything-that-can-fail"
else
    fail "helper:opens-the-fifo-before-anything-that-can-fail" \
         "the fifo is opened on line ${fifo_line:-?} but the first line that can fail is
line ${risky_line:-?}. Anything failing above the open leaves the applet blocked in open(2) with no
writer, forever, and a blocked applet makes every later launch a silent no-op (#274)."
fi
assert_contains "helper:closes-the-fd-for-the-launcher" '9>&-' "$helper_code"

# AND THE SAME PROPERTY BEHAVIOURALLY, because a line-order assertion only guards the shape of
# today's fix. This runs the REAL helper against a course directory that does not exist, with a
# reader standing in for the applet's `read -r v < fifo`, and requires the reader to be RELEASED.
# Before the reorder it blocked in open(2) forever: the helper exited on its `cd` without ever
# becoming a writer, so EOF never arrived. Portable -- a fifo and two shells -- so unlike most of
# the applet checks this one also runs on Linux.
hdir="$TMP/helper-strand"; mkdir -p "$hdir"
hfifo="$hdir/fifo"; mkfifo "$hfifo" 2>/dev/null
( read -r hv < "$hfifo" || true; printf '%s' "${hv:-}" > "$hdir/verdict" ) &
hreader=$!
"$PRIVATE/macapp/cs193v-run" "$hdir/no-such-course-dir" "$hfifo" >/dev/null 2>&1
hrc=$?
if wait_until 10 test -f "$hdir/verdict"; then
    pass      "helper:releases-the-waiter-when-it-fails-before-the-launcher"
    assert_eq "helper:sends-no-verdict-on-an-early-failure" "" "$(cat "$hdir/verdict" 2>/dev/null)"
else
    kill "$hreader" 2>/dev/null
    fail "helper:releases-the-waiter-when-it-fails-before-the-launcher" \
         "the helper exited $hrc against a missing course directory and the reader was STILL
blocked 10s later -- which is the applet hanging forever on a fifo with no writer. Check that the
fifo is opened before the cd; see helper:opens-the-fifo-before-anything-that-can-fail."
    skip "helper:sends-no-verdict-on-an-early-failure" "the waiter never returned"
fi
wait "$hreader" 2>/dev/null || true
record "helper:early-failure-exit-status" "$hrc"
assert_contains "helper:runs-the-launcher"           './cs193v' "$helper_code"
# THE SENTINEL IS GATED ON THE EXIT STATUS. Unconditional, it would close the window ~100ms
# after a fast refusal and the student would never read the error.
assert_contains "helper:signals-only-on-success"     '[ "$st" -eq 0 ]' "$helper_code"
# AND IT MUST NOT exec THE LAUNCHER: that would make it the process group leader in place of the
# helper. The two `exec 9` forms are redirections and are fine, so the ban is on the launcher.
assert_not_contains "helper:does-not-exec-the-launcher" 'exec ./cs193v' "$helper_code"

# ── what install_mac_app does with it ─────────────────────────────────────────
# STILL PORTABLE, AND DELIBERATELY SO: the function copies a directory and writes one text file,
# neither of which needs a Mac. That is what keeps a Linux developer able to break this code and
# find out. The read-back names come out of the installer so there is one definition of each.
MAC_RECORD_REL="$(sed -n 's/^MAC_APP_RECORD="\([^"]*\)".*/\1/p' $PRIVATE/course-install.sh)"
assert_ne "mac-app:record-path-was-readable" "" "$MAC_RECORD_REL"

carve_func $PRIVATE/course-install.sh install_mac_app "$TMP/mac_app.sh"
if [ -s "$TMP/mac_app.sh" ]; then pass "extract:mac-app"
else fail "extract:mac-app" "could not carve install_mac_app out of course-install.sh"; fi

run_mac_app() {                       # run_mac_app DIR FAKEHOME PLAT -> whatever it printed
    (
        . "$TMP/mac_app.sh"
        # The stubs PRINT, because silent ones once made says-nothing-off-macos vacuous: it
        # asserted the empty string against a function whose every output path was muted, and
        # passed with the platform gate deleted.
        step() { printf 'STEP %s\n' "$*"; }
        ok()   { printf 'OK %s\n'   "$*"; }
        note() { printf 'NOTE %s\n' "$*"; }
        warn() { printf 'WARN %s\n' "$*"; }
        notes() { while IFS= read -r l; do note "$l"; done; }
        die() { printf 'DIED: %s\n' "$*"; exit 1; }
        msg() { printf '%s' "$*"; }
        MAC_APP_LABEL="$MAC_LABEL"; MAC_APP_RECORD="$MAC_RECORD_REL"
        DIR="$1"; HOME="$2"; PLAT="$3"
        install_mac_app
    )
}

# A COURSE DIRECTORY WITH A SPACE AND A QUOTE, because choose_dir's second option is "type a
# path" and #218 is the same failure one layer up. The fixture needs the real committed bundle
# in place, since the function copies rather than generates.
appdir="$TMP/mac/course dir with'quote"
mkdir -p "$appdir/.private" "$TMP/mac/home"
cp -R "$PRIVATE/macapp" "$appdir/.private/macapp"
out="$(run_mac_app "$appdir" "$TMP/mac/home" macos 2>&1)"
record "mac-app:install-said" "${out:-nothing}"
APP="$TMP/mac/home/Applications/$MAC_LABEL.app"
assert_contains "mac-app:announces-its-step"      "STEP step.mac-app" "$out"
assert_contains "mac-app:reports-where-it-put-it" "APP=$APP"          "$out"
assert_not_contains "mac-app:did-not-warn-on-a-good-run" "NOTE"       "$out"

assert_file "mac-app:bundle-was-copied"      "$APP/Contents/MacOS/applet"
assert_exec "mac-app:copied-helper-is-executable" "$APP/Contents/Resources/cs193v-run"
assert_file "mac-app:copied-icon-came-along" "$APP/Contents/Resources/cs193v.icns"

# THE COPY IS BYTE-IDENTICAL TO THE COMMITTED BUNDLE, which is one assertion standing in for the
# rule that nothing may ever be written INSIDE the bundle. Editing a signed bundle invalidates
# its seal, and a bundle that fails `codesign -v` has a damaged identity -- the one thing the
# applet exists to have. So the course directory goes in a record beside it, never in it.
assert_ok "mac-app:copy-is-identical-to-the-committed-bundle" \
          diff -r "$PRIVATE/macapp/CS193V.app" "$APP"

# AND THE RECORD CARRIES THE CHOSEN DIRECTORY EXACTLY, quote and space included. Compared by
# reading the file rather than grepping the bundle, because that is where it now lives.
assert_eq "mac-app:records-the-course-directory" "$appdir" \
          "$(cat "$TMP/mac/home/$MAC_RECORD_REL" 2>/dev/null)"

# A RERUN IS THE NORMAL CASE -- it is what a student is told to do when something went wrong.
printf 'a stale file no bundle should keep\n' > "$APP/Contents/MacOS/leftover"
out2="$(run_mac_app "$appdir" "$TMP/mac/home" macos 2>&1)"
record "mac-app:second-pass-said" "${out2:-nothing}"
assert_file    "mac-app:second-pass-leaves-a-bundle"       "$APP/Contents/MacOS/applet"
assert_no_file "mac-app:second-pass-sweeps-the-old-bundle" "$APP/Contents/MacOS/leftover"
assert_ok      "mac-app:second-pass-is-still-identical" \
               diff -r "$PRIVATE/macapp/CS193V.app" "$APP"

# THE GATE. Asserted because a step that ran everywhere would put an Applications directory and
# an unlaunchable bundle into a Linux student's home.
mkdir -p "$TMP/mac/home-linux"
out3="$(run_mac_app "$appdir" "$TMP/mac/home-linux" linux 2>&1)"
assert_eq      "mac-app:says-nothing-off-macos"   "" "$out3"
assert_no_file "mac-app:writes-nothing-off-macos" "$TMP/mac/home-linux/Applications/$MAC_LABEL.app/Contents/MacOS/applet"
assert_no_file "mac-app:writes-no-record-off-macos" "$TMP/mac/home-linux/$MAC_RECORD_REL"

# ─── the Windows Start Menu shim  (#134) ───────────────────────────────────────
# WHY THE WORK IS SPLIT ACROSS TWO FILES, and it is the same tension #218 resolved for the
# closing message. Only course-install.sh knows $DIR -- win_projects_path's comment at :183 says
# so -- and only install-cs193v-windows.cmd is a Windows process that can author a .lnk. So
# neither does the other's job: this side writes a shim at a FIXED path with $DIR baked into it,
# and the .cmd points a shortcut at that fixed path. No student-specific value crosses the
# boundary, which is what keeps `for /f` out of the .cmd and means none of this depends on WSL
# interop being available from inside the student pass.
carve_func $PRIVATE/course-install.sh install_win_shim "$TMP/win_shim.sh"
if [ -s "$TMP/win_shim.sh" ]; then pass "extract:win-shim"
else fail "extract:win-shim" "could not carve install_win_shim out of course-install.sh"; fi

# THE TWO FIXED PATHS, read back out of the installer for the reason mac-app:label-was-readable
# gives: the .cmd hardcodes the Windows spelling of both, so a rename here that this suite did
# not notice would leave a shortcut pointing at nothing.
assert_ne "win-shim:shim-name-was-readable" "" "$WIN_SHIM_PATH"
assert_ne "win-shim:icon-name-was-readable" "" "$WIN_ICON_PATH"

run_win_shim() {                      # run_win_shim DIR FAKEHOME WINFLAG -> whatever it printed
    (
        . "$TMP/win_shim.sh"
        step() { printf 'STEP %s\n' "$*"; }
        ok()   { printf 'OK %s\n'   "$*"; }
        note() { printf 'NOTE %s\n' "$*"; }
        die() { printf 'DIED: %s\n' "$*"; exit 1; }
        msg() { printf '%s' "$*"; }
        WIN_SHIM_NAME="$WIN_SHIM_PATH"; WIN_ICON_NAME="$WIN_ICON_PATH"
        DIR="$1"; HOME="$2"; CS193V_WINDOWS="$3"
        install_win_shim
    )
}

# THE SAME AWKWARD DIRECTORY AS THE MAC CASE, and for the same reason: choose_dir runs on the
# Windows path too, which is exactly the hole #218 found in the hardcoded {{UNC}}.
windir="$TMP/win/course dir with'quote"
mkdir -p "$windir/.private/icons" "$TMP/win/home"
printf 'stand-in for the real ico\n' > "$windir/.private/icons/cs193v.ico"
wout="$(run_win_shim "$windir" "$TMP/win/home" 1 2>&1)"
record "win-shim:generation-said" "${wout:-nothing}"
SHIM="$TMP/win/home/$WIN_SHIM_PATH"
assert_exec "win-shim:shim-is-executable" "$SHIM"
assert_file "win-shim:icon-was-copied"    "$TMP/win/home/$WIN_ICON_PATH"
assert_contains "win-shim:announces-its-step" "STEP step.win-shim" "$wout"

# ─── the shim is asserted by RUNNING it, not by reading it ─────────────────────
# The path in it is single-quote escaped, so for this directory the raw string is not in the
# file -- the same reason mac-app:carries-the-chosen-directory sources its DIR= line instead of
# grepping for it. Here the whole shim can simply be run against a stub launcher, which tests
# the cd, the quoting and the exit status in one go.
# `pwd -P` ON BOTH SIDES, NOT THE STRING WE PASSED IN. On macOS $TMPDIR ends in a slash, so
# $TMP/... carries a `//` that the shell collapses the moment it stores $PWD -- and /var is a
# symlink to /private/var besides. Comparing what we typed against what the shell resolved fails
# on a shim that went to exactly the right place. Measured: that was this assertion's first run.
printf '#!/bin/sh\npwd -P > "%s/win/RAN"\n' "$TMP" > "$windir/cs193v"
chmod +x "$windir/cs193v"
rm -f "$TMP/win/RAN"
if "$SHIM" >/dev/null 2>&1; then pass "win-shim:runs-cleanly"
else fail "win-shim:runs-cleanly" "the shim exited non-zero against a stub launcher"; fi
assert_eq "win-shim:lands-in-the-chosen-directory" \
          "$(cd "$windir" && pwd -P)" "$(cat "$TMP/win/RAN" 2>/dev/null)"

# A MISSING COURSE DIRECTORY MUST NOT LOOK LIKE A CLEAN RUN. The shim is what a Start Menu entry
# points at, so if the course tree has been moved or deleted the student clicks an icon and gets
# a window. Something has to be in it: a shim that ran `cd` unchecked would run ./cs193v from
# whatever directory WSL happened to start in, and `wsl --cd ~` makes that the home directory.
# FROM AN EMPTY DIRECTORY, AND ASSERTED ON WHAT IT SAYS -- both because of what the first
# version of this case measured. It ran the shim from the suite's own working directory, which
# is $REPO, and asked only "did it exit non-zero". $REPO CONTAINS A REAL ./cs193v: with the cd
# check deleted the shim fell through and ran the launcher itself, which refused for its own
# unrelated reason (no tty) and exited non-zero -- so the assertion passed, having tested
# nothing, and had quietly invoked the real launcher to do it. Mutation I of this block.
#
# An empty CWD removes the accident, and keying the assertion to the message removes the
# ambiguity: "exited non-zero" is true of almost any failure, while win-shim.moved is printed
# on exactly one path.
mkdir -p "$TMP/win/empty"
mv "$windir" "$TMP/win/moved-away"
moved_out="$(cd "$TMP/win/empty" && "$SHIM" 2>&1)" && moved_rc=0 || moved_rc=$?
mv "$TMP/win/moved-away" "$windir"
assert_eq       "win-shim:refuses-a-course-tree-that-moved" "1" "$moved_rc"
# THE DIRECTORY IT LOOKED IN, which is the student-visible contract -- the person who moved the
# folder is the only one who can put it back, and a window that opens and closes tells them
# nothing. Asserted as the PATH rather than through the catalogue on purpose: run_win_shim stubs
# msg(), so the prose baked into the shim here is the stub output, and a needle keyed to the real
# catalogue could never match. The path survives either renderer, so this assertion does not
# depend on which one generated the shim. The prose itself is 20-messages.sh's job -- it is what
# proves win-shim.moved exists, is non-empty and has its {{DIR}} supplied at exactly one site.
assert_contains "win-shim:says-where-it-looked" "$windir" "$moved_out"

# ─── shape, idempotency, and the gate ──────────────────────────────────────────
# The exec ban is the Windows half of the argument install_mac_app's header makes: the .lnk runs
# `bash -ic <shim>`, so the shim is a foreground job of an interactive shell and the launcher is
# its child -- inside the process group that a window close signals, and not the session leader,
# which is the one shape in which #170 is deterministic. Comments stripped first for the reason
# mac-app:never-execs records.
shim_code="$(sed 's/#.*//' "$SHIM" 2>/dev/null)"
assert_ne           "win-shim:code-survived-comment-stripping" "" "$(printf '%s' "$shim_code" | do_tr -d ' \n')"
assert_not_contains "win-shim:never-execs" "exec" "$shim_code"

printf 'stale\n' > "$TMP/win/home/$WIN_ICON_PATH"
wout2="$(run_win_shim "$windir" "$TMP/win/home" 1 2>&1)"
assert_exec "win-shim:second-pass-leaves-a-working-shim" "$SHIM"
assert_eq   "win-shim:second-pass-refreshes-the-icon" "stand-in for the real ico" \
            "$(cat "$TMP/win/home/$WIN_ICON_PATH" 2>/dev/null)"

# CS193V_WINDOWS IS THE GATE, the same variable say_done branches on -- it is set by
# install-cs193v-windows.cmd and by nothing else, so a Mac or Linux install never comes here.
mkdir -p "$TMP/win/home-unix"
wout3="$(run_win_shim "$windir" "$TMP/win/home-unix" '' 2>&1)"
assert_eq      "win-shim:says-nothing-without-the-windows-flag" "" "$wout3"
assert_no_file "win-shim:writes-nothing-without-the-windows-flag" "$TMP/win/home-unix/$WIN_SHIM_PATH"

# ─── the two files must agree about the Start Menu entry  (#134) ───────────────
# THREE CONSTANTS CROSS THE BOUNDARY AND NOTHING ENFORCES THEM BUT THIS. install_win_shim writes
# a shim and an icon at fixed paths in the student's WSL home; the .cmd hardcodes the Windows
# spelling of both and points a shortcut at them. Neither file imports anything from the other,
# so a rename on either side is a shortcut that opens a window with an error in it -- and the
# wine tier cannot catch it, because no Windows shell there ever resolves the shortcut. These are
# read out of BOTH files and compared, the same move windows:names-the-same-distro-as-the-sh
# makes for %DISTRO%.
WCMD="$(sed 's/\r$//' "$W")"
lnk_name="$(printf '%s\n' "$WCMD" | sed -n 's/^set "LNKNAME=\(.*\)"$/\1/p')"
lnk_args="$(printf '%s\n' "$WCMD" | sed -n 's/.*\$s\.Arguments = '"'"'\([^'"'"']*\)'"'"'.*/\1/p')"
lnk_target="$(printf '%s\n' "$WCMD" | sed -n 's/.*\$s\.TargetPath = '"'"'\([^'"'"']*\)'"'"'.*/\1/p')"
ico_copy="$(printf '%s\n' "$WCMD" | grep -- 'copy /y' | head -1)"
assert_ne "windows:the-shortcut-name-was-readable"   "" "$lnk_name"
assert_ne "windows:the-shortcut-args-were-readable"  "" "$lnk_args"
assert_ne "windows:the-shortcut-target-was-readable" "" "$lnk_target"

# ONE LABEL ACROSS BOTH PLATFORMS. It is the string students are told to look for, so a Mac and
# a Windows student have to be told the same one.
assert_eq "windows:the-start-menu-label-matches-the-mac-bundle" "$MAC_LABEL" "$lnk_name"
# AND THE SHORTCUT RUNS THE SHIM install_win_shim ACTUALLY WROTE.
assert_contains "windows:the-shortcut-runs-the-shim-the-installer-writes" \
                "$WIN_SHIM_PATH" "$lnk_args"
assert_contains "windows:the-icon-it-copies-is-the-one-the-installer-left" \
                "$WIN_ICON_PATH" "$ico_copy"

# SYSTEM32 AND NOT %SYS32%, which is the one place in that file where the difference bites:
# %SYS32% is %SystemRoot%\Sysnative under WOW64, and Sysnative is a redirector that exists only
# for the 32-bit process looking at it -- fine for running wsl from the script, unresolvable once
# baked into a .lnk that Explorer opens later.
assert_contains     "windows:the-shortcut-targets-a-real-system32-path" '%SystemRoot%\System32\wsl' "$lnk_target"
assert_not_contains "windows:the-shortcut-does-not-bake-sysnative"      'SYS32'  "$lnk_target"
# NOT WINDOWS TERMINAL. wt is an App Execution Alias: its backing path moves with every Store
# update and Settings can switch the alias off entirely.
assert_not_contains "windows:the-shortcut-does-not-target-windows-terminal" 'wt.exe' "$lnk_target"

# THE SHAPE, which is the Windows half of the argument install_mac_app's header makes. A bare
# `-- <shim>` runs the shim instead of a shell, which makes it the session leader and is the one
# state in which #170 is deterministic. `bash -ic` is an interactive shell with job control on,
# so the shim is a foreground job and the launcher its child.
assert_contains     "windows:the-shortcut-goes-through-an-interactive-shell" 'bash -ic' "$lnk_args"
assert_not_contains "windows:the-shortcut-does-not-run-the-launcher-itself"  './cs193v' "$lnk_args"

# ORDERING. The shim does not exist until stage two has run, so a shortcut created before it
# points at nothing. Compared by line number rather than by reading the file twice.
pass_line="$(printf '%s\n' "$WCMD" | grep -n -- 'env CS193V_WINDOWS=1 bash %STAGE2%' | head -1 | cut -d: -f1)"
lnk_line="$(printf '%s\n' "$WCMD" | grep -n -- 'set "LNKNAME=' | head -1 | cut -d: -f1)"
assert_ne "windows:both-lines-were-found" "" "${pass_line:-}${lnk_line:-}"
if [ -n "${pass_line:-}" ] && [ -n "${lnk_line:-}" ] && [ "$lnk_line" -gt "$pass_line" ]; then
    pass "windows:the-shortcut-is-made-after-the-student-pass"
else
    fail "windows:the-shortcut-is-made-after-the-student-pass" \
         "the Start Menu block is at line ${lnk_line:-?}, the student pass at ${pass_line:-?}"
fi

# AND WSL'S OWN ENTRY GOES. Two entries a letter apart is worse than either alone; the plain one
# opens a login shell in the home directory, not the launcher.
del_ps="$(printf '%s\n' "$WCMD" | sed -n 's/^set "PSDEL=\(.*\)"$/\1/p')"
assert_ne       "windows:the-delete-was-readable" "" "$del_ps"
assert_contains "windows:deletes-the-entry-named-for-the-distro" '%DISTRO%.lnk' "$del_ps"
assert_contains "windows:the-delete-is-guarded-on-the-target"    'TargetPath'   "$del_ps"

# ─── the four arms, asserted  (#134) ───────────────────────────────────────────
assert_eq "sign-off:macos-with-a-bundle-promises-the-app" \
          "finished.macos"            "$(run_say_done '' yes '')"
assert_eq "sign-off:macos-without-a-bundle-falls-back" \
          "finished"                  "$(run_say_done '' '' '')"
assert_eq "sign-off:windows-with-a-shortcut-promises-it" \
          "finished.windows-shortcut" "$(run_say_done 1 '' yes)"
assert_eq "sign-off:windows-without-a-shortcut-falls-back" \
          "finished.windows"          "$(run_say_done 1 '' '')"
# LINUX IS THE SAME ARM AS A MAC WHOSE BUNDLE FAILED, and that is the reason there are two new
# keys rather than four: the flags are empty everywhere their step does not run, so a Linux
# install reaches `finished` down the path it always did.
#
# BUT "EMPTY" AND "NEVER ASSIGNED" ARE NOT THE SAME THING UNDER `set -u`, and this assertion used
# to miss the difference -- it compared run_say_done to ITSELF, which no change could ever redden.
# The difference is the whole defect: MAC_APP_READY and WIN_SHIM_READY were set only INSIDE
# install_mac_app and install_win_shim, which return early off their own platform, so a Linux or
# WSL install reached say_done with them UNBOUND and died AT ITS OWN SIGN-OFF -- after smoke_test
# had already told the student the environment works. run_say_done cannot see that: it assigns all
# three flags itself, which is right for the four arms above and wrong for this one.
#
# So this arm sources say_done together with whatever column-0 initialisation the script really
# makes. 26-installer-sandbox.sh's student pass is what caught the defect end to end; this is the
# millisecond guard for the rule that keeps it fixed.
say_done_as_a_linux_install() {       # -> the key, or the shell's own error text
    (
        set -u
        eval "$(grep '^[A-Z][A-Z0-9_]*_READY=' $PRIVATE/course-install.sh)"
        . "$TMP/say_done.sh"
        msg() { printf '%s' "$1"; }
        win_projects_path() { printf 'UNC'; }
        DIR=/course; WSL_DISTRO=CS193V; MAC_APP_LABEL="a label"
        say_done
    ) 2>&1 | do_tr -d ' \n'
}
assert_eq "sign-off:a-linux-install-is-unchanged" "finished" "$(say_done_as_a_linux_install)"

# AND BY NAME AS WELL AS BY BEHAVIOUR, so a flag ADDED later inherits the rule rather than
# needing somebody to remember it. Every *_READY say_done reads bare -- ${X:-} forms are excluded
# by the pattern, because a default is its own initialisation -- must be assigned at column 0.
sd_flags="$(grep -o '\$[A-Z][A-Z0-9_]*_READY' "$TMP/say_done.sh" | do_tr -d '$' | sort -u)"
record    "sign-off:the-flags-say-done-reads" "${sd_flags:-none}"
assert_ne "sign-off:the-flag-list-was-readable" "" "$sd_flags"
for v in $sd_flags; do
    assert_ne "sign-off:$(printf '%s' "$v" | do_tr 'A-Z_' 'a-z-')-is-initialised-before-the-flow" \
              "" "$(grep "^$v=" $PRIVATE/course-install.sh)"
done
# AND THE WINDOWS FLAG WINS OVER A STALE MAC FLAG. Nothing sets both today; the arms are ordered
# so that if something ever did, a Windows student is not sent to an Applications folder.
assert_eq "sign-off:windows-wins-over-a-mac-flag" \
          "finished.windows-shortcut" "$(run_say_done 1 yes yes)"

# ─── the one-click entry points are the LAST thing a run does  (#134) ──────────
# NOT A STYLE POINT. install_mac_app and install_win_shim read icons that install_files has just
# unpacked, so sitting them next to it is the obvious placement and the wrong one: build_image
# and smoke_test can both still refuse, and a run that gets that far leaves a bundle in
# ~/Applications and an entry in the Start Menu pointing at an install that cannot start. #134
# asks for a way in that also makes sure a student really is inside the environment.
#
# IT IS ALSO WHAT LETS say_done TRUST MAC_APP_READY AND WIN_SHIM_READY. Those flags are set on
# the success path of these two steps; if either ran before something that could still abort, the
# sign-off could promise a gesture on a run that never finished.
#
# READ OFF THE CALL SEQUENCE, not the function definitions, which sit elsewhere in the file and
# in a different order on purpose.
flow="$(sed -n '/^say_welcome$/,/^say_done$/p' $PRIVATE/course-install.sh \
        | grep -vE '^[[:space:]]*(#|$)')"
flow_n() { printf '%s\n' "$flow" | grep -n "^$1\$" | head -1 | cut -d: -f1; }
for step in say_welcome install_files build_image smoke_test install_mac_app install_win_shim say_done; do
    assert_ne "flow:$step-is-in-the-sequence" "" "$(flow_n "$step")"
done
# AND THE ORDER, as three separate questions so a failure says which one moved.
for pair in smoke_test:install_mac_app smoke_test:install_win_shim \
            install_mac_app:say_done install_win_shim:say_done \
            build_image:install_mac_app install_files:build_image; do
    earlier="${pair%%:*}"; later="${pair#*:}"
    a="$(flow_n "$earlier")"; b="$(flow_n "$later")"
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then
        pass "flow:$earlier-runs-before-$later"
    else
        fail "flow:$earlier-runs-before-$later" \
             "$earlier is at line ${a:-absent} and $later at ${b:-absent} in the call sequence"
    fi
done
