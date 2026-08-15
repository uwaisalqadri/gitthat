import Testing
@testable import GitThatKit

@Test(arguments: [
    // input, expected
    ("feat(a-feature): WIP working on DNS improvement ASAP",
     "feat(a-feature): WIP working on DNS improvement ASAP"),
    ("feat(a-feature): WIP Working on DNS Improvement ASAP",
     "feat(a-feature): WIP working on DNS improvement ASAP"),
    ("Add token refresh", "add token refresh"),
    ("add token refresh", "add token refresh"),
    ("Fix DNS lookup", "fix DNS lookup"),
    ("feat: Add support for iOS", "feat: add support for iOS"),
    ("fix: handle GitHub rate limits", "fix: handle GitHub rate limits"),
    ("fix: guard refreshToken against nil", "fix: guard refreshToken against nil"),
    ("refactor: split TokenStore", "refactor: split TokenStore"),
    ("chore: bump API version", "chore: bump API version"),
    ("Well-Known endpoints", "well-known endpoints"),
    ("Add a trailing period.", "add a trailing period."),
    ("I fixed it", "I fixed it"),
])
func enforcesCasing(input: String, expected: String) {
    #expect(SubjectCase.enforce(input, setting: .lower) == expected)
}

@Test(arguments: [
    "feat: touch Sources/GitThatKit/Git.swift",
    "fix: update Package.swift",
    "docs: rewrite README.md",
    "chore: rename Foo_Bar to baz",
])
func leavesIdentifiersAndPathsAlone(subject: String) {
    #expect(SubjectCase.enforce(subject, setting: .lower) == subject)
}

@Test func preserveDisablesEnforcement() {
    let subject = "Add Token Refresh"
    #expect(SubjectCase.enforce(subject, setting: .preserve) == subject)
}

@Test(arguments: ["", " ", "A", "I", "DNS", "iOS"])
func handlesDegenerateInputWithoutChanging(subject: String) {
    #expect(SubjectCase.enforce(subject, setting: .lower) == subject)
}

@Test func reportsViolationsWithoutFixingThem() {
    #expect(SubjectCase.violates("Add token refresh"))
    #expect(!SubjectCase.violates("add token refresh"))
    #expect(!SubjectCase.violates("fix DNS lookup"))
}
