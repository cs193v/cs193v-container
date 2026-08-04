# CS193V shell ergonomics. Sourced by login shells via /etc/profile.d, and appended to
# /etc/bash.bashrc so interactive non-login shells get it too.

# Disable XON/XOFF flow control.
#
# Ctrl-S is "save" in every GUI editor. On a terminal it sends XOFF, which freezes ALL
# output and stops echoing what you type — indistinguishable from a crashed container.
# The recovery is Ctrl-Q, which no novice knows. Flow control has no modern use on a
# pseudo-terminal; it is only still enabled by inertia.
#
# Bonus: with ixon off, bash's readline gets Ctrl-S back as forward-search-history.
case $- in
    *i*) [ -t 0 ] && stty -ixon 2>/dev/null ;;
esac
