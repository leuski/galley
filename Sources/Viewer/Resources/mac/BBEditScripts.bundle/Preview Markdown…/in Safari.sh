#! /bin/sh

# Open the current BBEdit document in Safari via Galley Server's
# /preview/ route. The server binds to an OS-assigned port at
# startup and publishes it under `serverHTTPPort` in the
# `net.leuski.galley` defaults suite; this script reads it at run
# time, so a Galley Server restart with a new port "just works"
# without reinstalling scripts.
#
# Note: this reads another app's preference domain. The non-sandboxed
# direct-download BBEdit can do that. The App Store BBEdit is
# sandboxed and may be denied — same limitation as the previous
# port-file approach, since QL-grade entitlements aren't available
# for a one-off shell script.

PORT=$(defaults read net.leuski.galley serverHTTPPort 2>/dev/null)
if ! [ "$PORT" -gt 0 ] 2>/dev/null; then
  osascript -e 'display alert "Galley Server is not running." message "Start Galley Server from its menu-bar icon and try again."'
  exit 1
fi

BASE="http://localhost:${PORT}/preview/"

ENC=$(/usr/bin/python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$BB_DOC_PATH")

osascript <<EOF
tell application "Safari"
  set targetURL to "${BASE}$ENC"
  set foundWin to missing value
  set foundTab to missing value
  repeat with w in windows
    repeat with t in tabs of w
      if URL of t starts with "${BASE}" then
        set foundWin to w
        set foundTab to t
        exit repeat
      end if
    end repeat
    if foundWin is not missing value then exit repeat
  end repeat
  if foundWin is not missing value then
    set URL of foundTab to targetURL
    set current tab of foundWin to foundTab
    set index of foundWin to 1
  else
    open location targetURL
  end if
  activate
end tell
EOF
