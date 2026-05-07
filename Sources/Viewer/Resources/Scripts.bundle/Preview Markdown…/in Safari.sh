#! /bin/sh

ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$BB_DOC_PATH")

osascript <<EOF
tell application "Safari"
  set targetURL to "__LOCATION__$ENC"
  set foundWin to missing value
  set foundTab to missing value
  repeat with w in windows
    repeat with t in tabs of w
      if URL of t starts with "__LOCATION__" then
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
