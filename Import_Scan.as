on run {input, parameters}
    set fileCount to count of input
    set lastNote to null
    
    repeat with theFile in input
        set fileName to name of (info for theFile)
        set filePath to POSIX path of theFile
        
        -- Try to get file creation date/time using stat command
        try
            set creationTimestamp to do shell script "stat -f '%SB' -t '%Y-%m-%d at %H:%M:%S' " & quoted form of filePath
        on error
            set creationTimestamp to ""
        end try
        
        -- Extract date from filename (first 10 characters: YYYY-MM-DD)
        try
            set fileDate to text 1 thru 10 of fileName
            set description to text 12 thru -5 of fileName
            set noteName to fileDate & " " & description
            set scanDate to fileDate
        on error
            -- Fallback if filename doesn't match expected format
            set noteName to text 1 thru -5 of fileName
            set scanDate to "Unknown"
        end try
        
        -- Build scan date/time string
        if creationTimestamp is not "" then
            set scanDateTime to creationTimestamp
        else
            set scanDateTime to scanDate
        end if
        
        -- Get current date and time for import timestamp
        set importDateTime to do shell script "date '+%Y-%m-%d at %H:%M:%S'"
        
        -- Build note body with title in bold
        set noteBody to "<div><b>" & noteName & "</b></div><div><br></div><div>Scanned by Eric Brown on " & scanDateTime & ", imported on " & importDateTime & "</div>"
        
        tell application "Notes"
            tell folder "Scans"
                set newNote to make new note with properties {body:noteBody}
                -- Add small delay before attaching
                delay 1.0
                tell newNote
                    make new attachment with data theFile
                end tell
                
                -- Save reference to this note if only importing one
                if fileCount is 1 then
                    set lastNote to newNote
                end if
            end tell
        end tell
        
        -- Add delay between notes when processing multiple files
        delay 0.5
    end repeat
    
    tell application "Notes"
        activate
        -- If only one file was imported, select that note
        if fileCount is 1 and lastNote is not null then
            show lastNote
        end if
    end tell
    
    return input
end run
