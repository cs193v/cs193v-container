#!/usr/bin/env bash
# TIER: shim
#
# The launcher's state machine and every refusal path, driven against a fake podman.
#
# This covers VERIFICATION.md §1.4, §1.5, §1.7, §2.1, §2.2, §2.5, §2.6, §2.7 and the
# §A.10 launcher checks, with no container created and nothing installed. That matters for
# two reasons: these are the paths that decide whether a student gets a comprehensible
# error or a raw podman one, and they are unreachable from a working machine — you cannot
# test "podman is too old" on a machine with a current podman.
#
# §A.10's own version of the verb loop hangs, because `cs193v` with no verb ends in
# `exec podman exec -it` and it left stdin on the terminal. Everything here closes stdin.

set -u
. "$(dirname -- "$0")/lib/assert.sh"
. "$(dirname -- "$0")/lib/podman-shim.sh"

require_cmd script "needed to drive the arrow-key menu through a pty"
trap 'shim_cleanup' EXIT

COPY="$(repo_copy)"
LAUNCHER_DIR="$COPY"

# ─── dispatch and usage ────────────────────────────────────────────────────────
shim_new
for v in --help -h help; do
    assert_eq "dispatch:$v-exits-0" "0" "$(launcher_rc "$v")"
done
out="$(launcher --help)"
assert_says "usage:mentions-ports"   "cs193v ports"   "$out"
assert_says "usage:mentions-doctor"  "cs193v doctor"  "$out"
assert_contains "usage:mentions-rebuild" "--rebuild"      "$out"
# The "many windows are fine" promise is the one students most need up front.
assert_says "usage:explains-many-windows" "as many terminal windows" "$out"

assert_eq "dispatch:unknown-verb-exits-2" "2" "$(launcher_rc bogusverb)"
assert_says "dispatch:unknown-verb-prints-usage" "cs193v ports" "$(launcher bogusverb)"
# A typo must not create anything.
assert_eq "dispatch:unknown-verb-creates-nothing" "0" "$(shim_count '^run ')"

# ─── --dev-print-command  (§1.7) ───────────────────────────────────────────────
# This is the first thing to ask a student for in a support thread, so it has to be
# trustworthy: every flag in the args files must appear, unmangled.
shim_new
assert_eq "print:exits-0" "0" "$(launcher_rc --dev-print-command)"
line="$(launcher --dev-print-command)"
# "$NAME", not the literal: under CS193V_INSTANCE the name is cs193v-<instance>, and
# "--name cs193v" is a SUBSTRING of that, so a literal here would keep passing while
# asserting nothing about the thing it names.
assert_contains "print:has-name"       "--name $NAME"  "$line"
assert_contains "print:has-detach"     "--detach"      "$line"
assert_contains "print:has-confighash" "cs193v.confighash=" "$line"
assert_contains "print:has-dir-label"  "cs193v.dir=$COPY"   "$line"
assert_contains "print:mounts-sibling-projects" "src=$COPY/projects,dst=/home/student/projects,rw" "$line"

# One-directional on purpose: the launcher legitimately ADDS --name, --detach, --label and
# --mount, so a plain diff would fail spuriously. What must be empty is the set of flags
# present in the args files but missing from the run line.
missing="$(LC_ALL=C comm -13 \
    <(printf '%s\n' "$line" | tr ' ' '\n' | grep -E '^--?[a-z]' | LC_ALL=C sort -u) \
    <(sed 's/#.*//' "$COPY/.config/container.args" "$COPY/.config/local.args" 2>/dev/null \
        | tr ' ' '\n' | grep -E '^--?[a-z]' | LC_ALL=C sort -u) | tr '\n' ' ')"
assert_eq "print:contains-every-args-file-flag" "" "$(printf '%s' "$missing" | sed 's/ *$//')"

# local.args is machine-specific and absent from a fresh clone; the memory cap must reach
# the run line once the installer has written it.
printf -- '--memory=2048m\n-e CS193V_MEMORY_MB=2048\n' > "$COPY/.config/local.args"
line="$(launcher --dev-print-command)"
assert_contains "print:includes-memory-cap"    "--memory=2048m"        "$line"
assert_contains "print:includes-memory-env"    "CS193V_MEMORY_MB=2048" "$line"
# local.args changing must change the hash, or the cap never reaches an existing container.
h_with="$(current_hash)"
rm -f "$COPY/.config/local.args"
assert_ne "print:memory-cap-changes-confighash" "$h_with" "$(current_hash)"

# A comment on the same line as a flag must not leak into the run line.
assert_not_contains "print:strips-trailing-comments" "#" "$(launcher --dev-print-command)"

# The launcher resolves its own location, so it mounts its own sibling projects/ no matter
# where it is invoked from — and through a symlink, which is how a student who adds it to
# their PATH will reach it.
( cd / && PATH="$SHIM:$PATH" "$COPY/cs193v" --dev-print-command 2>&1 ) > "$SHIM/fromroot"
assert_contains "print:works-from-any-cwd" "src=$COPY/projects" "$(cat "$SHIM/fromroot")"
ln -sf "$COPY/cs193v" "$SHIM/cs193v-link"
assert_contains "print:resolves-through-symlink" "src=$COPY/projects" \
    "$(PATH="$SHIM:$PATH" "$SHIM/cs193v-link" --dev-print-command 2>&1)"

# ─── refuses to run as root  (§1.5) ────────────────────────────────────────────
shim_new
shim_fake_id 0 root
out="$(launcher)"
assert_contains "root:refused"              "STOP"          "$out"
assert_contains "root:message-mentions-sudo" "sudo"         "$out"
assert_eq       "root:exits-1"              "1"             "$(launcher_rc)"
assert_eq       "root:creates-nothing"      "0"             "$(shim_count '^run ')"
# It must refuse before even asking podman anything.
assert_eq       "root:asks-podman-nothing"  "0"             "$(shim_count '.')"

# ─── version floor  (§1.4) ─────────────────────────────────────────────────────
# version_lt compares numerically, field by field. A lexical compare would call 10.0.0
# older than 5.7.0 and refuse every future podman.
for v in 5.6.0 5.6.9 4.9.3 0.1.0; do
    shim_new; shim_set version "podman version $v"
    assert_eq "version:$v-refused" "1" "$(launcher_rc)"
    assert_eq "version:$v-creates-nothing" "0" "$(shim_count '^run ')"
done
shim_new; shim_set version "podman version 5.6.0"
out="$(launcher)"
assert_contains "version:refusal-shows-found"  "5.6.0" "$out"
assert_contains "version:refusal-shows-needed" "5.7.0" "$out"
assert_says "version:refusal-names-the-fix" "apt install" "$out"

# 5.7.0 is exactly MIN_PODMAN and is what Ubuntu 26.04 ships, so the boundary is the case
# that actually matters — an off-by-one here refuses every student on a stock Ubuntu.
# 10.0.0 guards against a lexical compare, which would call it older than 5.7.0.
for v in 5.7.0 5.7.1 5.8.0 6.0.2 10.0.0; do
    shim_new; shim_set version "podman version $v"
    launcher >/dev/null 2>&1
    assert_eq "version:$v-accepted" "1" "$(shim_count '^run ')"
done

# ─── podman not responding  (§6.1) ─────────────────────────────────────────────
# After a Mac wakes from sleep, `podman info` hangs rather than failing
# (containers/podman#21675). Every probe is timeout-wrapped so the launcher says something
# instead of looking frozen. The point of this test is the elapsed time.
shim_new; shim_touch hang
T0="$(date +%s)"
rc="$(launcher_rc)"
T1="$(date +%s)"
ELAPSED=$((T1 - T0))
assert_eq "hang:exits-nonzero" "1" "$rc"
if [ "$ELAPSED" -lt 40 ]; then
    pass "hang:returns-in-seconds-not-minutes"
else
    fail "hang:returns-in-seconds-not-minutes" "took ${ELAPSED}s"
fi
record "hang:elapsed-seconds" "$ELAPSED"
shim_new; shim_touch hang
assert_says "hang:message-says-not-responding" "not responding" "$(launcher)"

# ─── rootless and reachability ─────────────────────────────────────────────────
# --userns=keep-id is a HARD ERROR on a rootful connection, not a no-op, so this must be
# caught with an explanation rather than surfaced as a raw podman error.
shim_new; shim_set rootless false
out="$(launcher)"
assert_contains "rootful:refused"          "rootful" "$out"
assert_eq       "rootful:creates-nothing"  "0"       "$(shim_count '^run ')"

shim_new; shim_set info_rc 1
out="$(launcher)"
assert_says "unreachable:refused"         "cannot reach it" "$out"
assert_eq       "unreachable:creates-nothing" "0"               "$(shim_count '^run ')"

# ─── image resolution ──────────────────────────────────────────────────────────
# No pin and nothing built: the only actionable answer is "build it", and it has to name
# the command. There is no registry to fall back to.
shim_new; shim_set image_exists no
out="$(launcher)"
assert_says "image:nothing-built-refuses"      "has not been built" "$out"
assert_says "image:nothing-built-says-how"     "--build"            "$out"
assert_eq   "image:refusal-creates-nothing" "0" "$(shim_count '^run ')"

# A locally built image is the NORMAL case now, not a staff-only escape hatch, so the
# launch must be silent about it. The old warn.dev-mode told any student who saw it to
# contact staff; left in place it would fire for every student on every launch, which is
# the fastest way to teach a class to ignore the launcher's warnings.
shim_new
out="$(launcher 2>&1)"
assert_says_not "image:local-image-does-not-warn"   "locally built" "$out"
assert_says_not "image:local-image-no-staff-scare"  "tell course staff" "$out"
assert_eq       "image:local-image-launches" "1" "$(shim_count '^run ')"

# ─── the state machine  (§2.1, §2.2) ───────────────────────────────────────────
shim_new
assert_eq "state:absent-creates-one" "1" "$(launcher_rc >/dev/null; shim_count '^run ')"

# §A.10 idempotency: twenty launches, still exactly one container. The fake flips to
# running and remembers the hash it was given, so the second launch takes the same path a
# real second launch would.
shim_new
i=0
while [ "$i" -lt 20 ]; do launcher >/dev/null 2>&1; i=$((i + 1)); done
assert_eq "state:20-launches-create-one-container" "1" "$(shim_count '^run ')"
assert_eq "state:20-launches-remove-nothing"       "0" "$(shim_count '^rm ')"

# Every launch after the first must open a shell rather than recreate. Driven through a pty,
# because open_shell now refuses without a terminal — so a piped launch never gets this far,
# which is exactly the behaviour the refusal is for.
shim_new
i=0
while [ "$i" -lt 3 ]; do launcher_pty >/dev/null 2>&1; i=$((i + 1)); done
assert_eq "state:pty-launches-create-one-container" "1" "$(shim_count '^run ')"
if [ "$(shim_count '^exec -it')" -ge 3 ]; then pass "state:every-pty-launch-opens-a-shell"
else fail "state:every-pty-launch-opens-a-shell" "only $(shim_count '^exec -it') exec sessions"; fi

# A stopped container is started, never recreated — recreating would silently discard
# anything the student installed inside it.
shim_new
launcher >/dev/null 2>&1                       # create, so the hash matches
shim_set state exited
shim_clear_log
launcher >/dev/null 2>&1
assert_eq "state:exited-is-started" "1" "$(shim_count '^start ')"
assert_eq "state:exited-is-not-recreated" "0" "$(shim_count '^run ')"

# ─── a container from a different copy of the course directory  (§2.7) ─────────
# Without this a student who re-downloads after breaking something silently gets the old
# container with the old mount, and their edits appear to vanish.
shim_new
shim_set state running
shim_set label_dir /somewhere/else/cs193v
out="$(launcher)"
assert_says "foreign-dir:refused"        "different folder" "$out"
assert_contains "foreign-dir:names-theirs"   "/somewhere/else/cs193v" "$out"
assert_contains "foreign-dir:names-yours"    "$COPY" "$out"
assert_contains "foreign-dir:offers-rebuild" "--rebuild" "$out"
assert_eq       "foreign-dir:creates-nothing" "0" "$(shim_count '^run ')"
assert_eq       "foreign-dir:opens-no-shell"  "0" "$(shim_count '^exec ')"

# ─── config drift  (§2.5) ──────────────────────────────────────────────────────
# `podman start` reuses the container's STORED config and ignores the image digest, the
# port list, keep-id and --memory alike. Without this check, every student's flags would be
# frozen at first run and edits to container.args would never reach anyone.
shim_new
launcher >/dev/null 2>&1                       # one container, hash recorded
shim_clear_log
echo '-p 127.0.0.1:9998:9998' >> "$COPY/.config/container.args"
out="$(launcher)"
assert_says "drift:prompt-shown"    "settings have changed" "$out"
assert_says "drift:explains-why"    "cannot apply new settings" "$out"
assert_says "drift:reassures-files" "Your files are safe" "$out"
assert_eq "drift:declined-keeps-container" "0" "$(shim_count '^run ')"
assert_eq "drift:declined-removes-nothing" "0" "$(shim_count '^rm ')"
# The new flag must be visible in the run line even before the recreate.
assert_contains "drift:visible-in-print-command" "9998" "$(launcher --dev-print-command)"

# Accepting it, through a pty, must actually recreate with the new flag.
shim_clear_log
out="$(launcher_tty '\033[B\n' | strip_ansi)"
assert_says "drift:accepted-selects-apply" "Apply the new settings" "$out"
assert_eq "drift:accepted-removes-old" "1" "$(shim_count '^rm ')"
assert_eq "drift:accepted-creates-new" "1" "$(shim_count '^run ')"
assert_contains "drift:new-container-has-the-flag" "9998" "$(shim_log | grep '^run ')"

# Restore, and confirm a matching config produces no prompt at all.
edit_remove "$COPY/.config/container.args" '9998'
shim_new
launcher >/dev/null 2>&1
shim_clear_log
out="$(launcher)"
assert_says_not "nodrift:no-prompt" "settings have changed" "$out"
assert_eq "nodrift:no-recreate" "0" "$(shim_count '^run ')"

# ─── a newer pinned image  (§2.6) ──────────────────────────────────────────────
shim_new
launcher >/dev/null 2>&1
shim_set image_id "sha256:bbbbnewer"           # the pin now resolves to something else
shim_clear_log
out="$(launcher)"
assert_says "newer-image:prompt-shown" "newer version" "$out"
assert_eq "newer-image:declined-keeps-container" "0" "$(shim_count '^run ')"
shim_clear_log
launcher_tty '\033[B\n' >/dev/null 2>&1
assert_eq "newer-image:accepted-recreates" "1" "$(shim_count '^run ')"

# ─── a stale recipe  (the replacement for the digest pin) ──────────────────────
# How a mid-quarter fix reaches a student who never runs --update. With no registry there
# is no digest to change, and podman mints a new image ID on every build including a
# no-op one — so the IMAGE ID cannot answer "is this out of date". The recipe can.
shim_new
launcher >/dev/null 2>&1
shim_set image_buildhash "0000deadbeefnotthecurrentrecipe"
shim_clear_log
out="$(launcher)"
assert_says "stale-recipe:prompt-shown" "has been updated since" "$out"
assert_eq   "stale-recipe:declined-builds-nothing" "0" "$(shim_count '^build ')"
assert_eq   "stale-recipe:declined-keeps-container" "0" "$(shim_count '^run ')"

shim_clear_log
launcher_tty '\033[B\n' >/dev/null 2>&1
assert_eq "stale-recipe:accepted-rebuilds"  "1" "$(shim_count '^build ')"
assert_eq "stale-recipe:accepted-recreates" "1" "$(shim_count '^run ')"

# An image built before the label existed has none, and an UNKNOWN answer must not nag —
# the same rule the confighash check follows. Nagging on every launch with no way to
# silence it is how a class learns to click through prompts.
shim_new
launcher >/dev/null 2>&1
shim_clear_log
assert_says_not "stale-recipe:unlabelled-does-not-nag" "has been updated since" "$(launcher)"
assert_eq       "stale-recipe:unlabelled-builds-nothing" "0" "$(shim_count '^build ')"

# ─── --rebuild and --full-rebuild  (§2.3, §2.4) ────────────────────────────────
shim_new
launcher >/dev/null 2>&1
shim_clear_log
launcher --rebuild >/dev/null 2>&1
assert_eq "rebuild:removes-container" "1" "$(shim_count '^rm ')"
assert_eq "rebuild:creates-container" "1" "$(shim_count '^run ')"
# --rebuild must keep logins: none of the five volumes is touched.
assert_eq "rebuild:keeps-volumes" "0" "$(shim_count '^volume rm')"
assert_says "rebuild:says-logins-kept" "logins are kept" "$(launcher --rebuild)"

shim_new
launcher >/dev/null 2>&1
shim_clear_log
out="$(launcher --full-rebuild)"
assert_says "full-rebuild:warns-about-logout" "logging you out" "$out"
assert_says "full-rebuild:lists-what-is-kept" "projects folder" "$out"
# The safe option is the default, so a non-TTY run must change nothing.
assert_says "full-rebuild:non-tty-cancels" "Nothing was changed" "$out"
assert_eq "full-rebuild:non-tty-removes-nothing" "0" "$(shim_count '^rm ')"

shim_clear_log
launcher_tty '\033[B\n' --full-rebuild >/dev/null 2>&1
assert_eq "full-rebuild:accepted-removes-container" "1" "$(shim_count '^rm ')"
if [ "$(shim_count '^volume rm')" -eq 5 ]; then pass "full-rebuild:accepted-removes-5-volumes"
else fail "full-rebuild:accepted-removes-5-volumes" "removed $(shim_count '^volume rm')"; fi

# ─── --update  (§9.1) ──────────────────────────────────────────────────────────
# With no pin — the normal case — --update BUILDS. It used to refuse outright, on the
# reasoning that there was no published image to update to; now the Containerfile is what
# ships, so "get the newest version" means rebuilding from the newest recipe.
shim_new
launcher --update >/dev/null 2>&1
assert_eq "update:unpinned-builds"        "1" "$(shim_count '^build ')"
assert_eq "update:unpinned-pulls-nothing" "0" "$(shim_count '^pull ')"
assert_eq "update:unpinned-recreates"     "1" "$(shim_count '^run ')"
# The recipe fingerprint has to be on the image, or nothing downstream can tell a stale
# image from a current one — see ensure_container and doctor.
assert_contains "update:build-labels-the-recipe" "cs193v.buildhash=" "$(shim_log | grep '^build ')"

PINNED="ghcr.io/example/cs193v@sha256:1111"
shim_new
edit_sub "$COPY/.config/container.args" '^IMAGE=.*' "IMAGE=$PINNED"
launcher --update >/dev/null 2>&1
assert_eq "update:pulls" "1" "$(shim_count '^pull ')"
assert_eq "update:recreates" "1" "$(shim_count '^run ')"
assert_contains "update:pulls-the-pinned-digest" "$PINNED" "$(shim_log | grep '^pull ')"
assert_contains "update:retries-on-flaky-wifi" "--retry" "$(shim_log | grep '^pull ')"

# A failed pull is the commonest student failure after a dropped connection, and its
# message interpolates multi-line podman output — the case that used to print a blank box.
shim_new
shim_set pull_rc 1
shim_set pull_err 'Error: initializing source docker://cs193v: reading manifest
unexpected EOF
Error: pulling image: connection reset by peer'
out="$(launcher --update)"
assert_contains "update:failure-shows-podman-line-1" "reading manifest" "$out"
assert_contains "update:failure-shows-podman-line-3" "connection reset by peer" "$out"
assert_says "update:failure-says-safe-to-retry" "safe to run" "$out"
assert_not_contains "update:failure-no-sed-error" "unterminated" "$out"
edit_sub "$COPY/.config/container.args" '^IMAGE=.*' "IMAGE="

# ─── ports and doctor ──────────────────────────────────────────────────────────
shim_new
shim_set state absent
assert_says "ports:refused-when-not-running" "not running yet" "$(launcher ports)"

shim_new
launcher >/dev/null 2>&1
shim_clear_log
out="$(launcher ports)"
assert_says "ports:execs-the-in-container-tool" "$NAME ports" "$(shim_log | tr '\n' ' ')"

shim_new
out="$(launcher doctor)"
assert_contains "doctor:reports-platform"  "platform"     "$out"
assert_contains "doctor:reports-podman"    "5.7.0"        "$out"
assert_contains "doctor:reports-dir"       "$COPY"        "$out"
assert_contains "doctor:reports-container" "container"    "$out"
assert_says "doctor:asks-for-a-paste"  "Paste all of the above" "$out"
# doctor must never create or modify anything — it is what staff ask for first.
assert_eq "doctor:creates-nothing" "0" "$(shim_count '^run ')"
assert_eq "doctor:removes-nothing" "0" "$(shim_count '^rm ')"

# The positive case, and the one that was broken. A container created from the current
# container.args must be reported as matching it. verb_doctor hashed IMAGE="" because it
# never resolved the image, while the launch path hashed the resolved dev image — so in dev
# mode (an empty IMAGE=, which is how the repo ships) doctor called EVERY container stale
# and sent people chasing a recreate prompt that never appears.
shim_new
launcher >/dev/null 2>&1
out="$(launcher doctor)"
assert_says "doctor:reports-a-matching-config-as-matching" "matches container.args" "$out"
assert_says_not "doctor:does-not-cry-stale-when-config-matches" "STALE" "$out"
# Whatever doctor says has to agree with what a real launch decides, or one of the two is
# lying to the student.
assert_says_not "doctor:agrees-with-the-launch-path" "settings have changed" "$(launcher)"

# Again with a pinned image, so the fix is not accidentally dev-mode-only.
shim_new
cp "$COPY/.config/container.args" "$SHIM/ca.bak"
edit_sub "$COPY/.config/container.args" '^IMAGE=.*' 'IMAGE=ghcr.io/example/cs193v@sha256:2222'
launcher >/dev/null 2>&1
assert_says "doctor:matching-config-with-a-pinned-image" "matches container.args" \
            "$(launcher doctor)"
cp "$SHIM/ca.bak" "$COPY/.config/container.args"

# And drift must still be reported when it is real.
shim_new
launcher >/dev/null 2>&1
shim_set label_hash STALE
assert_contains "doctor:reports-stale-config" "STALE" "$(launcher doctor)"

# doctor is "the report to paste when asking for help", so it has to answer the first
# question staff will ask about behaviour they cannot reproduce. That question used to be
# "what digest are you on"; with the image built on the student's own machine the
# answerable form is which image, when it was built, and whether it still matches the
# course files. VERIFICATION.md §A.1 calls doctor untrustworthy if it lies here.
shim_new
launcher >/dev/null 2>&1
out="$(launcher doctor)"
assert_says "doctor:names-the-image"      "localhost/cs193v:local" "$out"
assert_says "doctor:says-it-was-built-here" "built here"           "$out"
assert_says "doctor:dates-the-image"      "image built"            "$out"
assert_says "doctor:reports-the-recipe"   "image recipe"           "$out"

shim_new
launcher >/dev/null 2>&1
shim_set image_buildhash "0000deadbeefnotthecurrentrecipe"
assert_contains "doctor:reports-a-stale-recipe" "STALE" "$(launcher doctor | grep 'image recipe')"

# Nothing built yet: doctor must say so rather than printing a tag that does not exist,
# and must name the command that fixes it.
shim_new; shim_set image_exists no
out="$(launcher doctor)"
assert_says "doctor:says-when-nothing-is-built" "NOT BUILT" "$out"
assert_says "doctor:says-how-to-build"          "--build"   "$out"

# ─── terminal handling ─────────────────────────────────────────────────────────
# podman forces TERM=xterm and does not copy the client's value
# (containers/podman#25683), costing 256-colour support. But the image ships a limited
# terminfo set, so an exotic TERM cannot be forwarded verbatim or a full-screen editor
# fails to start. Whitelist, and fall back to a safe 256-colour entry.
# Driven through a pty: TERM is forwarded by open_shell, which now refuses without a
# terminal, so a piped launch never reaches the exec at all.
shim_new
TERM=xterm-256color launcher_pty >/dev/null 2>&1
assert_contains "term:known-term-forwarded" "TERM=xterm-256color" "$(shim_log)"
for exotic in kitty ghostty alacritty wezterm foot xterm-kitty; do
    shim_new
    TERM="$exotic" launcher_pty >/dev/null 2>&1
    assert_contains "term:$exotic-falls-back-to-256color" "TERM=xterm-256color" "$(shim_log)"
    assert_not_contains "term:$exotic-not-forwarded-verbatim" "TERM=$exotic" "$(shim_log)"
done
shim_new
TERM='' launcher_pty >/dev/null 2>&1
assert_contains "term:empty-term-gets-a-default" "TERM=xterm-256color" "$(shim_log)"

shim_new
out="$(NO_COLOR=1 launcher bogusverb)"
assert_not_match "no-color:emits-no-escapes" "$(printf '\033')" "$out"

# ─── opening a shell requires a terminal  (ERRORS.md B13) ──────────────────────
# `podman exec -it` allocates a pty, and a pty never delivers EOF the way a pipe does, so
# with a redirected stdin the container's `bash -l` used to wait forever and the launcher
# looked wedged with no output at all. It now refuses instead.
shim_new
out="$(launcher)"
assert_says "noterm:refuses-without-a-terminal" "could not open a shell" "$out"
assert_says "noterm:explains-why"               "not being run from a terminal" "$out"
assert_says "noterm:says-the-container-is-fine" "container is set up and running" "$out"
# The message has to name what a script SHOULD use, or it is just a dead end.
assert_says "noterm:points-at-rebuild" "cs193v --rebuild" "$out"
assert_says "noterm:points-at-doctor"  "cs193v doctor"    "$out"
assert_says "noterm:points-at-podman-exec" "podman exec -it cs193v bash -lc" "$out"
assert_eq   "noterm:exits-nonzero" "1" "$(launcher_rc)"
# It must refuse, not hang. A wall-clock check, since hanging was the original bug.
T0="$(date +%s)"; launcher >/dev/null 2>&1; T1="$(date +%s)"
if [ "$((T1 - T0))" -lt 30 ]; then pass "noterm:refuses-promptly-instead-of-hanging"
else fail "noterm:refuses-promptly-instead-of-hanging" "took $((T1 - T0))s"; fi
# The work done before the shell is still real and idempotent — the message promises this.
assert_eq "noterm:container-was-still-created" "1" "$(shim_count '^run ')"
# And no shell was attempted.
assert_eq "noterm:no-exec-attempted" "0" "$(shim_count '^exec -it')"
# With a terminal, the very same invocation must go on to open the shell.
#
# The landing point is cs193v-shell, not `bash -l`: it puts the student inside tmux and
# picks a session to attach to. `bash -l` remains what the refusal message points scripts
# at, which is asserted separately above -- the two must not be conflated, because the
# whole point of that message is that it names the path which does NOT go through tmux.
shim_new
launcher_pty >/dev/null 2>&1
assert_contains "noterm:with-a-terminal-it-opens-a-shell" "cs193v-shell" "$(shim_log)"
# The failure path inside the container has to print an exact `podman exec` line, and only
# the launcher knows the container's name -- CS193V_INSTANCE may have suffixed it.
assert_contains "noterm:passes-the-container-name-in" "CS193V_CONTAINER=" "$(shim_log)"

# The scriptable verbs must NOT be caught by the refusal — they are what the message tells
# people to use, so they have to work with a redirected stdin.
for v in --dev-print-command doctor --rebuild; do
    shim_new
    assert_says_not "noterm:verb-$v-still-works-piped" "could not open a shell" \
                    "$(launcher $v)"
done
shim_new
launcher --rebuild >/dev/null 2>&1
assert_eq "noterm:--rebuild-still-creates-a-container-piped" "1" "$(shim_count '^run ')"

# ─── warnings survive the shell being opened  (issue #19) ──────────────────────
# open_shell's last act is `exec podman exec -it ... cs193v-shell`, and cs193v-shell
# attaches tmux, which switches the terminal to its alternate screen — erasing everything
# printed before it. So every warning the launcher has was displayed and none of them was
# readable: the dev-image advisory, "the tunnel did not come up", "these ports are already
# in use". The launcher now stops for ENTER whenever it warned.
#
# The shim's launches warn with no arranging needed: the fake podman cannot serve an ssh
# tunnel, so the tunnel fails and warn.tunnel-failed is printed.
#
# This used to warn TWICE, the second being a dev-image advisory for an unpinned IMAGE.
# That warning is gone -- a locally built image is now the normal case, not a fault -- so
# the tunnel failure is the only warning left to hang this on. Any surviving warning would
# do; what is being tested is the ENTER gate, not which warning triggered it.
#
# exec_out makes the moment the container is opened visible in the transcript: it is what
# the fake prints for the final `podman exec -it`, and that is the only exec whose output
# is not captured or discarded by the launcher.
shim_new
shim_set exec_out "SHELL-OPENED"
out="$(launcher_tty '\nexit\n' | strip_ansi)"
assert_says "ack:a-warned-launch-asks-for-enter" "Press ENTER to continue" "$out"
# The warning itself has to still be on screen at that point — acknowledging a message you
# cannot see is no better than not being shown it.
assert_says "ack:the-warning-is-still-on-screen" "browser will not be able to reach" "$out"
# ENTER goes on to open the shell rather than giving up.
assert_contains "ack:enter-then-opens-the-shell" "cs193v-shell" "$(shim_log)"
# And the prompt comes BEFORE the container is opened, not after it has already swallowed
# the screen. Line numbers from the transcript, so this asserts on order, not just presence.
p_ack="$(printf '%s\n' "$out" | grep -n 'Press ENTER to continue' | head -1 | cut -d: -f1)"
p_shell="$(printf '%s\n' "$out" | grep -n 'SHELL-OPENED' | head -1 | cut -d: -f1)"
if [ -n "$p_ack" ] && [ -n "$p_shell" ] && [ "$p_ack" -lt "$p_shell" ]; then
    pass "ack:prompt-comes-before-the-container-is-opened"
else
    fail "ack:prompt-comes-before-the-container-is-opened" \
         "prompt at line ${p_ack:-none}, shell opened at line ${p_shell:-none}:
$out"
fi

# It WAITS, rather than printing a prompt and carrying on regardless — which is the whole
# of the fix, and what an ordering check alone cannot tell apart. Driven with a terminal
# that stays open and says nothing, so nothing can be mistaken for an answer.
shim_new
shim_set exec_out "SHELL-OPENED"
launcher_pty_silent_start
if launcher_pty_silent_wait 30 'Press ENTER'; then
    pass "ack:prompt-reached-on-a-silent-terminal"
    assert_eq "ack:silence-does-not-open-the-shell" "0" "$(shim_count '^exec -it')"
else
    fail "ack:prompt-reached-on-a-silent-terminal" \
         "the launcher never asked, or exited without asking:
$(cat "$PTY_OUT" 2>/dev/null)"
    fail "ack:silence-does-not-open-the-shell" "no prompt was reached, so nothing was held"
fi
launcher_pty_silent_stop

# A launch with nothing to say must NOT stop for an acknowledgement. A pause on every
# single launch teaches a student to press ENTER without reading, which costs the fix its
# whole value — the prompt has to mean "there is something here".
#
# Two things are arranged so a shim launch has nothing to say: an ssh that succeeds, so the
# tunnel does not fail, and a pinned image. The pin used to be here to suppress the dev-image
# advisory, which no longer exists; it still earns its place, because a pinned IMAGE is also
# what skips the stale-recipe check, and that check is the other thing that can speak up.
shim_new
shim_fake_ssh
shim_set exec_out "SHELL-OPENED"
cp "$COPY/.config/container.args" "$SHIM/ca.bak"
edit_sub "$COPY/.config/container.args" '^IMAGE=.*' 'IMAGE=ghcr.io/example/cs193v@sha256:3333'
out="$(launcher_tty 'exit\n' | strip_ansi)"
assert_says_not "ack:a-quiet-launch-warns-about-nothing" "NOTE:" "$out"
assert_says_not "ack:a-quiet-launch-does-not-stop" "Press ENTER to continue" "$out"
assert_contains "ack:a-quiet-launch-still-opens-the-shell" "SHELL-OPENED" "$out"
cp "$SHIM/ca.bak" "$COPY/.config/container.args"

# Warning and prompting are separate: the verbs warn too, and they return to the student's
# own shell with their output intact, so stopping them would be a pause for nothing.
# Through a pty, or the acknowledgement would decline to prompt for want of a terminal and
# this would pass without asserting anything.
shim_new
out="$(launcher_tty '\n' --reset-tunnel | strip_ansi)"
assert_says "ack:a-verb-still-warns" "no container running" "$out"
assert_says_not "ack:a-verb-does-not-stop-to-be-acknowledged" "Press ENTER to continue" "$out"

# ─── malformed args files ──────────────────────────────────────────────────────
shim_new
assert_says "args:missing-file-refused" "container.args is missing" \
    "$(rm -f "$COPY/.config/container.args.bak"; mv "$COPY/.config/container.args" "$COPY/.config/container.args.bak"; \
       launcher; mv "$COPY/.config/container.args.bak" "$COPY/.config/container.args")"

# A container.args holding only comments leaves ARGS empty. Expanding an empty array under
# `set -u` is fatal on bash < 4.4 — every Mac — so this must produce our output, not a raw
# "ARGS[@]: unbound variable" from bash.
shim_new
cp "$COPY/.config/container.args" "$SHIM/ca.bak"
printf '# every line here is a comment\n# and nothing else\nIMAGE=\n' > "$COPY/.config/container.args"
out="$(launcher --dev-print-command)"
assert_not_contains "args:comment-only-no-unbound-variable" "unbound variable" "$out"
assert_not_contains "args:comment-only-no-bash-error"       "cs193v: line"     "$out"
assert_contains     "args:comment-only-still-prints-a-run-line" "podman run"   "$out"
out="$(launcher)"
assert_not_contains "args:comment-only-launch-no-bash-error" "unbound variable" "$out"
cp "$SHIM/ca.bak" "$COPY/.config/container.args"

# Blank lines, extra whitespace and inline comments must all be tolerated.
shim_new
cp "$COPY/.config/container.args" "$SHIM/ca.bak"
printf 'IMAGE=\n\n   \n   --network=pasta   # trailing comment\n\n-e FOO=bar\n' \
    > "$COPY/.config/container.args"
line="$(launcher --dev-print-command)"
assert_contains "args:whitespace-tolerated" "--network=pasta" "$line"
assert_contains "args:second-flag-kept"     "-e FOO=bar"      "$line"
assert_not_contains "args:inline-comment-dropped" "trailing"  "$line"
cp "$SHIM/ca.bak" "$COPY/.config/container.args"
