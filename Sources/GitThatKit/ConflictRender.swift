import Foundation

/// Renders the conflict review screen shown to the user for each conflicted file.
///
/// Layout rules:
/// - Side-by-side when max line length on BOTH sides is ≤ 38 characters (fits ~80-col terminal).
/// - Stacked (ours then theirs) when any line exceeds 38 characters — wrapping a side-by-side
///   diff is more confusing than stacking it.
/// - Truncated at 30 lines per side with a remaining-lines notice. The full conflict markers
///   are always available in the editor; truncation here prevents flooding, not hiding truth.
/// - A nil side means the file was deleted on that side. Rendered as `(deleted)` with a note.
public enum ConflictRender {
    private static let dim   = "\u{001B}[2m"
    private static let bold  = "\u{001B}[1m"
    private static let reset = "\u{001B}[0m"

    private static let maxLineWidth = 38  // chars per column before falling back to stacked
    private static let maxLines     = 30  // lines shown per side before truncation

    // MARK: - Public API

    /// Returns the full conflict screen for one file.
    /// - Parameters:
    ///   - file:     The conflicted file (ours/theirs may be nil = deleted on that side).
    ///   - proposal: AI-suggested resolution text, or nil if not yet generated.
    ///   - index:    Zero-based position of this file in the conflict set.
    ///   - total:    Total number of conflicted files.
    public static func file(
        _ file: ConflictedFile,
        proposal: String?,
        index: Int,
        total: Int
    ) -> String {
        var lines: [String] = []

        // Header: path + progress
        let progress = "file \(index + 1) of \(total)"
        lines.append("\(bold)\(file.path)\(reset)  \(dim)— \(progress)\(reset)")
        lines.append("")

        // Side sections
        let oursLines   = sideLines(file.ours,   label: "ours (HEAD)")
        let theirsLines = sideLines(file.theirs, label: "theirs")

        let useSideBySide = file.ours != nil && file.theirs != nil
            && maxLineLen(file.ours!)  <= maxLineWidth
            && maxLineLen(file.theirs!) <= maxLineWidth

        if useSideBySide {
            lines.append(contentsOf: sideBySide(oursLines: oursLines, theirsLines: theirsLines))
        } else {
            lines.append(contentsOf: stacked(oursLines: oursLines, theirsLines: theirsLines))
        }
        lines.append("")

        // Proposed resolution
        if let proposal {
            lines.append("  \(bold)proposed resolution\(reset)")
            lines.append("  \(dim)\(String(repeating: "─", count: 32))\(reset)")
            let (truncated, omitted) = truncate(proposal.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
            for l in truncated { lines.append("  \(l)") }
            if omitted > 0 {
                lines.append("  \(dim)… \(omitted) more lines omitted\(reset)")
            }
            lines.append("")
        }

        // Action hints (only when proposal is present — caller shows different prompt otherwise)
        if proposal != nil {
            lines.append("  [a] accept into editor   [e] edit manually")
            lines.append("  [o] take ours            [t] take theirs   [s] skip")
        } else {
            lines.append("  [e] edit manually   [o] take ours   [t] take theirs   [s] skip")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Private helpers

    /// Returns header + rule + content lines for one side.
    private static func sideLines(_ content: String?, label: String) -> [String] {
        var result: [String] = []
        result.append("\(dim)\(label)\(reset)")
        result.append("\(dim)\(String(repeating: "─", count: max(label.count, 16)))\(reset)")
        if let content {
            let rawLines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let (truncated, omitted) = truncate(rawLines)
            result.append(contentsOf: truncated)
            if omitted > 0 {
                result.append("\(dim)… \(omitted) more lines omitted\(reset)")
            }
        } else {
            result.append("\(dim)(deleted on this side)\(reset)")
        }
        return result
    }

    /// Render ours and theirs columns side by side (two-column layout).
    private static func sideBySide(oursLines: [String], theirsLines: [String]) -> [String] {
        let colWidth = maxLineWidth + 4  // padding
        let count = max(oursLines.count, theirsLines.count)
        return (0..<count).map { i in
            let left  = i < oursLines.count   ? oursLines[i]   : ""
            let right = i < theirsLines.count ? theirsLines[i] : ""
            let stripped = stripANSI(left)
            let pad = max(0, colWidth - stripped.count)
            return "  \(left)\(String(repeating: " ", count: pad))\(right)"
        }
    }

    /// Render ours then theirs in separate stacked sections.
    private static func stacked(oursLines: [String], theirsLines: [String]) -> [String] {
        var result: [String] = []
        for l in oursLines   { result.append("  \(l)") }
        result.append("")
        for l in theirsLines { result.append("  \(l)") }
        return result
    }

    /// Truncate to maxLines, returning the slice and count of omitted lines.
    private static func truncate(_ lines: [String]) -> ([String], Int) {
        guard lines.count > maxLines else { return (lines, 0) }
        return (Array(lines.prefix(maxLines)), lines.count - maxLines)
    }

    /// Longest line length in a string (ignoring ANSI escapes).
    private static func maxLineLen(_ s: String) -> Int {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { stripANSI(String($0)).count }
            .max() ?? 0
    }

    /// Strip ANSI escape sequences for length calculation.
    private static func stripANSI(_ s: String) -> String {
        // ponytail: naive regex-free strip; covers SGR sequences only. Fine for our own output.
        var result = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\u{001B}", s.index(after: i) < s.endIndex, s[s.index(after: i)] == "[" {
                i = s.index(after: s.index(after: i))  // skip ESC[
                while i < s.endIndex, !s[i].isLetter { i = s.index(after: i) }
                if i < s.endIndex { i = s.index(after: i) }  // skip terminator letter
            } else {
                result.append(s[i])
                i = s.index(after: i)
            }
        }
        return result
    }
}
