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

@Test func rejectsUnrecognisedStyleValue() throws {
    #expect(throws: ConfigError.invalidValue(
        key: "commit.style", value: "nonsense",
        allowed: ["auto", "conventional", "plain"]
    )) {
        try Config.parse("""
            [commit]
            style = "nonsense"
            """)
    }
}

@Test func rejectsUnrecognisedSubjectCaseValue() throws {
    // Also proves the check is case-sensitive: "NONSENSE" is invalid, "lower" is the valid spelling.
    #expect(throws: ConfigError.invalidValue(
        key: "commit.subject_case", value: "NONSENSE",
        allowed: ["lower", "preserve"]
    )) {
        try Config.parse("""
            [commit]
            subject_case = "NONSENSE"
            """)
    }
}

@Test func absentStyleKeyInheritsRatherThanThrows() throws {
    // Key absent → inherit from base; must NOT throw even though there is no raw value.
    let config = try Config.parse("""
        [commit]
        max_subject = 50
        """)
    #expect(config.commit.style == .auto)
    #expect(config.commit.subjectCase == .lower)
}

@Test func rejectsStringValueForMaxSubject() throws {
    // Type mismatch: a string where an integer is expected must throw, not silently use the default.
    #expect(throws: ConfigError.invalidValue(
        key: "commit.max_subject", value: "seventy", allowed: ["integer"]
    )) {
        try Config.parse("""
            [commit]
            max_subject = "seventy"
            """)
    }
}

@Test func absentMaxSubjectKeyInheritsRatherThanThrows() throws {
    // Absent key → inherit; must NOT throw (regression guard for B4 fix).
    let config = try Config.parse("""
        [commit]
        style = "plain"
        """)
    #expect(config.commit.maxSubject == 72)
}

@Test func unreadableConfigFileThrowsDistinctError() throws {
    // Create a file then make it unreadable; load must throw unreadable, not silently use defaults.
    // Skip when running as root (root can read any file regardless of permissions).
    guard ProcessInfo.processInfo.environment["USER"] != "root" else { return }

    let url = try writeTemporary("[commit]\nstyle = \"plain\"\n")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

    var caught: ConfigError? = nil
    do {
        _ = try Config.load(globalPath: url, repositoryPath: nil)
    } catch let e as ConfigError {
        caught = e
    }

    if case .unreadable(let path, _) = caught {
        #expect(path == url.path)
    } else {
        Issue.record("expected ConfigError.unreadable, got \(String(describing: caught))")
    }
}
