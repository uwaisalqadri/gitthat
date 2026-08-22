import Foundation

// MARK: - Public types

public enum ConflictChoice: Sendable, Equatable {
    case acceptIntoEditor
    case editManually
    case takeOurs
    case takeTheirs
    case skip
}

public enum ConflictOutcome: Sendable, Equatable {
    case allResolved
    case someSkipped([String])
    case cancelled
}

public enum ConflictFlowError: Error, Equatable {
    case notStopped
    /// Staged rejected: content still contains conflict markers after user review.
    case resolutionContainsMarkers
}

// MARK: - ConflictFlow

/// The per-file resolution loop for merge conflicts.
///
/// Safety rule: nothing reaches `git add` until the user has seen the resulting
/// file. This file contains NO call to `git.stage()` and no way to make one.
/// All staging goes through `StagingGuard.reviewThenStage`, which performs the
/// user review and the staging as one indivisible operation — see
/// `StagingGuard.swift` for why that is not forgeable from here.
public struct ConflictFlow: Sendable {
    // No `git` property: this type holds no handle capable of staging. The only
    // git access it has is through `guardrail`, which cannot stage without review.
    private let provider: Provider
    private let ui: UserInterface
    private let directory: URL
    private let guardrail: StagingGuard

    /// The `directory` parameter is the repository root — the same value
    /// passed to `ConflictSet.collect(git:directory:)`.
    public init(git: Git, provider: Provider, ui: UserInterface, directory: URL) {
        self.provider = provider
        self.ui = ui
        self.directory = directory
        self.guardrail = StagingGuard(git: git, ui: ui)
    }

    public func run(_ set: ConflictSet) async throws -> ConflictOutcome {
        var skipped: [String] = []

        for (index, file) in set.files.enumerated() {
            // When both sides are nil we cannot construct a meaningful prompt.
            // Show what git left on disk, ask the user to handle it directly.
            let proposal: String?
            if file.ours == nil && file.theirs == nil {
                proposal = nil
                ui.show(ConflictRender.file(file, proposal: nil, index: index, total: set.files.count))
            } else {
                do {
                    proposal = try await resolveWithRetry(file: file, subject: set.applyingSubject)
                } catch {
                    // I3: provider failed mid-loop — report what was resolved so far, then propagate.
                    if !skipped.isEmpty || index > 0 {
                        let resolved = set.files[..<index].map(\.path).filter { !skipped.contains($0) }
                        if !resolved.isEmpty {
                            ui.show("  \(resolved.count) file(s) already resolved before this error: \(resolved.joined(separator: ", "))")
                        }
                    }
                    throw error
                }
                ui.show(ConflictRender.file(file, proposal: proposal, index: index, total: set.files.count))
            }

            let didStage = try await handleChoice(for: file, proposal: proposal, index: index, total: set.files.count)
            if !didStage {
                skipped.append(file.path)
            }
        }

        if skipped.isEmpty { return .allResolved }
        return .someSkipped(skipped)
    }

    // MARK: - Per-file choice handler

    /// Returns true when the file was staged, false when it was skipped.
    private func handleChoice(
        for file: ConflictedFile,
        proposal: String?,
        index: Int,
        total: Int
    ) async throws -> Bool {
        // C3: bounded loop — avoid recursion when a nil side is chosen repeatedly.
        // ponytail: 5 attempts is generous for human use; non-interactive UIs get a clear error.
        for attempt in 1...5 {
            let choice = ui.askConflictChoice()
            switch choice {
            case .acceptIntoEditor:
                return try await acceptIntoEditor(file: file, proposal: proposal ?? file.merged)

            case .editManually:
                return try await editFile(file: file, content: file.merged)

            case .takeOurs:
                guard let content = file.ours else {
                    ui.show("  [o] is not available — this file was deleted on our side. Choose [t], [e], or [s].")
                    if attempt == 5 { ui.show("  No valid choice after 5 attempts — skipping file."); return false }
                    continue
                }
                return try showThenStage(file: file, content: content)

            case .takeTheirs:
                guard let content = file.theirs else {
                    ui.show("  [t] is not available — this file was deleted on their side. Choose [o], [e], or [s].")
                    if attempt == 5 { ui.show("  No valid choice after 5 attempts — skipping file."); return false }
                    continue
                }
                return try showThenStage(file: file, content: content)

            case .skip:
                return false
            }
        }
        // Unreachable: loop body always returns or continues, and .skip returns false.
        return false
    }

    // MARK: - Choice implementations

    /// Writes `content` to the working file, opens the editor for review,
    /// then stages only on a successful (zero-exit) editor close.
    private func acceptIntoEditor(file: ConflictedFile, proposal: String) async throws -> Bool {
        // Seed the working file so the editor opens on the proposal.
        try proposal.write(to: fileURL(for: file), atomically: true, encoding: .utf8)
        return try guardrail.reviewThenStage(
            proposal, review: .editor, path: file.path, in: directory
        )
    }

    /// Opens the editor on the file as git left it (markers and all).
    /// Stages only on a successful editor close.
    private func editFile(file: ConflictedFile, content: String) async throws -> Bool {
        try guardrail.reviewThenStage(
            content, review: .editor, path: file.path, in: directory
        )
    }

    /// Writes `content` to disk, shows it to the user (review gate), then stages.
    ///
    /// I2: The conflict overview (ConflictRender) truncates at 30 lines per side, so a
    /// user who picks [o]/[t] based on that preview may not have seen the whole file.
    /// We show the FULL content here (no truncation) before staging, so the user
    /// always reviews the complete result. When the file exceeds 30 lines we note
    /// the total so they know the preview was partial.
    private func showThenStage(file: ConflictedFile, content: String) throws -> Bool {
        let lineCount = content.components(separatedBy: "\n").count
        let header = lineCount > 30
            ? "  result (\(lineCount) lines — the conflict preview was truncated; this is the full file):"
            : "  result:"
        return try guardrail.reviewThenStage(
            content, review: .display(header: header), path: file.path, in: directory
        )
    }

    // MARK: - Marker detection

    /// Sends the prompt with one retry on marker-containing response.
    /// On second failure, returns nil so the caller falls back to manual editing.
    ///
    /// - Returns: clean proposal, or nil when both attempts contain markers.
    private func resolveWithRetry(file: ConflictedFile, subject: String?) async throws -> String? {
        let prompt = try ConflictPrompts.resolve(file: file, applyingSubject: subject, retryError: nil)
        let raw = try await provider.complete(prompt)

        if !containsMarkers(raw) { return raw }

        // First response had markers — retry once with the error appended.
        let retryError = "Your previous response contained conflict markers (<<<<<<, =======, >>>>>>>). Reply with the resolved file content only, no markers."
        let retryPrompt = try ConflictPrompts.resolve(file: file, applyingSubject: subject, retryError: retryError)
        let raw2 = try await provider.complete(retryPrompt)

        if !containsMarkers(raw2) { return raw2 }

        // Both attempts had markers — fall back to nil so caller uses editManually.
        ui.show("  The agent's resolution contained conflict markers after two attempts. Falling back to manual editing.")
        return nil
    }

    /// Pre-screen for the provider retry loop. This is a convenience to avoid
    /// showing the user a proposal that is obviously unresolved — it is NOT the
    /// safety check. The authoritative marker check runs inside
    /// `StagingGuard.reviewThenStage`, after review and before the index.
    private func containsMarkers(_ text: String) -> Bool {
        StagingGuard.containsMarkers(text)
    }

    // MARK: - Staging guard (structural enforcement)
    //
    // There is deliberately no staging code in this file, and no token type.
    //
    // The previous design had a `ReviewedContent` token with a `private init`
    // and a `fileprivate static` factory. That was not enforcement: `fileprivate`
    // is file-wide, and a `private init` on a type nested in `ConflictFlow` is
    // reachable from any extension in this file. Any resolution code added here
    // later could mint a token for content the user never saw and hand it to the
    // staging function. Deleting or renaming the factory did not close that —
    // the nested type's initializer remained reachable file-wide.
    //
    // The token is now gone entirely. `StagingGuard.reviewThenStage` performs the
    // review and the staging as a single operation, so there is no intermediate
    // value to forge and no staging entry point that can be reached without
    // passing through review. It lives in StagingGuard.swift, where `private`
    // is a real boundary this file cannot cross.

    private func fileURL(for file: ConflictedFile) -> URL {
        directory.appendingPathComponent(file.path)
    }
}

