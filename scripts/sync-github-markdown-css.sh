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
DEST_DIR="$REPO_ROOT/Sources/GalleyCoreKit/Resources/Templates.bundle"
MANIFEST="$REPO_ROOT/docs/vendored-templates.md"

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

echo "==> Copying github-markdown.css → GitHub-vendor.css"
cp "$SRC_DIR/github-markdown.css" "$DEST_DIR/GitHub-vendor.css"

echo "==> Copying license → GitHub-vendor-LICENSE"
cp "$SRC_DIR/license" "$DEST_DIR/GitHub-vendor-LICENSE"

SOURCE_SHA="$(shasum -a 256 "$DEST_DIR/GitHub-vendor.css" | awk '{print $1}')"
TODAY="$(date -u +%Y-%m-%d)"

mkdir -p "$(dirname "$MANIFEST")"
{
    echo "# Vendored Template CSS"
    echo
    echo "Upstream stylesheets vendored into"
    echo "\`Sources/GalleyCoreKit/Resources/Templates.bundle/\`."
    echo "Re-sync with the per-repo scripts in \`Scripts/\`."
    echo
    echo "## github-markdown-css"
    echo
    echo "- Source: <https://github.com/sindresorhus/github-markdown-css>"
    echo "- License: MIT (see \`GitHub-vendor-LICENSE\`)"
    echo "- Pinned version: \`${VERSION}\`"
    echo "- Vendored file: \`GitHub-vendor.css\` (SHA-256 \`${SOURCE_SHA}\`)"
    echo "- Last sync: ${TODAY}"
    echo "- Sync command: \`./Scripts/sync-github-markdown-css.sh\`"
    echo
    echo "Galley-specific overrides (page layout, print rules, mermaid)"
    echo "live in \`GitHub-overrides.css\` and load *after* the vendor file."
} > "$MANIFEST"

echo "==> Done. Files updated:"
echo "    $DEST_DIR/GitHub-vendor.css"
echo "    $DEST_DIR/GitHub-vendor-LICENSE"
echo "    $MANIFEST"
echo
echo "Next steps:"
echo "  1. Verify GitHub.html wraps content in <article class=\"markdown-body\">."
echo "  2. Confirm GitHub-vendor.css and GitHub-vendor-LICENSE are members of"
echo "     the GalleyCoreKit target's Templates.bundle resources in Xcode."
echo "  3. Build the Viewer scheme and spot-check a markdown doc with the"
echo "     GitHub template selected."
