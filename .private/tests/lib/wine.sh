#!/usr/bin/env bash
# Driving install-cs193v-windows.cmd under wine's cmd.exe, one throwaway container per case.
#
# WHY A CONTAINER PER CASE. wine's WINEPREFIX is an entire fake C:\ with a live registry, and
# every run mutates it. Sharing one would let case N inherit case N-1's environment variables,
# drive mappings and files -- the same slow collision CS193V_INSTANCE exists to prevent. The
# prefix is baked into the fixture instead, so each container starts from an IDENTICAL C:\ and is
# then thrown away. Measured: prefix creation costs 10.6 s, a warm `wine64 cmd /c` costs 127 ms,
# which is the whole reason the prefix is baked rather than made per case.
#
# WHAT THIS REACHES, AND WHAT IT CANNOT. Every DECISION the .cmd takes, and no EFFECT -- the same
# line lib/sandbox.sh:5-16 draws for the .sh installer. Whether WSL really installs stays in
# MANUAL.md. Two things wine gets WRONG rather than merely not reaching are LF line endings and
# `::` inside a block, where it is MORE permissive than cmd.exe; those are asserted statically in
# 25-installer.sh precisely because a green run here would prove nothing about them.

WINE_FIXTURE=wine

wine_require() {                      # wine_require -> 0 if this machine can run the tier
    require_podman || return 1
    fixture_build "$WINE_FIXTURE" || return 1
}

# ─── building a case ───────────────────────────────────────────────────────────
#
# A case is a directory holding the knobs, the message table, and a subdirectory standing in for
# wherever the student downloaded the two files. The subdirectory name is a parameter because
# where a student downloads to is one of the things that breaks batch: `cs193v (1)` is what a
# browser names a second copy.
wine_new() {                          # wine_new [DOWNLOAD_DIR_NAME]
    WINE_CASE="$(mktemp -d "$WINE_TMP/case.XXXXXX")"
    WINE_DL_NAME="${1:-Downloads}"
    WINE_DL="$WINE_CASE/$WINE_DL_NAME"
    mkdir -p "$WINE_DL"
    cp "$PRIVATE/install-cs193v-windows.cmd" "$WINE_DL/"
    cp "$FIXTURE_DIR/wsl-messages.$WINE_MSG_VERSION" "$WINE_CASE/messages"
    # The sibling .sh exists by default: its ABSENCE is one specific case, not the baseline.
    : > "$WINE_DL/install-cs193v.sh"
    WINE_OUT=''; WINE_ERR=''; WINE_RC=''; WINE_ARGV=''; WINE_DIED=''
}

wine_knob() {                         # wine_knob NAME VALUE
    printf '%s\n' "$2" > "$WINE_CASE/$1"
}

# Seed the registered-distribution list. With no arguments the machine has none, which is the
# state a fresh WSL install is in -- and the state in which `wsl -l -q` exits 0 with EMPTY output
# rather than failing, which is why the installer cannot use its exit code to answer the question.
wine_list() {                         # wine_list [DISTRO...]
    : > "$WINE_CASE/wsl.list"
    for d in "$@"; do printf '%s\n' "$d" >> "$WINE_CASE/wsl.list"; done
}

wine_no_sibling() { rm -f "$WINE_DL/install-cs193v.sh"; }

# ─── running it ────────────────────────────────────────────────────────────────
wine_run() {                          # wine_run -> populates WINE_OUT / WINE_ERR / WINE_RC / WINE_ARGV
    local raw="$WINE_CASE/.report"
    # The fixture runs as a non-root user, so the container CANNOT read a 0700 mktemp directory:
    # rootless podman maps container-root to the invoking user, but not container-uid-1000.
    # (lib/sandbox.sh does not need this because its image never leaves root.) Nothing here is
    # secret -- it is a throwaway tree of knob files -- so widening it is the honest fix.
    chmod -R a+rX "$WINE_CASE"
    # --network=none: nothing here should ever reach a network, and saying so means a case that
    # starts trying to is a failure rather than a slow success.
    podman run --rm --network=none --label "$VT_LABEL" \
        -e XDG_RUNTIME_DIR=/tmp/xdg \
        -e "CS193V_FAKE_DIR=Z:\\tmp\\case" \
        -v "$WINE_CASE:/work:ro" \
        "$(fixture_tag "$WINE_FIXTURE")" \
        bash -c '
            set -u
            mkdir -p /tmp/xdg && chmod 700 /tmp/xdg
            mkdir -p /tmp/case && cp -r /work/. /tmp/case/ && chmod -R u+w /tmp/case
            # The fakes go in the SAME directory as the .cmd. cmd.exe searches the current
            # directory before PATH -- on wine and on Windows alike -- so this shadows wine own
            # net.exe and where.exe, which is not optional: wine `net session` answers with a
            # usage banner and EXIT 0, i.e. it reports every user as an Administrator.
            cp /home/ubuntu/shim/*.exe "/tmp/case/'"$WINE_DL_NAME"'/"
            # cd first and invoke by RELATIVE name. `wine64 cmd /c <path with ( or )>` fails with
            # "Can not recognize ... as an internal or external command" (WineHQ 37789), so a
            # case testing a download folder called "cs193v (1)" would fail in the HARNESS and
            # look like a defect in the installer. Measured; this is the workaround.
            cd "/tmp/case/'"$WINE_DL_NAME"'" || exit 97
            wine64 cmd /c install-cs193v-windows.cmd </dev/null >/tmp/o 2>/tmp/e
            rc=$?
            printf "===RC=%s===\n" "$rc"
            printf "===OUT===\n"; cat /tmp/o
            printf "\n===ERR===\n"; cat /tmp/e
            printf "\n===ARGV===\n"; cat /tmp/case/argv.log 2>/dev/null
            printf "\n===END===\n"
        ' > "$raw" 2>&1

    WINE_RC="$(sed -n 's/^===RC=\([0-9-]*\)===$/\1/p' "$raw" | head -1)"
    WINE_OUT="$(_wine_section "$raw" OUT)"
    WINE_ERR="$(_wine_section "$raw" ERR)"
    WINE_ARGV="$(_wine_section "$raw" ARGV)"
    # A run that produced no report at all is a harness failure, and must not look like a program
    # that simply printed nothing -- otherwise every assert_says_not in the suite passes for free.
    # A run that produced no report is a HARNESS failure and must not be able to look like a
    # program that merely printed nothing -- otherwise every assert_says_not and every count of
    # zero below passes for free. The marker travels IN THE VALUE, which is what assert.sh
    # inspects, so all four channels carry it and wine_argv_count refuses to answer at all.
    if ! grep -q '^===END===$' "$raw"; then
        WINE_DIED="$CHECKER_DIED: no report from the container; raw output follows:
$(head -20 "$raw")"
        WINE_OUT="$WINE_DIED"; WINE_ERR="$WINE_DIED"; WINE_ARGV="$WINE_DIED"; WINE_RC="$WINE_DIED"
    fi
}

_wine_section() {                     # _wine_section FILE NAME
    sed -n "/^===$2===\$/,/^===[A-Z]*=*[A-Z]*===\$/p" "$1" \
        | sed '1d;$d' | sed 's/\r$//'
}

wine_argv_count() {                   # wine_argv_count ERE -> how many logged calls match
    if [ -n "${WINE_DIED:-}" ]; then printf '%s' "$WINE_DIED"; return 0; fi
    printf '%s\n' "$WINE_ARGV" | grep -cE "$1" || true
}
