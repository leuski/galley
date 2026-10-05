#!/usr/bin/env bash
#
# Vendor Temml (TeX → MathML) into GalleyCoreKit's Temml.bundle.
#
# The built-in Markdown processor lifts `$…$` / `$$…$$` spans out of the
# source and hands each one to Temml, running inside JavaScriptCore, to
# produce a <math> element that WebKit renders natively — no page-side
# script, so equations show up identically in the Viewer, Quick Look,
# print / PDF export, and over the Vision Pro tunnel.
#
# Only the browser build (`dist/temml.min.js`) and the LICENSE are
# vendored. Temml's optional CSS + woff2 font (which pick a math font
# for the page) are deliberately not shipped: templates stay untouched
# and WebKit falls back to the system math font.
#
# Usage:   ./Scripts/sync-temml.sh [version]
# Default: pinned $DEFAULT_VERSION below.

set -euo pipefail

DEFAULT_VERSION="0.13.5"
VERSION="${1:-$DEFAULT_VERSION}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="$REPO_ROOT/Sources/GalleyCoreKit/Render/Math/Temml.bundle"
MANIFEST="$REPO_ROOT/docs/vendored-templates.md"
SECTION="temml"

mkdir -p "$DEST_DIR"

TARBALL_URL="https://github.com/ronkok/Temml/archive/refs/tags/v${VERSION}.tar.gz"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> Fetching Temml v${VERSION}"
curl -fsSL "$TARBALL_URL" -o "$TMP_DIR/src.tar.gz"
tar -xzf "$TMP_DIR/src.tar.gz" -C "$TMP_DIR"

SRC_DIR="$TMP_DIR/Temml-${VERSION}"
if [[ ! -d "$SRC_DIR" ]]; then
    echo "error: expected $SRC_DIR after extract" >&2
    exit 1
fi

echo "==> Copying dist/temml.min.js → Temml.bundle/temml.min.js"
cp "$SRC_DIR/dist/temml.min.js" "$DEST_DIR/temml.min.js"

# Release tags are dist-only trees (no LICENSE at the tag), so the
# license text comes from the default branch.
LICENSE_URL="https://raw.githubusercontent.com/ronkok/Temml/main/LICENSE"
echo "==> Fetching LICENSE → Temml.bundle/LICENSE"
curl -fsSL "$LICENSE_URL" -o "$DEST_DIR/LICENSE"

SOURCE_SHA="$(shasum -a 256 "$DEST_DIR/temml.min.js" | awk '{print $1}')"
SOURCE_BYTES="$(wc -c < "$DEST_DIR/temml.min.js" | tr -d ' ')"
TODAY="$(date -u +%Y-%m-%d)"

SECTION_FILE="$TMP_DIR/section.md"
{
    echo "## temml"
    echo
    echo "- Source: <https://github.com/ronkok/Temml>"
    echo "- License: MIT (see \`Temml.bundle/LICENSE\`)"
    echo "- Pinned version: \`${VERSION}\`"
    echo "- Vendored: \`Temml.bundle/temml.min.js\` (${SOURCE_BYTES} bytes, SHA-256 \`${SOURCE_SHA}\`)"
    echo "- Last sync: ${TODAY}"
    echo "- Sync command: \`./Scripts/sync-temml.sh\`"
    echo
    echo "Not a template: Temml is the TeX → MathML converter the built-in"
    echo "Markdown processor runs inside JavaScriptCore (\`TemmlMathRenderer\`)."
    echo "Only the browser build + license are vendored; Temml's optional"
    echo "CSS/font files are intentionally omitted so templates need no"
    echo "changes and WebKit uses the system math font."
} > "$SECTION_FILE"

if ! grep -q "<!-- BEGIN: ${SECTION} -->" "$MANIFEST"; then
    {
        echo
        echo "<!-- BEGIN: ${SECTION} -->"
        echo
        echo "<!-- END: ${SECTION} -->"
    } >> "$MANIFEST"
fi

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
echo "    $DEST_DIR/temml.min.js"
echo "    $DEST_DIR/LICENSE"
echo "    $MANIFEST (section: $SECTION)"
