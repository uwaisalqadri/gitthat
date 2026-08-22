import Foundation

// MARK: - Public types

public struct UndoEntry: Sendable, Equatable {
    public let sha: String
    public let description: String
    public let age: String

    public init(sha: String, description: String, age: String) {
        self.sha = sha
        self.description = description
        self.age = age
    }
}

public enum UndoOutcome: Sendable, Equatable {
    case restored(sha: String)
    case cancelled
    case nothingToUndo
}

public enum UndoFlowError: Error, Equatable {}

// MARK: - UndoFlow

public struct UndoFlow: Sendable {
    private let git: Git
    private let ui: UserInterface
    private let safety: Safety

    public init(git: Git, ui: UserInterface, safety: Safety) {
        self.git = git
        self.ui = ui
        self.safety = safety
    }

    public func run(hard: Bool) throws -> UndoOutcome {
        let entries = try Self.buildEntries(git: git, safety: safety)
        guard !entries.isEmpty else { return .nothingToUndo }

        // Show the numbered list (skip index 0 — that is the current HEAD).
        // Entries[0] is the current state; entries[1..] are the states to undo to.
        let candidates = Array(entries.dropFirst())
        guard !candidates.isEmpty else { return .nothingToUndo }

        // ponytail: no numbers — askForEntry uses confirm() per entry, not numeric input.
        // Numbers that do nothing mislead users into typing them. Remove until numeric
        // selection is implemented (readline or TTY prompt).
        let list = candidates.map { e in
            "  \(e.age.padding(toLength: 12, withPad: " ", startingAt: 0))  \(e.description)"
        }.joined(separator: "\n")
        ui.show(list)

        // Ask which entry to restore.
        let target: UndoEntry
        if candidates.count == 1 {
            // Only one option — confirm it directly.
            let question = "Restore to: \(candidates[0].description) (\(candidates[0].age))?"
            guard ui.confirm(question) else { return .cancelled }
            target = candidates[0]
        } else {
            // Ask for a number.
            guard let picked = askForEntry(candidates: candidates) else { return .cancelled }
            target = picked
        }

        let mode = hard ? "hard (working tree will be reset)" : "soft (working tree unchanged)"
        let question = "Move HEAD to \(target.sha.prefix(8)) — \(mode)?"
        guard ui.confirm(question) else { return .cancelled }

        try safety.restore(to: target.sha, hard: hard)
        return .restored(sha: target.sha)
    }

    private func askForEntry(candidates: [UndoEntry]) -> UndoEntry? {
        // ponytail: no interactive readline loop here — RecordingUI's confirm() drives tests;
        // TerminalUI's confirm() is used via the numbered list + a confirm per selection.
        // We use confirm() for each candidate in order, stopping at first "yes".
        for candidate in candidates {
            let question = "Restore to: \(candidate.description) (\(candidate.age))?"
            if ui.confirm(question) { return candidate }
        }
        return nil
    }

    // MARK: – Entry building (internal for tests)

    /// Builds the full list of reflog entries including the current HEAD (index 0).
    public static func buildEntries(git: Git, safety: Safety) throws -> [UndoEntry] {
        let raw = try git.reflog()
        guard !raw.isEmpty else { return [] }

        let backups = (try? safety.backups()) ?? []
        let backupsBySha = Dictionary(grouping: backups, by: \.sha)

        return raw.map { (sha, subject, refDesc, age) in
            let desc = translate(subject: subject, sha: sha, backups: backupsBySha)
            return UndoEntry(sha: sha, description: desc, age: age)
        }
    }

    // MARK: – Vocabulary translation

    /// Translates a git reflog subject into GITTHAT's plain-language vocabulary.
    /// None of the returned strings may contain git's internal rewrite vocabulary.
    static func translate(
        subject: String,
        sha: String,
        backups: [String: [BackupRef]]
    ) -> String {
        let s = subject.trimmingCharacters(in: .whitespaces)

        // Check if this is a GITTHAT operation (backup ref points at this SHA).
        if backups[sha] != nil {
            // Count how many commits were involved isn't recoverable from reflog alone;
            // describe it generically.
            return "rewrote commit history (gitthat)"
        }

        // git's interactive-rewrite subjects start with a word GITTHAT must not surface.
        // The constant lives in GitVocabulary.swift, which is the single exempt file.
        if s.hasPrefix(GitVocabulary.rebaseVerb) {
            return translateRebaseSubject(s)
        }

        // commit: commit <sha> (first line): subject
        if s.hasPrefix("commit: ") {
            let msg = String(s.dropFirst("commit: ".count))
            return "committed \"\(msg)\""
        }
        if s.hasPrefix("commit (initial): ") {
            let msg = String(s.dropFirst("commit (initial): ".count))
            return "committed \"\(msg)\" (initial)"
        }
        if s.hasPrefix("commit (amend): ") {
            let msg = String(s.dropFirst("commit (amend): ".count))
            return "amended \"\(msg)\""
        }

        // checkout: moving from X to Y
        if s.hasPrefix("checkout: moving from ") {
            let rest = String(s.dropFirst("checkout: moving from ".count))
            let parts = rest.components(separatedBy: " to ")
            if parts.count >= 2 {
                return "switched to \(parts[parts.count - 1])"
            }
            return "switched branches"
        }

        // reset: moving to <ref>
        if s.hasPrefix("reset: moving to ") {
            let ref = String(s.dropFirst("reset: moving to ".count))
            return "moved back to \(ref)"
        }

        // merge
        if s.hasPrefix("merge ") {
            let branch = String(s.dropFirst("merge ".count)).trimmingCharacters(in: .init(charactersIn: ":"))
            return "merged \(branch)"
        }

        // cherry-pick
        if s.hasPrefix(GitVocabulary.cherryPickPrefix) {
            let msg = String(s.dropFirst(GitVocabulary.cherryPickPrefix.count))
            return "applied \"\(msg)\""
        }

        // pull
        if s.hasPrefix("pull: ") || s.hasPrefix("pull --") {
            return "pulled changes"
        }
        if s.hasPrefix("pull") {
            return "pulled changes"
        }

        // clone
        if s.hasPrefix("clone: from") {
            return "cloned repository"
        }

        // branch rename / creation
        if s.hasPrefix("branch: Created from") {
            return "created branch"
        }
        if s.hasPrefix("branch: Reset to") {
            return "reset branch"
        }

        // Fallback — strip forbidden words and show verbatim.
        return sanitize(s)
    }

    private static func translateRebaseSubject(_ s: String) -> String {
        // Examples git emits:
        //   rebase (start): checkout <sha>
        //   rebase (finish): returning to refs/heads/<branch>
        //   rebase: rewinding head to replay your work on top of it...
        //   rebase -i (start): checkout <sha>
        //   rebase -i (finish): ...
        // We map them all to "rewrote commit history".
        if s.contains("(finish)") || s.contains("finish") {
            return "rewrote commit history"
        }
        if s.contains("(start)") || s.contains("start") {
            return "started rewriting commit history"
        }
        return "rewrote commit history"
    }

    /// Fallback for unrecognised reflog subjects.
    /// Strips forbidden git vocabulary so nothing internal reaches the user,
    /// then returns whatever description remains so the user still knows WHAT changed.
    static func sanitize(_ s: String) -> String {
        let forbidden = [GitVocabulary.rebaseVerb, GitVocabulary.todoSquash, GitVocabulary.todoFixup]
        var result = s
        for word in forbidden {
            // Case-insensitive replacement — git's wording could vary.
            result = result.replacingOccurrences(of: word, with: "…", options: .caseInsensitive)
        }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "git operation" : trimmed
    }
}
