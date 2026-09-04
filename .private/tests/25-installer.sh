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

set -u
. "$(dirname -- "$0")/lib/assert.sh"
. "$(dirname -- "$0")/lib/podman-shim.sh"

cd "$REPO" || exit 1
TMP="$(new_tmpdir)"

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
# version_lt is duplicated in cs193v-ui.sh and the installer. If they ever disagree, a
# student is told to upgrade by one and accepted by the other.
# carve_func (lib/shared.sh) is this sed, lifted out because three other places now need it;
# the reason it anchors on /^name()/ rather than the brace is recorded there.
carve_func $PRIVATE/files/cs193v-ui.sh version_lt "$TMP/vl_launcher.sh"
carve_func $PRIVATE/install-cs193v.sh  version_lt "$TMP/vl_installer.sh"
for f in vl_launcher vl_installer; do
    if [ "$(wc -l < "$TMP/$f.sh" | do_tr -d ' ')" -gt 3 ]; then pass "extract:$f"
    else fail "extract:$f" "could not extract version_lt"; exit 1; fi
done

# 5.7.0 vs 5.7.0 is the case that matters most: MIN_PODMAN is 5.7.0 and Ubuntu 26.04 ships
# exactly that, so "equal" must mean "acceptable" or every stock Ubuntu student is refused.
# 10.0.0 vs 5.7.0 guards against a lexical compare.
run_vl() { ( . "$TMP/$1.sh"; version_lt "$2" "$3" ); }
for pair in "5.7.0 5.7.0 no" "5.6.0 5.7.0 yes" "5.6.9 5.7.0 yes" "5.7.1 5.7.0 no" \
            "10.0.0 5.7.0 no" "5.7 5.7.0 no" "5.7.0 5.7 no" "6 5.7.0 no" \
            "4.9.3 5.7.0 yes" "0.0.1 5.7.0 yes" "5.10.0 5.9.0 no" "5.9.0 5.10.0 yes"; do
    set -- $pair
    a="$1"; b="$2"; want="$3"
    assert_eq "version_lt:launcher($a<$b)"  "$want" "$(run_vl vl_launcher  "$a" "$b")"
    assert_eq "version_lt:installer($a<$b)" "$want" "$(run_vl vl_installer "$a" "$b")"
done
# 5.10 vs 5.9 is the classic numeric-vs-lexical trap; asserted above for both copies.

# ─── and the two floors it is compared against ─────────────────────────────────
# THE FUNCTION IS DUPLICATED AND SO ARE THE NUMBERS. version_lt is checked above; the floors are
# declared separately in install-cs193v.sh and in cs193v, for the reason the duplication exists at
# all -- the installer is curl-piped and cannot source the launcher.
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
for plat in LINUX MACOS; do
    mp_inst="$(sed -n "s/^MIN_PODMAN_$plat=\"\([^\"]*\)\".*/\1/p" $PRIVATE/install-cs193v.sh)"
    mp_lnch="$(sed -n "s/^MIN_PODMAN_$plat=\"\([^\"]*\)\".*/\1/p" "$REPO/cs193v")"
    # NON-EMPTY FIRST, both of them, and this is the guard rather than pedantry: an empty-vs-empty
    # comparison passes forever, which is the exact trap this file records at its top for
    # version_lt. A renamed constant or a changed quoting style would make the sed match nothing.
    assert_ne "min-podman:installer-declares-$plat" "" "$mp_inst"
    assert_ne "min-podman:launcher-declares-$plat"  "" "$mp_lnch"
    assert_eq "min-podman:the-two-$plat-floors-agree" "$mp_inst" "$mp_lnch"
    record    "min-podman:$plat-floor" "$mp_inst"
    # EXACTLY ONE DECLARATION IN EACH, because a second one later in either file would shadow the
    # first and the check above would read the wrong number. Counted rather than assumed: the sed
    # takes every match, so two lines would give "4.9.0\n5.7.0" and compare unequal by luck
    # rather than by design -- and two IDENTICAL extra lines would compare equal and hide it.
    assert_eq "min-podman:installer-declares-$plat-once" "1" \
              "$(grep -c "^MIN_PODMAN_$plat=" $PRIVATE/install-cs193v.sh)"
    assert_eq "min-podman:launcher-declares-$plat-once"  "1" \
              "$(grep -c "^MIN_PODMAN_$plat=" "$REPO/cs193v")"
done
# AND THE MAC FLOOR IS NEVER THE LOWER OF THE TWO, which is the whole point of splitting them: the
# Linux floor exists to be lowered as distros are measured, and the macOS one exists to stay put.
# Someone lowering "the floor" and touching only the pair they noticed would invert that silently.
# Checked with the installer's own version_lt, already extracted above.
mp_lin="$(sed -n 's/^MIN_PODMAN_LINUX="\([^"]*\)".*/\1/p' $PRIVATE/install-cs193v.sh)"
mp_mac="$(sed -n 's/^MIN_PODMAN_MACOS="\([^"]*\)".*/\1/p' $PRIVATE/install-cs193v.sh)"
assert_eq "min-podman:mac-floor-is-not-below-the-linux-one" "no" \
          "$(run_vl vl_installer "$mp_mac" "$mp_lin")"

# ─── the PATH repair is the same code in both copies  (issue #121) ─────────────
# ensure_podman_path is the third function the installer has to carry rather than source, and
# it is the one where a disagreement is worst: this script runs FIRST, reports success, and
# hands the student a launcher that runs LAST. If the two ever answer differently about where
# podman is, the student sees "Setup finished" followed by "Podman is not installed" -- which
# IS issue #121, and is what it looked like the first time.
pkg_inst="$(sed -n 's/^PODMAN_PKG_ID="\([^"]*\)".*/\1/p' $PRIVATE/install-cs193v.sh)"
pkg_lnch="$(sed -n 's/^PODMAN_PKG_ID="\([^"]*\)".*/\1/p' "$REPO/cs193v")"
# NON-EMPTY FIRST, both of them, for the reason the floors above give: empty-vs-empty passes
# forever, and a renamed constant makes the sed match nothing.
assert_ne "probe:installer-declares-the-package-id" "" "$pkg_inst"
assert_ne "probe:launcher-declares-the-package-id"  "" "$pkg_lnch"
assert_eq "probe:the-two-package-ids-agree" "$pkg_inst" "$pkg_lnch"
record    "probe:package-id" "$pkg_inst"
assert_eq "probe:installer-declares-the-package-id-once" "1" \
          "$(grep -c '^PODMAN_PKG_ID=' $PRIVATE/install-cs193v.sh)"
assert_eq "probe:launcher-declares-the-package-id-once"  "1" \
          "$(grep -c '^PODMAN_PKG_ID=' "$REPO/cs193v")"

# AND THE BODIES, not just the constant. carve_func's own header explains why an empty carving
# is the trap here: sourced, it asserts nothing and passes.
carve_func "$PRIVATE/install-cs193v.sh" ensure_podman_path "$TMP/probe_installer.sh"
assert_ok "extract:probe_installer" test -s "$TMP/probe_installer.sh"
carve_func "$REPO/cs193v"              ensure_podman_path "$TMP/probe_launcher.sh"
assert_ok "extract:probe_launcher"  test -s "$TMP/probe_launcher.sh"
assert_eq "probe:the-two-copies-are-byte-identical" "" \
          "$(diff "$TMP/probe_installer.sh" "$TMP/probe_launcher.sh")"

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

for f in installer launcher; do
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
for f in ui:$PRIVATE/files/cs193v-ui.sh inst:$PRIVATE/install-cs193v.sh; do
    sed -n '/^menu() {/,/^}$/p' "${f#*:}" \
        | sed -n '/case "\$key" in/,/esac/p' | sed 's/^[[:space:]]*//' > "$TMP/keys.${f%%:*}"
done
# Extraction asserted first, or an empty file would match an empty file and this would pass
# forever having read nothing — the trap this suite records for version_lt above.
if [ "$(grep -c '.' "$TMP/keys.ui")" -ge 5 ]; then pass "menu:key-table-extractable"
else fail "menu:key-table-extractable" "could not find menu()'s case block in cs193v-ui.sh"; fi
assert_eq "menu:same-keys-in-both-copies" "" "$(diff "$TMP/keys.ui" "$TMP/keys.inst" 2>&1)"
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
sed -n '/^mac_vm_target_mb()/,/^}$/p' $PRIVATE/install-cs193v.sh >> "$TMP/vm.sh"
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
# Shaped the way GitHub's archive endpoint shapes it -- a single top-level directory, which
# is why the installer strips one component -- AND HOLDING WHAT THAT ENDPOINT HOLDS, which
# is tracked files: projects/.gitkeep and no node_modules. Its own excludes carried the
# developer's projects/ into the fixture instead, so this gzipped 58 MB (#76).
copy_course_tree "$TMP/pkg/cs193v-main"
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
run_consent() { installer_host "$TMP/installer.sh" CS193V_DIR="$TMP/consent"; }
out="$(run_consent)"
assert_says "consent:non-tty-declines"      "Nothing was changed"   "$out"
assert_says "consent:offers-a-way-forward"  "contact course staff"  "$out"
# NOTE: this one PASSED on macOS, and vacuously -- with nothing needing consent the installer
# runs to the end and exits 0 for an unrelated reason. It belongs inside the guard.
assert_eq   "consent:non-tty-exits-0"       "0" \
            "$(run_consent >/dev/null 2>&1; printf '%s' "$?")"
assert_no_file "consent:declining-creates-no-directory" "$TMP/consent"
# It must say WHAT it wants permission for, and why, before asking.
assert_says "consent:names-what-it-wants" "subuid range" "$out"
assert_says "consent:explains-why"        "needs your password" "$out"
# And it must never reach the download when consent was refused.
assert_says_not "consent:declining-skips-the-download" "Getting the course files" "$out"
else
skip_linux_arm "consent:non-tty-declines" "consent:offers-a-way-forward" "consent:non-tty-exits-0" \
               "consent:declining-creates-no-directory" "consent:names-what-it-wants" \
               "consent:explains-why" "consent:declining-skips-the-download"
fi

# With podman already present and a subuid range already there, nothing needs consent at
# all and the installer should say so rather than asking a pointless question.
shim_new
out="$(installer_host "$TMP/installer.sh" CS193V_DIR="$TMP/noconsent" || true)"
assert_says "consent:nothing-to-change-when-already-set-up" \
            "Nothing on your computer needs to change" "$out"
assert_says "consent:reports-the-existing-podman" "podman 5.7.0" "$out"

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
assert_says "unsupported-os:says-what-it-supports" "supports macOS, Ubuntu" "$out"
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
carve_func $PRIVATE/install-cs193v.sh os_release_field "$TMP/orf.sh"
carve_func $PRIVATE/install-cs193v.sh distro_family    "$TMP/df.sh"
carve_func $PRIVATE/install-cs193v.sh distro_packages  "$TMP/dp.sh"
for f in orf df dp; do
    if [ -s "$TMP/$f.sh" ]; then pass "extract:$f"
    else fail "extract:$f" "could not carve the distro helpers out of install-cs193v.sh"; fi
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
    po_floor="$(sed -n 's/^MIN_PODMAN_MACOS="\([^"]*\)".*/\1/p' $PRIVATE/install-cs193v.sh)"
    # The one needle here that is a literal rather than a value read back from the installer:
    # the Mac branch's advice is inline prose, not a table entry, so there is nothing to carve.
    po_fix="remove the podman you have"
else
    po_floor="$(sed -n 's/^MIN_PODMAN_LINUX="\([^"]*\)".*/\1/p' $PRIVATE/install-cs193v.sh)"
    po_fix="$(host_upgrade_cmd)"
fi
record "podman-old:the-branch-measured-here" "$(uname -s) / ${po_fix}"
# Both non-empty first. An empty needle would make assert_says pass against any output at all,
# which is the trap this file's own header records for version_lt.
assert_ne "podman-old:the-floor-was-readable" "" "$po_floor"
assert_ne "podman-old:the-fix-was-readable"   "" "$po_fix"
assert_says "podman-old:refused"            "needs $po_floor or newer" "$out"
assert_says "podman-old:names-what-it-found" "Podman 4.3.1"            "$out"
assert_says "podman-old:says-how-to-upgrade" "$po_fix"                 "$out"
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
assert_says_not "unwritable-dest:does-not-claim-success" "Setup finished" "$out"
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
assert_says "podman-mute:refuses-to-continue"   "Podman is installed but is not answering" "$out"
assert_says "podman-mute:suggests-the-mac-fix"  "podman machine start" "$out"
assert_says "podman-mute:changed-nothing-more"  "Nothing further has been changed" "$out"
assert_says_not "podman-mute:does-not-claim-success" "Setup finished" "$out"
assert_eq "podman-mute:exits-1" "1" \
          "$(installer_host_rc "$TMP/installer.sh" CS193V_DIR="$TMP/nopodman2")"

# THE WORST POSSIBLE LIE, and the one smoke_test exists to prevent: a build that produced
# no image, reported over the words "Setup finished". The installer's own comment calls this
# ERRORS.md A6's shape -- a truncated download that passed.
shim_new
shim_set image_exists no
out="$(installer_host "$TMP/installer.sh" CS193V_DIR="$TMP/noimage")"
assert_says "no-image:refuses-to-claim-success" "was not built, but setup did not stop" "$out"
assert_says_not "no-image:does-not-say-finished" "Setup finished" "$out"
assert_says "no-image:tells-them-what-to-send-staff" "doctor" "$out"

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
assert_says "consent-yes:the-arrow-moved-the-selection" "Go ahead" "$out"
assert_says "consent-yes:the-resize-ran"     "Resizing podman's virtual machine to 8192 MB" "$out"
assert_says "consent-yes:reports-the-resize" "resized and restarted" "$out"
assert_says "consent-yes:finishes"           "Setup finished" "$out"
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
assert_says "consent-no:declines-on-a-tty"  "Nothing was changed" "$out"
assert_says "consent-no:offers-a-way-forward" "contact course staff" "$out"
assert_says_not "consent-no:the-log-shows-no-resize" "machine set" "$(installer_log)"
assert_says     "consent-no:the-log-was-really-read" "machine list" "$(installer_log)"

# The digit shortcut. The key TABLE is diffed against the launcher's copy above, which proves
# the digits are listed; this proves they work in the installer's own copy.
shim_new; shim_fake_mac
shim_set machine_list podman-machine-default; shim_set machine_mem 4096
out="$(installer_tty '2' "$TMP/installer.sh" CS193V_DIR="$SHIM/dest" | strip_ansi)"
assert_says "consent-digit:selects-and-accepts" "resized and restarted" "$out"

# ─── setup_subuid, executing for the first time ────────────────────────────────
# The one privileged call reachable from here. sudo-fake records it and runs nothing, so what
# is asserted is the command the installer WOULD have run as root -- the range included,
# because a wrong range is a silent failure much later, inside podman.
if linux_arm; then
shim_new; shim_fake_id 1000 nosuchuser-cs193v
out="$(installer_tty '2' "$TMP/installer.sh" CS193V_DIR="$SHIM/dest" | strip_ansi)"
assert_says "subuid:step-announced" "Setting up your account's ID range" "$out"
assert_says "subuid:reports-success" "subuid range added for nosuchuser-cs193v" "$out"
assert_says "subuid:asks-root-for-the-right-range" \
            "usermod --add-subuids 200000-265535 --add-subgids 200000-265535 nosuchuser-cs193v" \
            "$(sudo_log)"
# This run cannot reach the end and that is correct rather than a gap: the faked account has
# no real /etc/subuid entry, so the launcher's own preflight refuses at --rebuild. Recorded
# so the reason is visible instead of looking like a missing assertion.
record "subuid:what-happens-after-a-faked-usermod" \
       "$(printf '%s' "$out" | grep -c 'Setup finished') finished-lines"

# ...and when root refuses. The die must name the account and tell them what to send staff.
shim_new; shim_fake_id 1000 nosuchuser-cs193v; shim_set sudo_fail usermod
out="$(installer_tty '2' "$TMP/installer.sh" CS193V_DIR="$SHIM/dest" | strip_ansi)"
assert_says "subuid-fails:names-the-account" "Could not add a subuid range for nosuchuser-cs193v" "$out"
assert_says "subuid-fails:says-what-to-send" "cat /etc/subuid" "$out"
assert_says_not "subuid-fails:does-not-claim-success" "subuid range added" "$out"
else
# subuid-fails:* is the one pair with NO container equivalent yet: it needs a sudo that works for
# everything except `usermod`, and SB_SUDO offers only nopasswd/password/deny/absent -- `deny`
# takes sudo away entirely and the installer would fail earlier for a different reason.
skip_linux_arm "subuid:step-announced" "subuid:reports-success" "subuid:asks-root-for-the-right-range" \
               "subuid-fails:names-the-account" "subuid-fails:says-what-to-send" \
               "subuid-fails:does-not-claim-success"
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

# THE RANGE IS PARSED OUT OF THE INSTALLER, not typed here, so changing installer:653 reddens
# this instead of leaving a test that agrees with a number nobody uses any more.
UM_RANGE="$(sed -n 's/.*--add-subuids \([0-9]*-[0-9]*\).*/\1/p' "$PRIVATE/install-cs193v.sh" | head -1)"
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
assert_says "choosedir:default-finishes"        "Setup finished" "$out"

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
# launcher -- whose progress meter draws cursor escapes on a tty of its own accord. Asserting
# over the whole transcript measured the meter, not the colour decision.
pre() { sed -n '1,/Building the course container/p'; }
raw="$(installer_tty '\n' "$TMP/installer.sh" CS193V_DIR="$SHIM/dest" | pre)"
if printf '%s' "$raw" | grep -q "$(printf '\033')\["; then pass "colour:on-with-a-terminal"
else fail "colour:on-with-a-terminal" "no escape sequences in a pty transcript"; fi
assert_says "colour:the-coloured-run-got-that-far" "Looking at your computer" "$raw"

shim_new
raw="$(installer_tty '\n' "$TMP/installer.sh" NO_COLOR=1 CS193V_DIR="$SHIM/dest" | pre)"
if printf '%s' "$raw" | grep -q "$(printf '\033')\["; then
    fail "colour:NO_COLOR-suppresses-it" "escape sequences survived NO_COLOR=1"
else pass "colour:NO_COLOR-suppresses-it"; fi
# ...and the run really ran, so the check above is not passing on an empty transcript.
assert_says "colour:NO_COLOR-run-got-that-far" "Looking at your computer" "$raw"

DEST="$TMP/dest"
shim_new
run_installer() { installer_host "$TMP/installer.sh" CS193V_DIR="$DEST"; }
out1="$(run_installer)"
assert_says "install:first-run-finishes"     "Setup finished"  "$out1"
assert_says "install:first-run-fetched"      "course files"    "$out1"
assert_file "install:launcher-installed"     "$DEST/cs193v"
assert_exec "install:launcher-executable"    "$DEST/cs193v"
assert_file "install:args-installed"         "$DEST/.config/container.args"
assert_file "install:messages-installed"     "$DEST/.private/messages.txt"
assert_ok   "install:projects-dir-created"   test -d "$DEST/projects"
assert_says "install:tells-them-how-to-start" "./cs193v" "$out1"

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

assert_says "install:second-run-finishes" "Setup finished" "$out2"
if diff -u "$TMP/s1" "$TMP/s2" > "$TMP/statediff" 2>&1; then
    pass "install:is-idempotent"
else
    fail "install:is-idempotent" "$(cat "$TMP/statediff")"
fi
assert_eq "install:student-work-survives-a-rerun" "my work" \
          "$(cat "$DEST/projects/my-app/index.js" 2>/dev/null)"
# Re-running must report already-satisfied steps rather than redoing them.
assert_says "install:reports-already-done" "already done" "$out2"

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
sed -n '/^check_disk()/,/^}$/p' $PRIVATE/install-cs193v.sh >> "$TMP/cd.sh"
if [ "$(grep -c '.' "$TMP/cd.sh")" -gt 8 ]; then pass "extract:check_disk"
else fail "extract:check_disk" "could not extract check_disk"; fi

cd_for() {                            # cd_for ALLOC USED [RC] -> its note/ok lines
    ( . "$TMP/cd.sh"; FAKE_OUT="$1 $2" FAKE_RC="${3:-0}" check_disk )
}
#  10 GiB allocated, 6 used -> 4 GiB free, under the 8 GiB floor check_disk names.
assert_says "check-disk:warns-under-the-floor" \
            "Only about 4 GB is free" "$(cd_for 10737418240 6442450944)"
assert_says "check-disk:says-it-can-be-resumed" \
            "pick up where it stopped" "$(cd_for 10737418240 6442450944)"
# 100 GiB allocated, 10 used -> 90 free, comfortably over.
assert_says "check-disk:reports-ample-room" \
            "90 GB free for the container" "$(cd_for 107374182400 10737418240)"
assert_says_not "check-disk:ample-room-does-not-warn" \
            "Only about" "$(cd_for 107374182400 10737418240)"
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
assert_says "check-disk:the-fake-really-feeds-it" "Only about 4 GB is free" "$out"
assert_says "check-disk:low-disk-is-not-fatal"    "Setup finished"          "$out"

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

# The gate on everything below: if this fails, every other assertion here is failing
# because the run is still on Linux, not because of anything to do with a machine.
out="$(mac_run)"
assert_says "mac:platform-is-detected" "macos on arm64" "$out"

# ─── nothing exists yet -> init  (survey's machine-list-empty arm) ─────────────
# init is announced with ok(), not need(), so it is the one machine change that needs no
# consent -- which is what makes this reachable with no tty at all.
assert_says "mac-init:announced-in-the-survey" "virtual machine will be created" "$out"
assert_says "mac-init:names-the-size-it-will-use" "8192 MB, 64 GB disk" "$out"
assert_says "mac-init:reports-success" "created and started" "$out"
# The flags, not just the prose: --now matters (without it the machine is created stopped
# and every later podman call fails), and the two values must be the computed ones.
assert_says "mac-init:asks-for-the-computed-size" \
            'machine init --memory 8192 --disk-size 64 --now' "$(installer_log)"
assert_says_not "mac-init:does-not-also-resize" "Resizing" "$out"

out="$(mac_run machine_init_rc 1)"
assert_says "mac-init:failure-is-fatal" "Could not create the podman virtual machine" "$out"
assert_says_not "mac-init:failure-does-not-claim-success" "Setup finished" "$out"
assert_eq "mac-init:failure-exits-1" "1" "$(mac_rc machine_init_rc 1)"

# ─── a machine that is too small -> the resize is OFFERED  (survey :384-387) ───
# 80% of 8192 is 6553, so 4096 is under it and 16384 is over.
out="$(mac_run machine_list podman-machine-default machine_mem 4096)"
assert_says "mac-resize:offered-when-the-vm-is-small" \
            "more memory (4096 MB -> 8192 MB)" "$out"
assert_says "mac-resize:explains-why-a-mac-needs-it" "fixed amount of memory" "$out"
# EVERY NEGATIVE BELOW IS PAIRED WITH A POSITIVE OFF THE SAME VALUE. An empty argv.log --
# a wrong path, a run that never started -- satisfies `machine set is absent` perfectly,
# and VERIFICATION.md records assert_not_contains as a measured vacuity blind spot: ten of
# them passed in the sabotage run. The companion asserts a line that can only be there if
# the installer really asked podman about a machine.
# It needs permission, so with no tty it must change NOTHING -- including no init.
assert_says "mac-resize:no-tty-declines"  "Nothing was changed" "$out"
assert_says     "mac-resize:the-log-was-really-read" 'machine list' "$(installer_log)"
assert_says_not "mac-resize:declining-touches-no-machine" 'machine set' "$(installer_log)"

# ─── a machine that is big enough -> skip  (survey's else arm) ─────────────────
out="$(mac_run machine_list podman-machine-default machine_mem 16384)"
assert_says "mac-ok:reasonable-size-is-left-alone" "reasonable size" "$out"
assert_says_not "mac-ok:does-not-offer-a-resize" "more memory" "$out"
assert_says "mac-ok:still-finishes" "Setup finished" "$out"

# inspect returning nothing must land in the SAME arm, not in the resize one: an empty
# value would make `[ "$vm_mb" -lt ... ]` an error, so the installer guards with -n first.
out="$(mac_run machine_list podman-machine-default machine_mem '')"
assert_says "mac-inspect-empty:treated-as-reasonable" "reasonable size" "$out"
assert_says_not "mac-inspect-empty:does-not-offer-a-resize" "more memory" "$out"

# ─── growing the disk, on the path where nothing else stopped the machine ──────
# grow_machine_disk_when_stopped, reached only through the skip arm above.
out="$(mac_run machine_list pmd machine_mem 16384 machine_disk 32)"
assert_says "mac-disk:grows-a-disk-that-is-too-small" "from 32 GB to 64 GB" "$out"
assert_says "mac-disk:says-it-costs-nothing-up-front" "does not use the space up front" "$out"
assert_says "mac-disk:asks-podman-to-grow-it" 'machine set --disk-size 64' "$(installer_log)"

out="$(mac_run machine_list pmd machine_mem 16384 machine_disk 64)"
assert_says_not "mac-disk:a-big-enough-disk-is-left-alone" "Growing" "$out"
assert_says     "mac-disk:the-log-was-really-read" 'machine inspect' "$(installer_log)"
assert_says_not "mac-disk:no-set-when-there-is-nothing-to-do" 'machine set' "$(installer_log)"

# podman refuses to SHRINK a machine disk, so a refusal here is expected rather than
# exceptional -- it must be a note and the install must go on.
out="$(mac_run machine_list pmd machine_mem 16384 machine_disk 32 machine_set_rc 1)"
assert_says "mac-disk:a-refused-grow-is-not-fatal" "Could not grow it; continuing" "$out"
assert_says "mac-disk:still-finishes-after-a-refused-grow" "Setup finished" "$out"

# A non-numeric DiskSize is podman's output changing shape, and the installer's own comment
# says the harmless direction is to stop growing rather than to guess.
out="$(mac_run machine_list pmd machine_mem 16384 machine_disk bad)"
assert_says_not "mac-disk:non-numeric-size-grows-nothing" "Growing" "$out"
assert_says "mac-disk:non-numeric-size-still-finishes" "Setup finished" "$out"

# ─── survey does not reinstall a podman it cannot see  (issue #121) ────────────
# The second bug #121 caused, and the one that costs a student real money: re-running this
# script in the window that ran it the first time saw NO podman -- so it re-downloaded 75 MB,
# asked for the password again, and re-ran `sudo installer`, whose preinstall does
# `rm -rf /opt/podman` and takes the virtual machine and every container in it with it.
#
# A REWRITTEN COPY OF THE INSTALLER, so the receipt consulted is a fabricated one. The shipped
# identifier is REAL on a maintainer's Mac, which would make these pass for the wrong reason.
cp "$PRIVATE/install-cs193v.sh" "$TMP/install-probe.sh"
edit_sub "$TMP/install-probe.sh" '^REPO_OWNER=.*' 'REPO_OWNER="test"'
edit_sub "$TMP/install-probe.sh" '^TARBALL=.*'    "TARBALL=\"file://$TMP/course.tar.gz\""
edit_sub "$TMP/install-probe.sh" '^PODMAN_PKG_ID=.*' "PODMAN_PKG_ID=\"$IPROBE_PKG_ID\""
# EVERY REWRITE ASSERTED. edit_sub whose ERE matches nothing is a silent no-op -- lib/sandbox.sh
# records the same trap -- and here the consequence is a case that interrogates the developer's
# real /opt/podman and passes without testing anything.
assert_eq "probe:the-installer-copy-names-the-fake-package" "1" \
          "$(grep -c "^PODMAN_PKG_ID=\"$IPROBE_PKG_ID\"\$" "$TMP/install-probe.sh")"
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
assert_says "probe:the-survey-run-reached-macos"    "macos on arm64" "$out"
assert_says "probe:the-installer-reports-the-podman-it-found" "podman 5.7.0" "$out"
assert_says "probe:the-installer-says-where-it-found-it" \
            "podman is installed in $IOFF" "$out"
assert_says "probe:the-installer-explains-the-path"  "does not name yet" "$out"
# THE NEGATIVE, and its positive is the pair above. "Podman runs the course container" is the
# opening of the need() body on BOTH the macOS and the Linux arm, so this needs no platform gate.
assert_says_not "probe:the-installer-does-not-reinstall-a-podman-it-cannot-see" \
                "Podman runs the course container" "$out"
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
assert_says "probe:the-survey-absent-run-reached-macos" "macos on arm64" "$out"
assert_says "probe:the-installer-offers-to-install-a-podman-that-really-is-absent" \
            "Podman runs the course container" "$out"
assert_says_not "probe:it-claims-no-directory-when-there-is-none" \
                "podman is installed in" "$out"

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
assert_says "intel-mac:refused" "Intel" "$out"
assert_no_file "intel-mac:changes-nothing" "$TMP/intel"

# ─── a bad download must never report success ──────────────────────────────────
# Three failure shapes, because they are caught by three different guards.
# Prints the installer's output; leaves its exit status in $TMP/rc, because the caller
# reads the output through a command substitution and a variable set in that subshell
# would never make it back.
run_with_tarball() {                  # run_with_tarball FILE DEST
    cp "$TMP/installer.sh" "$TMP/installer-case.sh"
    edit_sub "$TMP/installer-case.sh" '^TARBALL=.*' "TARBALL=\"file://$1\""
    shim_new
    installer_host "$TMP/installer-case.sh" CS193V_DIR="$2"
    printf '%s' "$?" > "$TMP/rc"
}
last_rc() { cat "$TMP/rc"; }

# 1. A truncated gzip stream. GNU tar exits nonzero here of its own accord; pipefail makes
#    that independent of which tar is installed.
head -c 3000 "$TMP/course.tar.gz" > "$TMP/truncated.tar.gz"
out="$(run_with_tarball "$TMP/truncated.tar.gz" "$TMP/broken-trunc")"
assert_says_not "truncated:does-not-claim-success"   "Setup finished" "$out"
assert_eq       "truncated:exits-nonzero"            "1" "$(last_rc)"
assert_says     "truncated:says-it-is-safe-to-retry" "safe to run this script again" "$out"

# 2. A URL that is not there at all — what a wrong REPO_OWNER produces.
out="$(run_with_tarball "$TMP/no-such-file.tar.gz" "$TMP/broken-404")"
assert_says_not "missing-tarball:does-not-claim-success" "Setup finished" "$out"
assert_eq       "missing-tarball:exits-nonzero"         "1" "$(last_rc)"

# 3. The one neither exit status can catch: a well-formed archive that is simply missing
#    files. tar extracts it happily and exits 0, so without the sentinel check the
#    installer would print "Setup finished" over a directory with no launcher in it. This
#    is what the explicit per-file check exists for.
mkdir -p "$TMP/pkg2/cs193v-main"
cp "$PRIVATE/messages.txt" "$TMP/pkg2/cs193v-main/"
( cd "$TMP/pkg2" && tar czf "$TMP/incomplete.tar.gz" cs193v-main )
assert_ok "incomplete:archive-is-well-formed" tar tzf "$TMP/incomplete.tar.gz"
out="$(run_with_tarball "$TMP/incomplete.tar.gz" "$TMP/broken-partial")"
assert_says_not "incomplete:does-not-claim-success"    "Setup finished" "$out"
assert_eq       "incomplete:exits-nonzero"             "1" "$(last_rc)"
assert_says     "incomplete:names-the-missing-file"    "cs193v is missing" "$out"
assert_says     "incomplete:blames-the-transfer"       "cut short" "$out"
assert_says     "incomplete:says-it-is-safe-to-retry"  "safe to run this script again" "$out"

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
             '\-e curl -fsSL --retry 10 --retry-delay 3 -o %STAGE2% %INSTALLER_URL%$' "$curl_line"
assert_not_match "windows:curl-diagnostics-reach-the-student" '>' "$curl_line"

# ORDER, which no wine run can prove absent: the downloaded script must be checked BEFORE it is
# handed to bash. Both line numbers must exist, so a rename on either side goes red rather than
# quiet.
sentinel_ln="$(sed 's/\r$//' "$W" | grep -n 'grep -q %SENTINEL%' | head -1 | cut -d: -f1)"
bash_ln="$(sed 's/\r$//' "$W" | grep -n -- '-e bash %STAGE2%' | head -1 | cut -d: -f1)"
assert_ok "windows:checks-the-download-before-running-it" \
          sh -c "test -n '$sentinel_ln' && test -n '$bash_ln' && test '$sentinel_ln' -lt '$bash_ln'"

assert_ok "windows:names-the-same-distro-as-the-sh"  \
          sh -c "grep -q 'DISTRO=CS193V' '$W' && grep -q 'WSL_DISTRO=\"CS193V\"' $PRIVATE/install-cs193v.sh"
# A .cmd, not a .ps1, so a downloaded file just runs instead of teaching students to click
# past security warnings in a course about not trusting code.
#
# $PRIVATE, not a bare name: this file does `cd "$REPO"` at the top, so the relative form this
# check used to have looked in the repo root while the .cmd lives one directory down -- a
# .private/install-cs193v-windows.ps1 passed it.
assert_no_file "windows:is-cmd-not-ps1" "$PRIVATE/install-cs193v-windows.ps1"

. "$(dirname -- "$0")/lib/cmdlint.sh"

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
