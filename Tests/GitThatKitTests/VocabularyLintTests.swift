import Foundation
import Testing
@testable import GitThatKit

/// Git's internal vocabulary must not reach the user. Rebasing means moving
/// work onto a different base, which GITTHAT cannot do, and `squash`/`fixup`
/// are todo-file verbs the user never sees.
private let forbiddenWords = ["rebase", "squash", "fixup", "pick", "todo"]

private func assertClean(_ text: String, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let lowered = text.lowercased()
    for word in forbiddenWords {
        #expect(!lowered.contains(word),
                "\(label) contains the forbidden word '\(word)'",
                sourceLocation: sourceLocation)
    }
}

@Test func commitPreviewIsClean() {
    let message = CommitMessage(subject: "feat: add a thing", body: "a body")
    assertClean(Render.commitPreview(message, branch: "feature/sso"), "commit preview")
}

@Test func commitPromptIsClean() {
    let input = CommitPromptInput(
        diff: StagedDiff(text: "diff", wasTruncated: true),
        recentSubjects: ["feat: a thing"],
        style: .conventional,
        ticket: "PROJ-1",
        maxSubject: 72
    )
    assertClean(Prompts.commitMessage(input), "commit prompt")
}

@Test(arguments: [
    ProviderError.notFound(command: "claude"),
    ProviderError.timedOut(seconds: 60),
    ProviderError.failed(exitCode: 1, stderr: "trouble"),
    ProviderError.empty,
])
func providerErrorsAreClean(error: ProviderError) {
    assertClean(String(describing: error), "provider error")
}

@Test func configErrorsAreClean() {
    assertClean(
        String(describing: ConfigError.unknownProvider(name: "nope", available: ["claude"])),
        "config error"
    )
}

@Test func sourceFilesContainNoForbiddenUserFacingStrings() throws {
    // Walks the source tree and flags string literals containing forbidden
    // words. Comments are exempt — they explain implementation, which is
    // allowed to name git's own concepts.
    //
    // EXEMPT FILES: these files use git's vocabulary as git subcommand strings or path
    // components — never as user-facing strings. Everything else must not surface these words.
    //   GitVocabulary.swift — defines the named constants; the single source of truth
    //   Git.swift           — passes GitVocabulary constants to git as subcommand args,
    //                         and checks for "rebase-merge"/"rebase-apply" paths
    let exemptFiles: Set<String> = ["GitVocabulary.swift", "Git.swift"]
    //
    // Strategy: track whether we're inside a multi-line string literal (""")
    // so interior lines — which contain no quote character — are still scanned.
    // Single-line guard dropped; we scan every non-comment line instead.
    let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // GitThatKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root
        .appendingPathComponent("Sources")

    let files = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }
        .filter { !exemptFiles.contains($0.lastPathComponent) } ?? []

    try #require(!files.isEmpty, "found no source files to lint — path navigation is wrong")

    for file in files {
        let contents = try String(contentsOf: file, encoding: .utf8)
        var inMultilineString = false
        for (index, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Toggle multi-line string state on """. An odd number of """ on
            // one line flips the state; even leaves it unchanged.
            let tripleCount = trimmed.components(separatedBy: "\"\"\"").count - 1
            if tripleCount % 2 == 1 { inMultilineString.toggle() }

            // Skip full-line comments.
            guard !trimmed.hasPrefix("//") else { continue }

            let scanTarget: String
            if inMultilineString {
                // Inside a multi-line string: the whole (non-comment) line is literal content.
                scanTarget = trimmed
            } else {
                // Single-line: only scan actual string literal contents, not identifiers or
                // surrounding code. extractStringLiteralContents returns the concatenated
                // content of every "..." on this line, comment-stripped.
                // ponytail: naive scan — a string containing "//" (e.g. a URL) can
                // cause early truncation, but no such string exists in this source
                // tree today. Full solution: a proper Swift lexer.
                guard trimmed.contains("\"") else { continue }
                scanTarget = extractStringLiteralContents(trimmed)
                guard !scanTarget.isEmpty else { continue }
            }

            let lowered = scanTarget.lowercased()
            for word in forbiddenWords {
                #expect(!lowered.contains(word),
                        "\(file.lastPathComponent):\(index + 1) has a string containing '\(word)'")
            }
        }
    }
}

/// Proves the lint engine rejects forbidden words (including the newly added pick/todo) in a non-exempt file.
/// Uses a temporary .swift file containing string literals with "pick" and "todo",
/// then runs the same scan logic used by sourceFilesContainNoForbiddenUserFacingStrings
/// and confirms it produces violations for both words.
@Test func lintRejectsNonExemptFileWithForbiddenWord() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("LintCanFail-\(UUID().uuidString).swift")
    // Write a .swift file with string literals containing newly-added forbidden words.
    let source = "let x = \"Do not pick this commit\"\nlet y = \"todo list\""
    try source.write(to: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmp) }

    var violations: [String] = []
    let contents = try String(contentsOf: tmp, encoding: .utf8)
    var inMultilineString = false
    for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let tripleCount = trimmed.components(separatedBy: "\"\"\"").count - 1
        if tripleCount % 2 == 1 { inMultilineString.toggle() }
        guard !trimmed.hasPrefix("//") else { continue }
        let scanTarget: String
        if inMultilineString {
            scanTarget = trimmed
        } else {
            guard trimmed.contains("\"") else { continue }
            scanTarget = extractStringLiteralContents(trimmed)
            guard !scanTarget.isEmpty else { continue }
        }
        let lowered = scanTarget.lowercased()
        for word in forbiddenWords where lowered.contains(word) {
            violations.append("\(tmp.lastPathComponent): '\(word)'")
        }
    }
    #expect(!violations.isEmpty, "expected lint to flag the injected forbidden word but found no violations")
}

/// Extracts and concatenates the contents of all double-quoted string literals
/// on a single non-multi-line-string line (after stripping trailing comments).
/// Identifiers, operators, and other code are excluded.
/// ponytail: handles only basic strings; raw strings and interpolations are not
/// decomposed further, but their content is still scanned as-is.
private func extractStringLiteralContents(_ line: String) -> String {
    var result = ""
    var inString = false
    var i = line.startIndex
    while i < line.endIndex {
        let c = line[i]
        if c == "\\" && inString {
            // Skip escaped char — include it in literal content to preserve sequences like \n.
            let next = line.index(after: i)
            if next < line.endIndex {
                result.append(c)
                result.append(line[next])
                i = line.index(after: next)
            } else {
                break
            }
            continue
        }
        if c == "\"" {
            inString.toggle()
            i = line.index(after: i)
            continue
        }
        // Trailing comment outside string — stop.
        if !inString && c == "/" {
            let next = line.index(after: i)
            if next < line.endIndex && line[next] == "/" { break }
        }
        if inString { result.append(c) }
        i = line.index(after: i)
    }
    return result
}
