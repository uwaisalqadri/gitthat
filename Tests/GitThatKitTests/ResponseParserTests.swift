import Testing
@testable import GitThatKit

@Test func parsesAPlainSubject() throws {
    let message = try ResponseParser.commitMessage(from: "feat: add token refresh")
    #expect(message.subject == "feat: add token refresh")
    #expect(message.body == nil)
}

@Test func parsesSubjectAndBody() throws {
    let raw = "feat: add token refresh\n\nRefreshes ten seconds before expiry.\nFalls back to a full login."
    let message = try ResponseParser.commitMessage(from: raw)

    #expect(message.subject == "feat: add token refresh")
    #expect(message.body == "Refreshes ten seconds before expiry.\nFalls back to a full login.")
    #expect(message.full == raw)
}

@Test(arguments: [
    "```\nfeat: add token refresh\n```",
    "```text\nfeat: add token refresh\n```",
    "```json\nfeat: add token refresh\n```",
    "  ```\n  feat: add token refresh\n  ```  ",
])
func stripsFences(raw: String) throws {
    let message = try ResponseParser.commitMessage(from: raw)
    #expect(message.subject == "feat: add token refresh")
}

@Test(arguments: [
    "Here's the commit message:\n\nfeat: add token refresh",
    "Here is the commit message:\nfeat: add token refresh",
    "Sure, here's a commit message:\n\nfeat: add token refresh",
    "Certainly! Here is one:\n\nfeat: add token refresh",
])
func stripsConversationalPreamble(raw: String) throws {
    let message = try ResponseParser.commitMessage(from: raw)
    #expect(message.subject == "feat: add token refresh")
}

@Test func keepsAColonSubjectThatIsNotPreamble() throws {
    let message = try ResponseParser.commitMessage(from: "feat: add token refresh")
    #expect(message.subject == "feat: add token refresh")
}

@Test func trimsSurroundingWhitespace() throws {
    let message = try ResponseParser.commitMessage(from: "\n\n  feat: add token refresh  \n\n")
    #expect(message.subject == "feat: add token refresh")
}

@Test(arguments: ["", "   ", "\n\n", "```\n```"])
func rejectsEmptyResponses(raw: String) {
    #expect(throws: ResponseError.empty) {
        try ResponseParser.commitMessage(from: raw)
    }
}

@Test func collapsesExtraBlankLinesBetweenSubjectAndBody() throws {
    let message = try ResponseParser.commitMessage(from: "feat: x\n\n\n\nthe body")
    #expect(message.subject == "feat: x")
    #expect(message.body == "the body")
}

// Step 1 adjudication: preamble regex must NOT eat commit subjects that contain
// a colon but are NOT preamble lines (they don't end with a bare colon).
@Test func preambleDoesNotEatOkColonSubject() throws {
    let message = try ResponseParser.commitMessage(from: "ok: handle the retry")
    #expect(message.subject == "ok: handle the retry")
}

@Test func preambleDoesNotEatSureColonSubject() throws {
    let message = try ResponseParser.commitMessage(from: "sure: fix the thing")
    #expect(message.subject == "sure: fix the thing")
}

@Test func preambleDoesNotEatHeresDealSubject() throws {
    let message = try ResponseParser.commitMessage(from: "here's the deal: it works")
    #expect(message.subject == "here's the deal: it works")
}

// Fix (a): unclosed opening fence — content after the fence should be used.
@Test func unclosedFenceUsesContent() throws {
    let message = try ResponseParser.commitMessage(from: "```\nfeat: fix")
    #expect(message.subject == "feat: fix")
}

// Fix (b): orphan closing fence — trailing fence line with no opener should be stripped.
@Test func orphanClosingFenceIsStripped() throws {
    let message = try ResponseParser.commitMessage(from: "feat: fix\n```")
    #expect(message.subject == "feat: fix")
    #expect(message.body == nil)
}

// Fix (c): indentation inside a fenced block must be preserved.
@Test func fencedBodyPreservesIndentation() throws {
    let raw = "```\nfeat: fix\n\n    indented line\n```"
    let message = try ResponseParser.commitMessage(from: raw)
    #expect(message.subject == "feat: fix")
    #expect(message.body == "    indented line")
}
