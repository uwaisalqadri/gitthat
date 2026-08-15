import Testing
@testable import GitThatKit

private func step(_ sha: String, _ action: RewriteAction, keepMessage: Bool? = nil, message: String? = nil) -> RewriteStep {
    RewriteStep(sha: sha, action: action, keepMessage: keepMessage, message: message)
}

// MARK: - render(_:)

@Test func todoRenderKeep() {
    let plan = RewritePlan(commits: [step("abc1234", .keep)])
    #expect(TodoFile.render(plan) == "p abc1234")
}

@Test func todoRenderReword() {
    let plan = RewritePlan(commits: [step("abc1234", .reword, message: "fix: typo")])
    #expect(TodoFile.render(plan) == "r abc1234")
}

@Test func todoRenderCombineKeepMessage() {
    let plan = RewritePlan(commits: [step("abc1234", .combine, keepMessage: true)])
    #expect(TodoFile.render(plan) == "s abc1234")
}

@Test func todoRenderCombineDropMessage() {
    let plan = RewritePlan(commits: [step("abc1234", .combine, keepMessage: false)])
    #expect(TodoFile.render(plan) == "f abc1234")
}

@Test func todoRenderCombineNilKeepMessageRendersAsDiscard() {
    // nil keepMessage is now a validation error (combineWithoutKeepMessage).
    // An unvalidated plan that bypasses validated(against:) still renders
    // safely as "f" (discard) without trapping.
    let plan = RewritePlan(commits: [step("abc1234", .combine)])
    #expect(TodoFile.render(plan) == "f abc1234")
}

@Test func todoRenderDeleteOmitsLine() {
    let plan = RewritePlan(commits: [step("abc1234", .delete)])
    #expect(TodoFile.render(plan) == "")
}

@Test func todoRenderOrderPreserved() {
    let plan = RewritePlan(commits: [
        step("aaa", .keep),
        step("bbb", .reword, message: "fix: b"),
        step("ccc", .combine, keepMessage: true),
        step("ddd", .delete),
        step("eee", .combine, keepMessage: false),
    ])
    let expected = """
    p aaa
    r bbb
    s ccc
    f eee
    """
    #expect(TodoFile.render(plan) == expected)
}

@Test func todoRenderAllKeep() {
    let plan = RewritePlan(commits: [
        step("a1", .keep),
        step("b2", .keep),
        step("c3", .keep),
    ])
    let expected = "p a1\np b2\np c3"
    #expect(TodoFile.render(plan) == expected)
}

// MARK: - messageQueue(_:)

@Test func messageQueueReturnsRewordMessagesInOrder() {
    let plan = RewritePlan(commits: [
        step("aaa", .keep),
        step("bbb", .reword, message: "fix: first reword"),
        step("ccc", .combine, keepMessage: true),
        step("ddd", .reword, message: "feat: second reword"),
        step("eee", .delete),
    ])
    #expect(TodoFile.messageQueue(plan) == ["fix: first reword", "feat: second reword"])
}

@Test func messageQueueEmptyWhenNoRewordSteps() {
    let plan = RewritePlan(commits: [
        step("a", .keep),
        step("b", .combine),
        step("c", .delete),
    ])
    #expect(TodoFile.messageQueue(plan).isEmpty)
}

@Test func messageQueueSkipsNilMessages() {
    // A reword step with a nil message (invalid, but defensively handled)
    // should be excluded from the queue rather than inserting nil/empty.
    let plan = RewritePlan(commits: [
        step("aaa", .reword, message: "valid message"),
        step("bbb", .reword),  // no message — invalid plan but queue must not crash
    ])
    #expect(TodoFile.messageQueue(plan) == ["valid message"])
}

// MARK: - Finding (1): queue position stability

/// A queue that contains NUL-delimited entries must preserve ALL entries including
/// any that are empty strings, so that position in the queue matches position in the
/// todo file. The validated plan never produces empty messages (rewordWithoutMessage
/// guards upstream), so the queue from a validated plan has no empty entries.
@Test func messageQueuePositionsMatchTodoFileOrder() {
    // Three reword steps — queue must have exactly three entries in todo-file order.
    let plan = RewritePlan(commits: [
        step("aaa", .reword, message: "msg one"),
        step("bbb", .keep),
        step("ccc", .reword, message: "msg two"),
        step("ddd", .reword, message: "msg three"),
    ])
    let q = TodoFile.messageQueue(plan)
    #expect(q == ["msg one", "msg two", "msg three"])
    // The NUL-joined string must round-trip without losing positional information.
    let joined = q.joined(separator: "\0")
    let parts = joined.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    #expect(parts == q)
}
