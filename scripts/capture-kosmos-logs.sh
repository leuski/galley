#!/bin/bash
#
# Stream every Galley + Kosmos log line into a single file.
#
# Captures BOTH:
#   - the macOS host's Galley Mac Viewer + Galley Server processes
#   - the visionOS simulator's Galley process (the simulator routes
#     its os_log through the host's unified log, so one `log stream`
#     sees both sides)
#
# Usage:
#   ./Scripts/capture-kosmos-logs.sh                  # writes /tmp/kosmos-debug.log
#   ./Scripts/capture-kosmos-logs.sh /path/to/file    # custom path
#
# Reproduce the issue, then Ctrl-C and share the file.

set -eu

OUT=${1:-/tmp/kosmos-debug.log}

PREDICATE='(subsystem CONTAINS "leuski.kosmos") OR (subsystem CONTAINS "leuski.galley") OR (subsystem CONTAINS "net.leuski.kosmos") OR (subsystem CONTAINS "net.leuski.galley")'

echo "Streaming Galley + Kosmos logs to: $OUT"
echo "Predicate: $PREDICATE"
echo "Press Ctrl-C when reproduction is done."
echo

# Truncate so each capture starts clean.
: > "$OUT"

exec log stream \
  --level=info \
  --style=compact \
  --predicate "$PREDICATE" \
  >> "$OUT"
