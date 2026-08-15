import Foundation

public struct CommitInfo: Sendable, Equatable {
    public let sha: String
    public let subject: String
    public let isPushed: Bool

    public init(sha: String, subject: String, isPushed: Bool) {
        self.sha = sha
        self.subject = subject
        self.isPushed = isPushed
    }
}

public struct CommitRange: Sendable, Equatable {
    /// Ordered oldest-first — matches todo-file order.
    public let commits: [CommitInfo]
    public let baseSha: String?
    public var hasPushed: Bool { commits.contains { $0.isPushed } }

    public init(commits: [CommitInfo], baseSha: String?) {
        self.commits = commits
        self.baseSha = baseSha
    }
}

public struct BackupRef: Sendable, Equatable {
    public let name: String
    public let sha: String
    public let timestamp: Date

    public init(name: String, sha: String, timestamp: Date) {
        self.name = name
        self.sha = sha
        self.timestamp = timestamp
    }
}

public enum SafetyError: Error, Equatable {
    case dirtyTree
    case noUpstreamAndNoDefaultBranch
    case emptyRange
    case detachedHead
    case unbornHead
}

public struct Safety: Sendable {
    private let git: Git
    private static let backupPrefix = "refs/gitthat/backup"

    public init(git: Git) {
        self.git = git
    }

    /// Resolves the commit range to operate on.
    /// - `count` overrides automatic detection.
    /// - Without count: defaults to `@{upstream}..HEAD`; if no upstream, uses merge-base with default branch.
    /// - `isPushed` is true when a commit is an ancestor of the upstream ref.
    public func resolveRange(count: Int?) throws -> CommitRange {
        // Distinguish between unborn HEAD (no commits) and detached HEAD (real commit without branch).
        let currentBranch = try git.currentBranch()
        let recentSubjects = try git.recentSubjects(1)

        if recentSubjects.isEmpty && currentBranch == nil {
            // No commits at all — unborn HEAD
            throw SafetyError.unbornHead
        }

        guard currentBranch != nil else {
            throw SafetyError.detachedHead
        }

        let upstream = try git.upstreamRef()

        if let count {
            // count overrides: take exactly N commits from HEAD (capped at history length)
            let shas = try git.revListCount(count)
            // baseSha = parent of the oldest commit, if it exists
            let base = shas.first.flatMap { try? git.parentSha(of: $0) }
            return try buildRange(shas: shas, baseSha: base, upstream: upstream)
        }

        if let upstream {
            let shas = try git.revList("\(upstream)..HEAD")
            if shas.isEmpty { throw SafetyError.emptyRange }
            let base = try git.mergeBase("HEAD", upstream)
            return try buildRange(shas: shas, baseSha: base, upstream: upstream)
        }

        // No upstream: fall back to merge-base with default branch
        guard let defaultRef = try git.defaultBranchRef() else {
            // No default branch detectable — use all commits from root
            let shas = try git.revList("HEAD")
            if shas.isEmpty { throw SafetyError.emptyRange }
            return try buildRange(shas: shas, baseSha: nil, upstream: nil)
        }

        guard let base = try git.mergeBase("HEAD", defaultRef) else {
            throw SafetyError.noUpstreamAndNoDefaultBranch
        }

        let head = try git.headSha()
        // If merge-base == HEAD, we ARE the default branch — take all commits from root.
        let shas = base == head
            ? try git.revList("HEAD")
            : try git.revList("\(base)..HEAD")
        if shas.isEmpty { throw SafetyError.emptyRange }
        return try buildRange(shas: shas, baseSha: base == head ? nil : base, upstream: nil)
    }

    private func buildRange(shas: [String], baseSha: String?, upstream: String?) throws -> CommitRange {
        let commits: [CommitInfo] = try shas.map { sha in
            let subject = try git.subject(of: sha)
            let pushed: Bool
            if let upstream {
                pushed = try git.isAncestor(sha, of: upstream)
            } else {
                pushed = false
            }
            return CommitInfo(sha: sha, subject: subject, isPushed: pushed)
        }
        return CommitRange(commits: commits, baseSha: baseSha)
    }

    /// Creates a backup ref at `refs/gitthat/backup/<unix-timestamp>-<uuid>` pointing at HEAD.
    /// Always written BEFORE any git operation that might move HEAD.
    @discardableResult
    public func createBackupRef() throws -> String {
        let head = try git.headSha()
        let ts = Int(Date().timeIntervalSince1970)
        let uuid = UUID().uuidString.lowercased()
        let name = "\(Self.backupPrefix)/\(ts)-\(uuid)"
        try git.updateRef(name, to: head)
        return name
    }

    /// Lists all backup refs, newest first.
    public func backups() throws -> [BackupRef] {
        let pairs = try git.refsMatching(Self.backupPrefix)
        return pairs.compactMap { (name, sha) -> BackupRef? in
            // name: refs/gitthat/backup/<timestamp>-<uuid>
            guard let refComponent = name.split(separator: "/").last,
                  let dashIdx = refComponent.firstIndex(of: "-") else { return nil }
            let tsStr = String(refComponent[..<dashIdx])
            guard let ts = Double(tsStr) else { return nil }
            return BackupRef(name: name, sha: sha, timestamp: Date(timeIntervalSince1970: ts))
        }.sorted { $0.timestamp > $1.timestamp }
    }

    /// Resets the current branch to `sha`. `hard` also resets the working tree.
    public func restore(to sha: String, hard: Bool) throws {
        if hard {
            try git.resetHard(to: sha)
        } else {
            try git.resetSoft(to: sha)
        }
    }

    /// Returns true when the working tree and index are clean.
    public func isClean() throws -> Bool {
        let result = try git.isClean()
        return result
    }
}
