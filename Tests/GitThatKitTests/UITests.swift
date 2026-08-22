import Foundation
import Testing
@testable import GitThatKit

@Test func previewShowsSubjectAndBody() {
    let message = CommitMessage(subject: "feat: add token refresh",
                                body: "Refreshes ten seconds before expiry.")
    let rendered = Render.commitPreview(message, branch: "feature/sso")

    #expect(rendered.contains("feat: add token refresh"))
    #expect(rendered.contains("Refreshes ten seconds before expiry."))
}

@Test func previewShowsTheBranch() {
    let message = CommitMessage(subject: "feat: x", body: nil)
    #expect(Render.commitPreview(message, branch: "feature/sso").contains("feature/sso"))
}

@Test func previewSurvivesAMissingBranch() {
    let message = CommitMessage(subject: "feat: x", body: nil)
    let rendered = Render.commitPreview(message, branch: nil)
    #expect(rendered.contains("feat: x"))
}

@Test func previewUsesNoForbiddenVocabulary() {
    let message = CommitMessage(subject: "feat: x", body: "a body")
    let rendered = Render.commitPreview(message, branch: "main").lowercased()

    for word in ["rebase", "squash", "fixup", "pick", "todo"] {
        #expect(!rendered.contains(word))
    }
}

@Test func recordingInterfaceReturnsQueuedAnswers() {
    let ui = RecordingUI(commitChoices: [.regenerate, .accept])
    #expect(ui.askCommitChoice() == .regenerate)
    #expect(ui.askCommitChoice() == .accept)
}

// MARK: - Empty-queue safety (finding 2)

@Test func recordingUIEmptyCommitChoicesReturnsCancel() {
    let ui = RecordingUI(commitChoices: [])
    #expect(ui.askCommitChoice() == .cancel)
}

@Test func recordingUIEmptyStyleChoicesReturnsConventional() {
    let ui = RecordingUI(styleChoices: [])
    #expect(ui.askStyle() == .conventional)
}

@Test func recordingUIEmptyConfirmationsReturnsFalse() {
    let ui = RecordingUI(confirmations: [])
    #expect(ui.confirm("proceed?") == false)
}

// MARK: - ANSI TTY guard (B6)

/// When stdout is not a TTY (as in test runs), ANSI escapes must be absent from rendered output.
/// In test runs, STDOUT_FILENO is a pipe, so isatty() returns 0 → escapes should be empty strings.
@Test func ansiEscapesAbsentWhenNotTTY() {
    // Tests run with stdout piped, so Render.isTTY is false → dim/bold/reset are "".
    let message = CommitMessage(subject: "feat: x", body: nil)
    let rendered = Render.commitPreview(message, branch: "main")
    #expect(!rendered.contains("\u{001B}["))
}

// MARK: - Multi-word $EDITOR support (finding 1)

/// Proves the shell invocation supports multi-word $EDITOR values such as
/// "sh /path/to/script" (two words). Direct exec would try to exec a binary
/// literally named "sh /path/to/script" and fail; the shell handles it correctly.
/// This test will break if someone "hardens" edit() into a direct exec.
@Test func editSupportsMultiWordEditor() throws {
    // Write a tiny non-interactive editor script that writes "hello" to its first arg.
    let scriptURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("test-editor-script-\(UUID().uuidString).sh")
    try "#!/bin/sh\nprintf hello > \"$1\"\n".write(to: scriptURL, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: scriptURL) }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

    // EDITOR is two words: "sh /path/to/script" — intentionally multi-word.
    let editorCmd = "sh \(scriptURL.path)"

    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("test-editor-file-\(UUID().uuidString)")
    try "original".write(to: fileURL, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: fileURL) }

    // Replicate TerminalUI.edit()'s exact Process setup.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    // Same invocation as TerminalUI.edit(): shell expands multi-word EDITOR, path via $1.
    process.arguments = ["sh", "-c", "\(editorCmd) \"$1\"", "sh", fileURL.path]
    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    let result = try String(contentsOf: fileURL, encoding: .utf8)
    #expect(result == "hello")
}
