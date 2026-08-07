# CS193V -- show a second word in tab labels for commands whose name alone says nothing.
#
# Installed as /etc/cs193v/tabname.bash and sourced from /etc/bash.bashrc, which reaches
# every interactive bash and therefore every tab. Sourced, never executed: no exec bit.
#
# PROVENANCE. Forked from the Option B prototype in the sibling `multiplexer` project; see
# the header of tmux.conf. Divergences are marked `# FORK:`.
#
# WHY THIS EXISTS
# tmux labels a tab with the foreground process's NAME, which it reads from /proc. That is
# exactly right almost all the time, and it needs no scripting -- but a single word is not
# enough for two kinds of command:
#
#     sudo apt install nginx     ->  tab says "sudo"   (the wrapper hides the real command)
#     git commit -m "..."        ->  tab says "git"    (could be a commit, a clone, a long rebase)
#     npm install express        ->  tab says "npm"
#
# With this hook those read "sudo apt", "git commit" and "npm install".
#
# An argument keeps only its basename, so labels stay short and still name the interesting
# thing: `sudo /usr/bin/apt` -> "sudo apt", `python3 ./src/app.py` -> "python3 app.py",
# `pytest tests/unit` -> "pytest unit".
#
# tmux cannot fix this by configuration. Verified exhaustively: `display-message -a` (which
# dumps EVERY format variable tmux knows) exposes `pane_current_command` and `pane_pid`, but
# nothing anywhere contains the process's argument vector. There is no format for it, so no
# `automatic-rename-format` can recover the second word.
#
# ONE TRADEOFF WORTH KNOWING. Setting a label pins it (see rename-window, below), so for as
# long as a listed command runs, the tab shows WHAT YOU TYPED rather than what is in the
# foreground right now. `git commit` opens an editor, and the tab keeps saying "git commit"
# instead of switching to "nano". That is usually the more useful of the two, but it is a
# real change in meaning: without this hook the label always tracks the live process. Trim
# the list if you would rather have fidelity than context.

[ -n "${TMUX:-}" ] || return 0
case "$-" in *i*) ;; *) return 0 ;; esac

# Commands whose FIRST WORD ALONE does not tell a student what is happening. For these, and
# only these, the tab shows two words instead of one. Everything else is left to tmux.
#
# Two groups, for two different reasons:
#
#   WRAPPERS -- the process really is the wrapper, and it hides the command underneath.
#               `sudo apt install nginx` genuinely runs as `sudo`, so tmux can only say "sudo".
#
#   MULTI-TOOLS -- the process name is right but uselessly broad, because the tool does many
#               unrelated jobs. "git" could be a commit, a clone, or a 20-minute rebase; "npm"
#               could be an install or a dev server. The subcommand is the informative part.
#
# FORK: `claude`, `gh` and `vercel` added -- the three course tools, none of which the
# prototype's machine had installed the way this image installs them.
#
# `claude` is not a nicety, it is the reason the hook ships at all. Claude Code is installed
# here with `npm install -g`, so /usr/local/bin/claude is a script with a
# `#!/usr/bin/env node` shebang, and /proc reports the INTERPRETER. Without this line every
# Claude Code tab in the course -- which is most of them -- would be labelled `node`. The
# prototype recorded this as a known gap because its own `claude` happened to be a native
# binary; here it is the common case. The alternative fix, an
# `automatic-rename-format` conditional mapping `node` to `claude`, was rejected: it would
# also relabel a student's own `node server.js`, which is a thing this course expects them
# to run.
_CS193V_SHOW_ARG="sudo doas env time nice ionice nohup stdbuf xargs setsid
                  git python python3 pip pip3 npm npx node yarn pnpm deno
                  make cargo go docker podman apt apt-get gem bundle poetry uv pytest
                  claude gh vercel"

# A CAVEAT ABOUT `time`, which is worth knowing before you extend this list: `time` is a bash
# KEYWORD, not a command, and bash reports only the *inner* command to the DEBUG trap. Typing
#     time git commit
# gives $BASH_COMMAND = "git commit", so the tab reads "git commit" -- which is the better label
# anyway, since the process really is git. `time` stays on the list because the external binary
# (/usr/bin/time, or `command time`) DOES arrive intact and would otherwise label as just "time".
# Verified: a DEBUG trap on `time sleep 1` sees "sleep 1"; on `/usr/bin/time sleep 1` it sees the
# whole line.

# Flags that consume the NEXT token, where a command still follows afterwards:
#   sudo -u www-data apt install   ->  skip "-u", skip "www-data", keep looking, find "apt"
_CS193V_VALUE_FLAGS="-u -g -U -C -p -h -r -t -D -R -S"

# Flags after which EVERYTHING is data, not a command name -- so stop looking entirely.
# This exists because `set --` word-splits a quoted argument into several words:
#   python3 -c 'import time; time.sleep(30)'
# splits into  python3 | -c | 'import | time; | time.sleep(30)'
# Merely skipping one token after -c would leave "time;" looking like a command, and the tab would
# read "python3 time;". Stopping gives the correct "python3".
_CS193V_STOP_FLAGS="-c -e --eval --command --exec-command"

# Hard ceiling on label length in words, so no chain of runners can produce a silly label.
_CS193V_MAX_WORDS=3

# Only the first command after each prompt may relabel the tab. The DEBUG trap fires for every
# command bash runs -- including each entry in PROMPT_COMMAND -- so without this the label would
# end up being whatever the prompt machinery ran last. Ubuntu sets __vte_prompt_command by
# default, and that is exactly what the tab used to be named.
_cs193v_armed=0

# Run a tmux command against THIS SHELL'S OWN window, whichever tab the student is looking at.
#
# This targeting is not optional, and leaving it out caused a real bug: a tmux command run from
# inside a pane does NOT default to that pane's window, it resolves against the session's CURRENT
# window. So when a command finished in a background tab, `set-window-option automatic-rename on`
# landed on whatever tab happened to be active instead; the original tab kept automatic-rename OFF
# and its pinned label ("python3 slowpoke.py") became permanent -- it never reverted to "bash", not
# even after switching back to it.
#
# $TMUX_PANE is the pane's own unique id (e.g. "%0"), exported by tmux into every pane's
# environment, and a pane id is a valid -t target that resolves to that pane's window.
_cs193v_tmux() {
    local cmd="$1"; shift
    if [ -n "${TMUX_PANE:-}" ]; then
        tmux "$cmd" -t "$TMUX_PANE" "$@" 2>/dev/null
    else
        tmux "$cmd" "$@" 2>/dev/null
    fi
}

_cs193v_preexec() {
    [ "$_cs193v_armed" = 1 ] || return 0
    [ -n "${COMP_LINE:-}" ] && return 0
    case "$BASH_COMMAND" in _cs193v_*|tmux\ *) return 0 ;; esac

    # FORK, AND WITHOUT IT NOTHING BELOW EVER RUNS ON UBUNTU 26.04.
    #
    # Skip anything that is itself an entry in PROMPT_COMMAND, and skip it WITHOUT
    # disarming -- the return above `_cs193v_armed=0` is the load-bearing part.
    #
    # The prototype only skipped its own entries, on the assumption that its precmd was the
    # last thing to run before the prompt. It is not, here. Ubuntu 26.04 ships systemd's
    # shell integration, and bash 5.1+ makes PROMPT_COMMAND an ARRAY:
    #
    #     declare -a PROMPT_COMMAND=([0]="_cs193v_precmd" [1]="__systemd_osc_context_precmdline")
    #
    # Ours is element 0 because /etc/bash.bashrc is sourced by /etc/profile BEFORE the
    # profile.d loop that adds systemd's, so systemd's always runs after ours -- and it was
    # spending the one-shot arming flag every single time. Measured with a DEBUG-trap log:
    #
    #     armed=0 cmd=[_cs193v_precmd]                    <- arms
    #     armed=1 cmd=[__systemd_osc_context_precmdline]  <- spends it
    #     armed=0 cmd=[sudo python3 ...]                  <- the real command, disarmed
    #
    # The symptom was total and silent: every label stayed at tmux's one-word default, so
    # `sudo apt install` read `sudo` and the hook may as well not have been installed.
    #
    # Matching against PROMPT_COMMAND itself rather than adding "__systemd_osc_context_*" to
    # the pattern above, because the next release will ship a different prompt hook and this
    # keeps working without anyone noticing it had to.
    local _pc
    for _pc in "${PROMPT_COMMAND[@]:-}"; do
        [ "$BASH_COMMAND" = "$_pc" ] && return 0
    done

    local first label tok next words=1

    # Split the command line into words. Two safeguards on this one line:
    #   `local -` makes shell-option changes local to this function, and `set -f` disables globbing
    #   for the split, so a command like `sudo rm *.txt` does not expand the glob against the
    #   current directory just to work out a tab label.
    #   `set --` (with the --) means a command line starting with a dash can never be mistaken for
    #   options to `set` itself.
    local -
    set -f
    set -- $BASH_COMMAND
    first=${1##*/}
    case "$first" in ""|*=*) return 0 ;; esac

    _cs193v_armed=0
    label="$first"

    case " $_CS193V_SHOW_ARG " in
        *" $first "*) ;;
        *) return 0 ;;   # not on the list: leave it to tmux, which is cheaper and always accurate
    esac
    shift

    # RECURSIVE. One pass would give "sudo apt", but `apt` is itself on the list and its subcommand
    # is the informative part, so the rule re-applies: "sudo apt update". It keeps unwrapping for as
    # long as the word it lands on is also a runner, and stops at the first word that is not:
    #
    #     sudo apt update          ->  sudo, apt on the list, update is not   ->  "sudo apt update"
    #     sudo apt install nginx   ->  stops at install                       ->  "sudo apt install"
    #     sudo -u root npm install ->  flags skipped, npm on the list         ->  "sudo npm install"
    #     git commit -m "..."      ->  commit is not on the list              ->  "git commit"
    #     claude                   ->  nothing follows                        ->  "claude"
    #     gh auth login            ->  stops at auth                          ->  "gh auth"
    #
    # Capped at _CS193V_MAX_WORDS so a label can never run away (`sudo time nice env ...`), and
    # truncated to 24 characters at the end regardless.
    while [ $# -gt 0 ] && [ "$words" -lt "$_CS193V_MAX_WORDS" ]; do
        next=""
        while [ $# -gt 0 ]; do
            tok="$1"
            case " $_CS193V_STOP_FLAGS " in
                *" $tok "*)
                    # `-c` is genuinely ambiguous and both readings are common here:
                    #     python3 -c 'import time; …'   -> code follows, stop reading
                    #     git -c user.name=x commit     -> a setting follows, and a subcommand
                    #                                      still comes after it
                    # Peek at the value: an assignment (contains "=") means keep looking, anything
                    # else means the rest is data.
                    case "${2:-}" in
                        # `shift 2` FAILS (and shifts nothing) when only one argument is left,
                        # which would spin this loop forever -- hence the count check.
                        *=*) if [ $# -ge 2 ]; then shift 2; else shift; fi; continue ;;
                        *)   break 2 ;;   # leaves BOTH loops: nothing after this is a command
                    esac
                    ;;
            esac
            case " $_CS193V_VALUE_FLAGS " in
                *" $tok "*) if [ $# -ge 2 ]; then shift 2; else shift; fi; continue ;;
            esac
            case "$tok" in
                -*|*=*) shift; continue ;;            # a plain flag, or FOO=bar
            esac
            next="${tok##*/}"
            shift
            break
        done

        [ -n "$next" ] || break                       # ran out of words without finding one
        label="$label $next"
        words=$((words + 1))

        case " $_CS193V_SHOW_ARG " in
            *" $next "*) ;;                           # itself a runner: unwrap another level
            *) break ;;                               # a real subcommand: this is the last word
        esac
    done

    # rename-window also switches automatic-rename OFF for this window, which is what keeps the
    # label pinned for as long as the command runs. _cs193v_precmd turns it back on.
    _cs193v_tmux rename-window "${label:0:24}"
}

_cs193v_precmd() {
    # Hand labeling back to tmux: the command finished, so the tab should track the process again
    # (which makes it read "bash" at an idle prompt).
    #
    # MUST be targeted at this shell's own window -- see _cs193v_tmux. The command may well have
    # finished while the student was looking at a different tab.
    _cs193v_tmux set-window-option automatic-rename on
    _cs193v_armed=1      # armed LAST, so nothing above can re-trigger the trap
}

# LIMITATIONS, stated plainly: `sudo -u www-data apt` labels as "sudo www-data", because option
# grammars are not universally parseable; this is bash only, with nothing for zsh or fish; and it
# only sees commands the student types, not commands launched by scripts.
#
# The PROMPT_COMMAND composition below APPENDS. Anything sourced after this file that assigns
# PROMPT_COMMAND wholesale will silently drop the hook, so this must stay last in
# /etc/bash.bashrc.
trap '_cs193v_preexec' DEBUG
PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }_cs193v_precmd"
