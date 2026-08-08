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

# ─── 2. the recipe is the distribution, so its pins are the release gate ───────
# THIS SECTION REPLACED A REGISTRY CHECK, and it is stricter than the one it replaced.
#
# It used to assert that IMAGE= held a published manifest-list digest and that CI built
# both architectures. There is no registry now: .private/Containerfile is what ships, and
# every student builds it. A floating input used to mean CI drifted between runs and one
# artifact still reached everybody; now it means TWO STUDENTS GET DIFFERENT SOFTWARE, and
# nothing downstream can detect that it happened.
#
# Empty IMAGE= is therefore correct and expected. A value is a deliberate override — see
# .config/container.args — and only its shape is checked, not its existence.
img="$(sed 's/#.*//' $REPO/.config/container.args | sed -n 's/^IMAGE=\(.*\)/\1/p' | tr -d ' ' | head -1)"
record "image:IMAGE" "${img:-<empty: built locally, the normal state>}"
if [ -n "$img" ]; then
    # An override is allowed, but a floating one is not: it would reintroduce exactly the
    # drift this section exists to prevent, and silently.
    assert_contains "image:override-pinned-by-digest-not-tag" "@sha256:" "$img"
    assert_not_contains "image:override-not-latest" ":latest" "$img"
    if command -v podman >/dev/null 2>&1; then
        assert_ok "image:override-resolves-in-the-registry" podman manifest inspect "$img"
    else
        skip "image:override-resolves-in-the-registry" "podman not installed"
    fi
else
    skip "image:override-pinned-by-digest-not-tag"  "IMAGE= is empty (normal)"
    skip "image:override-not-latest"                "IMAGE= is empty (normal)"
    skip "image:override-resolves-in-the-registry"  "IMAGE= is empty (normal)"
fi

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
for arg in VERCEL_VERSION CLAUDE_CODE_VERSION PLAYWRIGHT_VERSION; do
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
    assert_ok "build:no-cache-build-succeeds" "$REPO/cs193v" --build --no-cache
else
    skip "build:no-cache-build-succeeds" "set CS193V_RELEASE_BUILD=yes (needs ~6 GB free and many minutes)"
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
