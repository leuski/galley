#!/usr/bin/env bash
#
# Vendor tufte-css from edwardtufte/tufte-css into the Templates bundle.
# CSS is upstream-untouched; Galley-specific tweaks live in Tufte-overrides.css
# and are loaded after the vendor file in Tufte.html.
#
# Upstream font references are relative (`url("et-book/...")`), so the et-book
# directory must sit beside the CSS in the bundle.
#
# Usage:   ./Scripts/sync-tufte-css.sh [version]
# Default: pinned $DEFAULT_VERSION below.

set -euo pipefail

DEFAULT_VERSION="1.8.0"
VERSION="${1:-$DEFAULT_VERSION}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="$REPO_ROOT/Sources/GalleyCoreKit/Resources/Templates.bundle/Tufte"
MANIFEST="$REPO_ROOT/docs/vendored-templates.md"
SECTION="tufte-css"

mkdir -p "$DEST_DIR"

TARBALL_URL="https://github.com/edwardtufte/tufte-css/archive/refs/tags/v${VERSION}.tar.gz"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> Fetching tufte-css v${VERSION}"
curl -fsSL "$TARBALL_URL" -o "$TMP_DIR/src.tar.gz"
tar -xzf "$TMP_DIR/src.tar.gz" -C "$TMP_DIR"

SRC_DIR="$TMP_DIR/tufte-css-${VERSION}"
if [[ ! -d "$SRC_DIR" ]]; then
    echo "error: expected $SRC_DIR after extract" >&2
    exit 1
fi

echo "==> Copying tufte.min.css → Tufte/vendor.css"
cp "$SRC_DIR/tufte.min.css" "$DEST_DIR/vendor.css"

echo "==> Replacing et-book fonts (woff only — see notes below)"
rm -rf "$DEST_DIR/et-book"
cp -R "$SRC_DIR/et-book" "$DEST_DIR/et-book"
# Tufte's @font-face rules list eot/woff/ttf/svg with format() hints.
# WebKit honors format() and only fetches the first supported format,
# which is woff. The eot/ttf/svg files are never requested, so deleting
# them saves ~1.15MB without touching the vendor CSS.
find "$DEST_DIR/et-book" -type f \
    \( -name '*.eot' -o -name '*.ttf' -o -name '*.svg' \) -delete

echo "==> Copying LICENSE → Tufte/LICENSE"
cp "$SRC_DIR/LICENSE" "$DEST_DIR/LICENSE"

SOURCE_SHA="$(shasum -a 256 "$DEST_DIR/vendor.css" | awk '{print $1}')"
FONT_BYTES="$(find "$DEST_DIR/et-book" -type f -print0 \
    | xargs -0 wc -c | awk 'END {print $1}')"
TODAY="$(date -u +%Y-%m-%d)"

SECTION_FILE="$TMP_DIR/section.md"
{
    echo "## tufte-css"
    echo
    echo "- Source: <https://github.com/edwardtufte/tufte-css>"
    echo "- License: MIT (see \`Templates.bundle/Tufte/LICENSE\`)"
    echo "- Pinned version: \`${VERSION}\`"
    echo "- Vendored: \`Templates.bundle/Tufte/vendor.css\` (SHA-256 \`${SOURCE_SHA}\`)"
    echo "- Fonts: \`Templates.bundle/Tufte/et-book/\` (${FONT_BYTES} bytes, five faces, woff only — eot/ttf/svg pruned at sync time)"
    echo "- Last sync: ${TODAY}"
    echo "- Sync command: \`./Scripts/sync-tufte-css.sh\`"
    echo
    echo "Galley-specific overrides (mermaid, print) live in"
    echo "\`Templates.bundle/Tufte/overrides.css\` and load *after* the"
    echo "vendor file. Tufte CSS already ships a dark-mode variant."
} > "$SECTION_FILE"

awk -v section="$SECTION" -v content_file="$SECTION_FILE" '
    $0 == "<!-- BEGIN: " section " -->" {
        print; print ""
        while ((getline line < content_file) > 0) print line
        print ""
        in_block = 1
        next
    }
    $0 == "<!-- END: " section " -->" { in_block = 0; print; next }
    !in_block { print }
' "$MANIFEST" > "$MANIFEST.new" && mv "$MANIFEST.new" "$MANIFEST"

echo "==> Done. Files updated:"
echo "    $DEST_DIR/vendor.css"
echo "    $DEST_DIR/LICENSE"
echo "    $DEST_DIR/et-book/  (fonts)"
echo "    $MANIFEST (section: $SECTION)"
