import Foundation
import TOMLKit

public enum ConfigError: Error, Equatable {
    case unknownProvider(name: String, available: [String])
    case malformed(String)
    case invalidValue(key: String, value: String, allowed: [String])
    case unreadable(path: String, reason: String)
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
    /// An unreadable file (exists but cannot be read) throws `ConfigError.unreadable`.
    public static func load(globalPath: URL?, repositoryPath: URL?) throws -> Config {
        var config = Config.defaults
        for path in [globalPath, repositoryPath] {
            guard let path else { continue }
            // Missing file: skip silently. Unreadable file: throw to surface the problem.
            if !FileManager.default.fileExists(atPath: path.path) { continue }
            let text: String
            do {
                text = try String(contentsOf: path, encoding: .utf8)
            } catch {
                throw ConfigError.unreadable(path: path.path, reason: error.localizedDescription)
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

        let style: StyleSetting
        if let raw = commitTable?["style"]?.string {
            guard let parsed = StyleSetting(rawValue: raw) else {
                throw ConfigError.invalidValue(
                    key: "commit.style", value: raw,
                    allowed: StyleSetting.allCases.map(\.rawValue)
                )
            }
            style = parsed
        } else {
            style = base.commit.style
        }

        let subjectCase: SubjectCaseSetting
        if let raw = commitTable?["subject_case"]?.string {
            guard let parsed = SubjectCaseSetting(rawValue: raw) else {
                throw ConfigError.invalidValue(
                    key: "commit.subject_case", value: raw,
                    allowed: SubjectCaseSetting.allCases.map(\.rawValue)
                )
            }
            subjectCase = parsed
        } else {
            subjectCase = base.commit.subjectCase
        }

        let maxSubject: Int
        if let rawMax = commitTable?["max_subject"] {
            guard let intMax = rawMax.int else {
                throw ConfigError.invalidValue(
                    key: "commit.max_subject",
                    value: rawMax.string ?? String(describing: rawMax),
                    allowed: ["integer"]
                )
            }
            maxSubject = intMax
        } else {
            maxSubject = base.commit.maxSubject
        }

        let commit = CommitConfig(
            style: style,
            subjectCase: subjectCase,
            maxSubject: maxSubject
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
