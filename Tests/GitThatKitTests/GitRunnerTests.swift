import Foundation
import Testing
@testable import GitThatKit

@Test func runnerInitialisesARepository() throws {
    try withTempDirectory { directory in
        let runner = SystemGitRunner(environmentOverrides: isolatedGitEnvironment)

        let initResult = try runner.run(["init", "-q", "-b", "main"], in: directory, stdin: nil)
        #expect(initResult.succeeded)

        let check = try runner.run(["rev-parse", "--is-inside-work-tree"], in: directory, stdin: nil)
        #expect(check.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true")
    }
}

@Test func runnerReportsFailureWithoutThrowing() throws {
    try withTempDirectory { directory in
        let runner = SystemGitRunner(environmentOverrides: isolatedGitEnvironment)
        let result = try runner.run(["status"], in: directory, stdin: nil)

        #expect(!result.succeeded)
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("not a git repository"))
    }
}

@Test func runnerPassesStdinThrough() throws {
    try withTempDirectory { directory in
        let runner = SystemGitRunner(environmentOverrides: isolatedGitEnvironment)
        _ = try runner.run(["init", "-q", "-b", "main"], in: directory, stdin: nil)

        let result = try runner.run(["hash-object", "-w", "--stdin"],
                                    in: directory, stdin: "hello gitthat\n")
        #expect(result.succeeded)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).count == 40)
    }
}

@Test func runnerHandlesOutputLargerThanAPipeBuffer() throws {
    try withTempDirectory { directory in
        let runner = SystemGitRunner(environmentOverrides: isolatedGitEnvironment)
        _ = try runner.run(["init", "-q", "-b", "main"], in: directory, stdin: nil)

        // 2MB of content — far beyond the 64KB pipe buffer that naive
        // implementations deadlock on.
        let big = String(repeating: "gitthat line of text\n", count: 100_000)
        try big.write(to: directory.appendingPathComponent("big.txt"),
                      atomically: true, encoding: .utf8)
        _ = try runner.run(["add", "-A"], in: directory, stdin: nil)

        let result = try runner.run(["diff", "--cached"], in: directory, stdin: nil)
        #expect(result.succeeded)
        #expect(result.stdout.count > 1_000_000)
    }
}
