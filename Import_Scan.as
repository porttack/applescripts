use AppleScript version "2.4"
use framework "Foundation"
use scripting additions

-- ===== Settings =====
property notesFolderName : "Scans"
property doneTag : "Green" -- Finder tag added after a successful import
property skipAlreadyTagged : true -- true = skip files that already have the doneTag
property addFileLink : true -- add a clickable link to the original file, just above the attached scan
property attachScan : true -- embed the scan itself in the note
property scannedBy : "Eric Brown"
property addSummary : true -- summarize the scan with Apple Intelligence via the summarize-pdf tool
property summaryTool : "/usr/local/bin/summarize-pdf" -- full path to the compiled Swift tool

on run {input, parameters}
	set fileCount to count of input
	set lastNote to missing value
	set importedCount to 0
	set skippedCount to 0
	set failedNames to {}
	
	repeat with fileRef in input
		set theFile to contents of fileRef
		set filePath to POSIX path of theFile
		set fileURL to current application's |NSURL|'s fileURLWithPath:filePath
		set fileName to (fileURL's lastPathComponent()) as text
		set baseName to ((fileURL's lastPathComponent())'s stringByDeletingPathExtension()) as text
		
		if skipAlreadyTagged and my hasFinderTag(fileURL, doneTag) then
			set skippedCount to skippedCount + 1
		else
			-- Title and date from a filename like "2026-03-14 Water bill.pdf"
			set looksLikeDate to false
			if (count of baseName) ≥ 10 then
				if character 5 of baseName is "-" and character 8 of baseName is "-" then set looksLikeDate to true
			end if
			
			if looksLikeDate then
				set fileDate to text 1 thru 10 of baseName
				if (count of baseName) > 11 then
					set noteName to fileDate & " " & (text 12 thru -1 of baseName)
				else
					set noteName to fileDate
				end if
			else
				set fileDate to ""
				set noteName to baseName
			end if
			
			-- File creation time (can be the copy/sync time, not the scan time)
			try
				set creationTimestamp to do shell script "stat -f '%SB' -t '%Y-%m-%d at %H:%M:%S' " & quoted form of filePath
			on error
				set creationTimestamp to ""
			end try
			
			-- Prefer the filename date; use the full timestamp only when it agrees with it
			if fileDate is not "" then
				if creationTimestamp starts with fileDate then
					set scanDateTime to creationTimestamp
				else
					set scanDateTime to fileDate
				end if
			else if creationTimestamp is not "" then
				set scanDateTime to creationTimestamp
			else
				set scanDateTime to "an unknown date"
			end if
			
			set importDateTime to do shell script "date '+%Y-%m-%d at %H:%M:%S'"
			
			set noteBody to "<div><b>" & my htmlEscape(noteName) & "</b></div><div><br></div>" & ¬
				"<div>Scanned by " & scannedBy & " on " & scanDateTime & ", imported on " & importDateTime & "</div>"
			
			-- Optional AI summary (skipped quietly if the shortcut fails or returns nothing)
			if addSummary then
				set summaryText to my getSummary(filePath)
				if summaryText is not "" then
					set summaryHTML to my replaceText(my htmlEscape(summaryText), return, "<br>")
					set noteBody to noteBody & "<div><br></div><div><b>Summary:</b> " & summaryHTML & "</div>"
				end if
			end if
			
			-- The link goes at the end of the body, so it sits right above the attachment
			if addFileLink then
				set fileURLString to (fileURL's absoluteString()) as text
				set noteBody to noteBody & "<div><br></div><div><a href=\"" & my htmlEscape(fileURLString) & "\">Original file: " & my htmlEscape(fileName) & "</a></div>"
			end if
			
			try
				tell application "Notes"
					tell folder notesFolderName
						set newNote to make new note with properties {body:noteBody}
						if attachScan then
							delay 1.0
							tell newNote to make new attachment with data theFile
						end if
					end tell
				end tell
				
				-- Mark the file as done only after the note was created successfully
				my addFinderTag(fileURL, doneTag)
				set importedCount to importedCount + 1
				if fileCount is 1 then set lastNote to newNote
			on error errMsg
				set end of failedNames to fileName
			end try
			
			delay 0.5
		end if
	end repeat
	
	tell application "Notes"
		activate
		if lastNote is not missing value then show lastNote
	end tell
	
	-- Summary when anything was skipped or failed
	if skippedCount > 0 or (count of failedNames) > 0 then
		set msg to "Imported " & importedCount & ", skipped " & skippedCount & " (already tagged " & doneTag & ")"
		if (count of failedNames) > 0 then
			set AppleScript's text item delimiters to ", "
			set msg to msg & ", failed: " & (failedNames as text)
			set AppleScript's text item delimiters to ""
		end if
		display notification msg with title "Import Scans to Notes"
	end if
	
	return input
end run

-- ===== Finder tag helpers =====
on getFinderTags(fileURL)
	set {ok, theTags} to fileURL's getResourceValue:(reference) forKey:(current application's NSURLTagNamesKey) |error|:(missing value)
	if theTags is missing value then return current application's NSMutableArray's array()
	return theTags's mutableCopy()
end getFinderTags

on hasFinderTag(fileURL, tagName)
	return ((my getFinderTags(fileURL))'s containsObject:tagName) as boolean
end hasFinderTag

on addFinderTag(fileURL, tagName)
	set tagList to my getFinderTags(fileURL)
	if (tagList's containsObject:tagName) as boolean then return
	tagList's addObject:tagName
	fileURL's setResourceValue:tagList forKey:(current application's NSURLTagNamesKey) |error|:(missing value)
end addFinderTag

-- ===== Summary helper =====
on getSummary(filePath)
	-- Returns "" if the tool is missing, the PDF has no text layer, or the model errors
	try
		return do shell script summaryTool & " " & quoted form of filePath & " 2>/dev/null"
	on error
		return ""
	end try
end getSummary

-- ===== Text helpers =====
on replaceText(theText, findText, replaceWith)
	set AppleScript's text item delimiters to findText
	set parts to text items of theText
	set AppleScript's text item delimiters to replaceWith
	set theText to parts as text
	set AppleScript's text item delimiters to ""
	return theText
end replaceText

on htmlEscape(theText)
	set theText to my replaceText(theText, "&", "&amp;")
	set theText to my replaceText(theText, "<", "&lt;")
	set theText to my replaceText(theText, ">", "&gt;")
	return theText
end htmlEscape
