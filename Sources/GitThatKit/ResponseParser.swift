import Foundation

public struct CommitMessage: Sendable, Equatable {
    public let subject: String
    public let body: String?

    public init(subject: String, body: String?) {
        self.subject = subject
        self.body = body
    }

    /// The message as git should receive it.
    public var full: String {
        guard let body, !body.isEmpty else { return subject }
        return subject + "\n\n" + body
    }
}

public enum ResponseError: Error, Equatable {
    case empty
}

public enum ResponseParser {

    /// Matches an opening conversational line — "Here's the commit message:".
    /// Deliberately narrow so a real subject like `feat: add x` is never eaten.
    // ponytail: nonisolated(unsafe) because Regex is not Sendable but this value
    // is immutable after init and never mutated; computed-property alternative
    // would rebuild Regex on every call.
    nonisolated(unsafe) private static let preamble = try! Regex(
        #"(?i)^(sure|certainly|okay|ok|here'?s|here is)\b[^\n]*:$"#
    )

    public static func commitMessage(from raw: String) throws -> CommitMessage {
        let text = stripPreamble(stripFences(raw))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ResponseError.empty }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let subject = String(lines[0]).trimmingCharacters(in: .whitespaces)
        guard !subject.isEmpty else { throw ResponseError.empty }

        let body = lines.dropFirst()
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)

        return CommitMessage(subject: subject, body: body.isEmpty ? nil : body)
    }

    public static func stripFences(_ raw: String) -> String {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        let isFence = { (line: Substring) in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
        }

        // Find first non-empty line; if it's a fence, extract the fenced content.
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           isFence(lines[first]) {
            let remainder = lines[(first + 1)...]
            if let closing = remainder.lastIndex(where: isFence) {
                // Normal case: opening + closing fence found — content is between them.
                // Only trim the fence delimiter lines; preserve indentation of content lines.
                return remainder[..<closing].joined(separator: "\n")
            } else {
                // Fix (a): unclosed opening fence — use everything after the opener.
                return remainder.joined(separator: "\n")
            }
        }

        // Fix (b): no opening fence — strip any orphan closing fence lines.
        let stripped = lines.filter { !isFence($0) }
        if stripped.count == lines.count { return raw }  // nothing changed, return original
        return stripped.joined(separator: "\n")
    }

    private static func stripPreamble(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        while let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                lines.removeFirst()
            } else if trimmed.wholeMatch(of: preamble) != nil {
                lines.removeFirst()
            } else {
                break
            }
        }
        return lines.joined(separator: "\n")
    }
}
