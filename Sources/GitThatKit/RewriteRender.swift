import Foundation

public enum RewriteRender {
    private static let dim   = "\u{001B}[2m"
    private static let bold  = "\u{001B}[1m"
    private static let reset = "\u{001B}[0m"

    /// Returns the full before/after preview the user sees before confirming a rewrite.
    public static func preview(range: CommitRange, plan: RewritePlan, branch: String?) -> String {
        var lines: [String] = []

        // Header: branch + count
        let count = range.commits.count
        let noun  = count == 1 ? "commit" : "commits"
        if let branch {
            lines.append("\(dim)⎇  \(branch)\(reset)   ·   \(count) \(noun) in range")
        } else {
            lines.append("\(count) \(noun) in range")
        }
        lines.append("")

        // Before list — oldest-first as stored in CommitRange
        lines.append("\(bold)Before\(reset)")
        for (i, commit) in range.commits.enumerated() {
            let short  = String(commit.sha.prefix(7))
            let pushed = commit.isPushed ? "  \(dim)⚠ pushed\(reset)" : ""
            lines.append("  \(i + 1). \(short)  \(commit.subject)\(pushed)")
        }
        lines.append("")

        // After list — reflect what the plan produces
        lines.append("\(bold)After\(reset)")
        let afterLines = buildAfterLines(range: range, plan: plan)
        if afterLines.isEmpty {
            lines.append("  \(dim)(all commits removed)\(reset)")
        } else {
            lines.append(contentsOf: afterLines.enumerated().map { i, l in "  \(i + 1). \(l)" })
        }
        lines.append("")

        // Boundary statement — not decoration
        lines.append("\(dim)GITTHAT edits this branch only. Other branches are never touched.\(reset)")

        return lines.joined(separator: "\n")
    }

    /// Returns a warning string when any commit in the range has already been pushed,
    /// nil when all commits are local. Never offers to run the push — GITTHAT does not push.
    public static func pushedWarning(range: CommitRange, upstream: String?) -> String? {
        guard range.hasPushed else { return nil }
        let remote = upstream.map { "(\($0)) " } ?? ""
        return """
        \(bold)⚠  Some commits have already been pushed.\(reset)
           After the rewrite you will need to run:

             git push --force-with-lease

           \(dim)The remote \(remote)will reflect the new history once you run that command yourself.\(reset)
        """
    }

    // MARK: - Private

    /// Build the numbered after-list entries, skipping deleted/combined commits.
    private static func buildAfterLines(range: CommitRange, plan: RewritePlan) -> [String] {
        let subjectMap = Dictionary(uniqueKeysWithValues: range.commits.map { ($0.sha, $0.subject) })
        return plan.commits.compactMap { step in
            switch step.action {
            case .delete, .combine:
                return nil
            case .reword:
                return step.message ?? subjectMap[step.sha] ?? step.sha
            case .keep:
                return subjectMap[step.sha] ?? step.sha
            }
        }
    }
}
