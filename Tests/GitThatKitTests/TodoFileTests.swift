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
    // A plain keep → reword → combine(drop) → reword → delete plan.
    // No squash groups; each reword gets a .write entry; no .leave entries.
    let plan = RewritePlan(commits: [
        step("aaa", .keep),
        step("bbb", .reword, message: "fix: first reword"),
        step("ccc", .combine, keepMessage: false),
        step("ddd", .reword, message: "feat: second reword"),
        step("eee", .delete),
    ])
    #expect(TodoFile.messageQueue(plan) == [.write("fix: first reword"), .write("feat: second reword")])
}

@Test func messageQueueEmptyWhenNoEditorSteps() {
    let plan = RewritePlan(commits: [
        step("a", .keep),
        step("b", .combine, keepMessage: false),
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
    #expect(TodoFile.messageQueue(plan) == [.write("valid message")])
}

@Test func messageQueueSquashGroupEmitsOneLeaveThenReword() {
    // p aaa, s bbb, s ccc, r ddd → invocations: LEAVE (squash group), WRITE ddd
    let plan = RewritePlan(commits: [
        step("aaa", .keep),
        step("bbb", .combine, keepMessage: true),
        step("ccc", .combine, keepMessage: true),
        step("ddd", .reword, message: "feat: new message"),
    ])
    #expect(TodoFile.messageQueue(plan) == [.leave, .write("feat: new message")])
}

@Test func messageQueueRewordBeforeAndAfterSquashGroup() {
    // r aaa, s bbb, s ccc, r ddd → invocations: WRITE aaa, LEAVE (group), WRITE ddd
    let plan = RewritePlan(commits: [
        step("aaa", .reword, message: "fix: A"),
        step("bbb", .combine, keepMessage: true),
        step("ccc", .combine, keepMessage: true),
        step("ddd", .reword, message: "feat: D"),
    ])
    #expect(TodoFile.messageQueue(plan) == [.write("fix: A"), .leave, .write("feat: D")])
}

@Test func messageQueueConsecutiveSquashGroupsAreSeparatedByLeaves() {
    // p a, s b, p c, s d — two squash groups, each emits one .leave
    let plan = RewritePlan(commits: [
        step("aaa", .keep),
        step("bbb", .combine, keepMessage: true),
        step("ccc", .keep),
        step("ddd", .combine, keepMessage: true),
    ])
    #expect(TodoFile.messageQueue(plan) == [.leave, .leave])
}

// MARK: - Queue serialisation round-trip

@Test func queueEntriesRoundTripThroughSerialisation() {
    let entries: [TodoFile.QueueEntry] = [
        .write("feat: first"),
        .leave,
        .write("fix: second\nwith body"),
        .leave,
        .write("chore: third"),
    ]
    let data = TodoFile.serialiseQueue(entries)
    let decoded = TodoFile.deserialiseQueue(data)
    #expect(decoded == entries)
}

// MARK: - Finding (1): queue position stability (updated for typed entries)

@Test func messageQueuePositionsMatchTodoFileOrder() {
    // Three reword steps — queue must have exactly three .write entries in order.
    let plan = RewritePlan(commits: [
        step("aaa", .reword, message: "msg one"),
        step("bbb", .keep),
        step("ccc", .reword, message: "msg two"),
        step("ddd", .reword, message: "msg three"),
    ])
    let q = TodoFile.messageQueue(plan)
    #expect(q == [.write("msg one"), .write("msg two"), .write("msg three")])
    // Serialisation round-trip must preserve position.
    #expect(TodoFile.deserialiseQueue(TodoFile.serialiseQueue(q)) == q)
}
