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

# ─── 1. CI, which does not exist ───────────────────────────────────────────────
# README.md and the Containerfile both point at it. Without it there is no multi-arch
# image, so IMAGE= can never be filled, so every student runs permanently in dev mode and
# sees the "tell course staff — this line should not appear" warning on every launch.
# It also makes VERIFICATION.md §A.2's manifest assertions, §A.12's digest check and
# §9.1's --update path unrunnable by construction.
assert_file "ci:workflow-exists" "$REPO/.github/workflows/build.yml"
if [ -f "$REPO/.github/workflows/build.yml" ]; then
    wf="$(cat "$REPO/.github/workflows/build.yml")"
    assert_contains "ci:builds-both-architectures" "linux/arm64" "$wf"
    assert_contains "ci:builds-amd64"              "linux/amd64" "$wf"
    # The digest pin is only meaningful if the build is reproducible from pinned inputs.
    assert_contains "ci:pins-vercel-version"       "vercel_version" "$wf"
    assert_contains "ci:pins-claude-code-version"  "claude_code_version" "$wf"
    assert_contains "ci:prints-the-manifest-digest" "digest" "$wf"
else
    skip "ci:builds-both-architectures"      "no workflow file"
    skip "ci:builds-amd64"                   "no workflow file"
    skip "ci:pins-vercel-version"            "no workflow file"
    skip "ci:pins-claude-code-version"       "no workflow file"
    skip "ci:prints-the-manifest-digest"     "no workflow file"
fi
# README lists the workflow in its file map, so the two must not drift apart.
assert_contains "ci:readme-references-it" ".github/workflows/build.yml" "$(cat $PRIVATE/README.md)"

# ─── 2. the installer's repository ─────────────────────────────────────────────
# REPO_OWNER=CHANGEME makes the tarball URL a 404, so the installer cannot complete at all
# and VERIFICATION.md §1 and §A.12 cannot be run as shipped.
owner="$(sed -n 's/^REPO_OWNER="\(.*\)".*/\1/p' $PRIVATE/install-cs193v.sh | head -1)"
assert_ne "installer:REPO_OWNER-is-set" "CHANGEME" "$owner"
record    "installer:REPO_OWNER" "$owner"
assert_ne "installer:REPO_OWNER-not-empty" "" "$owner"

# ─── 3. the pinned image ───────────────────────────────────────────────────────
# Pinned by MANIFEST-LIST digest, not a per-architecture digest, so one pin serves both the
# arm64 and amd64 legs.
img="$(sed 's/#.*//' $REPO/.config/container.args | sed -n 's/^IMAGE=\(.*\)/\1/p' | tr -d ' ' | head -1)"
assert_ne "image:IMAGE-is-pinned" "" "$img"
record    "image:IMAGE" "${img:-<empty: dev mode>}"
if [ -n "$img" ]; then
    assert_contains "image:pinned-by-digest-not-tag" "@sha256:" "$img"
    assert_not_contains "image:not-pinned-to-latest" ":latest" "$img"
    # A published image must actually be published.
    if command -v podman >/dev/null 2>&1; then
        assert_ok "image:pin-resolves-in-the-registry" podman manifest inspect "$img"
        if podman manifest inspect "$img" >/dev/null 2>&1; then
            plats="$(podman manifest inspect "$img" \
                     | python3 -c 'import json,sys
d=json.load(sys.stdin)
print(" ".join(sorted("%s/%s" % (m["platform"]["os"], m["platform"]["architecture"])
                      for m in d.get("manifests", []))))' 2>/dev/null)"
            record "image:platforms" "$plats"
            assert_contains "image:manifest-has-amd64" "linux/amd64" "$plats"
            assert_contains "image:manifest-has-arm64" "linux/arm64" "$plats"
        fi
    else
        skip "image:pin-resolves-in-the-registry" "podman not installed"
    fi
else
    skip "image:pinned-by-digest-not-tag"    "IMAGE= is empty"
    skip "image:not-pinned-to-latest"        "IMAGE= is empty"
    skip "image:pin-resolves-in-the-registry" "IMAGE= is empty"
fi

# ─── 4. reproducible build inputs ──────────────────────────────────────────────
# `latest` in a build ARG makes the digest pin a lie: the same Containerfile at the same
# commit produces different images on different days, so "students are all on the image we
# tested" stops being true.
for arg in VERCEL_VERSION CLAUDE_CODE_VERSION; do
    v="$(sed -n "s/^ARG $arg=\(.*\)/\1/p" $PRIVATE/Containerfile | head -1)"
    record "build:$arg" "$v"
    assert_ne "build:$arg-is-pinned" "latest" "$v"
done
# NODE_VERSION is already pinned; assert it stays that way and looks like a real version.
nv="$(sed -n 's/^ARG NODE_VERSION=\(.*\)/\1/p' $PRIVATE/Containerfile | head -1)"
assert_match "build:NODE_VERSION-is-explicit" '^[0-9]+\.[0-9]+\.[0-9]+$' "$nv"
record "build:NODE_VERSION" "$nv"

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
