#!/bin/bash
#
# embed-server-as-galley.sh
#
# Run Script build phase for the Viewer target. Moves the freshly built
# "Galley Server.app" out of the products dir and into Galley.app's Resources,
# renamed to match the host app's wrapper name, so Finder/LaunchServices display
# the embedded server as "Galley" (Finder shows the bundle's folder name —
# CFBundleName / CFBundleDisplayName are ignored for that surface).
#
# No code signing here: this runs before Xcode's implicit signing step, so Xcode
# seals the renamed bundle when it signs Galley.app at the end. The server's own
# signature survives the move untouched (a signature seals contents, not the
# bundle's folder name/path).
#
# Add as the LAST Run Script phase on the Viewer target. Takes no arguments —
# it reads the standard Xcode build environment.

set -euo pipefail

: "${BUILT_PRODUCTS_DIR:?must run as an Xcode build phase}"
: "${TARGET_BUILD_DIR:?must run as an Xcode build phase}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?must run as an Xcode build phase}"
: "${WRAPPER_NAME:?must run as an Xcode build phase}"

SERVER_PRODUCT="Galley Server.app"
SRC="${BUILT_PRODUCTS_DIR}/${SERVER_PRODUCT}"
RES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
# Name the embedded server the same as its host wrapper (Galley.app) — that
# folder name is exactly what Finder displays.
DST="${RES}/${WRAPPER_NAME}"

if [[ ! -d "$SRC" ]]; then
  # Server not rebuilt this pass (incremental build) — keep the copy already in
  # Resources. Or this is a non-macOS slice (visionOS) with no server at all.
  if [[ -d "$DST" ]]; then
    echo "note: ${SERVER_PRODUCT} not rebuilt; keeping existing ${WRAPPER_NAME} in Resources"
  else
    echo "note: no ${SERVER_PRODUCT} in ${BUILT_PRODUCTS_DIR} (non-macOS build?); skipping"
  fi
  exit 0
fi

mkdir -p "$RES"
rm -rf "$DST"                       # replace any copy from a prior build
mv "$SRC" "$DST"
echo "embedded ${SERVER_PRODUCT} -> ${DST#$TARGET_BUILD_DIR/}"
