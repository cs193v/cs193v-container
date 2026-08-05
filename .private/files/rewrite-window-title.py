#!/usr/bin/env python3
"""Point the terminal's window title at the course, in the student's ~/.bashrc.

Ubuntu sets the window title *through* PS1, and re-emits it on every prompt:

    PS1="\\[\\e]0;${debian_chroot:+($debian_chroot)}\\u@\\h: \\w\\a\\]$PS1"

That means a title set once at login is overwritten immediately, so naming the environment
in the window chrome requires editing this one escape. Only the invisible title sequence is
touched -- the visible prompt is left exactly as Ubuntu ships it, because the hostname
(cs193v-development) already makes it say where you are.

`\\w` is kept in the new title so the chrome still shows the current directory, which is
genuinely useful and would be lost by pinning a static string.

This is a script rather than a `sed -i` in the Containerfile on purpose: the pattern is
almost entirely backslashes, and getting those through the Dockerfile parser *and* the shell
*and* into a BRE correctly is a well-known way to ship something that silently matches
nothing. Here the strings are literal, and it fails loudly if the expected text is absent --
which is what should happen if a future base image changes its default bashrc.
"""

import sys

PATH = "/home/student/.bashrc"

OLD = r'\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]'
NEW = r'\[\e]0;CS193V Development Environment \w\a\]'


def main():
    with open(PATH) as fh:
        text = fh.read()

    if NEW in text:
        print("window title already points at CS193V; nothing to do")
        return 0

    if OLD not in text:
        sys.stderr.write(
            "ERROR: could not find Ubuntu's PS1 window-title escape in %s.\n"
            "The base image's default bashrc must have changed. Update OLD in\n"
            "files/rewrite-window-title.py to match, or the window title will\n"
            "silently keep saying student@<host> instead of naming the course.\n" % PATH
        )
        return 1

    with open(PATH, "w") as fh:
        fh.write(text.replace(OLD, NEW))
    print("window title now names the CS193V environment")
    return 0


if __name__ == "__main__":
    sys.exit(main())
