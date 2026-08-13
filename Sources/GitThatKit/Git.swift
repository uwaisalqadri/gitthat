import Foundation

public struct StagedDiff: Sendable, Equatable {
    public let text: String
    public let wasTruncated: Bool
}

public enum GitError: Error, Equatable {
    case notARepository
    case commandFailed(command: String, stderr: String)
}

/// Typed queries over a repository. Holds no policy — it runs commands and
/// returns values, and every decision is made by a caller.
public struct Git: Sendable {
    private let runner: GitRunner
    private let directory: URL

    public init(runner: GitRunner, directory: URL) {
        self.runner = runner
        self.directory = directory
    }

    public func isRepository() -> Bool {
        guard let result = try? runner.run(["rev-parse", "--is-inside-work-tree"],
                                           in: directory, stdin: nil) else { return false }
        return result.succeeded
    }

    public func stagedDiff(limit: Int) throws -> StagedDiff {
        let text = try require(["diff", "--cached"])
        guard text.count > limit else {
            return StagedDiff(text: text, wasTruncated: false)
        }
        return StagedDiff(text: String(text.prefix(limit)), wasTruncated: true)
    }

    public func hasStagedChanges() throws -> Bool {
        let result = try runner.run(["diff", "--cached", "--quiet"], in: directory, stdin: nil)
        // --quiet exits 1 when there are differences, 0 when there are none.
        return result.exitCode == 1
    }

    public func stageAll() throws {
        _ = try require(["add", "-A"])
    }

    public func recentSubjects(_ count: Int) throws -> [String] {
        let result = try runner.run(["log", "--format=%s", "-n", String(count)],
                                    in: directory, stdin: nil)
        // An empty repository has no HEAD and git exits non-zero. That is not
        // an error here — it is a repository with no subjects.
        guard result.succeeded else { return [] }
        return result.stdout.split(separator: "\n").map(String.init)
    }

    public func currentBranch() throws -> String? {
        let result = try runner.run(["rev-parse", "--abbrev-ref", "HEAD"],
                                    in: directory, stdin: nil)
        guard result.succeeded else { return nil }
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return name == "HEAD" ? nil : name
    }

    /// Commits the staged changes and returns the new SHA.
    @discardableResult
    public func commit(message: String) throws -> String {
        _ = try require(["commit", "-q", "-F", "-"], stdin: message)
        return try require(["rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func require(_ arguments: [String], stdin: String? = nil) throws -> String {
        let result = try runner.run(arguments, in: directory, stdin: stdin)
        guard result.succeeded else {
            throw GitError.commandFailed(
                command: "git " + arguments.joined(separator: " "),
                stderr: result.stderr
            )
        }
        return result.stdout
    }
}
