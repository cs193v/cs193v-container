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
# Not /^version_lt() {$/ — the helper's copy carries a trailing comment on the same line.
sed -n '/^version_lt()/,/^}$/p' $PRIVATE/files/cs193v-ui.sh > "$TMP/vl_launcher.sh"
sed -n '/^version_lt()/,/^}$/p' $PRIVATE/install-cs193v.sh  > "$TMP/vl_installer.sh"
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

# The macOS VM sizing formula. A Mac's containers run in a fixed-size VM that does not
# scale with the host, and podman's default is too small for this course.
cat > "$TMP/vm.sh" <<'EOF'
MAC_VM_SHARE_PCT=75
MAC_VM_LEAVE_GB=4
MAC_VM_MAX_GB=16
MAC_VM_MIN_GB=4
host_ram_mb() { printf '%s' "$FAKE_RAM_MB"; }
EOF
sed -n '/^mac_vm_target_mb()/,/^}$/p' $PRIVATE/install-cs193v.sh >> "$TMP/vm.sh"
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
run_consent() { installer_host "$PRIVATE/install-cs193v.sh" CS193V_DIR="$TMP/consent"; }
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
out="$(installer_host "$PRIVATE/install-cs193v.sh" CS193V_DIR="$TMP/noconsent" || true)"
assert_says "consent:nothing-to-change-when-already-set-up" \
            "Nothing on your computer needs to change" "$out"
assert_says "consent:reports-the-existing-podman" "podman 5.7.0" "$out"

# ─── §A.12 idempotency, done for real ──────────────────────────────────────────
# Serve the course files from a local tarball shaped the way GitHub's archive endpoint
# does — a single top-level directory, which is why the installer strips one component.
#
# AND HOLDING WHAT THAT ENDPOINT HOLDS, which is tracked files: projects/.gitkeep and no
# node_modules. Its own excludes carried the developer's projects/ into the fixture instead, so
# this gzipped 58 MB — 1.7 s of CPU — and then extracted it twice, once per idempotency run (#76).
copy_course_tree "$TMP/pkg/cs193v-main"
( cd "$TMP/pkg" && tar czf "$TMP/course.tar.gz" cs193v-main )
assert_file "install:test-tarball-built" "$TMP/course.tar.gz"

cp $PRIVATE/install-cs193v.sh "$TMP/installer.sh"
edit_sub "$TMP/installer.sh" '^REPO_OWNER=.*' 'REPO_OWNER="test"'
edit_sub "$TMP/installer.sh" '^TARBALL=.*'    "TARBALL=\"file://$TMP/course.tar.gz\""
assert_ok "install:test-copy-is-valid-bash" bash -n "$TMP/installer.sh"

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
assert_file "install:local-args-written"     "$DEST/.config/local.args"
assert_ok   "install:projects-dir-created"   test -d "$DEST/projects"
assert_says "install:tells-them-how-to-start" "./cs193v" "$out1"

# local.args must carry the memory cap, computed from what podman reports rather than from
# /proc -- which inside a container reports the host's RAM, not the cgroup limit.
assert_ok "install:local-args-has-memory-cap" grep -q '^--memory=' "$DEST/.config/local.args"
cap="$(sed -n 's/^--memory=\([0-9]*\)m/\1/p' "$DEST/.config/local.args")"
# The fake podman reports 8 GiB; the linux formula reserves 35% (min 3072) -> 5120.
assert_eq "install:cap-matches-the-formula" "5120" "$cap"
assert_ok "install:local-args-explains-itself" grep -q 'reserving' "$DEST/.config/local.args"

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

# ─── check_disk, which no mechanism could reach before ─────────────────────────
# check_disk asks podman for two Store fields (installer's check_disk), and podman-fake's
# info arm answered only Rootless and MemTotal — every other --format fell through to
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
    shim_fake_mac                     # 16 GiB arm64 -> mac_vm_target_mb wants 12288 MB
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
assert_says "mac-init:names-the-size-it-will-use" "12288 MB, 64 GB disk" "$out"
assert_says "mac-init:reports-success" "created and started" "$out"
# The flags, not just the prose: --now matters (without it the machine is created stopped
# and every later podman call fails), and the two values must be the computed ones.
assert_says "mac-init:asks-for-the-computed-size" \
            'machine init --memory 12288 --disk-size 64 --now' "$(installer_log)"
assert_says_not "mac-init:does-not-also-resize" "Resizing" "$out"

out="$(mac_run machine_init_rc 1)"
assert_says "mac-init:failure-is-fatal" "Could not create the podman virtual machine" "$out"
assert_says_not "mac-init:failure-does-not-claim-success" "Setup finished" "$out"
assert_eq "mac-init:failure-exits-1" "1" "$(mac_rc machine_init_rc 1)"

# ─── a machine that is too small -> the resize is OFFERED  (survey :384-387) ───
# 80% of 12288 is 9830, so 4096 is under it and 16384 is over.
out="$(mac_run machine_list podman-machine-default machine_mem 4096)"
assert_says "mac-resize:offered-when-the-vm-is-small" \
            "more memory (4096 MB -> 12288 MB)" "$out"
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

# ─── the Windows stage-one script ──────────────────────────────────────────────
# Not executable here, but its structure is checkable, and it is the one file no
# Linux or macOS test run would otherwise look at.
W=$PRIVATE/install-cs193v-windows.cmd
assert_ok "windows:requires-administrator"   grep -q 'net session' "$W"
assert_ok "windows:handles-utf16-wsl-output" grep -q 'WSL_UTF8' "$W"
assert_ok "windows:translates-path-with-wslpath" grep -q 'wslpath' "$W"
# Bare filename on purpose: the .cmd and the .sh are downloaded side by side, before any
# .private/ directory exists, so stage one must reference its sibling.
assert_ok "windows:hands-off-to-the-shared-installer" grep -q 'install-cs193v.sh' "$W"
assert_ok "windows:names-the-same-distro-as-the-sh"  \
          sh -c "grep -q 'DISTRO=CS193V' '$W' && grep -q 'WSL_DISTRO=\"CS193V\"' $PRIVATE/install-cs193v.sh"
# A .cmd, not a .ps1, so a downloaded file just runs instead of teaching students to click
# past security warnings in a course about not trusting code.
assert_ok "windows:is-cmd-not-ps1" test ! -f install-cs193v-windows.ps1
# CRLF matters: a .cmd with bare LF endings can misparse under cmd.exe.
if grep -qU $'\r' "$W" 2>/dev/null || file "$W" | grep -q CRLF; then
    pass "windows:has-crlf-line-endings"
else
    record "windows:line-endings" "LF only — verify cmd.exe parses it on a real Windows box"
fi
