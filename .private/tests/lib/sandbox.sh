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
# ─── the two axes, declared once ───────────────────────────────────────────────
#
# THE ONE PLACE. Before this there were three: install-sandbox.sh had its own nested and wsl
# cases, sandbox_run grew a no-podman case, and nest_build hardcoded its own -- and they
# disagreed. That is not a hypothetical: the no-podman fixture installs a real podman, the
# installer's next step asks it for MemTotal, and it failed with "cannot set up namespace using
# /usr/bin/newuidmap" because only the nested path had been given SYS_ADMIN. A person driving
# it by hand found it; the suite had called the case green.
#
# TWO AXES, SUBTRACTIVE, WITH EVERYTHING PRESENT BY DEFAULT, which is the second thing this
# fixes. `--machine NAME` bundled three unrelated decisions into every image -- what software
# is installed, what the container may do, and what platform it looks like -- so a machine
# stood for states nobody asked for. `no-podman` meant BOTH "podman is absent" (its purpose)
# and "podman is installed but cannot run" (an accident of it lacking SYS_ADMIN), and
# assertions were written treating the accident as a feature. Split:
#
#   --no-prereqs   what the machine LACKS      -> which install path runs
#   --no-caps      what the container is DENIED -> which error path runs
#
# and the default -- no flags at all -- is the end-to-end success case, which is the case that
# did not exist before.
#
# 10-static.sh asserts this is the only place that names these flags, which is what stops the
# paths drifting apart again rather than trusting whoever edits next to remember.
#
# AN ARRAY, not a string: `unmask=/proc/*` contains a glob, and a word-split string would let
# the shell expand it against the filesystem. Callers use the ${arr[@]+"${arr[@]}"} idiom that
# 10-static.sh requires, because expanding an empty array under `set -u` is fatal on bash 3.2.

# THE USER-FACING AXIS IS ONE ENTRY, and the reason is a test each candidate has to pass:
# denying a capability only earns a knob if the failure it produces is one a STUDENT could
# have. sysadmin passes on merit rather than mechanism -- Ubuntu ships
# kernel.apparmor_restrict_unprivileged_userns=1 and relies on newuidmap being setuid-root, so
# a restrictive profile, a nosuid mount or a missing uidmap all give a student podman that is
# installed and cannot create a user namespace. Same observable, and the installer stops at
# write_local_args (installer:757).
MACHINE_CAP_NAMES='sysadmin'
# THE OTHER THREE ARE FIXTURE SCAFFOLDING, measured rather than assumed:
#   * fuse -- this host's podman reports driver=overlay with no options and never touches
#     fuse-overlayfs; /dev/fuse is crw-rw-rw- on any normal Linux.
#   * tun  -- same shape; pasta needs /dev/net/tun only because we nested.
#   * unmask -- /proc/sys is not even a separate mount outside a container, so nothing masks it
#     on a student's machine.
# Denying any of them breaks OUR container and models nothing, so they are unconditional
# constants of every machine. They stay reachable here, and only here, because the nested
# preflight's differential controls need them to prove the HARNESS requires them -- a claim
# about the harness, which is why it is not on the flag surface.
#   * label -- the SELinux type the fixture runs under. Only ever passed on a host that HAS
#     SELinux, and then only to a base that runs a podman inside itself; see the arm in
#     machine_flags for the measurement and for the two narrower postures that were tried first.
MACHINE_CAP_INTERNAL='unmask fuse tun label'
# Subtracted at boot by lib/sandbox-guest.sh, which is where the removal commands live.
MACHINE_PREREQ_NAMES='podman ssh subuid curl uidmap'

# ─── the bases, and which of them nest ─────────────────────────────────────────
#
# A DISTRO IS A BASE, NOT A THIRD AXIS. The two axes above are subtractive -- everything is
# present and a flag takes something away -- and a distro is neither an absence nor a capability.
# It is a SUBSTITUTION, which is exactly what `base=` already means: Containerfile.podman-old is
# "the one machine that is not the machine" because a podman VERSION cannot be produced by
# subtracting from a 26.04 base. A package MANAGER cannot either.
MACHINE_BASE_NAMES='machine podman-old podman-old-nested debian fedora fedora-nested arch'

# WHICH BASES RUN A PODMAN INSIDE THEMSELVES, and it is only one of them. SYS_ADMIN, the unmask
# and the two devices are what a NESTED podman costs; podman-old and debian both die in survey
# off a single `podman --version`, which never touches the runtime, so handing them a capability
# was privilege nothing had asked for.
#
# IT WAS ALSO INCONSISTENT, which is the sharper reason this is a list rather than a comment:
# install-sandbox.sh special-cased podman-old and withheld every flag, while sandbox_run handed
# it the full set. So the machine you drove BY HAND and the machine the suite ASSERTED against
# differed -- the exact drift 10-static.sh's one-place rules exist to stop, which had opened up
# anyway because the two paths disagreed about a CASE rather than about a flag. One list, read by
# both.
MACHINE_NESTED_BASES='machine podman-old-nested fedora-nested'

# AND WHICH OF THOSE NEED SYS_ADMIN. Every nesting base does, and the interesting part is that
# they need it for TWO SEPARATE REASONS -- which is worth writing down, because trying to narrow
# this list on the strength of only the first reason was measurably wrong.
#
# REASON ONE, creating the nested user namespace, is Debian-family PACKAGING and not nesting per
# se. Debian's shadow is compiled without sys/capability.h, so newuidmap carries only a setuid bit,
# and a setuid bit does not preserve CAP_SETUID inside an unprivileged nested userns. Fedora's
# shadow-utils ships FILE CAPABILITIES, which do survive. Measured by 26-installer-sandbox.sh's
# fedora-caps differential, and visible in one `ls`: fedora:43 has -rwxr-xr-x on newuidmap while
# debian:13 and ubuntu:24.04 have -rwsr-xr-x.
#
#   fedora-nested      without SYS_ADMIN -> user:[4026533148]        (a namespace!)
#   podman-old-nested  without SYS_ADMIN -> cannot set up namespace using "/usr/bin/newuidmap"
#
# REASON TWO, BUILDING, applies to every base regardless of packaging, and is what makes this list
# all of them. crun calls sethostname(2) when it creates the container for a RUN step, and that
# needs CAP_SYS_ADMIN. Measured the hard way: fedora-nested was briefly removed from this list on
# the strength of reason one alone, and the Fedora end-to-end case then failed at STEP 2/25 with
#
#   error running container: from /usr/bin/crun creating container for [/bin/sh -c apt-get ...]:
#   sethostname: Operation not permitted
#
# So reason one is a true and useful distinction that says nothing about whether a base can BUILD.
# Nothing covered building on a reduced flag set until fedora-e2e existed, which is the test bed
# catching an over-generalisation rather than a product bug.
#
# ONE TRAP REASON ONE RESTS ON: the Fedora BASE IMAGE loses those capabilities (RHBZ 1995337), so
# Containerfile.fedora-nested restores them with `rpm --setcaps shadow-utils` -- exactly as
# quay.io/podman/stable does -- and asserts at build time that they are there. Without that line
# the differential would measure a broken image rather than Fedora's packaging.
MACHINE_SYSADMIN_BASES='machine podman-old-nested fedora-nested'

machine_is_nested() {                 # machine_is_nested BASE -> 0 if it runs a podman inside
    case " $MACHINE_NESTED_BASES " in *" $1 "*) return 0 ;; esac
    return 1
}

# WHICH PACKAGE MANAGER THE GUEST HAS, which lib/sandbox-guest.sh needs in order to REMOVE
# something for --no-prereqs. Passed IN from the base name rather than read from the guest's own
# /etc/os-release, and that is deliberate: install-cs193v.sh detects its family from os-release, so
# a harness that read the same file could be wrong in exactly the same way and mask it.
machine_distro() {                    # machine_distro BASE -> debian | fedora | arch
    case "$1" in
        fedora|fedora-nested) printf 'fedora' ;;
        arch)                 printf 'arch' ;;
        *)                    printf 'debian' ;;
    esac
}

machine_needs_sysadmin() {            # machine_needs_sysadmin BASE -> 0 if its newuidmap is setuid
    case " $MACHINE_SYSADMIN_BASES " in *" $1 "*) return 0 ;; esac
    return 1
}

# STRICT, and shared, so a typo cannot read as an installer branch in either half. CLAUDE.md §2
# records what a silently-skipped malformed value costs; here it is worse than a shrunken set,
# because you would conclude the installer took a path it never took.
machine_valid() {                     # machine_valid caps|prereqs|bases LIST -> 0, or the bad entry
    local kind="$1" list="${2:-}" known e
    case "$kind" in
        caps)    known="$MACHINE_CAP_NAMES" ;;
        prereqs) known="$MACHINE_PREREQ_NAMES" ;;
        bases)   known="$MACHINE_BASE_NAMES" ;;
        *) printf 'machine_valid: unknown kind %s\n' "$kind" >&2; return 2 ;;
    esac
    [ -n "$list" ] || return 0
    for e in $(printf '%s' "$list" | tr ',' ' '); do
        case " $known " in *" $e "*) ;; *) printf '%s' "$e"; return 1 ;; esac
    done
    return 0
}

MACHINE_FLAGS=()
# The run-time half of both axes. Every flag a fixture container gets beyond the constants
# sandbox_run applies itself.
machine_flags() {                     # machine_flags [NO_CAPS] [PLATFORM] [FAKE_PODMAN] [BASE]
    MACHINE_FLAGS=()
    local drop platform fake base
    drop=",$(printf '%s' "${1:-}" | tr -d '[:space:]'),"
    platform="${2:-linux}"; fake="${3:-no}"; base="${4:-machine}"
    # VALIDATED HERE TOO, against both vocabularies, so a typo in one of the nested case's
    # differential controls -- which pass names this function accepts but the flag surface does
    # not -- fails instead of silently granting the flag it meant to remove. A control that
    # removes nothing passes for the wrong reason, which is the worst outcome available.
    local d
    for d in $(printf '%s' "$drop" | tr ',' ' '); do
        case " $MACHINE_CAP_NAMES $MACHINE_CAP_INTERNAL " in
            *" $d "*) ;;
            *) printf 'machine_flags: unknown capability %s\n' "$d" >&2; return 2 ;;
        esac
    done
    # GATED ON THE BASE, because these four are what a NESTED podman costs and nothing else here
    # wants them. A base that dies in survey gets none of them -- see MACHINE_NESTED_BASES. The
    # --no-caps vocabulary is still validated above for every base, so `--no-caps=sysadmin` on a
    # base that was never going to get it fails as a nonsense combination rather than passing
    # vacuously.
    if machine_is_nested "$base"; then
    # SYS_ADMIN IS NARROWER THAN THE OTHER THREE, and measured rather than assumed -- see
    # MACHINE_SYSADMIN_BASES. A Fedora base nests without it because its newuidmap carries file
    # capabilities; a Debian-family one cannot, because a setuid bit does not survive the nesting.
    if machine_needs_sysadmin "$base"; then
    case "$drop" in *,sysadmin,*) : ;; *) MACHINE_FLAGS=("${MACHINE_FLAGS[@]}" --cap-add=SYS_ADMIN) ;; esac
    fi
    case "$drop" in *,unmask,*)   : ;; *) MACHINE_FLAGS=("${MACHINE_FLAGS[@]}" --security-opt 'unmask=/proc/*') ;; esac
    case "$drop" in *,fuse,*)     : ;; *) MACHINE_FLAGS=("${MACHINE_FLAGS[@]}" --device /dev/fuse) ;; esac
    case "$drop" in *,tun,*)      : ;; *) MACHINE_FLAGS=("${MACHINE_FLAGS[@]}" --device /dev/net/tun) ;; esac
    # ─── AND ON AN SELinux HOST, THE LABEL COMES OFF (#119) ────────────────────
    #
    # WHAT IT FIXES, which is BOTH of the two limits #119 reports as independent. They are one
    # cause: the host's policy adjudicating what the OUTER fixture may do. Without this flag, on
    # Fedora 44 / podman 5.8.4 / crun 1.28:
    #
    #   * crun cannot create a container for a RUN step -- `mount `proc` to `proc`: Permission
    #     denied` -- so both nested builds die at STEP 3/25 of the course image, and
    #   * /dev/net/tun is passed but cannot be stat()ed, so the inner network never comes up
    #     (`Failed to set up tap device in namespace`, or on podman 4.9.3
    #     `slirp4netns: open("/dev/net/tun"): Permission denied`).
    #
    # #119 concluded the second needed `setsebool -P container_use_devices 1` -- a root,
    # machine-wide change. It does not: that boolean gates container_t, and this changes the type.
    #
    # NOT THE KERNEL, MEASURED: `--security-opt unmask=ALL` does not help, so this is not
    # mount_too_revealing() refusing a procfs whose parent has hidden submounts.
    #
    # THE TWO NARROWER POSTURES THAT WERE TRIED, so they are not tried again:
    #
    #   label=type:container_engine_t   the type container-selinux ships FOR a container engine
    #                                   inside a container. Gets past `mount proc` and is then
    #                                   refused every masked sysfs path in turn -- `mount `tmpfs`
    #                                   to `sys/firmware``, and with that unmasked, `sys/fs/selinux`
    #                                   next. Nothing here can stop the INNER engine masking them:
    #                                   containers.conf(5) has no key for masked paths, and those
    #                                   runs are buildah's, inside the launcher's own podman build.
    #   label=type:container_runtime_t  works -- because it transitions to spc_t. It KEEPS the MCS
    #                                   categories, which reads like least privilege and is not:
    #                                   a container at s0:c103,c851 read a file labelled
    #                                   container_file_t:s0:c1,c2 that a properly-labelled
    #                                   container_t container was denied. The categories are
    #                                   decorative on spc_t, so this is label=disable wearing a
    #                                   narrower name, which is worse than saying it plainly.
    #
    # WHAT IT COSTS, stated rather than apologised for. lib/sandbox.sh's header lists what makes
    # these fixtures safe -- no host state inside, no podman socket, no writable mount,
    # --network=none -- and SELinux is not on that list. The outer container is a clean room for
    # system-wide changes, not the boundary: that is the user namespace (the fixture is uid 2,
    # which lands on a subuid), DAC, and there being nothing mounted worth reading. Upstream's own
    # podman-in-podman recipe passes this same flag.
    #
    # AND IT COSTS NO FIDELITY, which is the claim worth checking rather than assuming. The inner
    # engine ALREADY sees SELinux as disabled -- /sys/fs/selinux is empty inside a container
    # (podman-run(1) on label=nested) -- so the course container it builds gets no label either
    # way. What these fixtures cannot test about the course container's own labelling, they could
    # not test before this flag; MANUAL.md records it as a real-Fedora-machine item.
    #
    # THE BAN ELSEWHERE IS NOT THIS. 10-static.sh's container.args invariants and
    # 60-container.sh's flag check both forbid label=disable for the COURSE container, one level
    # in, where host isolation really is the user namespace's job and this would punch through it.
    # Same distinction this function already relies on for unmask=/proc/* against container.args'
    # ban on unmask=ALL: a fixture, one level out, naming one thing.
    if [ -n "${VT_SELINUX:-}" ]; then
    case "$drop" in *,label,*)    : ;; *) MACHINE_FLAGS=("${MACHINE_FLAGS[@]}" --security-opt label=disable) ;; esac
    fi
    fi
    # A BIND MOUNT IS THE WHOLE WSL ARM. platform() decides by `grep -qi microsoft
    # /proc/version` (installer:306) and the effect is two file writes, so it is executable on
    # Linux with no Windows anywhere.
    case "$platform" in
        wsl) MACHINE_FLAGS=("${MACHINE_FLAGS[@]}" -v "$SB_WORK/proc-version:/proc/version:ro$VT_MOUNT_Z") ;;
    esac
    # A TEST CONVENIENCE, NAMED AS ONE, and deliberately on neither axis: a fake podman is
    # not an absence and not a capability, and it is not a machine any student could have.
    # It used to be baked into two fixtures, which made it invisible in the machine name --
    # `subuid` and `wsl` were fast for a reason nothing said out loud. /usr/local/bin comes
    # before /usr/bin on the default PATH, so the real podman is shadowed rather than removed.
    # OVER /usr/bin/podman, NOT /usr/local/bin/podman, and that is a measured correction rather
    # than a preference. Mounting a file at a path that does not exist makes `podman diff` report
    # it as ADDED, so the fake showed up in every exact-set audit as a path the installer wrote;
    # the obvious fix -- a non-executable placeholder in the image -- turned out to be far worse.
    # BASH's `command -v` RETURNS A NON-EXECUTABLE FILE when it is the only candidate on PATH
    # (dash correctly returns nothing), so once --no-prereqs=podman removed the real binary, the
    # installer found the empty placeholder, read an empty version, and refused with "Podman is
    # installed, but the course needs 5.7.0 or newer" -- a fixture artefact wearing the costume
    # of a product refusal. Mounting over the real path shadows it exactly and adds no path.
    if [ "$fake" = yes ]; then
        MACHINE_FLAGS=("${MACHINE_FLAGS[@]}" -v "$SB_WORK/podman-fake:/usr/bin/podman:ro$VT_MOUNT_Z" \
                       -e CS193V_SHIM=/var/tmp/shim)
    fi
    return 0
}

# ─── a machine, described once per case ────────────────────────────────────────
#
# REQUIRED BEFORE EVERY sandbox_run, and cleared by it, so a case that forgets to say what
# machine it wants FAILS rather than silently inheriting the previous case's. That is the
# no-podman conflation's exact shape -- state standing in for something nobody declared -- and
# the fix is to make the omission loud.
SB_BASE=machine; SB_NO_CAPS=''; SB_NO_PREREQS=''; SB_PLATFORM=linux; SB_FAKE_PODMAN=no
SB_SPEC=''
sb_machine() {                        # sb_machine [base=B] [no-caps=L] [no-prereqs=L] [platform=P] [fake-podman=yes]
    SB_BASE=machine; SB_NO_CAPS=''; SB_NO_PREREQS=''; SB_PLATFORM=linux; SB_FAKE_PODMAN=no
    local a bad
    for a in "$@"; do
        case "$a" in
            base=*)        SB_BASE="${a#base=}" ;;
            no-caps=*)     SB_NO_CAPS="${a#no-caps=}" ;;
            no-prereqs=*)  SB_NO_PREREQS="${a#no-prereqs=}" ;;
            platform=*)    SB_PLATFORM="${a#platform=}" ;;
            fake-podman=*) SB_FAKE_PODMAN="${a#fake-podman=}" ;;
            *) printf 'sb_machine: unknown key %s\n' "$a" >&2; return 2 ;;
        esac
    done
    # STRICTLY, like the other two vocabularies, and this was the one that was missing: `base=`
    # was assigned unvalidated, so `sb_machine base=fedroa` reached fixture_build and failed there
    # with "the specified Containerfile does not exist" -- a typo reported as a missing fixture.
    if ! bad="$(machine_valid bases "$SB_BASE")"; then
        printf 'sb_machine: unknown base %s (want: %s)\n' "$bad" "$MACHINE_BASE_NAMES" >&2; return 2
    fi
    if ! bad="$(machine_valid caps "$SB_NO_CAPS")"; then
        printf 'sb_machine: unknown capability %s (want: %s)\n' "$bad" "$MACHINE_CAP_NAMES" >&2; return 2
    fi
    if ! bad="$(machine_valid prereqs "$SB_NO_PREREQS")"; then
        printf 'sb_machine: unknown prereq %s (want: %s)\n' "$bad" "$MACHINE_PREREQ_NAMES" >&2; return 2
    fi
    case "$SB_PLATFORM" in linux|wsl) ;; *) printf 'sb_machine: platform %s\n' "$SB_PLATFORM" >&2; return 2 ;; esac
    # NONSENSE, AND ALSO IMPOSSIBLE: the fake is bind-mounted over /usr/bin/podman, so apt cannot
    # delete the file it is asked to remove. Refused rather than half-honoured.
    case ",$SB_NO_PREREQS," in
        *,podman,*) if [ "$SB_FAKE_PODMAN" = yes ]; then
                        printf 'sb_machine: --fake-podman cannot combine with removing podman\n' >&2; return 2
                    fi ;;
    esac
    SB_SPEC="base=$SB_BASE no-caps=${SB_NO_CAPS:-none} no-prereqs=${SB_NO_PREREQS:-none}"
    SB_SPEC="$SB_SPEC platform=$SB_PLATFORM fake-podman=$SB_FAKE_PODMAN"
    return 0
}

fixture_tag() {                       # fixture_tag BASE -> the tag for this instance
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
# THE CONTAINERFILE ALONE now. lib/podman-fake used to be hashed in because two fixtures
# COPYed it; none do, since --fake-podman bind-mounts it at run time instead. Hashing a file no
# image contains would rebuild every machine whenever the fake changed, which is a slow no-op.
fixture_hash() {                      # fixture_hash BASE -> a hex digest
    # THE RECIPE IS NOT ONLY THE CONTAINERFILE. Anything it COPYs into the image is part of the
    # recipe too, and hashing only the Containerfile meant editing a COPYed file left the image
    # CACHED -- so every case kept running against the previous build, silently. Found the hard
    # way: a fake was edited, rebuilt "successfully", and the run showed the old behaviour with
    # nothing anywhere saying why.
    #
    # Paths are printed RELATIVE to $FIXTURE_DIR, so the digest does not depend on where the
    # repository happens to be checked out.
    {
        cat "$FIXTURE_DIR/Containerfile.$1"
        sed -n 's/^COPY[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/p' \
            "$FIXTURE_DIR/Containerfile.$1" \
        | while IFS= read -r src; do
            [ -n "$src" ] || continue
            ( cd "$FIXTURE_DIR" || exit 0
              if [ -d "$src" ]; then
                  find "$src" -type f | LC_ALL=C sort | while IFS= read -r one; do
                      printf '%s\n' "$one"; cat "$one"
                  done
              elif [ -f "$src" ]; then
                  printf '%s\n' "$src"; cat "$src"
              fi )
        done
    } | sb_sha
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
    if podman build --label "cs193v.fixturehash=$want" --label "$VT_LABEL" \
                    -f "$FIXTURE_DIR/Containerfile.$case" -t "$tag" "$FIXTURE_DIR" \
                    > "$SB_TMP/build.$case.log" 2>&1; then
        record "fixture:$case" "built"
    else
        fail "fixture:$case-builds" "$(tail -20 "$SB_TMP/build.$case.log")"
        return 1
    fi
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
    # THE SAME `sandbox` COMMAND THE HAND-DRIVEN TOOL GETS, so the arrangement of a machine has
    # ONE implementation. run.sh used to carry its own copy of the wsl.conf cases while
    # lib/sandbox-guest.sh carried another, which is the drift this whole change exists to stop
    # -- and --no-prereqs would have made it two copies of something far more destructive.
    cp "$TESTS_DIR/lib/sandbox-guest.sh" "$SB_WORK/sandbox"
    cp "$TESTS_DIR/lib/podman-fake"      "$SB_WORK/podman-fake"
    chmod +x "$SB_WORK/sandbox" "$SB_WORK/podman-fake"
    cp "$PRIVATE/install-cs193v.sh" "$SB_WORK/installer.sh"
    edit_sub "$SB_WORK/installer.sh" '^REPO_OWNER=.*' 'REPO_OWNER="test"'
    edit_sub "$SB_WORK/installer.sh" '^TARBALL=.*'    'TARBALL="file:///work/course.tar.gz"'
    cat > "$SB_WORK/nest-probe.sh" <<'PROBE'
set -u
# Every answer is a positive token. An empty value means the probe did not run, and the
# assertion that reads it must fail rather than see what it hoped for.
echo "FIXTURE_ID=$(cat /etc/cs193v-fixture-id 2>/dev/null)"
echo "ID=$(id -u):$(id -un)"
# WHAT THE HOST'S LSM ACTUALLY APPLIED to this fixture, read from inside, which is the only place
# it can be read: the probes are --rm and gone before anything host-side could inspect them.
# NOT NAMED FOR SELinux, deliberately -- on the machine this suite is usually developed on this
# file is AppArmor's (.config/container.args records the same distinction), so a token called
# SELINUX_CTX would be reporting a different LSM under a name nobody would question.
# DEFAULTED WITH ${x:-}, NOT `|| echo`: `tr` exits 0 on empty input, so a `|| echo none` arm can
# never fire and the token would go out empty on a host with no label at all.
pac="$(cat /proc/self/attr/current 2>/dev/null | tr -d '\0')"
echo "PROC_ATTR_CURRENT=${pac:-no-lsm-label}"
echo "PODMAN_VERSION=$(podman --version 2>&1 | tail -1)"
echo "SUBUID=$(cat /etc/subuid 2>/dev/null)"
echo "INNER_USERNS=$(podman unshare readlink /proc/self/ns/user 2>&1 | tail -1)"
echo "MAPPED_IDS=$(podman unshare awk '{s+=$3} END{print s}' /proc/self/uid_map 2>&1 | tail -1)"
echo "ROOTFS=$(findmnt -no FSTYPE,OPTIONS --target /usr/bin/newuidmap 2>/dev/null | awk '{print $1, ($2 ~ /nosuid/) ? "nosuid" : "suid-ok"}')"
# THE MOUNT, not the file mode. `test -w` on a root-owned file is false for this user however
# the mount is configured, so it measured the wrong thing entirely: podman masks /proc/sys with
# a read-only bind mount, and the unmask removes that mount rather than changing a permission.
# Both answers are positive tokens, so an empty value fails either assertion.
if findmnt -no OPTIONS /proc/sys 2>/dev/null | grep -qE '(^|,)ro(,|$)'; then
    echo "PROC_SYS=masked-ro"
else
    echo "PROC_SYS=not-masked"
fi
echo "DEVFUSE=$(test -c /dev/fuse && echo char-device || echo MISSING)"
echo "DEVNETTUN=$(test -c /dev/net/tun && echo char-device || echo MISSING)"
mkdir -p /tmp/l /tmp/u /tmp/w /tmp/m
fuse-overlayfs -o lowerdir=/tmp/l,upperdir=/tmp/u,workdir=/tmp/w /tmp/m >/dev/null 2>&1
echo "FUSE_MOUNT=$(findmnt -no FSTYPE /tmp/m 2>/dev/null || echo FAILED)"
fusermount3 -u /tmp/m >/dev/null 2>&1 || true
# ─── AND CAN A CONTAINER ACTUALLY START IN HERE? (#119) ─────────────────────────
#
# THE ONE THING THIS PROBE DID NOT DO, and the omission cost #119 twelve red assertions. Every
# other token above is answered by `podman unshare` or `podman info`, and NEITHER CREATES A
# CONTAINER -- so the first thing in the whole suite to ask crun for one was a 25-step build,
# several minutes and 6 GB in. On a Fedora host that build dies at STEP 3/25 with
#
#     crun: mount `proc` to `proc`: Permission denied
#
# and eleven assertions about the installer fail because of it. This asks in the seconds tier.
#
# A HAND-BUILT ROOTFS, WHICH IS WHAT MAKES IT AFFORDABLE. Creating a container normally needs an
# image, and there is none in here, so the obvious probe pulls one -- measured at 3 s per probe
# invocation against a tier that costs about six seconds in total, and it puts the INTERNET on the
# path of a preflight. `--rootfs` takes an exploded directory instead (podman-run(1)), and
# /bin/true plus what ldd says it links against is three files and no network at all.
#
# WHAT IT COSTS, measured rather than asserted to be cheap: interleaved against the previous probe,
# n=5, this adds 130 ms per invocation (527 ms -> 658 ms). There are nine invocations across the
# tier, so about a second and a quarter, which is why this is on the default path of the
# prerequisites gate rather than behind a variable of its own.
#
# NOT `--rootfs /`, WHICH CANNOT WORK -- measured, so it is not tried again. crun pivot_root()s
# onto the rootfs it is given, and pivot_root onto the root you are already standing on is EINVAL:
#
#     crun: pivot_root: Invalid argument
#
# `--rootfs /:O` fails differently, inside the overlay driver, on all three nested bases. A copied
# directory has neither problem.
#
# THE WHOLE crun PATH, deliberately, rather than the single mount that fails first. `mount proc`
# is not the only thing the policy denies: under --security-opt label=type:container_engine_t proc
# SUCCEEDS and the masked sysfs paths are refused next (`mount tmpfs to sys/firmware`), so a probe
# that tested only proc would report that posture as working. An
# `unshare --user --map-root-user --mount --pid --fork mount -t proc` probe was measured, works,
# and was rejected for exactly that reason -- it answers a narrower question than its name would.
#
# --network=none, SO THIS MEASURES ONE THING. Without it the failure without the flag is the inner
# network's ("Failed to set up tap device in namespace", or on podman 4.9.3
# `slirp4netns: open("/dev/net/tun"): Permission denied`) -- a REAL failure, and the same policy's
# doing, but a different one from the mount, and a probe that cannot tell them apart is a probe
# whose value has to be read rather than asserted on. DEVNETTUN above is the token for that half.
#
# --label IS INERT HERE and is present anyway: this container is created by the podman INSIDE the
# fixture, so no host-side sweep can see it, and it is --rm besides. 10-static.sh's
# throwaways:every-podman-run-is-labelled-as-ours is a per-line grep over this file, and its
# neighbour records why a rule that parsed shell continuations would be a worse rule -- so the
# label goes on the line rather than the rule learning about heredocs.
rf=/tmp/rootfs; rm -rf "$rf"; mkdir -p "$rf/bin"
cp /usr/bin/true "$rf/bin/true" 2>/dev/null || cp /bin/true "$rf/bin/true" 2>/dev/null || true
for lib in $(ldd /usr/bin/true 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^\//) print $i}'); do
    mkdir -p "$rf$(dirname "$lib")" && cp "$lib" "$rf$lib" 2>/dev/null || true
done
inner="$(podman run --label cs193v.test=nested-probe --rm --network=none --rootfs "$rf" /bin/true 2>&1)"
# A POSITIVE TOKEN EITHER WAY, per this file's contract above: `ok` when the container ran and
# said nothing, and crun's own words when it did not -- which is the diagnosis, carried out of the
# container verbatim, with no classifier anywhere deciding what the words mean.
# FLATTENED, because nest_get takes only the first line of a token (`head -1`) and podman can
# print a warning ahead of the error -- on podman 4.9.3 the network failure arrives under two
# lines of "Support for seccomp is experimental". Collapsing keeps the cause in the value.
if [ -z "$inner" ]; then echo "INNER_RUN=ok"
else echo "INNER_RUN=FAILED: $(printf '%s' "$inner" | tr '\n' ' ')"; fi
echo "STORE=$(podman info --format '{{.Store.GraphRoot}} {{.Store.GraphDriverName}}' 2>&1 | tail -1)"
echo "CGROUP=$(podman info --format '{{.Host.CgroupManager}} {{.Host.CgroupsVersion}}' 2>&1 | tail -1)"
if [ -S "/run/user/$(id -u)/bus" ]; then bus=bus; else bus=no-bus; fi
echo "SESSION=$bus ${DBUS_SESSION_BUS_ADDRESS:-unset}"
PROBE
    chmod +x "$SB_WORK/nest-probe.sh"
    # The nested case's own command: the installer end to end, then the two questions only
    # answerable from inside once it has finished -- is the image really there, and did this
    # fixture's SYS_ADMIN reach the container the launcher created. That second one is the
    # boundary the fixture exists on the wrong side of, so it is asserted rather than trusted.
    cat > "$SB_WORK/nest-run.sh" <<'NEST'
set -u
# THE SAME ARRANGEMENT AS EVERY OTHER CASE, so the end-to-end case -- no podman, installed for
# real, and then a real build -- is one flag rather than a fixture of its own. That case is the
# one nothing covered before: no-podman proved apt installs it, nested proved the build works,
# and nothing joined them.
/work/sandbox arrange </dev/null || { printf '===ARRANGE-FAILED===\n'; exit 90; }
# TRACED, so both the fixture cases and the nested build are coverage producers. They reach
# branches no host case can decide -- the real apt install, the real usermod, both wsl.conf
# writes -- and a gate blind to them would score the installer as far less covered than it is.
# fd 9 keeps the trace off stdout; the numbers come back out in the report below.
# TRACED ONLY WHEN ASKED. Measured: `bash -x` took this tier from 6.4 s to 69 s and pushed the
# apt case past its ceiling, because tracing multiplies the cost of every command in a run that
# installs 31 packages. Coverage is a periodic question, not something every run should pay 10x
# for -- so the container half is opt-in and the gate reports which producers it heard from
# rather than pretending a host-only number is the whole picture.
# WHICH INSTALLER, because one case runs the lowered-floor copy sb_work_init writes beside the
# real one. Defaulted, so every existing case is unchanged and only the case that means it says so.
INST="${SB_INSTALLER:-/work/installer.sh}"
printf '===INSTALLER-USED===\n%s\n' "$INST"
if [ -n "${CS193V_COVERAGE:-}" ]; then
    PS4='+${LINENO} ' BASH_XTRACEFD=8 bash -x "$INST" 8>>/var/tmp/report/trace
else
    bash "$INST"
fi
rc=$?
# Without this the container cannot exit: podman's rootless pause process outlives the run and
# holds this container's stdio open. See run.sh for the measurement.
pkill -x catatonit 2>/dev/null || true
printf '\n===INSTALLER-RC=%s===\n' "$rc"
printf '===ARRANGED===\n'; cat /var/tmp/report/arranged 2>/dev/null
# A TRAILING NEWLINE, because ${Status} has none of its own: without it the value ran straight
# into the next `===IMAGE-EXISTS===` header, sb_section found no line matching that header, and
# the image assertion failed with an empty value on a run that had built the image perfectly.
printf '===DPKG-PODMAN===\n'; dpkg-query -W -f='${Status}\n' podman 2>/dev/null || echo not-installed
printf '===IMAGE-EXISTS===\n'
podman image exists localhost/cs193v:local && echo yes || echo no
printf '===INNER-CAPS===\n'
podman inspect cs193v --format '{{.EffectiveCaps}}' 2>/dev/null || echo NO-CONTAINER
printf '===INNER-STORE-BYTES===\n'
du -sb "$(podman info --format '{{.Store.GraphRoot}}')" 2>/dev/null | cut -f1
# THE LAUNCHER'S OWN BUILD LOG. The meter deliberately shows only podman's last eight lines
# on failure, so the transcript cannot carry the error -- but BUILD_LOG has all of it, which
# is what cs193v:908-910 says it is for on a build that fails rather than hangs.
printf '===BUILD-LOG===\n'
for f in /tmp/cs193v-build-*.log; do [ -f "$f" ] && tail -60 "$f"; done
printf '===DOCTOR===\n'
"$HOME/cs193v/cs193v" doctor >/dev/null 2>&1 && echo ok || echo problems
printf '===TRACE===\n'
sed -n 's/^+\([0-9]\{1,\}\) .*/\1/p' /var/tmp/report/trace 2>/dev/null | sort -un | tr '\n' ' '
printf '\n===END-REPORT===\n'
NEST
    chmod +x "$SB_WORK/nest-run.sh"
    cat > "$SB_WORK/run.sh" <<'RUN'
#!/bin/sh
# Arrange the machine this case asked for, THEN run the installer, then report what changed.
#
# ARRANGED BY `sandbox arrange`, NOT HERE. This file used to carry its own copy of the wsl.conf
# states while lib/sandbox-guest.sh carried another, and --no-prereqs would have made that two
# copies of `apt-get remove`. One implementation, used by the suite and by the person driving it
# by hand, so the machine you assert against and the machine you poke at cannot differ.
#
# STDIN CLOSED FOR THE ARRANGEMENT. The keystrokes on stdin belong to the installer's menus, and
# anything the arrangement runs -- apt in particular -- is entitled to read the terminal.
/work/sandbox arrange </dev/null || { printf '===ARRANGE-FAILED===\n'; exit 90; }

# The package set before and after, taken AFTER the arrangement so that a package --no-prereqs
# removed and the installer put back reads as ADDED, which is the claim. For the cases that
# really run apt, the path-level diff is several hundred lines of /usr and /var/lib/dpkg --
# unreadable, and the wrong unit anyway.
# INSTALLED, NOT MERELY KNOWN, and the difference is the whole assertion. `apt-get remove`
# leaves a package in the `config-files` state, and plain `dpkg-query -W` lists it there just as
# it lists an installed one -- so the before-picture still contained podman, `comm` found nothing
# new afterwards, and "apt installed three packages" failed on a run where apt demonstrably had.
sb_installed() { dpkg-query -W -f='${db:Status-Status} ${Package}\n' 2>/dev/null \
                   | awk '$1 == "installed" { print $2 }' | LC_ALL=C sort; }
sb_installed > /var/tmp/report/dpkg-before

# TRACED ONLY WHEN ASKED. Measured: `bash -x` took this tier from 6.4 s to 69 s, because tracing
# multiplies the cost of every command in a run that installs 31 packages. Coverage is a
# periodic question, not something every run should pay 10x for -- so the container half is
# opt-in and the gate reports which producers it heard from rather than pretending a host-only
# number is the whole picture. fd 9 keeps the trace off stdout.
# WHICH INSTALLER, defaulted, so every existing case is unchanged and only a case that means it
# says so. nest-run.sh honours the same variable; the floor-skew case is a Tier A case and runs
# through this file.
INST="${SB_INSTALLER:-/work/installer.sh}"
printf '===INSTALLER-USED===\n%s\n' "$INST"
if [ -n "${CS193V_COVERAGE:-}" ]; then
    PS4='+${LINENO} ' BASH_XTRACEFD=8 bash -x "$INST" 8>>/var/tmp/report/trace
else
    bash "$INST"
fi
rc=$?

# ─── release podman's rootless pause process ────────────────────────────────────
# WITHOUT THIS THE CONTAINER CANNOT EXIT, and that is measured, not defensive. The first podman
# command to set up the rootless user namespace forks a pause process (`catatonit -P`) which
# outlives the installer and keeps this container's pty open, so `script` never returns and the
# run burns its whole ceiling having FINISHED successfully. That is exactly what the "no-podman
# hangs when given SYS_ADMIN" note recorded as unexplained: with SYS_ADMIN the podman it installs
# works, so a pause process exists; without it podman never starts one and the case looked fine.
#
# INSIDE THE CONTAINER'S OWN PID NAMESPACE, so this cannot see -- let alone signal -- anything
# on the host or in a colleague's run.
pkill -x catatonit 2>/dev/null || true

sb_installed > /var/tmp/report/dpkg-now
comm -13 /var/tmp/report/dpkg-before /var/tmp/report/dpkg-now > /var/tmp/report/dpkg-added

printf '\n===INSTALLER-RC=%s===\n' "$rc"
printf '===ARRANGED===\n';   cat /var/tmp/report/arranged 2>/dev/null
printf '===ETC-SUBUID===\n'; cat /etc/subuid  2>/dev/null
printf '===ETC-SUBGID===\n'; cat /etc/subgid  2>/dev/null
printf '===WSL-CONF===\n';   cat /etc/wsl.conf 2>/dev/null
printf '===DPKG-ADDED===\n'; cat /var/tmp/report/dpkg-added 2>/dev/null
printf '===PODMAN-AFTER===\n'
if command -v podman >/dev/null 2>&1; then podman --version; else echo absent; fi
# INSTALLED IS NOT THE SAME AS WORKING, and asserting the former let a broken podman read as a
# success. `podman --version` never touches the runtime, so it answers happily from a podman
# that cannot create a user namespace -- while the installer's very next step asks it for
# MemTotal, gets nothing, and stops. This is the question the installer actually asks.
# ASKED ONLY WHERE IT IS WANTED. `podman info` creates a store, an events log and lock files,
# and their exact set differs between runs -- so probing unconditionally gave the podman-old
# case a non-deterministic blast radius and its exact-set audit chased new paths every run.
printf '===PODMAN-WORKS===\n'
if [ -z "${SB_PROBE_PODMAN:-}" ]; then
    echo not-probed
elif command -v podman >/dev/null 2>&1; then
    podman info --format '{{.Host.MemTotal}}' 2>&1 | tail -1
else
    echo no-podman
fi
printf '===SSH-AFTER===\n'
if command -v ssh >/dev/null 2>&1; then echo present; else echo absent; fi
printf '===COURSE-DIR===\n'
d="${CS193V_DIR:-$HOME/cs193v}"
if [ -x "$d/cs193v" ]; then echo launcher-is-executable; elif [ -d "$d" ]; then echo dir-only; else echo absent; fi
# NO `podman image exists` HERE, deliberately, and it was here for one run: any podman command
# that touches the runtime creates a store, an events log and lock files, so asking put a dozen
# paths into podman-old's exact-set audit as changes the installer had supposedly made. The one
# case that really builds asks in its own script (nest-run.sh), where a store already exists.
printf '===TRACE===\n'
sed -n 's/^+\([0-9]\{1,\}\) .*/\1/p' /var/tmp/report/trace 2>/dev/null | sort -un | tr '\n' ' '
printf '\n===END-REPORT===\n'
RUN
    chmod +x "$SB_WORK/run.sh"
}

# ─── a course tree whose LAUNCHER floor disagrees with the installer's ─────────
#
# BUILT ON DEMAND, for one case, and that case exists to prove a defect rather than to measure
# anything. The podman floor is declared TWICE -- MIN_PODMAN_LINUX in install-cs193v.sh and again
# in cs193v -- because the installer is curl-piped and cannot source the launcher. Nothing but
# 25-installer.sh's static check stops them drifting, and this is the behavioural half: what a
# student actually SEES when they do.
#
# RAISING THE LAUNCHER'S, NOT LOWERING THE INSTALLER'S, and the direction matters. Lowering the
# installer's floor would need a fixture whose podman is below it, and the only such fixture
# (podman-old, 3.4.4) has no nesting adaptations -- so the run would die at write_local_args, on
# `podman info`, long before build_image handed off to the launcher. Raising the launcher's floor
# instead reproduces the same disagreement on podman-old-nested, whose 4.9.3 the real installer
# accepts, and gets all the way to the hand-off.
#
# 5.7.0 because it is what the macOS floor is, so the number is one somebody might plausibly type
# into the wrong copy.
sb_work_skew() {                      # -> $SB_WORK/installer-skew.sh, and its tarball
    [ -f "$SB_WORK/installer-skew.sh" ] && return 0
    mkdir -p "$SB_TMP/pkg-skew"
    cp -a "$SB_TMP/pkg/cs193v-main" "$SB_TMP/pkg-skew/cs193v-main" || return 1
    edit_sub "$SB_TMP/pkg-skew/cs193v-main/cs193v" '^MIN_PODMAN_LINUX=.*' 'MIN_PODMAN_LINUX="5.7.0"'
    # ASSERTED, NOT TRUSTED. An edit_sub whose ERE matches nothing is a silent no-op, and the two
    # copies would then AGREE -- so the case would assert a refusal that never came and read as the
    # launcher having stopped checking versions. Measured the hard way once already: the constant
    # was renamed from MIN_PODMAN when the floors split per platform.
    grep -q '^MIN_PODMAN_LINUX="5.7.0"' "$SB_TMP/pkg-skew/cs193v-main/cs193v" || {
        printf 'sb_work_skew: the launcher floor was not raised -- was the constant renamed?\n' >&2
        return 1; }
    ( cd "$SB_TMP/pkg-skew" && tar czf "$SB_WORK/course-skew.tar.gz" cs193v-main ) || return 1
    # THE INSTALLER IS UNMODIFIED except for where it fetches from, which is the point: the skew is
    # entirely in the launcher's copy of the number.
    cp "$SB_WORK/installer.sh" "$SB_WORK/installer-skew.sh"
    edit_sub "$SB_WORK/installer-skew.sh" '^TARBALL=.*' 'TARBALL="file:///work/course-skew.tar.gz"'
    grep -q 'course-skew.tar.gz' "$SB_WORK/installer-skew.sh" || {
        printf 'sb_work_skew: the tarball URL was not repointed\n' >&2; return 1; }
    return 0
}

# An installer that never finishes, so the ceiling machinery can be exercised for the price of a
# container start rather than the price of a 25-step build (#130).
#
# WHY A FIXTURE INSTALLER RATHER THAN A FIXTURE GUEST. nest_build's entry command is fixed --
# `sh /work/nest-run.sh` -- and the one thing a case may substitute is which installer that script
# runs. So the hang goes where the case already has a hook, and everything before it is the real
# path: the real arrange, the real report scaffolding, the real pipeline and the real ceiling.
#
# IT PRINTS BEFORE IT SLEEPS, and that is the half the marker exists to preserve. A killed run's
# value is whatever it managed to say first, so the case can assert that the marker was APPENDED
# to a partial transcript rather than written over it.
#
# AND IT READS A KEYSTROKE FIRST, which is not decoration. nest_build's keys are argument 3 now
# that the label is argument 1, and an off-by-one there does not fail -- it feeds the installer
# nothing, menu()'s `read` waits on a pty that never delivers EOF (ERRORS.md B13), and the run
# burns its whole ceiling looking exactly like the hang this file is about. `read -rsn1` is what
# menu() itself uses, and nest-run.sh runs the installer under bash, so this reads the real path.
sb_work_hang() {                      # -> $SB_WORK/installer-hang.sh
    [ -f "$SB_WORK/installer-hang.sh" ] && return 0
    cat > "$SB_WORK/installer-hang.sh" <<'HANG'
printf 'pretending to build the course image\n'
read -rsn1 k || true
printf 'keystroke=[%s]\n' "$k"
sleep 3600
HANG
    return 0
}

# ─── the nested case's prerequisites, measured before anything rests on them ────
#
# THE GRAPH ROOT IS NOT ON A VOLUME, and that is a measured decision rather than the one this
# was designed with. The plan assumed podman refuses overlay-on-overlay and that a named
# volume was therefore required; it does not -- the outer overlay is mounted `userxattr`, so a
# graph root on the container's own writable layer gets driver=overlay and works. With no
# correctness reason left, the layer is strictly better than a volume: it is discarded with
# the container, so there is nothing to reap, nothing to leak onto a shared machine, and no
# pid-named volume for a killed run to strand.
#
# ONE CONTAINER RUN, many answers. Every probe reports KEY=value and every assertion reads a
# POSITIVE token, never an absence -- a probe that never ran must fail, not look happy.
# THE BASE IS AN ARGUMENT TO ALL FOUR OF THESE, defaulting to `machine`, so every existing call
# is unchanged. It exists because the flag set is per-base: Debian's shadow ships newuidmap with
# only a setuid bit, which does not survive nesting, while Fedora's ships file capabilities, which
# do -- so whether a base needs SYS_ADMIN is a property of its packaging and has to be measured
# per base rather than copied.
# `|| return 1` ON ALL FOUR OF THESE, and it is not defensive tidying. machine_flags clears
# MACHINE_FLAGS before it validates the drop list, so a refused call does not fail loudly -- it
# succeeds at running the fixture with NO nesting flags at all, and what you then read is a probe
# whose every token is wrong for reasons that look nothing like a typo. Returning instead leaves
# the transcript empty, and an empty transcript makes every positive token above empty, which is
# the contract this file's probe was written to.
nest_probe() {                        # nest_probe [BASE] [PODMAN_ARGS...] -> KEY=value lines
    local base="${1:-machine}"; shift 2>/dev/null || true
    # shellcheck disable=SC2086
    machine_flags '' linux no "$base" || return 1
    timeout 180 podman run --label "$VT_LABEL" --rm \
        ${MACHINE_FLAGS[@]+"${MACHINE_FLAGS[@]}"} \
        -v "$SB_WORK/nest-probe.sh:/probe.sh:ro$VT_MOUNT_Z" "$@" \
        "$(fixture_tag "$base")" sh /probe.sh 2>&1
}

# TWO DEPARTURES, ONE CONTROL EACH. Running a real podman in here needs SYS_ADMIN and
# unmask=/proc/*, and asserting only that the privileged run works would leave both requirements
# untested -- a later podman needing less, or more, would go unnoticed either way. So each
# control removes exactly one flag and the assertion says which symptom appears.
#
# Measured symptoms: without SYS_ADMIN, newuidmap cannot write uid_map. Without the unmask,
# /proc/sys is read-only and crun cannot set ping_group_range for the inner network.
#
# THE ONLY REMAINING USE OF MACHINE_CAP_INTERNAL, and the reason it exists: `unmask` is not on
# the --no-caps flag surface, because nothing masks /proc/sys on a student's machine, so denying
# it says nothing about the installer. What it says something about is this harness, and that is
# worth one assertion each.
#
# unmask=/proc/* IS NARROWER THAN THE FORBIDDEN FORM. container.args bans `unmask=ALL` for the
# course container; this is the fixture, one level out, and it names one subtree.
nest_probe_nocap() {                  # nest_probe_nocap [BASE] -- SYS_ADMIN removed, unmask kept
    local base="${1:-machine}"
    machine_flags sysadmin linux no "$base" || return 1
    timeout 180 podman run --label "$VT_LABEL" --rm \
        ${MACHINE_FLAGS[@]+"${MACHINE_FLAGS[@]}"} \
        -v "$SB_WORK/nest-probe.sh:/probe.sh:ro$VT_MOUNT_Z" \
        "$(fixture_tag "$base")" sh /probe.sh 2>&1
}

# THE THIRD DEPARTURE'S CONTROL (#119), and the one that will eventually make the flag go away.
# `label=type:container_engine_t` gets further than container_t and is refused the masked sysfs
# paths, which looks like a gap in container-selinux rather than a decision. If it is ever closed,
# or podman stops masking those paths, container_t becomes sufficient and this control STOPS
# FAILING -- which reddens the assertion that reads it, and that red means "delete the flag".
# Nothing else would notice: the flag would simply keep being passed, unexamined, for years.
# MACHINE_SYSADMIN_BASES above records what happened the last time this project narrowed a fixture
# privilege without a measurement standing behind it.
nest_probe_nolabel() {                # nest_probe_nolabel [BASE] -- the SELinux label left ON
    local base="${1:-machine}"
    machine_flags label linux no "$base" || return 1
    timeout 180 podman run --label "$VT_LABEL" --rm \
        ${MACHINE_FLAGS[@]+"${MACHINE_FLAGS[@]}"} \
        -v "$SB_WORK/nest-probe.sh:/probe.sh:ro$VT_MOUNT_Z" \
        "$(fixture_tag "$base")" sh /probe.sh 2>&1
}

nest_probe_nounmask() {               # nest_probe_nounmask [BASE] -- unmask removed, SYS_ADMIN kept
    local base="${1:-machine}"
    machine_flags unmask linux no "$base" || return 1
    timeout 180 podman run --label "$VT_LABEL" --rm \
        ${MACHINE_FLAGS[@]+"${MACHINE_FLAGS[@]}"} \
        -v "$SB_WORK/nest-probe.sh:/probe.sh:ro$VT_MOUNT_Z" \
        "$(fixture_tag "$base")" sh /probe.sh 2>&1
}

# ─── what a ceiling says when it fires, in ONE place (#130) ────────────────────
#
# A TIMEOUT HAS TO ANNOUNCE ITSELF, and this is the whole of that. Piping podman straight into
# strip_ansi threw away its exit status, so a container killed at the ceiling produced a
# transcript truncated at the hang and every assertion then failed with "expected X, flattened
# output:" -- which says the installer did not print something, not that it never ran. Measured:
# a run where three cases each burned the ceiling looked like three unrelated content failures.
#
# ONE PLACE, FOR THE REASON 10-static.sh:349 GIVES ABOUT THE FIXTURE FLAGS. sandbox_run grew this
# and nest_build never got it, so the expensive half of the suite -- a 25-step course build,
# 6.2 GB of inner store, several minutes -- was the half that explained itself least. Two copies
# of a classifier is how that happens, so there is one.
#
# THE RESULTS FILE, NOT ONLY THE TRANSCRIPT, and that is what #130 is actually about. _detail goes
# to stdout only, and half the assertions downstream read `sb_section "$out" NAME` rather than the
# transcript -- so on a killed run they compare "yes" against an empty string and the marker they
# would have carried is nowhere near them. A named result reaches run-tests.sh's FAILURES block.
#
# ON STDERR, because every call site is `out="$(sandbox_run ...)"`. A `fail` on stdout is captured
# into the transcript instead of printed, which is where sandbox_run's `record` line has been going
# all along; fd 2 is untouched by the substitution, so the line lands on the terminal in place AND
# the transcript stays exactly what the container said.
#
# FAILURE-ONLY, no paired pass. This is a harness self-check, like the two above it in
# sandbox_run, and a `pass` here would put a green line on every one of the suite's twenty-odd
# sandbox_run calls for a condition that essentially never fires.
#
# ─── WHY THE ARMS ARE SPELT 124|137, WHICH IS NOT OBVIOUS AND WAS WRONG HERE ────
#
# `timeout --kill-after` returns 137, NOT 124, whenever it has to escalate to SIGKILL. That is
# documented -- `timeout --help` lists "137 if COMMAND (or timeout itself) is sent the KILL (9)
# signal" -- and against an ATTACHED podman it is what the outer backstop always returns, because
# podman does not exit on TERM while attached: --sig-proxy forwards it to the container's process
# instead. Measured, with a real container and a 5 s backstop:
#
#   container process ignores TERM      -> rc 137, container left `Up`
#   container process would die on TERM -> rc 137, container left `Up`  <-- the surprise
#   podman hung BEFORE a container existed (a stalled pull, a storage lock) -> rc 124, no debris
#
# So the arm that was spelt 124 alone covered only the case with nothing to clean up, and the case
# its own comment was written for -- "the odd case where one does exist and conmon's ceiling did
# not fire" -- fell through silently and left the container running. conmon outlives its dead
# podman, which is what keeps it alive. Both statuses mean the same thing to a reader, so they
# share an arm, and the rc is printed rather than inferred.
#
# 255 IS PODMAN'S OWN --timeout, and it does NOT remove the container: conmon has already stopped
# it, sandbox_run is deliberately not --rm so `podman diff` can read it, and sandbox_reap collects
# it. A rm here would destroy the evidence the next assertion is about.
sb_ceiling_note() {                   # sb_ceiling_note LABEL RC CAP OUTER NAME FILE -> 1 if a ceiling fired
    case "$2" in
        255) printf '\n===SANDBOX-TIMEOUT=== podman killed the container at its %ss ceiling\n' \
                    "$3" >> "$6"
             fail "$1:the-run-stayed-inside-its-ceiling" \
                  "podman killed the container at its $3s ceiling, so the transcript stops where the run was killed" >&2
             return 1 ;;
        124|137)
             # ASKED UNCONDITIONALLY, both statuses alike. On 137 the container is live and this is
             # the only thing that ends it; on 124 there is nothing to remove and asking costs a
             # process. A ceiling that creates debris is a bad ceiling, and this is where it can.
             podman rm -f "$5" >/dev/null 2>&1 || true
             printf '\n===SANDBOX-TIMEOUT=== the OUTER backstop fired at %ss (rc %s) and podman did not\n' \
                    "$4" "$2" >> "$6"
             printf 'honour its own ceiling; any container it left was force-removed here\n' >> "$6"
             fail "$1:the-run-stayed-inside-its-ceiling" \
                  "the outer backstop fired at $4s (rc $2); any container podman left was force-removed" >&2
             return 1 ;;
    esac
    return 0
}

# The real thing: the installer end to end with a genuine `podman build` inside.
#
# NETWORK ON, unlike every other case here, and it has to be: the course image is assembled
# from seven separate origins (cs193v:1209-1213 names them), so this is the one case whose
# reliability is the internet's. It is also why --network=none and --network=pasta cannot both
# hold in one run -- pasta needs a template interface, and there is none with no network.
#
# 900 s rather than sandbox_run's 120: the installer's own measurement is a 242 s cold build
# (installer:823), and a first run also pulls the base image.
#
# BUILDAH_LAYERS=false, WHICH IS WHAT MAKES vfs AFFORDABLE. The nested store has to be vfs --
# overlay breaks the locales postinst, measured both ways -- and vfs copies a full parent tree
# per layer, so 25 committed layers cost 37 GB and still had not finished before the disk
# watchdog killed it. With layers off, buildah keeps ONE working container, so vfs copies one
# tree. The launcher passes neither --layers nor --squash, and podman documents this variable
# as the override, so it reaches the inner build without the launcher knowing.
#
# The departure to record: the image produced is single-layer rather than 25. Its CONTENTS are
# what the Containerfile says either way, and the buildhash label is still applied, so the
# launcher's staleness check is unaffected.
# KEYSTROKES AND A TTY, which this did not need until the end-to-end case existed. With no
# prereqs removed there is nothing to consent to, so `</dev/null` and no terminal were fine --
# menu() takes the safe default and there is no menu. The moment a case removes podman there are
# consent items, and the safe default for consent is DECLINING: the run would exit 0 having
# changed nothing, and "the installer finished" would fail for a reason that looks nothing like
# the cause.
# ONE NESTED BUILD AT A TIME, and the container name says nothing about the base on purpose: they
# run strictly in sequence, each one reaped before the next begins, and `podman rm -f` at the top
# collects a previous one either way. A per-base name would only matter if two ran at once, and
# two of these at once would not fit on the disk.
# A LABEL, LIKE sandbox_run'S, and it is here because the ceiling has to be able to name itself.
# Four call sites, one per block, each spelt as that block's assertion prefix -- so a killed build
# reads as `nest:the-run-stayed-inside-its-ceiling` rather than as an anonymous harness complaint
# next to eleven statements about install-cs193v.sh.
#
# THE CAP IS OVERRIDABLE, FOR THE TEST AND NOTHING ELSE. 26's ceiling case needs a ceiling it can
# actually reach without assembling the course image, and the only alternative is a case that
# costs 900 s to prove a printf. One knob drives both numbers, keeping today's 900/1000 relation
# exactly, because the pair has to stay ordered: the inner ceiling is the one a real hang should
# hit, and the outer only exists for a podman that will not honour it.
nest_build() {                        # nest_build LABEL [PREREQS] [KEYS] [BASE] [INSTALLER] -> transcript
    local name="cs193v-fixture-nested-$$" base="${4:-machine}" inst="${5:-/work/installer.sh}"
    local cap="${CS193V_NEST_CAP:-900}" outer rc
    outer=$((cap + 100))
    machine_flags '' linux no "$base" || return 1
    printf '%s' "$name" > "$SB_TMP/last-name"
    podman rm -f "$name" >/dev/null 2>&1 || true
    printf '%b' "${3:-}" | timeout --kill-after=30 "$outer" \
        podman run --timeout "$cap" --label "$VT_LABEL" -it --name "$name" \
        ${MACHINE_FLAGS[@]+"${MACHINE_FLAGS[@]}"} \
        --mount type=tmpfs,destination=/var/tmp/report \
        -e CS193V_DIR=/home/student/cs193v \
        -e BUILDAH_LAYERS=false \
        -e "SB_NO_PREREQS=${2:-}" \
        -e "SB_DISTRO=$(machine_distro "$base")" \
        -e "SB_INSTALLER=$inst" \
        -e "CS193V_COVERAGE=${CS193V_COVERAGE:-}" \
        -v "$SB_WORK:/work:ro$VT_MOUNT_Z" \
        "$(fixture_tag "$base")" \
        sh /work/nest-run.sh > "$SB_TMP/nraw" 2>&1
    # THE PIPELINE'S STATUS, READ IMMEDIATELY, and it is the whole of #130. `$?` after a pipeline
    # is the LAST member's, which is `timeout` -- what we want. There is no `set -e` and no
    # `pipefail` anywhere in the host-side tree, so the nonzero status neither aborts nor gets
    # substituted from the `printf` on the left.
    rc=$?
    grep -v 'The input device is not a TTY' "$SB_TMP/nraw" > "$SB_TMP/nraw.clean" 2>/dev/null || true
    mv -f "$SB_TMP/nraw.clean" "$SB_TMP/nraw" 2>/dev/null || true
    # WRITTEN HERE TOO, so sandbox_rc means something after a nest_build. It used to return
    # whatever the previous sandbox_run had left in the file -- a stale value that looked measured,
    # which is the same shape as the SB_SPEC inheritance sandbox_run refuses below.
    printf '%s' "$rc" > "$SB_TMP/last-rc"
    # AFTER the TTY-warning filter, so the marker cannot be caught by it, and before the trace
    # collector, so the transcript this returns is the one the marker is in.
    sb_ceiling_note "$1" "$rc" "$cap" "$outer" "$name" "$SB_TMP/nraw"
    sb_collect_trace < "$SB_TMP/nraw"
    strip_ansi < "$SB_TMP/nraw"
}

nest_get() {                          # nest_get OUTPUT KEY -> the value
    printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

# ONE keystroke per menu, and a case that gets the count wrong HANGS rather than fails: a
# pty never delivers EOF (ERRORS.md B13), so menu()'s `read` simply waits. Measured here,
# not reasoned about -- the first probe fed one key with CS193V_DIR unset, choose_dir ate it
# and ask_consent blocked until the timeout. That timeout is the only thing bounding it.
#
# ─── THE TTY COMES FROM PODMAN, NOT FROM `script` INSIDE ────────────────────────
#
# menu() needs BOTH stdin and stdout to be a terminal (installer:269), and this used to be
# arranged with `script -q -c /work/run.sh /dev/null` in the container. `podman run -t` does the
# same job -- verified rather than assumed: both fds are ttys inside, and a keystroke on a plain
# pipe still arrives (podman warns that the input device is not a tty and then forwards it
# anyway).
#
# THE REASON FOR THE CHANGE IS TWO MEASURED FAILURES, both of which looked like the installer
# hanging and neither of which was:
#
#   1. `script` STOPS DRAINING its pty master when certain children touch the tty. Ubuntu's sudo
#      defaults use_pty ON, which was enough; so was dpkg configuring a package. Once the drain
#      stops, output accumulates in the kernel's pty buffer and the writer blocks in write()
#      forever. Bisected: 400 lines after `true` come through, the same 400 after `sudo true`
#      stall at 11 bytes. This is what "the apt case hangs under bash -x, frozen at 1750 bytes"
#      was -- tracing multiplies output tenfold, so it crossed the buffer every time -- and what
#      "no-podman hangs when given SYS_ADMIN" was, since a working podman means a longer run.
#   2. podman'''s rootless PAUSE PROCESS (`catatonit -P`) outlives the installer and held the
#      container'''s pty open, so `script` never returned and a FINISHED run burned its whole
#      ceiling. With `-t` the entry command is pid 1, so the container ends when it exits.
#
# conmon drains its pty for a living, so both go away: measured at 11754 bytes of transcript
# through a real apt install and a real podman, identical with sudo'''s use_pty on or off.
sandbox_run() {                       # sandbox_run LABEL KEYS [PODMAN_ARGS...] -> transcript
    local case="$1" keys="$2"; shift 2
    # THE SPEC IS REQUIRED, and consumed. sb_machine sets it and this clears it, so a case that
    # forgets to say what machine it wants fails loudly instead of quietly inheriting the
    # previous case's -- which is the same shape as the conflation this design removes.
    if [ -z "$SB_SPEC" ]; then
        fail "sb-$case:declared-its-machine" "call sb_machine ... before sandbox_run"
        return 1
    fi
    record "sb-$case:machine" "$SB_SPEC"
    SB_SPEC=''
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
    # A TIMEOUT HAS TO ANNOUNCE ITSELF, and sb_ceiling_note above does the announcing for this
    # function and for nest_build alike -- including WHICH statuses count as a ceiling, which was
    # wrong here until #130. What stays below is the part that is this function's own: how big the
    # two ceilings are, and why there are two.
    #
    # PODMAN'S OWN --timeout IS THE CEILING, not the outer `timeout`, and that distinction is
    # the whole reason a hang here ran for 400 s instead of 60. Measured:
    #
    #   `timeout 60 podman run ...` does NOT bound an attached container. --sig-proxy defaults
    #   to true, so timeout's SIGTERM is forwarded to the container's process instead of ending
    #   podman -- and that process is bash blocked in `read -rsn1` on a pty, which defers trap
    #   handling until the builtin returns. Nothing dies, and plain `timeout` never escalates
    #   to SIGKILL. Confirmed on a bare case too: `timeout 10 podman run --rm ubuntu sleep 300`
    #   was still running minutes later.
    #
    #   `podman run --timeout 60` has conmon kill the container, so podman returns (rc 255) and
    #   --rm/reap collects it. Measured at 6 s for a 5 s ceiling.
    #
    # THE OUTER TIMEOUT COVERS WHAT --timeout STRUCTURALLY CANNOT: a podman that hangs BEFORE
    # the container exists -- a storage lock, a stalled pull -- where a container runtime limit
    # never engages. No container means no debris in that case. In the odd case where one does
    # exist and conmon's ceiling did not fire, the 124 arm below removes it by name rather than
    # leaving it for the next sweep.
    #
    # It is worth having even though a podman this broken sinks the run either way: a hang that
    # never returns is strictly worse than one that fails in 120 s and says why. That is what
    # this cost before -- 400 s of budget and three assertions failing as if their content were
    # wrong.
    #
    # 60 s because these cases take about a second; nest_build keeps 900, a real build takes
    # minutes.
    # THE CEILING HAS TO KNOW WHAT KIND OF MACHINE THIS IS, and getting that wrong reads exactly
    # like a hang. Two things move it by two orders of magnitude:
    #
    #   * a real podman rather than --fake-podman. A fake case is about a second; the default
    #     machine removes packages, runs a real offline apt install, asks a real podman for
    #     MemTotal and then lets the launcher try to build -- measured at ~100 s with the network
    #     off. At the old 60 s ceiling that looked like the transcript freezing mid-apt, because
    #     a killed run loses whatever `script` had buffered.
    #   * tracing. `bash -x` multiplies the cost of every command in a run that installs 31
    #     packages; measured at 15 s -> 61 s back when the case was smaller.
    local cap=60 outer=120 rc cov="${CS193V_COVERAGE:-}"
    [ "$SB_FAKE_PODMAN" = yes ] || { cap=300; outer=360; }
    if [ -n "$cov" ]; then cap=$((cap * 2)); outer=$((cap + 60)); fi
    # EVERY CASE IS TRACEABLE NOW, and the exclusion that used to live here is gone with its
    # cause. The apt case "hung deterministically under bash -x, frozen at 1750 bytes" because
    # Ubuntu's sudo defaults use_pty ON: sudo takes a pty of its own, `script` stops draining
    # its master until the child exits, and output past the kernel's pty buffer blocks in
    # write() forever. Tracing multiplies output about tenfold, so it crossed that buffer every
    # time. Bisected: 400 lines after `true` come through, the same 400 after `sudo true` stall
    # at 11 bytes, and `Defaults !use_pty` in the fixture restores both. So the gate no longer
    # has a case whose branches it must leave out.
    # THE LABEL STAYS ON FOR TIER A, AND THIS IS THE WHOLE OF THE SCOPING (#119). Turning it off
    # is what a NESTED podman costs, and nothing sandbox_run runs is nested: the installer either
    # dead-ends at write_local_args or reaches build_image with --network=none, where the launcher's
    # podman build dies pulling the base image -- before any RUN step, so crun is never asked to
    # create a container.
    #
    # IT IS NOT ENOUGH TO GATE ON THE BASE, which is the trap here and the reason this is a
    # separate drop rather than a condition in machine_flags. SB_BASE defaults to `machine`, which
    # IS in MACHINE_NESTED_BASES, and five of 26-installer-sandbox.sh's sb_machine calls name no
    # base at all -- so eight Tier A cases are on a nested base and would take the flag along with
    # the rest of the nesting set. One of them takes an exact-set `podman diff` audit, which has no
    # business moving because of a posture it has no use for.
    #
    # APPENDED to whatever the case asked for, not replacing it: `no-caps=sysadmin` is a real case
    # (sb-noans), and it must keep its own denial as well as this one.
    # ANNOUNCED, for the reason the timeout arms below are announced. machine_flags returns 2 on a
    # name it does not know, and it clears MACHINE_FLAGS before it validates -- so an ignored
    # refusal does not run nothing, it runs the container with NO nesting flags, and every
    # assertion then fails about the installer's output. sb_machine validates $SB_NO_CAPS long
    # before this, so this cannot fire today; it exists so that a future call site that mistypes a
    # drop name is told which of the two things went wrong.
    machine_flags "${SB_NO_CAPS:+$SB_NO_CAPS,}label" "$SB_PLATFORM" "$SB_FAKE_PODMAN" "$SB_BASE" \
        || { fail "sb-$case:the-machine-flags-were-accepted" "machine_flags refused the drop list"; return 1; }
    set -- ${MACHINE_FLAGS[@]+"${MACHINE_FLAGS[@]}"} "$@"
    printf '%b' "$keys" | timeout --kill-after=15 "$outer" \
        podman run --timeout "$cap" --label "$VT_LABEL" -it --name "$SB_NAME" \
        --network=none \
        --mount type=tmpfs,destination=/var/tmp/shim \
        --mount type=tmpfs,destination=/var/tmp/report \
        -e "CS193V_COVERAGE=$cov" \
        -e "SB_NO_PREREQS=$SB_NO_PREREQS" \
        -e "SB_DISTRO=$(machine_distro "$SB_BASE")" \
        -v "$SB_WORK:/work:ro$VT_MOUNT_Z" "$@" \
        "$(fixture_tag "$SB_BASE")" \
        /work/run.sh > "$SB_TMP/raw" 2>&1
    rc=$?
    # PODMAN'S OWN WARNING, REMOVED FROM THE TRANSCRIPT. `-t` with a pipe on stdin makes podman
    # say "The input device is not a TTY" on the same stream as the container's output, and it is
    # neither the installer's words nor a fixture's -- so it would be the one line in every
    # transcript that belongs to the harness. Filtered by its exact text, not by a level=warning
    # pattern, so a DIFFERENT podman warning still reaches whoever is reading.
    grep -v 'The input device is not a TTY' "$SB_TMP/raw" > "$SB_TMP/raw.clean" 2>/dev/null || true
    mv -f "$SB_TMP/raw.clean" "$SB_TMP/raw" 2>/dev/null || true
    printf '%s' "$rc" > "$SB_TMP/last-rc"
    sb_ceiling_note "sb-$case" "$rc" "$cap" "$outer" "$SB_NAME" "$SB_TMP/raw"
    sb_collect_trace < "$SB_TMP/raw"
    strip_ansi < "$SB_TMP/raw"
}

# The line numbers a container run reported, appended to this run's trace directory so
# 95-installer-coverage.sh can union them with the host cases'. Rewritten into the same
# "+NNN text" shape the host traces use, so the gate has one parser rather than two.
sb_collect_trace() {
    [ -n "${CS193V_RUN_DIR:-}" ] || return 0
    mkdir -p "$CS193V_RUN_DIR/trace" 2>/dev/null || return 0
    # tr -d '\r' FIRST. This reads the RAW transcript, which came through a pty, so every line
    # ends in a carriage return and /^===TRACE===$/ matched nothing -- the collected file was
    # zero bytes while the section was plainly there in the stripped output I was reading. The
    # gate then reported the producer silent, which was true and completely misleading.
    tr -d '\r' \
        | sed -n '/^===TRACE===$/,/^===/p' | sed '1d;$d' | tr ' ' '\n' | grep -E '^[0-9]+$' \
        | sed 's/^/+/;s/$/ traced-in-container/' \
        >> "$CS193V_RUN_DIR/trace/${CS193V_SUITE:-standalone}.$$" || true
}

# The exit status of the last sandbox_run, which the pipeline above would otherwise hide.
sandbox_rc() { cat "$SB_TMP/last-rc" 2>/dev/null; }

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
