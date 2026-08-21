# shellcheck shell=bash
#
# The fixture-container half of the installer tests. Source after lib/assert.sh.
#
# WHAT THIS IS FOR, and what it deliberately is not. lib/podman-shim.sh runs the installer
# on THIS machine with fakes on PATH, which reaches every DECISION the installer takes and
# no EFFECT it has: sudo-fake has no exec branch, so `sudo apt-get install`, `sudo usermod
# --add-subuids` and the /etc/wsl.conf writes are recorded and never happen. Three branches
# cannot even be decided there -- podman absent, ssh absent and a podman too old are all
# properties of the machine, and taking the fake podman off PATH just exposes the real one.
#
# So this half runs the installer on a machine that genuinely has those properties, inside a
# throwaway container, and asserts on what really changed. The container is the boundary:
# nothing of this host's state is inside it, no podman socket, no writable mount, and
# --network=none, so a bug in a case here cannot reach the developer's machine however
# wrong the command is.
#
# MUST STAY BASH 3.2 COMPATIBLE -- see lib/assert.sh for why.

FIXTURE_DIR="$TESTS_DIR/fixtures"

# Tags are the one piece of shared, content-bearing state this introduces, on a machine
# where eleven checkouts of this repo build at once. So they are suffixed exactly the way
# the launcher suffixes its own image (cs193v:869-881) -- CLAUDE.md §1 records what happens
# when two people write the same tag, and it is not a clean collision.
fixture_tag() {                       # fixture_tag CASE -> the tag for this instance
    printf 'localhost/cs193v-fixture-%s:local%s' "$1" "${CS193V_INSTANCE:+-$CS193V_INSTANCE}"
}

# sha256sum is GNU; a TA's Mac has shasum. Same reason lib/assert.sh cannot use `date +%N`.
sb_sha() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
    else shasum -a 256 | cut -d' ' -f1; fi
}

# The recipe hash, over the Containerfile AND everything it COPYs in. This is the
# cs193v.buildhash mechanism the launcher already uses (cs193v:1233-1240), for the reason
# CLAUDE.md §1 gives: `podman image exists || build` silently serves the OLD starting state
# after the recipe moves, and the plan wants cache hits, so staleness is the steady state
# rather than an edge case.
fixture_hash() {                      # fixture_hash CASE -> a hex digest
    { cat "$FIXTURE_DIR/Containerfile.$1"
      cat "$TESTS_DIR/lib/podman-fake"; } | sb_sha
}

fixture_build() {                     # fixture_build CASE -> builds only if the recipe moved
    local case="$1" tag want have
    tag="$(fixture_tag "$case")"
    want="$(fixture_hash "$case")"
    have="$(podman image inspect --format '{{index .Config.Labels "cs193v.fixturehash"}}' \
              "$tag" 2>/dev/null || true)"
    if [ "$want" = "$have" ] && [ -n "$have" ]; then
        record "fixture:$case" "cached"
        return 0
    fi
    # The CONTEXT is the fixtures directory, not $REPO. There is no .containerignore here,
    # so a context of the repo would tar projects/ and .git into every build -- which is
    # what COURSE_COPY_EXCLUDES exists to prevent (#76).
    cp "$TESTS_DIR/lib/podman-fake" "$FIXTURE_DIR/podman-fake"
    if podman build --label "cs193v.fixturehash=$want" --label "$VT_LABEL" \
                    -f "$FIXTURE_DIR/Containerfile.$case" -t "$tag" "$FIXTURE_DIR" \
                    > "$SB_TMP/build.$case.log" 2>&1; then
        record "fixture:$case" "built"
    else
        fail "fixture:$case-builds" "$(tail -20 "$SB_TMP/build.$case.log")"
        return 1
    fi
    rm -f "$FIXTURE_DIR/podman-fake"
}

# The installer, plus a delimited report of what it changed, as ONE container command. The
# report is how a case sees CONTENT rather than paths: `podman diff` knows /etc/subuid was
# opened for write and cannot say what is in it, and the claim under test is the contents.
sb_work_init() {                      # sb_work_init -> $SB_WORK holding installer + tarball
    SB_WORK="$SB_TMP/work"
    mkdir -p "$SB_WORK"
    copy_course_tree "$SB_TMP/pkg/cs193v-main"
    ( cd "$SB_TMP/pkg" && tar czf "$SB_WORK/course.tar.gz" cs193v-main )
    # What platform() greps. Bound over /proc/version at run time, which is the entire cost
    # of making the WSL arm executable on Linux.
    printf 'Linux version 6.6.0-microsoft-standard-WSL2 (x86_64) #1 SMP\n' > "$SB_WORK/proc-version"
    cp "$PRIVATE/install-cs193v.sh" "$SB_WORK/installer.sh"
    edit_sub "$SB_WORK/installer.sh" '^REPO_OWNER=.*' 'REPO_OWNER="test"'
    edit_sub "$SB_WORK/installer.sh" '^TARBALL=.*'    'TARBALL="file:///work/course.tar.gz"'
    cat > "$SB_WORK/run.sh" <<'RUN'
#!/bin/sh
# Arrange any boot-time state this case asked for, THEN run the installer, then report what
# changed. Arranging it here rather than in the image means one image serves every state --
# at the cost that a file this touches shows up in `podman diff` whichever way the installer
# went, so the content report below is what distinguishes the cases and the path list only
# ever says "and nothing else".
case "${SB_WSLCONF:-}" in
    absent)  sudo rm -f /etc/wsl.conf ;;
    noboot)  printf '[automount]\nenabled=true\n' | sudo tee /etc/wsl.conf >/dev/null ;;
    boot)    printf '[boot]\n'                     | sudo tee /etc/wsl.conf >/dev/null ;;
    systemd) printf '[boot]\nsystemd=true\n'       | sudo tee /etc/wsl.conf >/dev/null ;;
esac

# The package set before and after. For the one fixture that really runs apt, the path-level
# diff is several hundred lines of /usr and /var/lib/dpkg -- unreadable, and the wrong unit
# anyway: what that case claims is that three PACKAGES arrived, so packages are what it is
# asserted in.
dpkg-query -W -f='${Package}\n' 2>/dev/null | LC_ALL=C sort > /var/tmp/report/dpkg-before

bash /work/installer.sh
rc=$?

dpkg-query -W -f='${Package}\n' 2>/dev/null | LC_ALL=C sort > /var/tmp/report/dpkg-now
comm -13 /var/tmp/report/dpkg-before /var/tmp/report/dpkg-now > /var/tmp/report/dpkg-added

printf '\n===INSTALLER-RC=%s===\n' "$rc"
printf '===ETC-SUBUID===\n';  cat /etc/subuid  2>/dev/null
printf '===ETC-SUBGID===\n';  cat /etc/subgid  2>/dev/null
printf '===WSL-CONF===\n';    cat /etc/wsl.conf 2>/dev/null
printf '===DPKG-ADDED===\n';  cat /var/tmp/report/dpkg-added 2>/dev/null
printf '===PODMAN-AFTER===\n'
if command -v podman >/dev/null 2>&1; then podman --version; else echo absent; fi
printf '===SSH-AFTER===\n'
if command -v ssh >/dev/null 2>&1; then echo present; else echo absent; fi
printf '===END-REPORT===\n'
RUN
    chmod +x "$SB_WORK/run.sh"
}

# ONE keystroke per menu, and a case that gets the count wrong HANGS rather than fails: a
# pty never delivers EOF (ERRORS.md B13), so menu()'s `read` simply waits. Measured here,
# not reasoned about -- the first probe fed one key with CS193V_DIR unset, choose_dir ate it
# and ask_consent blocked until the timeout. That timeout is the only thing bounding it.
sandbox_run() {                       # sandbox_run CASE KEYS [PODMAN_ARGS...] -> transcript
    local case="$1" keys="$2"; shift 2
    local SB_NAME="cs193v-fixture-$case-$$"
    # TO A FILE, not a variable. Every call site is `out="$(sandbox_run ...)"` -- a subshell,
    # so a name assigned here never reaches sandbox_diff and `podman diff ""` is what
    # actually ran. Third time this project has paid for that shape (#76, and both doors in
    # lib/podman-shim.sh), which is why it is spelt out rather than remembered.
    printf '%s' "$SB_NAME" > "$SB_TMP/last-name"
    podman rm -f "$SB_NAME" >/dev/null 2>&1 || true
    # NOT --rm: the container has to survive for `podman diff`. Removed by sandbox_reap the
    # moment its diff is taken, so at most one writable layer is live at a time.
    # shellcheck disable=SC2086
    # TWO tmpfs mounts, so that neither the fake podman's state nor this harness's own dpkg
    # snapshots can appear in `podman diff`. Measured the hard way: adding the package report
    # put /tmp/dpkg-{before,now,added} into the writable layer and reddened the audit for two
    # cases that had nothing to do with it. An audit that reports on the harness is an audit
    # that grows an allowlist and stops being read.
    # --label ON THE SAME LINE as `podman run`, because 10-static.sh's rule is a per-line
    # grep and a continuation line does not satisfy it. That is deliberate on its part: the
    # label is what tells this container from a colleague's (#74), and a rule that had to
    # parse shell continuations would be a worse rule.
    printf '%b' "$keys" | timeout 120 podman run --label "$VT_LABEL" -i --name "$SB_NAME" \
        --network=none \
        --mount type=tmpfs,destination=/var/tmp/shim \
        --mount type=tmpfs,destination=/var/tmp/report \
        -v "$SB_WORK:/work:ro" "$@" \
        "$(fixture_tag "$case")" \
        script -q -c /work/run.sh /dev/null 2>&1 | strip_ansi
}

# What the installer changed, relative to the image. Paths only -- `C` means "opened for
# write", not "contents differ", so this answers "and nothing else" and the report above
# answers "and this is what is in it".
# The name of the container the last sandbox_run created. `:?` rather than a default,
# because every caller of these two hands the result to a destructive or a load-bearing
# command, and an empty target is the one argument neither may receive.
sb_name() { cat "$SB_TMP/last-name" 2>/dev/null; }

sandbox_diff() { local n; n="$(sb_name)"; podman diff "${n:?sandbox_diff: no container}" 2>/dev/null; }

sandbox_reap() { local n; n="$(sb_name)"; podman rm -f "${n:?sandbox_reap: no container}" >/dev/null 2>&1 || true; }

# One section of the in-container report.
sb_section() {                        # sb_section TRANSCRIPT NAME
    printf '%s\n' "$1" | sed -n "/^===$2===$/,/^===/p" | sed '1d;$d'
}

# Every fixture container and image this suite could have left behind, and NOTHING else.
# By exact tag and by our own label -- never a `reference=cs193v*` glob, which on this
# machine matches localhost/cs193v:local and two colleagues' instance images.
# Fixture containers an EARLIER, KILLED run left behind, by pid and not by age -- the same
# reasoning sweep_stale_tmpdirs gives, and for a sharper reason here: these carry
# cs193v.test=$NAME, so one survivor reddens cleanup:no-stray-containers in the live tier
# (80-launcher-live.sh:842) as though a colleague's run had leaked it. Measured, not
# imagined: a probe of mine that I killed mid-run left exactly that.
#
# At suite START as well as on EXIT, because a killed suite cannot run its own trap.
sandbox_sweep_stale() {               # -> how many it removed
    local c pid n=0
    for c in $(podman ps -aq --filter "name=^cs193v-fixture-" --format '{{.Names}}' 2>/dev/null); do
        pid="${c##*-}"
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        kill -0 "$pid" 2>/dev/null && continue
        podman rm -f "$c" >/dev/null 2>&1 && n=$((n + 1))
    done
    printf '%s' "$n"
}

sandbox_cleanup() {
    local c
    for c in $SB_CASES; do
        podman rm -f "cs193v-fixture-$c-$$" >/dev/null 2>&1 || true
    done
    rm -f "$FIXTURE_DIR/podman-fake"
    return 0
}

# THE "AND NOTHING ELSE" HALF. `podman diff` lists every path added, changed or deleted
# relative to the image, so a checked-in expected set turns "it changed what it claimed"
# into an assertion -- and, more usefully, reddens when the installer grows a host write
# nobody noticed.
#
# The course tree is excluded because it is the installer's PURPOSE, it is a hundred paths,
# and it is asserted directly elsewhere (the launcher exists at $DIR and is executable).
# What is left is the system blast radius, which is short enough to read.
sandbox_system_diff() {               # sandbox_system_diff DIR -> diff lines outside DIR
    sandbox_diff | grep -vE "^. $1" | grep -v '^[[:space:]]*$' | LC_ALL=C sort
}

# assert_system_diff CASE DIR -- both halves, and the guard that stops empty-vs-empty from
# passing forever (the trap 25-installer.sh:34-37 records for version_lt).
assert_system_diff() {                # assert_system_diff CASE DIR [LABEL]
    local lbl="${3:-$1}" exp="$FIXTURE_DIR/expected-system-paths.$1" got extra want
    want="$SB_TMP/expected.$1"
    grep -v '^#' "$exp" 2>/dev/null | grep -v '^[[:space:]]*$' > "$want" || true
    if [ -s "$want" ]; then pass "sb-$lbl:expected-path-set-is-not-empty"
    else fail "sb-$lbl:expected-path-set-is-not-empty" "$exp is missing, empty or all comments"; return; fi
    got="$(sandbox_system_diff "$2")"
    if [ -n "$got" ]; then pass "sb-$lbl:the-diff-was-really-read"
    else fail "sb-$lbl:the-diff-was-really-read" "podman diff produced nothing"; return; fi
    extra="$(printf '%s\n' "$got" | grep -vxF -f "$want" || true)"
    assert_eq "sb-$lbl:changed-nothing-it-did-not-claim" "" "$extra"
    local missing
    missing="$(grep -vxF -f <(printf '%s\n' "$got") "$want" || true)"
    assert_eq "sb-$lbl:changed-everything-it-claimed" "" "$missing"
}
