#!/usr/bin/env bash
#
# Phase 1 release: build an unsigned (or ad-hoc / free-team-signed) .app,
# zip it, and publish a GitHub release.
#
# Usage:
#   scripts/release.sh v0.1.0              # build, install, tag, publish
#   scripts/release.sh --dry-run v0.1.0    # build, install, zip — no tag, no publish
#
# Requirements: Xcode, gh CLI authenticated, clean git tree (unless --dry-run).

set -euo pipefail

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  shift
fi

if [[ $# -ne 1 ]]; then
  echo "usage: $0 [--dry-run] <tag>   e.g. $0 v0.1.0" >&2
  exit 1
fi

TAG="$1"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

if [[ $DRY_RUN -eq 0 && -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is dirty. commit or stash first." >&2
  exit 1
fi

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: tag must look like v1.2.3 (got '$TAG')" >&2
  exit 1
fi

MARKETING_VERSION="${TAG#v}"
BUILD_NUMBER="$(git rev-list --count HEAD)"

SCHEME="Viewer"
APP_NAME="Galley.app"
BUILD_DIR="$PROJECT_ROOT/build/release"
ARCHIVE_PATH="$BUILD_DIR/Galley.xcarchive"
ZIP_PATH="$BUILD_DIR/Galley-$TAG.zip"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Archiving $SCHEME ($TAG, build $BUILD_NUMBER)"
xcodebuild \
  -project Galley.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS" \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  archive

APP_SRC="$ARCHIVE_PATH/Products/Applications/$APP_NAME"
if [[ ! -d "$APP_SRC" ]]; then
  echo "error: built app not found at $APP_SRC" >&2
  exit 1
fi

# Ad-hoc re-sign, inside-out, preserving each component's entitlements.
#
# `codesign --force --deep --sign -` doesn't work here: it walks
# top-down, and xattr -cr has already invalidated nested seals, so
# codesign refuses with "nested code is modified or invalid". And
# without entitlements the Quick Look appex fails to register with
# pluginkit (silent — preview falls back to plain text).
#
# `--preserve-metadata=entitlements` doesn't work either: it reads
# from the *existing* signature, which means re-signing components
# first invalidates the host's record of nested seals before we get
# to re-sign the host itself.
#
# So: extract each component's entitlements to a temp file before
# re-signing, then re-apply via --entitlements. Order matters:
# frameworks → appex → nested .app → host.

ENTITLEMENTS_TMPDIR="$(mktemp -d -t galley-resign)"
trap 'rm -rf "$ENTITLEMENTS_TMPDIR"' EXIT

resign_adhoc() {
  local target="$1"
  local ent_file
  ent_file="$ENTITLEMENTS_TMPDIR/$(echo "$target" | shasum | cut -c1-16).plist"

  # Capture existing entitlements. The exit code is non-zero when there
  # are no entitlements; the empty-file check below handles that.
  codesign -d --entitlements "$ent_file" --xml "$target" 2>/dev/null || true

  if [[ -s "$ent_file" ]]; then
    codesign --force --sign - --entitlements "$ent_file" "$target"
  else
    codesign --force --sign - "$target"
  fi
}

ad_hoc_resign_bundle() {
  local app="$1"
  xattr -cr "$app"

  # Frameworks first (sign the versioned dir, not the symlinked root).
  local fw
  for fw in "$app/Contents/Frameworks/"*.framework; do
    [[ -d "$fw" ]] || continue
    resign_adhoc "$fw/Versions/A"
  done

  # App extensions.
  local appex
  for appex in "$app/Contents/PlugIns/"*.appex; do
    [[ -d "$appex" ]] || continue
    resign_adhoc "$appex"
  done

  # Nested helper apps inside Resources (e.g. Galley Server.app).
  local helper
  for helper in "$app/Contents/Resources/"*.app; do
    [[ -d "$helper" ]] || continue
    resign_adhoc "$helper"
  done

  # Host last.
  resign_adhoc "$app"
}

echo "==> Stripping provenance attrs and ad-hoc re-signing"
ad_hoc_resign_bundle "$APP_SRC"
codesign --verify --deep --strict --verbose=2 "$APP_SRC"

echo "==> Refreshing /Applications copy (overwrites the build phase's intermediate copy)"
INSTALLED="/Applications/$APP_NAME"
if [[ -d "$INSTALLED" ]]; then rm -rf "$INSTALLED"; fi
ditto "$APP_SRC" "$INSTALLED"
ad_hoc_resign_bundle "$INSTALLED"
codesign --verify --deep --strict --verbose=2 "$INSTALLED"

# Ad-hoc re-signing changes the bundle's code-signature hash on every
# run, which invalidates any existing SMAppService LaunchAgent
# registration: launchd's `copy_bundle_path` lookup against the BTM
# database returns nothing, so the agent fails to spawn with EX_CONFIG.
# Bootout the user-domain registration if it exists; the user can
# re-toggle the setting in Galley to re-register against the new
# bundle. (Idempotent — `bootout` exits 3 when the service isn't
# registered.)
echo "==> Resetting SMAppService registration for net.leuski.galley.server"
launchctl bootout "gui/$(id -u)/net.leuski.galley.server" 2>/dev/null \
  && echo "    booted out previous registration" \
  || echo "    no previous registration to remove"

echo "==> Zipping $APP_NAME"
ditto -c -k --keepParent --sequesterRsrc "$APP_SRC" "$ZIP_PATH"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "==> Dry run complete (no tag, no publish): $ZIP_PATH"
  exit 0
fi

echo "==> Tagging $TAG"
git tag -a "$TAG" -m "$TAG"
git push origin "$TAG"

echo "==> Creating GitHub release $TAG"
NOTES_FILE="$BUILD_DIR/NOTES.md"
cat > "$NOTES_FILE" <<EOF
## $TAG

**Ad-hoc signed build** (no Apple Developer account). macOS will block the
download until you remove the quarantine attribute.

\`\`\`
unzip Galley-$TAG.zip
mv "Galley.app" /Applications/
xattr -dr com.apple.quarantine "/Applications/Galley.app"
open "/Applications/Galley.app"
\`\`\`

### Updating from a previous release

Because the build is ad-hoc signed (no stable Team ID), each release
produces a new code-signature hash. macOS's Background Task Manager
treats it as a different app, so any previously-enabled
"Run Markdown Preview Server in background" toggle stops launching.

After replacing the app, open Galley → Settings → Server, then toggle
the server enable off and on once to refresh the registration.
EOF

gh release create "$TAG" "$ZIP_PATH" \
  --title "$TAG" \
  --notes-file "$NOTES_FILE"

echo "==> Done: $ZIP_PATH"
