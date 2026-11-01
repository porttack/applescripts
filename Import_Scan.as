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
// Exit codes: 0 = success, 1 = no text in PDF, 2 = model error or still too long,
//             3 = model declined even with permissive guardrails,
//             4 = language not recognized (e.g., numbers-only receipt),
//             5 = timed out downloading an iCloud-only file, 64 = usage error
// Progress notes go to stderr (prefixed DEBUG:), so only the summary appears on stdout.
// If the default guardrails decline a document (e.g., a tax return), the summary from the
// permissive fallback is printed with the prefix "Potentially sensitive: ".
// Everything runs on-device; nothing is sent off the Mac.

import Foundation
import PDFKit
import FoundationModels

// The on-device model has roughly a 4,096-token window shared by instructions,
// schema, document, and reply. ~2,500 words leaves room for everything else.
let maxWords = 2500
let fallbackCharLimits = [6000, 3000]   // tried in order if the word budget is still too big

let baseInstructions =
    "You summarize scanned personal documents such as bills, letters, forms, tax documents, and receipts."

@Generable
struct ScanSummary {
    @Guide(description: "A 2-3 sentence summary of the document as one plain-text paragraph, with no title, preamble, or formatting")
    var summary: String
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("DEBUG: \(message)\n".utf8))
}

// If the file is an iCloud placeholder (offloaded by Optimize Mac Storage), ask iCloud to
// download it and wait until a local copy exists. Returns false if it times out.
func ensureDownloaded(_ url: URL, timeout: TimeInterval = 120) async -> Bool {
    let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
    guard let values = try? url.resourceValues(forKeys: keys), values.isUbiquitousItem == true else {
        return true   // not an iCloud file, nothing to do
    }
    func isLocal(_ status: URLUbiquitousItemDownloadingStatus?) -> Bool {
        status == .current || status == .downloaded
    }
    if isLocal(values.ubiquitousItemDownloadingStatus) { return true }

    log("file is only in iCloud; downloading it first")
    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        if isLocal(try? fresh.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus) {
            log("download finished")
            return true
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
    return false
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

// Wrap the OCR text in plain English. Receipts and forms are mostly numbers and codes,
// and without some real sentences the model's language check can fail ("Unsupported language").
func makePrompt(_ text: String) -> String {
    "Please summarize the following scanned document. It may be a receipt, bill, form, or letter, "
        + "so the text below may be mostly numbers, abbreviations, and OCR errors.\n\nDocument text:\n"
        + text
}

// Normal path: default guardrails, guided generation (clean output, no preamble).
func summarizeGuided(_ text: String) async throws -> String {
    let session = LanguageModelSession(instructions: baseInstructions)
    let response = try await session.respond(to: makePrompt(text), generating: ScanSummary.self)
    return response.content.summary
}

// Fallback path for documents the default guardrails decline (tax returns, medical bills, etc.).
// Permissive guardrails apply only to plain String output, so the reply gets cleaned up afterward.
func summarizePermissive(_ text: String) async throws -> String {
    let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    let session = LanguageModelSession(model: model, instructions: baseInstructions +
        " Reply with only a 2-3 sentence summary as one plain-text paragraph: no title, no preamble, no formatting.")
    let response = try await session.respond(to: makePrompt(text))
    return cleanUp(response.content)
}

// Strip chatty lead-ins ("Sure! Here is a summary:"), markdown titles, and bold markers.
func cleanUp(_ reply: String) -> String {
    var lines = reply.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    if let first = lines.first, lines.count > 1, first.hasSuffix(":") {
        lines.removeFirst()
    }
    lines.removeAll { ($0.hasPrefix("**") && $0.hasSuffix("**")) || $0.hasPrefix("#") }
    return lines.joined(separator: " ").replacingOccurrences(of: "**", with: "")
}

func summarizeWithFallback(_ text: String) async throws -> String {
    do {
        return try await summarizeGuided(text)
    } catch let error as LanguageModelSession.GenerationError {
        switch error {
        case .refusal, .guardrailViolation:
            log("default guardrails declined (\(error.localizedDescription)); retrying with permissive guardrails")
            // Flag summaries that needed the permissive fallback; this text goes straight into the note
            return "Potentially sensitive: " + (try await summarizePermissive(text))
        default:
            throw error
        }
    }
}

guard CommandLine.arguments.count > 1 else {
    log("usage: summarize-pdf file.pdf")
    exit(64)
}

let path = CommandLine.arguments[1]
let fileURL = URL(fileURLWithPath: path)
guard await ensureDownloaded(fileURL) else {
    log("timed out waiting for iCloud to download the file")
    exit(5)
}
guard let doc = PDFDocument(url: fileURL),
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
        let summary = try await summarizeWithFallback(text)
        log("attempt \(number + 1) succeeded with \(text.count) characters")
        print(summary)
        exit(0)
    } catch let error as LanguageModelSession.GenerationError {
        switch error {
        case .exceededContextWindowSize:
            log("attempt \(number + 1) too long at \(text.count) characters, trying shorter")
            continue
        case .refusal, .guardrailViolation:
            log("model declined to summarize this document: \(error.localizedDescription)")
            exit(3)
        case .unsupportedLanguageOrLocale:
            log("model could not identify the document's language (often a numbers-only receipt or poor OCR)")
            exit(4)
        default:
            log("model error: \(error)")
            exit(2)
        }
    } catch {
        log("error: \(error)")
        exit(2)
    }
}

log("still too long after all fallbacks")
exit(2)
