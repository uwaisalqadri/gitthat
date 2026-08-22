import Foundation
import Testing
@testable import GitThatKit

// MARK: - Fixtures

private let simpleFile = ConflictedFile(
    path: "src/Auth/TokenStore.swift",
    ours: "func refresh() {\n    return old\n}",
    theirs: "func refresh() {\n    return new\n}",
    merged: "<<<<<<< HEAD\nfunc refresh() {\n    return old\n}\n=======\nfunc refresh() {\n    return new\n}\n>>>>>>> fix-token"
)

private let nilOursFile = ConflictedFile(
    path: "src/Auth/Legacy.swift",
    ours: nil,
    theirs: "func legacy() {}",
    merged: "<<<<<<< HEAD\n=======\nfunc legacy() {}\n>>>>>>> add-legacy"
)

private let nilTheirsFile = ConflictedFile(
    path: "src/Auth/Old.swift",
    ours: "func old() {}",
    theirs: nil,
    merged: "<<<<<<< HEAD\nfunc old() {}\n=======\n>>>>>>> remove-old"
)

private let longLineFile = ConflictedFile(
    path: "src/Util/Names.swift",
    ours:   String(repeating: "x", count: 120),
    theirs: String(repeating: "y", count: 120),
    merged: ""
)

private let largeFile: ConflictedFile = {
    let side: String = (1...50).map { "line \($0)" }.joined(separator: "\n")
    return ConflictedFile(path: "Big.swift", ours: side, theirs: side, merged: "")
}()

// MARK: - Header and progress

@Test func conflictRenderShowsPath() {
    let out = ConflictRender.file(simpleFile, proposal: nil, index: 0, total: 1)
    #expect(out.contains("src/Auth/TokenStore.swift"))
}

@Test func conflictRenderShowsProgressSingleFile() {
    let out = ConflictRender.file(simpleFile, proposal: nil, index: 0, total: 1)
    // "file 1 of 1" or similar — just check both numbers appear near each other
    #expect(out.contains("1 of 1"))
}

@Test func conflictRenderShowsProgressMultipleFiles() {
    let out = ConflictRender.file(simpleFile, proposal: nil, index: 1, total: 5)
    #expect(out.contains("2 of 5"))
}

// MARK: - Two-sided content

@Test func conflictRenderShowsOursContent() {
    let out = ConflictRender.file(simpleFile, proposal: nil, index: 0, total: 1)
    #expect(out.contains("return old"))
}

@Test func conflictRenderShowsTheirsContent() {
    let out = ConflictRender.file(simpleFile, proposal: nil, index: 0, total: 1)
    #expect(out.contains("return new"))
}

@Test func conflictRenderShowsColumnHeaders() {
    let out = ConflictRender.file(simpleFile, proposal: nil, index: 0, total: 1)
    let lower = out.lowercased()
    #expect(lower.contains("ours"))
    #expect(lower.contains("theirs"))
}

// MARK: - Proposal

@Test func conflictRenderNoProposalOmitsResolutionSection() {
    let out = ConflictRender.file(simpleFile, proposal: nil, index: 0, total: 1)
    let lower = out.lowercased()
    #expect(!lower.contains("proposed resolution"))
}

@Test func conflictRenderWithProposalShowsResolutionHeader() {
    let out = ConflictRender.file(simpleFile, proposal: "func refresh() {\n    return merged\n}", index: 0, total: 1)
    let lower = out.lowercased()
    #expect(lower.contains("proposed resolution"))
}

@Test func conflictRenderWithProposalShowsResolutionContent() {
    let out = ConflictRender.file(simpleFile, proposal: "func refresh() {\n    return merged\n}", index: 0, total: 1)
    #expect(out.contains("return merged"))
}

// MARK: - Nil sides

@Test func conflictRenderNilOursShowsDeletedLabel() {
    let out = ConflictRender.file(nilOursFile, proposal: nil, index: 0, total: 1)
    let lower = out.lowercased()
    #expect(lower.contains("deleted"))
}

@Test func conflictRenderNilOursShowsTheirsContent() {
    let out = ConflictRender.file(nilOursFile, proposal: nil, index: 0, total: 1)
    #expect(out.contains("func legacy()"))
}

@Test func conflictRenderNilTheirsShowsDeletedLabel() {
    let out = ConflictRender.file(nilTheirsFile, proposal: nil, index: 0, total: 1)
    let lower = out.lowercased()
    #expect(lower.contains("deleted"))
}

@Test func conflictRenderNilTheirsShowsOursContent() {
    let out = ConflictRender.file(nilTheirsFile, proposal: nil, index: 0, total: 1)
    #expect(out.contains("func old()"))
}

// MARK: - Long lines (stacked fallback)

@Test func conflictRenderLongLineDoesNotCrash() {
    let out = ConflictRender.file(longLineFile, proposal: nil, index: 0, total: 1)
    // Just verify it renders something meaningful
    #expect(out.contains("src/Util/Names.swift"))
    #expect(out.contains("ours") || out.lowercased().contains("ours"))
}

@Test func conflictRenderLongLineShowsBothSides() {
    let out = ConflictRender.file(longLineFile, proposal: nil, index: 0, total: 1)
    #expect(out.contains(String(repeating: "x", count: 10)))
    #expect(out.contains(String(repeating: "y", count: 10)))
}

// MARK: - Large conflicts (truncation)

@Test func conflictRenderLargeFileShowsTruncationNotice() {
    let out = ConflictRender.file(largeFile, proposal: nil, index: 0, total: 1)
    // Should mention that lines were omitted
    let lower = out.lowercased()
    #expect(lower.contains("omitted") || lower.contains("more line") || lower.contains("truncated"))
}

@Test func conflictRenderLargeFileDoesNotShowAllLines() {
    let out = ConflictRender.file(largeFile, proposal: nil, index: 0, total: 1)
    // 50 lines — should not show "line 50"
    #expect(!out.contains("line 50"))
}

// MARK: - Action hints

@Test func conflictRenderShowsActionHints() {
    let out = ConflictRender.file(simpleFile, proposal: "resolved", index: 0, total: 1)
    let lower = out.lowercased()
    #expect(lower.contains("[a]"))
    #expect(lower.contains("[e]"))
    #expect(lower.contains("[s]"))
}

// MARK: - Vocabulary lint

@Test func conflictRenderContainsNoForbiddenWords() {
    let out = ConflictRender.file(simpleFile, proposal: "resolved", index: 0, total: 3).lowercased()
    for word in ["rebase", "squash", "fixup", "pick", "todo"] {
        #expect(!out.contains(word), "ConflictRender output contains forbidden word '\(word)'")
    }
}
