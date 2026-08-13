# GITTHAT Plan 1 — Foundation and `gitthat commit`

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `gitthat commit` — a working CLI that reads the staged diff, asks an installed agent CLI for a message, enforces the project's casing rule, and commits after the user approves.

**Architecture:** One SwiftPM package, two targets. `gitthat` is a thin ArgumentParser executable; `GitThatKit` holds all logic and is tested without spawning the binary. The agent is reached through a `Provider` protocol whose only implementation spawns a configured command — the single seam where non-determinism enters, stubbed in every test. Git is real everywhere except failure-injection tests.

**Tech Stack:** Swift 6.3, SwiftPM, Swift Testing, `swift-argument-parser` 1.8.2, `TOMLKit` 0.6.0.

**Spec:** `docs/superpowers/specs/2026-08-13-gitthat-design.md` is the source of truth. Where this plan and the spec disagree, the spec wins — report the conflict rather than guessing.

## Global Constraints

These apply to every task without being repeated.

- **Swift 6.3**, tools version 6.0, `.macOS(.v13)` platform floor.
- **Swift Testing** (`import Testing`, `@Test`, `#expect`). Never XCTest.
- **No user-facing string may contain** `rebase`, `squash`, or `fixup`. Task 12 enforces this with a test, covering help text, prompts, previews, and error messages. (The spec also forbids `pick` and `todo`; both are deferred to Plan 2, where history rewriting introduces them. `pick` is ordinary English — "pick a style" — and would false-positive on Plan 1's own copy.)
- **Never run `git commit`.** Stage completed work with `git add -A` and stop. The human commits at each task boundary, after the task passes review. A task ends staged, not committed.
- **`GitThatKit` must not import `ArgumentParser`.** Only the executable target parses arguments.
- **Every type crossing an `async` boundary is `Sendable`.**
- **Tests create repositories in fresh temp directories** and remove them afterwards. No test touches a fixed path or the developer's real git config.
- **Every test that runs git sets** `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` to `/dev/null`, plus `GIT_AUTHOR_*`/`GIT_COMMITTER_*` identity variables. A developer's `commit.gpgsign` must not change a result.
- **Commit messages in this repository** follow Conventional Commits with the casing rule: every word entirely lowercase or entirely uppercase.

## File Structure

```
Package.swift                                  package manifest, two targets
Sources/gitthat/
  GitThat.swift                                @main, root ArgumentParser command
  CommitCommand.swift                          the `commit` subcommand, wiring only
Sources/GitThatKit/
  GitRunner.swift                              protocol + SystemGitRunner + GitResult
  Git.swift                                    typed queries built on GitRunner
  Config.swift                                 TOML load, global/repo overlay, defaults
  SubjectCase.swift                            the casing rule
  CommitStyle.swift                            conventional/plain inference
  TicketID.swift                               branch-name ticket extraction
  ResponseParser.swift                         fence stripping, subject/body split
  Provider.swift                               protocol + CLIProvider + ProviderError
  Prompts.swift                                prompt construction
  UI.swift                                     preview, confirmation, $EDITOR handoff
Tests/GitThatKitTests/
  Support/RepoFixture.swift                    declarative real-repo builder
  Support/StubProvider.swift                   queued responses, records prompts
  GitRunnerTests.swift
  GitTests.swift
  ConfigTests.swift
  SubjectCaseTests.swift
  CommitStyleTests.swift
  TicketIDTests.swift
  ResponseParserTests.swift
  ProviderTests.swift
  PromptsTests.swift
  UITests.swift
  CommitFlowTests.swift
  VocabularyLintTests.swift
scripts/check-own-history.sh                   layer 7 — validates this repo's log
```

One responsibility per file. `Git` holds no policy; `SubjectCase`, `CommitStyle`, `TicketID`, and `ResponseParser` are pure and have no dependencies at all, which is why they are testable exhaustively in milliseconds.

---

### Task 1: Package scaffold and the git process wrapper

Everything else runs git. This task produces a wrapper that cannot deadlock on large output and cannot be polluted by developer config.

**Files:**
- Create: `Package.swift`
- Create: `Sources/GitThatKit/GitRunner.swift`
- Create: `Sources/gitthat/GitThat.swift`
- Test: `Tests/GitThatKitTests/GitRunnerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `GitResult` (struct: `stdout: String`, `stderr: String`, `exitCode: Int32`, `succeeded: Bool`), `protocol GitRunner: Sendable` with `func run(_ arguments: [String], in directory: URL, stdin: String?) throws -> GitResult`, and `struct SystemGitRunner: GitRunner` with `init(environmentOverrides: [String: String] = [:])`.

- [ ] **Step 1: Create the package manifest**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "gitthat",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "gitthat", targets: ["gitthat"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "gitthat",
            dependencies: [
                "GitThatKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "GitThatKit",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit")
            ]
        ),
        .testTarget(
            name: "GitThatKitTests",
            dependencies: ["GitThatKit"]
        ),
    ]
)
```

- [ ] **Step 2: Create a placeholder entry point so the package builds**

`Sources/gitthat/GitThat.swift`:

```swift
import ArgumentParser

@main
struct GitThat: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gitthat",
        abstract: "Rewrite history without remembering how."
    )
}
```

- [ ] **Step 3: Verify dependencies resolve**

Run: `swift build`
Expected: success. If TOMLKit fails to resolve, run `swift package resolve` and report the actual error — do not change the dependency without saying so.

- [ ] **Step 4: Write the failing test**

`Tests/GitThatKitTests/GitRunnerTests.swift`:

> **Amended during execution.** The two file-scope helpers below —
> `withTempDirectory` and `isolatedGitEnvironment` — now live in
> `Tests/GitThatKitTests/Support/TestSupport.swift` instead. Six later tasks
> depend on them, and shared helpers belong beside `RepoFixture`, not in an
> unrelated test file. The code is unchanged; only its home moved.

```swift
import Foundation
import Testing
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
```

- [ ] **Step 5: Run the tests to verify they fail**

Run: `swift test --filter GitRunnerTests`
Expected: FAIL — `cannot find 'SystemGitRunner' in scope`.

- [ ] **Step 6: Implement the runner**

`Sources/GitThatKit/GitRunner.swift`:

```swift
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
}

public struct SystemGitRunner: GitRunner {
    private let environmentOverrides: [String: String]

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
        let errorHandle = try FileHandle(forWritingTo: errorURL)
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
        try? outputHandle.close()
        try? errorHandle.close()

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
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --filter GitRunnerTests`
Expected: PASS, 4 tests.

- [ ] **Step 8: Stage for review**

```bash
git add Package.swift Sources/ Tests/
# Do not commit. Stop here and report — the human commits at this boundary.
```

---

### Task 2: RepoFixture and typed git queries

`Git` turns raw command output into the values the commit flow needs. `RepoFixture` makes every later integration test readable.

**Files:**
- Create: `Tests/GitThatKitTests/Support/RepoFixture.swift`
- Create: `Sources/GitThatKit/Git.swift`
- Test: `Tests/GitThatKitTests/GitTests.swift`

**Interfaces:**
- Consumes: `GitRunner`, `SystemGitRunner`, `GitResult` from Task 1.
- Produces: `struct Git` with `init(runner: GitRunner, directory: URL)` and methods `isRepository() -> Bool`, `stagedDiff(limit: Int) throws -> StagedDiff`, `recentSubjects(_ count: Int) throws -> [String]`, `currentBranch() throws -> String?`, `hasStagedChanges() throws -> Bool`, `stageAll() throws`, `commit(message: String) throws -> String`. Produces `struct StagedDiff: Sendable { let text: String; let wasTruncated: Bool }`. Produces test helper `RepoFixture`.

- [ ] **Step 1: Write the fixture builder**

`Tests/GitThatKitTests/Support/RepoFixture.swift`:

```swift
import Foundation
@testable import GitThatKit

/// Builds a real git repository in a temp directory.
///
/// Building a four-commit repository costs about 2.7 seconds, so suites that
/// need many identical repositories should build one and copy it. `copy()`
/// costs about 34ms.
final class RepoFixture {
    let directory: URL
    let runner: SystemGitRunner
    private(set) var remoteDirectory: URL?

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitthat-repo-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        runner = SystemGitRunner(environmentOverrides: isolatedGitEnvironment)
        run(["init", "-q", "-b", "main"])
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        if let remoteDirectory { try? FileManager.default.removeItem(at: remoteDirectory) }
    }

    @discardableResult
    func run(_ arguments: [String], stdin: String? = nil) -> GitResult {
        try! runner.run(arguments, in: directory, stdin: stdin)
    }

    /// Writes a file and commits it with the given subject.
    @discardableResult
    func commit(_ subject: String, file: String, contents: String) -> Self {
        try! contents.write(to: directory.appendingPathComponent(file),
                            atomically: true, encoding: .utf8)
        run(["add", "-A"])
        run(["commit", "-q", "-m", subject])
        return self
    }

    /// Writes a file and stages it without committing.
    @discardableResult
    func stage(file: String, contents: String) -> Self {
        try! contents.write(to: directory.appendingPathComponent(file),
                            atomically: true, encoding: .utf8)
        run(["add", "-A"])
        return self
    }

    /// Writes a file without staging it.
    @discardableResult
    func write(file: String, contents: String) -> Self {
        try! contents.write(to: directory.appendingPathComponent(file),
                            atomically: true, encoding: .utf8)
        return self
    }

    @discardableResult
    func checkout(branch: String) -> Self {
        run(["checkout", "-q", "-b", branch])
        return self
    }

    /// Creates a bare repository, pushes everything committed so far, and sets
    /// upstream tracking. Everything committed before this call is "pushed".
    @discardableResult
    func push() -> Self {
        if remoteDirectory == nil {
            let remote = FileManager.default.temporaryDirectory
                .appendingPathComponent("gitthat-remote-\(UUID().uuidString)")
            try! FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
            try! runner.run(["init", "-q", "--bare"], in: remote, stdin: nil)
            remoteDirectory = remote
            run(["remote", "add", "origin", remote.path])
        }
        let branch = run(["rev-parse", "--abbrev-ref", "HEAD"])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        run(["push", "-q", "-u", "origin", branch])
        return self
    }

    var git: Git { Git(runner: runner, directory: directory) }

    func subjects() -> [String] {
        run(["log", "--format=%s"]).stdout
            .split(separator: "\n").map(String.init)
    }
}
```

- [ ] **Step 2: Write the failing test**

`Tests/GitThatKitTests/GitTests.swift`:

```swift
import Foundation
import Testing
@testable import GitThatKit

@Test func detectsARepository() {
    let repo = RepoFixture()
    #expect(repo.git.isRepository())
}

@Test func readsStagedDiff() throws {
    let repo = RepoFixture()
        .commit("initial", file: "a.txt", contents: "one\n")
        .stage(file: "b.txt", contents: "two\n")

    let diff = try repo.git.stagedDiff(limit: 8192)
    #expect(diff.text.contains("b.txt"))
    #expect(diff.text.contains("+two"))
    #expect(!diff.wasTruncated)
}

@Test func truncatesLargeDiffsAndSaysSo() throws {
    let repo = RepoFixture()
        .commit("initial", file: "a.txt", contents: "one\n")
        .stage(file: "big.txt", contents: String(repeating: "x\n", count: 20_000))

    let diff = try repo.git.stagedDiff(limit: 8192)
    #expect(diff.wasTruncated)
    #expect(diff.text.count <= 8192)
}

@Test func reportsWhetherAnythingIsStaged() throws {
    let repo = RepoFixture().commit("initial", file: "a.txt", contents: "one\n")
    #expect(try repo.git.hasStagedChanges() == false)

    repo.stage(file: "b.txt", contents: "two\n")
    #expect(try repo.git.hasStagedChanges() == true)
}

@Test func stagesEverything() throws {
    let repo = RepoFixture()
        .commit("initial", file: "a.txt", contents: "one\n")
        .write(file: "b.txt", contents: "two\n")

    #expect(try repo.git.hasStagedChanges() == false)
    try repo.git.stageAll()
    #expect(try repo.git.hasStagedChanges() == true)
}

@Test func readsRecentSubjectsNewestFirst() throws {
    let repo = RepoFixture()
        .commit("first", file: "a.txt", contents: "1")
        .commit("second", file: "b.txt", contents: "2")
        .commit("third", file: "c.txt", contents: "3")

    #expect(try repo.git.recentSubjects(20) == ["third", "second", "first"])
}

@Test func recentSubjectsIsEmptyInAnEmptyRepository() throws {
    let repo = RepoFixture()
    #expect(try repo.git.recentSubjects(20) == [])
}

@Test func readsCurrentBranch() throws {
    let repo = RepoFixture()
        .commit("initial", file: "a.txt", contents: "1")
        .checkout(branch: "feature/PROJ-421-sso")

    #expect(try repo.git.currentBranch() == "feature/PROJ-421-sso")
}

@Test func commitsWithAMultiLineMessage() throws {
    let repo = RepoFixture()
        .commit("initial", file: "a.txt", contents: "1")
        .stage(file: "b.txt", contents: "2")

    let message = "feat(auth): add token refresh\n\nRefreshes ten seconds before expiry."
    let sha = try repo.git.commit(message: message)

    #expect(sha.count == 40)
    #expect(repo.subjects().first == "feat(auth): add token refresh")
    let body = repo.run(["log", "-1", "--format=%b"]).stdout
    #expect(body.contains("ten seconds before expiry"))
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter GitTests`
Expected: FAIL — `cannot find 'Git' in scope`.

- [ ] **Step 4: Implement the typed queries**

`Sources/GitThatKit/Git.swift`:

```swift
import Foundation

public struct StagedDiff: Sendable, Equatable {
    public let text: String
    public let wasTruncated: Bool
}

public enum GitError: Error, Equatable {
    case notARepository
    case commandFailed(command: String, stderr: String)
}

/// Typed queries over a repository. Holds no policy — it runs commands and
/// returns values, and every decision is made by a caller.
public struct Git: Sendable {
    private let runner: GitRunner
    private let directory: URL

    public init(runner: GitRunner, directory: URL) {
        self.runner = runner
        self.directory = directory
    }

    public func isRepository() -> Bool {
        guard let result = try? runner.run(["rev-parse", "--is-inside-work-tree"],
                                           in: directory, stdin: nil) else { return false }
        return result.succeeded
    }

    public func stagedDiff(limit: Int) throws -> StagedDiff {
        let text = try require(["diff", "--cached"])
        guard text.count > limit else {
            return StagedDiff(text: text, wasTruncated: false)
        }
        return StagedDiff(text: String(text.prefix(limit)), wasTruncated: true)
    }

    public func hasStagedChanges() throws -> Bool {
        let result = try runner.run(["diff", "--cached", "--quiet"], in: directory, stdin: nil)
        // --quiet exits 1 when there are differences, 0 when there are none.
        return result.exitCode == 1
    }

    public func stageAll() throws {
        _ = try require(["add", "-A"])
    }

    public func recentSubjects(_ count: Int) throws -> [String] {
        let result = try runner.run(["log", "--format=%s", "-n", String(count)],
                                    in: directory, stdin: nil)
        // An empty repository has no HEAD and git exits non-zero. That is not
        // an error here — it is a repository with no subjects.
        guard result.succeeded else { return [] }
        return result.stdout.split(separator: "\n").map(String.init)
    }

    public func currentBranch() throws -> String? {
        let result = try runner.run(["rev-parse", "--abbrev-ref", "HEAD"],
                                    in: directory, stdin: nil)
        guard result.succeeded else { return nil }
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return name == "HEAD" ? nil : name
    }

    /// Commits the staged changes and returns the new SHA.
    @discardableResult
    public func commit(message: String) throws -> String {
        _ = try require(["commit", "-q", "-F", "-"], stdin: message)
        return try require(["rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func require(_ arguments: [String], stdin: String? = nil) throws -> String {
        let result = try runner.run(arguments, in: directory, stdin: stdin)
        guard result.succeeded else {
            throw GitError.commandFailed(
                command: "git " + arguments.joined(separator: " "),
                stderr: result.stderr
            )
        }
        return result.stdout
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter GitTests`
Expected: PASS, 9 tests.

- [ ] **Step 6: Stage for review**

```bash
git add Sources/GitThatKit/Git.swift Tests/GitThatKitTests/
# Do not commit. Stop here and report — the human commits at this boundary.
```

---

### Task 3: The subject casing rule

The rule from the spec: every word entirely lowercase or entirely uppercase. A word violates it when it has a leading capital and no other capital.

**Files:**
- Create: `Sources/GitThatKit/SubjectCase.swift`
- Test: `Tests/GitThatKitTests/SubjectCaseTests.swift`

**Interfaces:**
- Consumes: nothing. This file has no dependencies.
- Produces: `enum SubjectCaseSetting: String, Sendable, Codable { case lower, preserve }` and `enum SubjectCase` with `static func enforce(_ subject: String, setting: SubjectCaseSetting) -> String` and `static func violates(_ subject: String) -> Bool`.

- [ ] **Step 1: Write the failing test**

`Tests/GitThatKitTests/SubjectCaseTests.swift`:

```swift
import Testing
@testable import GitThatKit

@Test(arguments: [
    // input, expected
    ("feat(a-feature): WIP working on DNS improvement ASAP",
     "feat(a-feature): WIP working on DNS improvement ASAP"),
    ("feat(a-feature): WIP Working on DNS Improvement ASAP",
     "feat(a-feature): WIP working on DNS improvement ASAP"),
    ("Add token refresh", "add token refresh"),
    ("add token refresh", "add token refresh"),
    ("Fix DNS lookup", "fix DNS lookup"),
    ("feat: Add support for iOS", "feat: add support for iOS"),
    ("fix: handle GitHub rate limits", "fix: handle GitHub rate limits"),
    ("fix: guard refreshToken against nil", "fix: guard refreshToken against nil"),
    ("refactor: split TokenStore", "refactor: split TokenStore"),
    ("chore: bump API version", "chore: bump API version"),
    ("Well-Known endpoints", "well-known endpoints"),
    ("Add a trailing period.", "add a trailing period."),
    ("I fixed it", "I fixed it"),
])
func enforcesCasing(input: String, expected: String) {
    #expect(SubjectCase.enforce(input, setting: .lower) == expected)
}

@Test(arguments: [
    "feat: touch Sources/GitThatKit/Git.swift",
    "fix: update Package.swift",
    "docs: rewrite README.md",
    "chore: rename Foo_Bar to baz",
])
func leavesIdentifiersAndPathsAlone(subject: String) {
    #expect(SubjectCase.enforce(subject, setting: .lower) == subject)
}

@Test func preserveDisablesEnforcement() {
    let subject = "Add Token Refresh"
    #expect(SubjectCase.enforce(subject, setting: .preserve) == subject)
}

@Test(arguments: ["", " ", "A", "I", "DNS", "iOS"])
func handlesDegenerateInputWithoutChanging(subject: String) {
    #expect(SubjectCase.enforce(subject, setting: .lower) == subject)
}

@Test func reportsViolationsWithoutFixingThem() {
    #expect(SubjectCase.violates("Add token refresh"))
    #expect(!SubjectCase.violates("add token refresh"))
    #expect(!SubjectCase.violates("fix DNS lookup"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SubjectCaseTests`
Expected: FAIL — `cannot find 'SubjectCase' in scope`.

- [ ] **Step 3: Implement the rule**

`Sources/GitThatKit/SubjectCase.swift`:

```swift
public enum SubjectCaseSetting: String, Sendable, Codable {
    case lower
    case preserve
}

/// Enforces the project's casing rule: every word is entirely lowercase or
/// entirely uppercase.
///
/// A run of letters violates the rule when it starts with a capital and every
/// following letter is lowercase — `Add`, `Working`, `Improvement`. Acronyms
/// pass because they are fully uppercase. Identifiers and proper nouns pass
/// because they carry an internal capital: `iOS`, `GitHub`, `refreshToken`,
/// `TokenStore`.
public enum SubjectCase {

    public static func enforce(_ subject: String, setting: SubjectCaseSetting) -> String {
        guard setting == .lower else { return subject }
        return subject
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { fixToken(String($0)) }
            .joined(separator: " ")
    }

    public static func violates(_ subject: String) -> Bool {
        enforce(subject, setting: .lower) != subject
    }

    /// Tokens that look like paths or code identifiers are left entirely alone,
    /// so `Sources/Git.swift` does not become `sources/git.swift`.
    private static func fixToken(_ token: String) -> String {
        guard !isIdentifierLike(token) else { return token }

        var result = ""
        var run = ""
        for character in token {
            if character.isLetter {
                run.append(character)
            } else {
                result += fixRun(run)
                run = ""
                result.append(character)
            }
        }
        return result + fixRun(run)
    }

    private static func isIdentifierLike(_ token: String) -> Bool {
        if token.contains(where: { "/\\_@`".contains($0) }) { return true }
        // An internal dot, as in `Git.swift` — but not a trailing full stop.
        if let dot = token.firstIndex(of: "."), token.index(after: dot) != token.endIndex {
            return true
        }
        return false
    }

    private static func fixRun(_ run: String) -> String {
        isViolatingRun(run) ? run.lowercased() : run
    }

    private static func isViolatingRun(_ run: String) -> Bool {
        guard run.count >= 2, let first = run.first, first.isUppercase else { return false }
        return run.dropFirst().allSatisfy(\.isLowercase)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SubjectCaseTests`
Expected: PASS, 24 test cases across 5 functions.

- [ ] **Step 5: Stage for review**

```bash
git add Sources/GitThatKit/SubjectCase.swift Tests/GitThatKitTests/SubjectCaseTests.swift
# Do not commit. Stop here and report — the human commits at this boundary.
```

---

### Task 4: Commit style inference

**Note on a spec correction:** the spec's prose said "at least 70% conventional, otherwise plain" *and* "mixed history is ambiguous, so ask". Those conflict. This task implements the resolved rule, and Task 12 updates the spec to match: **≥70% conventional → `.conventional`; ≤30% → `.plain`; anything between, or fewer than five subjects → ambiguous, ask the user.**

**Files:**
- Create: `Sources/GitThatKit/CommitStyle.swift`
- Test: `Tests/GitThatKitTests/CommitStyleTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum CommitStyle: String, Sendable, Codable { case conventional, plain }`, `enum StyleSetting: String, Sendable, Codable { case auto, conventional, plain }`, and `enum StyleInference` with `static func isConventional(_ subject: String) -> Bool` and `static func infer(from subjects: [String]) -> CommitStyle?` returning `nil` when ambiguous.

- [ ] **Step 1: Write the failing test**

`Tests/GitThatKitTests/CommitStyleTests.swift`:

```swift
import Testing
@testable import GitThatKit

@Test(arguments: [
    "feat: add token refresh",
    "fix(auth): handle expiry",
    "chore!: drop support for macOS 12",
    "refactor(core): split TokenStore",
    "docs: rewrite the readme",
])
func recognisesConventionalSubjects(subject: String) {
    #expect(StyleInference.isConventional(subject))
}

@Test(arguments: [
    "add token refresh",
    "Fixed the auth bug",
    "feat add token refresh",     // no colon
    "feat:no space after colon",
    "FEAT: uppercase type",
    "feat():empty scope",
    "",
])
func rejectsNonConventionalSubjects(subject: String) {
    #expect(!StyleInference.isConventional(subject))
}

private func subjects(conventional: Int, plain: Int) -> [String] {
    Array(repeating: "feat: a change", count: conventional)
        + Array(repeating: "a change", count: plain)
}

@Test func infersConventionalAtSeventyPercent() {
    #expect(StyleInference.infer(from: subjects(conventional: 7, plain: 3)) == .conventional)
}

@Test func infersConventionalAboveSeventyPercent() {
    #expect(StyleInference.infer(from: subjects(conventional: 71, plain: 29)) == .conventional)
}

@Test func isAmbiguousJustBelowSeventyPercent() {
    #expect(StyleInference.infer(from: subjects(conventional: 69, plain: 31)) == nil)
}

@Test func infersPlainAtThirtyPercent() {
    #expect(StyleInference.infer(from: subjects(conventional: 3, plain: 7)) == .plain)
}

@Test func isAmbiguousInTheMiddle() {
    #expect(StyleInference.infer(from: subjects(conventional: 5, plain: 5)) == nil)
}

@Test func isAmbiguousWithFewerThanFiveSubjects() {
    #expect(StyleInference.infer(from: subjects(conventional: 4, plain: 0)) == nil)
}

@Test func isAmbiguousWithNoSubjects() {
    #expect(StyleInference.infer(from: []) == nil)
}

@Test func infersConventionalWhenEverythingIsConventional() {
    #expect(StyleInference.infer(from: subjects(conventional: 20, plain: 0)) == .conventional)
}

@Test func infersPlainWhenNothingIsConventional() {
    #expect(StyleInference.infer(from: subjects(conventional: 0, plain: 20)) == .plain)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter CommitStyleTests`
Expected: FAIL — `cannot find 'StyleInference' in scope`.

- [ ] **Step 3: Implement inference**

`Sources/GitThatKit/CommitStyle.swift`:

```swift
import Foundation

public enum CommitStyle: String, Sendable, Codable {
    case conventional
    case plain
}

public enum StyleSetting: String, Sendable, Codable {
    case auto
    case conventional
    case plain
}

public enum StyleInference {
    /// `type(scope)!: description` — lowercase type, optional scope, optional
    /// breaking marker, a space after the colon, and a non-empty description.
    private static let pattern = try! Regex(#"^[a-z]+(\([^)]+\))?!?: .+$"#)

    private static let minimumSampleSize = 5
    private static let conventionalThreshold = 0.70
    private static let plainThreshold = 0.30

    public static func isConventional(_ subject: String) -> Bool {
        (try? pattern.wholeMatch(in: subject)) .flatMap { $0 } != nil
    }

    /// Returns `nil` when history cannot settle the question — too few commits,
    /// or a genuinely mixed repository. The caller asks the user.
    public static func infer(from subjects: [String]) -> CommitStyle? {
        guard subjects.count >= minimumSampleSize else { return nil }

        let ratio = Double(subjects.filter(isConventional).count) / Double(subjects.count)
        if ratio >= conventionalThreshold { return .conventional }
        if ratio <= plainThreshold { return .plain }
        return nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter CommitStyleTests`
Expected: PASS, 21 test cases across 10 functions.

If `wholeMatch(in:)` produces a compiler error about optionality, the correct
call is `subject.wholeMatch(of: pattern) != nil`. Use whichever compiles and
keep the behaviour identical.

- [ ] **Step 5: Stage for review**

```bash
git add Sources/GitThatKit/CommitStyle.swift Tests/GitThatKitTests/CommitStyleTests.swift
# Do not commit. Stop here and report — the human commits at this boundary.
```

---

### Task 5: Ticket ID extraction

**Files:**
- Create: `Sources/GitThatKit/TicketID.swift`
- Test: `Tests/GitThatKitTests/TicketIDTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum TicketID` with `static func extract(fromBranch branch: String?) -> String?` and `static func appearsIn(subjects: [String]) -> Bool`.

- [ ] **Step 1: Write the failing test**

`Tests/GitThatKitTests/TicketIDTests.swift`:

```swift
import Testing
@testable import GitThatKit

@Test(arguments: [
    ("feature/PROJ-421-sso", "PROJ-421"),
    ("PROJ-421", "PROJ-421"),
    ("bugfix/AB-1", "AB-1"),
    ("feature/PROJ-421-and-PROJ-422", "PROJ-421"),   // first wins
    ("feature/X1Y2-99-thing", "X1Y2-99"),
])
func extractsTickets(branch: String, expected: String) {
    #expect(TicketID.extract(fromBranch: branch) == expected)
}

@Test(arguments: [
    "main",
    "feature/sso",
    "feature/add-123-things",       // lowercase prefix is not a ticket
    "release/1.2.3",
    "feature/A-1",                  // single letter prefix is too noisy
])
func findsNoTicket(branch: String) {
    #expect(TicketID.extract(fromBranch: branch) == nil)
}

@Test func handlesNoBranch() {
    #expect(TicketID.extract(fromBranch: nil) == nil)
}

@Test func detectsWhetherHistoryUsesTickets() {
    #expect(TicketID.appearsIn(subjects: ["PROJ-1 add a thing", "fix a thing"]))
    #expect(!TicketID.appearsIn(subjects: ["add a thing", "fix a thing"]))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TicketIDTests`
Expected: FAIL — `cannot find 'TicketID' in scope`.

- [ ] **Step 3: Implement extraction**

`Sources/GitThatKit/TicketID.swift`:

```swift
import Foundation

public enum TicketID {
    /// Two or more uppercase alphanumerics, a hyphen, then digits — `PROJ-421`.
    /// Requiring two characters keeps single-letter branch segments from
    /// registering as tickets.
    private static let pattern = try! Regex(#"[A-Z][A-Z0-9]+-[0-9]+"#)

    public static func extract(fromBranch branch: String?) -> String? {
        guard let branch else { return nil }
        guard let match = branch.firstMatch(of: pattern) else { return nil }
        return String(branch[match.range])
    }

    /// Whether the repository's own history shows ticket IDs in subjects. Used
    /// to decide whether including one is appropriate.
    public static func appearsIn(subjects: [String]) -> Bool {
        subjects.contains { $0.firstMatch(of: pattern) != nil }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TicketIDTests`
Expected: PASS, 12 test cases across 4 functions.

- [ ] **Step 5: Stage for review**

```bash
git add Sources/GitThatKit/TicketID.swift Tests/GitThatKitTests/TicketIDTests.swift
# Do not commit. Stop here and report — the human commits at this boundary.
```

---

### Task 6: Response parsing

Agent CLIs wrap output in fences, add preambles, and pad with whitespace. This turns raw text into a subject and body.

**Files:**
- Create: `Sources/GitThatKit/ResponseParser.swift`
- Test: `Tests/GitThatKitTests/ResponseParserTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct CommitMessage: Sendable, Equatable { let subject: String; let body: String? ; var full: String }` and `enum ResponseParser` with `static func stripFences(_ raw: String) -> String` and `static func commitMessage(from raw: String) throws -> CommitMessage`, plus `enum ResponseError: Error, Equatable { case empty }`.

- [ ] **Step 1: Write the failing test**

`Tests/GitThatKitTests/ResponseParserTests.swift`:

```swift
import Testing
@testable import GitThatKit

@Test func parsesAPlainSubject() throws {
    let message = try ResponseParser.commitMessage(from: "feat: add token refresh")
    #expect(message.subject == "feat: add token refresh")
    #expect(message.body == nil)
}

@Test func parsesSubjectAndBody() throws {
    let raw = "feat: add token refresh\n\nRefreshes ten seconds before expiry.\nFalls back to a full login."
    let message = try ResponseParser.commitMessage(from: raw)

    #expect(message.subject == "feat: add token refresh")
    #expect(message.body == "Refreshes ten seconds before expiry.\nFalls back to a full login.")
    #expect(message.full == raw)
}

@Test(arguments: [
    "```\nfeat: add token refresh\n```",
    "```text\nfeat: add token refresh\n```",
    "```json\nfeat: add token refresh\n```",
    "  ```\n  feat: add token refresh\n  ```  ",
])
func stripsFences(raw: String) throws {
    let message = try ResponseParser.commitMessage(from: raw)
    #expect(message.subject == "feat: add token refresh")
}

@Test(arguments: [
    "Here's the commit message:\n\nfeat: add token refresh",
    "Here is the commit message:\nfeat: add token refresh",
    "Sure, here's a commit message:\n\nfeat: add token refresh",
    "Certainly! Here is one:\n\nfeat: add token refresh",
])
func stripsConversationalPreamble(raw: String) throws {
    let message = try ResponseParser.commitMessage(from: raw)
    #expect(message.subject == "feat: add token refresh")
}

@Test func keepsAColonSubjectThatIsNotPreamble() throws {
    let message = try ResponseParser.commitMessage(from: "feat: add token refresh")
    #expect(message.subject == "feat: add token refresh")
}

@Test func trimsSurroundingWhitespace() throws {
    let message = try ResponseParser.commitMessage(from: "\n\n  feat: add token refresh  \n\n")
    #expect(message.subject == "feat: add token refresh")
}

@Test(arguments: ["", "   ", "\n\n", "```\n```"])
func rejectsEmptyResponses(raw: String) {
    #expect(throws: ResponseError.empty) {
        try ResponseParser.commitMessage(from: raw)
    }
}

@Test func collapsesExtraBlankLinesBetweenSubjectAndBody() throws {
    let message = try ResponseParser.commitMessage(from: "feat: x\n\n\n\nthe body")
    #expect(message.subject == "feat: x")
    #expect(message.body == "the body")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ResponseParserTests`
Expected: FAIL — `cannot find 'ResponseParser' in scope`.

- [ ] **Step 3: Implement the parser**

`Sources/GitThatKit/ResponseParser.swift`:

```swift
import Foundation

public struct CommitMessage: Sendable, Equatable {
    public let subject: String
    public let body: String?

    public init(subject: String, body: String?) {
        self.subject = subject
        self.body = body
    }

    /// The message as git should receive it.
    public var full: String {
        guard let body, !body.isEmpty else { return subject }
        return subject + "\n\n" + body
    }
}

public enum ResponseError: Error, Equatable {
    case empty
}

public enum ResponseParser {

    /// Matches an opening conversational line — "Here's the commit message:".
    /// Deliberately narrow so a real subject like `feat: add x` is never eaten.
    private static let preamble = try! Regex(
        #"(?i)^(sure|certainly|okay|ok|here'?s|here is)\b[^\n]*:$"#
    )

    public static func commitMessage(from raw: String) throws -> CommitMessage {
        let text = stripPreamble(stripFences(raw))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ResponseError.empty }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let subject = String(lines[0]).trimmingCharacters(in: .whitespaces)
        guard !subject.isEmpty else { throw ResponseError.empty }

        let body = lines.dropFirst()
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return CommitMessage(subject: subject, body: body.isEmpty ? nil : body)
    }

    public static func stripFences(_ raw: String) -> String {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        let isFence = { (line: Substring) in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
        }
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              isFence(lines[first]) else { return raw }

        let remainder = lines[(first + 1)...]
        guard let closing = remainder.lastIndex(where: isFence) else { return raw }

        return remainder[..<closing]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }

    private static func stripPreamble(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        while let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                lines.removeFirst()
            } else if trimmed.wholeMatch(of: preamble) != nil {
                lines.removeFirst()
            } else {
                break
            }
        }
        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ResponseParserTests`
Expected: PASS, 20 test cases across 8 functions.

- [ ] **Step 5: Stage for review**

```bash
git add Sources/GitThatKit/ResponseParser.swift Tests/GitThatKitTests/ResponseParserTests.swift
# Do not commit. Stop here and report — the human commits at this boundary.
```

---

### Task 7: Provider protocol, CLIProvider, and StubProvider

The single seam where non-determinism enters. `CLIProvider` spawns a configured command; `StubProvider` replaces it in every other test.

**Files:**
- Create: `Sources/GitThatKit/Provider.swift`
- Create: `Tests/GitThatKitTests/Support/StubProvider.swift`
- Test: `Tests/GitThatKitTests/ProviderTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `protocol Provider: Sendable { func complete(_ prompt: String) async throws -> String }`, `struct CLIProvider: Provider` with `init(command: [String], timeout: Duration)`, `enum ProviderError: Error, Equatable { case notFound(command: String), timedOut(seconds: Int), failed(exitCode: Int32, stderr: String), empty }`, and test helper `StubProvider` with `init(responses: [String])`, `init(error: ProviderError)`, and `var receivedPrompts: [String]`.

- [ ] **Step 1: Write the stub**

`Tests/GitThatKitTests/Support/StubProvider.swift`:

```swift
import Foundation
@testable import GitThatKit

/// Returns queued responses and records the prompts it was given.
///
/// Queued responses are consumed in order. When the queue empties, the last
/// response repeats — so a single-response stub answers any number of calls.
final class StubProvider: Provider, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String]
    private var error: ProviderError?
    private(set) var receivedPrompts: [String] = []

    init(responses: [String]) {
        self.responses = responses
    }

    init(response: String) {
        self.responses = [response]
    }

    init(error: ProviderError) {
        self.responses = []
        self.error = error
    }

    var callCount: Int {
        lock.withLock { receivedPrompts.count }
    }

    func complete(_ prompt: String) async throws -> String {
        try lock.withLock {
            receivedPrompts.append(prompt)
            if let error { throw error }
            guard !responses.isEmpty else { return "" }
            return responses.count == 1 ? responses[0] : responses.removeFirst()
        }
    }
}
```

- [ ] **Step 2: Write the failing test**

`Tests/GitThatKitTests/ProviderTests.swift`:

```swift
import Foundation
import Testing
@testable import GitThatKit

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

@Test func killsACommandThatOverrunsItsTimeout() async {
    let provider = CLIProvider(command: ["sleep", "30"], timeout: .seconds(1))
    let started = Date()

    await #expect(throws: ProviderError.timedOut(seconds: 1)) {
        try await provider.complete("anything")
    }

    // The point is that it did not wait 30 seconds.
    #expect(Date().timeIntervalSince(started) < 5)
}

@Test func stubRecordsPromptsAndReturnsQueuedResponses() async throws {
    let stub = StubProvider(responses: ["first", "second"])

    #expect(try await stub.complete("prompt one") == "first")
    #expect(try await stub.complete("prompt two") == "second")
    #expect(stub.receivedPrompts == ["prompt one", "prompt two"])
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter ProviderTests`
Expected: FAIL — `cannot find 'CLIProvider' in scope`.

- [ ] **Step 4: Implement the provider**

`Sources/GitThatKit/Provider.swift`:

```swift
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
        process.standardOutput = try FileHandle(forWritingTo: outputURL)
        process.standardError = try FileHandle(forWritingTo: errorURL)

        let inputPipe = Pipe()
        process.standardInput = inputPipe

        do {
            try process.run()
        } catch {
            throw ProviderError.notFound(command: executable)
        }

        inputPipe.fileHandleForWriting.write(Data(prompt.utf8))
        try? inputPipe.fileHandleForWriting.close()

        try await waitForExit(of: process)

        let stderr = Self.read(errorURL)
        guard process.terminationStatus == 0 else {
            throw ProviderError.failed(exitCode: process.terminationStatus, stderr: stderr)
        }

        let output = Self.read(outputURL)
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.empty
        }
        return output
    }

    /// Waits for the process, terminating it if it overruns the timeout.
    private func waitForExit(of process: Process) async throws {
        let seconds = Int(timeout.components.seconds)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    // waitUntilExit blocks, so it runs off the cooperative pool.
                    DispatchQueue.global().async {
                        process.waitUntilExit()
                        continuation.resume()
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                if process.isRunning { process.terminate() }
                throw ProviderError.timedOut(seconds: seconds)
            }

            // Whichever finishes first decides the outcome.
            try await group.next()
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
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter ProviderTests`
Expected: PASS, 7 tests. The timeout test takes about one second; the rest are immediate.

- [ ] **Step 6: Stage for review**

```bash
git add Sources/GitThatKit/Provider.swift Tests/GitThatKitTests/
# Do not commit. Stop here and report — the human commits at this boundary.
```

---

### Task 8: Configuration

**Files:**
- Create: `Sources/GitThatKit/Config.swift`
- Test: `Tests/GitThatKitTests/ConfigTests.swift`

**Interfaces:**
- Consumes: `StyleSetting` (Task 4), `SubjectCaseSetting` (Task 3).
- Produces: `struct Config: Sendable, Equatable` with fields `provider: String`, `providers: [String: ProviderConfig]`, `commit: CommitConfig`, `rewrite: RewriteConfig`; `struct ProviderConfig: Sendable, Equatable { let command: [String]; let timeout: Int }`; `struct CommitConfig: Sendable, Equatable { let style: StyleSetting; let subjectCase: SubjectCaseSetting; let maxSubject: Int }`; `struct RewriteConfig: Sendable, Equatable { let autostash: Bool; let verify: String? }`. Static members: `Config.defaults`, `Config.load(globalPath:repositoryPath:) throws -> Config`, `Config.parse(_ toml: String) throws -> Config`, and `func resolvedProvider() throws -> ProviderConfig`.

- [ ] **Step 1: Write the failing test**

`Tests/GitThatKitTests/ConfigTests.swift`:

```swift
import Foundation
import Testing
@testable import GitThatKit

private func writeTemporary(_ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gitthat-config-\(UUID().uuidString).toml")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Test func defaultsApplyWhenNothingIsConfigured() throws {
    let config = try Config.load(globalPath: nil, repositoryPath: nil)

    #expect(config.commit.style == .auto)
    #expect(config.commit.subjectCase == .lower)
    #expect(config.commit.maxSubject == 72)
    #expect(config.rewrite.autostash == false)
    #expect(config.rewrite.verify == nil)
}

@Test func parsesAFullConfiguration() throws {
    let config = try Config.parse("""
        provider = "claude"

        [providers.claude]
        command = ["claude", "-p"]
        timeout = 60

        [commit]
        style = "conventional"
        subject_case = "preserve"
        max_subject = 50

        [rewrite]
        autostash = true
        verify = "swift test"
        """)

    #expect(config.provider == "claude")
    #expect(config.providers["claude"]?.command == ["claude", "-p"])
    #expect(config.providers["claude"]?.timeout == 60)
    #expect(config.commit.style == .conventional)
    #expect(config.commit.subjectCase == .preserve)
    #expect(config.commit.maxSubject == 50)
    #expect(config.rewrite.autostash == true)
    #expect(config.rewrite.verify == "swift test")
}

@Test func partialConfigurationKeepsDefaultsForEverythingElse() throws {
    let config = try Config.parse("""
        [commit]
        style = "plain"
        """)

    #expect(config.commit.style == .plain)
    #expect(config.commit.subjectCase == .lower)     // default survives
    #expect(config.commit.maxSubject == 72)          // default survives
}

@Test func repositoryConfigurationOverlaysGlobalPerKey() throws {
    let global = try writeTemporary("""
        provider = "claude"

        [providers.claude]
        command = ["claude", "-p"]
        timeout = 60

        [commit]
        style = "auto"
        max_subject = 72
        """)
    let repository = try writeTemporary("""
        [commit]
        style = "conventional"
        """)
    defer {
        try? FileManager.default.removeItem(at: global)
        try? FileManager.default.removeItem(at: repository)
    }

    let config = try Config.load(globalPath: global, repositoryPath: repository)

    #expect(config.commit.style == .conventional)         // overlaid
    #expect(config.commit.maxSubject == 72)               // inherited from global
    #expect(config.provider == "claude")                  // inherited from global
    #expect(config.providers["claude"]?.timeout == 60)    // inherited from global
}

@Test func missingFilesAreNotAnError() throws {
    let absent = URL(fileURLWithPath: "/tmp/gitthat-does-not-exist-\(UUID().uuidString).toml")
    let config = try Config.load(globalPath: absent, repositoryPath: absent)
    #expect(config == Config.defaults)
}

@Test func resolvesTheSelectedProvider() throws {
    let config = try Config.parse("""
        provider = "ollama"

        [providers.ollama]
        command = ["ollama", "run", "qwen2.5-coder"]
        timeout = 120
        """)

    let resolved = try config.resolvedProvider()
    #expect(resolved.command == ["ollama", "run", "qwen2.5-coder"])
    #expect(resolved.timeout == 120)
}

@Test func reportsAnUnknownProviderSelection() throws {
    let config = try Config.parse("""
        provider = "nope"

        [providers.claude]
        command = ["claude", "-p"]
        """)

    #expect(throws: ConfigError.unknownProvider(name: "nope", available: ["claude"])) {
        try config.resolvedProvider()
    }
}

@Test func rejectsMalformedToml() {
    #expect(throws: (any Error).self) {
        try Config.parse("this is = = not toml")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ConfigTests`
Expected: FAIL — `cannot find 'Config' in scope`.

- [ ] **Step 3: Implement configuration**

`Sources/GitThatKit/Config.swift`:

```swift
import Foundation
import TOMLKit

public enum ConfigError: Error, Equatable {
    case unknownProvider(name: String, available: [String])
    case malformed(String)
}

public struct ProviderConfig: Sendable, Equatable {
    public let command: [String]
    public let timeout: Int

    public init(command: [String], timeout: Int = 60) {
        self.command = command
        self.timeout = timeout
    }
}

public struct CommitConfig: Sendable, Equatable {
    public let style: StyleSetting
    public let subjectCase: SubjectCaseSetting
    public let maxSubject: Int

    // Explicit and public: the synthesized memberwise init is internal, and the
    // executable target constructs these to apply --conventional / --plain.
    public init(style: StyleSetting, subjectCase: SubjectCaseSetting, maxSubject: Int) {
        self.style = style
        self.subjectCase = subjectCase
        self.maxSubject = maxSubject
    }
}

public struct RewriteConfig: Sendable, Equatable {
    public let autostash: Bool
    public let verify: String?

    public init(autostash: Bool, verify: String?) {
        self.autostash = autostash
        self.verify = verify
    }
}

public struct Config: Sendable, Equatable {
    public let provider: String
    public let providers: [String: ProviderConfig]
    public let commit: CommitConfig
    public let rewrite: RewriteConfig

    public init(
        provider: String,
        providers: [String: ProviderConfig],
        commit: CommitConfig,
        rewrite: RewriteConfig
    ) {
        self.provider = provider
        self.providers = providers
        self.commit = commit
        self.rewrite = rewrite
    }

    public static let defaults = Config(
        provider: "claude",
        providers: ["claude": ProviderConfig(command: ["claude", "-p"], timeout: 60)],
        commit: CommitConfig(style: .auto, subjectCase: .lower, maxSubject: 72),
        rewrite: RewriteConfig(autostash: false, verify: nil)
    )

    /// Loads global defaults and overlays the repository file on top, per key.
    /// A missing file contributes nothing and is not an error.
    public static func load(globalPath: URL?, repositoryPath: URL?) throws -> Config {
        var config = Config.defaults
        for path in [globalPath, repositoryPath] {
            guard let path, let text = try? String(contentsOf: path, encoding: .utf8) else {
                continue
            }
            config = try overlay(text, onto: config)
        }
        return config
    }

    public static func parse(_ toml: String) throws -> Config {
        try overlay(toml, onto: .defaults)
    }

    private static func overlay(_ toml: String, onto base: Config) throws -> Config {
        let table: TOMLTable
        do {
            table = try TOMLTable(string: toml)
        } catch {
            throw ConfigError.malformed(String(describing: error))
        }

        var providers = base.providers
        if let declared = table["providers"]?.table {
            for key in declared.keys {
                guard let entry = declared[key]?.table else { continue }
                let command = entry["command"]?.array?.compactMap(\.string)
                    ?? providers[key]?.command
                    ?? []
                let timeout = entry["timeout"]?.int ?? providers[key]?.timeout ?? 60
                providers[key] = ProviderConfig(command: command, timeout: timeout)
            }
        }

        let commitTable = table["commit"]?.table
        let commit = CommitConfig(
            style: commitTable?["style"]?.string
                .flatMap(StyleSetting.init(rawValue:)) ?? base.commit.style,
            subjectCase: commitTable?["subject_case"]?.string
                .flatMap(SubjectCaseSetting.init(rawValue:)) ?? base.commit.subjectCase,
            maxSubject: commitTable?["max_subject"]?.int ?? base.commit.maxSubject
        )

        let rewriteTable = table["rewrite"]?.table
        let verifyValue = rewriteTable?["verify"]?.string
        let rewrite = RewriteConfig(
            autostash: rewriteTable?["autostash"]?.bool ?? base.rewrite.autostash,
            // An empty string means "unset", so a config file can disable an
            // inherited verify command.
            verify: verifyValue.map { $0.isEmpty ? nil : $0 } ?? base.rewrite.verify
        )

        return Config(
            provider: table["provider"]?.string ?? base.provider,
            providers: providers,
            commit: commit,
            rewrite: rewrite
        )
    }

    public func resolvedProvider() throws -> ProviderConfig {
        guard let resolved = providers[provider] else {
            throw ConfigError.unknownProvider(name: provider, available: providers.keys.sorted())
        }
        return resolved
    }

    /// `~/.config/gitthat/config.toml`
    public static func defaultGlobalPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/gitthat/config.toml")
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ConfigTests`
Expected: PASS, 8 tests.

TOMLKit's accessor names may differ slightly from `.table`, `.array`, `.string`, `.int`, `.bool`. If the build fails, read the TOMLKit API and adjust the accessors only — the structure and defaults must not change.

- [ ] **Step 5: Stage for review**

```bash
git add Sources/GitThatKit/Config.swift Tests/GitThatKitTests/ConfigTests.swift
# Do not commit. Stop here and report — the human commits at this boundary.
```

---

### Task 9: Prompt construction

**Files:**
- Create: `Sources/GitThatKit/Prompts.swift`
- Test: `Tests/GitThatKitTests/PromptsTests.swift`

**Interfaces:**
- Consumes: `StagedDiff` (Task 2), `CommitStyle` (Task 4).
- Produces: `struct CommitPromptInput: Sendable { let diff: StagedDiff; let recentSubjects: [String]; let style: CommitStyle; let ticket: String?; let maxSubject: Int }` and `enum Prompts { static func commitMessage(_ input: CommitPromptInput) -> String }`.

- [ ] **Step 1: Write the failing test**

`Tests/GitThatKitTests/PromptsTests.swift`:

```swift
import Testing
@testable import GitThatKit

private func input(
    diff: String = "diff --git a/a.txt b/a.txt\n+hello",
    truncated: Bool = false,
    subjects: [String] = ["feat: add a thing", "fix: correct a thing"],
    style: CommitStyle = .conventional,
    ticket: String? = nil,
    maxSubject: Int = 72
) -> CommitPromptInput {
    CommitPromptInput(
        diff: StagedDiff(text: diff, wasTruncated: truncated),
        recentSubjects: subjects,
        style: style,
        ticket: ticket,
        maxSubject: maxSubject
    )
}

@Test func includesTheDiff() {
    let prompt = Prompts.commitMessage(input(diff: "UNIQUE_DIFF_MARKER"))
    #expect(prompt.contains("UNIQUE_DIFF_MARKER"))
}

@Test func includesRecentSubjectsAsStyleExamples() {
    let prompt = Prompts.commitMessage(input(subjects: ["feat: add a thing"]))
    #expect(prompt.contains("feat: add a thing"))
}

@Test func statesTheCasingRule() {
    let prompt = Prompts.commitMessage(input())
    #expect(prompt.lowercased().contains("lowercase"))
    #expect(prompt.contains("WIP"))       // the worked example from the spec
    #expect(prompt.contains("DNS"))
}

@Test func asksForConventionalCommitsWhenThatIsTheStyle() {
    let prompt = Prompts.commitMessage(input(style: .conventional))
    #expect(prompt.contains("type(scope): description"))
}

@Test func doesNotAskForConventionalCommitsWhenStyleIsPlain() {
    let prompt = Prompts.commitMessage(input(style: .plain))
    #expect(!prompt.contains("type(scope): description"))
}

@Test func includesTheTicketWhenThereIsOne() {
    let prompt = Prompts.commitMessage(input(ticket: "PROJ-421"))
    #expect(prompt.contains("PROJ-421"))
}

@Test func omitsTicketInstructionsWhenThereIsNone() {
    let prompt = Prompts.commitMessage(input(ticket: nil))
    #expect(!prompt.lowercased().contains("ticket"))
}

@Test func saysWhenTheDiffWasTruncated() {
    let full = Prompts.commitMessage(input(truncated: false))
    let cut = Prompts.commitMessage(input(truncated: true))

    #expect(!full.lowercased().contains("truncated"))
    #expect(cut.lowercased().contains("truncated"))
}

@Test func statesTheSubjectLengthLimit() {
    let prompt = Prompts.commitMessage(input(maxSubject: 50))
    #expect(prompt.contains("50"))
}

@Test func asksForNothingButTheMessage() {
    let prompt = Prompts.commitMessage(input())
    #expect(prompt.lowercased().contains("no explanation"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PromptsTests`
Expected: FAIL — `cannot find 'Prompts' in scope`.

- [ ] **Step 3: Implement prompt construction**

`Sources/GitThatKit/Prompts.swift`:

```swift
import Foundation

public struct CommitPromptInput: Sendable {
    public let diff: StagedDiff
    public let recentSubjects: [String]
    public let style: CommitStyle
    public let ticket: String?
    public let maxSubject: Int

    public init(
        diff: StagedDiff,
        recentSubjects: [String],
        style: CommitStyle,
        ticket: String?,
        maxSubject: Int
    ) {
        self.diff = diff
        self.recentSubjects = recentSubjects
        self.style = style
        self.ticket = ticket
        self.maxSubject = maxSubject
    }
}

public enum Prompts {

    public static func commitMessage(_ input: CommitPromptInput) -> String {
        var sections: [String] = []

        sections.append("""
            Write a git commit message for the staged changes below.

            Rules:
            - The subject line is at most \(input.maxSubject) characters.
            - Every word in the subject is either entirely lowercase or entirely \
            uppercase. Never capitalise only the first letter of a word.
              Correct:   WIP working on DNS improvement ASAP
              Incorrect: WIP Working on DNS Improvement ASAP
            - Describe what the change does, not which files moved.
            - Add a body only when the reason is not obvious from the subject. \
            Separate it from the subject with a blank line.
            - Reply with the commit message and nothing else. No explanation, no \
            code fences, no preamble.
            """)

        if input.style == .conventional {
            sections.append("""
                Use Conventional Commits: type(scope): description
                The type is one of feat, fix, docs, style, refactor, test, chore. \
                The scope is optional and omitted when the change spans unrelated areas.
                """)
        }

        if let ticket = input.ticket {
            sections.append("""
                This branch carries the ticket \(ticket), and this repository's \
                history includes ticket IDs. Include it in the subject.
                """)
        }

        if !input.recentSubjects.isEmpty {
            sections.append("""
                Recent commit subjects from this repository, to match their style:

                \(input.recentSubjects.map { "- \($0)" }.joined(separator: "\n"))
                """)
        }

        if input.diff.wasTruncated {
            sections.append("""
                The diff below was truncated because it is large. Describe the \
                change as a whole rather than only the part shown.
                """)
        }

        sections.append("""
            Staged changes:

            \(input.diff.text)
            """)

        return sections.joined(separator: "\n\n")
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PromptsTests`
Expected: PASS, 10 tests.

- [ ] **Step 5: Stage for review**

```bash
git add Sources/GitThatKit/Prompts.swift Tests/GitThatKitTests/PromptsTests.swift
# Do not commit. Stop here and report — the human commits at this boundary.
```

---

### Task 10: Terminal output and confirmation

`UI` is split behind a protocol so the commit flow can be tested without a terminal.

**Files:**
- Create: `Sources/GitThatKit/UI.swift`
- Test: `Tests/GitThatKitTests/UITests.swift`

**Interfaces:**
- Consumes: `CommitMessage` (Task 6).
- Produces: `enum CommitChoice: Sendable, Equatable { case accept, edit, regenerate, cancel }`, `protocol UserInterface: Sendable` with `func show(_ text: String)`, `func askCommitChoice() -> CommitChoice`, `func askStyle() -> CommitStyle`, `func confirm(_ question: String) -> Bool`, `func edit(_ text: String) throws -> String`; `struct TerminalUI: UserInterface`; `enum Render { static func commitPreview(_ message: CommitMessage, branch: String?) -> String }`; and test double `RecordingUI`.

- [ ] **Step 1: Write the failing test**

`Tests/GitThatKitTests/UITests.swift`:

```swift
import Foundation
import Testing
@testable import GitThatKit

/// A scripted interface. Answers come from queues; output is recorded.
final class RecordingUI: UserInterface, @unchecked Sendable {
    private let lock = NSLock()
    private var commitChoices: [CommitChoice]
    private var styleChoices: [CommitStyle]
    private var confirmations: [Bool]
    var editResult: String?
    private(set) var shown: [String] = []
    private(set) var questions: [String] = []

    init(
        commitChoices: [CommitChoice] = [.accept],
        styleChoices: [CommitStyle] = [.conventional],
        confirmations: [Bool] = [true]
    ) {
        self.commitChoices = commitChoices
        self.styleChoices = styleChoices
        self.confirmations = confirmations
    }

    func show(_ text: String) { lock.withLock { shown.append(text) } }

    func askCommitChoice() -> CommitChoice {
        lock.withLock { commitChoices.count > 1 ? commitChoices.removeFirst() : commitChoices[0] }
    }

    func askStyle() -> CommitStyle {
        lock.withLock { styleChoices.count > 1 ? styleChoices.removeFirst() : styleChoices[0] }
    }

    func confirm(_ question: String) -> Bool {
        lock.withLock {
            questions.append(question)
            return confirmations.count > 1 ? confirmations.removeFirst() : confirmations[0]
        }
    }

    func edit(_ text: String) throws -> String { editResult ?? text }

    var allOutput: String { lock.withLock { shown.joined(separator: "\n") } }
}

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

    for word in ["rebase", "squash", "fixup"] {
        #expect(!rendered.contains(word))
    }
}

@Test func recordingInterfaceReturnsQueuedAnswers() {
    let ui = RecordingUI(commitChoices: [.regenerate, .accept])
    #expect(ui.askCommitChoice() == .regenerate)
    #expect(ui.askCommitChoice() == .accept)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter UITests`
Expected: FAIL — `cannot find 'UserInterface' in scope`.

- [ ] **Step 3: Implement the interface and renderer**

`Sources/GitThatKit/UI.swift`:

```swift
import Foundation

public enum CommitChoice: Sendable, Equatable {
    case accept
    case edit
    case regenerate
    case cancel
}

public enum UIError: Error, Equatable {
    case editorFailed(String)
}

public protocol UserInterface: Sendable {
    func show(_ text: String)
    func askCommitChoice() -> CommitChoice
    func askStyle() -> CommitStyle
    func confirm(_ question: String) -> Bool
    func edit(_ text: String) throws -> String
}

public enum Render {
    static let dim = "\u{001B}[2m"
    static let bold = "\u{001B}[1m"
    static let reset = "\u{001B}[0m"

    public static func commitPreview(_ message: CommitMessage, branch: String?) -> String {
        var lines: [String] = []
        if let branch {
            lines.append("\(dim)⎇  \(branch)\(reset)")
            lines.append("")
        }
        lines.append("   \(bold)\(message.subject)\(reset)")
        if let body = message.body, !body.isEmpty {
            lines.append("")
            for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("   \(line)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

public struct TerminalUI: UserInterface {
    public init() {}

    public func show(_ text: String) {
        print(text)
    }

    public func askCommitChoice() -> CommitChoice {
        while true {
            print("\n   [a]ccept  [e]dit  [r]egenerate  [c]ancel: ", terminator: "")
            switch readLine()?.trimmingCharacters(in: .whitespaces).lowercased() {
            case "a", "": return .accept
            case "e": return .edit
            case "r": return .regenerate
            case "c": return .cancel
            default: print("   Please answer a, e, r, or c.")
            }
        }
    }

    public func askStyle() -> CommitStyle {
        print("""

            This repository's history does not settle the question.
            Which commit message style should GITTHAT use here?

              [1] conventional   feat(auth): add token refresh
              [2] plain          add token refresh

            The answer is saved to ./.gitthat.toml, so this is asked once.
            """)
        while true {
            print("\n   [1/2]: ", terminator: "")
            switch readLine()?.trimmingCharacters(in: .whitespaces) {
            case "1", "": return .conventional
            case "2": return .plain
            default: print("   Please answer 1 or 2.")
            }
        }
    }

    public func confirm(_ question: String) -> Bool {
        print("\n   \(question) [y/N]: ", terminator: "")
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }

    /// Writes the text to a temp file, opens `$EDITOR` on it, and returns what
    /// the user saved.
    public func edit(_ text: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("COMMIT_EDITMSG-\(UUID().uuidString)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "vi"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sh", "-c", "\(editor) \"$1\"", "sh", url.path]

        do {
            try process.run()
        } catch {
            throw UIError.editorFailed(editor)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw UIError.editorFailed("\(editor) exited \(process.terminationStatus)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter UITests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Stage for review**

```bash
git add Sources/GitThatKit/UI.swift Tests/GitThatKitTests/UITests.swift
# Do not commit. Stop here and report — the human commits at this boundary.
```

---

### Task 11: The commit flow and the `commit` subcommand

Everything wires together here. The flow lives in `GitThatKit` so it can be tested; the subcommand only constructs it.

**Files:**
- Create: `Sources/GitThatKit/CommitFlow.swift`
- Create: `Sources/gitthat/CommitCommand.swift`
- Modify: `Sources/gitthat/GitThat.swift`
- Test: `Tests/GitThatKitTests/CommitFlowTests.swift`

**Interfaces:**
- Consumes: `Git`, `Provider`, `Config`, `UserInterface`, `Prompts`, `ResponseParser`, `SubjectCase`, `StyleInference`, `TicketID`.
- Produces: `struct CommitFlow` with `init(git: Git, provider: Provider, config: Config, ui: UserInterface, repositoryConfigPath: URL?)` and `func run() async throws -> CommitOutcome`; `enum CommitOutcome: Sendable, Equatable { case committed(sha: String), cancelled, nothingToCommit }`; `enum CommitFlowError: Error, Equatable { case notARepository }`.

- [ ] **Step 1: Write the failing test**

`Tests/GitThatKitTests/CommitFlowTests.swift`:

```swift
import Foundation
import Testing
@testable import GitThatKit

private func flow(
    repo: RepoFixture,
    provider: Provider,
    ui: UserInterface,
    style: StyleSetting = .conventional,
    subjectCase: SubjectCaseSetting = .lower
) -> CommitFlow {
    let config = Config(
        provider: "stub",
        providers: ["stub": ProviderConfig(command: ["true"], timeout: 60)],
        commit: CommitConfig(style: style, subjectCase: subjectCase, maxSubject: 72),
        rewrite: RewriteConfig(autostash: false, verify: nil)
    )
    return CommitFlow(git: repo.git, provider: provider, config: config,
                      ui: ui, repositoryConfigPath: nil)
}

@Test func commitsAnAcceptedMessage() async throws {
    let repo = RepoFixture()
        .commit("chore: initial", file: "a.txt", contents: "1")
        .stage(file: "b.txt", contents: "2")
    let provider = StubProvider(response: "feat: add token refresh")
    let ui = RecordingUI(commitChoices: [.accept])

    let outcome = try await flow(repo: repo, provider: provider, ui: ui).run()

    guard case .committed(let sha) = outcome else {
        Issue.record("expected a commit, got \(outcome)")
        return
    }
    #expect(sha.count == 40)
    #expect(repo.subjects().first == "feat: add token refresh")
}

@Test func appliesTheCasingRuleToTheAgentsOutput() async throws {
    let repo = RepoFixture()
        .commit("chore: initial", file: "a.txt", contents: "1")
        .stage(file: "b.txt", contents: "2")
    let provider = StubProvider(response: "feat: Add DNS Support For iOS")
    let ui = RecordingUI(commitChoices: [.accept])

    _ = try await flow(repo: repo, provider: provider, ui: ui).run()

    #expect(repo.subjects().first == "feat: add DNS support for iOS")
}

@Test func casingIsNotAppliedWhenSetToPreserve() async throws {
    let repo = RepoFixture()
        .commit("chore: initial", file: "a.txt", contents: "1")
        .stage(file: "b.txt", contents: "2")
    let provider = StubProvider(response: "feat: Add DNS Support")
    let ui = RecordingUI(commitChoices: [.accept])

    _ = try await flow(repo: repo, provider: provider, ui: ui, subjectCase: .preserve).run()

    #expect(repo.subjects().first == "feat: Add DNS Support")
}

@Test func stripsFencesBeforeCommitting() async throws {
    let repo = RepoFixture()
        .commit("chore: initial", file: "a.txt", contents: "1")
        .stage(file: "b.txt", contents: "2")
    let provider = StubProvider(response: "```\nfeat: add token refresh\n```")
    let ui = RecordingUI(commitChoices: [.accept])

    _ = try await flow(repo: repo, provider: provider, ui: ui).run()

    #expect(repo.subjects().first == "feat: add token refresh")
}

@Test func regenerateAsksTheProviderAgain() async throws {
    let repo = RepoFixture()
        .commit("chore: initial", file: "a.txt", contents: "1")
        .stage(file: "b.txt", contents: "2")
    let provider = StubProvider(responses: ["feat: first attempt", "feat: second attempt"])
    let ui = RecordingUI(commitChoices: [.regenerate, .accept])

    _ = try await flow(repo: repo, provider: provider, ui: ui).run()

    #expect(provider.receivedPrompts.count == 2)
    #expect(repo.subjects().first == "feat: second attempt")
}

@Test func cancelCommitsNothing() async throws {
    let repo = RepoFixture()
        .commit("chore: initial", file: "a.txt", contents: "1")
        .stage(file: "b.txt", contents: "2")
    let provider = StubProvider(response: "feat: add token refresh")
    let ui = RecordingUI(commitChoices: [.cancel])

    let outcome = try await flow(repo: repo, provider: provider, ui: ui).run()

    #expect(outcome == .cancelled)
    #expect(repo.subjects() == ["chore: initial"])
}

@Test func editUsesWhateverTheEditorSaved() async throws {
    let repo = RepoFixture()
        .commit("chore: initial", file: "a.txt", contents: "1")
        .stage(file: "b.txt", contents: "2")
    let provider = StubProvider(response: "feat: generated subject")
    let ui = RecordingUI(commitChoices: [.edit, .accept])
    ui.editResult = "feat: hand written subject"

    _ = try await flow(repo: repo, provider: provider, ui: ui).run()

    #expect(repo.subjects().first == "feat: hand written subject")
}

@Test func offersToStageEverythingWhenNothingIsStaged() async throws {
    let repo = RepoFixture()
        .commit("chore: initial", file: "a.txt", contents: "1")
        .write(file: "b.txt", contents: "2")
    let provider = StubProvider(response: "feat: add token refresh")
    let ui = RecordingUI(commitChoices: [.accept], confirmations: [true])

    let outcome = try await flow(repo: repo, provider: provider, ui: ui).run()

    guard case .committed = outcome else {
        Issue.record("expected a commit, got \(outcome)")
        return
    }
    #expect(repo.subjects().first == "feat: add token refresh")
}

@Test func stopsWhenNothingIsStagedAndTheUserDeclinesToStage() async throws {
    let repo = RepoFixture()
        .commit("chore: initial", file: "a.txt", contents: "1")
        .write(file: "b.txt", contents: "2")
    let provider = StubProvider(response: "feat: add token refresh")
    let ui = RecordingUI(commitChoices: [.accept], confirmations: [false])

    let outcome = try await flow(repo: repo, provider: provider, ui: ui).run()

    #expect(outcome == .nothingToCommit)
    #expect(repo.subjects() == ["chore: initial"])
}

@Test func sendsTheDiffAndRecentSubjectsToTheProvider() async throws {
    let repo = RepoFixture()
        .commit("feat: earlier work", file: "a.txt", contents: "1")
        .stage(file: "unique-filename.txt", contents: "2")
    let provider = StubProvider(response: "feat: add token refresh")
    let ui = RecordingUI(commitChoices: [.accept])

    _ = try await flow(repo: repo, provider: provider, ui: ui).run()

    let prompt = try #require(provider.receivedPrompts.first)
    #expect(prompt.contains("unique-filename.txt"))
    #expect(prompt.contains("feat: earlier work"))
}

@Test func includesTheTicketWhenBranchAndHistoryBothUseThem() async throws {
    let repo = RepoFixture()
        .commit("PROJ-1 earlier work", file: "a.txt", contents: "1")
        .checkout(branch: "feature/PROJ-421-sso")
        .stage(file: "b.txt", contents: "2")
    let provider = StubProvider(response: "feat: add token refresh")
    let ui = RecordingUI(commitChoices: [.accept])

    _ = try await flow(repo: repo, provider: provider, ui: ui).run()

    let prompt = try #require(provider.receivedPrompts.first)
    #expect(prompt.contains("PROJ-421"))
}

@Test func asksForStyleWhenHistoryIsAmbiguous() async throws {
    let repo = RepoFixture()
        .commit("feat: one", file: "a.txt", contents: "1")
        .stage(file: "b.txt", contents: "2")
    let provider = StubProvider(response: "feat: add token refresh")
    let ui = RecordingUI(commitChoices: [.accept], styleChoices: [.plain])

    // Only one prior commit, so inference cannot settle it.
    _ = try await flow(repo: repo, provider: provider, ui: ui, style: .auto).run()

    let prompt = try #require(provider.receivedPrompts.first)
    #expect(!prompt.contains("type(scope): description"))
}

@Test func doesNotAskForStyleWhenConfigured() async throws {
    let repo = RepoFixture()
        .commit("feat: one", file: "a.txt", contents: "1")
        .stage(file: "b.txt", contents: "2")
    let provider = StubProvider(response: "feat: add token refresh")
    let ui = RecordingUI(commitChoices: [.accept])

    _ = try await flow(repo: repo, provider: provider, ui: ui, style: .conventional).run()

    let prompt = try #require(provider.receivedPrompts.first)
    #expect(prompt.contains("type(scope): description"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter CommitFlowTests`
Expected: FAIL — `cannot find 'CommitFlow' in scope`.

- [ ] **Step 3: Implement the flow**

`Sources/GitThatKit/CommitFlow.swift`:

```swift
import Foundation

public enum CommitOutcome: Sendable, Equatable {
    case committed(sha: String)
    case cancelled
    case nothingToCommit
}

public enum CommitFlowError: Error, Equatable {
    case notARepository
}

/// The oracle loop for `gitthat commit`: gather, ask, parse, enforce, preview,
/// confirm, commit. Every git command is run here, never by the agent.
public struct CommitFlow {
    private let git: Git
    private let provider: Provider
    private let config: Config
    private let ui: UserInterface
    private let repositoryConfigPath: URL?

    public init(
        git: Git,
        provider: Provider,
        config: Config,
        ui: UserInterface,
        repositoryConfigPath: URL?
    ) {
        self.git = git
        self.provider = provider
        self.config = config
        self.ui = ui
        self.repositoryConfigPath = repositoryConfigPath
    }

    public func run() async throws -> CommitOutcome {
        guard git.isRepository() else { throw CommitFlowError.notARepository }

        guard try ensureSomethingIsStaged() else { return .nothingToCommit }

        let diff = try git.stagedDiff(limit: 8192)
        let subjects = try git.recentSubjects(20)
        let branch = try git.currentBranch()
        let style = resolveStyle(from: subjects)

        let ticket = TicketID.appearsIn(subjects: subjects)
            ? TicketID.extract(fromBranch: branch)
            : nil

        let input = CommitPromptInput(
            diff: diff,
            recentSubjects: subjects,
            style: style,
            ticket: ticket,
            maxSubject: config.commit.maxSubject
        )
        let prompt = Prompts.commitMessage(input)

        var message = try await generate(prompt: prompt)

        while true {
            ui.show(Render.commitPreview(message, branch: branch))

            switch ui.askCommitChoice() {
            case .accept:
                return .committed(sha: try git.commit(message: message.full))

            case .edit:
                let edited = try ui.edit(message.full)
                message = enforce(try ResponseParser.commitMessage(from: edited))

            case .regenerate:
                message = try await generate(prompt: prompt)

            case .cancel:
                return .cancelled
            }
        }
    }

    /// Returns false when there is nothing to commit and the user declined to
    /// stage everything.
    private func ensureSomethingIsStaged() throws -> Bool {
        if try git.hasStagedChanges() { return true }
        guard ui.confirm("Nothing is staged. Stage everything?") else { return false }
        try git.stageAll()
        return try git.hasStagedChanges()
    }

    private func resolveStyle(from subjects: [String]) -> CommitStyle {
        switch config.commit.style {
        case .conventional: return .conventional
        case .plain: return .plain
        case .auto:
            if let inferred = StyleInference.infer(from: subjects) { return inferred }
            let chosen = ui.askStyle()
            persist(style: chosen)
            return chosen
        }
    }

    /// Writes the chosen style to the repository config so the question is
    /// asked at most once per repository.
    private func persist(style: CommitStyle) {
        guard let path = repositoryConfigPath else { return }
        let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        let addition = "\n[commit]\nstyle = \"\(style.rawValue)\"\n"
        try? (existing + addition).write(to: path, atomically: true, encoding: .utf8)
    }

    private func generate(prompt: String) async throws -> CommitMessage {
        let raw = try await provider.complete(prompt)
        return enforce(try ResponseParser.commitMessage(from: raw))
    }

    private func enforce(_ message: CommitMessage) -> CommitMessage {
        CommitMessage(
            subject: SubjectCase.enforce(message.subject, setting: config.commit.subjectCase),
            body: message.body
        )
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter CommitFlowTests`
Expected: PASS, 13 tests.

- [ ] **Step 5: Wire the subcommand**

`Sources/gitthat/CommitCommand.swift`:

```swift
import ArgumentParser
import Foundation
import GitThatKit

struct CommitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "commit",
        abstract: "Write a commit message for the staged changes."
    )

    @Flag(name: .long, help: "Force Conventional Commits for this run.")
    var conventional = false

    @Flag(name: .long, help: "Force a plain subject line for this run.")
    var plain = false

    mutating func run() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let repositoryConfig = directory.appendingPathComponent(".gitthat.toml")

        var config = try Config.load(
            globalPath: Config.defaultGlobalPath(),
            repositoryPath: repositoryConfig
        )

        if conventional || plain {
            config = Config(
                provider: config.provider,
                providers: config.providers,
                commit: CommitConfig(
                    style: conventional ? .conventional : .plain,
                    subjectCase: config.commit.subjectCase,
                    maxSubject: config.commit.maxSubject
                ),
                rewrite: config.rewrite
            )
        }

        let providerConfig = try config.resolvedProvider()
        let flow = CommitFlow(
            git: Git(runner: SystemGitRunner(), directory: directory),
            provider: CLIProvider(
                command: providerConfig.command,
                timeout: .seconds(providerConfig.timeout)
            ),
            config: config,
            ui: TerminalUI(),
            repositoryConfigPath: repositoryConfig
        )

        switch try await flow.run() {
        case .committed(let sha):
            print("\n   ✓ committed \(sha.prefix(7))")
        case .cancelled:
            print("\n   nothing changed")
            throw ExitCode(1)
        case .nothingToCommit:
            print("\n   nothing to commit")
            throw ExitCode(1)
        }
    }
}
```

`Sources/gitthat/GitThat.swift` — replace the whole file:

```swift
import ArgumentParser

@main
struct GitThat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gitthat",
        abstract: "Rewrite history without remembering how.",
        subcommands: [CommitCommand.self]
    )
}
```

- [ ] **Step 6: Verify the binary works end to end**

```bash
swift build
cd /tmp && rm -rf gitthat-smoke && mkdir gitthat-smoke && cd gitthat-smoke
git init -q -b main && echo hello > a.txt && git add -A
```

Run: `/path/to/gitthat/.build/debug/gitthat commit`
Expected: it reads the staged diff, calls the configured agent CLI, shows a preview, and commits on `a`. If no agent CLI is configured it must fail with a clear message naming the missing command — not a crash.

- [ ] **Step 7: Stage for review**

```bash
git add Sources/ Tests/
# Do not commit. Stop here and report — the human commits at this boundary.
```

---

### Task 12: Vocabulary lint, history check, and spec correction

The naming rule is a product commitment, so something has to check it. This also fixes the spec contradiction found while writing Task 4.

**Files:**
- Create: `Tests/GitThatKitTests/VocabularyLintTests.swift`
- Create: `scripts/check-own-history.sh`
- Create: `.gitthat.toml`
- Modify: `docs/superpowers/specs/2026-08-13-gitthat-design.md`

**Interfaces:**
- Consumes: `Render` (Task 10), `Prompts` (Task 9), `ProviderError` (Task 7), `ConfigError` (Task 8), `GitError` (Task 2).
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Write the lint test**

`Tests/GitThatKitTests/VocabularyLintTests.swift`:

```swift
import Foundation
import Testing
@testable import GitThatKit

/// Git's internal vocabulary must not reach the user. Rebasing means moving
/// work onto a different base, which GITTHAT cannot do, and `squash`/`fixup`
/// are todo-file verbs the user never sees.
let forbiddenWords = ["rebase", "squash", "fixup"]

private func assertClean(_ text: String, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let lowered = text.lowercased()
    for word in forbiddenWords {
        #expect(!lowered.contains(word),
                "\(label) contains the forbidden word '\(word)'",
                sourceLocation: sourceLocation)
    }
}

@Test func commitPreviewIsClean() {
    let message = CommitMessage(subject: "feat: add a thing", body: "a body")
    assertClean(Render.commitPreview(message, branch: "feature/sso"), "commit preview")
}

@Test func commitPromptIsClean() {
    let input = CommitPromptInput(
        diff: StagedDiff(text: "diff", wasTruncated: true),
        recentSubjects: ["feat: a thing"],
        style: .conventional,
        ticket: "PROJ-1",
        maxSubject: 72
    )
    assertClean(Prompts.commitMessage(input), "commit prompt")
}

@Test(arguments: [
    ProviderError.notFound(command: "claude"),
    ProviderError.timedOut(seconds: 60),
    ProviderError.failed(exitCode: 1, stderr: "trouble"),
    ProviderError.empty,
])
func providerErrorsAreClean(error: ProviderError) {
    assertClean(String(describing: error), "provider error")
}

@Test func configErrorsAreClean() {
    assertClean(
        String(describing: ConfigError.unknownProvider(name: "nope", available: ["claude"])),
        "config error"
    )
}

@Test func sourceFilesContainNoForbiddenUserFacingStrings() throws {
    // Walks the source tree and flags string literals containing forbidden
    // words. Comments are exempt — they explain implementation, which is
    // allowed to name git's own concepts.
    let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // GitThatKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root
        .appendingPathComponent("Sources")

    let files = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" } ?? []

    #expect(!files.isEmpty, "found no source files to lint")

    for file in files {
        let contents = try String(contentsOf: file, encoding: .utf8)
        for (index, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { continue }
            guard trimmed.contains("\"") else { continue }

            let lowered = trimmed.lowercased()
            for word in forbiddenWords {
                #expect(!lowered.contains(word),
                        "\(file.lastPathComponent):\(index + 1) has a string containing '\(word)'")
            }
        }
    }
}
```

- [ ] **Step 2: Run the lint to verify it passes**

Run: `swift test --filter VocabularyLintTests`
Expected: PASS, 8 test cases. If it fails, the failure names the file, line, and word — fix the string rather than the test.

- [ ] **Step 3: Add the history check script**

`scripts/check-own-history.sh`:

```bash
#!/usr/bin/env bash
# Layer 7 — validates that this repository's own commit subjects satisfy the
# rules GITTHAT enforces. Run in CI.
set -euo pipefail

range="${1:-origin/main..HEAD}"
failed=0

while IFS= read -r subject; do
  [ -z "$subject" ] && continue

  # Every word is entirely lowercase or entirely uppercase: a word starting
  # with a capital whose remaining letters are all lowercase is a violation.
  for word in $subject; do
    case "$word" in
      *[/\\_@.]*) continue ;;          # paths and identifiers are exempt
    esac
    if printf '%s' "$word" | grep -qE '^[A-Z][a-z]+$'; then
      echo "casing: '$word' in: $subject"
      failed=1
    fi
  done

  if ! printf '%s' "$subject" | grep -qE '^[a-z]+(\([^)]+\))?!?: .+'; then
    echo "not conventional: $subject"
    failed=1
  fi
done < <(git log --format=%s "$range")

if [ "$failed" -ne 0 ]; then
  echo
  echo "Fix the subjects above, or amend them with: gitthat rewrite"
  exit 1
fi

echo "history is clean"
```

Then: `chmod +x scripts/check-own-history.sh`

- [ ] **Step 4: Verify the script catches a bad subject**

```bash
./scripts/check-own-history.sh HEAD~5..HEAD ; echo "exit: $?"
```

Expected: exit 0 with "history is clean", because every commit in this plan uses a lowercase conventional subject. To confirm it actually detects violations, run it against a deliberately bad range or temporarily test with `git log --format=%s` piped from an invented subject.

- [ ] **Step 5: Add the repository's own config**

`.gitthat.toml`:

```toml
# GITTHAT is developed using GITTHAT. This file is both real configuration and
# the worked example the documentation refers to.

[commit]
style        = "conventional"
subject_case = "lower"

[rewrite]
verify = "swift test"
```

- [ ] **Step 6: Correct the spec's style inference contradiction**

In `docs/superpowers/specs/2026-08-13-gitthat-design.md`, find this text in the "Choosing a style" section:

```
3. Inference from the last 20 subjects. If at least 70% parse as Conventional
   Commits, `conventional` is used; otherwise `plain`.
```

Replace it with:

```
3. Inference from the last 20 subjects. At least 70% parsing as Conventional
   Commits selects `conventional`; 30% or fewer selects `plain`. A ratio
   between the two is treated as ambiguous and falls through to step 4.
```

This resolves a contradiction: the original said "otherwise plain" while step 4 said mixed history should ask. Step 4 already covers "fewer than five commits" and now also covers the mixed case.

- [ ] **Step 7: Run the whole suite**

Run: `swift test`
Expected: PASS. Roughly 110 test cases across 12 files, completing in well under a minute.

- [ ] **Step 8: Stage for review**

```bash
git add Tests/ scripts/ .gitthat.toml docs/
# Do not commit. Stop here and report — the human commits at this boundary.
```

---

## Definition of done

Plan 1 is complete when all of the following hold.

- `swift build` produces a working `gitthat` binary.
- `gitthat commit` generates a message from a real staged diff using a configured agent CLI, and commits on acceptance.
- `swift test` passes with no failures.
- `scripts/check-own-history.sh` passes against this repository's own history.
- No user-facing string contains `rebase`, `squash`, or `fixup`, enforced by a test rather than by review.
- The spec's style-inference rule matches the implemented behaviour.

## What Plan 1 deliberately leaves out

Each of these is covered by a later plan, not forgotten.

- `gitthat rewrite`, `gitthat undo`, backup refs, pushed-commit detection — Plan 2.
- The permutation test tier and its eleven invariants — Plan 2, which is where a plan model exists to permute.
- Conflict resolution and the `verify` hook — Plan 3. The `verify` key is parsed by `Config` in Task 8 so the schema is stable, but nothing reads it yet.
- First-run `PATH` scanning to auto-configure a provider. Until then an absent config falls back to `claude`, and a missing binary produces a clear error from Task 7.
