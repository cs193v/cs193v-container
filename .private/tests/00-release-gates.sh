#!/usr/bin/env bash
# TIER: release
#
# Release gates — NOT part of the default run.
#
#     tests/run-tests.sh --release
#
# These are not regressions and they are not bugs. They are the placeholders that must be
# filled in before students touch this, and they fail today by design: the repo is
# scaffolding with four deliberate blanks in it. Keeping them out of the everyday suite is
# the point — a suite that is permanently red teaches you to ignore it.
#
# Run this before the quarter starts, and again after any change to the publishing setup.

set -u
. "$(dirname -- "$0")/lib/assert.sh"

cd "$REPO" || exit 1

# ─── 1. the installer's repository ─────────────────────────────────────────────
# REPO_OWNER=CHANGEME makes the tarball URL a 404, so the installer cannot complete at all
# and VERIFICATION.md §1 cannot be run as shipped. This is now the ONLY blank left that is
# engineering rather than website work.
owner="$(sed -n 's/^REPO_OWNER="\(.*\)".*/\1/p' $PRIVATE/install-cs193v.sh | head -1)"
assert_ne "installer:REPO_OWNER-is-set" "CHANGEME" "$owner"
record    "installer:REPO_OWNER" "$owner"
assert_ne "installer:REPO_OWNER-not-empty" "" "$owner"

# ...and the URL the WINDOWS installer fetches stage two from, ACTUALLY FETCHED.
#
# THIS IS THE ONLY TEST IN THE SUITE THAT CAN CATCH A WRONG URL. install-cs193v-windows.cmd
# carries its own REPO_OWNER/REPO_NAME/REPO_BRANCH and composes a raw.githubusercontent.com URL
# from them; 25-installer.sh checks that those three agree with the .sh's and that the result
# needs no quoting, and the windows tier drives the whole download against a fake with
# --network=none. None of that can notice that the URL is a 404 -- a typo in the host, a renamed
# branch, or `.private/` moving -- and the consequence is that EVERY Windows student stops dead
# at stage two with a network error that is not a network error.
#
# It belongs in the release tier for the same reason the token expiry in §6 does: it depends on
# publication rather than on code, so it goes stale on someone else's schedule and a failure
# here would be unactionable noise in the everyday suite.
#
# DELIBERATELY WEAK, AND NOTHING BELOW LOOKS AT THE WORKING TREE. This gate answers one question
# -- "is something installer-shaped at that URL" -- and stops there. It used to also assert that
# the URL served THIS TREE's bytes, and that the published copy carried the sentinel. Both had to
# go, and the reason is worth keeping because the second version of this file will be tempted by
# them again:
#
#   * The bytes comparison was red for anyone with an uncommitted edit to install-cs193v.sh, and
#     could only be made green by committing AND pushing to the student branch. That is the exact
#     failure §6 warns about -- "failing for everybody with no change to blame" -- committed
#     inside the tier that was supposed to be immune to it. A red you can only clear by
#     publishing is not a test of the code.
#   * The sentinel check could not catch the thing it was aimed at. The .cmd and the .sh are
#     published by the SAME PUSH of the SAME BRANCH, so they cannot disagree about the token in
#     the repo. The one way they really can diverge is the course website's hand-uploaded .cmd
#     going stale against raw's .sh -- and this suite does not know the website's URL, so no
#     assertion here can see it. That is a line in README's release list, not a test.
#
# THE STRICT HALF IS ALREADY COVERED, OFFLINE, AGAINST THE WORKING TREE, which is why weakening
# this costs nothing:
#
#   * `--tier windows` drives the whole download -> sentinel -> bash sequence against the tree as
#     it stands. lib/wine.sh copies install-cs193v.sh in as stage2.src and fake-wsl.c's curl arm
#     serves it, so an edit to that script is exercised by the next run rather than by the next
#     push. Both directions: win-ok:* on a full body, win-portal on a cut-short one.
#   * 25-installer.sh asserts the contract a developer can actually act on -- that the token the
#     .cmd greps for is the .sh's last line and occurs there exactly once.
#
# The .cmd is parsed rather than the URL retyped, or this would assert that a constant equals
# itself. \r is stripped first: the file is CRLF, and a trailing carriage return in a URL is a
# 400 from a server and a mystery in a log.
cmdfile=$PRIVATE/install-cs193v-windows.cmd
cget() { sed 's/\r$//' "$cmdfile" | sed -n "s/^set \"$1=\(.*\)\"\$/\1/p" | head -1; }
stage2_url="$(cget INSTALLER_URL \
              | sed -e "s|%REPO_OWNER%|$(cget REPO_OWNER)|" \
                    -e "s|%REPO_NAME%|$(cget REPO_NAME)|" \
                    -e "s|%REPO_BRANCH%|$(cget REPO_BRANCH)|")"
record "installer:stage2-url" "$stage2_url"
rel_tmp="$(new_tmpdir)"
if curl -fsS --retry 3 -o "$rel_tmp/stage2.sh" "$stage2_url" 2>"$rel_tmp/curl.err"; then
    pass "installer:stage2-url-is-fetchable"
    record "installer:stage2-url-bytes" "$(wc -c < "$rel_tmp/stage2.sh")"

    # `curl -f` has already done most of the work: measured, it exits 22 for a wrong owner, a
    # wrong repo, a wrong branch AND a wrong path, so the assertion above covers the whole typo
    # class on its own. What it cannot see is a 200 carrying something else, which is the shape a
    # captive portal or an intercepting proxy has -- the same failure the .cmd's own sentinel
    # check exists to refuse at run time, here caught one layer earlier.
    #
    # `bash -n` and not a token search, on purpose. It asks "is this a shell script at all",
    # which is a property of every version of install-cs193v.sh past and future, so this cannot
    # go red because somebody edited the script. Measured: it accepts the real installer and
    # rejects an HTML sign-in page with exit 2.
    assert_ok "installer:stage2-url-serves-a-shell-script" \
              sh -c "head -1 '$rel_tmp/stage2.sh' | grep -qE '^#!.*bash' \
                     && bash -n '$rel_tmp/stage2.sh'"

    # ...and that it is THIS course's installer rather than some other shell script that happens
    # to live at that path. Constant NAMES, never their values: `REPO_OWNER=cs193v` changing to
    # anything else must not fail here, because that is a staff edit and 25-installer.sh is what
    # keeps it honest. Both names are load-bearing in the .sh and pinned by other assertions, so
    # neither can be renamed quietly.
    assert_ok "installer:stage2-url-serves-the-course-installer" \
              sh -c "grep -q '^REPO_OWNER=' '$rel_tmp/stage2.sh' \
                     && grep -q '^WSL_DISTRO=' '$rel_tmp/stage2.sh'"
else
    fail "installer:stage2-url-is-fetchable" \
         "the Windows installer would fetch stage two from:
    $stage2_url
and that failed. Every Windows student stops here.
$(cat "$rel_tmp/curl.err")"
    # Named rather than dropped: a check that quietly disappears is the same defect as one that
    # never ran (VERIFICATION.md §A.15).
    skip "installer:stage2-url-serves-a-shell-script"      "the URL could not be fetched"
    skip "installer:stage2-url-serves-the-course-installer" "the URL could not be fetched"
fi
rm -rf "$rel_tmp"

# ─── 2. the recipe is the distribution, so its pins are the release gate ───────
# THIS SECTION REPLACED A REGISTRY CHECK, and it is stricter than the one it replaced.
#
# It used to assert that IMAGE= held a published manifest-list digest and that CI built
# both architectures. There is no registry now: .private/Containerfile is what ships, and
# every student builds it. A floating input used to mean CI drifted between runs and one
# artifact still reached everybody; now it means TWO STUDENTS GET DIFFERENT SOFTWARE, and
# nothing downstream can detect that it happened.
#
# There is nothing left to check about the image REFERENCE, and that is the point: the
# IMAGE= line is gone from container.args and the launcher's IMAGE is a constant, so there is
# no value here that a release could get wrong. What ships is the recipe, so the pins below
# are the whole of this gate.

# The base image. A moving tag is the one drift a single line can close, so it must be
# closed: `ubuntu:26.04` is republished as the base rolls forward, and on the tag alone two
# students a week apart build on different foundations. Pinned by MANIFEST-LIST digest, not
# a per-architecture one, so the single line serves both the arm64 and amd64 legs.
from="$(sed -n 's/^FROM \(.*\)/\1/p' $PRIVATE/Containerfile | head -1)"
record "build:FROM" "$from"
assert_contains "build:base-image-pinned-by-digest" "@sha256:" "$from"
# `podman manifest inspect` and skopeo both REFUSE a name:tag@digest reference outright
# ("Docker references with both a tag and digest are currently not supported"), even though
# podman build accepts it happily. Strip the tag to inspect it. The Containerfile keeps the
# tag for readability and says there that it is decoration — the digest is what builds.
from_digest="${from%@*}@${from##*@}"
from_digest="${from_digest%%:*}@${from##*@}"
record "build:FROM-normalised" "$from_digest"
if command -v podman >/dev/null 2>&1 && [ "$from" != "${from#*@sha256:}" ]; then
    if podman manifest inspect "$from_digest" >/dev/null 2>&1; then
        plats="$(podman manifest inspect "$from_digest" \
                 | python3 -c 'import json,sys
d=json.load(sys.stdin)
print(" ".join(sorted("%s/%s" % (m["platform"]["os"], m["platform"]["architecture"])
                      for m in d.get("manifests", []))))' 2>/dev/null)"
        record "build:base-platforms" "$plats"
        # Both legs must be in the list the digest names, or the pin builds on exactly one
        # of the two architectures students actually have.
        assert_contains "build:base-has-amd64" "linux/amd64" "$plats"
        assert_contains "build:base-has-arm64" "linux/arm64" "$plats"
    else
        fail "build:base-digest-resolves" "podman manifest inspect $from_digest failed"
    fi
else
    skip "build:base-has-amd64" "podman not installed"
    skip "build:base-has-arm64" "podman not installed"
fi

# ─── 3. reproducible build inputs ──────────────────────────────────────────────
# `latest` in a build ARG means the student who installs on Tuesday and the student who
# installs on Thursday are running different software. CLAUDE_CODE_VERSION is the sharpest
# case: this is a course about using Claude Code, so a skew there is a skew in the subject
# being taught, and the managed-settings.json schema it has to accept is only checked for
# valid JSON at build time — never against the version that actually installs.
for arg in VERCEL_VERSION CODEX_VERSION CLAUDE_CODE_VERSION PLAYWRIGHT_VERSION; do
    v="$(sed -n "s/^ARG $arg=\(.*\)/\1/p" $PRIVATE/Containerfile | head -1)"
    record "build:$arg" "$v"
    assert_ne "build:$arg-is-pinned" "latest" "$v"
    assert_match "build:$arg-looks-like-a-version" '^[0-9]+\.[0-9]+\.[0-9]+$' "$v"
done
# NODE_VERSION is an exact apt version. Verified rather than assumed: NodeSource's nodistro
# suite retains the whole 24.x patch history, so unlike a distro archive that drops
# superseded packages this pin does not expire mid-quarter. Re-check with
# `apt-cache madison nodejs` before trusting the same of a future major.
nv="$(sed -n 's/^ARG NODE_VERSION=\(.*\)/\1/p' $PRIVATE/Containerfile | head -1)"
assert_match "build:NODE_VERSION-is-explicit" '^[0-9]+\.[0-9]+\.[0-9]+$' "$nv"
record "build:NODE_VERSION" "$nv"

# ─── 4. the recipe actually builds ─────────────────────────────────────────────
# The gate that the registry contract used to provide implicitly: CI proved the image
# built before anyone could pin its digest. Nothing proves that now unless this does, and
# a Containerfile that fails to build is not a degraded release, it is no release —
# every student's install stops at the same step.
#
# Slow and disk-hungry by nature, so it is opt-in even within this opt-in tier: it needs
# several GB free and many minutes. Run it on a machine with room before the quarter.
if [ "${CS193V_RELEASE_BUILD:-}" = yes ]; then
    assert_ok "build:no-cache-build-succeeds" "$REPO/cs193v" --rebuild --no-cache

    # ─── 4b. the launcher and podman agree about what the steps ARE ────────────
    # THE ONE PLACE THIS CAN BE SETTLED. The progress meter names each step from `####>`
    # markers in the Containerfile, which means the launcher numbers that file's instructions
    # itself and trusts its own numbering to pick the label for `STEP n/N`. Nothing on a
    # student's machine can be allowed to fail over a disagreement -- a label is not
    # load-bearing, so the launcher drops the labels and finishes the build -- and that is
    # exactly why the disagreement has to be a hard failure HERE instead, in staff's hands,
    # with real podman and the real Containerfile.
    #
    # 15-containerfile-parse.sh pins the parsing RULES against fixtures in half a second. It
    # cannot pin them against podman, because only podman knows what podman does.
    # ASKED OF THE LAUNCHER, not globbed. This was `ls -t "$TMPDIR"/cs193v-build-*.log | head -1`
    # -- the newest one on the MACHINE. The launcher keys the name on a hash of the course
    # directory and the instance precisely so two instances do not overwrite each other's
    # (BUILD_LOG in ./cs193v), and the glob threw that away: a colleague's --rebuild finishing
    # after ours handed this section THEIR build to diff against OUR Containerfile, and the stale
    # logs of every instance ever built here are candidates too, since the launcher deliberately
    # never deletes them. Same fix as #46 -- one derivation, from the launcher, via --dev-tunnel.
    #
    # Through fwd_init rather than a second call to the seam, so there is still only one place that
    # parses it. It used to inherit a hard-fail from fwd_init -- fewer than two declared ports and
    # the whole release gate stopped for a reason that was about ports and not about this check.
    # fwd_init reads no ports at all now, so that coupling is gone.
    fwd_init
    log="$FWD_BUILDLOG"
    [ -n "$log" ] && [ -f "$log" ] || log=''
    if [ -z "$log" ]; then
        fail "steps:build-log-was-found" "cs193v --dev-tunnel names this instance's build log as
${FWD_BUILDLOG:-<nothing>}, and there is no file there after a build."
    else
        record "steps:build-log" "$log"
        # Squeezed on both sides, the way the launcher compares them: podman deletes the
        # backslash-newline of a continued instruction and keeps every other byte, so the
        # joined text differs from ours only in runs of whitespace.
        podman_steps="$(sed -n 's/^STEP \([0-9]*\)\/[0-9]*: /\1\t/p' "$log" \
                        | awk -F'\t' '{ t = $2; gsub(/[ \t]+/, " ", t)
                                        sub(/^ /, "", t); sub(/ $/, "", t); print $1"\t"t }')"
        n_podman="$(sed -n 's/^STEP [0-9]*\/\([0-9]*\):.*/\1/p' "$log" | head -1)"
        ours="$("$REPO/cs193v" --dev-steps | cut -f1,3)"
        n_ours="$(printf '%s\n' "$ours" | wc -l | tr -d ' ')"

        # podman adds one step of its own: the LABEL it synthesizes from the launcher's
        # --label cs193v.buildhash flag, which has no line in the Containerfile. It lands
        # LAST, which is what keeps every parsed label correct without the two totals ever
        # having to match -- so this asserts the relationship rather than a number.
        record "steps:counts" "containerfile=$n_ours podman=$n_podman"
        assert_eq "steps:podman-adds-only-the-injected-label" \
                  "$(( n_ours + 1 ))" "${n_podman:-0}"

        # And every instruction podman announced is the one we think it is. This is the
        # assertion that a heredoc, an `# escape=` directive or a mishandled continuation
        # would break, and the only one that would notice.
        diff_out="$(diff <(printf '%s\n' "$podman_steps" | head -n "$n_ours") \
                         <(printf '%s\n' "$ours") 2>&1 || true)"
        assert_eq "steps:every-instruction-matches-podman" "" "$diff_out"

        # A build that had to switch the labels off says so in the log; on a build of the
        # real Containerfile by real podman it never should.
        assert_eq "steps:labels-were-not-switched-off" "0" \
                  "$(grep -c 'not the instruction the launcher parsed' "$log" || true)"
    fi
else
    skip "build:no-cache-build-succeeds" "set CS193V_RELEASE_BUILD=yes (needs ~6 GB free and many minutes)"
    skip "steps:every-instruction-matches-podman" "needs the real build above"
fi

# ─── 5. the published checksums the install docs promise ───────────────────────
# Both installers say their SHA-256 is published next to the download link, which is the
# only thing making "read it before you run it" checkable for a student.
record "checksum:$PRIVATE/install-cs193v.sh"          "$(sha256sum $PRIVATE/install-cs193v.sh | awk '{print $1}')"
record "checksum:$PRIVATE/install-cs193v-windows.cmd" "$(sha256sum $PRIVATE/install-cs193v-windows.cmd | awk '{print $1}')"
note_file="$REPO/PUBLISHED-CHECKSUMS.txt"
if [ -f "$note_file" ]; then
    for f in $PRIVATE/install-cs193v.sh $PRIVATE/install-cs193v-windows.cmd; do
        want="$(grep -F "$f" "$note_file" | awk '{print $1}' | head -1)"
        assert_eq "checksum:$f-matches-published" \
                  "$(sha256sum "$f" | awk '{print $1}')" "$want"
    done
else
    skip "checksum:matches-published" "no PUBLISHED-CHECKSUMS.txt to compare against"
fi

# ─── 6. the token expiry a student is told to choose ───────────────────────────
# setup-git hands students a prefilled link with an expiration in it, and names the same date in
# the by-hand steps. That date is the one value in this project that goes stale on a CALENDAR
# rather than on a change to the code, so nothing in the everyday suite can catch it: every test
# still passes, and a student is told to pick a date in the past.
#
# THIS LIVES IN THE RELEASE TIER for exactly that reason. A check in `static` would start failing
# one day for everybody with no change to blame, which is how a suite gets ignored. Here it is
# read once before the quarter starts, which is when the date needs setting anyway.
#
# setup-git clamps a stale date to a 30-day floor rather than emitting a negative lifetime, so the
# consequence of ignoring this is a token that expires mid-quarter, not a broken link.
expiry="$(sed -n 's/^CS193V_TOKEN_EXPIRY="${CS193V_TOKEN_EXPIRY:-\([0-9-]*\)}".*/\1/p' \
          $PRIVATE/files/setup-git | head -1)"
record "setup-git:token-expiry" "$expiry"
assert_match "setup-git:token-expiry-is-a-date" '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' "$expiry"
# 60 days, not one: a date inside the quarter it is meant to outlast is as wrong as a past one,
# and a token that dies in week 8 costs every student who has one a repeat of setup-git.
# The lifetime is read back out of setup-git's own link rather than recomputed here, so the two
# cannot disagree about a leap year. The two path overrides are the same ones 45-setup-git.sh
# uses: this runs on the HOST, where the image's /etc/cs193v does not exist.
days="$(CS193V_TOKEN_EXPIRY="$expiry" \
        CS193V_UI="$PRIVATE/files/cs193v-ui.sh" \
        CS193V_MESSAGES="$PRIVATE/files/setup-git-messages.txt" \
        bash "$PRIVATE/files/setup-git" --dev-print-token-url 2>/dev/null \
        | sed -n 's/.*expires_in=\([0-9]*\).*/\1/p')"
record "setup-git:token-lifetime-days" "$days"
if [ -n "$days" ] && [ "$days" -ge 60 ]; then
    pass "setup-git:token-expiry-is-comfortably-in-the-future"
else
    fail "setup-git:token-expiry-is-comfortably-in-the-future" \
         "CS193V_TOKEN_EXPIRY in files/setup-git is $expiry, which is less than 60 days away.
Set it past the end of the quarter — students are told to choose it, and the prefilled
link carries it as a lifetime in days."
fi

# The organization and the sandbox repository are the other two values a new quarter moves, and
# a placeholder left in either would fail on every student at once. Recorded rather than asserted
# against a literal: the point is that a human reads them before the quarter starts.
for v in CS193V_GH_ORG CS193V_GH_SANDBOX; do
    val="$(sed -n "s/^$v=\"\${$v:-\([^}]*\)}\".*/\1/p" $PRIVATE/files/setup-git | head -1)"
    record "setup-git:$v" "$val"
    assert_ne "setup-git:$v-is-set" "" "$val"
    assert_says_not "setup-git:$v-is-not-a-placeholder" "CHANGEME" "$val"
done
