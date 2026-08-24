#!/usr/bin/env bash
#
# `wincmd` -- the command you have inside tests/win-sandbox.sh. Bind-mounted to
# /usr/local/bin/wincmd, so it is on PATH the moment you land.
#
# Driving install-cs193v-windows.cmd by hand needs two things the suite does not give you:
# seeing what the fakes are about to answer BEFORE you run, and seeing what the .cmd actually
# CALLED afterwards. Without the first, a mistyped knob reads as an installer branch -- a wrong
# conclusion that outlives the session. Without the second you are guessing from prose.
#
# MUST STAY BASH 3.2 COMPATIBLE, like everything else under tests/.

set -u

CASE=/tmp/case
DL="$CASE/${SB_DL:-Downloads}"
CMDFILE="$DL/install-cs193v-windows.cmd"

hr() { printf '%s\n' '---------------------------------------------------------------'; }

# ─── arranging the machine: the ONE implementation ─────────────────────────────
#
# The knobs arrive read-only at /work because a bind mount the container could write would let a
# hand-driven session mutate the tree the next one starts from. Copied here instead, so every
# `wincmd run` starts from the shape you asked for on the command line.
arrange() {
    [ -d "$CASE" ] && return 0
    mkdir -p /tmp/xdg && chmod 700 /tmp/xdg
    mkdir -p "$CASE" && cp -r /work/. "$CASE/" && chmod -R u+w "$CASE"
    # The fakes go in the SAME directory as the .cmd. cmd.exe searches the current directory
    # before PATH -- on wine and on Windows alike -- and that is not a convenience: wine ships
    # its own net.exe, which answers `net session` with a usage banner and EXIT 0, i.e. it
    # reports every user as an Administrator. Being found first is the whole point.
    cp /home/ubuntu/shim/*.exe "$DL/" 2>/dev/null || true
}

# What each fake will answer, read off the knobs rather than described from memory.
knob() {                              # knob NAME DEFAULT -> current value
    if [ -f "$CASE/$1" ]; then head -1 "$CASE/$1"; else printf '%s' "$2"; fi
}

cmd_state() {
    arrange
    printf 'What the installer is about to see\n'; hr
    printf '  download folder      %s\n' "${SB_DL:-Downloads}"
    printf '  install-cs193v.sh    %s\n' \
        "$( [ -f "$DL/install-cs193v.sh" ] && printf 'present (the sibling it hands off to)' || printf 'ABSENT -- it will refuse' )"
    printf '  elevated             %s\n' \
        "$( [ "$(knob reg.query.rc 0)" = 0 ] && printf 'yes' || printf "no  -- reg query exits $(knob reg.query.rc 0)" )"
    printf '  wsl.exe on PATH      %s\n' \
        "$( [ "$(knob where.wsl.exe 1)" = 0 ] && printf 'NO -- it will try to install WSL' || printf 'yes' )"
    printf '  wsl --status         exits %s\n' "$(knob wsl.status.rc 0)"
    printf '  registered distros   %s\n' \
        "$( [ -s "$CASE/wsl.list" ] && tr '\n' ' ' < "$CASE/wsl.list" || printf '(none)' )"
    printf '  --name supported     %s\n' \
        "$( [ "$(knob wsl.name.unsupported 0)" = 0 ] && printf 'yes' || printf 'NO -- WSL older than 2.5.8' )"
    printf '  wslpath              %s\n' \
        "$( [ "$(knob wsl.wslpath.rc 0)" = 0 ] && printf "answers: $(knob wsl.wslpath.out '/mnt/c/Users/student/Downloads/install-cs193v.sh')" || printf "FAILS, exit $(knob wsl.wslpath.rc 0)" )"
    printf '  stage 2 (the .sh)    exits %s\n' "$(knob wsl.bash.rc 0)"
    printf '  distro probe         %s\n' \
        "$( [ "$(knob ps.rc -1)" = -1 ] && printf 'answers honestly from the distro list' || printf "FORCED to exit $(knob ps.rc -1)" )"
    hr
    printf 'wincmd run   to run it.   wincmd knobs   for everything you can change.\n'
}

cmd_run() {
    arrange
    : > "$CASE/argv.log"
    printf 'Running install-cs193v-windows.cmd under wine cmd.exe\n'; hr
    # cd first and invoke by RELATIVE name. `wine64 cmd /c <path containing ( or )>` fails with
    # "Can not recognize ... as an internal or external command" (WineHQ 37789), so driving a
    # download folder called "cs193v (1)" from an absolute path would fail in the HARNESS and
    # look like a defect in the installer.
    ( cd "$DL" && CS193V_FAKE_DIR='Z:\tmp\case' wine64 cmd /c install-cs193v-windows.cmd </dev/null 2>&1 ) \
        | tee /tmp/last-run.txt
    rc=${PIPESTATUS[0]}
    hr
    printf 'exit code: %s\n' "$rc"
    # SAID OUT LOUD, because otherwise it reads as an installer defect. wine cannot run `for /f`
    # command capture at all -- it shells out via a nested `CMD.EXE /C` that never launches -- so
    # any version of the .cmd that uses a backtick capture dies here for a reason that has
    # nothing to do with Windows. You will see this with --rev on anything before the rewrite.
    if grep -q "CMD.EXE /C" /tmp/last-run.txt 2>/dev/null; then
        hr
        printf 'NOTE: the "Can not recognize CMD.EXE /C ..." lines above are WINE, not the\n'
        printf '      installer. wine cannot execute a `for /f` backtick capture; the nested\n'
        printf '      cmd it spawns never launches. On real Windows that line works. This is\n'
        printf '      why the rewrite redirects to a file instead -- which also recovers the\n'
        printf '      exit code a backtick throws away.\n'
    fi
    printf 'wincmd log   for what it actually called.\n'
    return 0
}

cmd_log() {
    if [ ! -s "$CASE/argv.log" ]; then printf 'Nothing called yet: run `wincmd run` first.\n'; return 1; fi
    printf 'What the .cmd actually invoked, in order\n'; hr
    tr -d '\r' < "$CASE/argv.log" | sed 's/^/  /'
}

cmd_knobs() {
    arrange
    cat <<'EOF'
Everything you can change, by writing a file into /tmp/case
---------------------------------------------------------------
  reg.query.rc N          elevation probe exit code. 0 = Administrator
  where.wsl.exe 0         make `where wsl.exe` fail, i.e. no WSL at all
  wsl.status.rc N         `wsl --status`. Real failures are -1, NOT 1 --
                          which is the whole reason `if errorlevel 1` was wrong
  wsl.status.msg KEY      a message key from ./messages to print with it
  wsl.update.rc N         `wsl --update`
  wsl.feature.rc N        `wsl --install --no-distribution`
  wsl.name.unsupported 1  WSL older than 2.5.8: no --name, exits -1
  wsl.install.fails 1     creation refused (name already in use)
  wsl.install.rc N        the exit code of the LAUNCHED SHELL, which is what
                          `wsl --install` actually returns -- not the install's
  wsl.wslpath.rc N        wslpath fails. Its error goes to STDOUT, like the real one
  wsl.wslpath.out TEXT    what wslpath answers. Try a non-path to watch the guard
  wsl.bash.rc N           what stage 2 (install-cs193v.sh) exits with
  ps.rc N                 force the distro probe. -1 = answer honestly.
                          9009 = powershell missing, which is "cannot tell",
                          NOT "absent" -- the installer has a separate arm for it
  wsl.list                one distro name per line. Empty = a fresh WSL

  e.g.   echo -1 > /tmp/case/wsl.status.rc && wincmd run

The messages every fake prints come from /tmp/case/messages, which is
fixtures/wsl-messages.<version> -- each line tagged with how its wording was
sourced. Nothing is invented in the fakes themselves.
EOF
}

case "${1:-knobs}" in
    # Called by win-sandbox.sh before you get a prompt, so the tree exists and the fakes are in
    # place on your first command rather than after it.
    init)  arrange || exit 1 ;;
    state) cmd_state ;;
    run)   shift; cmd_run "$@" ;;
    log)   cmd_log ;;
    knobs) cmd_knobs ;;
    cmd)   arrange; ( cd "$DL" && CS193V_FAKE_DIR='Z:\tmp\case' exec wine64 cmd ) ;;
    -h|--help|help) cmd_knobs ;;
    *) printf 'wincmd: unknown command %s   (state|run|log|knobs|cmd)\n' "$1" >&2; exit 2 ;;
esac
