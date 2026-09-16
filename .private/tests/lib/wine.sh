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

# SC2034: this library sets WINE_OUT, WINE_ERR, WINE_RC, WINE_LNK and WINE_SKIP_WHY for its
# CALLER to read -- 27-installer-windows.sh reads them a hundred times, and WINE_SKIP_WHY is the
# skip message the caller prints when the tier declines. None of that is visible from inside the
# file, and each of them is written at three or four sites, so this is file-level for the reason
# 12-run-timeout.sh's is: shellcheck names only the last one.
# shellcheck disable=SC2034
WINE_FIXTURE=wine

WINE_SKIP_WHY=''                      # why the tier declined, for the caller's skip message
wine_require() {                      # wine_require -> 0 if this machine can run the tier
    require_podman || { WINE_SKIP_WHY="podman is unavailable"; return 1; }
    # ARCHITECTURE FIRST, BEFORE THE 2.53 GB BUILD. This used to ask only "is podman here and did
    # the fixture build" -- both true on an Apple Silicon Mac -- and then 97 of 189 assertions
    # failed inside wine rather than the tier declining. Ubuntu's wine cannot load its own PE
    # loader on aarch64:
    #
    #   wine: failed to load /usr/lib/aarch64-linux-gnu/wine/aarch64-windows/ntdll.dll
    #         error c00000bb                        (c00000bb is STATUS_NOT_SUPPORTED)
    #
    # An instruction set is not a missing dependency: nothing the operator installs fixes it, so
    # this is the one place a skip is right where the rest of the suite hard-fails. Checked here
    # rather than after the build, because building 2.53 GB to then decline is a four-minute
    # apology.
    case "$(uname -m)" in
        x86_64|amd64) ;;
        *) WINE_SKIP_WHY="wine cannot run on $(uname -m)"; return 1 ;;
    esac
    fixture_build "$WINE_FIXTURE" || {
        WINE_SKIP_WHY="the wine fixture could not be built"
        return 1
    }
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
    # WHAT THE FAKE SERVES, and it is the real thing rather than a stand-in. fake-wsl's curl arm
    # copies this to stage2.sh and its grep arm searches that, so the .cmd's sentinel check runs
    # against install-cs193v.sh's ACTUAL last line. A token invented here instead would make the
    # check tautological: the fixture would be agreeing with itself.
    #
    # There is deliberately no sibling install-cs193v.sh in the download folder any more. Stage
    # one fetches stage two by URL and never looks beside itself, and 25-installer.sh asserts
    # that %HERE%, wslpath and %TEMP% are all gone from the .cmd.
    cp "$PRIVATE/install-cs193v.sh" "$WINE_CASE/stage2.src"
    WINE_OUT=''; WINE_ERR=''; WINE_RC=''; WINE_ARGV=''; WINE_LNK=''; WINE_DIED=''
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

# ─── arranging a hostile download folder ──────────────────────────────────────
#
# Plant a copy of hostile.exe under every name the installer calls, in the folder the .cmd sits in.
# That is the shape issue #125 reports: the download folder is the installer's working directory,
# so anything already sitting there is a candidate for execution -- and Downloads is the likeliest
# place on a real machine for an untrusted file to already be. It used to run ELEVATED out of that
# folder, which is what made the report urgent; it now refuses an elevated run, so the consequence
# is the student's account rather than Administrator and the hole is otherwise unchanged.
#
# THESE ARE HARNESS ARRANGEMENTS, NOT FAKE KNOBS, and the `harness.` prefix says so. A knob
# configures how a program the installer means to call ANSWERS; these two change what exists on the
# machine before it starts, which no fake can express.
wine_plant_hijack() {                 # wine_plant_hijack
    : > "$WINE_CASE/harness.plant-hijack"
}

# "WSL is not installed at all". The fixture bakes system32\wsl.exe, and the installer asks
# `if not exist "%SYS32%\wsl.exe"`, so removing that file is the honest way to arrange it. This
# replaces the where.wsl.exe knob and fake-where.c, both retired: where.exe searched the current
# directory itself -- so its ANSWER was plantable even once the calls were qualified -- and it was
# answering a question about %PATH% that the installer no longer asks.
wine_hide_wsl() {                     # wine_hide_wsl
    : > "$WINE_CASE/harness.no-wsl-exe"
}

# ─── the icon the shortcut step copies, and why it is present by default  (#270) ─
#
# THE COPY FAILED ON EVERY CASE, which left the whole Start Menu block dead code in a tier
# reporting 213 pass 1 fail: `copy /y "\\wsl.localhost\%DISTRO%\home\student\.cs193v-icon.ico"`
# failed with `Path not found.`, the .cmd took :shortcutfailed, and nothing past that line ran.
# The one red assertion was win-ok:no-stderr-noise carrying that message, which reads as harness
# noise rather than as a block nothing entered.
#
# WINE DOES RESOLVE UNC, AND THE MAPPING IS A DIRECTORY IN THE PREFIX. Measured with
# WINEDEBUG=+file inside this fixture: `\\wsl.localhost\CS193V\home\student\.cs193v-icon.ico`
# becomes the NT path `\??\UNC\wsl.localhost\CS193V\home\student\.cs193v-icon.ico`, and `\??\`
# is built out of the prefix's own dosdevices -- so
#
#     dosdevices/unc/<host>/<share>/...   IS   \\<host>\<share>\...
#
# and creating that tree makes the .cmd's own copy line succeed with rc 0 against the path it
# really names. A symlink at dosdevices/unc works identically; a plain directory is used because
# it needs nothing outside the container's own filesystem.
#
# DO NOT BELIEVE THE OTHER ANSWER. An earlier attempt here recorded that wine collapses
# `\\host\share` onto the current drive -- `C:\wsl.localhost\...` -- and planted the icon under
# drive_c accordingly. That was an artefact of the PROBE: the .cmd it measured had lost one of
# its two leading backslashes, so wine was resolving `\wsl.localhost\...`, a drive-relative path,
# and answering a question nobody had asked. The trace for a real UNC path says `\??\UNC`. Any
# future probe here must be built from the installer's own bytes for that reason.
#
# WHAT THIS TIER STILL DOES NOT PROVE is that \\wsl.localhost resolves on WINDOWS -- that needs
# a running distribution and a real redirector, and it stays in MANUAL.md §134.3, the same line
# this file's header draws between a decision and an effect. What is now reachable is every
# decision AFTER the copy, which is all of #134's Start Menu code.
#
# PRESENT BY DEFAULT, AND THE KNOB SUBTRACTS -- install-sandbox.sh's rule, for its reason: with
# no arrangement at all a case gets the run that succeeds all the way to its last step, and
# asking for :shortcutfailed is something a case does on purpose.
#
# CS193V IS HARDCODED, matching CS193V_FAKE_DISTRO's default in fake-powershell.c. The .cmd's
# %DISTRO% is a constant and 25-installer.sh's windows:names-the-same-distro-as-the-sh is what
# keeps it one.
wine_hide_shim_icon() {               # wine_hide_shim_icon
    : > "$WINE_CASE/harness.no-shim-icon"
}

# A Start Menu entry that was ALREADY THERE before this run. Two uses, and neither can be got at
# by letting the fake --install create one: a leftover from an older install of the same
# environment, and a decoy that proves the delete's target guard is consulted rather than its
# filename alone.
#
# RELATIVE TO THE START MENU ROOT, so a case says where it means in the terms the defect is
# about: `CS193V.lnk` is the root, `Programs/CS193V.lnk` is the app list.
wine_plant_lnk() {                    # wine_plant_lnk RELPATH TARGETPATH
    printf '%s\t%s\n' "$1" "$2" >> "$WINE_CASE/harness.startmenu.tsv"
}

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
        -v "$WINE_CASE:/work:ro$VT_MOUNT_Z" \
        "$(fixture_tag "$WINE_FIXTURE")" \
        bash -c '
            set -u
            mkdir -p /tmp/xdg && chmod 700 /tmp/xdg
            mkdir -p /tmp/case && cp -r /work/. /tmp/case/ && chmod -R u+w /tmp/case
            # THE FAKES ARE ALREADY IN system32, baked into the fixture, because the installer
            # names %SYS32%\wsl.exe now. They used to be copied in HERE, beside the .cmd, and be
            # found because cmd.exe searches the current directory before PATH -- so this harness
            # depended on the very defect issue #125 reports, and qualifying the calls would have
            # left the tier executing nothing while still reporting green. NOTHING is copied
            # beside the .cmd any more, which is what makes the hijack case below mean something.
            #
            # "WSL IS NOT INSTALLED" IS NOW A MISSING FILE rather than a where.exe knob, because
            # `if not exist "%SYS32%\wsl.exe"` is the question the installer actually asks.
            if [ -f /tmp/case/harness.no-wsl-exe ]; then
                rm -f /home/ubuntu/.wine/drive_c/windows/system32/wsl.exe
            fi
            # A HOSTILE COPY IN THE DOWNLOAD FOLDER, under every name the installer calls. On the
            # unfixed installer each of these ran, as Administrator; on the fixed one nothing ever
            # looks at them. hostile.exe is never in system32, so this is the only way it can run.
            if [ -f /tmp/case/harness.plant-hijack ]; then
                for n in wsl reg where powershell; do
                    cp /home/ubuntu/shim/hostile.exe "/tmp/case/'"$WINE_DL_NAME"'/$n.exe"
                done
            fi
            # THE ICON, BEHIND THE UNC PATH THE .cmd NAMES. dosdevices/unc IS \\, so this tree
            # is literally \\wsl.localhost\CS193V\home\student. See wine_hide_shim_icon above
            # for the trace; without it the .cmd never gets past the copy.
            if [ ! -f /tmp/case/harness.no-shim-icon ]; then
                unc=/home/ubuntu/.wine/dosdevices/unc/wsl.localhost/CS193V/home/student
                mkdir -p "$unc"
                printf ICONBYTES > "$unc/.cs193v-icon.ico"
            fi
            # ENTRIES THAT WERE ALREADY THERE, written as the fakes write them so the delete
            # cannot tell a planted one from one `wsl --install` made. Relative to the root.
            sm="/home/ubuntu/.wine/drive_c/users/ubuntu/AppData/Roaming/Microsoft/Windows/Start Menu"
            if [ -f /tmp/case/harness.startmenu.tsv ]; then
                while IFS="$(printf "\t")" read -r rel tgt; do
                    [ -n "$rel" ] || continue
                    mkdir -p "$sm/$(dirname "$rel")"
                    printf "TargetPath=%s\nArguments=\nIconLocation=\n" "$tgt" > "$sm/$rel"
                done < /tmp/case/harness.startmenu.tsv
            fi
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
            # THE START MENU AS IT STANDS AFTERWARDS, which is the one channel that reports an
            # EFFECT rather than a decision. Paths are relative to the root and directories
            # carry a trailing slash, so `CS193V.lnk`, `Programs/CS193V.lnk` and
            # `Programs/CS193V/` are three distinguishable answers -- and telling the first two
            # apart is the whole of #270.
            printf "\n===LNK===\n"
            if [ -d "$sm" ]; then
                find "$sm" -mindepth 1 \( -type f -o -type d \) | LC_ALL=C sort | while IFS= read -r one; do
                    rel=${one#"$sm/"}
                    if [ -d "$one" ]; then
                        printf "%s/\t(dir)\n" "$rel"
                    else
                        printf "%s\t%s\n" "$rel" "$(sed -n "s/^TargetPath=//p" "$one" | head -1)"
                    fi
                done
            fi
            printf "\n===END===\n"
        ' > "$raw" 2>&1

    WINE_RC="$(sed -n 's/^===RC=\([0-9-]*\)===$/\1/p' "$raw" | head -1)"
    WINE_OUT="$(_wine_section "$raw" OUT)"
    WINE_ERR="$(_wine_section "$raw" ERR)"
    WINE_ARGV="$(_wine_section "$raw" ARGV)"
    WINE_LNK="$(_wine_section "$raw" LNK)"
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
        WINE_LNK="$WINE_DIED"
    fi
}

# Is there an entry at exactly this path? yes|no, relative to the Start Menu root.
#
# AN EXACT, WHOLE-LINE MATCH, which the defect makes necessary rather than tidy: `CS193V.lnk` is
# a substring of nothing here, but `Programs/CS193V.lnk` contains `CS193V.lnk` and a
# `-contains`-shaped check would answer yes for the root entry while looking at the app list one.
# grep -x on the first field is what keeps the two answers separate.
wine_lnk_has() {                      # wine_lnk_has RELPATH -> yes|no
    if [ -n "${WINE_DIED:-}" ]; then printf '%s' "$WINE_DIED"; return 0; fi
    if printf '%s\n' "$WINE_LNK" | cut -f1 | grep -qxF "$1"; then printf yes; else printf no; fi
}

# What that entry points at, or "" when there is no such entry. A case asserting on a target has
# to distinguish those two, so this deliberately does not report "absent" as a target of its own.
wine_lnk_target() {                   # wine_lnk_target RELPATH -> its TargetPath
    if [ -n "${WINE_DIED:-}" ]; then printf '%s' "$WINE_DIED"; return 0; fi
    printf '%s\n' "$WINE_LNK" | awk -F'\t' -v p="$1" '$1 == p { print $2; exit }'
}

_wine_section() {                     # _wine_section FILE NAME
    sed -n "/^===$2===\$/,/^===[A-Z]*=*[A-Z]*===\$/p" "$1" \
        | sed '1d;$d' | sed 's/\r$//'
}

wine_argv_count() {                   # wine_argv_count ERE -> how many logged calls match
    if [ -n "${WINE_DIED:-}" ]; then printf '%s' "$WINE_DIED"; return 0; fi
    printf '%s\n' "$WINE_ARGV" | grep -cE "$1" || true
}
