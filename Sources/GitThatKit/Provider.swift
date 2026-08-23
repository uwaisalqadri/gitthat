import Foundation

public protocol Provider: Sendable {
    /// Sends a prompt and returns the text that came back.
    func complete(_ prompt: String) async throws -> String
}

public enum ProviderError: Error, Equatable {
    case notFound(command: String)
    case timedOut(seconds: Int)
    case failed(exitCode: Int32, stderr: String)
    case empty
}

/// Spawns a configured command, writes the prompt to stdin, reads stdout.
///
/// This is the whole integration with an agent. It works identically for a
/// subscription-backed CLI and a local model, because both are commands that
/// read text and write text.
public struct CLIProvider: Provider {
    public let command: [String]
    public let timeout: Duration

    public init(command: [String], timeout: Duration) {
        self.command = command
        self.timeout = timeout
    }

    public func complete(_ prompt: String) async throws -> String {
        // ponytail: empty command array is the degenerate case — no executable to name.
        guard let executable = command.first else {
            throw ProviderError.notFound(command: "")
        }

        let outputURL = Self.makeTemporaryFile()
        let errorURL = Self.makeTemporaryFile()
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command

        // Fix (2): close handles explicitly after the process exits, consistent with GitRunner.
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer { try? errorHandle.close() }

        process.standardOutput = outputHandle
        process.standardError = errorHandle

        let inputPipe = Pipe()
        process.standardInput = inputPipe

        do {
            try process.run()
        } catch {
            throw ProviderError.notFound(command: executable)
        }

        // Foundation's Process already makes the child its own process group leader,
        // so kill(-pid, SIGTERM/SIGKILL) below reaps grandchildren without any
        // explicit setpgid() call here.

        // Fix (3): write stdin off the calling thread so a full pipe (64KB on macOS)
        // cannot block complete() before the timeout race even starts.
        // Use Darwin.write with F_SETNOSIGPIPE so a broken-pipe write returns EPIPE
        // instead of raising SIGPIPE or an NSException (which NSConcreteFileHandle
        // throws when the child exits before reading all of stdin).
        // A dedicated Thread rather than DispatchQueue.global(): the child blocks
        // reading stdin until this write happens, so if it were queued behind other
        // blocked work the child would never exit and the timeout would fire on a
        // command that was merely waiting for its input.
        let promptData = Data(prompt.utf8)
        let writeHandle = inputPipe.fileHandleForWriting
        let stdinThread = Thread {
            let fd = writeHandle.fileDescriptor
            // Suppress SIGPIPE on this specific fd; write returns EPIPE instead.
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            promptData.withUnsafeBytes { buf in
                var offset = 0
                while offset < buf.count {
                    let n = Darwin.write(fd, buf.baseAddress!.advanced(by: offset), buf.count - offset)
                    if n <= 0 { break } // EPIPE or other error — child closed read end
                    offset += n
                }
            }
            try? writeHandle.close()
        }
        stdinThread.stackSize = 512 * 1024
        stdinThread.start()

        try await waitForExit(of: process)

        let stderr = Self.read(errorURL)

        // ponytail: env exits 127 when it cannot find the command, not a launch error.
        // Treat 127 as notFound before the general failed case.
        if process.terminationStatus == 127 {
            throw ProviderError.notFound(command: executable)
        }

        guard process.terminationStatus == 0 else {
            // Many CLIs (e.g. claude) write diagnostics to stdout, not stderr.
            // Prefer stderr when non-empty; fall back to stdout so we never discard
            // the only available diagnosis. The enum label stays `stderr` for API stability.
            let stdoutForDiag = Self.read(outputURL)
            let diagnostic = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? stdoutForDiag
                : stderr
            throw ProviderError.failed(exitCode: process.terminationStatus, stderr: diagnostic)
        }

        let output = Self.read(outputURL)
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.empty
        }
        return output
    }

    /// Waits for the process, terminating it if it overruns the timeout.
    /// Fix (1): after SIGTERM, schedules a SIGKILL after a 2-second grace period
    /// on a DispatchQueue so a process that traps SIGTERM cannot hang complete().
    /// The SIGKILL is fire-and-forget so it does not delay the .timedOut throw.
    private func waitForExit(of process: Process) async throws {
        let seconds = Int(timeout.components.seconds)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    // waitUntilExit blocks, so it must not run on the cooperative pool.
                    // It also must not run on DispatchQueue.global(): that pool grows
                    // slowly, so under load the wait can sit queued for seconds and lose
                    // the race to the timeout task even though the child already exited —
                    // reporting a spurious .timedOut for a command that succeeded.
                    // A dedicated Thread is always schedulable immediately.
                    let thread = Thread {
                        process.waitUntilExit()
                        continuation.resume()
                    }
                    thread.stackSize = 512 * 1024
                    thread.start()
                }
            }
            group.addTask {
                // Use Thread.sleep (non-cooperative, kernel-scheduled) for the timeout
                // wait instead of Task.sleep (cooperative). Under CPU saturation from
                // concurrent git rebases, Task.sleep has been observed to delay > 200s
                // for a 1-second timeout — the kernel scheduler still runs dedicated
                // Threads regardless of how occupied the cooperative pool is.
                //
                // Pattern: sleep on a Thread, then resume a plain (non-throwing)
                // continuation so the timeout logic runs on the cooperative pool AFTER
                // the sleep. Task.checkCancellation() after the sleep ensures no
                // double-resume if the process exits first (task 1 wins, task 2 is
                // cancelled, checkCancellation throws CancellationError, group discards it).
                // ponytail: Thread.sleep; switch to clock_nanosleep if sub-ms precision needed.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let thread = Thread {
                        Thread.sleep(forTimeInterval: Double(seconds))
                        continuation.resume()
                    }
                    thread.stackSize = 64 * 1024
                    thread.start()
                }
                // Fast-fail if the process already exited (task 1 cancelled us).
                try Task.checkCancellation()
                let pid = process.processIdentifier
                // SIGTERM to the whole process group so grandchildren also get it.
                kill(-pid, SIGTERM)
                // SIGKILL escalation after 2s grace on DispatchQueue (fire-and-forget).
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(-pid, SIGKILL) }
                }
                throw ProviderError.timedOut(seconds: seconds)
            }

            // Whichever finishes first decides the outcome.
            // First task to finish: if it's the wait task (Void, no throw), we're done.
            // If it's the timeout task, it throws timedOut.
            // cancelAll cancels the other task; the wait task's CancellationError is
            // swallowed because we don't call next() again.
            do {
                try await group.next()
            } catch {
                group.cancelAll()
                throw error
            }
            group.cancelAll()
        }
    }

    private static func makeTemporaryFile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitthat-provider-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    private static func read(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
