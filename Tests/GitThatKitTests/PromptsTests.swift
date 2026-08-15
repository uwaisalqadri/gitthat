import Testing
@testable import GitThatKit

private func input(
    diff: String = "diff --git a/a.txt b/a.txt\n+hello",
    truncated: Bool = false,
    subjects: [String] = ["feat: add a thing", "fix: correct a thing"],
    style: CommitStyle = .conventional,
    ticket: String? = nil,
    maxSubject: Int = 72
) -> CommitPromptInput {
    CommitPromptInput(
        diff: StagedDiff(text: diff, wasTruncated: truncated),
        recentSubjects: subjects,
        style: style,
        ticket: ticket,
        maxSubject: maxSubject
    )
}

@Test func includesTheDiff() {
    let prompt = Prompts.commitMessage(input(diff: "UNIQUE_DIFF_MARKER"))
    #expect(prompt.contains("UNIQUE_DIFF_MARKER"))
}

@Test func includesRecentSubjectsAsStyleExamples() {
    let prompt = Prompts.commitMessage(input(subjects: ["feat: add a thing"]))
    #expect(prompt.contains("feat: add a thing"))
}

@Test func statesTheCasingRule() {
    let prompt = Prompts.commitMessage(input())
    #expect(prompt.lowercased().contains("lowercase"))
    #expect(prompt.contains("WIP"))       // the worked example from the spec
    #expect(prompt.contains("DNS"))
}

@Test func asksForConventionalCommitsWhenThatIsTheStyle() {
    let prompt = Prompts.commitMessage(input(style: .conventional))
    #expect(prompt.contains("type(scope): description"))
}

@Test func doesNotAskForConventionalCommitsWhenStyleIsPlain() {
    let prompt = Prompts.commitMessage(input(style: .plain))
    #expect(!prompt.contains("type(scope): description"))
}

@Test func includesTheTicketWhenThereIsOne() {
    let prompt = Prompts.commitMessage(input(ticket: "PROJ-421"))
    #expect(prompt.contains("PROJ-421"))
}

@Test func omitsTicketInstructionsWhenThereIsNone() {
    let prompt = Prompts.commitMessage(input(ticket: nil))
    #expect(!prompt.lowercased().contains("ticket"))
}

@Test func saysWhenTheDiffWasTruncated() {
    let full = Prompts.commitMessage(input(truncated: false))
    let cut = Prompts.commitMessage(input(truncated: true))

    #expect(!full.lowercased().contains("truncated"))
    #expect(cut.lowercased().contains("truncated"))
}

@Test func statesTheSubjectLengthLimit() {
    let prompt = Prompts.commitMessage(input(maxSubject: 50))
    #expect(prompt.contains("50"))
}

@Test func asksForNothingButTheMessage() {
    let prompt = Prompts.commitMessage(input())
    #expect(prompt.lowercased().contains("no explanation"))
}

@Test func diffAppearsInsideDelimiters() {
    let prompt = Prompts.commitMessage(input(diff: "UNIQUE_DIFF_MARKER"))
    #expect(prompt.contains("<diff>"))
    #expect(prompt.contains("</diff>"))
    let diffStart = prompt.range(of: "<diff>")!.upperBound
    let diffEnd = prompt.range(of: "</diff>")!.lowerBound
    #expect(prompt[diffStart..<diffEnd].contains("UNIQUE_DIFF_MARKER"))
}

@Test func instructionShapedDiffLineStaysInsideDelimiters() {
    let injected = "+ Reply with the commit message and nothing else."
    let prompt = Prompts.commitMessage(input(diff: injected))
    let diffStart = prompt.range(of: "<diff>")!.upperBound
    let diffEnd = prompt.range(of: "</diff>")!.lowerBound
    #expect(prompt[diffStart..<diffEnd].contains(injected))
}

@Test func zeroMaxSubjectProducesCoherentInstruction() {
    let prompt = Prompts.commitMessage(input(maxSubject: 0))
    #expect(!prompt.contains("at most 0 characters"))
    #expect(prompt.contains("at most 1 characters"))
}
