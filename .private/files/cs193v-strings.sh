# CS193V — the strings the container prints, defined once.
#
# Installed as /etc/cs193v/strings.sh and sourced by cs193v-welcome and cs193v-goodbye.
#
# WHY THIS FILE EXISTS. These strings had been written out twice: once in the script that
# prints them, and again as a literal inside each test that checks for them — across
# 10-static.sh, 50-image.sh and 60-container.sh. That is the brittle arrangement where
# rewording the greeting turns three tests red in three different tiers, none of which is
# actually a regression, and the usual response to which is to weaken the tests rather than
# fix them. Now the script and the tests read the same definition, so a reworded string
# stays green and a DELETED string still fails, which is the distinction worth keeping.
#
# It is a plain `NAME='value'` file with no logic in it on purpose: the tests source it on
# the HOST, straight out of .private/files/, without a container anywhere in the picture.
# Keep it that way — anything conditional here would have to be true on both sides.
#
# This does NOT change the rule that container-side prose lives in the image and host-side
# prose lives in messages.txt. This file is part of the image; the container still cannot
# see messages.txt, and 10-static.sh still asserts the banner text is absent from it.

# The name of the environment. Appears in the tmux title bar across the top of the terminal,
# and in the host terminal's window title.
#
# Nothing that RUNS reads this: tmux.conf and rewrite-window-title.py both carry the literal,
# because neither can source a shell file. So this is the one definition the tests check those
# two copies against, which is what keeps them from drifting apart unnoticed.
CS193V_TITLE='CS193V Development Environment'

# The entry banner's greeting line.
CS193V_WELCOME='Welcome to the CS193V Development Environment!'

# Printed once, after the whole tmux session ends — not per tab. See cs193v-goodbye.
CS193V_GOODBYE='You have left the CS193V development environment. Goodbye!'
