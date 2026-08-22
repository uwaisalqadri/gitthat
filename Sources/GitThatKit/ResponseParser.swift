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

    static func stripFences(_ raw: String) -> String {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        let isFence = { (line: Substring) in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
        }

        // Find the first fence. If it has a closing fence after it and non-empty content between
        // them, this is a fenced block (possibly with preamble prose before it) — extract the content.
        // This handles: bare fenced, fenced+lang-tag, preamble-then-fenced.
        if let open = lines.firstIndex(where: isFence) {
            let remainder = lines[(open + 1)...]
            if !remainder.isEmpty {
                if let closing = remainder.lastIndex(where: isFence) {
                    // Opening + closing fence found — content is everything between them.
                    return remainder[..<closing].joined(separator: "\n")
                } else {
                    // Fix (a): unclosed opening fence — use everything after the opener.
                    return remainder.joined(separator: "\n")
                }
            }
            // Fence is the last line with nothing after it — fall through to orphan-strip.
        }

        // Fix (b): no opening fence, or fence at the very end with no content after it.
        // Strip any orphan fence lines (e.g., trailing ``` with content before it).
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
