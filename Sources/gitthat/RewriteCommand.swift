import ArgumentParser
import Foundation
import GitThatKit

struct RewriteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rewrite",
        abstract: "Rewrite recent commit history with AI assistance."
    )

    @Option(name: .shortAndLong, help: "What you want to achieve (e.g. 'combine the last 3 WIP commits').")
    var intent: String? = nil

    @Option(name: .shortAndLong, help: "Number of commits to include in the rewrite range.")
    var count: Int? = nil

    @Flag(name: .long, help: "Stash uncommitted changes automatically before rewriting.")
    var autostash: Bool = false

    @Flag(name: .long, help: "Resume a rewrite that stopped due to a conflict.")
    var resume: Bool = false

    @Flag(name: .long, help: "Cancel a rewrite that stopped due to a conflict.")
    var cancel: Bool = false

    // Hidden aliases matching git's own flag names, so muscle memory works.
    @Flag(name: [.customLong("continue")], help: .hidden)
    var continueFlag: Bool = false

    @Flag(name: [.customLong("abort")], help: .hidden)
    var abortFlag: Bool = false

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
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let git = Git(runner: SystemGitRunner(), directory: directory)

        // Handle --resume / --continue
        if resume || continueFlag {
            guard git.rewriteInProgress() else {
                fputs("No rewrite in progress.\n", stderr)
                throw ExitCode(1)
            }
            let code = try git.rewriteContinue()
            if code == 0 {
                print("   rewrite resumed")
            } else {
                fputs("Continue failed (conflict still unresolved?). Resolve conflicts and try again.\n", stderr)
                throw ExitCode(1)
            }
            return
        }

        // Handle --cancel / --abort
        if cancel || abortFlag {
            guard git.rewriteInProgress() else {
                fputs("No rewrite in progress.\n", stderr)
                throw ExitCode(1)
            }
            let code = try git.rewriteAbort()
            if code == 0 {
                print("   rewrite cancelled — history restored")
            } else {
                fputs("Abort failed.\n", stderr)
                throw ExitCode(1)
            }
            return
        }

        // Normal run
        let repositoryConfig = directory.appendingPathComponent(".gitthat.toml")
        let globalPath = Config.defaultGlobalPath()

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

        var config = try Config.load(globalPath: globalPath, repositoryPath: repositoryConfig)

        if noConfig, let first = ProviderError.scanPath().first {
            config = Config(
                provider: first,
                providers: [first: ProviderConfig(command: [first, "-p"], timeout: 60)],
                commit: config.commit,
                rewrite: config.rewrite
            )
        }

        let providerConfig = try config.resolvedProvider()
        let safety = Safety(git: git)

        // Resolve binary path from CommandLine (absolute so it survives git's directory change).
        let arg0 = CommandLine.arguments[0]
        let binaryPath: String?
        if arg0.hasPrefix("/") {
            binaryPath = arg0
        } else {
            let resolved = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(arg0).path
            binaryPath = FileManager.default.fileExists(atPath: resolved) ? resolved : nil
        }

        guard binaryPath != nil else {
            fputs(
                "Error: Could not resolve the path to the gitthat binary. " +
                "Run gitthat from its installed location.\n",
                stderr
            )
            throw ExitCode(1)
        }

        let flow = RewriteFlow(
            git: git,
            provider: CLIProvider(
                command: providerConfig.command,
                timeout: .seconds(providerConfig.timeout)
            ),
            config: config,
            ui: TerminalUI(),
            safety: safety,
            binaryPath: binaryPath
        )

        let effectiveAutostash = autostash || config.rewrite.autostash
        let outcome = try await flow.run(intent: intent, count: count, autostash: effectiveAutostash)

        switch outcome {
        case .rewritten(let ref):
            print("\n   ✓ rewrite complete — backup: \(ref)")
        case .cancelled:
            print("\n   nothing changed")
            throw ExitCode(1)
        case .nothingToRewrite:
            print("\n   nothing to rewrite")
            throw ExitCode(1)
        case .conflicted:
            // Message already shown by the flow.
            throw ExitCode(1)
        }
    }
}
