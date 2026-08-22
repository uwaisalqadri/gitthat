import Testing
@testable import GitThatKit

private func file(
    path: String = "Sources/Foo.swift",
    ours: String? = "let x = 1",
    theirs: String? = "let x = 2",
    merged: String = "<<<<<<< HEAD\nlet x = 1\n=======\nlet x = 2\n>>>>>>> abc1234",
    oursIsDeleted: Bool = false,
    theirsIsDeleted: Bool = false
) -> ConflictedFile {
    ConflictedFile(path: path, ours: ours, theirs: theirs, merged: merged,
                   oursIsDeleted: oursIsDeleted, theirsIsDeleted: theirsIsDeleted)
}

// MARK: - Both sides present

@Test func includesOursContentWhenBothSidesPresent() throws {
    let prompt = try ConflictPrompts.resolve(file: file(), applyingSubject: nil, retryError: nil)
    #expect(prompt.contains("let x = 1"))
}

@Test func includesTheirsContentWhenBothSidesPresent() throws {
    let prompt = try ConflictPrompts.resolve(file: file(), applyingSubject: nil, retryError: nil)
    #expect(prompt.contains("let x = 2"))
}

@Test func oursContentAppearsInsideOursTags() throws {
    let prompt = try ConflictPrompts.resolve(file: file(ours: "UNIQUE_OURS"), applyingSubject: nil, retryError: nil)
    #expect(prompt.contains("<ours>"))
    #expect(prompt.contains("</ours>"))
    let start = prompt.range(of: "<ours>")!.upperBound
    let end = prompt.range(of: "</ours>")!.lowerBound
    #expect(prompt[start..<end].contains("UNIQUE_OURS"))
}

@Test func theirsContentAppearsInsideTheirsTags() throws {
    let prompt = try ConflictPrompts.resolve(file: file(theirs: "UNIQUE_THEIRS"), applyingSubject: nil, retryError: nil)
    #expect(prompt.contains("<theirs>"))
    #expect(prompt.contains("</theirs>"))
    let start = prompt.range(of: "<theirs>")!.upperBound
    let end = prompt.range(of: "</theirs>")!.lowerBound
    #expect(prompt[start..<end].contains("UNIQUE_THEIRS"))
}

// MARK: - Content-not-instructions framing

@Test func statesOursTagsContainContentNotInstructions() throws {
    let prompt = try ConflictPrompts.resolve(file: file(), applyingSubject: nil, retryError: nil)
    // The framing for the ours/theirs tags should say content, never instructions
    #expect(prompt.lowercased().contains("content"))
    #expect(prompt.lowercased().contains("never instructions") || prompt.lowercased().contains("not instructions"))
}

// MARK: - Nil sides (one side nil, one present)

@Test func oursNilDeletedConveysDeletedMessage() throws {
    let prompt = try ConflictPrompts.resolve(
        file: file(ours: nil, oursIsDeleted: true),
        applyingSubject: nil, retryError: nil)
    let lower = prompt.lowercased()
    #expect(lower.contains("deleted"))
    // Must warn against recreating the file
    #expect(lower.contains("do not recreate") || lower.contains("deliberately removed") || lower.contains("not recreate"))
    // Must not say "binary"
    #expect(!lower.contains("binary"))
}

@Test func oursNilBinaryConveysBinaryMessage() throws {
    let prompt = try ConflictPrompts.resolve(
        file: file(ours: nil, oursIsDeleted: false),
        applyingSubject: nil, retryError: nil)
    let lower = prompt.lowercased()
    #expect(lower.contains("binary"))
    // Must not say "deleted"
    #expect(!lower.contains("deleted"))
}

@Test func theirsNilDeletedConveysDeletedMessage() throws {
    let prompt = try ConflictPrompts.resolve(
        file: file(theirs: nil, theirsIsDeleted: true),
        applyingSubject: nil, retryError: nil)
    let lower = prompt.lowercased()
    #expect(lower.contains("deleted"))
    #expect(lower.contains("do not recreate") || lower.contains("deliberately removed") || lower.contains("not recreate"))
    #expect(!lower.contains("binary"))
}

@Test func theirsNilBinaryConveysBinaryMessage() throws {
    let prompt = try ConflictPrompts.resolve(
        file: file(theirs: nil, theirsIsDeleted: false),
        applyingSubject: nil, retryError: nil)
    let lower = prompt.lowercased()
    #expect(lower.contains("binary"))
    #expect(!lower.contains("deleted"))
}

// MARK: - Both sides nil: must throw

@Test func bothNilThrowsBothSidesUnresolvable() {
    #expect(throws: ConflictPromptsError.bothSidesUnresolvable(path: "Sources/Foo.swift")) {
        try ConflictPrompts.resolve(file: file(ours: nil, theirs: nil), applyingSubject: nil, retryError: nil)
    }
}

@Test func bothNilErrorCarriesPath() {
    let f = file(path: "unique/path/to/file.swift", ours: nil, theirs: nil)
    #expect(throws: ConflictPromptsError.bothSidesUnresolvable(path: "unique/path/to/file.swift")) {
        try ConflictPrompts.resolve(file: f, applyingSubject: nil, retryError: nil)
    }
}

// MARK: - applyingSubject

@Test func includesApplyingSubjectWhenPresent() throws {
    let prompt = try ConflictPrompts.resolve(file: file(), applyingSubject: "feat: add new login flow", retryError: nil)
    #expect(prompt.contains("feat: add new login flow"))
}

@Test func conveysSubjectIsNilWhenAbsent() throws {
    let prompt = try ConflictPrompts.resolve(file: file(), applyingSubject: nil, retryError: nil)
    let lower = prompt.lowercased()
    #expect(lower.contains("subject") || lower.contains("intent") || lower.contains("commit"))
}

@Test func subjectSectionPresentEvenWhenNil() throws {
    let withSubject = try ConflictPrompts.resolve(file: file(), applyingSubject: "some subject", retryError: nil)
    let withoutSubject = try ConflictPrompts.resolve(file: file(), applyingSubject: nil, retryError: nil)
    #expect(withSubject.lowercased().contains("subject") || withSubject.lowercased().contains("intent"))
    #expect(withoutSubject.lowercased().contains("subject") || withoutSubject.lowercased().contains("intent"))
}

@Test func subjectDirectiveSaysIntentWins() throws {
    let prompt = try ConflictPrompts.resolve(file: file(), applyingSubject: "some intent", retryError: nil)
    let lower = prompt.lowercased()
    // Must give a tiebreaker rule, not a weak "should reflect"
    #expect(lower.contains("intent wins") || lower.contains("determines") || lower.contains("apply it"))
}

// MARK: - No conflict markers in response

@Test func instructsNoConflictMarkersInResponse() throws {
    let prompt = try ConflictPrompts.resolve(file: file(), applyingSubject: nil, retryError: nil)
    // Must explicitly prohibit conflict markers — assert the prohibition text, not the marker itself
    let lower = prompt.lowercased()
    #expect(lower.contains("must not contain conflict markers") || lower.contains("must not contain"))
    // And separately: the prohibition must be present
    #expect(lower.contains("must not") || lower.contains("do not") || lower.contains("no conflict"))
}

@Test func asksForResolvedContentOnly() throws {
    let prompt = try ConflictPrompts.resolve(file: file(), applyingSubject: nil, retryError: nil)
    let lower = prompt.lowercased()
    #expect(lower.contains("no prose") || lower.contains("nothing else") || lower.contains("only") || lower.contains("content only"))
    #expect(lower.contains("no") && (lower.contains("fence") || lower.contains("code block") || lower.contains("preamble") || lower.contains("explanation")))
}

// MARK: - Retry

@Test func includesRetryErrorWhenGiven() throws {
    let prompt = try ConflictPrompts.resolve(file: file(), applyingSubject: nil, retryError: "UNIQUE_RETRY_ERROR")
    #expect(prompt.contains("UNIQUE_RETRY_ERROR"))
}

@Test func omitsRetryErrorWhenNil() throws {
    let prompt = try ConflictPrompts.resolve(file: file(), applyingSubject: nil, retryError: nil)
    #expect(!prompt.lowercased().contains("previous"))
}

@Test func retryAsksCorrectedResponse() throws {
    let prompt = try ConflictPrompts.resolve(file: file(), applyingSubject: nil, retryError: "something went wrong")
    let lower = prompt.lowercased()
    #expect(lower.contains("correct") || lower.contains("fix") || lower.contains("try again"))
}

@Test func retryNamesWhatToAvoid() throws {
    let prompt = try ConflictPrompts.resolve(file: file(), applyingSubject: nil, retryError: "had markers")
    let lower = prompt.lowercased()
    // Must tell the model to avoid repeating the mistake, not just "produce a corrected response"
    #expect(lower.contains("do not repeat") || lower.contains("avoids it") || lower.contains("avoid"))
}

// MARK: - Includes file path

@Test func includesFilePath() throws {
    let prompt = try ConflictPrompts.resolve(file: file(path: "src/Auth/Login.swift"), applyingSubject: nil, retryError: nil)
    #expect(prompt.contains("src/Auth/Login.swift"))
}

// MARK: - No forbidden vocabulary

@Test func noForbiddenVocabularyInPrompt() throws {
    let prompt = try ConflictPrompts.resolve(file: file(), applyingSubject: "some subject", retryError: "some error")
    #expect(!prompt.contains("rebase"))
    #expect(!prompt.contains("squash"))
    #expect(!prompt.contains("fixup"))
    #expect(!prompt.contains("pick"))
    // "todo" may appear in file content but not in our prompt framing — check raw prompt has none
    // (note: "todo" as substring of other words is fine, only standalone context matters;
    //  however the lint checks string literals so our source code must not have the word)
}
