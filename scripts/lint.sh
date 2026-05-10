#!/usr/bin/env bash
#
# SwiftLint runner for the Lint build phase. Skips with a warning when
# SwiftLint isn't installed so a missing dev tool doesn't fail the build.

set -euo pipefail

export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

cd "${SRCROOT:-$(dirname "$0")/..}"

if which swiftlint > /dev/null; then
    swiftlint --config swiftlint.yml Sources
else
    echo "warning: SwiftLint not installed, download from https://github.com/realm/SwiftLint"
fi
