import Testing
@testable import GitThatKit

@Test(arguments: [
    "feat: add token refresh",
    "fix(auth): handle expiry",
    "chore!: drop support for macOS 12",
    "refactor(core): split TokenStore",
    "docs: rewrite the readme",
])
func recognisesConventionalSubjects(subject: String) {
    #expect(StyleInference.isConventional(subject))
}

@Test(arguments: [
    "add token refresh",
    "Fixed the auth bug",
    "feat add token refresh",     // no colon
    "feat:no space after colon",
    "FEAT: uppercase type",
    "feat():empty scope",
    "",
])
func rejectsNonConventionalSubjects(subject: String) {
    #expect(!StyleInference.isConventional(subject))
}

private func subjects(conventional: Int, plain: Int) -> [String] {
    Array(repeating: "feat: a change", count: conventional)
        + Array(repeating: "a change", count: plain)
}

@Test func infersConventionalAtSeventyPercent() {
    #expect(StyleInference.infer(from: subjects(conventional: 7, plain: 3)) == .conventional)
}

@Test func infersConventionalAboveSeventyPercent() {
    #expect(StyleInference.infer(from: subjects(conventional: 71, plain: 29)) == .conventional)
}

@Test func isAmbiguousJustBelowSeventyPercent() {
    #expect(StyleInference.infer(from: subjects(conventional: 69, plain: 31)) == nil)
}

@Test func infersPlainAtThirtyPercent() {
    #expect(StyleInference.infer(from: subjects(conventional: 3, plain: 7)) == .plain)
}

@Test func isAmbiguousInTheMiddle() {
    #expect(StyleInference.infer(from: subjects(conventional: 5, plain: 5)) == nil)
}

@Test func isAmbiguousWithFewerThanFiveSubjects() {
    #expect(StyleInference.infer(from: subjects(conventional: 4, plain: 0)) == nil)
}

@Test func isAmbiguousWithNoSubjects() {
    #expect(StyleInference.infer(from: []) == nil)
}

@Test func infersConventionalWhenEverythingIsConventional() {
    #expect(StyleInference.infer(from: subjects(conventional: 20, plain: 0)) == .conventional)
}

@Test func infersPlainWhenNothingIsConventional() {
    #expect(StyleInference.infer(from: subjects(conventional: 0, plain: 20)) == .plain)
}
