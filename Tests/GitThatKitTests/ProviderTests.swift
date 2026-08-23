import Foundation
import Testing
@testable import GitThatKit

// All ProviderTests run serially to avoid cooperative-scheduler starvation when the
// permutation tier saturates the CPU with concurrent git rebases. `.serialized` means
// each test here waits for the previous one to finish, keeping async task pressure low.
@Suite(.serialized)
struct ProviderTests {

    @Test func runsACommandAndReturnsItsOutput() async throws {
        let provider = CLIProvider(command: ["cat"], timeout: .seconds(5))
        let output = try await provider.complete("feat: add token refresh")
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "feat: add token refresh")
    }

    @Test func passesExtraArgumentsToTheCommand() async throws {
        let provider = CLIProvider(command: ["sed", "s/foo/bar/"], timeout: .seconds(5))
        let output = try await provider.complete("foo")
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "bar")
    }

    @Test func reportsAMissingCommand() async {
        let provider = CLIProvider(command: ["gitthat-does-not-exist"], timeout: .seconds(5))
        await #expect(throws: ProviderError.notFound(command: "gitthat-does-not-exist")) {
            try await provider.complete("anything")
        }
    }

    @Test func reportsANonZeroExit() async throws {
        let provider = CLIProvider(command: ["sh", "-c", "echo trouble >&2; exit 3"],
                                   timeout: .seconds(5))
        do {
            _ = try await provider.complete("anything")
            Issue.record("expected a failure")
        } catch let error as ProviderError {
            guard case .failed(let code, let stderr) = error else {
                Issue.record("expected .failed, got \(error)")
                return
            }
            #expect(code == 3)
            #expect(stderr.contains("trouble"))
        }
    }

    @Test func reportsEmptyOutput() async {
        let provider = CLIProvider(command: ["true"], timeout: .seconds(5))
        await #expect(throws: ProviderError.empty) {
            try await provider.complete("anything")
        }
    }

    // Timing-sensitive tests run serially (inherited from parent suite) to avoid
    // flaking under parallel-rebase CPU saturation.
    // The bounds are generous enough to survive heavy load but still prove the property:
    // - timeout test: sleep 30s is killed; proving it finishes in < 20s is sufficient.
    // - SIGTERM test: sleep 20s is killed via SIGKILL after 2s grace; < 15s proves SIGKILL fired.
    @Suite("TimingTests", .serialized)
    struct TimingTests {
        @Test func killsACommandThatOverrunsItsTimeout() async {
            let provider = CLIProvider(command: ["sleep", "30"], timeout: .seconds(1))
            let started = Date()

            await #expect(throws: ProviderError.timedOut(seconds: 1)) {
                try await provider.complete("anything")
            }

            // The point is that it did not wait 30 seconds.
            #expect(Date().timeIntervalSince(started) < 20)
        }

        @Test func killsACommandThatTrapsSIGTERM() async {
            // Fix (1): a child that traps SIGTERM must still be killed within a few seconds
            // via the SIGKILL escalation, not after its full sleep duration.
            let provider = CLIProvider(
                command: ["sh", "-c", "trap '' TERM; sleep 20"],
                timeout: .seconds(1)
            )
            let started = Date()
            await #expect(throws: ProviderError.timedOut(seconds: 1)) {
                try await provider.complete("anything")
            }
            let elapsed = Date().timeIntervalSince(started)
            // timeout(1s) + grace(2s) + scheduling headroom = well under 15s; 20s would mean no SIGKILL fired.
            #expect(elapsed < 15, "SIGKILL escalation did not fire; elapsed: \(elapsed)s")
        }
    }

    @Test func completesWithLargeStdinPrompt() async throws {
        // Fix (3): a prompt larger than the 64KB pipe buffer must not deadlock.
        let bigPrompt = String(repeating: "x", count: 100_000)
        // cat reads all of stdin and echoes it; if the write blocks we never get here.
        let provider = CLIProvider(command: ["cat"], timeout: .seconds(10))
        let output = try await provider.complete(bigPrompt)
        #expect(output == bigPrompt)
    }

    // MARK: - Stdout diagnostic capture (the real-world claude OAuth failure shape)

    @Test func surfacesStdoutWhenStderrIsEmptyOnNonZeroExit() async throws {
        // Regression: provider CLIs like `claude` write diagnostics to stdout, not stderr.
        // Before the fix, this produced "Provider exited with code 1." with no detail.
        let provider = CLIProvider(
            command: ["sh", "-c", "echo 'Failed to authenticate: OAuth session expired'; exit 1"],
            timeout: .seconds(5)
        )
        do {
            _ = try await provider.complete("anything")
            Issue.record("expected a failure")
        } catch let error as ProviderError {
            guard case .failed(let code, let detail) = error else {
                Issue.record("expected .failed, got \(error)"); return
            }
            #expect(code == 1)
            #expect(detail.contains("OAuth session expired"),
                    "stdout diagnostic must reach the caller; got: \(detail)")
        }
    }

    @Test func surfacesStderrWhenOnlyStderrIsWrittenOnNonZeroExit() async throws {
        // Existing behaviour preserved: stderr-only diagnostics still work.
        let provider = CLIProvider(
            command: ["sh", "-c", "echo 'stderr only' >&2; exit 2"],
            timeout: .seconds(5)
        )
        do {
            _ = try await provider.complete("anything")
            Issue.record("expected a failure")
        } catch let error as ProviderError {
            guard case .failed(let code, let detail) = error else {
                Issue.record("expected .failed, got \(error)"); return
            }
            #expect(code == 2)
            #expect(detail.contains("stderr only"))
        }
    }

    @Test func prefersStderrWhenBothStreamsHaveContentOnNonZeroExit() async throws {
        // When both streams have content, stderr wins (it's the conventional error stream).
        let provider = CLIProvider(
            command: ["sh", "-c", "echo 'stdout noise'; echo 'real error' >&2; exit 5"],
            timeout: .seconds(5)
        )
        do {
            _ = try await provider.complete("anything")
            Issue.record("expected a failure")
        } catch let error as ProviderError {
            guard case .failed(let code, let detail) = error else {
                Issue.record("expected .failed, got \(error)"); return
            }
            #expect(code == 5)
            #expect(detail.contains("real error"), "stderr should be preferred; got: \(detail)")
            // stdout noise must not replace the stderr diagnosis
            #expect(!detail.trimmingCharacters(in: .whitespacesAndNewlines)
                       .hasPrefix("stdout noise"),
                    "stderr should win over stdout; got: \(detail)")
        }
    }

    @Test func realWorldClaudeOAuthFailureShape() async throws {
        // Exit 1, single line on stdout, empty stderr — the exact shape of `claude -p` when
        // OAuth session has expired. The user must see the diagnostic, not a bare exit code.
        let provider = CLIProvider(
            command: ["sh", "-c",
                      "printf 'Failed to authenticate: OAuth session expired and could not be refreshed'; exit 1"],
            timeout: .seconds(5)
        )
        do {
            _ = try await provider.complete("anything")
            Issue.record("expected a failure")
        } catch let error as ProviderError {
            guard case .failed(let code, let detail) = error else {
                Issue.record("expected .failed, got \(error)"); return
            }
            #expect(code == 1)
            #expect(detail.contains("OAuth session expired and could not be refreshed"),
                    "real-world diagnostic must reach the caller; got: \(detail)")
            let description = error.localizedDescription
            #expect(description.contains("OAuth session expired"),
                    "error description must surface the diagnostic; got: \(description)")
        }
    }

    @Test func stubRecordsPromptsAndReturnsQueuedResponses() async throws {
        let stub = StubProvider(responses: ["first", "second"])

        #expect(try await stub.complete("prompt one") == "first")
        #expect(try await stub.complete("prompt two") == "second")
        #expect(stub.receivedPrompts == ["prompt one", "prompt two"])
    }
}
