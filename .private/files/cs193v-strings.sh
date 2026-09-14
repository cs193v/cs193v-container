# CS193V — the strings the container prints, defined once.
#
# Installed as /etc/cs193v/strings.sh and sourced by cs193v-welcome.
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
#
# ONE EXCEPTION SINCE #257, AND IT IS THE CASE THE RULE CANNOT DECIDE. The two CS193V_OPEN_*
# strings below are printed by BOTH sides: by cs193v-platform-messages --hostpath, which an
# agent inside the container runs and reads out, and by the launcher's `doctor`, which the
# student runs on their own computer. They answer the same question, so a student who asks the
# agent and then runs doctor must not be shown two differently worded instructions -- which is
# exactly what happened on the first draft of #257, where the same sentence was written into the
# program and into messages.txt and the two came out different. Neither home can hold it alone:
# the container cannot read messages.txt, and a copy in the image that the launcher could not
# read would drift the moment either was reworded. So the launcher sources THIS file for these
# two keys, out of .private/files/ where it already sources cs193v-ui.sh from, and nothing else
# host-side moves here.

# The name of the environment. Appears in the tmux title bar across the top of the terminal,
# and in the host terminal's window title.
#
# Nothing that RUNS reads this: tmux.conf and rewrite-window-title.py both carry the literal,
# because neither can source a shell file. So this is the one definition the tests check those
# two copies against, which is what keeps them from drifting apart unnoticed.
CS193V_TITLE='CS193V Development Environment'

# The entry banner's greeting line.
CS193V_WELCOME='Welcome to the CS193V Development Environment!'

# NO GOODBYE HERE ANY MORE (#220). Leaving is announced by the LAUNCHER, from messages.txt,
# because the exit line has to stay on screen while the host tears the tunnel and the container
# down and then be finished off on the same row -- which nothing inside a container that is in
# the act of stopping can do. A container-side copy would be a second definition of one message.

# ─── how a student opens their own projects folder (#257) ──────────────────────
# READ BY BOTH SIDES, which is why they are here rather than in either home; see the exception
# noted at the top of this file.
#
# NO COMMAND IN EITHER OF THEM. A student on a Mac or on Windows is not assumed to know a
# terminal, so both are routes through a graphical file browser. `explorer.exe .` is shorter and
# is what Microsoft documents for this, and it is deliberately not here -- it is a command, and
# it cannot run inside the container at all, which has no Windows interop.
#
# THERE IS NO LINUX STRING, and that is the decision rather than an omission: that student is
# assumed to be at home in a terminal and a file manager, and naming one of the several Linux
# file managers would be wrong more often than it helped. The path on its own is the answer.
#
# BOTH FIT 61 COLUMNS, which is what doctor's drows leaves after its two spaces and the
# 16-column label.
CS193V_OPEN_MACOS='In Finder: Go menu, "Go to Folder", then paste that path.'
CS193V_OPEN_WINDOWS='In File Explorer, paste that path into the address bar.'
