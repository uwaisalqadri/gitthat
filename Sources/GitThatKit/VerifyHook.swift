import Foundation

public enum VerifyResult: Sendable, Equatable {
    case notConfigured
    case passed
    case failed(output: String)
}

/// Runs the configured `[rewrite] verify` command after a completed rewrite.
///
/// Never rolls back. Never throws (command failures become `.failed`).
/// The user decides what to do with a failing verify command.
public struct VerifyHook: Sendable {
    private let command: String?
    private let git: Git

    public init(command: String?, git: Git) {
        self.command = command
        self.git = git
    }

    public func run() throws -> VerifyResult {
        guard let command, !command.isEmpty else { return .notConfigured }
        let (exitCode, output) = git.shellWithOutput(command)
        return exitCode == 0 ? .passed : .failed(output: output)
    }
}
