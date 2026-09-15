#!/usr/bin/env bash
# Rebuild .private/macapp/CS193V.app from cs193v-app.applescript  (#134)
#
# DEVELOPER-ONLY, AND THE ARTIFACT IS COMMITTED. This is the same trade make-icons.sh makes and
# for a stronger reason: a student's Mac cannot do this work at all. `codesign` shells out to
# /usr/bin/codesign_allocate, which is a Command Line Tools shim -- byte-identical to the
# /usr/bin/git stub, 118640 bytes, six `xcselect` references -- so on a Mac without the CLT
# `codesign` can verify but not sign. A bundle compiled there could not be re-sealed after its
# Info.plist was written, and a bundle that fails `codesign -v` has a damaged identity, which is
# the one thing the applet exists to have.
#
# THE COMMITTED BUNDLE IS FULLY GENERIC. Nothing student-specific is baked in: the course
# directory is read at launch from ~/Library/Application Support/CS193V/course-dir, which the
# installer writes. That is what makes a prebuilt artifact possible, and it is also required --
# writing inside the bundle would break the seal.
#
# GIT HANDLING IS LOAD-BEARING. Measured through `git archive` under core.autocrlf=true:
# Contents/Info.plist and Contents/_CodeSignature/CodeResources are XML text and get mangled,
# which makes `codesign -v` report `invalid Info.plist`. The Mach-O itself survives -- git
# auto-detects it as binary -- so the app still LAUNCHES, but its signature is no longer valid.
# `.gitattributes` must therefore carry a path rule for this whole directory; with one in place
# the round-trip is byte-identical and `codesign -v` returns VALID.
set -eu

HERE="$(cd -- "$(dirname -- "$0")" && pwd -P)"
PRIVATE="$(cd -- "$HERE/.." && pwd -P)"
SRC="$HERE/cs193v-app.applescript"
HELPER="$HERE/cs193v-run"
ICNS="$PRIVATE/icons/cs193v.icns"
CAT="$PRIVATE/course-install-messages.txt"
APP="$HERE/CS193V.app"

# THE MACOS-ONLY DOOR, stated once and early, the way make-icons.sh does it: a Linux developer
# gets told what is wrong rather than four tool-not-found errors from inside a pipeline.
[ "$(uname -s)" = Darwin ] || {
    printf 'make-macapp.sh needs macOS: osacompile and codesign have no Linux equivalent.\n' >&2
    printf 'The applet is committed, so this only needs running when the AppleScript changes.\n' >&2
    exit 1
}
# codesign IS checked here even though it ships with macOS, because what it NEEDS may not:
# signing requires codesign_allocate from the Command Line Tools. Fail now, with the fix named.
for t in osacompile codesign plutil; do
    command -v "$t" >/dev/null || { printf 'missing: %s\n' "$t" >&2; exit 1; }
done
[ -x /usr/libexec/PlistBuddy ] || { printf 'missing: /usr/libexec/PlistBuddy\n' >&2; exit 1; }
for f in "$SRC" "$HELPER" "$ICNS" "$CAT"; do
    [ -f "$f" ] || { printf 'missing input: %s\n' "$f" >&2; exit 1; }
done

# ─── 1. the prose, read out of the catalogue rather than duplicated here ───────
# One definition of every student-facing string, which is the rule 10-static.sh's text116 lint
# enforces for course-install.sh. The applet cannot read the catalogue at launch -- it ships
# without it -- so the strings are baked in at build time instead.
# NAMED `msg`, AND THAT IS NOT COSMETIC: 20-messages.sh finds catalogue readers by grepping for
# `msg <key>` over the files in its IREADERS list, so a reader under any other name is invisible
# to the reconciliation and every key it consumes reports as an orphan. Measured -- the first
# version of this script used a different name and turned itext:no-orphans red for two keys.
#
# It is a plainer function than cs193v-ui.sh's msg(): no {{PLACEHOLDER}} substitution, because
# nothing baked into the applet takes one. That makes it a sixth deliberate duplication of a ui
# helper, named here rather than hidden, for the reason the other five are.
msg() {                               # msg KEY -> the body, staff notes and blanks stripped
    awk -v k="[[$1]]" '
        index($0, k) == 1 { f = 1; next }
        f && /^\[\[/      { exit }
        f && /^#/         { next }
        f                 { print }' "$CAT" \
    | sed -e 's/^[[:space:]]*//' -e '/^$/d' | awk '{ printf "%s%s", sep, $0; sep = " " } END { print "" }'
}
# AppleScript string escaping: backslash first, then quote, or the first pass eats the second's.
as_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

LABEL="$(sed -n 's/^MAC_APP_LABEL="\([^"]*\)".*/\1/p' "$PRIVATE/course-install.sh")"
NOT_INSTALLED="$(msg mac-app.not-installed)"
LAUNCH_FAILED="$(msg mac-app.launch-failed)"
AUTOMATION_WHY="$(msg mac-app.automation-why)"
for pair in "LABEL=$LABEL" "NOT_INSTALLED=$NOT_INSTALLED" "LAUNCH_FAILED=$LAUNCH_FAILED" \
            "AUTOMATION_WHY=$AUTOMATION_WHY"; do
    [ -n "${pair#*=}" ] || { printf 'empty string for %s -- is the catalogue key missing?\n' "${pair%%=*}" >&2; exit 1; }
done

# ─── 2. substitute, compile ───────────────────────────────────────────────────
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cs193v-macapp.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
sed -e "s|@@LABEL@@|$(as_escape "$LABEL")|g" \
    -e "s|@@NOT_INSTALLED@@|$(as_escape "$NOT_INSTALLED")|g" \
    -e "s|@@LAUNCH_FAILED@@|$(as_escape "$LAUNCH_FAILED")|g" \
    "$SRC" > "$TMP/app.applescript"
# THE PATTERN IS ANCHORED TO A REAL PLACEHOLDER, not to a bare `@@`. The source DOCUMENTS the
# placeholder mechanism in a comment, and a loose grep matches that documentation and refuses a
# perfectly substituted file -- measured, first run. Same hazard 10-static.sh:13 records.
if grep -qE '@@[A-Z_]+@@' "$TMP/app.applescript"; then
    printf 'unsubstituted placeholder left in the source:\n' >&2
    grep -nE '@@[A-Z_]+@@' "$TMP/app.applescript" >&2; exit 1
fi

rm -rf "$APP"
osacompile -o "$APP" "$TMP/app.applescript"

# ─── 3. our resources ─────────────────────────────────────────────────────────
cp "$ICNS" "$APP/Contents/Resources/cs193v.icns"
cp "$HELPER" "$APP/Contents/Resources/cs193v-run"
chmod +x "$APP/Contents/Resources/cs193v-run"
# osacompile ships its own droplet icon; ours replaces it rather than sitting beside it.
rm -f "$APP/Contents/Resources/applet.icns"

# AND ITS DROPLET ASSET CATALOGUE GOES TOO: Assets.car is 375 KB of the 740 KB bundle, it is
# osacompile's template rather than anything of ours -- a bare `osacompile -e 'return 1'` app
# contains the identical file -- and this applet has no droplet UI. Measured before removing it:
# an applet without Assets.car runs, runs again on relaunch, and `display alert` still works,
# which is the only AppleScript UI this one uses. The seal is re-made below, after this.
#
# WHY IT IS WORTH THE LINE: the student tree has a size ceiling (11-export.sh), raised once
# already for the icons. Keeping 375 KB of unused template assets would have meant raising it
# again to ship something nothing reads.
rm -f "$APP/Contents/Resources/Assets.car"

# ─── 3b. strip extended attributes, because a staff Mac's are not a student's ──
# MEASURED, AND IT HAD ALREADY HAPPENED: .private/icons/cs193v.icns carried
# `com.apple.quarantine: 0082;...;Preview;` -- somebody opened it in Preview while the artwork was
# being worked on -- and the `cp` above copied that straight into the bundle we sign. Git stores no
# xattrs, so it never reached a student (verified through `git archive` | tar: zero xattrs in the
# export). But it is a trap worth closing at the source rather than relying on git to launder it:
# quarantine on any file inside a bundle can make Gatekeeper assess an app that would otherwise
# never be assessed, and this builder is the one place that decides what goes inside the seal.
#
# BEFORE THE RE-SEAL BELOW, deliberately. Clearing xattrs does not change file contents, so it
# cannot invalidate a signature -- but doing it after signing would be relying on that, and the
# order here makes it a non-question.
xattr -cr "$APP"

# ─── 4. the Info.plist keys osacompile does not write ─────────────────────────
# NOT LSArchitecturePriority / LSRequiresNativeExecution: those existed only to tell Launch
# Services what a shell script could not. A universal Mach-O declares its own architectures, so
# writing them now would be dead weight.
pb() { /usr/libexec/PlistBuddy -c "$1" "$APP/Contents/Info.plist" >/dev/null; }
pb "Set :CFBundleName $LABEL" 2>/dev/null || pb "Add :CFBundleName string $LABEL"
pb "Set :CFBundleDisplayName $LABEL" 2>/dev/null || pb "Add :CFBundleDisplayName string $LABEL"
pb "Set :CFBundleIdentifier edu.stanford.cs193v.launcher" 2>/dev/null \
    || pb "Add :CFBundleIdentifier string edu.stanford.cs193v.launcher"
pb "Set :CFBundleIconFile cs193v.icns" 2>/dev/null || pb "Add :CFBundleIconFile string cs193v.icns"
pb "Set :LSMinimumSystemVersion 12.0" 2>/dev/null || pb "Add :LSMinimumSystemVersion string 12.0"
/usr/libexec/PlistBuddy -c "Delete :NSAppleEventsUsageDescription" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :NSAppleEventsUsageDescription string $AUTOMATION_WHY" \
    "$APP/Contents/Info.plist" >/dev/null
plutil -lint "$APP/Contents/Info.plist" >/dev/null || { printf 'the Info.plist we wrote is malformed\n' >&2; exit 1; }

# ─── 5. re-seal, because every edit above invalidated osacompile's signature ──
codesign --force --sign - "$APP"
codesign --verify --verbose=1 "$APP" || { printf 'the bundle does not verify after signing\n' >&2; exit 1; }

# ─── 6. say what was built, so a rebuild is auditable from the terminal ───────
printf 'built %s\n' "$APP"
printf '  executable : %s\n' "$(lipo -archs "$APP/Contents/MacOS/applet" 2>/dev/null || echo '?')"
printf '  signature  : %s\n' "$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Signature=//p')"
printf '  identifier : %s\n' "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null)"
printf '  files      : %s\n' "$(find "$APP" -type f | wc -l | tr -d ' ')"
