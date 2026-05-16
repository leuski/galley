#! /bin/sh

# Open the current BBEdit document in Google Chrome via Galley
# Server's /preview/ route. The server binds to an OS-assigned port
# at startup and publishes it to `server-http-port`; this script
# reads it at run time, so a Galley Server restart with a new port
# "just works" without reinstalling scripts.

PORT_FILE="$HOME/Library/Application Support/net.leuski.galley.localized/server-http-port"

if [ ! -r "$PORT_FILE" ]; then
  osascript -e 'display alert "Galley Server is not running." message "Start Galley Server from its menu-bar icon and try again."'
  exit 1
fi

PORT=$(tr -d ' \t\r\n' < "$PORT_FILE")
if ! [ "$PORT" -gt 0 ] 2>/dev/null; then
  osascript -e 'display alert "Galley Server port file is malformed." message "Try restarting Galley Server."'
  exit 1
fi

BASE="http://localhost:${PORT}/preview/"

ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$BB_DOC_PATH")

osascript <<EOF
tell application "Google Chrome"
  set targetURL to "${BASE}$ENC"
  set foundWin to missing value
  set foundIdx to 0
  repeat with w in windows
    set i to 0
    repeat with t in tabs of w
      set i to i + 1
      if URL of t starts with "${BASE}" then
        set foundWin to w
        set foundIdx to i
        exit repeat
      end if
    end repeat
    if foundWin is not missing value then exit repeat
  end repeat
  if foundWin is not missing value then
    set active tab index of foundWin to foundIdx
    set URL of active tab of foundWin to targetURL
    set index of foundWin to 1
  else
    open location targetURL
  end if
  activate
end tell
EOF
