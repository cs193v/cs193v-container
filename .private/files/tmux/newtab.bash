# CS193V -- a new tab opens where the shell in the tab it came from is (#493).
#
# Installed as /etc/cs193v/newtab.bash and sourced from /etc/bash.bashrc, only in a shell tmux has
# marked as a new tab. Sourced, never executed: no exec bit.
#
# tmux does most of it. Every new-tab binding in tmux.conf is
#
#     new-window -e CS193V_NEW_TAB=1 -c "/proc/#{pane_pid}/cwd"
#
# #{pane_pid} is the old tab's shell, and /proc/PID/cwd is the kernel's link to that shell's
# directory -- so this shell starts in it, whatever program the old tab was running at the time.
# See the note at the bindings for why it is done that way and not with #{pane_current_path}.
#
# WHAT IS LEFT FOR THE SHELL is to work out where tmux actually put it, from the $PWD tmux handed
# over, and to land somewhere real. Four cases, all measured on tmux 3.6 in this image:
#
#   * $PWD IS THE LINK. tmux's chdir worked and it exports PWD=/proc/PID/cwd, which bash keeps
#     because it names the directory bash is in. Left alone, the prompt reads /proc/PID/cwd. So cd
#     to the real path -- read from THIS shell's own link, /proc/self/cwd, never by resolving
#     $PWD: that is the OLD tab's link, which follows that shell to wherever it has gone since.
#   * ...BUT THAT DIRECTORY WAS DELETED. The link still resolved, so tmux entered a directory that
#     no longer exists, and the kernel reports it as "PATH (deleted)" -- which cd cannot enter, so
#     the fallback below catches it with no case of its own (#518 is about doing better).
#   * $PWD IS $HOME. tmux could not enter the old directory (chmod 000, say), fell back to $HOME
#     by itself and exported that. The marker is what tells this apart from an ordinary shell in ~.
#     Fall back.
#   * $PWD IS ANYTHING ELSE. The old tab's shell had already gone when this one started, so bash
#     found its inherited $PWD dead and replaced it with the real directory itself. Stay.
#
# EVERY FALLBACK IS ~/projects, NOT ~. It is where a student lands on the way in, and the less
# alarming of the two.
#
# The marker goes first, so a bash started inside this tab does not run this again. OLDPWD goes
# too: cd has just set it to the old $PWD, which in the first case is the /proc link -- still
# following the OLD tab, so `cd -` would take the student wherever that tab happens to be by then.

unset CS193V_NEW_TAB
# The launcher's MOUNT_DST; 10-static.sh :: newtab:fallback-matches-MOUNT_DST holds it to that.
_cs193v_fallback=/home/student/projects
case "$PWD" in
    /proc/[0-9]*/cwd)
        # /proc/self is readlink's own entry, and readlink inherited this shell's directory.
        _cs193v_cwd="$(readlink /proc/self/cwd 2>/dev/null)" ;;
    "$HOME") _cs193v_cwd= ;;
    *)       _cs193v_cwd="$PWD" ;;
esac
builtin cd -- "${_cs193v_cwd:-$_cs193v_fallback}" 2>/dev/null \
    || builtin cd -- "$_cs193v_fallback" 2>/dev/null
unset _cs193v_cwd _cs193v_fallback OLDPWD
