import Foundation

/// The single choke point between resolved content and `git add`.
///
/// Safety rule 4: *no resolution reaches the index until the user has seen the
/// file it produced.* This type is the structural enforcement of that rule.
///
/// The enforcement is not a token and not a naming convention. There is no
/// intermediate "reviewed" value to forge, because review and staging are the
/// same indivisible operation: `reviewThenStage` takes the raw content plus the
/// review action, performs the review itself, and only then writes and stages.
/// A caller cannot obtain the staging half without running the review half —
/// there is nothing to hold, pass, or fabricate in between.
///
/// This lives in its own file on purpose. `private` in Swift is file-scoped, so
/// the stored `git` handle and the initializer of the result type are genuinely
/// unreachable from `ConflictFlow.swift` — where future resolution code will be
/// added, and where a same-file guard would be forgeable by any new extension.
struct StagingGuard: Sendable {
    private let git: Git
    private let ui: UserInterface

    init(git: Git, ui: UserInterface) {
        self.git = git
        self.ui = ui
    }

    /// How the user is shown the content before it is staged.
    ///
    /// Every case performs a real, unavoidable presentation to the user. There
    /// is no case that means "already reviewed" or "skip review" — adding one
    /// would be the only way to reintroduce the hole, and it would be visible
    /// here rather than hidden behind a token constructor.
    enum Review: Sendable {
        /// Show the content in the terminal, verbatim and untruncated.
        case display(header: String)
        /// Open the content in the editor; the returned text is what gets staged.
        /// Staging happens only on a successful (zero-exit) editor close.
        case editor
    }

    /// Reviews `content` with the user and stages the result. The ONLY function
    /// in the package that calls `git.stage()`.
    ///
    /// Order of operations, which no caller can reorder or skip:
    ///   1. present `content` to the user via `review`
    ///   2. take whatever the user ended up with (editor output, or the shown text)
    ///   3. reject it if it still contains conflict markers
    ///   4. write it to the working file
    ///   5. `git add`
    ///
    /// - Returns: `true` when the file was staged, `false` when review failed
    ///   (editor error, or markers survived review) and the file was left conflicted.
    func reviewThenStage(
        _ content: String,
        review: Review,
        path: String,
        in directory: URL
    ) throws -> Bool {
        let seen: String
        switch review {
        case .display(let header):
            ui.show("\(header)\n\(content)")
            seen = content
        case .editor:
            do {
                seen = try ui.edit(content)
            } catch let uiErr as UIError {
                ui.show("Editor error: \(uiErr.localizedDescription) — file left conflicted.")
                return false
            }
        }

        // Marker check runs on every path, after review, before the index.
        if StagingGuard.containsMarkers(seen) {
            ui.show("  Resolution still contains conflict markers — file not staged. Please resolve manually.")
            return false
        }

        try seen.write(to: directory.appendingPathComponent(path), atomically: true, encoding: .utf8)
        try git.stage(path)
        return true
    }

    static func containsMarkers(_ text: String) -> Bool {
        text.contains("<<<<<<<") || text.contains("=======") || text.contains(">>>>>>>")
    }
}
