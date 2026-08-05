# CS193V entry banner: clear the screen, then say unmistakably where you are.
#
# WHY THE TEXT IS HARD-CODED HERE and not in messages.txt, unlike every other
# student-facing string in this project: this runs INSIDE the container, and the container
# cannot see messages.txt. Only projects/ is bind-mounted, and messages.txt sits outside it
# next to the launcher. Moving this text to messages.txt would silently blank the banner.
#
# WHAT WAS TRIED AND REJECTED, so it is not re-proposed (see issue #4):
#
#   A persistent frame around the terminal. Not achievable without a pty multiplexer.
#   DECSTBM reserves rows only, never columns; DECSLRM is xterm-only in practice. A sticky
#   top header via DECSTBM does work, but measured against real VTE it DESTROYS SCROLLBACK
#   -- 40 lines of output, only 10 retained -- because lines scrolled out of a partial
#   scrolling region are discarded rather than saved. tmux was rejected for the same class
#   of cost (it breaks the terminal's own scrollback and needs Shift to select text).
#
#   Changing the background colour. Ptyxis, the default terminal on Ubuntu 26.04, accepts
#   OSC 11 and answers the query with the new value, then paints its own palette background
#   anyway -- so nothing changes visually and the failure CANNOT be feature-detected. macOS
#   Terminal.app does not support OSC 11 at all. It would have been invisible on the default
#   terminal of two of three target platforms.
#
# What is left is portable, needs no feature detection, and survives nano: this banner, the
# window title (set from ~/.bashrc), and the hostname in the prompt.

# Interactive shells with a terminal only. Without this guard, `podman exec cs193v <cmd>`
# and every non-interactive call -- including the ones this project's own test suite makes --
# would get a screenful of banner mixed into their output.
case $- in
    *i*)
        if [ -t 1 ]; then
            # 2J clears the visible screen; 3J clears the SCROLLBACK as well, which is what
            # "prior commands are no longer visible" actually requires. Deliberate, and not
            # undoable -- entering the container is meant to be a clean break.
            printf '\033[2J\033[3J\033[H'

            _cs193v_title='CS193V Development Environment'
            # tput needs terminfo for $TERM; the launcher forwards only a whitelisted TERM,
            # but fall back anyway rather than drawing a broken box.
            _cs193v_cols="$(tput cols 2>/dev/null || echo 0)"
            [ "$_cs193v_cols" -ge 40 ] 2>/dev/null || _cs193v_cols=64
            [ "$_cs193v_cols" -gt 72 ] && _cs193v_cols=72
            _cs193v_inner=$(( _cs193v_cols - 4 ))
            _cs193v_pad=$(( (_cs193v_inner - 31) / 2 ))
            [ "$_cs193v_pad" -lt 0 ] && _cs193v_pad=0

            _cs193v_rule=''
            _cs193v_i=0
            while [ "$_cs193v_i" -lt "$_cs193v_inner" ]; do
                _cs193v_rule="$_cs193v_rule═"
                _cs193v_i=$(( _cs193v_i + 1 ))
            done

            printf '\n  \033[1m╔%s╗\033[0m\n' "$_cs193v_rule"
            printf '  \033[1m║\033[0m%*s\033[1m%s\033[0m%*s\033[1m║\033[0m\n' \
                "$_cs193v_pad" "" "$_cs193v_title" \
                "$(( _cs193v_inner - _cs193v_pad - 31 ))" ""
            printf '  \033[1m╚%s╝\033[0m\n' "$_cs193v_rule"
            printf '\n  Welcome to the CS193V Development Environment!\n\n'
            printf '  \033[2mYour files are in ~/projects. Run `ports` if a server is not\n'
            printf '  reachable, or `am-i-in-a-container` to see this setup again.\033[0m\n\n'

            unset _cs193v_title _cs193v_cols _cs193v_inner _cs193v_pad _cs193v_rule _cs193v_i
        fi
        ;;
esac
