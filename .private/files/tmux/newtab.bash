# CS193V -- a new tab opens where the shell in the tab it came from is (#493).
#
# Installed as /etc/cs193v/newtab.bash and sourced from /etc/bash.bashrc, AHEAD of tabname.bash,
# and only in a shell tmux has marked as a new tab. Sourced, never executed: no exec bit.
#
# tmux does most of it. Every new-tab binding in tmux.conf is
#
#     new-window -e CS193V_NEW_TAB=1 -c "/proc/#{pane_pid}/cwd"
#
# #{pane_pid} is the old tab's shell, and /proc/PID/cwd is the kernel's link to that shell's
# directory -- so this shell starts in it, whatever program the old tab was running at the time.
# See the note at the bindings for why it is done that way and not with #{pane_current_path}.
#
# THREE THINGS ARE LEFT FOR THE SHELL, all measured on tmux 3.6 in this image:
#
#   * $PWD. tmux exports PWD=/proc/PID/cwd, and bash keeps an inherited $PWD whenever it names the
#     directory bash is in -- which that link does. Left alone, the prompt reads /proc/PID/cwd.
#     So cd to the real path.
#   * A DELETED DIRECTORY. The link still resolves, so tmux's chdir succeeds into a directory that
#     no longer exists, and tmux's own fallback never fires. pwd -P fails there; fall back.
#   * A DIRECTORY TMUX COULD NOT ENTER (the old tab's, chmod 000). tmux falls back to $HOME by
#     itself and exports PWD=$HOME, which looks exactly like a tab really opened from ~ -- except
#     that the marker is set and $PWD is not the link. That case is what the marker is for.
#
# EVERY FALLBACK IS ~/projects, NOT ~. It is where a student lands on the way in, and the less
# alarming of the two.
#
# The marker goes first, so a bash started inside this tab does not run this again. OLDPWD goes
# too: cd has just set it to /proc/PID/cwd, which still follows the OLD tab, so `cd -` would take
# the student wherever that tab happens to be by then.

unset CS193V_NEW_TAB
# The launcher's MOUNT_DST; 10-static.sh :: newtab:fallback-matches-MOUNT_DST holds it to that.
_cs193v_fallback=/home/student/projects
case "$PWD" in
    /proc/[0-9]*/cwd) _cs193v_cwd="$(builtin pwd -P 2>/dev/null)" ;;
    *)                _cs193v_cwd= ;;
esac
builtin cd -- "${_cs193v_cwd:-$_cs193v_fallback}" 2>/dev/null \
    || builtin cd -- "$_cs193v_fallback" 2>/dev/null
unset _cs193v_cwd _cs193v_fallback OLDPWD
