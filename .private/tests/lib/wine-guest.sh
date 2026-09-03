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
    # The fakes are ALREADY in system32, baked into the fixture, because the installer names
    # %SYS32%\wsl.exe now. They used to be copied in here, beside the .cmd, and found because
    # cmd.exe searches the current directory before PATH -- see lib/wine.sh for why that had to
    # stop, and for why nothing is dropped beside the .cmd any more (issue #125).
    if [ -f "$CASE/harness.no-wsl-exe" ]; then
        rm -f /home/ubuntu/.wine/drive_c/windows/system32/wsl.exe
    fi
    if [ -f "$CASE/harness.plant-hijack" ]; then
        for n in wsl reg where powershell; do
            cp /home/ubuntu/shim/hostile.exe "$DL/$n.exe"
        done
    fi
}

# What each fake will answer, read off the knobs rather than described from memory.
knob() {                              # knob NAME DEFAULT -> current value
    if [ -f "$CASE/$1" ]; then head -1 "$CASE/$1"; else printf '%s' "$2"; fi
}

cmd_state() {
    arrange
    printf 'What the installer is about to see\n'; hr
    printf '  download folder      %s\n' "${SB_DL:-Downloads}"
    printf '  curl in the distro   %s\n' \
        "$( [ "$(knob wsl.curl.missing 0)" = 0 ] && printf 'present' \
            || printf 'MISSING -- stage one will apt-get install it' )"
    printf '  elevated             %s\n' \
        "$( [ "$(knob reg.query.rc 0)" = 0 ] && printf 'yes' || printf "no  -- reg query exits $(knob reg.query.rc 0)" )"
    printf '  wsl.exe in System32  %s\n' \
        "$( [ -f "$CASE/harness.no-wsl-exe" ] && printf 'NO -- it will try to install WSL' || printf 'yes' )"
    printf '  planted binaries     %s\n' \
        "$( [ -f "$CASE/harness.plant-hijack" ] && printf 'YES -- hostile.exe as wsl/reg/where/powershell.exe in the download folder' || printf 'none' )"
    printf '  wsl --status         exits %s%s\n' "$(knob wsl.status.rc 0)" \
        "$( [ "$(knob wsl.status.novirt 0)" = 0 ] && printf '' \
            || printf ', and PRINTS that virtualisation is off -- on stdout, still exiting 0' )"
    printf '  using the distro     %s\n' \
        "$( [ "$(knob wsl.vm.cannotstart 0)" = 0 ] && printf 'works' \
            || printf 'EVERY `wsl -d` call fails -- no utility VM' )"
    printf '  creating the distro  %s\n' \
        "$( [ "$(knob wsl.install.novirt 0)" != 0 ] && printf 'fails at CreateVm, AFTER downloading' \
            || { [ "$(knob wsl.install.rebootrequired 0)" != 0 ] \
                 && printf 'enables a component, installs nothing, exits 0' \
                 || printf 'works'; } )"
    printf '  registered distros   %s\n' \
        "$( [ -s "$CASE/wsl.list" ] && tr '\n' ' ' < "$CASE/wsl.list" || printf '(none)' )"
    printf '  --name supported     %s\n' \
        "$( [ "$(knob wsl.name.unsupported 0)" = 0 ] && printf 'yes' || printf 'NO -- WSL older than 2.5.8' )"
    printf '  apt-get              update exits %s, install exits %s%s\n' \
        "$(knob wsl.apt.update.rc 0)" "$(knob wsl.apt.install.rc 0)" \
        "$( [ "$(knob wsl.apt.nomarker 0)" = 0 ] && printf '' \
            || printf ' -- and leaves curl STILL missing' )"
    printf '  the download         exits %s%s\n' \
        "$(knob wsl.curl.rc 0)" \
        "$( [ "$(knob wsl.curl.truncated 0)" = 0 ] && printf ', serving the whole script' \
            || printf ', serving a CUT-SHORT body: the sentinel check must refuse it' )"
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
    if grep -q "Create a default Unix user account" /tmp/last-run.txt 2>/dev/null; then
        hr
        printf 'NOTE: Ubuntu first-run setup above was REPLAYED, not answered -- the prompts are\n'
        printf '      shown with answers already filled in. On a real machine those three\n'
        printf '      questions wait for the student. Knobs: wsl.oobe 0 to skip it,\n'
        printf '      wsl.oobe.insights 0 for the 24.04 shape (two questions, not three),\n'
        printf '      wsl.oobe.user NAME to change the pre-filled username.\n'
    fi
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

  harness.no-wsl-exe 1    delete system32\wsl.exe, i.e. no WSL at all. A FILE and not a knob:
                          the installer asks `if not exist "%SYS32%\wsl.exe"`, so this is the
                          same question it asks. Replaces the old where.wsl.exe knob, retired
                          with fake-where.c -- `where` searched the current directory itself, so
                          its answer was plantable, and it asked about %PATH% rather than about
                          the file the qualified calls actually use
  harness.plant-hijack 1  put hostile.exe in the download folder as wsl.exe, reg.exe, where.exe
                          and powershell.exe. On the unfixed installer these RAN, elevated,
                          because cmd.exe searches the current directory before %PATH% (issue
                          #125). It logs HIJACKED to argv.log, so `wincmd log` shows whether any
                          of them was reached
  wsl.status.rc N         `wsl --status`. Real failures are -1, NOT 1 --
                          which is the whole reason `if errorlevel 1` was wrong
  wsl.status.msg KEY      a message key from ./messages to print with it
  wsl.update.rc N         `wsl --update`
  wsl.feature.rc N        `wsl --install --no-distribution`
  wsl.status.novirt 1     --status PRINTS that the Virtual Machine Platform is missing and
                          STILL EXITS 0. Status() ends in an unconditional `return 0`, so the
                          diagnosis is on stdout and the exit code cannot carry it -- issue
                          #112, where the .cmd sent that stdout to nul
  wsl.status.nowsl1 1     --status also prints the WSL1-unsupported line
  wsl.vm.cannotstart 1    every `wsl -d <distro>` call fails, because each one needs the utility
                          VM. This is the SECOND site issue #114 is about and the one #112's fix
                          never reached: the environment already exists, so the create is skipped
                          and the run used to arrive at :curlfailed blaming the network. Pair it
                          with wsl.status.novirt so the refusal can say virtualisation is why;
                          leave that off to see the machine whose cause is unreadable
  ps.vmfail.rc N          force the "did Windows blame virtualisation?" probe alone. It normally
                          answers from wsl.status.novirt, so use this only to make the probe
                          itself fail -- which must produce a refusal naming no cause, not a
                          refusal naming the wrong one
  ps.distro.rc N          same, for the distro probe. Use this rather than ps.rc when you
                          want ONLY that probe to fail
  wsl.name.unsupported 1  WSL older than 2.5.8: no --name, exits -1
  wsl.install.fails 1     creation refused (name already in use)
  wsl.install.novirt 1    `--install -d` downloads, installs, then fails at CreateVm with
                          HCS_E_HYPERV_NOT_INSTALLED -- the transcript in issue #112,
                          including the two lines proving the download already happened
  wsl.install.rebootrequired 1
                          `--install -d` enables a component, prints the reboot notice,
                          installs NOTHING and exits ZERO. So "it exited 0" and "the distro
                          is there" are unrelated claims
  wsl.feature.nothingmissing 1
                          `--install --no-distribution` had nothing to enable, so it reports
                          plain success rather than reboot-required
  wsl.install.rc N        the exit code of the LAUNCHED SHELL, which is what
                          `wsl --install` actually returns -- not the install's
  wsl.curl.missing 1      curl is not in the distro. Stage one installs it rather
                          than refusing -- the distro is one it created itself
  wsl.apt.update.rc N     `apt-get update` inside the distro
  wsl.apt.install.rc N    `apt-get install -y curl ca-certificates`
  wsl.apt.nomarker 1      apt exits 0 and curl is STILL absent. The nastiest shape,
                          and only the re-probe after installing catches it
  wsl.curl.rc N           the download. curl's real codes: 6 no such host, 22 an
                          HTTP error under -f, 23 could not write the file,
                          28 timed out, 56 the transfer died mid-flight
  wsl.curl.truncated 1    the download exits 0 but the body is CUT SHORT -- which is
                          what a wifi sign-in page answering 200 OK looks like from
                          the outside. install-cs193v.sh's last line is missing from
                          it, and the sentinel check is what refuses
  wsl.bash.rc N           what stage 2 (install-cs193v.sh) exits with
  ps.rc N                 force EVERY probe -- which is what powershell being missing looks
                          like, and 9009 is cmd's own not-found code. -1 = answer honestly.
                          "cannot tell" is NOT "no", and the installer has a separate arm
                          for it at each probe. To break one probe only, use ps.<name>.rc
  wsl.list                one distro name per line. Empty = a fresh WSL

  wsl.oobe 0              skip Ubuntu's first-run setup entirely
  wsl.oobe.insights 0     drop the telemetry question, i.e. the 24.04 shape.
                          The installer's text promises THREE questions on 26.04
                          and two here -- this is how you check that claim
  wsl.oobe.user NAME      the pre-filled username (real WSL fills in the Windows
                          account name, lowercased and sanitised)
  wsl.stage2.quiet 1      drop the "install-cs193v.sh runs here" boundary line

  e.g.   echo -1 > /tmp/case/wsl.status.rc && wincmd run

The messages every fake prints come from /tmp/case/messages, which is
fixtures/wsl-messages.<version> -- each line tagged with how its wording was
sourced. Nothing is invented in the fakes themselves.

What the download SERVES is /tmp/case/stage2.src, which is the real
install-cs193v.sh. The fake copies it to stage2.sh and greps that, so the
sentinel check runs against the actual script's actual last line.
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
