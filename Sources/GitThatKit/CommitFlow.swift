import Foundation
import TOMLKit

public enum CommitOutcome: Sendable, Equatable {
    case committed(sha: String)
    case cancelled
    case nothingToCommit
}

public enum CommitFlowError: Error, Equatable {
    case notARepository
}

/// The oracle loop for `gitthat commit`: gather, ask, parse, enforce, preview,
/// confirm, commit. Every git command is run here, never by the agent.
public struct CommitFlow {
    private let git: Git
    private let provider: Provider
    private let config: Config
    private let ui: UserInterface
    private let repositoryConfigPath: URL?

    public init(
        git: Git,
        provider: Provider,
        config: Config,
        ui: UserInterface,
        repositoryConfigPath: URL?
    ) {
        self.git = git
        self.provider = provider
        self.config = config
        self.ui = ui
        self.repositoryConfigPath = repositoryConfigPath
    }

    public func run() async throws -> CommitOutcome {
        guard git.isRepository() else { throw CommitFlowError.notARepository }

        guard try ensureSomethingIsStaged() else { return .nothingToCommit }

        let diff = try git.stagedDiff(limit: 8192)
        let subjects = try git.recentSubjects(20)
        let branch = try git.currentBranch()
        let style = resolveStyle(from: subjects)

        let ticket = TicketID.appearsIn(subjects: subjects)
            ? TicketID.extract(fromBranch: branch)
            : nil

        let input = CommitPromptInput(
            diff: diff,
            recentSubjects: subjects,
            style: style,
            ticket: ticket,
            maxSubject: config.commit.maxSubject
        )
        let prompt = Prompts.commitMessage(input)

        var message = try await generate(prompt: prompt)

        while true {
            ui.show(Render.commitPreview(message, branch: branch))

            switch ui.askCommitChoice() {
            case .accept:
                return .committed(sha: try git.commit(message: message.full))

            case .edit:
                do {
                    let edited = try ui.edit(message.full)
                    do {
                        message = enforce(try ResponseParser.commitMessage(from: edited))
                    } catch {
                        // Empty save — tell the user and keep the previous message.
                        ui.show("Empty message ignored; keeping the previous message.")
                    }
                } catch let uiErr as UIError {
                    // Editor failed (not found, non-zero exit) — report it and keep looping.
                    ui.show("Editor error: \(uiErr.localizedDescription)")
                }

            case .regenerate:
                message = try await generate(prompt: prompt)

            case .cancel:
                return .cancelled
            }
        }
    }

    /// Returns false when there is nothing to commit and the user declined to
    /// stage everything.
    private func ensureSomethingIsStaged() throws -> Bool {
        if try git.hasStagedChanges() { return true }
        guard ui.confirm("Nothing is staged. Stage everything?") else { return false }
        try git.stageAll()
        return try git.hasStagedChanges()
    }

    private func resolveStyle(from subjects: [String]) -> CommitStyle {
        switch config.commit.style {
        case .conventional: return .conventional
        case .plain: return .plain
        case .auto:
            if let inferred = StyleInference.infer(from: subjects) { return inferred }
            let chosen = ui.askStyle()
            persist(style: chosen)
            return chosen
        }
    }

    /// Writes the chosen style to the repository config so the question is
    /// asked at most once per repository.
    ///
    /// Uses TOMLKit to parse and re-serialize so an existing [commit] table is
    /// updated in place rather than duplicated (which would corrupt the file).
    private func persist(style: CommitStyle) {
        guard let path = repositoryConfigPath else { return }
        let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        guard let table = try? TOMLTable(string: existing.isEmpty ? "" : existing) else { return }
        // Get or create the [commit] sub-table.
        let commitTable: TOMLTable
        if let existing = table["commit"]?.table {
            commitTable = existing
        } else {
            commitTable = TOMLTable()
            table["commit"] = commitTable
        }
        commitTable["style"] = style.rawValue
        try? table.convert().write(to: path, atomically: true, encoding: .utf8)
    }

    /// Calls the provider and parses the response. On a first parse failure,
    /// retries once with the error appended. If the second attempt also fails,
    /// surfaces the raw output to the user and throws.
    private func generate(prompt: String) async throws -> CommitMessage {
        let raw = try await provider.complete(prompt)
        do {
            return enforce(try ResponseParser.commitMessage(from: raw))
        } catch {
            // First attempt failed — retry with the parse error appended.
            let retryPrompt = prompt + "\n\n[Previous response could not be parsed: \(error.localizedDescription). Please respond with only the commit message, no extra text.]\n\nPrevious response:\n\(raw)"
            let raw2 = try await provider.complete(retryPrompt)
            do {
                return enforce(try ResponseParser.commitMessage(from: raw2))
            } catch {
                // Second attempt also failed — show the raw output before throwing.
                ui.show("Agent response could not be parsed. Raw output:\n\(raw2)")
                throw error
            }
        }
    }

    private func enforce(_ message: CommitMessage) -> CommitMessage {
        CommitMessage(
            subject: SubjectCase.enforce(message.subject, setting: config.commit.subjectCase),
            body: message.body
        )
    }
}
