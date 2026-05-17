-- Preview in Galley
-- Save as: ~/Library/Scripts/Applications/Xcode/Preview in Galley.scpt
-- Surfaces in the macOS Script Menu when Xcode is frontmost.

property markdownExtensions : ¬
    {"md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtext", "mmd"}

on pathExtension(p)
    set AppleScript's text item delimiters to "."
    set parts to text items of (p as string)
    set AppleScript's text item delimiters to ""
    if (count of parts) < 2 then return ""
    return last item of parts
end pathExtension

on isMarkdown(p)
    if p is missing value then return false
    if (p as string) is "" then return false
    return pathExtension(p) is in markdownExtensions
end isMarkdown

on warn(msg)
    display dialog msg buttons {"OK"} default button 1 with icon caution ¬
        with title "Preview in Galley"
end warn

tell application "Xcode"
    set docs to documents
    if (count of docs) is 0 then
        my warn("No documents are open in Xcode.")
        return
    end if

    set targetPath to missing value
    repeat with doc in docs
        try
            set p to path of doc
            if my isMarkdown(p) then
                set targetPath to p as string
                exit repeat
            end if
        end try
    end repeat
end tell

if targetPath is missing value then
    my warn("No Markdown document is open in Xcode.")
else
    do shell script "open " & quoted form of ("galley://" & targetPath)
end if
