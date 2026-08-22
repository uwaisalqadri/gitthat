import Foundation
import Testing
@testable import GitThatKit

@Test func detectsARepository() {
    let repo = RepoFixture()
    #expect(repo.git.isRepository())
}

@Test func readsStagedDiff() throws {
    let repo = RepoFixture()
        .commit("initial", file: "a.txt", contents: "one\n")
        .stage(file: "b.txt", contents: "two\n")

    let diff = try repo.git.stagedDiff(limit: 8192)
    #expect(diff.text.contains("b.txt"))
    #expect(diff.text.contains("+two"))
    #expect(!diff.wasTruncated)
}

@Test func truncatesLargeDiffsAndSaysSo() throws {
    let repo = RepoFixture()
        .commit("initial", file: "a.txt", contents: "one\n")
        .stage(file: "big.txt", contents: String(repeating: "x\n", count: 20_000))

    let diff = try repo.git.stagedDiff(limit: 8192)
    #expect(diff.wasTruncated)
    #expect(diff.text.count == 8192)           // exact boundary, not just ≤
    #expect(diff.text.hasPrefix("diff --git")) // real diff content, not an empty string
}

@Test func reportsWhetherAnythingIsStaged() throws {
    let repo = RepoFixture().commit("initial", file: "a.txt", contents: "one\n")
    #expect(try repo.git.hasStagedChanges() == false)

    repo.stage(file: "b.txt", contents: "two\n")
    #expect(try repo.git.hasStagedChanges() == true)
}

@Test func stagesEverything() throws {
    let repo = RepoFixture()
        .commit("initial", file: "a.txt", contents: "one\n")
        .write(file: "b.txt", contents: "two\n")

    #expect(try repo.git.hasStagedChanges() == false)
    try repo.git.stageAll()
    #expect(try repo.git.hasStagedChanges() == true)
}

@Test func readsRecentSubjectsNewestFirst() throws {
    let repo = RepoFixture()
        .commit("first", file: "a.txt", contents: "1")
        .commit("second", file: "b.txt", contents: "2")
        .commit("third", file: "c.txt", contents: "3")

    #expect(try repo.git.recentSubjects(20) == ["third", "second", "first"])
}

@Test func recentSubjectsIsEmptyInAnEmptyRepository() throws {
    let repo = RepoFixture()
    #expect(try repo.git.recentSubjects(20) == [])
}

@Test func readsCurrentBranch() throws {
    let repo = RepoFixture()
        .commit("initial", file: "a.txt", contents: "1")
        .checkout(branch: "feature/PROJ-421-sso")

    #expect(try repo.git.currentBranch() == "feature/PROJ-421-sso")
}

@Test func commitsWithAMultiLineMessage() throws {
    let repo = RepoFixture()
        .commit("initial", file: "a.txt", contents: "1")
        .stage(file: "b.txt", contents: "2")

    let message = "feat(auth): add token refresh\n\nRefreshes ten seconds before expiry."
    let sha = try repo.git.commit(message: message)

    #expect(sha.count == 40)
    #expect(repo.subjects().first == "feat(auth): add token refresh")
    let body = repo.run(["log", "-1", "--format=%b"]).stdout
    #expect(body.contains("ten seconds before expiry"))
}
