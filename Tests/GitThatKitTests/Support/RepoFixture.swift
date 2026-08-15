import Foundation
@testable import GitThatKit

/// Builds a real git repository in a temp directory.
///
/// Building a four-commit repository costs about 2.7 seconds, so suites that
/// need many identical repositories should build one and copy it. `copy()`
/// costs about 34ms.
final class RepoFixture {
    let directory: URL
    let runner: SystemGitRunner
    private(set) var remoteDirectory: URL?

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitthat-repo-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        runner = SystemGitRunner(environmentOverrides: isolatedGitEnvironment)
        run(["init", "-q", "-b", "main"])
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        if let remoteDirectory { try? FileManager.default.removeItem(at: remoteDirectory) }
    }

    @discardableResult
    func run(_ arguments: [String], stdin: String? = nil) -> GitResult {
        try! runner.run(arguments, in: directory, stdin: stdin)
    }

    /// Writes a file and commits it with the given subject.
    @discardableResult
    func commit(_ subject: String, file: String, contents: String) -> Self {
        try! contents.write(to: directory.appendingPathComponent(file),
                            atomically: true, encoding: .utf8)
        run(["add", "-A"])
        run(["commit", "-q", "-m", subject])
        return self
    }

    /// Writes a file and stages it without committing.
    @discardableResult
    func stage(file: String, contents: String) -> Self {
        try! contents.write(to: directory.appendingPathComponent(file),
                            atomically: true, encoding: .utf8)
        run(["add", "-A"])
        return self
    }

    /// Writes a file without staging it.
    @discardableResult
    func write(file: String, contents: String) -> Self {
        try! contents.write(to: directory.appendingPathComponent(file),
                            atomically: true, encoding: .utf8)
        return self
    }

    @discardableResult
    func checkout(branch: String) -> Self {
        run(["checkout", "-q", "-b", branch])
        return self
    }

    /// Creates a bare repository, pushes everything committed so far, and sets
    /// upstream tracking. Everything committed before this call is "pushed".
    @discardableResult
    func push() -> Self {
        if remoteDirectory == nil {
            let remote = FileManager.default.temporaryDirectory
                .appendingPathComponent("gitthat-remote-\(UUID().uuidString)")
            try! FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
            try! runner.run(["init", "-q", "--bare"], in: remote, stdin: nil)
            remoteDirectory = remote
            run(["remote", "add", "origin", remote.path])
        }
        let branch = run(["rev-parse", "--abbrev-ref", "HEAD"])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        run(["push", "-q", "-u", "origin", branch])
        return self
    }

    var git: Git { Git(runner: runner, directory: directory) }

    func subjects() -> [String] {
        run(["log", "--format=%s"]).stdout
            .split(separator: "\n").map(String.init)
    }

    /// Returns a cheap copy of this fixture in a new temp directory.
    ///
    /// Copying a built `.git` directory costs ~34ms vs ~2.7s for a full rebuild,
    /// making this load-bearing for the exhaustive permutation suite. Each copy
    /// is an independent repo — rewrites in one do not affect the others.
    func copy() -> RepoFixture {
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitthat-repo-\(UUID().uuidString)")
        try! FileManager.default.copyItem(at: directory, to: dst)
        return RepoFixture(existingDirectory: dst, runner: runner)
    }

    /// Init from an already-initialised directory (used by `copy()`).
    private init(existingDirectory: URL, runner: SystemGitRunner) {
        self.directory = existingDirectory
        self.runner = runner
    }
}
