#!/usr/bin/env bash
# TIER: static
#
# VERIFICATION.md §A.1, plus the invariants the repo documents in prose but nothing
# enforces. No podman, no image, no network.
#
# Three §A.1 checks are corrected here rather than copied:
#   * the .gitignore greps need -F. `grep -x 'projects/*'` treats * as a BRE quantifier,
#     so it matches "projects", "projects/", "projects//" — never the literal line, and
#     the check silently never fired.
#   * the messages cross-reference needs LC_ALL=C. Under en_US.UTF-8, sort and comm
#     disagree about punctuation and comm aborts with "file 1 is not in sorted order".
#   * the ban-list greps must strip comments first, or the scripts' own documentation of
#     the ban matches itself.

set -u
. "$(dirname -- "$0")/lib/assert.sh"

cd "$REPO" || exit 1

# ABOVE THE FIRST CHECK THAT USES IT, which here is syntax:shortlink four lines down. Twelve
# checks in this file derive an answer from python3, and two of them -- syntax:shortlink and
# claude:managed-settings-is-valid-json -- are assert_oks, so their whole verdict IS the
# interpreter's exit status. Measured (#79): an interpreter that prints something else and exits 0
# passes both while compiling and parsing nothing. The other ten answer with a sentinel and fail
# on it, which is why the file cannot go green either way -- but a pass that measured nothing is
# still a pass that measured nothing.
require_python3

# ─── syntax ────────────────────────────────────────────────────────────────────
assert_ok  "syntax:cs193v"            bash -n cs193v
assert_ok  "syntax:install"           bash -n $PRIVATE/install-cs193v.sh
assert_ok  "syntax:entrypoint"        bash -n $PRIVATE/files/entrypoint.sh
assert_ok  "syntax:profile.d"         bash -n $PRIVATE/files/profile.d/10-cs193v-shell.sh
assert_ok  "syntax:open-url"          sh -n $PRIVATE/files/open-url
# THE ONE PYTHON PROGRAM THIS IMAGE INSTALLS, and `compile()` rather than py_compile for the
# reason the Containerfile records: py_compile would drop a .pyc beside it.
assert_ok  "syntax:shortlink"         python3 -c \
           "import sys; p = sys.argv[1]; compile(open(p).read(), p, 'exec')" \
           $PRIVATE/files/shortlink
assert_ok  "syntax:man"               sh -n $PRIVATE/files/man
assert_ok  "syntax:ui"                bash -n $PRIVATE/files/cs193v-ui.sh
assert_ok  "syntax:setup-git"         bash -n $PRIVATE/files/setup-git
assert_ok  "syntax:podman-fake"       sh -n $PRIVATE/tests/lib/podman-fake
assert_ok  "syntax:run-tests"         bash -n $PRIVATE/tests/run-tests.sh

assert_exec "exec:cs193v"             "$REPO/cs193v"
assert_exec "exec:install"            "$PRIVATE/install-cs193v.sh"

# ─── the tunnel may only ever bind loopback ────────────────────────────────────
# EVERY -L IN THE LAUNCHER MUST BIND 127.0.0.1, and this is the cheapest possible guard on the
# security property the whole design rests on: the host side of the tunnel is loopback-only
# because the ssh client binds it that way, not because of a flag anyone remembers. There is one
# -L left -- the template in tunnel_dyn_forward, whose port comes from the container -- and the
# address either side of it is a literal. A `-L $something:` or a `-L *:` reaching this file would
# expose a student's dev server to the dorm network, and no runtime test would necessarily catch
# the case that mattered.
#
# 60-container.sh asserts the same property from the other end, against a running tunnel; this one
# fails at edit time, before anything is built.
# `[ -L` FILTERED FIRST, and it is not a nicety: -L is also test(1)'s "is a symlink", which the
# launcher uses to resolve $SELF. And the address is QUOTED at the call site, so the allowed
# pattern has to admit the quote -- without that this matched the two correct lines and reported
# them as violations.
# TWO OTHER MEANINGS OF -L ARE FILTERED FIRST, and both were false positives on the real file:
# test(1)'s "is a symlink", which the launcher uses to resolve $SELF, and `tmux -L`, which names a
# socket. And the address is QUOTED at the call site, so the allowed pattern has to admit the
# quote -- without that this matched the two correct lines and called them violations.
hits="$(sed 's/#.*//' cs193v | grep -nE '(^|[^[:alnum:]_])-L ' \
        | grep -vE '\[ *!? *-L ' | grep -vE 'tmux[^|]*-L ' \
        | grep -vE '[-]L "?127[.]0[.]0[.]1:' || true)"
assert_eq "ports:every-forward-binds-loopback" "" "$hits"

# ─── bash 3.2 compatibility ────────────────────────────────────────────────────
# macOS ships bash 3.2 and the launcher is the same script on every platform, so a bash 4
# construct is a Mac-only breakage that no Linux test run would ever surface.
# `coproc` joined the list while the supervisor was being written: it is bash 4, it is exactly
# what someone reaches for when wiring a long-lived reader to a long-lived writer, and the
# supervisor is that shape -- so this is the one place a Mac-only breakage would have been most
# tempting to introduce. verb_supervise uses `< <(...)` instead.
BASH4='declare -A|mapfile|readarray|coproc |\$\{[A-Za-z_]+,,\}|\$\{[A-Za-z_]+\^\^\}|[[:space:]]\|&[[:space:]]|&>>'
hits="$(sed 's/#.*//' cs193v $PRIVATE/install-cs193v.sh | grep -nE "$BASH4" || true)"
assert_eq  "bash32:no-bash4-constructs" "" "$hits"

hits="$(sed 's/#.*//' cs193v $PRIVATE/install-cs193v.sh | grep -nE 'read[^|]*-t *0?\.[0-9]' || true)"
assert_eq  "bash32:no-fractional-read-t" "" "$hits"

# The test suite itself has to run on bash 3.2, since the TAs use it on Macs to settle
# VERIFICATION.md §5.2/§5.3. The BASH4= assignment below is excluded, or the ban list
# matches its own definition.
#
# THE GLOB IS `tests/*.sh`, TOP LEVEL ONLY, AND tests/tmux-harness/ IS EXEMPT ON PURPOSE.
# Do not widen it. That directory is copied into the container and run there, by the
# container's own bash 5 -- it never executes on the host, so bash 3.2 is not a constraint
# on it, and holding it to one would mean rewriting vendored code for a platform it will
# never see. Its host-side driver, 65-tmux.sh, IS top level and so IS covered here, which
# is the part that matters.
hits="$(sed 's/#.*//' $PRIVATE/tests/run-tests.sh $PRIVATE/tests/lib/assert.sh $PRIVATE/tests/lib/podman-shim.sh $PRIVATE/tests/lib/sandbox.sh $PRIVATE/tests/*.sh \
        | grep -v 'BASH4=' | grep -nE "$BASH4" || true)"
assert_eq  "bash32:tests-are-bash32-safe" "" "$hits"

# ─── every throwaway container the suite starts is labelled as ours ────────────
# The live tier tells its own containers from a colleague's by a label, because a `podman run --rm`
# with no --name gets a name podman chose and there is nothing else to go on (#74, and VT_LABEL in
# lib/assert.sh). One `podman run` written without it reopens the hole INVISIBLY: the container
# lives for seconds, it reddens somebody else's run rather than the run that wrote it, and it
# arrives as a flake. So the rule is checked here rather than trusted to review.
#
# ONLY THE SUITES THAT DRIVE REAL PODMAN, which is what the tier line names. 30-launcher-shim.sh
# is excluded on purpose and by construction: it runs against a fake podman on PATH, creates
# nothing, and legitimately says "podman run" as an assertion needle.
#
# `--label` rather than `$VT_RUN` is the thing looked for, so that the one line which spells the
# label out passes on its own terms and a future second runner can too.
# lib/sandbox.sh IS ON THIS LIST, and it has to be: the install tier's `podman run` lives in
# the library rather than in the suite, so a list built only from suite files checked nothing
# at all for that tier. `install` joins the case arm for the same reason -- a new tier is
# silently exempt from this rule otherwise, which is how the hole reopens without anyone
# editing the rule.
real_podman="$PRIVATE/tests/lib/assert.sh $PRIVATE/tests/lib/sandbox.sh"
for f in $PRIVATE/tests/[0-9][0-9]-*.sh; do
    case "$(sed -n 's/^#[[:space:]]*TIER:[[:space:]]*\([a-z]*\).*/\1/p' "$f" | head -1)" in
        image|container|live|install) real_podman="$real_podman $f" ;;
    esac
done
# -H so the failure names the file even when the list is one entry long, and the comment filter
# is anchored to grep's own file:line: prefix rather than looking for a `#` anywhere.
# shellcheck disable=SC2086   # deliberately word-split: it is a list of paths
bare="$(grep -Hn 'podman run' $real_podman | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' \
        | grep -v -- '--label' || true)"
assert_eq "throwaways:every-podman-run-is-labelled-as-ours" "" "$bare"

# ─── one door for running the installer on the host ────────────────────────────
# install-cs193v.sh is the one script in this repo that changes a machine, and the suite
# runs it FOR REAL -- against a fake podman, but with real mkdir, real tar and real chmod.
# Those three need no privilege, so the only thing standing between a case and the
# developer's own home directory is where $DIR comes from.
#
# CS193V_DIR IS NOT ENOUGH, and that is why this rule exists rather than a comment.
# choose_dir returns immediately when CS193V_DIR is set, so any case that wants to reach
# its MENU -- the typed path, the empty-input fallback, the ~/ expansion -- has to leave it
# unset, and DEFAULT_DIR is then $HOME/cs193v. Until installer_host existed, the only
# reason no case had ever written there was that all four of them happened to spell
# CS193V_DIR out by hand: a habit, one new call site away from being broken.
#
# So: exactly one helper may start the installer, and it sets HOME as well. `bash -n` is
# excluded because it parses without executing, which is a syntax check and not a run.
# THE NEEDLE IS ASSEMBLED TAIL-FIRST, and that is not style: written out in one piece it
# would match this very line and the rule would fail on its own definition forever. With
# the two halves in this order the line contains "install" BEFORE "bash ", which the
# pattern -- bash first -- cannot match. The bash 3.2 ban list above has the same problem
# and solves it by naming its files rather than globbing them.
door_tail='install'; door_head='bash '
# shellcheck disable=SC2086   # deliberately word-split: it is a list of paths
bare="$(grep -Hn "$door_head.*$door_tail" $PRIVATE/tests/[0-9][0-9]-*.sh \
        | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' \
        | grep -v 'bash -n' | grep -vE 'installer_host|installer_tty' || true)"
assert_eq "installer-door:no-other-way-to-start-it" "" "$bare"

# And the door has to do the thing it exists for. Extraction asserted first: an empty
# function body would satisfy every grep below it forever.
door="$(sed -n '/^installer_host()/,/^}$/p' "$PRIVATE/tests/lib/podman-shim.sh")"
if [ "$(printf '%s' "$door" | grep -c '.')" -ge 4 ]; then pass "installer-door:extractable"
else fail "installer-door:extractable" "could not find installer_host in lib/podman-shim.sh"; fi
assert_contains "installer-door:redirects-HOME"        'HOME=' "$door"
assert_contains "installer-door:puts-the-shim-first"   'PATH="$SHIM' "$door"

# The pty door is a second copy of the same rule, for the reason its own comment gives, so
# the agreement is asserted rather than assumed.
ttydoor="$(sed -n '/^installer_tty()/,/^}$/p' "$PRIVATE/tests/lib/podman-shim.sh")"
if [ "$(printf '%s' "$ttydoor" | grep -c '.')" -ge 4 ]; then pass "installer-door:tty-extractable"
else fail "installer-door:tty-extractable" "could not find installer_tty"; fi
assert_contains "installer-door:tty-redirects-HOME"      'HOME=' "$ttydoor"
assert_contains "installer-door:tty-puts-the-shim-first" 'PATH=$SHIM' "$ttydoor"

# ─── the fake sudo cannot execute anything ─────────────────────────────────────
# All four of the installer's privileged calls go through one name, so a sudo that never
# execs makes the whole shim tier structurally unable to change this machine. That is worth
# more than any assertion about what a case happened to do -- and it is one negated test
# away from being false if an exec branch is ever added, so the absence is checked here.
sudofake="$PRIVATE/tests/lib/sudo-fake"
assert_ok "sudo-fake:exists" test -x "$sudofake"
bare="$(grep -nE '(^|[^-[:alnum:]_])(exec|eval)([^[:alnum:]_]|$)' "$sudofake" \
        | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
assert_eq "sudo-fake:never-executes-anything" "" "$bare"
# ...and it is on PATH for EVERY shim run, not only the cases that assert on it, so a case
# written later cannot reach the real sudo by forgetting to ask for the fake.
assert_contains "sudo-fake:installed-by-shim_new" 'lib/sudo-fake' \
                "$(sed -n '/^shim_new()/,/^}$/p' "$PRIVATE/tests/lib/podman-shim.sh")"

# ...and no run in the cheap lane may use the UNEDITED installer, whose TARBALL is the real
# GitHub URL. That is how the shim tier came to make a live network request on every run,
# in a tier whose own header says "no podman, no image, no network", with `|| true` hiding
# what came back. Every case now runs a copy whose TARBALL is a file:// path, so the rule
# is simply that the original is never handed to the door.
#
# Assembled second-literal-first for the same reason as the needle above: written in one
# piece this line would match itself.
net_arg='install-cs193v.sh'; net_fn='installer_host'
# shellcheck disable=SC2086   # deliberately word-split: it is a list of paths
bare="$(grep -Hn "$net_fn.*$net_arg" $PRIVATE/tests/[0-9][0-9]-*.sh \
        | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true)"
assert_eq "installer-door:never-runs-the-unedited-installer" "" "$bare"

# ─── the traced line numbers have to mean something ────────────────────────────
# THE PURE HALF OF THE COVERAGE GATE. 95-installer-coverage.sh unions line numbers recorded
# while the installer ran, and every one of those runs is of an EDITED COPY -- edit_sub
# rewrites REPO_OWNER and TARBALL so the tarball comes from file:// instead of GitHub. That is
# only safe because both are same-line substitutions. If either ever became multi-line, the
# copy's line numbers would drift from the original's and the gate would score the wrong file
# while reporting a confident percentage. Checked here because it is repo-versus-repo and
# costs milliseconds; the union itself cannot live here, since this suite runs FIRST and the
# producers all run later.
cov_tmp="$(mktemp -d "${TMPDIR:-/tmp}/cs193v-cov.XXXXXX")"
cp "$PRIVATE/install-cs193v.sh" "$cov_tmp/copy.sh"
sed -E 's|^REPO_OWNER=.*|REPO_OWNER="test"|' "$cov_tmp/copy.sh" > "$cov_tmp/a" && mv "$cov_tmp/a" "$cov_tmp/copy.sh"
sed -E 's|^TARBALL=.*|TARBALL="file:///work/course.tar.gz"|' "$cov_tmp/copy.sh" > "$cov_tmp/a" && mv "$cov_tmp/a" "$cov_tmp/copy.sh"
assert_eq "coverage:the-edited-copy-keeps-the-original-s-line-numbers" \
          "$(grep -c '' "$PRIVATE/install-cs193v.sh")" "$(grep -c '' "$cov_tmp/copy.sh")"
# ...and the edits really landed, or the assertion above is comparing a file to itself.
assert_ok "coverage:the-edits-really-applied" grep -q '^REPO_OWNER="test"' "$cov_tmp/copy.sh"
rm -rf "$cov_tmp"

# ─── one place decides what a fixture machine needs ────────────────────────────
# The install tier and the hand-driven sandbox both run the same fixture images, and each used
# to decide a machine's podman flags for itself -- install-sandbox.sh had the nested caps and
# the wsl bind mount, sandbox_run grew a no-podman case, nest_build hardcoded its own. They
# disagreed, and the failure was not subtle: the no-podman fixture installs a real podman, the
# installer asked it for MemTotal, and it died with "cannot set up namespace using
# /usr/bin/newuidmap" because only the nested path had SYS_ADMIN. The suite called that case
# green, because it only ever asked `podman --version`, which never touches the runtime.
#
# So the requirements live in fixture_flags and this asserts nothing else names them. A rule,
# not a convention: the next person to add a machine cannot reintroduce the split by forgetting
# a convention they never read.
# shellcheck disable=SC2086   # deliberately word-split: it is a list of paths
# NOT this file: 10-static.sh names --cap-add=SYS_ADMIN in its own container.args invariant
# list, which is a different job entirely. The rule is about the files that DECIDE what a
# fixture machine gets.
flagfiles="$PRIVATE/tests/lib/sandbox.sh $PRIVATE/tests/install-sandbox.sh $PRIVATE/tests/2[0-9]-*.sh"
# shellcheck disable=SC2086
# ASSEMBLED TAIL-FIRST, or this line matches itself and the rule fails on its own definition --
# the third time that has happened in this file, hence the shared idiom.
sa_tail='SYS_ADMIN'; sa_head='--cap-add='
naming="$(grep -Hn -- "$sa_head$sa_tail" $flagfiles \
          | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true)"
assert_eq "fixture-flags:only-one-place-names-SYS_ADMIN" "1" \
          "$(printf '%s\n' "$naming" | grep -c . )"
assert_says "fixture-flags:and-that-place-is-fixture_flags" 'lib/sandbox.sh' "$naming"
# The same for the unmask, which is the other departure and the one container.args forbids in
# its wider form -- so a second copy appearing anywhere is worth failing over.
# shellcheck disable=SC2086
um_tail='=/proc'; um_head='unmask'
naming2="$(grep -Hn -- "$um_head$um_tail" $flagfiles \
           | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true)"
assert_eq "fixture-flags:only-one-place-names-the-unmask" "1" \
          "$(printf '%s\n' "$naming2" | grep -c . )"

# Expanding an empty array under `set -u` is fatal on bash < 4.4. Every such expansion
# must be guarded with the ${arr[@]+"${arr[@]}"} idiom.
bare="$(grep -nE '"\$\{(ARGS|RUN_ARGS|NEEDS|NEEDS_WHY|opts)\[@\]\}"' cs193v $PRIVATE/install-cs193v.sh \
        | grep -vE '\+"\$\{' || true)"
assert_eq  "bash32:empty-array-expansions-guarded" "" "$bare"

# ─── Containerfile ─────────────────────────────────────────────────────────────
# A `#` line inside a line-continued RUN is stripped by the parser today, but if that ever
# changed the comment would swallow the command after it and silently produce a broken
# image. The Containerfile documents this rule; this enforces it.
bad="$(awk '/\\$/{cont=1; next} cont && /^[[:space:]]*#/{print FILENAME":"NR": "$0} {cont=0}' $PRIVATE/Containerfile)"
assert_eq  "containerfile:no-comments-in-continuations" "" "$bad"

# ─── what the progress meter's labels depend on ────────────────────────────────
# The launcher parses this file line by line to learn what each step is called (`####>`
# markers) and to check, against the instruction podman echoes, that it is looking at the step
# it thinks it is. Everything below is a construct that would silently shift that numbering.
# None of it is used here, and forbidding it is cheaper than teaching the parser Dockerfile
# syntax this file has no reason to contain.

# HEREDOCS ARE THE DANGEROUS ONE. podman supports `RUN <<EOF`, and a line-based parse counts
# every line of the body as another instruction -- so one heredoc would misname every step
# after it, and the mismatch check would switch the labels off for the rest of the build.
bad="$(grep -nE '^[[:space:]]*(RUN|COPY|ADD)[[:space:]].*<<-?[A-Za-z_"'"'"']' $PRIVATE/Containerfile || true)"
assert_eq  "containerfile:no-heredocs" "" "$bad"

# `# escape=` changes the line-continuation character out from under the parser, which decides
# where one instruction ends and the next begins.
bad="$(grep -nE '^[[:space:]]*#[[:space:]]*escape[[:space:]]*=' $PRIVATE/Containerfile || true)"
assert_eq  "containerfile:no-escape-directive" "" "$bad"

# A backslash followed by trailing whitespace continues nothing -- docker does not treat it as
# a continuation -- but it reads exactly like one, so the parser and the human would disagree
# about how many instructions the file has.
bad="$(grep -nE '\\[[:space:]]+$' $PRIVATE/Containerfile || true)"
assert_eq  "containerfile:no-space-after-a-continuation" "" "$bad"

# A blank line inside a continuation is the one case where podman's own behaviour is not worth
# depending on, so it is forbidden rather than handled.
bad="$(awk '/\\$/{cont=1; next} cont && /^[[:space:]]*$/{print FILENAME":"NR": blank line inside a continuation"} {cont=0}' \
       $PRIVATE/Containerfile)"
assert_eq  "containerfile:no-blank-lines-in-continuations" "" "$bad"

# A marker must sit above a top-level instruction. Inside a continuation it is only a comment,
# so podman ignores it and the step it was meant to name goes unnamed.
bad="$(awk '/\\$/{cont=1; next} cont && /^[[:space:]]*####>/{print FILENAME":"NR": "$0} {cont=0}' \
       $PRIVATE/Containerfile)"
assert_eq  "containerfile:no-markers-in-continuations" "" "$bad"

# THE FIRST MARKER MUST PRECEDE FROM, or step 1 -- the base-image download, the longest part of
# a cold install -- is the one step with no name beside its bar.
first_marker="$(grep -nE '^[[:space:]]*####>' $PRIVATE/Containerfile | head -1 | cut -d: -f1)"
first_instr="$(grep -nE '^[[:space:]]*FROM[[:space:]]' $PRIVATE/Containerfile | head -1 | cut -d: -f1)"
if [ -n "$first_marker" ] && [ -n "$first_instr" ] && [ "$first_marker" -lt "$first_instr" ]; then
    pass "containerfile:a-marker-precedes-FROM"
else
    fail "containerfile:a-marker-precedes-FROM" \
         "first ####> is at line ${first_marker:-none}, FROM is at line ${first_instr:-none}"
fi

# EVERY STEP IS NAMED, checked through the launcher's own parser rather than by counting
# markers here -- a second implementation of the counting rule is exactly how the two would
# come to disagree. Markers are sticky, so this fails only when a section is added ahead of
# the first marker, which cannot happen, or when the closing marker is removed.
unnamed="$("$REPO/cs193v" --dev-steps | awk -F'\t' '$2 == "" { print $1": "$3 }')"
assert_eq  "containerfile:every-step-has-a-label" "" "$unnamed"

# The tail of the file -- ENV, USER, WORKDIR, ENTRYPOINT and the LABEL podman synthesizes from
# the launcher's --label flag -- has no marker of its own and inherits the last one. That is
# only correct if the last marker is a closing one rather than the name of a specific job, so
# a student is not told the build is "Caching the tldr pages..." while it sets WORKDIR.
last_label="$("$REPO/cs193v" --dev-steps | tail -1 | cut -f2)"
assert_eq  "containerfile:closing-marker-covers-the-tail" "Finishing up..." "$last_label"

# Whole-line comments blanked, line NUMBERS preserved, so an ordering check cannot match the
# Containerfile's own prose about the thing it is checking. Layer 2's comment contains the
# words "every `npm install -g` in this file depends on them", which is exactly that trap —
# the same one the ban-list greps at the top of this file have to dodge.
cf_code="$(sed 's/^[[:space:]]*#.*//' $PRIVATE/Containerfile)"
cf_grep() { printf '%s\n' "$cf_code" | grep -nE "$1" | head -1 | cut -d: -f1; }

# Layer order is load-bearing: podman cannot resume a partial layer download but does keep
# completed ones, so the most volatile software must come last. If claude-code moved
# earlier, every version bump would re-download node, gh and vercel too.
#
# Quote-agnostic: the install lines are wrapped in `su student -s /bin/sh -c "..."` now, so
# the package name is single-quoted inside a double-quoted string.
ln_node="$(cf_grep 'deb\.nodesource\.com')"
ln_gh="$(cf_grep 'cli\.github\.com/packages')"
ln_vercel="$(cf_grep "npm install -g [\"']vercel")"
ln_codex="$(cf_grep "npm install -g [\"']@openai/codex")"
ln_claude="$(cf_grep "npm install -g [\"']@anthropic-ai/claude-code")"
# CODEX SITS BEFORE CLAUDE CODE, and which of the two is last is a cache-cost decision rather
# than a preference. A bump re-runs its own layer plus every layer after it, and these are the two
# biggest layers in the file -- measured with `podman history`: codex 312 MB, Claude Code 298 MB.
# With codex earlier, a CLAUDE_CODE_VERSION bump -- the pin most often moved -- re-runs ~323 MB;
# with codex last, the same bump would drag codex along for ~635 MB.
if [ -n "$ln_claude" ] && [ -n "$ln_codex" ] && [ -n "$ln_vercel" ] && [ -n "$ln_gh" ] && [ -n "$ln_node" ] \
   && [ "$ln_claude" -gt "$ln_codex" ] && [ "$ln_codex" -gt "$ln_vercel" ] \
   && [ "$ln_vercel" -gt "$ln_gh" ] && [ "$ln_gh" -gt "$ln_node" ]; then
    pass "containerfile:claude-code-is-last-software-layer"
else
    fail "containerfile:claude-code-is-last-software-layer" \
         "want node < gh < vercel < codex < claude-code; got node=$ln_node gh=$ln_gh vercel=$ln_vercel codex=$ln_codex claude=$ln_claude"
fi

# EACH VERSION ARG MUST SIT NEXT TO THE LAYER THAT USES IT, never in a tidy block at the
# top of the file. This is a performance contract, and it is invisible: buildah folds every
# in-scope build arg into each step's cache key, so an ARG declared above the RUN steps
# invalidates the cache for all of them. Measured — bumping CLAUDE_CODE_VERSION with the
# ARGs at the top cost 250 s and 726 MB (18 of 23 steps re-ran); with each declared at its
# point of use, 89 s and 95 MB. Nothing breaks if someone tidies them back into a block, so
# nothing would catch it. This does. See ERRORS.md B5.
cf_lines="$(sed 's/#.*//' $PRIVATE/Containerfile)"
for pair in NODE_VERSION:nodesource PLAYWRIGHT_VERSION:playwright@ VERCEL_VERSION:vercel@ \
            CODEX_VERSION:@openai/codex@ CLAUDE_CODE_VERSION:claude-code@; do
    var="${pair%%:*}"; use="${pair#*:}"
    ln_arg="$(printf '%s\n' "$cf_lines" | grep -n "^ARG $var=" | head -1 | cut -d: -f1)"
    ln_use="$(printf '%s\n' "$cf_lines" | grep -nF "$use" | head -1 | cut -d: -f1)"
    if [ -z "$ln_arg" ] || [ -z "$ln_use" ]; then
        fail "containerfile:$var-declared-near-its-use" "could not locate ARG ($ln_arg) or use ($ln_use)"
    elif [ "$ln_arg" -lt "$ln_use" ] && [ $(( ln_use - ln_arg )) -le 12 ]; then
        pass "containerfile:$var-declared-near-its-use"
    else
        fail "containerfile:$var-declared-near-its-use" \
             "ARG $var is at line $ln_arg but is first used at line $ln_use ($(( ln_use - ln_arg )) lines later).
An ARG invalidates podman's build cache for every step below it, so declaring this one far
from its layer makes a one-line version bump cost every student a full rebuild. Move it to
sit directly above the RUN that uses it."
    fi
done

# Node is apt-managed, so `apt upgrade` inside the container can pick up security fixes —
# a tarball in /usr/local cannot be patched by anything a student runs. Authenticity comes
# from the signed repository rather than a hand-checked SHASUMS file.
assert_ok  "containerfile:node-from-signed-apt-repo" \
           grep -q 'signed-by=/etc/apt/keyrings/nodesource.asc' $PRIVATE/Containerfile
assert_ok  "containerfile:node-version-pinned-exactly" \
           grep -q 'nodejs=\${NODE_VERSION}-1nodesource1' $PRIVATE/Containerfile
assert_ok  "containerfile:node-version-asserted-at-build-time" \
           grep -q 'test "\$(node --version)" = "v\${NODE_VERSION}"' $PRIVATE/Containerfile
# Holding the package would re-create exactly the problem that moving off the tarball fixed.
assert_not_contains "containerfile:node-not-apt-mark-held" "apt-mark hold nodejs" \
                    "$(cat $PRIVATE/Containerfile)"
# No tarball left behind.
assert_not_contains "containerfile:no-node-tarball-download" "nodejs.org/dist" \
                    "$(cat $PRIVATE/Containerfile)"

# ─── the globals go in the STUDENT's npm prefix  (issue #13) ───────────────────
# Every `npm install -g` in the build must run as `student`. Installed as root they land in
# nodesource's /usr prefix while the student's is ~/.local — npm reads one prefix, so the
# tools become invisible to `npm ls -g` and updates write a second copy elsewhere on PATH.
#
# Asserted here, in milliseconds, rather than only in the image tier: reverting this costs a
# ~2 GB rebuild to discover otherwise.
for pkg in playwright vercel '@openai/codex' '@anthropic-ai/claude-code'; do
    line="$(printf '%s\n' "$cf_code" | grep -nE "npm install -g [\"']$pkg" | head -1)"
    case "$line" in
        *"su student"*) pass "containerfile:$pkg-installed-as-student" ;;
        '') fail "containerfile:$pkg-installed-as-student" "no 'npm install -g $pkg' line found" ;;
        *)  fail "containerfile:$pkg-installed-as-student" \
                 "installed as root — it must run under 'su student':
$line" ;;
    esac
done
# The prefix has to be configured BEFORE the first install, or that install silently uses
# root's and the ordering above buys nothing. Comment-stripped, or layer 2's own prose about
# `npm install -g` matches ahead of any actual install line.
ln_prefix="$(cf_grep 'npm config set prefix /home/student/\.local')"
ln_firstglobal="$(cf_grep 'npm install -g')"
if [ -n "$ln_prefix" ] && [ -n "$ln_firstglobal" ] && [ "$ln_prefix" -lt "$ln_firstglobal" ]; then
    pass "containerfile:npm-prefix-set-before-first-global-install"
else
    fail "containerfile:npm-prefix-set-before-first-global-install" \
         "want prefix < first install; got prefix=${ln_prefix:-none} first-install=${ln_firstglobal:-none}"
fi
# ~/.local/lib/node_modules must be pre-created, or `npm ls -g` on an untouched prefix exits
# 254 with ENOENT instead of printing an empty tree.
assert_ok "containerfile:student-node-modules-precreated" \
          grep -qE 'install -d -o student -g student .*/home/student/\.local/lib/node_modules' \
          $PRIVATE/Containerfile

args_live_early="$(sed 's/#.*//' $REPO/.config/container.args)"
# ─── identity: hostname, banner, title, goodbye  (issues #3 and #4) ────────────
# The hostname is the cheapest possible "you are somewhere else" signal: it lands in the
# default prompt on every line, survives nano, and costs nothing. Without it the prompt
# reads student@<random hex>, which tells a student nothing.
assert_contains "args:hostname-is-cs193v-development" "--hostname cs193v-development" \
                "$args_live_early"

assert_ok  "containerfile:installs-the-welcome-banner" \
           grep -q '20-cs193v-welcome.sh /etc/profile.d/' $PRIVATE/Containerfile
assert_ok  "containerfile:installs-bash-logout" \
           grep -qE 'bash_logout .*/home/student/.bash_logout' $PRIVATE/Containerfile

# ~/.bashrc sets the window title THROUGH PS1 and re-emits it every prompt, so a title set
# once at login is immediately overwritten. The image rewrites that one escape.
assert_ok  "containerfile:rewrites-the-bashrc-window-title" \
           grep -q 'CS193V Development Environment' $PRIVATE/Containerfile

# The banner runs INSIDE the container, which cannot reach messages.txt — only projects/ is
# mounted. So this text has to live in the image, and must not be "tidied" into messages.txt
# later, which would silently blank the banner.
#
# The TEXT lives in files/cs193v-welcome and the DECISION to print it lives in
# files/profile.d/20-cs193v-welcome.sh. They were split when tmux became the landing point:
# tmux runs the login shell in every tab, so profile.d fires per-tab, while the banner must
# appear once. The first tab gets it from cs193v-shell; profile.d now covers only the
# non-tmux path, `podman exec -it cs193v bash -l`.
# ─── the shared strings ────────────────────────────────────────────────────────
# The text the container prints is defined once, in files/cs193v-strings.sh, and read by
# the scripts that print it AND by this suite (lib/assert.sh sources it). So these check the
# DEFINITIONS are present and non-empty; the checks further down then use the values rather
# than repeating them, and rewording a string no longer reddens tests in three tiers.
assert_ok  "strings:file-exists" test -f $PRIVATE/files/cs193v-strings.sh
assert_ok  "strings:syntax"      sh -n $PRIVATE/files/cs193v-strings.sh
assert_ne  "strings:title-is-defined"   "" "${CS193V_TITLE:-}"
assert_ne  "strings:welcome-is-defined" "" "${CS193V_WELCOME:-}"
assert_ne  "strings:goodbye-is-defined" "" "${CS193V_GOODBYE:-}"
assert_ok  "containerfile:installs-the-strings" \
           grep -q 'cs193v-strings.sh  */etc/cs193v/strings.sh' $PRIVATE/Containerfile

assert_ok  "welcome:script-exists" test -f $PRIVATE/files/cs193v-welcome
# The script must SOURCE the shared definitions rather than carry its own copy, or the two
# drift and the tests go on passing against text nobody sees.
assert_contains "welcome:reads-the-shared-strings" '/etc/cs193v/strings.sh' \
                "$(cat $PRIVATE/files/cs193v-welcome)"
assert_contains "welcome:has-the-welcome-line" 'CS193V_WELCOME' \
                "$(cat $PRIVATE/files/cs193v-welcome)"
assert_not_contains "welcome:text-is-NOT-in-$PRIVATE/messages.txt" "$CS193V_WELCOME" \
                    "$(cat $PRIVATE/messages.txt)"

# THE SAME RULE, for setup-git's prose. It runs in the container too, so its catalogue is a
# separate file installed into the image — and the tidy-looking mistake is to fold those keys into
# messages.txt, where the container cannot read them and every screen would render
# "(missing message: ...)". Checked in both directions: no key of one file is defined in the other.
sgkeys="$(grep -oE '^\[\[[a-z0-9._-]+\]\]' $PRIVATE/files/setup-git-messages.txt | LC_ALL=C sort -u)"
lkeys="$(grep -oE '^\[\[[a-z0-9._-]+\]\]' $PRIVATE/messages.txt | LC_ALL=C sort -u)"
assert_ne "setup-git:catalogue-has-keys" "" "$sgkeys"
both="$(printf '%s\n' "$sgkeys" | grep -xF -f <(printf '%s\n' "$lkeys") | tr '\n' ' ')"
if [ -z "$both" ]; then
    pass "setup-git:catalogues-do-not-overlap"
else
    fail "setup-git:catalogues-do-not-overlap" "defined in BOTH catalogues: $both
A key name means two different things then, which is not wrong at runtime -- each script reads
its own file -- but it is wrong for anyone reading either one, and it is wrong for the tests:
assert_says_key defaulted to the launcher's catalogue and asserted the wrong prose until
msg_text learned to take a file. Rename one of them."
fi
# And setup-git must not reach for the launcher's file, which would work on the host and be empty
# in the image -- the exact shape of bug the welcome banner's rule exists to prevent.
assert_not_contains "setup-git:does-not-read-messages.txt" "private/messages.txt" \
                    "$(cat $PRIVATE/files/setup-git)"
# [3J clears the SCROLLBACK too, which is what "prior commands are no longer visible" means.
assert_contains "welcome:clears-scrollback-not-just-screen" '[3J' \
                "$(cat $PRIVATE/files/cs193v-welcome)"
assert_ok  "welcome:syntax" sh -n $PRIVATE/files/cs193v-welcome

assert_ok  "welcome:hook-exists" test -f $PRIVATE/files/profile.d/20-cs193v-welcome.sh
# Interactive-only, matching 10-cs193v-shell.sh, so `podman exec cs193v <cmd>` and every
# non-interactive call in this suite stay silent.
assert_contains "welcome:guards-on-interactive-shell" 'case $- in' \
                "$(cat $PRIVATE/files/profile.d/20-cs193v-welcome.sh)"
# The $TMUX guard is what keeps the banner out of every new tab. Without it, CTRL+T clears
# the pane and greets again, which is the failure the split above exists to prevent.
assert_contains "welcome:hook-skips-inside-tmux" 'TMUX' \
                "$(cat $PRIVATE/files/profile.d/20-cs193v-welcome.sh)"
assert_ok  "welcome:hook-syntax" sh -n $PRIVATE/files/profile.d/20-cs193v-welcome.sh

assert_ok  "logout:script-exists" test -f $PRIVATE/files/cs193v-goodbye
assert_contains "logout:reads-the-shared-strings" '/etc/cs193v/strings.sh' \
                "$(cat $PRIVATE/files/cs193v-goodbye)"
assert_contains "logout:says-goodbye" 'CS193V_GOODBYE' "$(cat $PRIVATE/files/cs193v-goodbye)"
assert_ok  "logout:syntax" sh -n $PRIVATE/files/cs193v-goodbye
assert_ok  "logout:hook-exists" test -f $PRIVATE/files/bash_logout
# Same reason as the banner: .bash_logout fires once per TAB inside tmux, so the farewell
# would print into a pane that is closing, for something the student has not left.
assert_contains "logout:hook-skips-inside-tmux" 'TMUX' "$(cat $PRIVATE/files/bash_logout)"
assert_ok  "logout:hook-syntax" sh -n $PRIVATE/files/bash_logout

# ─── man  (issue #8) ───────────────────────────────────────────────────────────
# Manual pages are deliberately absent and tldr stands in, but Ubuntu's minimized base
# leaves a /usr/bin/man of its own that exits 0 and says to run `unminimize` — which a
# first-year student reads as an instruction, and which downloads hundreds of megabytes
# into a container the next --rebuild discards. Our stub replaces it.
#
# /usr/bin, not /usr/local/bin: shadowing would leave the original reachable by full path
# and to anything with a fixed PATH. If this assertion is ever "fixed" by moving the
# install to /usr/local/bin, the unminimize advice comes straight back.
assert_ok  "man:script-exists" test -f $PRIVATE/files/man
assert_ok  "man:containerfile-replaces-usr-bin-man" \
           grep -qE 'files/man +/usr/bin/man' $PRIVATE/Containerfile
# grep, not assert_not_contains: its needle is matched literally, so a `*` in it would
# assert nothing at all rather than acting as a wildcard.
assert_fail "man:not-shadowed-from-usr-local" \
            grep -qE 'files/man +/usr/local/bin' $PRIVATE/Containerfile
man_stub="$(cat $PRIVATE/files/man)"
assert_contains "man:points-at-tldr"      'tldr'   "$man_stub"
assert_contains "man:stub-exits-nonzero"  'exit 1' "$man_stub"
# The one word that must never reach a student from this container.
assert_not_contains "man:never-says-unminimize" "unminimize" "$(sed 's/#.*//' $PRIVATE/files/man)"
# And the build refuses an image whose `man git` still carries the base image's advice, so
# a base-image change that reinstates it fails CI rather than a student.
assert_ok  "man:build-checks-the-stub-took" \
           grep -q 'man git 2>&1 | grep -F unminimize' $PRIVATE/Containerfile

# ─── ssh, scp and telnet  (issue #2) ───────────────────────────────────────────
# These are course tools: logging into a remote machine, copying a file across, and typing
# an HTTP request at a web server by hand. They are named on the apt line rather than
# arriving as a dependency of something else — `ssh` and `scp` were in the image for a year
# only because openssh-server Depends on openssh-client, which is not a promise. If the
# tunnel ever stopped needing sshd, they would vanish and the only symptom would be a lab
# exercise that no longer works.
apt_line="$(sed -n '/^RUN apt-get update/,/rm -rf \/var\/lib\/apt\/lists/p' $PRIVATE/Containerfile)"
assert_contains "net:openssh-client-named-explicitly" "openssh-client" "$apt_line"
assert_contains "net:telnet-installed"                "inetutils-telnet" "$apt_line"
# `telnet` on Ubuntu 26.04 is a transitional dummy whose whole content is a dependency on
# inetutils-telnet, and transitional packages get removed. Naming it would work today and
# break on some future release for a reason nobody would connect to this line.
assert_not_match "net:not-the-transitional-telnet-package" \
                 '(^|[[:space:]])telnet([[:space:]]|\\|$)' "$apt_line"

# ─── Python: the floor, and nothing above it  (issue #44) ──────────────────────
# The image ships an interpreter and the means to install libraries, not the libraries. These
# four assertions pin that shape, because every one of them would fail silently: a student
# would still get a working `python3` and only find out later, mid-assignment.
#
# python3-dev is the half of the compiler story pip cannot download. build-essential is already
# on this line; without the headers a source build dies at `fatal error: Python.h: No such file
# or directory` — verified against psutil, which compiles once they are there.
assert_contains "python:dev-headers-named-explicitly" "python3-dev" "$apt_line"
# python3-venv, for the reason openssh-client is named just above: it is in the image
# today only because pipx Depends on it, and a dependency is not a promise. `python3 -m venv` is
# what pip's own externally-managed error tells a student to reach for.
assert_contains "python:venv-named-explicitly"        "python3-venv" "$apt_line"
# numpy was REMOVED, and re-adding it has to be a test failure rather than a quiet return to the
# mixed state: one apt-managed library beside a pip-installed set means `pip list` reports a
# version pip cannot upgrade in place, and `pip install -U numpy` leaves apt's copy shadowed but
# still on disk. If a library set is ever wanted, it belongs in a pip layer, not on this line.
assert_not_contains "python:no-apt-managed-libraries" "python3-numpy" "$apt_line"
# setuptools is absent on purpose — PEP 517 build isolation downloads its own backend, and
# Debian de-vendors setuptools into 11 packages. Named here so the absence is a decision.
assert_not_contains "python:no-apt-setuptools"        "python3-setuptools" "$apt_line"

# ─── tmux: the landing point ───────────────────────────────────────────────────
# `./cs193v` runs cs193v-shell, which puts the student inside tmux. These assertions cover
# the properties that are load-bearing and would fail SILENTLY: a student would still get a
# terminal, just not the locked-down one the course documents.
#
# Nothing here re-tests what the config DOES -- 65-tmux.sh drives a real tmux inside the
# container and asserts on rendered screens for that. This is the cheap tier: the files
# exist, the image installs them, and the handful of settings that no screen makes obvious
# are set.
tmux_conf="$(cat $PRIVATE/files/tmux/tmux.conf)"

assert_ok  "tmux:conf-exists"    test -f $PRIVATE/files/tmux/tmux.conf
assert_ok  "tmux:tabname-exists" test -f $PRIVATE/files/tmux/tabname.bash
assert_ok  "tmux:tabname-syntax" bash -n $PRIVATE/files/tmux/tabname.bash
# Every course tool must be ON the label list, and this is a grep rather than a behavioural test
# on purpose: the MECHANISM is already proven behaviourally in the tmux harness ("claude is
# labeled 'claude', not 'node'", "setup-git is labeled 'setup-git', not 'bash'"), so what is
# left to catch is a tool quietly dropping off the list.
#
# WHICH ENTRIES ARE LOAD-BEARING, measured in the image rather than assumed: `codex` and
# `vercel` install as `#!/usr/bin/env node` scripts and `setup-git` is a bash script, so /proc
# reports the INTERPRETER for all three, so without their entries those tabs would read `node`,
# `node` and `bash`. This
# comment used to name `claude` and `codex` as that pair; `claude`'s bin is a 297 MB native ELF
# now and reports `claude` on its own, and `gh` is a native ELF too. Both stay listed anyway --
# `gh` as a genuine multi-tool, `claude` because a repackaging back to a node shim would
# otherwise relabel every tab in the course. See the rationale in tabname.bash.
tabname_list="$(sed -n '/^_CS193V_SHOW_ARG=/,/"$/p' $PRIVATE/files/tmux/tabname.bash)"
for tool in claude codex gh vercel setup-git; do
    assert_match "tmux:tabname-lists-$tool" "(^|[[:space:]])$tool([[:space:]]|\"|$)" "$tabname_list"
done
assert_ok  "tmux:shell-exists"   test -f $PRIVATE/files/cs193v-shell
assert_ok  "tmux:shell-syntax"   bash -n $PRIVATE/files/cs193v-shell

assert_ok  "tmux:package-installed" \
           grep -qE '^ +tmux ncurses-term' $PRIVATE/Containerfile
# ncurses-term carries the tmux-256color terminfo entry and is only a Recommends, so
# --no-install-recommends drops it. Without it tmux does not start AT ALL, which with tmux
# as the landing point means nobody can open a shell.
assert_contains "tmux:ncurses-term-installed" "ncurses-term" "$(cat $PRIVATE/Containerfile)"

assert_ok  "tmux:containerfile-installs-conf" \
           grep -q 'tmux/tmux.conf     /etc/cs193v/tmux.conf' $PRIVATE/Containerfile
assert_ok  "tmux:containerfile-installs-tabname" \
           grep -q 'tmux/tabname.bash  /etc/cs193v/tabname.bash' $PRIVATE/Containerfile
for cmd in cs193v-shell cs193v-welcome cs193v-goodbye; do
    assert_ok "tmux:containerfile-installs-$cmd" \
              grep -qE "$cmd +/usr/local/bin/$cmd" $PRIVATE/Containerfile
done
# The hook must reach every tab, which /etc/bash.bashrc does and a tmux default-command
# does not -- that reaches tab one only, which is a silent half-working state.
assert_ok  "tmux:containerfile-wires-the-tabname-hook" \
           grep -q 'etc/cs193v/tabname.bash; fi' $PRIVATE/Containerfile
# A bad config is now a container nobody can get into, so it must fail the BUILD.
assert_ok  "tmux:containerfile-validates-the-config" \
           grep -q 'tmux -L cs193vbuild' $PRIVATE/Containerfile

# The disarm. Emptying all four tables is the whole basis of "only these actions exist";
# `unbind -a` without -T clears the prefix table alone, so each one is named.
assert_contains "tmux:no-prefix-key" "set -g prefix None" "$tmux_conf"
for tbl in prefix root copy-mode copy-mode-vi; do
    assert_contains "tmux:unbinds-$tbl" "unbind -a -T $tbl" "$tmux_conf"
done

# Six root bindings, because each of the three actions has an ALT key and a key that works
# without Meta. macOS terminals compose Option by default, so an ALT-only keymap would be
# unreachable for most of the class.
n="$(grep -cE '^bind -N ".*" +-n +(M-t|C-t|M-Left|S-Left|M-Right|S-Right) ' \
     $PRIVATE/files/tmux/tmux.conf || true)"
assert_eq  "tmux:six-root-tab-bindings" "6" "$n"
# ...and the same six inside copy mode, or the tab bar goes dead the moment the wheel is
# brushed, which is exactly when a confused student reaches for it.
n="$(grep -cE '^bind -T copy-mode (M-t|C-t|M-Left|S-Left|M-Right|S-Right) ' \
     $PRIVATE/files/tmux/tmux.conf || true)"
assert_eq  "tmux:six-copy-mode-tab-bindings" "6" "$n"
# The escape hatch out of copy mode. Without it a stray scroll leaves a dead keyboard.
#
# GUARDED, and the guard is the whole assertion. tmux's `Any` matches MOUSE events as well as
# keystrokes, so unguarded it fired on the button press that begins every selection gesture and
# scrolled the student to the bottom before they could select anything (#61). The equality form
# is asserted literally because the obvious alternative is wrong: mouse_x is 0-based, so a click
# in column 1 reports "0", which a truthiness test reads as FALSE and treats as a keystroke.
assert_contains "tmux:copy-mode-any-key-escapes" \
                'bind -T copy-mode Any if -F "#{==:#{mouse_x},}" { copy-mode -q }' "$tmux_conf"
# The + NEW TAB chip must keep working while scrolled back, for the same reason the six tab keys
# above are repeated in that table -- and it is the only route to a new tab that needs no keyboard
# at all, so it is the one that matters most. Its click resolves to the pane the mouse is over,
# which while scrolled back is a pane in copy mode; the tab LABELS need no such line, because a
# click on one resolves to that tab's own pane, which is not in a mode.
assert_contains "tmux:copy-mode-new-tab-chip" \
                "bind -T copy-mode MouseDown1StatusRight" "$tmux_conf"
# Copying while scrolled back must NOT cancel the mode. Cancelling returns the pane to the live
# screen, so the student got the right text on the clipboard and was still thrown to the bottom the
# moment they released the button -- the second half of #61, reported from a real terminal after the
# `Any` guard above had fixed the press. The no-clear form is what holds the view still.
# NO MOUSE-DRIVEN COPY PATH AT ALL, and this is the invariant that replaced two rounds of trying to
# make one work. tmux can only reach a student's clipboard through OSC 52, and a terminal is free not
# to implement that escape -- the one this course is taught from does not, measured by hand outside
# any container. So selection is the terminal's job (SHIFT+drag, which never reaches tmux) and these
# two assertions state that tmux does not attempt it: no copy commands, and no selection to copy.
# Asserted over the CODE, not the file: the config deliberately names both removed commands in prose,
# in a "what used to be here, so nobody rebuilds it by accident" note, and a whole-file grep would
# fail on the documentation of the very invariant it is checking.
conf_code="$(grep -v '^[[:space:]]*#' $PRIVATE/files/tmux/tmux.conf || true)"
assert_not_contains "tmux:no-mouse-copy-path" "copy-pipe" "$conf_code"
assert_not_contains "tmux:no-mouse-selection" "begin-selection" "$conf_code"
# ...and the gesture that used to copy has to say what does work instead. One user option, because
# six bindings display it and a student-facing string repeated six times drifts.
assert_contains "tmux:copy-hint-names-shift" 'set -g @copy-hint "TO COPY: hold SHIFT' "$tmux_conf"
# The clipboard override stays, and it is worth being clear about what it is FOR now that tmux copies
# nothing: an APPLICATION in a tab writing its own OSC 52 (claude, vim, a student's program). tmux's
# unaided write carries an EMPTY target, which xterm's ctlseqs defines as `s0` -- PRIMARY plus cut
# buffer 0 -- so those writes went somewhere Ctrl+V never reads. With this override the app's own
# target composes with the literal `c`: an app naming PRIMARY comes out as `\033]52;cp;...`, both
# selections. Measured with a pane writing `\033]52;p;...`.
#
# KEEP %p1 IN THE STRING. The form circulated everywhere drops it, and tmux then emits no clipboard
# write whatsoever rather than a wrong one -- silently. Measured both ways on a pty; see the note in
# the config and tmux-harness/clipprobe.py, the only instrument here that can see the difference.
assert_contains "tmux:osc52-names-the-clipboard" 'Ms=\\E]52;c%p1%s;%p2%s\\007' "$tmux_conf"

# destroy-unattached MUST be off. `on` (which is what the upstream prototype sets) destroys
# a session the moment its last client goes, which kills every pane and therefore every
# server a student left running -- reversing the property measured in ERRORS.md D1 and
# asserted in 70-sighup.sh.
assert_contains "tmux:destroy-unattached-is-off" "set -g destroy-unattached off" "$tmux_conf"
# Stated rather than inherited: the prototype relied on `off` being the 3.6 default, so its
# regression test passed while the config had no opinion. Scrollbars on make nano flicker.
assert_contains "tmux:scrollbars-explicitly-off" "set -g pane-scrollbars off" "$tmux_conf"
# allow-rename off swallows the shell's OSC 0, so without set-titles the window title
# silently stops naming the course.
assert_contains "tmux:sets-the-window-title" "set -g set-titles on" "$tmux_conf"
assert_contains "tmux:title-bar-says-CS193V" "$CS193V_TITLE" "$tmux_conf"
# The prototype's title bar dropped the V. Everything else in this project has it.
assert_not_contains "tmux:title-bar-not-missing-the-V" "CS193 Development" "$tmux_conf"

# -f suppresses BOTH /etc/tmux.conf and ~/.tmux.conf. Installing to /etc/tmux.conf instead
# would let a student's own ~/.tmux.conf win and re-arm a prefix key.
assert_contains "tmux:shell-names-the-config-explicitly" '-f "$CONF"' \
                "$(cat $PRIVATE/files/cs193v-shell)"
assert_contains "tmux:shell-uses-a-dedicated-socket" '-L "$SOCKET"' \
                "$(cat $PRIVATE/files/cs193v-shell)"
assert_contains "launcher:lands-on-cs193v-shell" '"$NAME" cs193v-shell' "$(cat $REPO/cs193v)"

# ─── the lifecycle: closing the terminal stops the container  (#41) ─────────────
# Four assertions used to live here, and they pinned the OPPOSITE design: reattach to an
# unattached session, prune stale clients, stamp the owning pid. All three mechanisms are gone,
# so the assertions went with them. What follows pins the shape that replaced them AND the
# deletions themselves, because the failure mode of a half-applied change here is a student's
# container left running forever with nothing attached to it.
#
# FUNCTION BODIES, not the whole file, for the exec check below. The check has to name
# open_shell specifically: what must never exec is the SESSION, because a launcher replaced by
# podman cannot run its teardown trap. A file-wide grep for `exec podman` would be answered by
# prose as readily as by code -- the warn() comment near the top of the launcher contains the
# string -- so it would pass or fail for reasons that have nothing to do with the invariant.
fn_body() {                           # fn_body NAME FILE -> that function's source
    sed -n "/^$1() {/,/^}/p" "$2"
}
launcher_src="$(cat $REPO/cs193v)"
shell_src="$(cat $PRIVATE/files/cs193v-shell)"
open_shell_body="$(fn_body open_shell $REPO/cs193v)"
# stop_container, not shell_teardown: the latter is only the once-guarded wrapper the trap uses,
# and the ordering that matters lives in the former, which --stop and the maintenance verbs
# also call. Asserting the order against the wrapper would pass while the real stop had it
# backwards.
teardown_body="$(fn_body stop_container $REPO/cs193v)"
guard_body="$(fn_body shell_teardown $REPO/cs193v)"

# THE load-bearing line. `exec` replaces the launcher with podman, so no process survives the
# shell to stop anything -- which is precisely why the old design could not have implemented
# #41 without this changing, and why it is asserted ahead of everything else here.
assert_not_contains "launcher:does-not-exec-the-shell" "exec podman" "$open_shell_body"
assert_contains "launcher:installs-the-teardown-trap" "trap shell_teardown" "$open_shell_body"
# EXIT alone is not enough: a closed window delivers HUP, and bash without a HUP trap dies
# without running the EXIT one. INT/TERM cover Ctrl-C and a kill.
for sig in EXIT HUP INT TERM; do
    assert_match "launcher:teardown-traps-$sig" "trap shell_teardown.*$sig" "$open_shell_body"
done

# ─── nothing shared is touched before the session is WON ───────────────────────
# open_shell claims the tmux session, THEN installs the trap, THEN raises the tunnel. That order
# has no runtime symptom, which is why it is asserted here: a launch that will lose the race still
# gets a shell either way, so moving ensure_tunnel back above the claim would leave every test
# green while a losing launch bound host ports it then abandoned. `podman start` is idempotent and
# the launcher's own state check is a check-then-act, so the claim is the only thing that decides
# ownership -- see files/cs193v-shell and 80-launcher-live.sh's four-way race.
# COMMENTS STRIPPED FIRST, and that is not tidiness: the prose here mentions ensure_tunnel by
# name several times, so searching the raw body finds a comment and reports the wrong line. The
# first version of this check passed with the regression in place for exactly that reason.
open_shell_code="$(printf '%s\n' "$open_shell_body" | sed 's/^[[:space:]]*#.*//')"
line_of() { printf '%s\n' "$open_shell_code" | grep -n -- "$1" | head -1 | cut -d: -f1; }
claim_at="$(line_of 'cs193v-shell --claim')"
trap_at="$(line_of 'trap shell_teardown')"
tun_at="$(line_of 'ensure_tunnel')"
att_at="$(line_of 'cs193v-shell --attach')"
if [ -n "$claim_at" ] && [ -n "$trap_at" ] && [ -n "$tun_at" ] && [ -n "$att_at" ] \
   && [ "$claim_at" -lt "$trap_at" ] && [ "$trap_at" -lt "$tun_at" ] && [ "$tun_at" -lt "$att_at" ]; then
    pass "launcher:no-setup-work-before-the-session-claim"
else
    fail "launcher:no-setup-work-before-the-session-claim" \
"open_shell must run: claim -> trap -> ensure_tunnel -> attach.
Got line numbers within the function: claim=$claim_at trap=$trap_at tunnel=$tun_at attach=$att_at
A launch that loses the claim race must not have bound host ports first."
fi
# The launcher raises the tunnel INSIDE open_shell now, not on the dispatch arm, for the same
# reason. Asserting its absence there stops it drifting back.
assert_not_contains "launcher:dispatch-does-not-raise-the-tunnel" \
                    "ensure_tunnel || true
                         open_shell" "$launcher_src"

# THE SUPERVISOR'S PID MUST BE THE LOOP'S PID, and that is a claim about one shell metacharacter.
# `podman exec ... | sup_loop` puts the loop in a SUBSHELL, so the $$ written to the pidfile names
# the PARENT -- killing it leaves the loop and the exec running. Measured before this assertion
# existed: one supervisor survived every single stop. `sup_loop < <(podman exec ...)` makes the loop
# this very process, so the tracked pid is the one whose death cascades.
# Comments stripped first: verb_supervise's own comment QUOTES the pipeline it warns against, so
# an unstripped grep matches the warning and passes with the bug in place. That exact trap already
# cost this suite one vacuous assertion.
# NOTHING IN THE SUPERVISOR'S PARSE PATH MAY EVALUATE WHAT THE CONTAINER SENT. Measured on bash
# 5.3.9 with `a[$(cmd)]` injected: $(( )), (( )), [[ -eq ]], ${v:x:y} and ${a[x]} ALL execute it.
# `case` evaluates nothing, which is why the gate is case-first -- but the gate lives in
# cs193v-ui.sh and the functions that CONSUME its output live in the launcher, so this checks the
# consumers. It has to sit down here rather than beside the other port lints: fn_body is defined
# further up this file, and placed earlier the whole block errored out with "fn_body: command not
# found" while assert_eq compared two empty strings and passed. Measured -- it did.
sup_parse="$(for f in tunnel_dyn_read_floor tunnel_dyn_forward tunnel_dyn_cancel \
                      tunnel_dyn_classify sup_log sup_publish sup_tick sup_loop; do
                 fn_body "$f" "$REPO/cs193v"
             done | sed 's/^[[:space:]]*#.*//')"
if [ -z "$sup_parse" ]; then
    fail "supervisor:the-parse-path-was-found" "fn_body returned nothing for the supervisor's
functions, so the two assertions below would compare empty strings and pass."
else
    pass "supervisor:the-parse-path-was-found"
fi
assert_not_contains "supervisor:no-double-bracket-in-the-parse-path" "[[" "$sup_parse"
assert_eq "supervisor:no-array-subscripts-in-the-parse-path" "" \
          "$(printf '%s\n' "$sup_parse" | grep -nE '\$\{[A-Za-z_][A-Za-z_0-9]*\[' || true)"

sup_body="$(fn_body verb_supervise $REPO/cs193v | sed 's/^[[:space:]]*#.*//')"
assert_not_contains "supervisor:the-loop-is-not-behind-a-pipe" "| sup_loop" "$sup_body"
assert_contains "supervisor:the-loop-reads-a-substitution" "sup_loop < <(" "$sup_body"

# AND THE WATCHER IS REAPED ON BOTH SIDES OF THE LIFECYCLE. The cascade the comment above describes
# stops at the host: the container-side watcher's writes land in a pipe buffer conmon holds open, so
# the EPIPE that should end it may never arrive. Teardown handles this by stopping the container --
# but --reset-tunnel never calls tunnel_down, so without an explicit reap each reset would strand one
# watcher and start another beside it. Measured: four accumulated across one testing session.
for f in tunnel_sup_start tunnel_sup_stop; do
    assert_contains "supervisor:$f-reaps-the-watcher" \
                    'pkill -f "cs193v-portwatch --watch"' "$(fn_body $f $REPO/cs193v)"
done

# The tunnel goes down BEFORE the container, always. remove_container documents why in full:
# an ssh client outliving its container holds every forwarded host port against a dead pipe, so the
# next tunnel can bind none of them. Asserted as an ORDER, because both lines being present
# in the wrong sequence is the bug.
assert_contains "launcher:teardown-drops-the-tunnel" "tunnel_down" "$teardown_body"
assert_contains "launcher:teardown-stops-the-container" "stop -t" "$teardown_body"
td_grep() { printf '%s\n' "$teardown_body" | grep -nE "$1" | head -1 | cut -d: -f1; }
ln_tun="$(td_grep 'tunnel_down')"; ln_stop="$(td_grep 'stop -t')"
if [ -n "$ln_tun" ] && [ -n "$ln_stop" ] && [ "$ln_tun" -lt "$ln_stop" ]; then
    pass "launcher:teardown-drops-the-tunnel-before-the-container"
else
    fail "launcher:teardown-drops-the-tunnel-before-the-container" \
         "want tunnel_down before the stop; got tunnel_down=$ln_tun stop=$ln_stop"
fi
# Reuse pm/pmq rather than a fourth hand-rolled timeout, and bound podman's OWN grace period:
# entrypoint.sh traps TERM and exits immediately, so `stop`'s default -t 10 spends seven
# seconds of headroom on a process that exits in milliseconds. -i keeps --stop idempotent.
assert_match "launcher:teardown-bounds-podmans-own-grace" 'stop -t [0-9]' "$teardown_body"
# HUP runs the handler and EXIT then runs it again, so without a guard the student gets two
# "stopping" lines for one stop.
assert_contains "launcher:teardown-runs-once" "TEARDOWN_DONE" "$guard_body"

# One session at a time. The refusal is the whole student-facing contract of #41, and its
# message has to name the way out or a force-quit strands somebody.
assert_contains "launcher:refuses-a-second-session" "err.session-in-use" "$launcher_src"
assert_contains "messages:refusal-exists" "[[err.session-in-use]]" "$(cat $PRIVATE/messages.txt)"
assert_contains "messages:refusal-names-the-way-out" "--stop" \
                "$(sed -n '/\[\[err.session-in-use\]\]/,/^\[\[/p' $PRIVATE/messages.txt)"
# The crash caveat is load-bearing prose, not decoration: without it the message asserts
# something a student with no other window open knows to be false, and they stop believing it.
assert_match "messages:refusal-admits-it-may-be-a-crash" 'crash' \
             "$(sed -n '/\[\[err.session-in-use\]\]/,/^\[\[/p' $PRIVATE/messages.txt)"
assert_contains "launcher:has-a-stop-verb" "--stop)" "$launcher_src"

# Every verb that would disturb a live session refuses first, pointing at the same --stop, so
# there is ONE way to deal with "the container is busy" rather than one per verb.
#
# ONE VERB TO CHECK, so this is unrolled rather than a loop (shellcheck SC2043). IF A SECOND
# CONTAINER-CREATING VERB IS EVER ADDED it needs its own line here: the assert_not_contains
# below is only meaningful while at least one positive assertion names this helper.
assert_contains "launcher:verb_rebuild-refuses-while-a-session-is-live" \
                "refuse_if_session_live" "$(fn_body verb_rebuild $REPO/cs193v)"
# THE WHOLE ARM, not one line of it. The bare launch's statements are spread over several lines --
# it announces itself before the first probe (issue #57) and reflowing that was enough to make a
# line-scoped match fail while the invariant it exists for was untouched. Extracted from `'')` to
# its `;;`, so an empty extraction fails this rather than passing it vacuously.
bare_arm="$(sed -n "/^    '')/,/;;/p" $REPO/cs193v)"
assert_contains "launcher:bare-launch-refuses-while-a-session-is-live" \
                "refuse_if_session_live" "$bare_arm"
# And it says so BEFORE any of them. 30-launcher-shim.sh pins the order in the output; this pins
# that the arm is where the announcement lives, so no verb inherits it and none of the checks
# above it can run first.
assert_contains "launcher:bare-launch-announces-itself" "status.entering" "$bare_arm"

# --reset-tunnel MUST NOT refuse. Its entire purpose is fixing the tunnel WHILE a session is
# live, and require_tunnel in lib/assert.sh calls it for exactly that reason, so wiring the
# refusal into it would break the one verb students are told to reach for.
#
# THE POSITIVES ABOVE ARE WHAT KEEP THIS FROM GOING VACUOUS, and that is not a hypothetical
# worry: an assert_not_contains for a name that exists nowhere passes forever and tests
# nothing, which is exactly how #34's self-matching pgrep made this suite green whatever
# happened. Rename the helper and the loop above fails loudly rather than this quietly.
assert_not_contains "launcher:reset-tunnel-is-exempt-from-the-refusal" \
                    "refuse_if_session_live" "$(fn_body verb_reset_tunnel $REPO/cs193v)"

# The deletions. Each of these strings is the whole of a mechanism that #41 removes, so its
# survival means the old design is still half-wired underneath the new one.
#
# WHOLE-LINE COMMENTS BLANKED FIRST, exactly as the Containerfile ordering checks above do it,
# and for the same reason: both scripts document what they removed, and that prose would match
# these greps and fail forever. NOT `sed 's/#.*//'` -- that also eats inline `#` inside code,
# and every tmux format string here is of the form '#{session_name}', so the broader strip would
# hide a genuinely surviving `#{@cs193v_host_pid}` instead of catching it.
launcher_code="$(sed 's/^[[:space:]]*#.*//' $REPO/cs193v)"
shell_code="$(sed 's/^[[:space:]]*#.*//' $PRIVATE/files/cs193v-shell)"
assert_not_contains "launcher:no-stale-client-pruning-left" \
                    "prune_stale_tmux_clients" "$launcher_code"
assert_not_contains "launcher:no-client-pid-plumbing-left" "CS193V_CLIENT_PID" "$launcher_code"
assert_not_contains "launcher:no-host-client-liveness-check-left" \
                    "host_client_alive" "$launcher_code"
assert_not_contains "tmux:shell-no-longer-stamps-an-owner" "@cs193v_host_pid" "$shell_code"
assert_not_contains "tmux:shell-no-longer-hunts-for-a-free-session" \
                    "session_attached" "$shell_code"
# Only one client can exist now, so a warning about having six of them can never fire.
assert_not_contains "launcher:no-many-shells-warning-left" "warn.many-shells" "$launcher_code"
assert_not_contains "messages:no-many-shells-string-left" \
                    "[[warn.many-shells]]" "$(cat $PRIVATE/messages.txt)"

# The race the state check cannot win on its own. `podman start` is idempotent and reports
# nothing (measured against podman 5.7.0), so two launches that both see `exited` both reach
# cs193v-shell -- and the tmux session name is what breaks the tie, atomically, inside the
# container where it cannot go stale across a stop. Measured: rc=1, "duplicate session: NAME".
assert_contains "tmux:shell-claims-one-fixed-session" "duplicate session" "$shell_src"
# The lost-race exit status is a CONTRACT BETWEEN TWO FILES: cs193v-shell returns it, and the
# launcher turns it into the refusal. Nothing else would notice them drifting apart, and the
# symptom would be a lost race printing cs193v-shell's "this is a fault in the container image,
# not something you did" box -- both wrong and alarming for something a student caused by
# opening a second window.
assert_contains "tmux:shell-defines-the-lost-race-status" "RACE_LOST_STATUS=3" "$shell_src"
assert_contains "launcher:agrees-on-the-lost-race-status" "RACE_LOST_STATUS=3" "$launcher_src"
# The tab-label hook arms itself once per prompt so that only the command the student typed
# can relabel. On Ubuntu 26.04 systemd's own PROMPT_COMMAND entry runs after ours and used
# to spend that arming flag, which disabled EVERY label silently -- the fallback looks
# exactly like having no hook at all. See ERRORS.md D0.
assert_contains "tmux:tabname-ignores-other-prompt-command-entries" 'PROMPT_COMMAND[@]' \
                "$(cat $PRIVATE/files/tmux/tabname.bash)"

# Since 23.04 the Ubuntu base image ships its own `ubuntu` user at uid AND gid 1000, so a
# bare `groupadd -g 1000` exits 4 with "GID '1000' already exists" and aborts the build.
# That is what stopped this image from ever building. The layer must clear 1000 first.
assert_ok  "containerfile:handles-base-image-uid-1000" \
           grep -q 'getent passwd 1000' $PRIVATE/Containerfile
assert_ok  "containerfile:handles-base-image-gid-1000" \
           grep -q 'getent group 1000' $PRIVATE/Containerfile
assert_ok  "containerfile:asserts-student-ids-at-build-time" \
           grep -q 'id -u student' $PRIVATE/Containerfile

# GIT_EDITOR must stay unset: git resolves GIT_EDITOR -> core.editor -> VISUAL -> EDITOR
# -> vi, and /usr/bin/vi is vim.tiny, which strands a novice on `git commit` with no -m.
env_block="$(sed -n '/^ENV /,/^$/p' $PRIVATE/Containerfile)"
for v in LANG EDITOR VISUAL PAGER LESS BROWSER; do
    assert_contains "containerfile:env-has-$v" "$v=" "$env_block"
done
assert_not_contains "containerfile:no-GIT_EDITOR" "GIT_EDITOR" "$(sed 's/#.*//' $PRIVATE/Containerfile)"
# HOST and FLASK_RUN_HOST are gone with the bind-0.0.0.0 rule, and must stay gone: with the
# tunnel reaching the container's loopback there is nothing for them to nudge, so all they
# could do is silently change what a student's server binds to for a reason that no longer
# exists. Comments are stripped first, or the Containerfile's own explanation of the removal
# matches itself and this passes while the ENV line is back.
env_live="$(sed 's/#.*//' $PRIVATE/Containerfile | sed -n '/^ENV /,/^$/p')"
for v in HOST FLASK_RUN_HOST; do
    assert_not_contains "containerfile:no-$v-env" "$v=" "$env_live"
done

# PIPX_HOME/PIPX_BIN_DIR must be inline on the RUN, never ENV: as ENV they persist into
# the runtime and point a student's own `pipx install` at root-owned /usr/local.
assert_not_match "containerfile:pipx-vars-not-ENV" '^ENV.*PIPX' "$(cat $PRIVATE/Containerfile)"

# PIP_BREAK_SYSTEM_PACKAGES is the exact mirror of that rule, and the reason is the same one read
# the other way round: the pipx variables must not reach the student's shell, and this one is
# useless unless it does. Without it in the ENV, `pip3 install X` and even `pip3 install --user X`
# fail with externally-managed-environment, and #44's whole complaint comes back. Comments are
# stripped first, or the Containerfile's own explanation of the variable satisfies this while the
# ENV entry itself is gone.
assert_contains "containerfile:pip-guard-is-ENV" "PIP_BREAK_SYSTEM_PACKAGES=" "$env_live"
# And it must NOT have been done by deleting Ubuntu's marker file instead: that is the same thing
# to pip, but `apt reinstall libpython3.14-stdlib` restores the file, so a stdlib security update
# mid-quarter would silently re-break pip. Verified, not assumed.
assert_not_contains "containerfile:pep668-marker-not-deleted" "EXTERNALLY-MANAGED" \
                    "$(sed 's/#.*//' $PRIVATE/Containerfile)"

assert_ok  "containerfile:runs-as-student" grep -qx 'USER student' $PRIVATE/Containerfile

# The bind mount lands at ~/projects, INSIDE $HOME alongside the five credential volumes.
# The target must be pre-created student-owned in the image: podman auto-chowns an empty
# named volume, but a bind mount onto a missing directory gets created root-owned, and then
# nothing the student runs can write to their own work.
assert_ok  "containerfile:precreates-the-projects-mount-student-owned" \
           grep -qE 'install -d -o student -g student .*/home/student/projects' $PRIVATE/Containerfile
assert_ok  "containerfile:workdir-is-the-projects-mount" \
           grep -qx 'WORKDIR /home/student/projects' $PRIVATE/Containerfile
# The old path must be gone, not merely shadowed — two directories would be worse than one
# wrong one, because the docs would be right about a directory nobody is standing in.
assert_not_contains "containerfile:no-stale-workspaces-path" "/workspaces" \
                    "$(cat $PRIVATE/Containerfile)"

# WORKDIR, the launcher's -w and the mount destination must all name the same directory, or
# the student's shell opens somewhere other than their files.
wd="$(sed -n 's/^WORKDIR //p' $PRIVATE/Containerfile | head -1)"
assert_eq "launcher:mount-destination-matches-WORKDIR" "$wd" \
          "$(sed -n 's/^MOUNT_DST="\(.*\)"/\1/p' cs193v | head -1)"

# config_hash decides whether an existing container is stale. It must cover the mount
# DESTINATION, not just the source: when this moved from /workspaces to ~/projects, every
# container already on a student machine would otherwise have kept the old mount silently,
# because the destination was a constant baked into build_run_args and never hashed.
assert_contains "launcher:confighash-covers-the-mount-destination" "MOUNT_DST" \
                "$(sed -n '/^config_hash()/,/^}/p' cs193v)"


# ─── container.args invariants ──────────────────────────────────────────────────
# The block at the top of container.args lists these as "never add any of these". Host
# isolation comes from the user namespace, and each of these punches through it.
args_live="$(sed 's/#.*//' $REPO/.config/container.args)"
for bad_flag in --privileged --cap-add=SYS_ADMIN --cap-add=SYS_PTRACE --network=host \
                --pid=host --ipc=host --userns=host seccomp=unconfined unmask=ALL \
                label=disable docker.sock podman.sock; do
    assert_not_contains "invariant:no-$bad_flag" "$bad_flag" "$args_live"
done

# Each of these was considered and rejected for a documented reason; re-adding one should
# be a deliberate act that breaks a test, not a quiet edit.
for rejected in --memory-swap --init --tmpfs --pids-limit --cpus --shm-size \
                host-lo-to-ns-lo '-t,auto'; do
    assert_not_contains "rejected:no-$rejected" "$rejected" "$args_live"
done

# :Z relabels recursively and can break unrelated host services; the launcher adds :z
# narrowly and only where SELinux is enforcing.
assert_not_match "invariant:no-Z-relabel" ',Z' "$args_live"

assert_contains "args:userns-explicit-uid-gid" "--userns=keep-id:uid=1000,gid=1000" "$args_live"

# Every volume container.args CREATES must be one `--rebuild --logout` REMOVES. Two lists in two
# files -- the `-v cs193v-NAME:` lines here, and the `for v in ...` inside remove_volumes --
# and a name in one but not the other leaks a volume --logout silently keeps.
#
# This is a grep, which this file otherwise avoids when a behavioural test proves the same
# thing. Nothing here duplicates one. 30-launcher-shim.sh counts the `volume rm` calls
# `--rebuild --logout` makes, which proves the launcher removes the volumes IT KNOWS ABOUT — it
# compares remove_volumes against the shim's own expectation, never against container.args,
# so a volume added to container.args alone passes it. MANUAL.md §2.4 is the only end-to-end
# check and it is deliberately human, because the honest automated version would delete a
# developer's real logins. That gap is what this grep covers.
args_vols="$(printf '%s\n' "$args_live" \
    | sed -n 's/.*-v cs193v-\([A-Za-z0-9_-]*\):.*/\1/p' | LC_ALL=C sort | tr '\n' ' ')"
launcher_vols="$(sed -n 's/^[[:space:]]*for v in \(.*\); do$/\1/p' cs193v \
    | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort | tr '\n' ' ')"
assert_eq "volumes:launcher-removes-every-volume-args-creates" "$args_vols" "$launcher_vols"
assert_contains "args:network-pasta"           "--network=pasta"                    "$args_live"

# ─── load_args pays for content, not for lines  (issue #57) ────────────────────
# container.args is 239 lines of which 228 are a comment or blank, and load_args used to trim
# each one with a `sed` in a command substitution BEFORE testing whether the line held anything:
# 239 forks, ~700ms of the launcher's ~1.8s startup. The order is the whole fix, so it is the
# thing to assert.
#
# 16-args-parse.sh proves the COST behaviourally, by counting sed calls through a shim, which is
# the stronger test. This grep is here for the case that one cannot see: a rewrite that keeps the
# fork count at 11 for today's file while putting the guard somewhere it no longer dominates. The
# order is the invariant; the count is a consequence of it.
#
# Read out of the FUNCTION BODY, not the file, so line numbers cannot drift with edits elsewhere,
# and the patterns are specific enough that the function's own comments — which discuss both the
# guard and the retired `[ -z ]` test — cannot match them.
la_body="$(awk '/^load_args\(\) \{/ { f = 1 } f { print } f && /^}/ { exit }' cs193v)"
la_guard="$(printf '%s\n' "$la_body" | grep -n 'case "\$line" in \*\[!\[:space:\]\]\*)' | head -1 | cut -d: -f1)"
la_trim="$( printf '%s\n' "$la_body" | grep -n "sed -e 's/\^\[\[:space:\]\]\*//'"      | head -1 | cut -d: -f1)"
assert_ne "load_args:body-was-found"    ""  "$la_body"
assert_ne "load_args:has-content-guard" ""  "$la_guard"
assert_ne "load_args:has-a-trim"        ""  "$la_trim"
if [ -n "$la_guard" ] && [ -n "$la_trim" ]; then
    assert_eq "load_args:guard-precedes-the-trim" "yes" \
        "$([ "$la_guard" -lt "$la_trim" ] && printf yes || printf no)"
fi
# A whitespace test, not an emptiness test: `[ -z "$line" ]` here would skip only the lines that
# are already empty, so indenting that comment block — a reflow, not a semantic edit — would put
# all 239 forks back. 16-args-parse.sh has the case that catches it.
assert_not_match "load_args:guard-is-not-an-emptiness-test" \
    '\[ -z "\$line" \] && continue' "$(printf '%s\n' "$la_body" | sed 's/#.*//')"

# ─── forwarded ports ───────────────────────────────────────────────────────────
# A -p line does not merely duplicate the tunnel, it BREAKS it. Both bind host
# 127.0.0.1:<port>, so whichever loses the race gets EADDRINUSE — and podman wins, because
# the container is created before the tunnel starts, which means re-adding a -p line here
# silently costs the student that port entirely. This is the strongest of the port
# invariants and it replaced the old "every -p must be loopback-prefixed" check: with no -p
# lines at all, the host side is loopback by construction, because the ssh client binds
# 127.0.0.1 itself.
published="$(printf '%s\n' "$args_live" | grep -E '^\s*-p( |$)' || true)"
assert_eq  "ports:no-p-lines-they-would-break-the-tunnel" "" "$published"

# THE ARGS FILE DECLARES NO PORTS AT ALL, and that is now the invariant rather than a property of
# whatever it declared. There is no list to count, no privileged entry to reject and no AirPlay
# collision to avoid, because nothing here chooses ports: the launcher's supervisor forwards what
# the container turns out to be listening on. ports:count-is-47, its no-privileged-no-airplay
# sibling and ports:codex-login-callback-is-forwarded all went with the list they were about.
#
# WHAT REPLACES THEM IS THE ABSENCE, asserted, because a -e CS193V_PORTS line coming back would
# not fail anything on its own -- nothing reads it -- and would quietly reintroduce the second
# source of truth this change exists to remove. Someone re-adding one is made to come here.
assert_eq "ports:no-port-list-is-declared" "" \
          "$(printf '%s\n' "$args_live" | grep -E 'CS193V_PORTS' || true)"

# ports:CS193V_PORTS-matches--p-lines is DELETED, not rewritten. It guarded the agreement
# between CS193V_PORTS and a parallel set of -p lines; deriving the forwards from
# CS193V_PORTS makes that disagreement structurally impossible, so there is nothing left to
# assert. Enforcing an invariant by construction beats enforcing it by test.

# ports:CLAUDE.md-matches-CS193V_PORTS is DELETED, and nothing replaces it.
#
# By decision, NOTHING asserts on the CONTENT of the managed CLAUDE.md. Two attempts were made
# and both removed: an equality check against the port list, and a subset check over whatever
# ranges the prose still named. Both punish ordinary rewording — a correct edit that happens
# not to match the pattern fails the suite — and a test that fires on correct changes trains
# people to delete it rather than heed it, which is worse than not having it.
#
# What guards that file instead: it is short enough to read in full, and a human reads it. The
# suite still checks that it EXISTS and is readable in the image (50-image.sh), which is the
# part a machine can judge.

# ─── the tunnel's invariants ───────────────────────────────────────────────────
# Only the ones with NO behavioural equivalent are checked here. Six greps that used to live in
# this section were removed because a real test already proved the same thing, and a grep whose
# only job is to restate what a behavioural test proves is pure brittleness -- it breaks on
# refactors and buys nothing:
#
#   -R / RemoteForward in the launcher, and AllowTcpForwarding local in the config
#       -> 80-launcher-live.sh :: tunnel:remote-forward-is-refused actually attempts a remote
#          forward and asserts it is refused with zero listeners created.
#   PermitOpen 127.0.0.1:*
#       -> tunnel:cannot-proxy-off-box actually forwards to an off-box address and asserts the
#          connection fails.
#   ClearAllForwardings
#       -> ports:every-forward-is-on-the-host would find 0 forwards if they had been cleared.
#   remove_container calling tunnel_down
#       -> tunnel:releases-its-ports-when-the-container-dies and tunnel:comes-back-after-a-
#          rebuild cover the consequence, which is what actually matters.
#
# What is left below either has no runtime symptom to test, or is a build-time structural fact.
launcher_live="$(sed 's/#.*//' $REPO/cs193v)"
assert_not_contains "tunnel:no-agent-forwarding" "ForwardAgent=yes" "$launcher_live"
# -F none, or the student's own ~/.ssh/config could redirect or decorate the connection. No
# runtime symptom: it only shows up on a machine whose ssh config happens to interfere.
assert_contains "tunnel:ignores-the-users-ssh-config" "-F none" "$launcher_live"
# setsid(1) does not exist on macOS, so backgrounding must go through nohup. The symptom would
# only appear on a Mac, which this suite cannot reach.
assert_contains "tunnel:uses-nohup-not-setsid" "nohup ssh" "$launcher_live"
assert_not_match "tunnel:no-setsid" '(^|[[:space:]])setsid[[:space:]]' "$launcher_live"

sshd_conf="$(sed 's/^#.*//' $PRIVATE/files/sshd_config)"
assert_contains "sshd:no-agent-forwarding"        "AllowAgentForwarding no"  "$sshd_conf"
assert_contains "sshd:no-x11"                     "X11Forwarding no"         "$sshd_conf"
assert_contains "sshd:no-passwords"               "PasswordAuthentication no" "$sshd_conf"
assert_contains "sshd:no-root-login"              "PermitRootLogin no"       "$sshd_conf"
# ONE authorized_keys path, not OpenSSH's default pair. A writable authorized_keys2 would let
# the container grant inbound access to itself.
assert_not_contains "sshd:no-second-authorized-keys-file" "authorized_keys2" "$sshd_conf"

# The image must carry the server, pre-create ~/.ssh student-owned, and validate the config at
# build time. ~/.ssh is load-bearing and was measured, not guessed: without it podman creates
# the bind mount's parent as ROOT (verified root:root 0755), which would lock a student out of
# writing their own keys there.
cf="$(cat $PRIVATE/Containerfile)"
assert_contains "sshd:image-installs-openssh-server" "openssh-server" "$cf"
assert_contains "sshd:image-precreates-dot-ssh" \
                "install -d -o student -g student -m 0700 /home/student/.ssh" "$cf"
assert_contains "sshd:config-is-validated-at-build-time" "sshd -t -f /etc/ssh/cs193v_sshd_config" "$cf"
# A host key baked into the image would be one private key shipped to every student.
assert_match "sshd:build-time-host-key-is-deleted" \
             'rm -f /etc/ssh/cs193v_host_ed25519_key' "$cf"

# ─── the tldr cache must not be able to fail silently  (#9) ────────────────────
# `man` is deliberately absent, so tldr IS the command-line help. The build step that
# populates its cache ended in `|| true`, which means a network hiccup during a CI build
# would ship an image with NO help at all and nothing would report it. The build must fail
# loudly instead.
tldr_layer="$(sed -n '/tldr --update/p' $PRIVATE/Containerfile)"
assert_not_contains "tldr:build-does-not-swallow-failure" "|| true" "$tldr_layer"
assert_contains "tldr:build-asserts-the-cache-is-populated" "cache/tldr" \
                "$(sed -n '/tldr --update/,+3p' $PRIVATE/Containerfile)"

# ─── documented claims must be true  (#11, #12, #14) ───────────────────────────
# A comment that promises behaviour which does not exist is worse than no comment: the next
# person to edit this section will rely on it. container.args claimed `cs193v doctor` warns when
# the port list and the -p lines disagree. verb_doctor never compared them, and there is no list
# to disagree with now -- but the section is still the natural place for someone to write a claim
# about what doctor does, so the guard stays and is retargeted at the section as it now stands.
assert_not_contains "claims:no-phantom-doctor-ports-warning" "doctor" \
                    "$(sed -n '/─── Environment/,/^# ═══/p' $REPO/.config/container.args)"

# CONTAINER-DESIGN.md said "macOS and Windows are case-insensitive". On Windows this design
# puts projects/ inside the WSL distro's ext4 home, which IS case-sensitive -- and the doc
# gives that very path a few lines later.
assert_not_contains "claims:windows-not-called-case-insensitive" \
                    "macOS and Windows are case-insensitive" "$(cat $PRIVATE/CONTAINER-DESIGN.md)"

# INVERTED BY #41. This used to require the doc to state the Linux measurement that closing a
# window does NOT stop a server. That is no longer the behaviour, so the old promise must be gone
# and the new one present.
#
# Both halves are asserted, and the negative is the one that matters: a doc which added the new
# claim while leaving the old paragraph somewhere else would be actively worse than one that had
# not been updated at all, and nothing else would catch it.
#
# Checked for the DIRECTION of the claim rather than for the topic being mentioned. The old check in
# 70-sighup.sh looked only for the phrase "terminal window" and stayed green through a complete
# reversal of what the doc said about it, which is how a documentation test survives the thing it
# exists to catch.
design_md="$(cat $PRIVATE/CONTAINER-DESIGN.md)"
assert_not_contains "claims:no-stale-promise-that-work-survives-a-closed-window" \
                    "does not stop a server" "$design_md"
assert_not_contains "claims:no-stale-promise-of-tabs-coming-back" \
                    "back in the same tabs" "$design_md"
assert_contains "claims:closing-the-window-is-documented-as-stopping-things" \
                "Closing your terminal window stops the container" "$design_md"
# The COST has to be stated, not glossed. An accidental close is unrecoverable where the old design
# handed everything back, and a doc that says only "it stops" undersells what a student loses.
assert_match "claims:the-lost-work-cost-is-stated" 'unsaved' "$design_md"
# ...and the way out of a refusal, since that is the one message a student is guaranteed to hit.
assert_contains "claims:the-stop-verb-is-documented" "cs193v --stop" "$design_md"

# ─── .gitignore ────────────────────────────────────────────────────────────────
# -F, not -x alone: `projects/*` as a BRE is "project" + "s" + zero-or-more "/".
assert_ok  "gitignore:local.args-is-ignored" grep -qxF '.config/local.args' .gitignore
assert_ok  "gitignore:projects-contents" grep -qxF 'projects/*' .gitignore
assert_ok  "gitignore:keeps-gitkeep"     grep -qxF '!projects/.gitkeep' .gitignore
assert_file "gitignore:gitkeep-exists"   "$REPO/projects/.gitkeep"
# The bind-mount target must exist in a fresh clone or the mount creates a root-owned dir.
assert_ok  "gitignore:gitkeep-is-tracked" git -C "$REPO" ls-files --error-unmatch projects/.gitkeep
# local.args holds one machine's memory cap; committing it would ship it to everyone.
assert_ok  "gitignore:local.args-not-tracked" \
           sh -c "! git -C '$REPO' ls-files --error-unmatch $REPO/.config/local.args >/dev/null 2>&1"

# The tunnel's PRIVATE KEYS. These are generated per machine precisely so that no keypair is
# shared, and committing one would hand it to every student and every reader of the repo --
# undoing the entire reason the host key is not baked into the image. Asserted by asking git
# itself rather than by grepping .gitignore, so any spelling that actually works passes and
# any that silently does not fails.
for f in tunnel-key tunnel-key.pub tunnel-host-key tunnel-host-key.pub tunnel-known-hosts; do
    assert_ok "gitignore:$f-is-ignored" \
              git -C "$REPO" check-ignore -q ".config/$f"
    assert_ok "gitignore:$f-not-tracked" \
              sh -c "! git -C '$REPO' ls-files --error-unmatch '.config/$f' >/dev/null 2>&1"
done

# ─── Claude Code policy ────────────────────────────────────────────────────────
# ONE SPELLING OF THE PATH, which every check below is handed. Three of them used to build a
# command substitution around `files/claude-code/managed-settings.json` RELATIVE to the repo
# root; #16 moved files/ under .private/ and updated one of the four copies. The suite does not
# run from .private/, so the other three raised FileNotFoundError on every run since c723f6b,
# the substitution yielded the empty string, and each assertion then measured nothing:
# `assert_eq "" ""` passes, and so does `assert_not_contains <needle> ""` -- the vacuous-pass
# trap lib/assert.sh documents for the negative form. Verified with #73's three mutants (a
# Write() deny rule, and each forbidden key added at top level): all three survived.
#
# A FOURTH COPY OF THAT PATH IS WHAT MADE A FOURTH COPY OF THE BUG CHEAP, so there is one.
managed="$PRIVATE/files/claude-code/managed-settings.json"
# The notes are the other file this section reaches for, and they get the same treatment:
# one spelling, handed to whatever needs it.
NOTES="$PRIVATE/files/agent-notes.md"
assert_ok  "claude:managed-settings-is-valid-json" \
           python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$managed"

# EVERY DERIVED CHECK ANSWERS WITH A SENTINEL WHEN IT IS HAPPY, never with the empty string,
# because the empty string is also what a crashed python3 leaves behind and no assertion can
# tell those two apart. `rules-ok` here is the spelling 50-image.sh's sibling check already
# uses on the same file inside the image; the two now agree rather than nearly agreeing.
#
# THE PATH ARRIVES AS argv, not interpolated into the program text: $PRIVATE is a real
# directory path and a course folder is allowed an apostrophe in it, which would end the
# quoting and turn a policy check into a syntax error.
#
# Write(...) and Glob(...) path rules are accepted and then silently ignored with a
# startup warning. A security control that does nothing is worse than none.
#
# INDEXED, NOT `.get`, AND AN EMPTY LIST IS NOT "ok" -- both halves measured (#79). This read
# `d.get("permissions", {}).get("deny", [])`, so "every rule in the list is well formed" was
# satisfied by there being no list: with `"deny": []` injected -- Claude Code granted unrestricted
# read of every credential store in the image -- this printed `rules-ok` and passed, and so did
# it with `permissions` or `deny` renamed. Indexing turns a missing key into a traceback, which
# the guard idiom on this statement reports; emptiness has to be asked about separately, because
# an empty list is perfectly well formed and means the opposite of what this assertion claims.
bad_rules="$(python3 -c '
import json, sys
rules = json.load(open(sys.argv[1]))["permissions"]["deny"]
bad = [x for x in rules if not x.startswith(("Read(", "Edit("))]
if not rules:
    print("NO-DENY-RULES: the deny list is empty, so this document denies nothing")
else:
    print("BAD:" + ",".join(bad) if bad else "rules-ok")
' "$managed" 2>&1)" || bad_rules="the check itself failed: $bad_rules"
assert_eq  "claude:deny-rules-are-Read-or-Edit-only" "rules-ok" "$bad_rules"

# requiredMinimumVersion/requiredMaximumVersion cause a hard startup exit, which combined
# with a pinned image can manufacture a container that refuses to start at all.
#
# ASKED OF THE DOCUMENT'S KEYS -- not of the permissions subtree, and not of the file's text.
# Both are TOP-LEVEL settings, as the file's own $comment says, so ["permissions"] was the wrong
# subtree even once the path was right: with the key added at top level the check still could not
# see the thing it forbids. And the text cannot be searched instead, because that same $comment
# names both keys in its "NEVER add these" prose -- a grep over the document would fail on the
# very comment that documents the rule. A setting IS a key, so keys are what this reads, walked
# recursively so a nested section cannot hide one, and matched as a whole key rather than as a
# substring.
#
# AND IT SAYS "absent" RATHER THAN SAYING NOTHING. This is the shape the whole group had wrong:
# an assertion whose happy answer is the empty string is an assertion that a crash also
# satisfies, so assert_not_contains is the wrong verb here no matter how good the path is. A
# document with no `permissions` key is reported as not understood rather than as clean, which
# is the one reading under which "I could not find it" can never mean "it is not there".
for forbidden in requiredMinimumVersion requiredMaximumVersion; do
    assert_eq "claude:no-$forbidden" "absent" "$(python3 -c '
import json, sys
def walk(node):
    if isinstance(node, dict):
        for k, v in node.items():
            yield k
            for x in walk(v): yield x
    elif isinstance(node, list):
        for v in node:
            for x in walk(v): yield x
keys = list(walk(json.load(open(sys.argv[1]))))
if "permissions" not in keys:
    print("UNREADABLE: no permissions key, so this document was not understood")
else:
    print("PRESENT as a setting key" if sys.argv[2] in keys else "absent")
' "$managed" "$forbidden")"
done

# THE FULLSCREEN RENDERER (#77), and the one env var that makes it safe here.
#
# Claude Code ships two renderers. The classic one draws on the MAIN screen and never asks for
# mouse reporting, so all three terms of tmux's wheel guard -- alternate_on, pane_in_mode,
# mouse_any_flag (files/tmux/tmux.conf:195) -- are false, and the wheel scrolls TMUX instead of
# the agent. Measured in the container against a logged-in session: classic gives
# `alt=0 mouse=0`, `tui: fullscreen` gives `alt=1 mouse=1`.
#
# READ AS A KEY rather than grepped, for exactly the reason the two forbidden keys above are:
# this file's own $comment prose names the value, so a text search would pass on the comment
# that documents the setting.
assert_eq "claude:tui-is-fullscreen" "fullscreen" "$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1])).get("tui", "ABSENT"))
' "$managed")"

# CLAUDE_CODE_DISABLE_MOUSE_CLICKS IS PART OF THE SAME FIX AND MUST NOT BE SEPARATED FROM IT.
#
# The fullscreen renderer turns on `copyOnSelect`, which defaults to TRUE, and a drag inside it
# then writes the selection out over OSC 52. Measured: the toast reads "copied N chars to tmux
# buffer - paste with <prefix>p", and this configuration sets `prefix None` -- so the student is
# told to press a key that does not exist, about text they cannot reach. That is the failure #61
# deleted tmux's own copy path over, arriving by a different door.
#
# The variable is MISNAMED and the name is the trap: it does not disable clicks. It switches
# Claude Code's tracking from `?1000h ?1002h ?1003h ?1006h` to `?1000h ?1006h`, so button
# press/release is still reported -- clicking a link or a button in the agent still works, which
# is what tmux.conf's MouseDown1Pane binding exists for -- and only MOTION is dropped. Measured
# both ways: the wheel guard still sees mouse_any_flag=1, and a drag and a double-click each
# produce zero paste buffers and no toast.
assert_ok "claude:drag-selection-is-off-in-the-image" \
          grep -q 'CLAUDE_CODE_DISABLE_MOUSE_CLICKS=1' $PRIVATE/Containerfile

# ONE FILE, TWO TOOLS. The notes are the only real copy: /etc/claude-code/CLAUDE.md is a
# symlink to them, and the entrypoint links ~/.codex/AGENTS.md at them on every start, because
# codex reads global instructions only from $CODEX_HOME and that directory is a volume -- a file
# baked inside it would be seeded once on first mount and never refreshed.
assert_file "notes:the-one-real-file-exists" "$NOTES"
assert_ok  "notes:containerfile-links-the-claude-managed-slot" \
           grep -q 'ln -sfn /etc/cs193v/agent-notes.md /etc/claude-code/CLAUDE.md' $PRIVATE/Containerfile
assert_ok  "notes:entrypoint-links-the-codex-global-slot" \
           grep -qE 'ln -sfn /etc/cs193v/agent-notes\.md .*\.codex/AGENTS\.md' $PRIVATE/files/entrypoint.sh

# An `@word` outside backticks is an IMPORT to Claude Code -- it expands the file at that path
# into context -- and ordinary prose to codex. The notes already say "add `@playwright/test` at
# exactly that version", which is safe only because it is backticked. This is the one thing in a
# shared file that breaks differently for each reader, so it is checked rather than remembered.
at_imports="$(python3 -c "
import re
t = open('$NOTES').read()
t = re.sub(r'\`\`\`.*?\`\`\`', '', t, flags=re.S)
t = re.sub(r'\`[^\`]*\`', '', t)
print(' '.join(re.findall(r'(?:^|\s)(@[A-Za-z0-9._/-]+)', t, flags=re.M)))
" 2>&1)" || at_imports="the check itself failed: $at_imports"
assert_eq  "notes:no-unbackticked-at-import" "" "$at_imports"

lines="$(wc -l < $NOTES | tr -d ' ')"
if [ "$lines" -lt 200 ]; then pass "notes:under-200-lines"
else fail "notes:under-200-lines" "$lines lines"; fi

# NOTHING asserts on the PROSE of the notes, or of CONTAINER-DESIGN.md, by decision.
# Assertions forbidding the old bind-0.0.0.0 imperatives lived in both places briefly and were
# removed: a test that matches on what prose SAYS fails whenever the prose is reworded, including
# when it is reworded correctly, and a test that fires on correct changes teaches people to
# delete it rather than heed it.
#
# THE CREDENTIAL PATHS ARE THE ONE EXCEPTION, and the distinction is what keeps that decision
# intact rather than quietly abandoning it. A path is not prose: it is a third copy of a list the
# volume set and the deny rules already hold, and the cross-check below matches the paths alone,
# so every sentence around them can be rewritten freely without touching a test. The port ranges
# stay unasserted for exactly the reason above -- that check existed, twice, and was deleted both
# times.
#
# What replaces them is behaviour. The claim "a loopback-bound server is reachable" is asserted
# against a real server and a real tunnel in 60-container.sh and 80-launcher-live.sh, which
# cannot pass while the docs' advice is wrong in a way that matters.

# ─── Codex managed policy ─────────────────────────────────────────────────────
# /etc/codex/managed_config.toml, the analogue of managed-settings.json next door, and in /etc for
# the same two reasons: ~/.codex is a named volume, so a file placed there by the image is seeded
# once and never refreshed, and the student can edit it.
CODEX_POLICY="$PRIVATE/files/codex/managed_config.toml"
assert_file "codex:managed-config-exists" "$CODEX_POLICY"
assert_ok   "codex:managed-config-is-valid-toml" \
            python3 -c "import tomllib;tomllib.load(open('$CODEX_POLICY','rb'))"

# THE EXACT KEY SET, not a subset, and the values with it. Two reasons this is asserted rather
# than recorded. First, codex SILENTLY IGNORES a key it does not recognise -- verified against the
# real binary: a bogus key leaves `codex doctor` reporting "config loaded" with no warning at all
# -- so a typo is a policy that does nothing and says nothing, the same failure mode as a
# Write(...) rule in managed-settings.json. Second, the reference says not to combine sandbox_mode
# with `default_permissions` or `[sandbox_workspace_write]`, and an exact key set is what keeps
# either from arriving later without anyone noticing. Asserted on the PARSED keys rather than by
# grepping the file, because the file's own comments name both of those.
codex_keys="$(python3 -c "
import tomllib
print(' '.join(sorted(tomllib.load(open('$CODEX_POLICY','rb')))))" 2>&1)" \
    || codex_keys="the check itself failed: $codex_keys"
assert_eq "codex:policy-has-exactly-the-three-keys" \
          "approval_policy approvals_reviewer sandbox_mode" "$codex_keys"

codex_values="$(python3 -c "
import tomllib
d = tomllib.load(open('$CODEX_POLICY','rb'))
print('%s %s %s' % (d['sandbox_mode'], d['approval_policy'], d['approvals_reviewer']))" 2>&1)" \
    || codex_values="the check itself failed: $codex_values"
# approvals_reviewer = auto_review is a DELIBERATE DIVERGENCE from the Claude Code policy, which
# keeps its prompts in front of the student on the grounds that answering them is the course's core
# skill. Course staff chose the reviewer subagent for codex anyway; it is asserted here so the
# divergence stays a decision on the record rather than drifting back by accident in either
# direction. See the staff README.
assert_eq "codex:policy-is-workspace-write-on-request-auto-review" \
          "workspace-write on-request auto_review" "$codex_values"

assert_ok "codex:containerfile-installs-the-managed-policy" \
          grep -q 'install -m 0644 /tmp/cs193v-files/codex/managed_config.toml /etc/codex/managed_config.toml' \
          $PRIVATE/Containerfile

# ─── the credential stores: ONE list, three files ─────────────────────────────
# Every credential store that gets a volume must also get a deny rule, or a login token lands in
# an agent transcript the first time an agent globs the home directory.
#
# THIS LINE IS THE SOURCE for both checks below, so adding a store means editing one line. The
# second check is why that matters: the notes NAME these paths, because "never read credential
# files" gives codex no way to know that ~/.config/gh holds a token rather than ordinary config
# it might legitimately open while helping with `gh`. Naming them makes the notes a THIRD place
# the same paths are written, and this is what stops the three drifting apart.
#
# Codex is denied WHOLESALE, with gh and vercel, rather than at its credential file alone. Its
# location is something OpenAI moves -- `cli_auth_credentials_store` already exists -- so a rule
# naming auth.json would keep passing while protecting nothing; and ~/.codex/history.jsonl is
# every prompt the student has typed to codex. ~/.claude stays file-level because it doubles as
# Claude Code's own config and transcript home, which it legitimately reads.
CRED_STORES=".claude/.credentials.json .config/gh .codex .local/share/com.vercel.cli"

# THE RULES, NOT THE DOCUMENT'S TEXT, and this is the hazard the comment above
# claude:no-requiredMinimumVersion warns about, one screen up, unfixed until #79. This was
# `assert_contains "claude:denies-$store" "$store" "$(cat "$managed")"` -- a text search over the
# whole file, and the file's own $comment prose names three of these four paths. Measured: with
# `"deny": []` injected, three of the four passed on the strength of the comment that documents
# the rules, and only com.vercel.cli failed, because the prose happens to say "the Vercel
# directory" rather than the path. Parsed and joined, there is nothing but rules to match against.
deny_rules="$(python3 -c '
import json, sys
print("\n".join(json.load(open(sys.argv[1]))["permissions"]["deny"]))
' "$managed" 2>&1)" || deny_rules="the check itself failed: $deny_rules"

for store in $CRED_STORES; do
    assert_contains "claude:denies-$store" "$store" "$deny_rules"
    assert_contains "notes:names-$store"   "$store" "$(cat $NOTES)"
done

# And the other direction, which is the one a reword cannot break: every path the notes name
# must be COVERED by a deny rule, so the notes cannot promise a protection the rules do not
# implement. A wholesale rule ends in `/**`, so "covered" is a prefix test rather than equality:
# ~/.codex/auth.json is covered by Read(//home/student/.codex/**).
#
# Only the Credentials section is scanned. The notes name ~/projects elsewhere and that is not a
# thing to deny, so scanning every ~/ path in the file would demand a rule for it.
#
# THE THREE FILES SPELL THE SAME PATH THREE WAYS -- `~/...` in the notes, `//home/student/...` in
# the rules, `/home/student/...` in container.args -- so everything is normalised to a leading
# /home/student before it is compared.
uncovered="$(python3 -c "
import json, re, sys
rules = []
for r in json.load(open(sys.argv[1]))['permissions']['deny']:
    m = re.match(r'(?:Read|Edit)\((.*)\)\$', r)
    if m:
        rules.append(re.sub(r'^/+', '/', m.group(1)))
text = open(sys.argv[2]).read()
sec = re.search(r'^#+ *Credentials\b(.*?)(?=^#+ |\Z)', text, flags=re.S | re.M)
bad = []
for tilde in re.findall(r'~/[A-Za-z0-9._/-]+', sec.group(1) if sec else ''):
    path = '/home/student/' + tilde[2:]
    covered = False
    for r in rules:
        stem = r[:-3] if r.endswith('/**') else None
        if stem is not None:
            if path == stem or path.startswith(stem + '/'):
                covered = True
        elif path == r:
            covered = True
    if not covered:
        bad.append(tilde)
print('' if sec else 'NO-CREDENTIALS-SECTION')
print(' '.join(sorted(set(bad))))
" "$managed" "$NOTES" 2>&1)" || uncovered="the check itself failed: $uncovered"
assert_eq "notes:every-credential-path-named-is-denied" "" "$(printf '%s' "$uncovered" | sed '/^$/d')"

# ─── shellcheck ────────────────────────────────────────────────────────────────
# Last, because require_cmd aborts the suite: a missing shellcheck should not hide the
# result of every check above it.
require_cmd shellcheck "Run: sudo apt install -y shellcheck"
# -x so shellcheck FOLLOWS the `. "$UI"` into cs193v-ui.sh. Without it, every variable the
# launcher sets for the helper to read — MESSAGES, RT_SPIN — is reported unused (SC2034), and
# the alternative to following the source is excluding the check that would catch a genuinely
# dead variable. The `source-path=SCRIPTDIR` directive in cs193v is what makes this work from
# any working directory rather than only from the repo root.
assert_ok  "shellcheck:cs193v"  shellcheck -x --severity=warning cs193v
assert_ok  "shellcheck:install" shellcheck --severity=warning $PRIVATE/install-cs193v.sh
# The shared presentation layer, checked ALONE as well as through the launcher: the container
# sources it with no launcher in the picture, so it has to stand up by itself.
#
# SC2034 excluded, and only here. Every variable in a library looks unused from inside it —
# C_YEL is read by the launcher's warn(), RT_OUT by half its callers — so the check cannot say
# anything true about this file. It stays on for both scripts that consume it.
assert_ok  "shellcheck:ui" shellcheck --severity=warning --exclude=SC2034 \
                           $PRIVATE/files/cs193v-ui.sh
# setup-git and any future setup-*: they source the helper, so -x here too.
assert_ok  "shellcheck:setup-git" shellcheck -x --severity=warning $PRIVATE/files/setup-git
# The landing point and its two helpers. cs193v-shell is the only way a student gets a
# shell, so a quoting bug in it is a container nobody can enter.
assert_ok  "shellcheck:landing-point" shellcheck --severity=warning \
                                      $PRIVATE/files/cs193v-shell \
                                      $PRIVATE/files/cs193v-welcome \
                                      $PRIVATE/files/cs193v-goodbye
# The small /bin/sh helpers. `man` is here rather than left to the image tier because it
# runs as root-owned /usr/bin/man for every student: a quoting bug in it would turn every
# `man something` into a shell error on top of the missing manual page.
assert_ok  "shellcheck:helpers" shellcheck --severity=warning \
                                $PRIVATE/files/open-url \
                                $PRIVATE/files/man
# files/shortlink is deliberately NOT in that list: it is python3, and shellcheck asked to read it
# reports a syntax error on the first line it does not understand. Its check is the compile() above.
assert_match "shortlink:is-python-not-shell" "^#!/usr/bin/env python3$" \
             "$(head -1 $PRIVATE/files/shortlink)"
# tmux-harness/ is NOT shellchecked: it is vendored from the multiplexer prototype and is
# meant to stay diffable against it, so local style fixes would cost more than they buy.
# Its host-side driver is ours and is checked.
assert_ok  "shellcheck:tmux-driver" shellcheck --severity=warning --exclude=SC1090,SC1091 \
                                    $PRIVATE/tests/65-tmux.sh
assert_ok  "shellcheck:tests"   shellcheck --severity=warning --exclude=SC1090,SC1091 \
                                           $PRIVATE/tests/run-tests.sh $PRIVATE/tests/10-static.sh \
                                           $PRIVATE/tests/14-test-harness.sh \
                                           $PRIVATE/tests/16-args-parse.sh \
                                           $PRIVATE/tests/install-sandbox.sh \
                                           $PRIVATE/tests/lib/sandbox.sh \
                                           $PRIVATE/tests/lib/sandbox-guest.sh
# setup-git's two suites and the pty helpers they share. SC2034 as well: SG_SETUP_GIT and SG_ENV are
# set by each suite and read by the sourced helper, which is invisible without -x, and -x cannot
# resolve a path built from $0.
assert_ok  "shellcheck:setup-git-tests" shellcheck --severity=warning \
                                        --exclude=SC1090,SC1091,SC2034 \
                                        $PRIVATE/tests/lib/setup-git-shim.sh \
                                        $PRIVATE/tests/35-setup-git-shim.sh \
                                        $PRIVATE/tests/45-setup-git.sh \
                                        $PRIVATE/tests/90-setup-git-github.sh
# The two fakes are /bin/sh, like lib/podman-fake, and are run as commands by the suites above.
assert_ok  "shellcheck:setup-git-fakes" shellcheck --severity=warning \
                                        $PRIVATE/tests/lib/gh-fake $PRIVATE/tests/lib/git-fake
