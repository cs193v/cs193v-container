#!/usr/bin/env bash
#
# `sandbox` -- the command you have inside tests/install-sandbox.sh. Bind-mounted to
# /usr/local/bin/sandbox, so it is on PATH the moment you land.
#
# It exists because "drop me in a container with the installer" is only half of what makes
# driving it by hand useful. The other half is being able to see what the installer is looking
# at BEFORE you run it, and what it changed AFTER -- otherwise a mistyped flag reads as an
# installer branch, which is a wrong conclusion that outlives the session.
#
# MUST STAY BASH 3.2 COMPATIBLE, like everything else under tests/.

set -u

INST=/work/installer.sh
REP=/var/tmp/report
BASE="$REP/baseline"
LINES="$REP/lines"

have() { command -v "$1" >/dev/null 2>&1; }
hr() { printf '%s\n' '---------------------------------------------------------------'; }

# BEFORE the baseline, and once. The suite arranges wsl.conf in its own run.sh, which the
# interactive path never executes -- so --wslconf did nothing here until this existed, and
# `sandbox state` said "absent" while the flag said otherwise. That is precisely the
# mistyped-flag-looks-like-a-branch failure this tool is supposed to prevent, so it is arranged
# first and the baseline is taken over the arranged state: `diff` then shows what the INSTALLER
# did, not what the fixture was set up to be.
arrange() {
    [ -n "${SB_WSLCONF:-}" ] || return 0
    [ -f "$REP/arranged" ] && return 0
    mkdir -p "$REP"
    case "$SB_WSLCONF" in
        absent)  sudo -n rm -f /etc/wsl.conf ;;
        noboot)  printf '[automount]\nenabled=true\n' | sudo -n tee /etc/wsl.conf >/dev/null ;;
        boot)    printf '[boot]\n'                     | sudo -n tee /etc/wsl.conf >/dev/null ;;
        systemd) printf '[boot]\nsystemd=true\n'       | sudo -n tee /etc/wsl.conf >/dev/null ;;
        *) printf 'sandbox: unknown SB_WSLCONF=%s\n' "$SB_WSLCONF" >&2; return 1 ;;
    esac
    printf '%s\n' "$SB_WSLCONF" > "$REP/arranged"
}

# The sudo policy, which is the difference between watching the installer and watching what a
# STUDENT watches. The fixture ships passwordless sudo so the suite can run unattended; a real
# machine prompts, and the installer announces that in its consent text ("needs your password")
# before it happens. Whether that announcement lands before the prompt, and reads sensibly when
# it does, is a judgement only a person can make -- so it has to be reachable.
#
# APPLIED LAST in init, after arrange, link_installer and snapshot: every one of those needs
# sudo, and deny/absent take it away.
SUDOERS=/etc/sudoers.d/student
apply_sudo() {
    [ -n "${SB_SUDO:-}" ] || return 0
    [ -f "$REP/sudo-applied" ] && return 0
    mkdir -p "$REP"
    pw="${SB_SUDO#password:}"
    [ "$pw" = "${SB_SUDO}" ] && pw=student      # bare `password` -> a default worth printing
    case "${SB_SUDO%%:*}" in
        nopasswd) : ;;
        password)
            printf 'student:%s\n' "$pw" | sudo -n chpasswd
            printf 'student ALL=(ALL) ALL\n' | sudo -n tee "$SUDOERS" >/dev/null
            sudo -n chmod 0440 "$SUDOERS"
            sudo -n -K 2>/dev/null || true      # drop any cached credential, or the first
            sudo -K  2>/dev/null || true        # sudo would sail through without prompting
            printf '%s\n' "password:$pw" > "$REP/sudo-applied" ;;
        deny)
            # sudo exists, student is not allowed to use it: a different transcript from absent,
            # above the same installer failure.
            sudo -n rm -f "$SUDOERS"
            printf 'deny\n' > "$REP/sudo-applied" ;;
        absent)
            # /usr/bin/sudo is an alternatives symlink to sudo.ws; moving it is enough for
            # `command -v sudo` to fail, which is what the installer's own checks look at.
            sudo -n mv /usr/bin/sudo /usr/bin/sudo.hidden-by-sandbox 2>/dev/null || true
            printf 'absent\n' > "$REP/sudo-applied" ;;
        *) printf 'sandbox: unknown SB_SUDO=%s\n' "$SB_SUDO" >&2; return 1 ;;
    esac
}

sudo_state() {
    if [ -f "$REP/sudo-applied" ]; then cat "$REP/sudo-applied"
    elif ! command -v sudo >/dev/null 2>&1; then printf 'absent'
    elif sudo -n true 2>/dev/null; then printf 'passwordless'
    else printf 'needs a password'
    fi
}

# THE INSTALLER WHERE A STUDENT WOULD HAVE IT. It is bind-mounted read-only at
# /work/installer.sh, and landing in $HOME with nothing visible is both unhelpful and
# unfaithful: a student downloads install-cs193v.sh into a directory and runs
# `bash install-cs193v.sh` from there. A SYMLINK rather than a copy, so editing
# .private/install-cs193v.sh on the host still reaches this run with no rebuild.
link_installer() {
    [ -e "$HOME/install-cs193v.sh" ] && return 0
    ln -sf /work/installer.sh "$HOME/install-cs193v.sh" 2>/dev/null || true
}

# Taken once, on the first command that needs it, so `state` before anything is still a true
# before-picture. Copies rather than checksums: `reset` has to be able to put them back.
snapshot() {
    [ -d "$BASE" ] && return 0
    mkdir -p "$BASE/etc"
    # sudo for the ones only root can read -- /etc/shadow is 0640 root:shadow, and usermod
    # rewrites it, so a reset that could not restore it would be lying about what it undid.
    for f in subuid subgid passwd shadow group wsl.conf locale.conf; do
        [ -f "/etc/$f" ] || continue
        if [ -r "/etc/$f" ]; then cp "/etc/$f" "$BASE/etc/$f"
        else sudo -n cp "/etc/$f" "$BASE/etc/$f" 2>/dev/null && sudo -n chown "$(id -u)" "$BASE/etc/$f" 2>/dev/null
        fi
    done
    find /etc -maxdepth 1 -mindepth 1 -printf '%f\n' > "$BASE/etc-list" 2>/dev/null
    : > "$BASE/taken"
}

podman_kind() {
    if ! have podman; then printf 'absent'; return; fi
    if grep -ql 'CS193V_SHIM' "$(command -v podman)" 2>/dev/null; then
        printf 'FAKE (lib/podman-fake)'
    else
        printf 'real, %s' "$(podman --version 2>/dev/null | awk '{print $NF}')"
    fi
}

cmd_state() {
    snapshot
    printf 'The machine, as install-cs193v.sh will see it\n'; hr
    printf '  %-22s %s\n' 'podman'        "$(podman_kind)"
    printf '  %-22s %s\n' 'ssh'           "$(have ssh && echo present || echo ABSENT)"
    printf '  %-22s %s\n' 'ssh-keygen'    "$(have ssh-keygen && echo present || echo ABSENT)"
    printf '  %-22s %s\n' 'sudo'          "$(sudo_state)"
    printf '  %-22s %s\n' 'curl'          "$(have curl && echo present || echo ABSENT)"
    printf '  %-22s %s:%s\n' 'you are'    "$(id -u)" "$(id -un)"
    printf '  %-22s %s\n' 'uname -s -m'   "$(uname -s) $(uname -m)"
    printf '  %-22s %s\n' 'platform()'    "$(grep -qi microsoft /proc/version 2>/dev/null && echo wsl || echo linux)"
    printf '  %-22s %s\n' 'your subuid'   "$(grep "^$(id -un):" /etc/subuid 2>/dev/null || echo 'NONE -- so DO_SUBUID is yes')"
    printf '  %-22s %s\n' 'CS193V_DIR'    "${CS193V_DIR:-<unset -- choose_dir will ask>}"
    [ -f "$REP/arranged" ] && printf '  %-22s %s\n' 'wsl.conf arranged as' "$(cat "$REP/arranged")"
    printf '  %-22s %s\n' 'stdin is a tty' "$( [ -t 0 ] && echo yes || echo 'no -- menus take the safe default')"
    if [ -f /etc/wsl.conf ]; then
        printf '  %-22s\n' '/etc/wsl.conf:'
        sed 's/^/      /' /etc/wsl.conf
    else
        printf '  %-22s %s\n' '/etc/wsl.conf' 'absent'
    fi
    printf '  %-22s %s\n' 'podman MemTotal' "$(have podman && podman info --format '{{.Host.MemTotal}}' 2>/dev/null)"
    case "$(podman_kind)" in
        real*) printf '  %-22s %s\n' 'podman store' \
                      "$(podman info --format '{{.Store.GraphRoot}} ({{.Store.GraphDriverName}})' 2>/dev/null)" ;;
        FAKE*) printf '  %-22s %s\n' 'podman store' 'n/a -- the fake answers whatever it is asked' ;;
    esac
    hr
    printf 'Read this before you run, and a mistyped flag cannot look like an installer branch.\n'
}

cmd_run() {
    snapshot
    trace=no
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --trace) trace=yes ;;
            *) printf 'sandbox run: unknown option %s\n' "$1" >&2; return 2 ;;
        esac
        shift
    done
    if [ "$trace" = yes ]; then
        # PS4 carries the line number and the trace goes to fd 9, so the installer's own
        # output stays readable. Accumulated across runs, which is what makes `lines --missing`
        # a to-do list rather than one run's snapshot.
        exec 9>>"$REP/trace"
        PS4='+${LINENO} ' BASH_XTRACEFD=9 bash -x "$INST"
        rc=$?
        exec 9>&-
        sed -n 's/^+\([0-9]\{1,\}\) .*/\1/p' "$REP/trace" | sort -un >> "$LINES.raw" 2>/dev/null
        sort -un "$LINES.raw" > "$LINES" 2>/dev/null
        printf '\n[sandbox] traced; %s of the installer'"'"'s lines seen so far. `sandbox lines --missing`\n' \
               "$(grep -c . "$LINES" 2>/dev/null || echo 0)"
        return "$rc"
    fi
    bash "$INST"
}

# The executable lines, by the same conservative rule the coverage gate uses: not blank, not a
# comment, and not a bare block terminator. It is an approximation and says so.
executable_lines() {
    grep -n '' "$INST" \
      | sed -n 's/^\([0-9]\{1,\}\):[[:space:]]*\([^[:space:]].*\)$/\1 \2/p' \
      | grep -vE ' (#|fi$|esac$|done$|else$|\}$|\{$)' \
      | awk '{print $1}'
}

cmd_lines() {
    if [ ! -s "$LINES" ]; then
        printf 'Nothing traced yet. Run `sandbox run --trace` first.\n'; return 1
    fi
    total="$(executable_lines | grep -c .)"
    seen="$(grep -c . "$LINES")"
    case "${1:-}" in
        --missing)
            printf 'Executable lines of install-cs193v.sh not yet reached (%s of ~%s seen):\n' "$seen" "$total"
            executable_lines | grep -vxF -f "$LINES" | tr '\n' ' ' | fold -s -w 70
            printf '\n\nOpen the installer at those lines to see which branch each one is.\n' ;;
        '') printf 'seen %s of ~%s executable lines. --missing lists the rest.\n' "$seen" "$total" ;;
        *)  printf 'sandbox lines: unknown option %s\n' "$1" >&2; return 2 ;;
    esac
}

cmd_diff() {
    if [ ! -d "$BASE" ]; then printf 'No baseline: run `sandbox state` or `sandbox run` first.\n'; return 1; fi
    printf 'What has changed since this container booted\n'; hr
    for f in subuid subgid passwd shadow group wsl.conf locale.conf; do
        # NOT SHOWN, for the ones only root can read: /etc/shadow is password hashes, and a
        # diff of it does not belong on anybody's terminal. Compared through sudo so the
        # CHANGED verdict is still real -- without that, an unreadable file compares unequal
        # every time and the report cries wolf on every run.
        if [ -f "/etc/$f" ] && [ ! -r "/etc/$f" ]; then
            if [ -f "$BASE/etc/$f" ] && sudo -n cmp -s "$BASE/etc/$f" "/etc/$f" 2>/dev/null; then :
            else printf '  /etc/%s  CHANGED (contents not shown)\n' "$f"; fi
            continue
        fi
        if [ -f "$BASE/etc/$f" ] && [ -f "/etc/$f" ]; then
            if ! cmp -s "$BASE/etc/$f" "/etc/$f"; then
                printf '  /etc/%s:\n' "$f"; diff "$BASE/etc/$f" "/etc/$f" | sed 's/^/      /'
            fi
        elif [ -f "/etc/$f" ]; then
            printf '  /etc/%s  CREATED:\n' "$f"; sed 's/^/      /' "/etc/$f"
        elif [ -f "$BASE/etc/$f" ]; then
            printf '  /etc/%s  REMOVED\n' "$f"
        fi
    done
    newetc="$(find /etc -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null \
              | grep -vxF -f "$BASE/etc-list" 2>/dev/null || true)"
    [ -n "$newetc" ] && { printf '  new under /etc: %s\n' "$(printf '%s' "$newetc" | tr '\n' ' ')"; }
    d="${CS193V_DIR:-$HOME/cs193v}"
    if [ -d "$d" ]; then
        printf '  %s exists: %s files\n' "$d" "$(find "$d" -type f 2>/dev/null | grep -c .)"
        [ -x "$d/cs193v" ] && printf '  %s/cs193v is executable\n' "$d"
    else
        printf '  %s does not exist\n' "$d"
    fi
    hr
    printf 'This is CONTENT. For the exact path list, from the host:  podman diff <container>\n'
}

cmd_reset() {
    if [ ! -d "$BASE" ]; then printf 'No baseline to restore.\n'; return 1; fi
    # SAID UP FRONT, because a reset that could not write /etc and did not mention it would be
    # the same lie as one that claimed to undo packages.
    if ! sudo -n true 2>/dev/null; then
        printf 'sudo is %s here, so /etc cannot be restored.\n' "$(sudo_state)"
        printf 'Leave and come back for a clean machine.\n'
        return 1
    fi
    for f in subuid subgid passwd shadow group wsl.conf locale.conf; do
        if [ -f "$BASE/etc/$f" ]; then sudo cp "$BASE/etc/$f" "/etc/$f"
        elif [ -f "/etc/$f" ]; then sudo rm -f "/etc/$f"; fi
    done
    rm -rf "${CS193V_DIR:-$HOME/cs193v}"
    : > "$REP/trace"; : > "$LINES"; : > "$LINES.raw"
    printf 'Restored /etc, removed the course directory, cleared the trace.\n'
    # SAID PLAINLY, because a reset that overstated itself would turn every second run into a
    # false first run. Packages are the part this cannot undo.
    printf 'NOT undone: anything apt installed. Leave and come back for a truly clean machine.\n'
}

cmd_knobs() {
    cat <<EOF
sandbox -- driving install-cs193v.sh by hand

  sandbox state              the machine as the installer will see it.  Read this first
  sandbox run                run the installer
  sandbox run --trace        the same, recording which of its lines executed
  sandbox lines --missing    which executable lines you have not reached yet
  sandbox diff               what changed since boot, by CONTENT
  sandbox reset              put /etc back, remove the course directory, clear the trace
  sandbox knobs              this

The installer is at $INST and the course files come from a local tarball, so editing
.private/install-cs193v.sh on your own machine and re-running needs no rebuild.

Two things worth knowing before you start:
  * With no tty, menu() takes the safe default -- which for consent means DECLINING. If you
    want to see the arrow-key menu, you already have a tty here, so just run it.
  * CS193V_DIR is ${CS193V_DIR:+set to $CS193V_DIR}${CS193V_DIR:-unset, so choose_dir will ask you where to put things}.
EOF
}

arrange || exit 1
link_installer

# init IS RUN BEFORE YOU LAND, by install-sandbox.sh. Doing this lazily on the first `sandbox`
# call was wrong twice over: the installer symlink was not there when you arrived and looked
# for it, and the wsl.conf arrangement plus the baseline could be taken AFTER you had already
# run the installer by hand -- so `diff` would have shown nothing and been believed.
if [ "${1:-}" = init ]; then
    arrange || exit 1
    link_installer
    snapshot
    apply_sudo || exit 1
    exit 0
fi

case "${1:-knobs}" in
    state) cmd_state ;;
    run)   shift; cmd_run "$@" ;;
    lines) shift; cmd_lines "${1:-}" ;;
    diff)  cmd_diff ;;
    reset) cmd_reset ;;
    knobs|-h|--help) cmd_knobs ;;
    *) printf 'sandbox: unknown command %s\n\n' "$1" >&2; cmd_knobs >&2; exit 2 ;;
esac
