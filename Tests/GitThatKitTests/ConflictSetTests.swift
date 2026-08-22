import Foundation
import Testing
@testable import GitThatKit

// MARK: - Helpers

/// Builds a repo stopped mid-cherry-pick on a single text conflict.
/// Layout:
///   base   — shared ancestor, file.txt = "base\n"
///   main   — adds "main-line\n" to file.txt (the state on HEAD when cherry-pick runs)
///   picked — edits file.txt to "picked-line\n" (the commit being applied; subject = "add picked line")
/// cherry-pick of `picked` onto `main` conflicts because both touch file.txt.
private func repoWithSingleConflict() -> RepoFixture {
    let repo = RepoFixture()
    repo.commit("base commit", file: "file.txt", contents: "base\n")
    // Remember base SHA so we can branch from it
    let baseSha = repo.run(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    // Commit that will be cherry-picked (divergent change)
    repo.run(["checkout", "-q", "-b", "branch-a"])
    repo.commit("add picked line", file: "file.txt", contents: "picked-line\n")
    let pickedSha = repo.run(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    // Go back to base and add a conflicting change on main
    repo.run(["checkout", "-q", "main"])
    repo.run(["reset", "--hard", baseSha])
    repo.commit("main change", file: "file.txt", contents: "main-line\n")

    // cherry-pick the branch-a commit — this will conflict
    repo.run(["cherry-pick", "--no-commit", pickedSha])
    // Leave the repo in the conflicted state (don't abort or continue)
    return repo
}

/// Builds a repo stopped mid-cherry-pick on two conflicting files.
private func repoWithTwoConflicts() -> RepoFixture {
    let repo = RepoFixture()
    repo.commit("base", file: "a.txt", contents: "base-a\n")
    repo.commit("add b", file: "b.txt", contents: "base-b\n")
    let baseSha = repo.run(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    repo.run(["checkout", "-q", "-b", "br"])
    repo.commit("modify both", file: "a.txt", contents: "branch-a\n")
    repo.commit("modify b", file: "b.txt", contents: "branch-b\n")
    // cherry-pick both from HEAD~1..HEAD won't work cleanly; use a single commit touching both
    // Instead: squash into one commit on branch
    // Reset branch to base and make one commit touching both files
    repo.run(["reset", "--hard", baseSha])
    repo.run(["checkout", "-q", "-b", "br2"])
    try! "branch-a\n".write(to: repo.directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try! "branch-b\n".write(to: repo.directory.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
    repo.run(["add", "-A"])
    repo.run(["commit", "-qm", "two file change"])
    let pickSha = repo.run(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    // Back on main, make divergent changes to both files
    repo.run(["checkout", "-q", "main"])
    repo.run(["reset", "--hard", baseSha])
    repo.commit("main-a", file: "a.txt", contents: "main-a\n")
    repo.commit("main-b", file: "b.txt", contents: "main-b\n")

    repo.run(["cherry-pick", "--no-commit", pickSha])
    return repo
}

/// Builds a repo where one side deleted the file.
/// Layout: base has file.txt; branch-del deletes it; main modifies it.
/// cherry-pick of branch-del onto main produces a delete/modify conflict.
private func repoWithDeleteConflict() -> RepoFixture {
    let repo = RepoFixture()
    repo.commit("base", file: "file.txt", contents: "content\n")
    let baseSha = repo.run(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    // Branch: delete the file
    repo.run(["checkout", "-q", "-b", "del-branch"])
    repo.run(["rm", "file.txt"])
    repo.run(["commit", "-qm", "delete file"])
    let delSha = repo.run(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    // Main: modify the file
    repo.run(["checkout", "-q", "main"])
    repo.run(["reset", "--hard", baseSha])
    repo.commit("modify file", file: "file.txt", contents: "modified content\n")

    // Cherry-pick the delete onto main — conflict: modified by us, deleted by them
    repo.run(["cherry-pick", "--no-commit", delSha])
    return repo
}

/// Builds a repo where a binary file conflicts.
private func repoWithBinaryConflict() -> RepoFixture {
    let repo = RepoFixture()
    // Write a binary file (PNG magic bytes)
    let binaryBase = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02])
    try! binaryBase.write(to: repo.directory.appendingPathComponent("image.png"))
    repo.run(["add", "-A"])
    repo.run(["commit", "-qm", "add binary"])
    let baseSha = repo.run(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    // Branch: different binary
    repo.run(["checkout", "-q", "-b", "bin-branch"])
    let binaryBranch = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0xFE])
    try! binaryBranch.write(to: repo.directory.appendingPathComponent("image.png"))
    repo.run(["add", "-A"])
    repo.run(["commit", "-qm", "branch binary"])
    let binSha = repo.run(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    // Main: different binary
    repo.run(["checkout", "-q", "main"])
    repo.run(["reset", "--hard", baseSha])
    let binaryMain = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xAA, 0xBB])
    try! binaryMain.write(to: repo.directory.appendingPathComponent("image.png"))
    repo.run(["add", "-A"])
    repo.run(["commit", "-qm", "main binary"])

    repo.run(["cherry-pick", "--no-commit", binSha])
    return repo
}

/// Builds a repo stopped mid-cherry-pick via a PLAIN cherry-pick (no --no-commit),
/// so that git writes CHERRY_PICK_HEAD. The commit being applied has subject "add picked line".
private func repoWithCherryPickStopped() -> RepoFixture {
    let repo = RepoFixture()
    repo.commit("base commit", file: "file.txt", contents: "base\n")
    let baseSha = repo.run(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    repo.run(["checkout", "-q", "-b", "branch-a"])
    repo.commit("add picked line", file: "file.txt", contents: "picked-line\n")
    let pickedSha = repo.run(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    repo.run(["checkout", "-q", "main"])
    repo.run(["reset", "--hard", baseSha])
    repo.commit("main change", file: "file.txt", contents: "main-line\n")

    // Plain cherry-pick: stops at conflict and writes CHERRY_PICK_HEAD
    repo.run(["cherry-pick", pickedSha])
    return repo
}

/// Builds a repo stopped mid-interactive-rebase so that rebase-merge/stopped-sha is written.
/// The commit being replayed has subject "branch change".
private func repoWithRebaseStopped() -> RepoFixture {
    let repo = RepoFixture()
    repo.commit("base", file: "file.txt", contents: "base\n")
    let baseSha = repo.run(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    // Make a conflicting commit on main
    repo.commit("main change", file: "file.txt", contents: "main-line\n")
    let mainTip = repo.run(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    // Branch from base with a commit that will conflict during rebase
    repo.run(["checkout", "-q", "-b", "branch-a", baseSha])
    repo.commit("branch change", file: "file.txt", contents: "branch-line\n")

    // Rebase branch-a onto main — conflicts, leaving rebase-merge/stopped-sha.
    // GIT_SEQUENCE_EDITOR=true makes git accept the todo list without opening an editor.
    var env = ProcessInfo.processInfo.environment
    for (k, v) in isolatedGitEnvironment { env[k] = v }
    env["GIT_SEQUENCE_EDITOR"] = "true"
    env["GIT_TERMINAL_PROMPT"] = "0"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "rebase", "-i", mainTip]
    process.currentDirectoryURL = repo.directory
    process.environment = env
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    // Non-zero exit is expected (conflict); the repo is left in rebase-stopped state
    return repo
}

// MARK: - ConflictError tests

@Test func conflictedPathsFailsWhenNotStopped() throws {
    let repo = RepoFixture()
        .commit("a", file: "f.txt", contents: "x\n")
    #expect(throws: ConflictError.notStopped) {
        try repo.git.conflictedPaths()
    }
}

// MARK: - Single text conflict

@Test func detectsSingleConflictedPath() throws {
    let repo = repoWithSingleConflict()
    let paths = try repo.git.conflictedPaths()
    #expect(paths == ["file.txt"])
}

@Test func readsBothSidesOfTextConflict() throws {
    let repo = repoWithSingleConflict()
    let sides = try repo.git.conflictSides("file.txt")
    #expect(sides.ours == "main-line\n")
    #expect(sides.oursIsDeleted == false)
    #expect(sides.theirs == "picked-line\n")
    #expect(sides.theirsIsDeleted == false)
}

@Test func readsMergedFileWithConflictMarkers() throws {
    let repo = repoWithSingleConflict()
    let merged = try String(contentsOf: repo.directory.appendingPathComponent("file.txt"), encoding: .utf8)
    #expect(merged.contains("<<<<<<<"))
    #expect(merged.contains("main-line"))
    #expect(merged.contains("picked-line"))
}

@Test func unmergedPathsRemainIsTrueWhenConflicted() throws {
    let repo = repoWithSingleConflict()
    #expect(try repo.git.unmergedPathsRemain() == true)
}

@Test func unmergedPathsRemainIsFalseWhenClean() throws {
    let repo = RepoFixture().commit("a", file: "f.txt", contents: "x\n")
    #expect(try repo.git.unmergedPathsRemain() == false)
}

// MARK: - Two conflicted files

@Test func detectsTwoConflictedPaths() throws {
    let repo = repoWithTwoConflicts()
    let paths = try repo.git.conflictedPaths()
    #expect(Set(paths) == Set(["a.txt", "b.txt"]))
}

// MARK: - Delete conflict

@Test func deletedSideReturnsNilTheirs() throws {
    let repo = repoWithDeleteConflict()
    let paths = try repo.git.conflictedPaths()
    #expect(paths == ["file.txt"])
    let sides = try repo.git.conflictSides("file.txt")
    // Theirs deleted the file — no stage 3
    #expect(sides.theirs == nil)
    #expect(sides.theirsIsDeleted == true)
    // Ours modified it — stage 2 present
    #expect(sides.ours != nil)
    #expect(sides.oursIsDeleted == false)
}

// MARK: - Binary conflict

@Test func binaryConflictSidesAreNil() throws {
    let repo = repoWithBinaryConflict()
    let paths = try repo.git.conflictedPaths()
    #expect(paths == ["image.png"])
    let sides = try repo.git.conflictSides("image.png")
    // Binary files can't be decoded as UTF-8 text — both sides are nil but NOT deleted
    #expect(sides.ours == nil)
    #expect(sides.oursIsDeleted == false)
    #expect(sides.theirs == nil)
    #expect(sides.theirsIsDeleted == false)
}

// MARK: - stoppedCommitSubject

@Test func stoppedCommitSubjectIsNilWhenNotStopped() throws {
    let repo = RepoFixture().commit("a", file: "f.txt", contents: "x\n")
    #expect(try repo.git.stoppedCommitSubject() == nil)
}

// Note: stoppedCommitSubject during a cherry-pick is tested indirectly via ConflictSet.
// The cherry-pick state is in .git/CHERRY_PICK_HEAD, not rebase-merge/stopped-sha.
// We test the ConflictSet.collect() path which handles both states.

// MARK: - ConflictSet.collect

@Test func collectBuildsConflictSetForSingleFile() throws {
    let repo = repoWithSingleConflict()
    let cs = try ConflictSet.collect(git: repo.git, directory: repo.directory)
    #expect(cs.files.count == 1)
    #expect(cs.files[0].path == "file.txt")
    #expect(cs.files[0].ours == "main-line\n")
    #expect(cs.files[0].theirs == "picked-line\n")
    #expect(cs.files[0].merged.contains("<<<<<<<"))
}

@Test func applyingSubjectIsCherryPickCommitSubject() throws {
    // Plain cherry-pick writes CHERRY_PICK_HEAD — applyingSubject must return the subject
    // of the commit being applied, NOT HEAD and NOT the previous commit.
    let repo = repoWithCherryPickStopped()
    let cs = try ConflictSet.collect(git: repo.git, directory: repo.directory)
    #expect(cs.applyingSubject == "add picked line")
}

@Test func applyingSubjectIsRebaseStoppedCommitSubject() throws {
    // Interactive rebase that stops at a conflict writes rebase-merge/stopped-sha —
    // applyingSubject must return the subject of the commit being replayed.
    let repo = repoWithRebaseStopped()
    let cs = try ConflictSet.collect(git: repo.git, directory: repo.directory)
    #expect(cs.applyingSubject == "branch change")
}

@Test func collectForTwoFiles() throws {
    let repo = repoWithTwoConflicts()
    let cs = try ConflictSet.collect(git: repo.git, directory: repo.directory)
    #expect(cs.files.count == 2)
    let paths = Set(cs.files.map(\.path))
    #expect(paths == Set(["a.txt", "b.txt"]))
}

@Test func collectDeleteConflict() throws {
    let repo = repoWithDeleteConflict()
    let cs = try ConflictSet.collect(git: repo.git, directory: repo.directory)
    #expect(cs.files.count == 1)
    let f = cs.files[0]
    #expect(f.path == "file.txt")
    #expect(f.theirs == nil)
    #expect(f.theirsIsDeleted == true)   // deleted on their side
    #expect(f.ours != nil)
    #expect(f.oursIsDeleted == false)
}

@Test func collectBinaryConflict() throws {
    let repo = repoWithBinaryConflict()
    let cs = try ConflictSet.collect(git: repo.git, directory: repo.directory)
    #expect(cs.files.count == 1)
    let f = cs.files[0]
    #expect(f.path == "image.png")
    #expect(f.ours == nil)
    #expect(f.oursIsDeleted == false)    // present but binary, not deleted
    #expect(f.theirs == nil)
    #expect(f.theirsIsDeleted == false)  // present but binary, not deleted
}

// MARK: - stage

@Test func stageMarksFileResolved() throws {
    let repo = repoWithSingleConflict()
    // Write a resolved version
    try "resolved\n".write(to: repo.directory.appendingPathComponent("file.txt"),
                            atomically: true, encoding: .utf8)
    try repo.git.stage("file.txt")
    #expect(try repo.git.unmergedPathsRemain() == false)
}
