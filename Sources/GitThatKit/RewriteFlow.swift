import Foundation

// MARK: - Public types

public enum RewriteOutcome: Sendable, Equatable {
    case rewritten(backupRef: String)
    case cancelled
    case nothingToRewrite
    case conflicted
}

public enum RewriteFlowError: Error, Equatable {
    case notARepository
    case crossBranchRequest(String)
    case dirtyTree
    case planRejected(raw: String)
    /// Thrown when a plan contains reword steps but the binary path cannot be resolved,
    /// which would otherwise cause git to open the user's real editor and hang.
    case missingBinaryPath
    /// Thrown when the history rewrite process exits non-zero but left no in-progress state,
    /// meaning the failure is not a conflict the user can resolve — it is a real error.
    case rewriteFailed(stderr: String, backupRef: String)
}

// MARK: - RewriteFlow

/// The oracle loop for `gitthat rewrite`. Shape mirrors CommitFlow.
public struct RewriteFlow: Sendable {
    private let git: Git
    private let provider: Provider
    private let config: Config
    private let ui: UserInterface
    private let safety: Safety
    /// Absolute path to the running binary. Injected for testability; defaults to resolving CommandLine.arguments[0].
    private let binaryPath: String?

    public init(
        git: Git,
        provider: Provider,
        config: Config,
        ui: UserInterface,
        safety: Safety,
        binaryPath: String? = nil
    ) {
        self.git = git
        self.provider = provider
        self.config = config
        self.ui = ui
        self.safety = safety
        self.binaryPath = binaryPath ?? RewriteFlow.resolveBinaryPath()
    }

    /// Package-internal init that stores `binaryPath` as-is (no fallback resolution).
    /// Use in tests to inject an explicit nil and exercise the missingBinaryPath path.
    init(
        git: Git,
        provider: Provider,
        config: Config,
        ui: UserInterface,
        safety: Safety,
        resolvedBinaryPath: String?
    ) {
        self.git = git
        self.provider = provider
        self.config = config
        self.ui = ui
        self.safety = safety
        self.binaryPath = resolvedBinaryPath
    }

    public func run(intent: String?, count: Int?, autostash: Bool) async throws -> RewriteOutcome {
        // 1. Repository check
        guard git.isRepository() else { throw RewriteFlowError.notARepository }

        // 2. Cross-branch detection: compare whole tokens from intent against branch names.
        // Tokenize on non-alphanumeric boundaries so "fix" in "fix the last 3 commits"
        // doesn't match a branch named "fix". Skip very short names (≤2 chars) that are
        // overwhelmingly common English words.
        if let intent {
            let branches = (try? git.localBranchNames()) ?? []
            let current = (try? git.currentBranch()) ?? ""
            let intentTokens = Set(
                intent.components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .map { $0.lowercased() }
                    .filter { !$0.isEmpty }
            )
            if let named = branches.first(where: { branch in
                // Skip the current branch and very short names (≤3 chars) that are
                // overwhelmingly common English words (e.g. "fix", "add", "wip").
                guard branch != current, branch.count > 3 else { return false }
                return intentTokens.contains(branch.lowercased())
            }) {
                throw RewriteFlowError.crossBranchRequest(
                    "'\(named)' is another branch. GITTHAT only edits your current branch. " +
                    "To merge or move commits between branches, use git directly."
                )
            }
        }

        // 3. Dirty tree check (unless autostash)
        if !autostash {
            let clean = (try? safety.isClean()) ?? true
            if !clean { throw RewriteFlowError.dirtyTree }
        }

        // 4. Resolve range
        let range: CommitRange
        do {
            range = try safety.resolveRange(count: count)
        } catch SafetyError.emptyRange, SafetyError.unbornHead {
            return .nothingToRewrite
        }
        if range.commits.isEmpty { return .nothingToRewrite }

        // 5. Build prompt, ask provider, decode and validate. Retry once on failure.
        let plan = try await generatePlan(range: range, intent: intent)

        // 6. Preview → confirm
        let branch = try? git.currentBranch()
        let upstream = try? git.upstreamRef()
        ui.show(RewriteRender.preview(range: range, plan: plan, branch: branch))
        guard ui.confirm("Apply this rewrite?") else { return .cancelled }

        // 7. Pushed commits → second confirmation
        if range.hasPushed {
            if let warning = RewriteRender.pushedWarning(range: range, upstream: upstream) {
                ui.show(warning)
            }
            guard ui.confirm("Confirm rewrite of pushed commits?") else { return .cancelled }
        }

        // 8. Backup ref — only here does git get touched
        let backupRef = try safety.createBackupRef()

        // 9. Write todo + queue files; run rebase.
        // The rewrite blocks on waitUntilExit for as long as git takes. Doing that
        // directly here would hold a cooperative-pool thread (one per core) for the
        // whole rewrite, starving every other async task in the process. Hand it to
        // a dedicated thread so only that thread blocks.
        let todo = TodoFile.render(plan)
        let queue = TodoFile.messageQueue(plan)
        let conflicted = try await runBlocking {
            try runRebase(baseSha: range.baseSha, todo: todo, queue: queue, autostash: autostash, backupRef: backupRef)
        }

        // 10. Conflict — run the resolution loop instead of stopping.
        if conflicted {
            let conflictOutcome = try await resolveConflicts(backupRef: backupRef)
            switch conflictOutcome {
            case .allResolved:
                // Continue the rewrite to completion, then fall through to verify + success.
                let continueCode = try git.rewriteContinue()
                if continueCode != 0 {
                    // Continue failed — likely another conflict or a real error.
                    // Leave the rebase in its stopped state so the user can use --resume/--cancel.
                    ui.show(
                        "Conflict during rewrite. Resolve the conflict, then run:\n" +
                        "  gitthat rewrite --resume\n" +
                        "Or to cancel:\n" +
                        "  gitthat rewrite --cancel"
                    )
                    return .conflicted
                }
                // Fall through to verify + .rewritten below.
            case .someSkipped(let skippedFiles):
                let list = skippedFiles.map { "  \($0)" }.joined(separator: "\n")
                ui.show(
                    "Some files remain conflicted:\n\(list)\n" +
                    "Resolve them manually, then run:\n" +
                    "  gitthat rewrite --resume\n" +
                    "Or to abandon the rewrite:\n" +
                    "  gitthat rewrite --cancel"
                )
                return .conflicted
            case .cancelled:
                ui.show(
                    "Conflict resolution cancelled. The rewrite is paused.\n" +
                    "To finish manually: gitthat rewrite --resume\n" +
                    "To abandon: gitthat rewrite --cancel"
                )
                return .conflicted
            }
        }

        // 11. Verify (if configured); report failure but do NOT roll back
        let hook = VerifyHook(command: config.rewrite.verify, git: git)
        if case .failed(let output) = try hook.run() {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = trimmed.isEmpty ? "(no output)" : trimmed
            ui.show(
                "Verify command failed:\n\(detail)\n" +
                "The rewrite completed. To undo: gitthat undo"
            )
        }

        return .rewritten(backupRef: backupRef)
    }

    // MARK: - Private

    /// Calls provider, decodes, validates. Retries once with the error. Throws `planRejected` on double failure.
    private func generatePlan(range: CommitRange, intent: String?) async throws -> RewritePlan {
        let prompt = RewritePrompts.plan(range: range, intent: intent, retryError: nil)
        let raw1 = try await provider.complete(prompt)
        do {
            return try RewritePlan.decode(raw1).validated(against: range)
        } catch {
            let retryPrompt = RewritePrompts.plan(range: range, intent: intent, retryError: error.localizedDescription)
            let raw2 = try await provider.complete(retryPrompt)
            do {
                return try RewritePlan.decode(raw2).validated(against: range)
            } catch {
                throw RewriteFlowError.planRejected(raw: raw2)
            }
        }
    }

    /// Writes the todo and queue files to temp paths, then runs the interactive rebase.
    /// Returns true when the rebase ended with a genuine conflict (non-zero exit AND in-progress
    /// state was left behind), false on clean success. Throws `rewriteFailed` when git exits
    /// non-zero but leaves no in-progress state — that is a real failure, not a conflict.
    private func runRebase(baseSha: String?, todo: String, queue: [TodoFile.QueueEntry], autostash: Bool, backupRef: String) throws -> Bool {
        // Whether git will call GIT_EDITOR: reword steps (r) and squash steps (s) both invoke it.
        // fixup (f) does not. We must set GIT_EDITOR any time git might open an editor.
        let todoLines = todo.split(separator: "\n", omittingEmptySubsequences: true)
        let hasEditorStep = todoLines.contains { $0.hasPrefix("r ") || $0.hasPrefix("s ") }

        // Guard: if there are editor-invoking steps but no binary path, git will open the user's
        // real editor and hang forever — throw early before touching git.
        if hasEditorStep && binaryPath == nil {
            throw RewriteFlowError.missingBinaryPath
        }

        // Write the sequence file to a temp path. GIT_SEQUENCE_EDITOR reads GITTHAT_SEQ_FILE and copies it.
        // Using a file avoids any quoting/newline issue — the path is the only thing in the command.
        let todoFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitthat-seq-\(UUID().uuidString)")
        try Data(todo.utf8).write(to: todoFileURL)
        defer { try? FileManager.default.removeItem(at: todoFileURL) }

        // Write queue file (typed, NUL-delimited) whenever git might invoke the editor.
        var queueFileURL: URL? = nil
        if hasEditorStep, let binary = binaryPath {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("gitthat-queue-\(UUID().uuidString)")
            try TodoFile.serialiseQueue(queue).write(to: url)
            queueFileURL = url
            _ = binary
        }
        defer { queueFileURL.flatMap { try? FileManager.default.removeItem(at: $0) } }

        // GIT_SEQUENCE_EDITOR: copy the pre-written sequence file over the file git passes as $1.
        // The path is in an env var so special characters in the path cannot break the command.
        let sequenceEditorCmd = "sh -c 'cp \"$GITTHAT_SEQ_FILE\" \"$1\"' sh"

        var env: [String: String] = [
            "GITTHAT_SEQ_FILE": todoFileURL.path,
            "GIT_SEQUENCE_EDITOR": sequenceEditorCmd,
        ]
        // GIT_TERMINAL_PROMPT is set inside git.rewriteInteractive; no need to duplicate it here.

        // Set GIT_EDITOR whenever git might invoke it (reword `r` or squash `s` steps).
        if hasEditorStep, let binary = binaryPath {
            env["GIT_EDITOR"] = "\(binary) __edit-message"
            if let queueFile = queueFileURL {
                env["GITTHAT_MESSAGE_QUEUE"] = queueFile.path
            }
        }

        let result = try git.rewriteInteractive(baseSha: baseSha, autostash: autostash, environment: env)
        guard result.exitCode != 0 else { return false }

        // Non-zero exit: discriminate between a genuine conflict (git left in-progress state)
        // and a real failure (corrupt repo, missing object, rejected hook, resource exhaustion…).
        if git.rewriteInProgress() {
            return true  // genuine conflict — caller shows resume/cancel instructions
        }
        // No in-progress state: this is a real failure the user cannot resolve by fixing conflicts.
        throw RewriteFlowError.rewriteFailed(stderr: result.stderr, backupRef: backupRef)
    }

    /// Runs a blocking body on a dedicated thread instead of the cooperative pool.
    /// The cooperative pool has roughly one thread per core, so blocking one for the
    /// length of a git rewrite stalls unrelated async work. A dedicated Thread is used
    /// rather than DispatchQueue.global() because that pool grows slowly under load
    /// and would queue the work behind other blocked rewrites.
    private func runBlocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                continuation.resume(with: Result { try body() })
            }
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }

    /// Collects the current conflict set and runs the per-file resolution loop.
    private func resolveConflicts(backupRef: String) async throws -> ConflictOutcome {
        // Collect the conflict set. If git is no longer stopped (e.g. race), treat as cancelled.
        let directory = git.topLevel() ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let set: ConflictSet
        do {
            set = try ConflictSet.collect(git: git, directory: directory)
        } catch ConflictError.notStopped {
            return .cancelled
        }
        let flow = ConflictFlow(git: git, provider: provider, ui: ui, directory: directory)
        return try await flow.run(set)
    }

    /// Returns the running binary's absolute path, or nil if it cannot be resolved.
    private static func resolveBinaryPath() -> String? {
        let arg0 = CommandLine.arguments[0]
        if arg0.hasPrefix("/") { return arg0 }
        let cwd = FileManager.default.currentDirectoryPath
        let resolved = URL(fileURLWithPath: cwd).appendingPathComponent(arg0).path
        if FileManager.default.fileExists(atPath: resolved) { return resolved }
        return nil
    }
}
