import Foundation
import Testing
@testable import GitThatKit

// MARK: - Fixtures

private let localCommits = CommitRange(
    commits: [
        CommitInfo(sha: "a3f21c9", subject: "wip",               isPushed: false),
        CommitInfo(sha: "8b02de1", subject: "fix typo",           isPushed: false),
    ],
    baseSha: "base000"
)

private let mixedCommits = CommitRange(
    commits: [
        CommitInfo(sha: "a3f21c9", subject: "wip",                  isPushed: false),
        CommitInfo(sha: "8b02de1", subject: "fix typo",              isPushed: false),
        CommitInfo(sha: "c4e7a10", subject: "add token refresh",     isPushed: true),
        CommitInfo(sha: "1d9f003", subject: "wip auth scaffolding",  isPushed: true),
    ],
    baseSha: "base000"
)

private func keepAll(_ range: CommitRange) -> RewritePlan {
    RewritePlan(commits: range.commits.map { RewriteStep(sha: $0.sha, action: .keep) })
}

// MARK: - preview: header

@Test func previewShowsBranch() {
    let out = RewriteRender.preview(range: localCommits, plan: keepAll(localCommits), branch: "feature/sso")
    #expect(out.contains("feature/sso"))
}

@Test func previewNilBranchDoesNotCrash() {
    let out = RewriteRender.preview(range: localCommits, plan: keepAll(localCommits), branch: nil)
    #expect(out.contains("wip"))
}

@Test func previewShowsCommitCount() {
    let out = RewriteRender.preview(range: localCommits, plan: keepAll(localCommits), branch: "main")
    #expect(out.contains("2"))
}

// MARK: - preview: before list

@Test func previewBeforeListContainsAllShas() {
    let out = RewriteRender.preview(range: mixedCommits, plan: keepAll(mixedCommits), branch: "main")
    for commit in mixedCommits.commits {
        #expect(out.contains(commit.sha.prefix(7)))
    }
}

@Test func previewMarksPushedCommits() {
    let out = RewriteRender.preview(range: mixedCommits, plan: keepAll(mixedCommits), branch: "main")
    #expect(out.contains("⚠"))
}

@Test func previewLocalCommitsHaveNoPushedMarker() {
    let out = RewriteRender.preview(range: localCommits, plan: keepAll(localCommits), branch: "main")
    #expect(!out.contains("⚠"))
}

// MARK: - preview: after list

@Test func previewAfterListShowsKeptSubjects() {
    let out = RewriteRender.preview(range: localCommits, plan: keepAll(localCommits), branch: "main")
    #expect(out.contains("wip"))
    #expect(out.contains("fix typo"))
}

@Test func previewAfterListOmitsDeletedCommit() {
    let plan = RewritePlan(commits: [
        RewriteStep(sha: "a3f21c9", action: .keep),
        RewriteStep(sha: "8b02de1", action: .delete),
    ])
    let out = RewriteRender.preview(range: localCommits, plan: plan, branch: "main")
    // "fix typo" should not appear in the after section
    // We split on a known after header and check only that half
    let parts = out.components(separatedBy: "After")
    #expect(parts.count >= 2)
    #expect(!parts.last!.contains("fix typo"))
}

@Test func previewAfterListShowsNewMessageForReword() {
    let range = CommitRange(
        commits: [CommitInfo(sha: "a3f21c9", subject: "wip", isPushed: false)],
        baseSha: nil
    )
    let plan = RewritePlan(commits: [
        RewriteStep(sha: "a3f21c9", action: .reword, message: "feat: real commit message"),
    ])
    let out = RewriteRender.preview(range: range, plan: plan, branch: "main")
    let parts = out.components(separatedBy: "After")
    #expect(parts.count >= 2)
    #expect(parts.last!.contains("feat: real commit message"))
}

@Test func previewAfterDeleteEverythingShowsEmptyNote() {
    let plan = RewritePlan(commits: [
        RewriteStep(sha: "a3f21c9", action: .delete),
        RewriteStep(sha: "8b02de1", action: .delete),
    ])
    let out = RewriteRender.preview(range: localCommits, plan: plan, branch: "main")
    // Should still render without crashing and show the empty-state message
    #expect(out.contains("(all commits removed)"))
}

// MARK: - preview: boundary statement

@Test func previewStatesThisBranchOnly() {
    let out = RewriteRender.preview(range: localCommits, plan: keepAll(localCommits), branch: "main")
    let lower = out.lowercased()
    #expect(lower.contains("branch"))
    #expect(lower.contains("other branch"))
}

// MARK: - pushedWarning

@Test func pushedWarningAbsentWhenNoPushedCommits() {
    let warning = RewriteRender.pushedWarning(range: localCommits, upstream: "origin/main")
    #expect(warning == nil)
}

@Test func pushedWarningPresentWhenHasPushed() {
    let warning = RewriteRender.pushedWarning(range: mixedCommits, upstream: "origin/main")
    #expect(warning != nil)
}

@Test func pushedWarningContainsForcePushCommand() {
    let warning = RewriteRender.pushedWarning(range: mixedCommits, upstream: "origin/main")!
    #expect(warning.contains("git push --force-with-lease"))
}

@Test func pushedWarningDoesNotOfferToRunPush() {
    let warning = RewriteRender.pushedWarning(range: mixedCommits, upstream: "origin/main")!
    let lower = warning.lowercased()
    // Must not say "will run", "running", "for you" — GITTHAT never pushes
    #expect(!lower.contains("will run"))
    #expect(!lower.contains("for you"))
}

@Test func pushedWarningNilUpstreamStillWorks() {
    let warning = RewriteRender.pushedWarning(range: mixedCommits, upstream: nil)
    #expect(warning != nil)
    #expect(warning!.contains("git push --force-with-lease"))
}

// MARK: - vocabulary lint

@Test func previewContainsNoForbiddenWords() {
    let out = RewriteRender.preview(range: mixedCommits, plan: keepAll(mixedCommits), branch: "feature/sso").lowercased()
    for word in ["rebase", "squash", "fixup", "pick"] {
        #expect(!out.contains(word), "preview contains forbidden word '\(word)'")
    }
}

@Test func pushedWarningContainsNoForbiddenWords() {
    let warning = (RewriteRender.pushedWarning(range: mixedCommits, upstream: "origin/main") ?? "").lowercased()
    for word in ["rebase", "squash", "fixup", "pick"] {
        #expect(!warning.contains(word), "pushedWarning contains forbidden word '\(word)'")
    }
}
