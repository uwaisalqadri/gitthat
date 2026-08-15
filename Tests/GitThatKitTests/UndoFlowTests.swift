import Foundation
import Testing
@testable import GitThatKit

// MARK: - Helpers

private func makeUndoFlow(repo: RepoFixture, ui: UserInterface) -> UndoFlow {
    UndoFlow(git: repo.git, ui: ui, safety: Safety(git: repo.git))
}

// MARK: - Tests

/// After a regular commit, undo restores the branch to the previous HEAD.
@Test func undoAfterCommitRestoresPreviousHead() throws {
    let repo = RepoFixture()
        .commit("feat: first", file: "a.txt", contents: "1")

    let originalHead = repo.run(["rev-parse", "HEAD"])
        .stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    repo.commit("feat: second", file: "b.txt", contents: "2")

    let ui = RecordingUI(confirmations: [true])
    let flow = makeUndoFlow(repo: repo, ui: ui)
    let outcome = try flow.run(hard: false)

    guard case .restored(let sha) = outcome else {
        Issue.record("expected restored, got \(outcome)")
        return
    }
    #expect(sha == originalHead)
    let headAfter = repo.run(["rev-parse", "HEAD"])
        .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(headAfter == originalHead)
}

/// After a GITTHAT rewrite, undo restores the exact original SHA stored in the backup ref.
@Test func undoAfterRewriteRestoresOriginalSha() throws {
    let repo = RepoFixture()
        .commit("feat: first", file: "a.txt", contents: "1")
        .commit("feat: second", file: "b.txt", contents: "2")

    let originalHead = repo.run(["rev-parse", "HEAD"])
        .stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    // Simulate what RewriteFlow does: create a backup ref then move HEAD.
    let safety = Safety(git: repo.git)
    let backupRef = try safety.createBackupRef()

    // Simulate a rewrite by making a new commit (changing HEAD).
    repo.commit("feat: rewritten", file: "c.txt", contents: "3")

    let ui = RecordingUI(confirmations: [true])
    let flow = UndoFlow(git: repo.git, ui: ui, safety: safety)
    let outcome = try flow.run(hard: false)

    guard case .restored(let sha) = outcome else {
        Issue.record("expected restored, got \(outcome)")
        return
    }
    #expect(sha == originalHead)
    _ = backupRef // silence unused-variable warning
}

/// Declining the confirmation changes nothing.
@Test func undoDecliningChangesNothing() throws {
    let repo = RepoFixture()
        .commit("feat: first", file: "a.txt", contents: "1")
        .commit("feat: second", file: "b.txt", contents: "2")

    let headBefore = repo.run(["rev-parse", "HEAD"])
        .stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    let ui = RecordingUI(confirmations: [false])
    let flow = makeUndoFlow(repo: repo, ui: ui)
    let outcome = try flow.run(hard: false)

    #expect(outcome == .cancelled)
    let headAfter = repo.run(["rev-parse", "HEAD"])
        .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(headBefore == headAfter)
}

/// `--hard` resets the working tree; default (soft) leaves the working tree untouched.
@Test func undoSoftLeavesWorkingTree() throws {
    let repo = RepoFixture()
        .commit("feat: first", file: "a.txt", contents: "v1")
        .commit("feat: second", file: "a.txt", contents: "v2")

    let ui = RecordingUI(confirmations: [true])
    let flow = makeUndoFlow(repo: repo, ui: ui)
    let outcome = try flow.run(hard: false)

    guard case .restored = outcome else {
        Issue.record("expected restored, got \(outcome)")
        return
    }
    // Working tree still has v2 content (unstaged after soft reset).
    let content = try String(
        contentsOf: repo.directory.appendingPathComponent("a.txt"),
        encoding: .utf8
    )
    #expect(content == "v2")
}

@Test func undoHardResetsWorkingTree() throws {
    let repo = RepoFixture()
        .commit("feat: first", file: "a.txt", contents: "v1")
        .commit("feat: second", file: "a.txt", contents: "v2")

    let ui = RecordingUI(confirmations: [true])
    let flow = makeUndoFlow(repo: repo, ui: ui)
    let outcome = try flow.run(hard: true)

    guard case .restored = outcome else {
        Issue.record("expected restored, got \(outcome)")
        return
    }
    // Working tree reverted to v1.
    let content = try String(
        contentsOf: repo.directory.appendingPathComponent("a.txt"),
        encoding: .utf8
    )
    #expect(content == "v1")
}

/// An empty reflog (brand-new repo with no commits) returns .nothingToUndo.
@Test func undoEmptyReflogReturnsNothingToUndo() throws {
    // Create a repo with one commit so the reflog has only the initial entry,
    // then verify a fresh repo (no prior HEAD) returns nothingToUndo.
    // Easiest: just use a fresh repo with zero commits.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gitthat-undo-empty-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let runner = SystemGitRunner(environmentOverrides: isolatedGitEnvironment)
    let git = Git(runner: runner, directory: dir)
    _ = try runner.run(["init", "-q", "-b", "main"], in: dir, stdin: nil)

    let ui = RecordingUI()
    let flow = UndoFlow(git: git, ui: ui, safety: Safety(git: git))
    let outcome = try flow.run(hard: false)
    #expect(outcome == .nothingToUndo)
}

// MARK: - sanitize() / forbidden-word stripping tests

/// Each forbidden word in an unrecognised subject must be replaced before reaching the user.
@Test func sanitizeStripsRebaseVerb() {
    let result = UndoFlow.sanitize("rebase -i (start): checkout abc123")
    #expect(!result.lowercased().contains("rebase"), "sanitize must strip 'rebase': \(result)")
}

@Test func sanitizeStripsSquash() {
    let result = UndoFlow.sanitize("squash 3 commits together")
    #expect(!result.lowercased().contains("squash"), "sanitize must strip 'squash': \(result)")
}

@Test func sanitizeStripsFixup() {
    let result = UndoFlow.sanitize("fixup: combine with previous")
    #expect(!result.lowercased().contains("fixup"), "sanitize must strip 'fixup': \(result)")
}

/// An entirely unrecognised subject with no forbidden words passes through with content intact.
@Test func sanitizePreservesNonForbiddenContent() {
    let result = UndoFlow.sanitize("unknown-future-git-verb: some description")
    #expect(!result.isEmpty)
    #expect(result.contains("unknown-future-git-verb") || result.contains("some description"),
            "sanitize should preserve non-forbidden content: \(result)")
}

/// A completely empty or all-forbidden subject falls back to a generic description.
@Test func sanitizeAllForbiddenFallsBack() {
    let result = UndoFlow.sanitize("rebase")
    #expect(!result.lowercased().contains("rebase"), "sanitize must strip 'rebase': \(result)")
    #expect(!result.trimmingCharacters(in: .whitespaces).isEmpty,
            "sanitize must not return an empty string")
}

/// A reflog subject containing a squash word in a commit message renders without it.
@Test func translateSquashInSubjectIsStripped() {
    // This simulates a commit whose message happens to contain a forbidden word —
    // not a recognised prefix, so it falls through to sanitize().
    let result = UndoFlow.translate(subject: "something squash related", sha: "abc", backups: [:])
    #expect(!result.lowercased().contains("squash"), "translate must not surface 'squash': \(result)")
}

@Test func translateFixupInSubjectIsStripped() {
    let result = UndoFlow.translate(subject: "fixup commit message", sha: "abc", backups: [:])
    #expect(!result.lowercased().contains("fixup"), "translate must not surface 'fixup': \(result)")
}

/// Recognised subjects still render correctly after the sanitize change.
@Test func translateRecognisedSubjectsStillWork() {
    #expect(UndoFlow.translate(subject: "commit: feat: add thing", sha: "abc", backups: [:])
        == "committed \"feat: add thing\"")
    #expect(UndoFlow.translate(subject: "commit (amend): fix: typo", sha: "abc", backups: [:])
        == "amended \"fix: typo\"")
    #expect(UndoFlow.translate(subject: "checkout: moving from main to feature/x", sha: "abc", backups: [:])
        == "switched to feature/x")
    #expect(UndoFlow.translate(subject: "reset: moving to HEAD~1", sha: "abc", backups: [:])
        == "moved back to HEAD~1")
}

/// Reflog descriptions shown to the user must not contain forbidden git vocabulary.
@Test func undoDescriptionsContainNoForbiddenWords() throws {
    let repo = RepoFixture()
        .commit("feat: first", file: "a.txt", contents: "1")
        .commit("feat: second", file: "b.txt", contents: "2")

    let forbidden = ["rebase", "squash", "fixup", "pick"]
    let entries = try UndoFlow.buildEntries(git: repo.git, safety: Safety(git: repo.git))
    for entry in entries {
        let lowered = entry.description.lowercased()
        for word in forbidden {
            #expect(!lowered.contains(word),
                    "entry description contains forbidden word '\(word)': \(entry.description)")
        }
    }
}
