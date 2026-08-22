import Foundation

// SAFETY PROPERTY: This type is closed over exactly four actions — keep, combine, reword, delete.
// A plan structurally cannot express pushing, resetting, or touching another branch.
// This is not an implementation convenience; it is the guarantee that executing a plan is safe.

public enum RewriteAction: String, Sendable, Codable, CaseIterable {
    case keep, combine, reword, delete
}

public struct RewriteStep: Sendable, Codable, Equatable {
    public let sha: String
    public let action: RewriteAction
    /// For `combine`: whether the merged commit's message survives into the target.
    public let keepMessage: Bool?
    /// For `reword`: the new commit message. Must be non-empty.
    public let message: String?

    public init(sha: String, action: RewriteAction, keepMessage: Bool? = nil, message: String? = nil) {
        self.sha = sha
        self.action = action
        self.keepMessage = keepMessage
        self.message = message
    }
}

public struct RewritePlan: Sendable, Codable, Equatable {
    /// The history the user wants, IN ORDER (oldest-first, matching CommitRange).
    /// Reordering is not an action — moving a commit means listing it at a different position.
    public let commits: [RewriteStep]

    public init(commits: [RewriteStep]) {
        self.commits = commits
    }

    /// Number of commits that will exist after the rewrite.
    /// Steps with action `delete` or `combine` do not produce a standalone commit.
    public var resultingCommitCount: Int {
        commits.filter { $0.action != .delete && $0.action != .combine }.count
    }
}

public enum PlanError: Error, Equatable {
    case shaOutsideRange(String)
    case ambiguousPrefix(String)
    case duplicateSha(String)
    case missingCommit(String)
    case firstStepIsCombine
    case rewordWithoutMessage(String)
    case emptyPlan
    case notJSON(String)
    case combineWithoutKeepMessage(String)
}

public extension RewritePlan {

    /// Decodes a plan from raw agent output.
    /// Tolerates bare JSON, fenced JSON, fenced with a language tag, and preamble prose before a fence.
    /// Throws `PlanError.notJSON(rawText)` on parse failure so the caller can surface it to the user.
    static func decode(_ raw: String) throws -> RewritePlan {
        let text = ResponseParser.stripFences(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = text.data(using: .utf8),
           let plan = try? JSONDecoder().decode(RewritePlan.self, from: data) {
            return plan
        }
        throw PlanError.notJSON(raw)
    }

    /// Validates the plan against a commit range. Throws the first violation found.
    /// Validation order matches the brief so tests have a stable expectation.
    ///
    /// SHA resolution: exact match first; if no exact match, the step's SHA is
    /// treated as a prefix and resolved to the unique range commit whose full SHA
    /// starts with it. An ambiguous prefix throws `ambiguousPrefix`; an
    /// unrecognised prefix throws `shaOutsideRange`. The returned plan carries
    /// full SHAs so that TodoFile emits values git will accept.
    func validated(against range: CommitRange) throws -> RewritePlan {
        guard !commits.isEmpty else { throw PlanError.emptyPlan }

        let rangeShas = range.commits.map(\.sha)
        let rangeShaSet = Set(rangeShas)

        /// Resolves a step SHA to a full range SHA (exact or unique-prefix).
        func resolve(_ sha: String) throws -> String {
            if rangeShaSet.contains(sha) { return sha }
            let matches = rangeShas.filter { $0.hasPrefix(sha) }
            switch matches.count {
            case 0: throw PlanError.shaOutsideRange(sha)
            case 1: return matches[0]
            default: throw PlanError.ambiguousPrefix(sha)
            }
        }

        var seen = Set<String>()
        var resolvedSteps: [RewriteStep] = []

        for step in commits {
            let full = try resolve(step.sha)
            guard !seen.contains(full) else { throw PlanError.duplicateSha(step.sha) }
            seen.insert(full)
            resolvedSteps.append(RewriteStep(
                sha: full,
                action: step.action,
                keepMessage: step.keepMessage,
                message: step.message
            ))
        }

        for sha in rangeShas {
            guard seen.contains(sha) else { throw PlanError.missingCommit(sha) }
        }

        if resolvedSteps.first?.action == .combine { throw PlanError.firstStepIsCombine }

        for step in resolvedSteps where step.action == .reword {
            let msg = step.message ?? ""
            guard !msg.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw PlanError.rewordWithoutMessage(step.sha)
            }
        }

        for step in resolvedSteps where step.action == .combine {
            guard step.keepMessage != nil else {
                throw PlanError.combineWithoutKeepMessage(step.sha)
            }
        }

        return RewritePlan(commits: resolvedSteps)
    }
}
