import Foundation

// MARK: - Error

public enum ConflictError: Error, Equatable {
    case notStopped
    case unreadableFile(String)
}

// MARK: - ConflictedFile

/// One file that is in a conflicted state.
///
/// `ours` and `theirs` are `String?`:
/// - Non-nil: the text content of that side.
/// - `nil`: either the side deleted the file (check `oursIsDeleted`/`theirsIsDeleted`)
///   or the content is binary (not valid UTF-8). These two cases are distinct:
///   - `isDeleted == true`: the index stage is absent — the side intentionally removed the file.
///   - `isDeleted == false` with `nil` content: binary file, cannot be decoded as text.
///
/// `merged` is the file as git left it on disk, conflict markers included.
public struct ConflictedFile: Sendable, Equatable {
    public let path: String
    public let ours: String?
    /// `true` when our side (HEAD) has no index stage — the file was deleted on our side.
    /// Only meaningful when `ours == nil`.
    public let oursIsDeleted: Bool
    public let theirs: String?
    /// `true` when their side has no index stage — the incoming commit deleted the file.
    /// Only meaningful when `theirs == nil`.
    public let theirsIsDeleted: Bool
    public let merged: String

    public init(
        path: String,
        ours: String?,
        theirs: String?,
        merged: String,
        oursIsDeleted: Bool = false,
        theirsIsDeleted: Bool = false
    ) {
        self.path = path
        self.ours = ours
        self.oursIsDeleted = oursIsDeleted
        self.theirs = theirs
        self.theirsIsDeleted = theirsIsDeleted
        self.merged = merged
    }
}

// MARK: - ConflictSet

/// The full set of files in conflict and the subject of the commit being applied.
///
/// Holds no behaviour — it is a data snapshot. Policy and resolution logic live elsewhere.
public struct ConflictSet: Sendable, Equatable {
    public let files: [ConflictedFile]
    /// Subject of the commit git was applying when it stopped (the "theirs" intent).
    /// `nil` when the state directory does not record a stopped SHA (e.g. a bare cherry-pick
    /// stopped outside a rebase session).
    public let applyingSubject: String?

    /// Reads the current conflict state from the repository at `directory`.
    /// Throws `ConflictError.notStopped` when no unmerged paths exist.
    public static func collect(git: Git, directory: URL) throws -> ConflictSet {
        let paths = try git.conflictedPaths()
        guard !paths.isEmpty else { throw ConflictError.notStopped }

        let files: [ConflictedFile] = try paths.map { path in
            let sides = try git.conflictSides(path)
            let fileURL = directory.appendingPathComponent(path)
            let merged = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            return ConflictedFile(
                path: path,
                ours: sides.ours,
                theirs: sides.theirs,
                merged: merged,
                oursIsDeleted: sides.oursIsDeleted,
                theirsIsDeleted: sides.theirsIsDeleted
            )
        }

        let subject = try git.stoppedCommitSubject()
        return ConflictSet(files: files, applyingSubject: subject)
    }
}
