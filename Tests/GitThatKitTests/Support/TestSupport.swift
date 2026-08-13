import Foundation
@testable import GitThatKit

/// Creates an empty temp directory and removes it when the test ends.
func withTempDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gitthat-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

/// Environment that isolates git from the developer's machine.
let isolatedGitEnvironment: [String: String] = [
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_SYSTEM": "/dev/null",
    "GIT_AUTHOR_NAME": "gitthat test",
    "GIT_AUTHOR_EMAIL": "test@example.invalid",
    "GIT_COMMITTER_NAME": "gitthat test",
    "GIT_COMMITTER_EMAIL": "test@example.invalid",
]
