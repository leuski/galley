#!/usr/bin/env bash
#
# Duplicate-code detection for the Lint/analysis build phase. Runs jscpd
# across Galley + the sibling packages and reprints each clone as an
# Xcode-parseable warning line:
#
#   /abs/path/File.swift:LINE: warning: <message>
#
# so clones surface in the build log and Issue navigator. Emits warnings
# only (never fails the build); skips cleanly when npx isn't available.

set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

cd "${SRCROOT:-$(dirname "$0")/..}"

if ! command -v npx > /dev/null; then
  echo "warning: npx not found; skipping duplicate-code detection"
  exit 0
fi

OUT="${DERIVED_FILE_DIR:-/tmp}/jscpd"

# --absolute → warning paths are clickable in Xcode.
# --format swift → Swift only (drop this line to include css/html/json).
npx --yes jscpd@latest \
  --min-tokens 50 --min-lines 5 \
  --format swift \
  --reporters json --absolute \
  --output "$OUT" \
  --ignore "**/.build/**,**/build/**,**/*.xcodeproj/**,**/Probes/**" \
  Sources ../Kosmos/Sources ../KosmosAppKit/Sources > /dev/null 2>&1 || true

REPORT="$OUT/jscpd-report.json"
if [ ! -f "$REPORT" ]; then
  echo "warning: jscpd produced no report; skipping"
  exit 0
fi

node -e '
const fs = require("fs");
const d = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
for (const c of d.duplicates) {
  const a = c.firstFile, b = c.secondFile;
  const msg = `Duplicate code: ${c.lines} lines / ${c.tokens} tokens`;
  console.log(`${a.name}:${a.start}: warning: ${msg} (also at ${b.name}:${b.start})`);
  console.log(`${b.name}:${b.start}: warning: ${msg} (also at ${a.name}:${a.start})`);
}
' "$REPORT"
