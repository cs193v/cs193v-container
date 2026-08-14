# CS193V entry banner, for a login shell opened OUTSIDE tmux.
#
# The banner itself lives in /usr/local/bin/cs193v-welcome; this file only decides whether
# to run it. See that script for the text.
#
# THE $TMUX GUARD IS THE WHOLE POINT OF THIS FILE'S CURRENT SHAPE.
#
# `./cs193v` now lands the student in tmux, and tmux runs the login shell in EVERY tab. So
# a banner printed unconditionally from /etc/profile.d would clear the screen and greet
# again every single time a student pressed CTRL+T -- turning a one-time "here is where
# you are" into a recurring interruption that also wipes the pane. The first tab gets the
# banner from cs193v-shell instead, which passes `cs193v-welcome` as that window's command
# and so reaches tab one and nothing else.
#
# What is left for this file is the path that is NOT tmux:
#
#     podman exec -it cs193v bash -l
#
# which is what scripts use, what the launcher's "could not open a shell" message points
# at, and what staff use to look at a container whose tmux will not start. That path should
# still say where it is, exactly as it always did.
#
# Reattaching deliberately does NOT re-print the banner: cs193v-shell only passes the
# welcome to a session it creates, so coming back to your tabs after closing a window
# resumes rather than re-greets. "You are inside the container" is carried continuously by
# the tmux title bar now, which is a better answer than a banner that scrolls away.

# Interactive shells with a terminal only. Without this guard, `podman exec cs193v <cmd>`
# and every non-interactive call -- including the ones this project's own test suite makes --
# would get a screenful of banner mixed into their output.
case $- in
    *i*)
        if [ -t 1 ] && [ -z "${TMUX:-}" ]; then
            cs193v-welcome
        fi
        ;;
esac
