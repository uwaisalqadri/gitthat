import Foundation

public struct StagedDiff: Sendable, Equatable {
    public let text: String
    public let wasTruncated: Bool
}

public enum GitError: Error, Equatable {
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

    // MARK: – Range queries

    /// Returns SHAs in the given range, oldest-first.
    public func revList(_ range: String) throws -> [String] {
        let out = try require(["rev-list", "--reverse", range])
        return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Returns up to `count` SHAs ending at HEAD, oldest-first.
    public func revListCount(_ count: Int) throws -> [String] {
        let out = try require(["rev-list", "--reverse", "--max-count", String(count), "HEAD"])
        return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Returns the parent SHA of `sha`, or nil if it is a root commit.
    public func parentSha(of sha: String) throws -> String? {
        let result = try runner.run(["rev-parse", "--verify", "\(sha)^"],
                                    in: directory, stdin: nil)
        guard result.succeeded else { return nil }
        let s = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Returns the one-line subject of a commit.
    public func subject(of sha: String) throws -> String {
        try require(["log", "-1", "--format=%s", sha])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the full ref name of the upstream branch, if any.
    public func upstreamRef() throws -> String? {
        let result = try runner.run(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
            in: directory, stdin: nil)
        guard result.succeeded else { return nil }
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Returns the ref of the default branch (main / master) if detectable.
    public func defaultBranchRef() throws -> String? {
        // Try refs/remotes/origin/HEAD first
        let result = try runner.run(
            ["symbolic-ref", "refs/remotes/origin/HEAD"],
            in: directory, stdin: nil)
        if result.succeeded {
            let ref = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return ref.isEmpty ? nil : ref
        }
        // Fall back to checking common names locally
        for candidate in ["refs/heads/main", "refs/heads/master"] {
            let check = try runner.run(["rev-parse", "--verify", candidate],
                                       in: directory, stdin: nil)
            if check.succeeded { return candidate }
        }
        return nil
    }

    /// Returns the merge-base SHA of two refs, or nil if none exists.
    public func mergeBase(_ a: String, _ b: String) throws -> String? {
        let result = try runner.run(["merge-base", a, b], in: directory, stdin: nil)
        guard result.succeeded else { return nil }
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// Writes a ref pointing at `sha`. Creates or overwrites.
    public func updateRef(_ name: String, to sha: String) throws {
        _ = try require(["update-ref", name, sha])
    }

    /// Returns all refs under `prefix` as (refName, sha) pairs.
    public func refsMatching(_ prefix: String) throws -> [(String, String)] {
        let result = try runner.run(
            ["for-each-ref", "--format=%(refname) %(objectname)", prefix],
            in: directory, stdin: nil)
        guard result.succeeded else { return [] }
        return result.stdout
            .split(separator: "\n")
            .compactMap { line -> (String, String)? in
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (parts[0], parts[1])
            }
    }

    public func resetHard(to sha: String) throws {
        _ = try require(["reset", "--hard", sha])
    }

    public func resetSoft(to sha: String) throws {
        _ = try require(["reset", "--soft", sha])
    }

    public func headSha() throws -> String {
        try require(["rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns true when the working tree and index have no modifications.
    public func isClean() throws -> Bool {
        let out = try require(["status", "--porcelain"])
        return out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns true if `a` is an ancestor of `b`.
    /// Uses `git merge-base --is-ancestor` which exits 0=yes, 1=no, >1=error.
    public func isAncestor(_ a: String, of b: String) throws -> Bool {
        let result = try runner.run(["merge-base", "--is-ancestor", a, b],
                                    in: directory, stdin: nil)
        if result.exitCode == 0 { return true }
        if result.exitCode == 1 { return false }
        throw GitError.commandFailed(
            command: "git merge-base --is-ancestor \(a) \(b)",
            stderr: result.stderr)
    }

    // MARK: – Reflog

    /// Returns raw reflog lines as tab-separated tuples: (sha, subject, ref-desc, relative-age).
    /// Format: `%H\t%gs\t%gd\t%cr`
    /// An empty list means no reflog exists (unborn HEAD or brand-new repo).
    public func reflog() throws -> [(sha: String, subject: String, refDesc: String, age: String)] {
        let result = try runner.run(
            ["reflog", "--format=%H%x09%gs%x09%gd%x09%cr"],
            in: directory, stdin: nil)
        guard result.succeeded else { return [] }
        return result.stdout
            .split(separator: "\n")
            .compactMap { line -> (String, String, String, String)? in
                let parts = line.split(separator: "\t", maxSplits: 3).map(String.init)
                guard parts.count == 4 else { return nil }
                return (parts[0], parts[1], parts[2], parts[3])
            }
    }

    // MARK: – Conflict support

    /// Returns paths with unresolved conflicts (index stages 2 and/or 3 present).
    /// Throws `ConflictError.notStopped` when there are no unmerged paths.
    public func conflictedPaths() throws -> [String] {
        let result = try runner.run(
            ["diff", "--name-only", "--diff-filter=U"],
            in: directory, stdin: nil)
        // git diff --name-only --diff-filter=U exits 0 even when there are no conflicts.
        // An empty result with no unmerged paths means we're not in a conflict state.
        guard result.succeeded else {
            throw ConflictError.notStopped
        }
        let paths = result.stdout
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !paths.isEmpty else { throw ConflictError.notStopped }
        return paths
    }

    /// Returns true when any unmerged paths remain in the index.
    public func unmergedPathsRemain() throws -> Bool {
        let result = try runner.run(
            ["diff", "--name-only", "--diff-filter=U"],
            in: directory, stdin: nil)
        guard result.succeeded else { return false }
        return !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns the text content and deletion status of both sides of a conflict for the given path.
    /// Stage 2 = "ours" (HEAD), stage 3 = "theirs" (being applied).
    ///
    /// For each side:
    /// - Non-nil text: the UTF-8 content of that stage.
    /// - nil text + `isDeleted == true`: the index stage is absent — the file was deleted on that side.
    /// - nil text + `isDeleted == false`: the stage exists but is binary (not valid UTF-8).
    public func conflictSides(_ path: String) throws -> (
        ours: String?, oursIsDeleted: Bool,
        theirs: String?, theirsIsDeleted: Bool
    ) {
        let (oursText, oursDeleted) = readIndexStage(2, path: path)
        let (theirsText, theirsDeleted) = readIndexStage(3, path: path)
        return (ours: oursText, oursIsDeleted: oursDeleted,
                theirs: theirsText, theirsIsDeleted: theirsDeleted)
    }

    /// Reads one index stage for `path` as raw bytes.
    /// Returns `(text, isDeleted)`:
    /// - `(String, false)`: stage present, UTF-8 decoded successfully.
    /// - `(nil, true)`:  stage absent — the file was deleted on this side.
    /// - `(nil, false)`: stage present but not valid UTF-8 — binary file.
    private func readIndexStage(_ stage: Int, path: String) -> (String?, Bool) {
        // Capture raw bytes via a temp file — the runner decodes via String(decoding:as:UTF8.self)
        // which replaces bad bytes, making binary indistinguishable from text. We need the raw data.
        let tmpURL = Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        var env = ProcessInfo.processInfo.environment
        for (k, v) in runner.environment { env[k] = v }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "show", ":\(stage):\(path)"]
        process.currentDirectoryURL = directory
        process.environment = env
        let outputHandle = try? FileHandle(forWritingTo: tmpURL)
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        try? process.run()
        process.waitUntilExit()
        try? outputHandle?.close()
        // Non-zero exit means the stage doesn't exist — file was deleted on this side.
        guard process.terminationStatus == 0 else { return (nil, true) }

        guard let data = try? Data(contentsOf: tmpURL) else { return (nil, false) }
        // Strict UTF-8: if any byte sequence is invalid, this is binary.
        return (String(data: data, encoding: .utf8), false)
    }

    /// Stages a file that has been resolved, marking it as no longer conflicted.
    public func stage(_ path: String) throws {
        _ = try require(["add", path])
    }

    /// Returns the subject of the commit git was applying when it stopped, or nil if unavailable.
    /// Reads `rebase-merge/stopped-sha` when in a rebase session; falls back to CHERRY_PICK_HEAD.
    public func stoppedCommitSubject() throws -> String? {
        func gitPath(_ name: String) -> URL? {
            guard let result = try? runner.run(
                ["rev-parse", "--git-path", name], in: directory, stdin: nil),
                  result.succeeded else { return nil }
            let p = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { return nil }
            return p.hasPrefix("/") ? URL(fileURLWithPath: p)
                                    : directory.appendingPathComponent(p)
        }

        // Rebase session: stopped-sha file holds the exact commit SHA
        if let stoppedURL = gitPath("rebase-merge/stopped-sha"),
           FileManager.default.fileExists(atPath: stoppedURL.path),
           let sha = try? String(contentsOf: stoppedURL, encoding: .utf8)
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !sha.isEmpty {
            return try? subject(of: sha)
        }

        // Cherry-pick outside a rebase: CHERRY_PICK_HEAD holds the commit SHA
        if let cpURL = gitPath("CHERRY_PICK_HEAD"),
           FileManager.default.fileExists(atPath: cpURL.path),
           let sha = try? String(contentsOf: cpURL, encoding: .utf8)
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !sha.isEmpty {
            return try? subject(of: sha)
        }

        return nil
    }

    // MARK: – Rewrite support

    /// Returns all local branch names (short format), used for cross-branch detection.
    public func localBranchNames() throws -> [String] {
        let result = try runner.run(["branch", "--format=%(refname:short)"], in: directory, stdin: nil)
        guard result.succeeded else { return [] }
        return result.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Runs `git rebase -i <baseSha>` (or `--root` when baseSha is nil) with the given
    /// environment additions. Returns the exit code and stderr — non-zero may mean conflict
    /// OR a real failure; callers must discriminate with `rewriteInProgress()`.
    public func rewriteInteractive(baseSha: String?, autostash: Bool = false, environment: [String: String]) throws -> (exitCode: Int32, stderr: String) {
        var env = ProcessInfo.processInfo.environment
        // Apply the runner's environment overrides first: this process spawns git
        // directly rather than going through runner.run, so without this it would
        // escape the isolation (e.g. GIT_CONFIG_GLOBAL) every other call receives.
        for (k, v) in runner.environment { env[k] = v }
        for (k, v) in environment { env[k] = v }
        env["GIT_TERMINAL_PROMPT"] = "0"
        if autostash { env[GitVocabulary.envRebaseAutostash] = "true" }

        let args: [String]
        if let base = baseSha {
            args = [GitVocabulary.rebaseVerb, "-i", base]
        } else {
            args = [GitVocabulary.rebaseVerb, "-i", "--root"]
        }

        let outputURL = Self.makeTempFile()
        let errorURL = Self.makeTempFile()
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = directory
        process.environment = env
        process.standardOutput = try FileHandle(forWritingTo: outputURL)
        process.standardError = try FileHandle(forWritingTo: errorURL)
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { throw GitRunnerError.couldNotLaunch(error.localizedDescription) }
        process.waitUntilExit()
        let stderr = (try? Data(contentsOf: errorURL)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return (exitCode: process.terminationStatus, stderr: stderr)
    }

    /// Continues an in-progress interactive rewrite session.
    @discardableResult
    public func rewriteContinue() throws -> Int32 {
        let result = try runner.run([GitVocabulary.rebaseVerb, "--continue"], in: directory, stdin: nil)
        return result.exitCode
    }

    /// Cancels an in-progress interactive rewrite session.
    @discardableResult
    public func rewriteAbort() throws -> Int32 {
        let result = try runner.run([GitVocabulary.rebaseVerb, "--abort"], in: directory, stdin: nil)
        return result.exitCode
    }

    /// Returns true when an interactive rewrite is currently in progress.
    public func rewriteInProgress() -> Bool {
        // Use git rev-parse --git-path so this works in worktrees and submodules
        // (where .git is a file, not a directory).
        func gitPath(_ name: String) -> String? {
            guard let result = try? runner.run(
                ["rev-parse", "--git-path", name], in: directory, stdin: nil),
                  result.succeeded else { return nil }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for name in ["rebase-merge", "rebase-apply"] {
            if let p = gitPath(name), !p.isEmpty {
                // The path may be relative to the repo root.
                let url = p.hasPrefix("/") ? URL(fileURLWithPath: p)
                                           : directory.appendingPathComponent(p)
                if FileManager.default.fileExists(atPath: url.path) { return true }
            }
        }
        return false
    }

    /// Returns the repository root (--show-toplevel), or nil on failure.
    public func topLevel() -> URL? {
        guard let result = try? runner.run(["rev-parse", "--show-toplevel"], in: directory, stdin: nil),
              result.succeeded else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    /// Runs a shell command in the repository directory and returns the exit code.
    public func shell(_ command: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Runs a shell command and captures combined stdout+stderr. Returns (exitCode, output).
    public func shellWithOutput(_ command: String) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    private static func makeTempFile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitthat-git-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
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
