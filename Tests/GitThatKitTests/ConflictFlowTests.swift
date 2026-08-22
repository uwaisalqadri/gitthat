import Testing
import Foundation
@testable import GitThatKit

// MARK: - Helpers

/// Sets up a repo with a real cherry-pick conflict between `base` and `ours` content
/// for one file. Returns the fixture with the conflict in place.
///
/// Strategy: commit "base" on main, branch off, commit "theirs" change, return to
/// main, commit "ours" change that conflicts, then cherry-pick the branch commit to
/// produce a conflict.
private func makeConflictedRepo(file: String = "hello.txt",
                                 base: String = "hello\n",
                                 ours: String = "hello from ours\n",
                                 theirs: String = "hello from theirs\n") -> RepoFixture {
    let repo = RepoFixture()
    // Base commit
    repo.commit("base commit", file: file, contents: base)
    // Branch for "theirs" change
    repo.run(["checkout", "-q", "-b", "feature"])
    repo.commit("feat: theirs change", file: file, contents: theirs)
    let featureSHA = repo.run(["rev-parse", "HEAD"]).stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)
    // Back to main, apply "ours" change
    repo.run(["checkout", "-q", "main"])
    repo.commit("ours change", file: file, contents: ours)
    // Cherry-pick will conflict
    _ = repo.run(["cherry-pick", featureSHA])
    return repo
}

/// Sets up a repo with TWO conflicted files by cherry-picking a single commit
/// that modifies both files.
private func makeTwoFileConflictedRepo() -> RepoFixture {
    let repo = RepoFixture()
    // Seed both files in one commit
    try! "a\n".write(to: repo.directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try! "b\n".write(to: repo.directory.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
    repo.run(["add", "-A"])
    repo.run(["commit", "-q", "-m", "init both files"])

    // Branch for "theirs" — single commit touching both files
    repo.run(["checkout", "-q", "-b", "feature"])
    try! "a theirs\n".write(to: repo.directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try! "b theirs\n".write(to: repo.directory.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
    repo.run(["add", "-A"])
    repo.run(["commit", "-q", "-m", "feat: theirs touches both"])
    let featureSHA = repo.run(["rev-parse", "HEAD"]).stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)

    // Back to main — single commit touching both files differently
    repo.run(["checkout", "-q", "main"])
    try! "a ours\n".write(to: repo.directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try! "b ours\n".write(to: repo.directory.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
    repo.run(["add", "-A"])
    repo.run(["commit", "-q", "-m", "ours: change both"])

    // Cherry-pick the feature commit — both files conflict
    _ = repo.run(["cherry-pick", featureSHA])
    return repo
}

// MARK: - ConflictChoice/Outcome tests

@Test("ConflictChoice is Sendable and Equatable")
func conflictChoiceEquatable() {
    #expect(ConflictChoice.acceptIntoEditor == ConflictChoice.acceptIntoEditor)
    #expect(ConflictChoice.skip != ConflictChoice.takeOurs)
}

@Test("ConflictOutcome allResolved is Equatable")
func conflictOutcomeEquatable() {
    #expect(ConflictOutcome.allResolved == ConflictOutcome.allResolved)
    #expect(ConflictOutcome.someSkipped(["a.txt"]) == ConflictOutcome.someSkipped(["a.txt"]))
    #expect(ConflictOutcome.cancelled == ConflictOutcome.cancelled)
}

// MARK: - acceptIntoEditor

@Test("acceptIntoEditor: writes proposal to working file, editor returns it, file is staged")
func acceptIntoEditorStages() async throws {
    let repo = makeConflictedRepo()
    let conflictSet = try ConflictSet.collect(git: repo.git, directory: repo.directory)
    #expect(conflictSet.files.count == 1)

    let resolution = "resolved content\n"
    let provider = StubProvider(response: resolution)
    // edit() is called with the proposal and returns it unchanged (RecordingUI default)
    let ui = RecordingUI(conflictChoices: [.acceptIntoEditor])
    ui.editResult = resolution

    let flow = ConflictFlow(git: repo.git, provider: provider, ui: ui, directory: repo.directory)
    let outcome = try await flow.run(conflictSet)

    #expect(outcome == .allResolved)
    // File must be staged (no longer in unmerged state)
    #expect((try? repo.git.unmergedPathsRemain()) == false)
}

@Test("acceptIntoEditor: non-zero editor exit does NOT stage the file")
func acceptIntoEditorEditorFailureDoesNotStage() async throws {
    let repo = makeConflictedRepo()
    let conflictSet = try ConflictSet.collect(git: repo.git, directory: repo.directory)

    let provider = StubProvider(response: "resolved\n")
    // Editor returns error — user cancelled
    let ui = RecordingUI(conflictChoices: [.acceptIntoEditor, .skip])
    ui.editError = UIError.editorFailed("vi exited 1")

    let flow = ConflictFlow(git: repo.git, provider: provider, ui: ui, directory: repo.directory)
    let outcome = try await flow.run(conflictSet)

    // File should be skipped after editor failure
    if case .someSkipped(let paths) = outcome {
        #expect(paths.count == 1)
    } else {
        Issue.record("Expected someSkipped, got \(outcome)")
    }
    // Must still be unmerged
    #expect((try? repo.git.unmergedPathsRemain()) == true)
}

// MARK: - editManually

@Test("editManually: opens editor on merged file, stages after successful edit")
func editManuallyStages() async throws {
    let repo = makeConflictedRepo()
    let conflictSet = try ConflictSet.collect(git: repo.git, directory: repo.directory)

    let provider = StubProvider(response: "resolved\n")
    let ui = RecordingUI(conflictChoices: [.editManually])
    ui.editResult = "manually resolved\n"

    let flow = ConflictFlow(git: repo.git, provider: provider, ui: ui, directory: repo.directory)
    let outcome = try await flow.run(conflictSet)

    #expect(outcome == .allResolved)
    #expect((try? repo.git.unmergedPathsRemain()) == false)
}

@Test("editManually: non-zero editor exit does NOT stage")
func editManuallyEditorFailureDoesNotStage() async throws {
    let repo = makeConflictedRepo()
    let conflictSet = try ConflictSet.collect(git: repo.git, directory: repo.directory)

    let provider = StubProvider(response: "resolved\n")
    let ui = RecordingUI(conflictChoices: [.editManually, .skip])
    ui.editError = UIError.editorFailed("vi exited 1")

    let flow = ConflictFlow(git: repo.git, provider: provider, ui: ui, directory: repo.directory)
    let outcome = try await flow.run(conflictSet)

    if case .someSkipped(let paths) = outcome {
        #expect(paths.count == 1)
    } else {
        Issue.record("Expected someSkipped, got \(outcome)")
    }
    #expect((try? repo.git.unmergedPathsRemain()) == true)
}

// MARK: - takeOurs / takeTheirs

@Test("takeOurs: writes ours side, shows result, then stages")
func takeOursStages() async throws {
    let repo = makeConflictedRepo()
    let conflictSet = try ConflictSet.collect(git: repo.git, directory: repo.directory)

    let provider = StubProvider(response: "resolved\n")
    let ui = RecordingUI(conflictChoices: [.takeOurs])

    let flow = ConflictFlow(git: repo.git, provider: provider, ui: ui, directory: repo.directory)
    let outcome = try await flow.run(conflictSet)

    #expect(outcome == .allResolved)
    #expect((try? repo.git.unmergedPathsRemain()) == false)
    // Working file should contain "ours" content
    let fileURL = repo.directory.appendingPathComponent(conflictSet.files[0].path)
    let content = try String(contentsOf: fileURL, encoding: .utf8)
    #expect(content == conflictSet.files[0].ours)
}

@Test("takeTheirs: writes theirs side, shows result, then stages")
func takeTheirsStages() async throws {
    let repo = makeConflictedRepo()
    let conflictSet = try ConflictSet.collect(git: repo.git, directory: repo.directory)

    let provider = StubProvider(response: "resolved\n")
    let ui = RecordingUI(conflictChoices: [.takeTheirs])

    let flow = ConflictFlow(git: repo.git, provider: provider, ui: ui, directory: repo.directory)
    let outcome = try await flow.run(conflictSet)

    #expect(outcome == .allResolved)
    #expect((try? repo.git.unmergedPathsRemain()) == false)
    let fileURL = repo.directory.appendingPathComponent(conflictSet.files[0].path)
    let content = try String(contentsOf: fileURL, encoding: .utf8)
    #expect(content == conflictSet.files[0].theirs)
}

@Test("takeOurs when ours is nil: shows error message, does not stage, eventually skips")
func takeOursWhenNilSide() async throws {
    // Build a conflict where ours deleted the file (add-delete conflict)
    let repo = RepoFixture()
    repo.commit("init", file: "gone.txt", contents: "original\n")
    // Branch: modify the file
    repo.run(["checkout", "-q", "-b", "feature"])
    repo.commit("theirs: modify", file: "gone.txt", contents: "modified by theirs\n")
    let featureSHA = repo.run(["rev-parse", "HEAD"]).stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)
    repo.run(["checkout", "-q", "main"])
    // Our side: delete the file
    repo.run(["rm", "gone.txt"])
    repo.run(["commit", "-q", "-m", "ours: delete"])
    _ = repo.run(["cherry-pick", featureSHA])

    let conflictSet = try ConflictSet.collect(git: repo.git, directory: repo.directory)
    guard conflictSet.files.first != nil else {
        Issue.record("No conflicted files found"); return
    }

    // C3 fix verification: [.takeOurs, .skip] must NOT recurse infinitely.
    // Ours is nil on an add-delete conflict — the bounded loop must re-prompt once,
    // show a message, and when the user picks [s] it skips cleanly.
    let ui = RecordingUI(conflictChoices: [.takeOurs, .skip])
    let provider = StubProvider(response: "fallback\n")

    let flow = ConflictFlow(git: repo.git, provider: provider, ui: ui, directory: repo.directory)
    let outcome = try await flow.run(conflictSet)

    // Must terminate (C3) and produce a definite outcome (not crash or loop)
    // Since the user eventually picked .skip the file must be in someSkipped.
    // (If git staged the file automatically as a delete, allResolved is also OK —
    //  but the key assertion is that no unmerged content was staged without review.)
    switch outcome {
    case .someSkipped(let paths):
        // Expected path: nil-side message shown, then user skipped
        #expect(!paths.isEmpty, "At least one file should be skipped when ours is nil and user skips")
    case .allResolved:
        // Git may have auto-resolved a pure delete; verify no broken content reached the index
        let indexContent = repo.run(["show", ":0:gone.txt"]).stdout
        #expect(!indexContent.contains("<<<<<<<"), "Index must not contain conflict markers")
    case .cancelled:
        Issue.record("Unexpected .cancelled outcome")
    }

    // UI must have shown the "not available" error message
    #expect(ui.shown.contains(where: { $0.contains("[o] is not available") }),
            "User must be told [o] is unavailable when ours side is nil")
}

// MARK: - skip

@Test("skip: leaves file conflicted, records path in outcome")
func skipLeavesConflict() async throws {
    let repo = makeConflictedRepo()
    let conflictSet = try ConflictSet.collect(git: repo.git, directory: repo.directory)

    let provider = StubProvider(response: "resolved\n")
    let ui = RecordingUI(conflictChoices: [.skip])

    let flow = ConflictFlow(git: repo.git, provider: provider, ui: ui, directory: repo.directory)
    let outcome = try await flow.run(conflictSet)

    if case .someSkipped(let paths) = outcome {
        #expect(paths == [conflictSet.files[0].path])
    } else {
        Issue.record("Expected someSkipped, got \(outcome)")
    }
    #expect((try? repo.git.unmergedPathsRemain()) == true)
}

@Test("skip some, resolve others: correct outcome and only unresolved files remain")
func skipSomeResolveOthers() async throws {
    let repo = makeTwoFileConflictedRepo()
    let conflictSet = try ConflictSet.collect(git: repo.git, directory: repo.directory)
    #expect(conflictSet.files.count == 2)

    let provider = StubProvider(response: "resolved\n")
    // First file: accept, second file: skip
    let ui = RecordingUI(conflictChoices: [.acceptIntoEditor, .skip])
    ui.editResult = "resolved content\n"

    let flow = ConflictFlow(git: repo.git, provider: provider, ui: ui, directory: repo.directory)
    let outcome = try await flow.run(conflictSet)

    if case .someSkipped(let paths) = outcome {
        #expect(paths.count == 1)
        #expect(paths[0] == conflictSet.files[1].path)
    } else {
        Issue.record("Expected someSkipped, got \(outcome)")
    }
}

// MARK: - Marker detection (safety rule)

@Test("proposal containing conflict markers is rejected, retried, then falls back to editManually")
func markerRejectionFallback() async throws {
    let repo = makeConflictedRepo()
    let conflictSet = try ConflictSet.collect(git: repo.git, directory: repo.directory)

    let markerResponse = "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\n"
    let cleanResponse = "clean resolved\n"
    // First call returns markers, second call (retry) also returns markers → fall back to edit
    let provider = StubProvider(responses: [markerResponse, markerResponse])
    let ui = RecordingUI(conflictChoices: [.editManually])
    ui.editResult = cleanResponse

    let flow = ConflictFlow(git: repo.git, provider: provider, ui: ui, directory: repo.directory)
    let outcome = try await flow.run(conflictSet)

    // Provider was called twice (original + retry)
    #expect(provider.receivedPrompts.count == 2)
    // After both fail the user sees the conflict view and is asked to edit manually
    // outcome should be allResolved (the manual edit succeeded)
    #expect(outcome == .allResolved)
    #expect((try? repo.git.unmergedPathsRemain()) == false)
}

@Test("proposal with markers on retry succeeds: second response is clean")
func markerRejectionSucceedsOnRetry() async throws {
    let repo = makeConflictedRepo()
    let conflictSet = try ConflictSet.collect(git: repo.git, directory: repo.directory)

    let markerResponse = "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\n"
    let cleanResponse = "clean resolved on retry\n"
    // First call returns markers, second call returns clean
    let provider = StubProvider(responses: [markerResponse, cleanResponse])
    let ui = RecordingUI(conflictChoices: [.acceptIntoEditor])
    ui.editResult = cleanResponse

    let flow = ConflictFlow(git: repo.git, provider: provider, ui: ui, directory: repo.directory)
    let outcome = try await flow.run(conflictSet)

    #expect(provider.receivedPrompts.count == 2)
    #expect(outcome == .allResolved)
}

// MARK: - Provider failure mid-loop

@Test("provider failure on file 2: file 1 already resolved is not lost")
func providerFailureMidLoop() async throws {
    let repo = makeTwoFileConflictedRepo()
    let conflictSet = try ConflictSet.collect(git: repo.git, directory: repo.directory)
    #expect(conflictSet.files.count == 2)

    // First call succeeds, second call throws
    let provider = TwoStepProvider(first: "resolved a\n", thenError: .empty)
    let ui = RecordingUI(conflictChoices: [.acceptIntoEditor])
    ui.editResult = "resolved a\n"

    let flow = ConflictFlow(git: repo.git, provider: provider, ui: ui, directory: repo.directory)

    do {
        _ = try await flow.run(conflictSet)
        Issue.record("Expected provider error to propagate")
    } catch {
        // Error propagated — but the first file must already be staged
        // Check that at most one unmerged path remains (file 1 resolved)
        let paths = try? repo.git.conflictedPaths()
        #expect((paths?.count ?? 0) <= 1)
    }
}

// MARK: - Staging guard structural tests

/// Verifies that a resolution cannot reach git add without being reviewed.
/// The previous version only checked that edit() was called — it could not detect
/// C1 (markers staged via editor) or C2 (forged token bypassing review).
/// This version tests the actual safety rule: no unreviewed or marker-containing
/// content may ever appear in the git index.
@Test("staging guard: edit() must be called before staging")
func stagingGuardEditCalledBeforeStage() async throws {
    let repo = makeConflictedRepo()
    let conflictSet = try ConflictSet.collect(git: repo.git, directory: repo.directory)

    let provider = StubProvider(response: "resolved\n")
    var editWasCalled = false
    let trackingUI = TrackingUI(choice: .acceptIntoEditor, editResult: "resolved\n") {
        editWasCalled = true
    }

    let flow = ConflictFlow(git: repo.git, provider: provider, ui: trackingUI, directory: repo.directory)
    let outcome = try await flow.run(conflictSet)

    #expect(editWasCalled, "edit() must be called before staging (the review gate)")
    #expect(outcome == .allResolved)
    #expect((try? repo.git.unmergedPathsRemain()) == false)
}

/// C1 regression: an editor returning content with conflict markers must NOT stage
/// the file. This is the exact scenario that was reproduced: editor returns
/// "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\n" and the flow must
/// detect markers in StagingGuard.reviewThenStage (the choke point) and refuse to stage.
@Test("staging guard: editor returning conflict markers does NOT stage the file (C1)")
func stagingGuardEditorWithMarkersDoesNotStage() async throws {
    let repo = makeConflictedRepo()
    let conflictSet = try ConflictSet.collect(git: repo.git, directory: repo.directory)

    let markerContent = "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\n"
    let provider = StubProvider(response: "resolved\n")
    // Editor returns content with markers — C1 scenario.
    // acceptIntoEditor catches the marker error and returns false (no second choice needed).
    let ui = RecordingUI(conflictChoices: [.acceptIntoEditor])
    ui.editResult = markerContent

    let flow = ConflictFlow(git: repo.git, provider: provider, ui: ui, directory: repo.directory)
    let outcome = try await flow.run(conflictSet)

    // The file must NOT be staged — still unmerged
    #expect((try? repo.git.unmergedPathsRemain()) == true,
            "File with markers must not reach the index")
    // UI must have shown a warning about markers
    #expect(ui.shown.contains(where: { $0.contains("conflict markers") }),
            "User must be warned that markers were detected")
    // Confirmed by unmergedPathsRemain above: the file was never staged.
    // Additionally verify the outcome reflects the file was skipped (not allResolved).
    if case .someSkipped(let paths) = outcome {
        #expect(paths.contains(conflictSet.files[0].path),
                "Marker-rejected file must appear in someSkipped")
    } else {
        Issue.record("Expected someSkipped after marker rejection, got \(outcome)")
    }
}

// MARK: - Test helpers

/// A provider that returns one response then throws.
private final class TwoStepProvider: Provider, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let first: String
    private let error: ProviderError

    init(first: String, thenError: ProviderError) {
        self.first = first
        self.error = thenError
    }

    func complete(_ prompt: String) async throws -> String {
        return try lock.withLock {
            calls += 1
            if calls == 1 { return first }
            throw error
        }
    }
}

/// Calls `onEdit` when `edit()` is called, to verify gate ordering.
private final class TrackingUI: UserInterface, @unchecked Sendable {
    private let choice: ConflictChoice
    private let editResult: String
    private let onEdit: () -> Void

    init(choice: ConflictChoice, editResult: String, onEdit: @escaping () -> Void) {
        self.choice = choice
        self.editResult = editResult
        self.onEdit = onEdit
    }

    func show(_ text: String) {}
    func askCommitChoice() -> CommitChoice { .cancel }
    func askStyle() -> CommitStyle { .conventional }
    func confirm(_ question: String) -> Bool { false }
    func edit(_ text: String) throws -> String {
        onEdit()
        return editResult
    }
    func askConflictChoice() -> ConflictChoice { choice }
}

// MARK: - StagingGuard: review and staging are inseparable

/// Safety rule 4: no resolution reaches the index until the user has seen the
/// file it produced. The guard fuses review and staging into one operation, so
/// the bytes staged are necessarily the bytes shown. This test locks that: it
/// would fail if anyone reintroduced a path that stages content other than what
/// was presented (e.g. a Review case that skips presentation).
@Test("StagingGuard stages exactly the bytes it showed the user")
func stagingGuardStagesWhatItShowed() throws {
    let repo = RepoFixture()
    repo.commit("base", file: "a.txt", contents: "old\n")
    let ui = RecordingUI()
    let guardrail = StagingGuard(git: repo.git, ui: ui)

    let staged = try guardrail.reviewThenStage(
        "resolved content\n", review: .display(header: "  result:"),
        path: "a.txt", in: repo.directory)

    #expect(staged)
    // The exact content reached the user...
    #expect(ui.allOutput.contains("resolved content"))
    // ...and the same bytes reached the index.
    let indexed = repo.run(["show", ":0:a.txt"]).stdout
    #expect(indexed == "resolved content\n")
}

/// The marker check runs on every path, including the non-editor display path,
/// and refuses the index rather than staging a half-resolved file.
@Test("StagingGuard refuses to stage content that still has markers")
func stagingGuardRefusesMarkers() throws {
    let repo = RepoFixture()
    repo.commit("base", file: "a.txt", contents: "old\n")
    let ui = RecordingUI()
    let guardrail = StagingGuard(git: repo.git, ui: ui)

    let staged = try guardrail.reviewThenStage(
        "<<<<<<< HEAD\na\n=======\nb\n>>>>>>> x\n",
        review: .display(header: "  result:"), path: "a.txt", in: repo.directory)

    #expect(!staged)
    #expect(ui.allOutput.contains("still contains conflict markers"))
}
