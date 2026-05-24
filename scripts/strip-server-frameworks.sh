#!/usr/bin/env bash
#
# Strip frameworks from the nested Galley Server.app embedded inside Galley.app
# and re-sign it. Galley.app ships its own copies of the shared frameworks at
# Galley.app/Contents/Frameworks; the nested Server.app would otherwise ship a
# duplicate set. Runs as a Run Script build phase after the embed phases.

set -euo pipefail

# Only applies to the macOS slice; visionOS has no nested Server.app.
if [[ "${PLATFORM_NAME:-}" != "macosx" ]]; then
    exit 0
fi

SERVER_APP="${CODESIGNING_FOLDER_PATH:?CODESIGNING_FOLDER_PATH not set}/Contents/Resources/Galley Server.app"

if [[ ! -d "$SERVER_APP" ]]; then
    echo "warning: Strip frameworks: nested Galley Server.app not found at $SERVER_APP, skipping."
    exit 0
fi

FRAMEWORKS_DIR="$SERVER_APP/Contents/Frameworks"
if [[ -d "$FRAMEWORKS_DIR" ]]; then
    count="$(ls "$FRAMEWORKS_DIR" | wc -l | tr -d ' ')"
    echo "Strip frameworks: removing $count frameworks from nested Galley Server.app"
    rm -rf "$FRAMEWORKS_DIR"
fi

if [[ "${CODE_SIGNING_ALLOWED:-}" != "NO" ]]; then
    echo "Strip frameworks: re-signing nested Galley Server.app"
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:?EXPANDED_CODE_SIGN_IDENTITY not set}" \
        --preserve-metadata=identifier,entitlements,flags --timestamp=none "$SERVER_APP"
fi
