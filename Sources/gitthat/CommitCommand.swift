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
        do {
            try await _run()
        } catch let code as ExitCode {
            throw code
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            throw ExitCode(1)
        }
    }

    private mutating func _run() async throws {
        guard !(conventional && plain) else {
            fputs("Error: --conventional and --plain are mutually exclusive. Pass only one.\n", stderr)
            throw ExitCode(1)
        }

        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let repositoryConfig = directory.appendingPathComponent(".gitthat.toml")
        let globalPath = Config.defaultGlobalPath()

        // First-run detection: no config file exists anywhere on disk.
        // Scan PATH for known agent CLIs and auto-select the first found.
        let noConfig = !FileManager.default.fileExists(atPath: globalPath.path)
                    && !FileManager.default.fileExists(atPath: repositoryConfig.path)
        if noConfig {
            let found = ProviderError.scanPath()
            guard let first = found.first else {
                fputs("""
                    Error: No config file found and no known agent CLI detected on PATH.
                    Install one of: claude, codex, gemini, ollama, opencode
                    Then run again, or create .gitthat.toml with: provider = "<name>"
                    """, stderr)
                fputs("\n", stderr)
                throw ExitCode(1)
            }
            print("   Auto-selected provider: \(first) (no config found)")
        }

        var config = try Config.load(
            globalPath: globalPath,
            repositoryPath: repositoryConfig
        )

        // Override provider with auto-detected one when no config was present.
        if noConfig, let first = ProviderError.scanPath().first {
            config = Config(
                provider: first,
                providers: [first: ProviderConfig(command: [first, "-p"], timeout: 60)],
                commit: config.commit,
                rewrite: config.rewrite
            )
        }

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
