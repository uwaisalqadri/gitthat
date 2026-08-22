import Foundation

public struct GitResult: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public var succeeded: Bool { exitCode == 0 }

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public enum GitRunnerError: Error, Equatable {
    case couldNotLaunch(String)
}

public protocol GitRunner: Sendable {
    /// Runs git and returns its result. A non-zero exit is a result, not an error —
    /// only failure to launch the process throws.
    func run(_ arguments: [String], in directory: URL, stdin: String?) throws -> GitResult

    /// Environment overrides this runner applies to every git process it launches.
    /// Callers that spawn git themselves (e.g. the interactive rewrite) must apply
    /// these too, or they escape the isolation every other call gets.
    var environment: [String: String] { get }
}

public extension GitRunner {
    var environment: [String: String] { [:] }
}

public struct SystemGitRunner: GitRunner {
    private let environmentOverrides: [String: String]

    public var environment: [String: String] { environmentOverrides }

    public init(environmentOverrides: [String: String] = [:]) {
        self.environmentOverrides = environmentOverrides
    }

    public func run(_ arguments: [String], in directory: URL, stdin: String?) throws -> GitResult {
        // Output goes to temp files rather than pipes. Pipes have a fixed buffer
        // (64KB on macOS) and a process that fills it blocks forever unless the
        // parent is draining concurrently. Diffs routinely exceed that.
        let outputURL = Self.makeTemporaryFile()
        let errorURL = Self.makeTemporaryFile()
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in environmentOverrides { environment[key] = value }
        process.environment = environment

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer { try? errorHandle.close() }
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        let inputPipe = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : inputPipe

        do {
            try process.run()
        } catch {
            throw GitRunnerError.couldNotLaunch(error.localizedDescription)
        }

        if let stdin {
            inputPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inputPipe.fileHandleForWriting.close()
        }

        process.waitUntilExit()

        return GitResult(
            stdout: Self.read(outputURL),
            stderr: Self.read(errorURL),
            exitCode: process.terminationStatus
        )
    }

    private static func makeTemporaryFile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitthat-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    private static func read(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
