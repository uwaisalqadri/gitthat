import Foundation
import Testing
@testable import GitThatKit

// MARK: - Helpers

private func range(shas: [String]) -> CommitRange {
    CommitRange(
        commits: shas.map { CommitInfo(sha: $0, subject: "msg", isPushed: false) },
        baseSha: nil
    )
}

private func step(_ sha: String, _ action: RewriteAction, keepMessage: Bool? = nil, message: String? = nil) -> RewriteStep {
    RewriteStep(sha: sha, action: action, keepMessage: keepMessage, message: message)
}

// MARK: - Codable round-trip

@Test func rewritePlanRoundTrip() throws {
    let plan = RewritePlan(commits: [
        step("abc123", .keep),
        step("def456", .reword, message: "fix: something"),
        step("ghi789", .combine, keepMessage: false),
        step("jkl012", .delete),
    ])
    let data = try JSONEncoder().encode(plan)
    let decoded = try JSONDecoder().decode(RewritePlan.self, from: data)
    #expect(decoded == plan)
}

// MARK: - resultingCommitCount

@Test func resultingCommitCountExcludesDeleteAndCombine() {
    let plan = RewritePlan(commits: [
        step("a", .keep),
        step("b", .combine),
        step("c", .reword, message: "x"),
        step("d", .delete),
    ])
    #expect(plan.resultingCommitCount == 2) // keep + reword
}

// MARK: - Validation: emptyPlan

@Test func emptyPlanRejected() throws {
    let plan = RewritePlan(commits: [])
    let r = range(shas: ["sha1"])
    #expect(throws: PlanError.emptyPlan) {
        try plan.validated(against: r)
    }
}

// MARK: - Validation: shaOutsideRange

@Test func shaOutsideRangeRejected() throws {
    let plan = RewritePlan(commits: [step("unknown", .keep)])
    let r = range(shas: ["sha1"])
    #expect(throws: PlanError.shaOutsideRange("unknown")) {
        try plan.validated(against: r)
    }
}

// MARK: - Validation: duplicateSha

@Test func duplicateShaRejected() throws {
    let plan = RewritePlan(commits: [step("sha1", .keep), step("sha1", .reword, message: "x")])
    let r = range(shas: ["sha1", "sha2"])
    #expect(throws: PlanError.duplicateSha("sha1")) {
        try plan.validated(against: r)
    }
}

// MARK: - Validation: missingCommit

@Test func missingCommitRejected() throws {
    let plan = RewritePlan(commits: [step("sha1", .keep)])
    let r = range(shas: ["sha1", "sha2"])
    #expect(throws: PlanError.missingCommit("sha2")) {
        try plan.validated(against: r)
    }
}

// MARK: - Validation: firstStepIsCombine

@Test func firstStepCombineRejected() throws {
    let plan = RewritePlan(commits: [step("sha1", .combine), step("sha2", .keep)])
    let r = range(shas: ["sha1", "sha2"])
    #expect(throws: PlanError.firstStepIsCombine) {
        try plan.validated(against: r)
    }
}

// MARK: - Validation: rewordWithoutMessage

@Test func rewordWithoutMessageRejected() throws {
    let plan = RewritePlan(commits: [step("sha1", .reword)])
    let r = range(shas: ["sha1"])
    #expect(throws: PlanError.rewordWithoutMessage("sha1")) {
        try plan.validated(against: r)
    }
}

@Test func rewordWithWhitespaceOnlyMessageRejected() throws {
    let plan = RewritePlan(commits: [step("sha1", .reword, message: "   ")])
    let r = range(shas: ["sha1"])
    #expect(throws: PlanError.rewordWithoutMessage("sha1")) {
        try plan.validated(against: r)
    }
}

// MARK: - Validation: combineWithoutKeepMessage

@Test func combineWithoutKeepMessageRejected() throws {
    let plan = RewritePlan(commits: [step("sha1", .keep), step("sha2", .combine)])
    let r = range(shas: ["sha1", "sha2"])
    #expect(throws: PlanError.combineWithoutKeepMessage("sha2")) {
        try plan.validated(against: r)
    }
}

@Test func combineWithKeepMessageTrueValidates() throws {
    let plan = RewritePlan(commits: [step("sha1", .keep), step("sha2", .combine, keepMessage: true)])
    let r = range(shas: ["sha1", "sha2"])
    let validated = try plan.validated(against: r)
    #expect(validated == plan)
}

@Test func combineWithKeepMessageFalseValidates() throws {
    let plan = RewritePlan(commits: [step("sha1", .keep), step("sha2", .combine, keepMessage: false)])
    let r = range(shas: ["sha1", "sha2"])
    let validated = try plan.validated(against: r)
    #expect(validated == plan)
}

// MARK: - Validation: valid plan passes

@Test func validPlanPassesValidation() throws {
    let plan = RewritePlan(commits: [
        step("sha1", .keep),
        step("sha2", .combine, keepMessage: true),
        step("sha3", .reword, message: "fix: typo"),
        step("sha4", .delete),
    ])
    let r = range(shas: ["sha1", "sha2", "sha3", "sha4"])
    let validated = try plan.validated(against: r)
    #expect(validated == plan)
}

// MARK: - Validation: short-SHA resolution

@Test func shortShaResolvesToFullSha() throws {
    let full = "abc1234567890abcdef1234567890abcdef123456"
    let plan = RewritePlan(commits: [step("abc1234", .keep)])
    let r = range(shas: [full])
    let validated = try plan.validated(against: r)
    #expect(validated.commits[0].sha == full)
}

@Test func fullShaStillValidates() throws {
    let full = "abc1234567890abcdef1234567890abcdef123456"
    let plan = RewritePlan(commits: [step(full, .keep)])
    let r = range(shas: [full])
    let validated = try plan.validated(against: r)
    #expect(validated.commits[0].sha == full)
}

@Test func ambiguousPrefixIsRejected() throws {
    let full1 = "abc1111111111111111111111111111111111111"
    let full2 = "abc2222222222222222222222222222222222222"
    // Both start with "abc" — prefix is ambiguous
    let plan = RewritePlan(commits: [
        step("abc", .keep),
        step(full2, .keep),
    ])
    let r = range(shas: [full1, full2])
    #expect(throws: PlanError.ambiguousPrefix("abc")) {
        try plan.validated(against: r)
    }
}

@Test func unknownPrefixIsShaOutsideRange() throws {
    let full = "abc1234567890abcdef1234567890abcdef123456"
    let plan = RewritePlan(commits: [step("zzz0000", .keep)])
    let r = range(shas: [full])
    #expect(throws: PlanError.shaOutsideRange("zzz0000")) {
        try plan.validated(against: r)
    }
}

@Test func resolvedPlanCarriesFullShasForTodoFile() throws {
    let full1 = "aaa0000000000000000000000000000000000000"
    let full2 = "bbb0000000000000000000000000000000000000"
    let plan = RewritePlan(commits: [
        step("aaa0000", .keep),
        step("bbb0000", .delete),
    ])
    let r = range(shas: [full1, full2])
    let validated = try plan.validated(against: r)
    let todoOutput = TodoFile.render(validated)
    // TodoFile emits "p <sha>" for keep steps; must use full SHA
    #expect(todoOutput.contains(full1))
}

// MARK: - decode: tolerance cases

private let bareJSON = """
{"commits":[{"sha":"abc","action":"keep"}]}
"""

private let fencedJSON = """
```
{"commits":[{"sha":"abc","action":"keep"}]}
```
"""

private let fencedWithLangTag = """
```json
{"commits":[{"sha":"abc","action":"keep"}]}
```
"""

private let preambleThenFenced = """
Here's the rewrite plan I suggest:
```json
{"commits":[{"sha":"abc","action":"keep"}]}
```
"""

@Test func decodeBareJSON() throws {
    let plan = try RewritePlan.decode(bareJSON)
    #expect(plan.commits.count == 1)
    #expect(plan.commits[0].sha == "abc")
}

@Test func decodeFencedJSON() throws {
    let plan = try RewritePlan.decode(fencedJSON)
    #expect(plan.commits[0].sha == "abc")
}

@Test func decodeFencedWithLangTag() throws {
    let plan = try RewritePlan.decode(fencedWithLangTag)
    #expect(plan.commits[0].sha == "abc")
}

@Test func decodePreambleThenFenced() throws {
    let plan = try RewritePlan.decode(preambleThenFenced)
    #expect(plan.commits[0].sha == "abc")
}

@Test func decodeGarbageThrowsNotJSON() throws {
    let raw = "This is definitely not JSON at all!"
    #expect(throws: PlanError.notJSON(raw)) {
        try RewritePlan.decode(raw)
    }
}
