#!/usr/bin/env bash
#
# Vendor github-markdown-css from sindresorhus/github-markdown-css into the
# Templates bundle. CSS is upstream-untouched; Galley-specific tweaks live in
# GitHub-overrides.css and are loaded after the vendor file in GitHub.html.
#
# Usage:   ./Scripts/sync-github-markdown-css.sh [version]
# Default: pinned $DEFAULT_VERSION below.

set -euo pipefail

DEFAULT_VERSION="5.9.0"
VERSION="${1:-$DEFAULT_VERSION}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="$REPO_ROOT/Sources/GalleyCoreKit/Resources/Templates.bundle/GitHub"
MANIFEST="$REPO_ROOT/docs/vendored-templates.md"
SECTION="github-markdown-css"

mkdir -p "$DEST_DIR"

TARBALL_URL="https://github.com/sindresorhus/github-markdown-css/archive/refs/tags/v${VERSION}.tar.gz"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> Fetching github-markdown-css v${VERSION}"
curl -fsSL "$TARBALL_URL" -o "$TMP_DIR/src.tar.gz"
tar -xzf "$TMP_DIR/src.tar.gz" -C "$TMP_DIR"

SRC_DIR="$TMP_DIR/github-markdown-css-${VERSION}"
if [[ ! -d "$SRC_DIR" ]]; then
    echo "error: expected $SRC_DIR after extract" >&2
    exit 1
fi

echo "==> Copying github-markdown.css → GitHub/vendor.css"
cp "$SRC_DIR/github-markdown.css" "$DEST_DIR/vendor.css"

echo "==> Copying license → GitHub/LICENSE"
cp "$SRC_DIR/license" "$DEST_DIR/LICENSE"

SOURCE_SHA="$(shasum -a 256 "$DEST_DIR/vendor.css" | awk '{print $1}')"
TODAY="$(date -u +%Y-%m-%d)"

SECTION_FILE="$TMP_DIR/section.md"
{
    echo "## github-markdown-css"
    echo
    echo "- Source: <https://github.com/sindresorhus/github-markdown-css>"
    echo "- License: MIT (see \`Templates.bundle/GitHub/LICENSE\`)"
    echo "- Pinned version: \`${VERSION}\`"
    echo "- Vendored: \`Templates.bundle/GitHub/vendor.css\` (SHA-256 \`${SOURCE_SHA}\`)"
    echo "- Last sync: ${TODAY}"
    echo "- Sync command: \`./Scripts/sync-github-markdown-css.sh\`"
    echo
    echo "Galley-specific overrides (page chrome, print rules, mermaid)"
    echo "live in \`Templates.bundle/GitHub/overrides.css\` and load *after*"
    echo "the vendor file."
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
echo "    $MANIFEST (section: $SECTION)"
