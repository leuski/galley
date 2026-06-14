#! /bin/sh

# Open the current BBEdit document in Galley at the cursor's source
# line. The viewer's `galley://` URL handler routes to its own LSHandler;
# `?line=N` is honored when the active renderer emits source positions
# (Swift markdown, pandoc with +sourcepos, cmark-gfm with --sourcepos).

# Percent-encode the path while preserving '/'. /usr/bin/python3 ships
# with the Command Line Tools that BBEdit users typically already have.
ENCODED=$(/usr/bin/python3 -c \
  'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe="/"))' \
  "$BB_DOC_PATH")

LINE="${BB_DOC_SELSTART_LINE:-1}"

open "galley://${ENCODED}?line=${LINE}"
