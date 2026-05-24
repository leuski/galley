#!/usr/bin/env bash
#
# Remove the standalone Galley Server.app from BUILT_PRODUCTS_DIR after it has
# been embedded into Galley.app. The nested copy inside
# Galley.app/Contents/Resources is what ships; the top-level copy is duplicate
# build output. Runs as a Run Script build phase after the embed phases.

set -euo pipefail

# Only applies to the macOS slice; visionOS does not embed Galley Server.app.
if [[ "${PLATFORM_NAME:-}" != "macosx" ]]; then
    exit 0
fi

PRODUCT="${BUILT_PRODUCTS_DIR:?BUILT_PRODUCTS_DIR not set}/Galley Server.app"

if [[ -d "$PRODUCT" ]]; then
    echo "Remove Galley Server.app from build products: $PRODUCT"
    rm -rf "$PRODUCT"
fi
