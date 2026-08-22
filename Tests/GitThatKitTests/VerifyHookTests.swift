import Testing
import Foundation
@testable import GitThatKit

// MARK: - VerifyHook tests

@Test func verifyHookNotConfiguredWhenCommandIsNil() throws {
    let repo = RepoFixture()
    let hook = VerifyHook(command: nil, git: repo.git)
    let result = try hook.run()
    #expect(result == .notConfigured)
}

@Test func verifyHookPassesWhenCommandSucceeds() throws {
    let repo = RepoFixture()
    let hook = VerifyHook(command: "true", git: repo.git)
    let result = try hook.run()
    #expect(result == .passed)
}

@Test func verifyHookFailsAndCapturesOutputWhenCommandFails() throws {
    let repo = RepoFixture()
    // Command that prints to stderr and fails
    let hook = VerifyHook(command: "echo 'build failed' >&2; exit 1", git: repo.git)
    let result = try hook.run()
    guard case .failed(let output) = result else {
        Issue.record("expected .failed, got \(result)")
        return
    }
    #expect(output.contains("build failed"))
}

@Test func verifyHookCapturesStdoutOnFailure() throws {
    let repo = RepoFixture()
    let hook = VerifyHook(command: "echo 'test output'; exit 1", git: repo.git)
    let result = try hook.run()
    guard case .failed(let output) = result else {
        Issue.record("expected .failed, got \(result)")
        return
    }
    #expect(output.contains("test output"))
}

@Test func verifyHookPassesForSuccessWithOutput() throws {
    let repo = RepoFixture()
    // A command that prints but exits 0
    let hook = VerifyHook(command: "echo 'ok'", git: repo.git)
    let result = try hook.run()
    #expect(result == .passed)
}

/// RewriteFlow: verify failure is reported but does not roll back (existing test updated to
/// assert output contains the failure command, not just "gitthat undo").
/// The existing test in RewriteFlowTests already covers this — these tests focus on
/// the hook type in isolation.

@Test func verifyResultEquatable() {
    #expect(VerifyResult.notConfigured == .notConfigured)
    #expect(VerifyResult.passed == .passed)
    #expect(VerifyResult.failed(output: "x") == .failed(output: "x"))
    #expect(VerifyResult.failed(output: "x") != .failed(output: "y"))
    #expect(VerifyResult.passed != .notConfigured)
}
