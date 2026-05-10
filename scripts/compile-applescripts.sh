#!/usr/bin/env bash
#
# Compile every .applescript inside the just-copied product Resources to a
# sibling .scpt and remove the source. Runs as a Run Script build phase after
# Copy Bundle Resources, so any .bundle folder reference that ships
# AppleScript source gets converted in place.
#
# Source .applescript files stay diffable in the repo; only the compiled
# .scpt ships in the product.

set -euo pipefail

resources="${TARGET_BUILD_DIR:?TARGET_BUILD_DIR not set}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?UNLOCALIZED_RESOURCES_FOLDER_PATH not set}"

if [[ ! -d "$resources" ]]; then
    echo "warning: resources directory not found: $resources"
    exit 0
fi

# -print0 / read -d '' so paths with spaces (we ship a few) survive the loop.
find "$resources" -type f -name "*.applescript" -print0 | while IFS= read -r -d '' src; do
    out="${src%.applescript}.scpt"
    /usr/bin/osacompile -o "$out" "$src"
    rm -f "$src"
done
