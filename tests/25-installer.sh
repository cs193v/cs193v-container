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
trap 'rm -rf "$TMP"; shim_cleanup' EXIT

# ─── the two pure functions, extracted and unit-tested ─────────────────────────
# version_lt is duplicated in the launcher and the installer. If they ever disagree, a
# student is told to upgrade by one and accepted by the other.
# Not /^version_lt() {$/ — the launcher's copy carries a trailing comment on the same line.
sed -n '/^version_lt()/,/^}$/p' cs193v            > "$TMP/vl_launcher.sh"
sed -n '/^version_lt()/,/^}$/p' install-cs193v.sh > "$TMP/vl_installer.sh"
for f in vl_launcher vl_installer; do
    if [ "$(wc -l < "$TMP/$f.sh" | tr -d ' ')" -gt 3 ]; then pass "extract:$f"
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

# The macOS VM sizing formula. A Mac's containers run in a fixed-size VM that does not
# scale with the host, and podman's default is too small for this course.
cat > "$TMP/vm.sh" <<'EOF'
MAC_VM_SHARE_PCT=75
MAC_VM_LEAVE_GB=4
MAC_VM_MAX_GB=16
MAC_VM_MIN_GB=4
host_ram_mb() { printf '%s' "$FAKE_RAM_MB"; }
EOF
sed -n '/^mac_vm_target_mb()/,/^}$/p' install-cs193v.sh >> "$TMP/vm.sh"
vm_for() { ( . "$TMP/vm.sh"; FAKE_RAM_MB="$1" mac_vm_target_mb ); }
#  8 GB: 75% = 6, but leave 4 for macOS -> 4 GB
# 16 GB: 75% = 12, leave 12 -> 12 GB
# 32 GB: 75% = 24, capped at 16 -> 16 GB
# 64 GB: capped at 16 GB — a VM gains nothing from more
assert_eq "mac-vm:8GB-host"  "4096"  "$(vm_for 8192)"
assert_eq "mac-vm:16GB-host" "12288" "$(vm_for 16384)"
assert_eq "mac-vm:32GB-host" "16384" "$(vm_for 32768)"
assert_eq "mac-vm:64GB-host" "16384" "$(vm_for 65536)"
assert_eq "mac-vm:never-exceeds-the-cap" "16384" "$(vm_for 131072)"

# ─── the memory-cap formula that lands in local.args ───────────────────────────
# A VM running nothing but podman needs a small floor; a Linux laptop has the student's
# whole desktop on the same RAM, so the reserve is much larger there.
cap_for() {                           # cap_for PLAT TOTAL_MB -> "--memory=Nm" or "none"
    ( PLAT="$1"; total_mb="$2"
      case "$PLAT" in
          macos|wsl) reserve_mb=$(( total_mb / 10 )); [ "$reserve_mb" -lt 768 ] && reserve_mb=768 ;;
          *)         reserve_mb=$(( total_mb * 35 / 100 )); [ "$reserve_mb" -lt 3072 ] && reserve_mb=3072 ;;
      esac
      cap_mb=$(( total_mb - reserve_mb ))
      if [ "$cap_mb" -lt 1536 ]; then printf 'none'; else printf -- '--memory=%sm' "$cap_mb"; fi )
}
assert_eq "memcap:linux-16GB" "--memory=10650m" "$(cap_for linux 16384)"
assert_eq "memcap:linux-8GB"  "--memory=5120m"  "$(cap_for linux 8192)"
assert_eq "memcap:macos-8GB"  "--memory=7373m"  "$(cap_for macos 8192)"
assert_eq "memcap:wsl-16GB"   "--memory=14746m" "$(cap_for wsl 16384)"
# A machine too small to cap usefully gets no cap at all, rather than one that breaks
# ordinary work more often than it helps.
assert_eq "memcap:linux-4GB-declines-to-cap" "none" "$(cap_for linux 4096)"
assert_eq "memcap:tiny-machine-declines"     "none" "$(cap_for macos 2048)"
# Whatever the formula, it must never hand out more than the machine has.
for t in 2048 4096 8192 16384 32768; do
    got="$(cap_for linux "$t")"
    case "$got" in
        none) : ;;
        *) n="${got#--memory=}"; n="${n%m}"
           if [ "$n" -lt "$t" ]; then pass "memcap:linux-${t}MB-leaves-headroom"
           else fail "memcap:linux-${t}MB-leaves-headroom" "cap $n >= total $t"; fi ;;
    esac
done

# ─── consent: nothing changes without a yes  (§1.2) ────────────────────────────
# menu() with no tty picks the DEFAULT, which for consent is "Stop, do not change
# anything". VERIFICATION.md §1.2 claims it falls back to numbered selection; it does not,
# and the behaviour it actually has is the safer one. This asserts the real behaviour.
# Something has to NEED consent, or there is no prompt to test. On a machine that already
# has podman and a subuid range, nothing does — so fake a username with no /etc/subuid
# entry. That drives the real DO_SUBUID branch and works on any machine, whereas assuming
# podman is absent only worked on a machine that happened not to have it.
shim_new
shim_fake_id 1000 nosuchuser-cs193v
run_consent() { PATH="$SHIM:$PATH" CS193V_DIR="$TMP/consent" bash install-cs193v.sh </dev/null 2>&1; }
out="$(run_consent)"
assert_says "consent:non-tty-declines"      "Nothing was changed"   "$out"
assert_says "consent:offers-a-way-forward"  "contact course staff"  "$out"
assert_eq   "consent:non-tty-exits-0"       "0" \
            "$(run_consent >/dev/null 2>&1; printf '%s' "$?")"
assert_no_file "consent:declining-creates-no-directory" "$TMP/consent"
# It must say WHAT it wants permission for, and why, before asking.
assert_says "consent:names-what-it-wants" "subuid range" "$out"
assert_says "consent:explains-why"        "needs your password" "$out"
# And it must never reach the download when consent was refused.
assert_says_not "consent:declining-skips-the-download" "Getting the course files" "$out"

# With podman already present and a subuid range already there, nothing needs consent at
# all and the installer should say so rather than asking a pointless question.
shim_new
out="$(PATH="$SHIM:$PATH" CS193V_DIR="$TMP/noconsent" bash install-cs193v.sh </dev/null 2>&1 || true)"
assert_says "consent:nothing-to-change-when-already-set-up" \
            "Nothing on your computer needs to change" "$out"
assert_says "consent:reports-the-existing-podman" "podman 5.7.0" "$out"

# ─── §A.12 idempotency, done for real ──────────────────────────────────────────
# Serve the course files from a local tarball shaped the way GitHub's archive endpoint
# does — a single top-level directory, which is why the installer strips one component.
mkdir -p "$TMP/pkg/cs193v-main"
( cd "$REPO" && tar cf - --exclude=.git --exclude=tests . ) \
    | ( cd "$TMP/pkg/cs193v-main" && tar xf - )
( cd "$TMP/pkg" && tar czf "$TMP/course.tar.gz" cs193v-main )
assert_file "install:test-tarball-built" "$TMP/course.tar.gz"

cp install-cs193v.sh "$TMP/installer.sh"
edit_sub "$TMP/installer.sh" '^REPO_OWNER=.*' 'REPO_OWNER="test"'
edit_sub "$TMP/installer.sh" '^TARBALL=.*'    "TARBALL=\"file://$TMP/course.tar.gz\""
assert_ok "install:test-copy-is-valid-bash" bash -n "$TMP/installer.sh"

DEST="$TMP/dest"
shim_new
run_installer() {
    PATH="$SHIM:$PATH" CS193V_DIR="$DEST" bash "$TMP/installer.sh" </dev/null 2>&1
}
out1="$(run_installer)"
assert_says "install:first-run-finishes"     "Setup finished"  "$out1"
assert_says "install:first-run-fetched"      "course files"    "$out1"
assert_file "install:launcher-installed"     "$DEST/cs193v"
assert_exec "install:launcher-executable"    "$DEST/cs193v"
assert_file "install:args-installed"         "$DEST/container.args"
assert_file "install:messages-installed"     "$DEST/messages.txt"
assert_file "install:local-args-written"     "$DEST/local.args"
assert_ok   "install:projects-dir-created"   test -d "$DEST/projects"
assert_says "install:tells-them-how-to-start" "./cs193v" "$out1"

# local.args must carry the cap AND the matching env var the in-container milestone check
# reads, computed from what podman reports rather than from /proc.
assert_ok "install:local-args-has-memory-cap" grep -q '^--memory=' "$DEST/local.args"
assert_ok "install:local-args-has-memory-env" grep -q 'CS193V_MEMORY_MB=' "$DEST/local.args"
cap="$(sed -n 's/^--memory=\([0-9]*\)m/\1/p' "$DEST/local.args")"
env_mb="$(sed -n 's/^-e CS193V_MEMORY_MB=\([0-9]*\)/\1/p' "$DEST/local.args")"
assert_eq "install:cap-and-env-agree" "$cap" "$env_mb"
# The fake podman reports 8 GiB; the linux formula reserves 35% (min 3072) -> 5120.
assert_eq "install:cap-matches-the-formula" "5120" "$cap"
assert_ok "install:local-args-explains-itself" grep -q 'reserving' "$DEST/local.args"

# Now the actual §A.12 property. Everything except local.args and projects/ must be
# byte-identical, and local.args must be identical too since the machine has not changed.
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

# ─── a bad download must never report success ──────────────────────────────────
# Three failure shapes, because they are caught by three different guards.
# Prints the installer's output; leaves its exit status in $TMP/rc, because the caller
# reads the output through a command substitution and a variable set in that subshell
# would never make it back.
run_with_tarball() {                  # run_with_tarball FILE DEST
    cp "$TMP/installer.sh" "$TMP/inst-case.sh"
    edit_sub "$TMP/inst-case.sh" '^TARBALL=.*' "TARBALL=\"file://$1\""
    shim_new
    PATH="$SHIM:$PATH" CS193V_DIR="$2" bash "$TMP/inst-case.sh" </dev/null 2>&1
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
cp "$REPO/messages.txt" "$TMP/pkg2/cs193v-main/"
( cd "$TMP/pkg2" && tar czf "$TMP/incomplete.tar.gz" cs193v-main )
assert_ok "incomplete:archive-is-well-formed" tar tzf "$TMP/incomplete.tar.gz"
out="$(run_with_tarball "$TMP/incomplete.tar.gz" "$TMP/broken-partial")"
assert_says_not "incomplete:does-not-claim-success"    "Setup finished" "$out"
assert_eq       "incomplete:exits-nonzero"             "1" "$(last_rc)"
assert_says     "incomplete:names-the-missing-file"    "cs193v is missing" "$out"
assert_says     "incomplete:blames-the-transfer"       "cut short" "$out"
assert_says     "incomplete:says-it-is-safe-to-retry"  "safe to run this script again" "$out"

# ─── the Windows stage-one script ──────────────────────────────────────────────
# Not executable here, but its structure is checkable, and it is the one file no
# Linux or macOS test run would otherwise look at.
W=install-cs193v-windows.cmd
assert_ok "windows:requires-administrator"   grep -q 'net session' "$W"
assert_ok "windows:handles-utf16-wsl-output" grep -q 'WSL_UTF8' "$W"
assert_ok "windows:translates-path-with-wslpath" grep -q 'wslpath' "$W"
assert_ok "windows:hands-off-to-the-shared-installer" grep -q 'install-cs193v.sh' "$W"
assert_ok "windows:names-the-same-distro-as-the-sh"  \
          sh -c "grep -q 'DISTRO=CS193V' '$W' && grep -q 'WSL_DISTRO=\"CS193V\"' install-cs193v.sh"
# A .cmd, not a .ps1, so a downloaded file just runs instead of teaching students to click
# past security warnings in a course about not trusting code.
assert_ok "windows:is-cmd-not-ps1" test ! -f install-cs193v-windows.ps1
# CRLF matters: a .cmd with bare LF endings can misparse under cmd.exe.
if grep -qU $'\r' "$W" 2>/dev/null || file "$W" | grep -q CRLF; then
    pass "windows:has-crlf-line-endings"
else
    record "windows:line-endings" "LF only — verify cmd.exe parses it on a real Windows box"
fi
