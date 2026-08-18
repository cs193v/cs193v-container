# CS193V — the strings the RESTRICTED container prints, defined once.
#
# Installed as /etc/cs193v/strings.sh in the `restricted` stage, exactly where
# cs193v-strings.sh goes in the `dev` stage. That shared path is the whole trick: it means
# cs193v-welcome and cs193v-goodbye need no fork and no flavour flag — each container
# sources whatever strings.sh is present and says the right thing.
#
# Read the header of cs193v-strings.sh for why these live in the image rather than in
# messages.txt, and why the tests source this same file instead of repeating its text.
#
# EVERY STRING HERE MUST NAME THE RESTRICTED ENVIRONMENT, not the development one. That is
# not cosmetic: the most likely serious mistake a student can make with this feature is
# running the sensitive script in the wrong container, and the banner, the tmux title bar,
# the shell prompt and the host window title are the four things that stop them. See
# CONTAINER-DESIGN.md § "Working with data Claude cannot see".
#
# The title must agree with three other places, all of which the tests check: the title bar
# and window title in files/tmux/tmux-restricted.conf, and the argument the Containerfile
# passes to rewrite-window-title.py.

# The name of the environment. Appears in the entry banner, in the tmux title bar across the
# top of the terminal, and in the host terminal's window title.
CS193V_TITLE='CS193V: Restricted Environment'

# The entry banner's greeting line, and the two lines under it. No mention of `ports`: that
# command is deliberately not installed here, because nothing is forwarded out of this
# container.
CS193V_WELCOME='This is the CS193V Restricted Environment.'
CS193V_WELCOME_HINT_1='Your data goes in ~/restricted. Run `am-i-in-a-container` to'
CS193V_WELCOME_HINT_2='see this setup again.'

# ─── The long explanation ──────────────────────────────────────────────────────
# PLACEHOLDER TEXT — staff to revise. The structure is the part worth keeping: what the
# sandbox guarantees, what it does not, and how to use it. The third section is not padding;
# without it the first thing a student meets is a container where `pip install` fails.
#
# Printed by cs193v-welcome after the greeting, and skipped entirely when unset — which is
# how the development container's banner stays exactly as it was.
#
# PRE-WRAPPED ON PURPOSE, and not reflowed by the script. The line breaks are staff's to
# choose, and the banner is capped at 72 columns, so keep lines under about 64 characters.
#
# NO APOSTROPHES: this is a single-quoted POSIX string, and `sh -n` at build time will not
# save you from one. Write "does not" rather than the contraction.
CS193V_WELCOME_BODY='Run code here over data that Claude must never see.

WHAT THIS CONTAINER GUARANTEES
  * No network at all. Nothing here can reach the internet,
    and no server started here can be reached from outside
    this container.
  * ~/projects is READ-ONLY. Code cannot change your work or
    leave anything behind in it.
  * There is no sudo, and Claude Code is not installed.

WHAT IT DOES NOT GUARANTEE
  * You are still a channel. Anything you copy from this
    window and paste into Claude has left the sandbox --
    including error messages.
  * Output can leak once you open it. An HTML or SVG file
    opened in your browser may fetch from the network. CSV,
    JSON, TXT, PNG and PDF cannot.

HOW TO USE IT
  * Put your data files in ~/restricted, and write your
    results there too.
  * Install dependencies in the DEVELOPMENT container, before
    you come here: npm into node_modules/, or pip into a
    .venv, both inside ~/projects. There is no apt and no
    network in here, so nothing can be added once you arrive.'

# Bold red, against plain bold in the development container. ANSI 31 rather than a
# 256-colour red so it maps through whatever theme the student's own terminal uses.
CS193V_BANNER_SGR='1;31'

# Printed once, after the whole tmux session ends — not per tab. See cs193v-goodbye.
CS193V_GOODBYE='You have left the CS193V restricted environment. Goodbye!'
