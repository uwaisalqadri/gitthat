import Foundation
import Testing
@testable import GitThatKit

@Test func resolvesUnpushedCommitsByDefault() throws {
    let repo = RepoFixture()
        .commit("feat: one", file: "a.txt", contents: "1")
        .commit("feat: two", file: "b.txt", contents: "2")
        .push()
        .commit("feat: three", file: "c.txt", contents: "3")

    let range = try Safety(git: repo.git).resolveRange(count: nil)

    #expect(range.commits.map(\.subject) == ["feat: three"])
    #expect(range.hasPushed == false)
}

@Test func marksPushedCommitsWhenCountReachesPastUpstream() throws {
    let repo = RepoFixture()
        .commit("feat: one", file: "a.txt", contents: "1")
        .commit("feat: two", file: "b.txt", contents: "2")
        .push()
        .commit("feat: three", file: "c.txt", contents: "3")

    let range = try Safety(git: repo.git).resolveRange(count: 3)

    #expect(range.commits.map(\.subject) == ["feat: one", "feat: two", "feat: three"])
    #expect(range.commits.map(\.isPushed) == [true, true, false])
    #expect(range.hasPushed)
}

@Test func rangeIsOrderedOldestFirst() throws {
    let repo = RepoFixture()
        .commit("feat: alpha", file: "a.txt", contents: "1")
        .commit("feat: beta", file: "b.txt", contents: "2")
        .commit("feat: gamma", file: "c.txt", contents: "3")

    let range = try Safety(git: repo.git).resolveRange(count: 3)

    #expect(range.commits.map(\.subject) == ["feat: alpha", "feat: beta", "feat: gamma"])
}

@Test func fallsBackToMergeBaseWithoutUpstream() throws {
    // No push() call, so no upstream. Should still produce a non-empty range
    // by finding merge-base with the default branch (which is the branch itself here,
    // so we need at least one commit for a meaningful range).
    let repo = RepoFixture()
        .commit("feat: one", file: "a.txt", contents: "1")
        .commit("feat: two", file: "b.txt", contents: "2")

    let range = try Safety(git: repo.git).resolveRange(count: nil)

    #expect(!range.commits.isEmpty)
    // With no upstream, nothing is considered pushed
    #expect(range.commits.allSatisfy { !$0.isPushed })
}

@Test func emptyRangeIsReported() throws {
    let repo = RepoFixture().commit("feat: one", file: "a.txt", contents: "1").push()
    #expect(throws: SafetyError.emptyRange) {
        try Safety(git: repo.git).resolveRange(count: nil)
    }
}

@Test func backupRefPointsAtHeadAndSurvives() throws {
    let repo = RepoFixture().commit("feat: one", file: "a.txt", contents: "1")
    let safety = Safety(git: repo.git)
    let head = try repo.git.headSha()

    let name = try safety.createBackupRef()

    #expect(name.hasPrefix("refs/gitthat/backup/"))
    let found = try safety.backups()
    #expect(found.contains { $0.sha == head })
}

@Test func restoreMovesBranchBackToBackup() throws {
    let repo = RepoFixture()
        .commit("feat: one", file: "a.txt", contents: "1")
    let safety = Safety(git: repo.git)
    let originalHead = try repo.git.headSha()

    _ = try safety.createBackupRef()

    // Make another commit after the backup
    repo.commit("feat: two", file: "b.txt", contents: "2")

    // HEAD should now be the new commit
    let newHead = try repo.git.headSha()
    #expect(newHead != originalHead)

    // Restore to backup
    try safety.restore(to: originalHead, hard: true)

    let restoredHead = try repo.git.headSha()
    #expect(restoredHead == originalHead)
}

@Test func detectsDirtyTree() throws {
    let repo = RepoFixture()
        .commit("feat: one", file: "a.txt", contents: "1")
        .write(file: "dirty.txt", contents: "not staged")

    let safety = Safety(git: repo.git)

    #expect(try safety.isClean() == false)
}

@Test func cleanTreeIsReportedClean() throws {
    let repo = RepoFixture().commit("feat: one", file: "a.txt", contents: "1")
    #expect(try Safety(git: repo.git).isClean() == true)
}

@Test func backupRefsAreUniqueEvenInSameSecond() throws {
    let repo = RepoFixture().commit("feat: one", file: "a.txt", contents: "1")
    let safety = Safety(git: repo.git)

    // Create first backup
    let backup1 = try safety.createBackupRef()
    let sha1 = try repo.git.headSha()

    // Move HEAD to a different commit
    repo.commit("feat: two", file: "b.txt", contents: "2")
    let sha2 = try repo.git.headSha()

    // Create second backup (may be within the same second)
    let backup2 = try safety.createBackupRef()

    // Both refs should exist and be different
    #expect(backup1 != backup2)
    let allBackups = try safety.backups()
    #expect(allBackups.count >= 2)
    #expect(allBackups.contains { $0.name == backup1 && $0.sha == sha1 })
    #expect(allBackups.contains { $0.name == backup2 && $0.sha == sha2 })
}

@Test func unbornHeadIsDistinctFromDetachedHead() throws {
    let repo = RepoFixture()
    // Don't commit anything — unborn HEAD
    let safety = Safety(git: repo.git)

    #expect(throws: SafetyError.unbornHead) {
        try safety.resolveRange(count: nil)
    }
}
