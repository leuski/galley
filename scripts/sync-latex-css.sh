#!/usr/bin/env bash
#
# Vendor latex.css from vincentdoerig/latex-css into the Templates bundle.
# CSS is upstream-untouched; Galley-specific tweaks live in LaTeX/overrides.css
# and load after the vendor file in LaTeX.html.
#
# Upstream font refs are relative (`url("./fonts/...")`), so the fonts dir
# must sit beside style.css inside LaTeX/. Each @font-face lists woff2 first
# with format() hints, so pruning woff/ttf is invisible to WebKit.
#
# Usage:   ./Scripts/sync-latex-css.sh [version]
# Default: pinned $DEFAULT_VERSION below.

set -euo pipefail

DEFAULT_VERSION="1.13.0"
VERSION="${1:-$DEFAULT_VERSION}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="$REPO_ROOT/Sources/GalleyCoreKit/Resources/Templates.bundle/LaTeX"
MANIFEST="$REPO_ROOT/docs/vendored-templates.md"
SECTION="latex-css"

mkdir -p "$DEST_DIR"

TARBALL_URL="https://github.com/vincentdoerig/latex-css/archive/refs/tags/v${VERSION}.tar.gz"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> Fetching latex-css v${VERSION}"
curl -fsSL "$TARBALL_URL" -o "$TMP_DIR/src.tar.gz"
tar -xzf "$TMP_DIR/src.tar.gz" -C "$TMP_DIR"

SRC_DIR="$TMP_DIR/latex-css-${VERSION}"
if [[ ! -d "$SRC_DIR" ]]; then
    echo "error: expected $SRC_DIR after extract" >&2
    exit 1
fi

echo "==> Copying style.css → LaTeX/vendor.css"
cp "$SRC_DIR/style.css" "$DEST_DIR/vendor.css"

echo "==> Replacing fonts (woff2 only — WebKit honors format() hints)"
rm -rf "$DEST_DIR/fonts"
cp -R "$SRC_DIR/fonts" "$DEST_DIR/fonts"
find "$DEST_DIR/fonts" -type f \
    \( -name '*.woff' -o -name '*.ttf' -o -name '*.eot' -o -name '*.svg' \) \
    -delete

echo "==> Copying LICENSE → LaTeX/LICENSE"
cp "$SRC_DIR/LICENSE" "$DEST_DIR/LICENSE"

SOURCE_SHA="$(shasum -a 256 "$DEST_DIR/vendor.css" | awk '{print $1}')"
FONT_BYTES="$(find "$DEST_DIR/fonts" -type f -print0 \
    | xargs -0 wc -c | awk 'END {print $1}')"
TODAY="$(date -u +%Y-%m-%d)"

SECTION_FILE="$TMP_DIR/section.md"
{
    echo "## latex-css"
    echo
    echo "- Source: <https://github.com/vincentdoerig/latex-css>"
    echo "- License: MIT (see \`Templates.bundle/LaTeX/LICENSE\`)"
    echo "- Pinned version: \`${VERSION}\`"
    echo "- Vendored: \`Templates.bundle/LaTeX/vendor.css\` (SHA-256 \`${SOURCE_SHA}\`)"
    echo "- Fonts: \`Templates.bundle/LaTeX/fonts/\` (${FONT_BYTES} bytes, Latin Modern + Libertinus, woff2 only)"
    echo "- Last sync: ${TODAY}"
    echo "- Sync command: \`./Scripts/sync-latex-css.sh\`"
    echo
    echo "Galley-specific overrides (mermaid, print) live in"
    echo "\`Templates.bundle/LaTeX/overrides.css\` and load *after* the"
    echo "vendor file. The vendor's dark mode is an opt-in \`.latex-dark\`"
    echo "class; \`LaTeX.html\` ships a one-line script that toggles it on"
    echo "\`<html>\` when the system reports dark, so the vendor palette"
    echo "stays the single source of truth."
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
echo "    $DEST_DIR/fonts/  (woff2 only)"
echo "    $MANIFEST (section: $SECTION)"
