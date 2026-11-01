// summarize-pdf: print a short Apple Intelligence summary of a PDF's text.
//
// Build and install (installs to /usr/local/bin, which is already on PATH;
// Homebrew on Apple silicon uses /opt/homebrew, so this folder stays ours):
//   swiftc summarize-pdf.swift -o summarize-pdf
//   sudo install -m 755 summarize-pdf /usr/local/bin/
// The "Import Scans to Notes" AppleScript calls /usr/local/bin/summarize-pdf by full path,
// because do shell script uses a minimal PATH. Update its summaryTool property if this moves.
// Rebuild after major macOS or Xcode updates.
//
// Requires: Apple silicon Mac, macOS 26+, Apple Intelligence on, Xcode or Command Line Tools.
// Usage:  summarize-pdf file.pdf
// Exit codes: 0 = success, 1 = no text in PDF, 2 = model error or still too long, 64 = usage error
// Progress notes go to stderr, so only the summary appears on stdout.

import Foundation
import PDFKit
import FoundationModels

// The on-device model has roughly a 4,096-token window shared by instructions,
// schema, document, and reply. ~2,500 words leaves room for everything else.
let maxWords = 2500
let fallbackCharLimits = [6000, 3000]   // tried in order if the word budget is still too big

@Generable
struct ScanSummary {
    @Guide(description: "A 2-3 sentence summary of the document as one plain-text paragraph, with no title, preamble, or formatting")
    var summary: String
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("DEBUG: \(message)\n".utf8))
}

// First `limit` words of the text, keeping its original spacing and line breaks.
func prefix(_ text: String, words limit: Int) -> String {
    var count = 0
    var end = text.startIndex
    text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                             options: [.byWords, .substringNotRequired]) { _, range, _, stop in
        count += 1
        end = range.upperBound
        if count >= limit { stop = true }
    }
    return count < limit ? text : String(text[..<end])
}

func summarize(_ text: String) async throws -> String {
    // A fresh session per attempt, so a failed attempt leaves nothing behind
    let session = LanguageModelSession(instructions:
        "You summarize scanned documents such as bills, letters, forms, and receipts.")
    let response = try await session.respond(to: text, generating: ScanSummary.self)
    return response.content.summary
}

guard CommandLine.arguments.count > 1 else {
    log("usage: summarize-pdf file.pdf")
    exit(64)
}

let path = CommandLine.arguments[1]
guard let doc = PDFDocument(url: URL(fileURLWithPath: path)),
      let fullText = doc.string, !fullText.isEmpty else {
    log("no text found in PDF (it may be an image-only scan)")
    exit(1)
}

// Build the list of attempts: word budget first, then shorter character cutoffs
var attempts = [prefix(fullText, words: maxWords)]
for limit in fallbackCharLimits where limit < attempts.last!.count {
    attempts.append(String(fullText.prefix(limit)))
}

log("PDF text: \(fullText.count) characters")

for (number, text) in attempts.enumerated() {
    do {
        let summary = try await summarize(text)
        log("attempt \(number + 1) succeeded with \(text.count) characters")
        print(summary)
        exit(0)
    } catch let error as LanguageModelSession.GenerationError {
        if case .exceededContextWindowSize = error {
            log("attempt \(number + 1) too long at \(text.count) characters, trying shorter")
            continue
        }
        log("model error: \(error)")
        exit(2)
    } catch {
        log("error: \(error)")
        exit(2)
    }
}

log("still too long after all fallbacks")
exit(2)
