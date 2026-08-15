import Foundation

// MARK: - Human-readable error descriptions for all GitThatKit error types.
// Rules: name what went wrong AND how to recover; no "rebase", "squash", "fixup".

extension ProviderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound(let command):
            let found = Self.scanPath()
            if found.isEmpty {
                return """
                    Provider '\(command)' was not found on PATH. \
                    No known agent CLIs (claude, codex, gemini, ollama, opencode) were detected. \
                    Install one, then set the provider in .gitthat.toml: provider = "<name>"
                    """
            } else {
                let list = found.map { "  found: \($0) — set provider = \"\($0)\"" }
                    .joined(separator: "\n")
                return """
                    Provider '\(command)' was not found on PATH.
                    \(list)
                    Set the correct provider in .gitthat.toml: provider = "<name>"
                    """
            }
        case .timedOut(let seconds):
            return "Provider timed out after \(seconds) second\(seconds == 1 ? "" : "s"). Try increasing timeout in .gitthat.toml: [providers.<name>] timeout = <seconds>"
        case .failed(let exitCode, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "Provider exited with code \(exitCode)."
            }
            return "Provider exited with code \(exitCode):\n\(detail)"
        case .empty:
            return "Provider returned an empty response. Check that the agent CLI is working correctly."
        }
    }

    /// Scans PATH for known agent CLIs and returns the ones found.
    public static func scanPath() -> [String] {
        let known = ["claude", "codex", "gemini", "ollama", "opencode"]
        let paths = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":").map(String.init) ?? []
        return known.filter { name in
            paths.contains { dir in
                FileManager.default.isExecutableFile(atPath: "\(dir)/\(name)")
            }
        }
    }
}

extension ConfigError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownProvider(let name, let available):
            if available.isEmpty {
                return "Unknown provider '\(name)'. No providers are configured. Add a [providers.\(name)] section to .gitthat.toml."
            }
            let list = available.joined(separator: ", ")
            return "Unknown provider '\(name)'. Available providers: \(list). Update provider = \"<name>\" in .gitthat.toml."
        case .malformed(let detail):
            return "Config file is malformed: \(detail)"
        case .invalidValue(let key, let value, let allowed):
            let list = allowed.joined(separator: ", ")
            return "Invalid value '\(value)' for '\(key)'. Allowed: \(list)"
        }
    }
}

extension GitError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "Git command failed: \(command)"
            }
            return "Git command failed: \(command)\n\(detail)"
        }
    }
}

extension CommitFlowError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notARepository:
            return "Not a git repository. Run 'git init' to create one, or change to a directory that is already a repository."
        }
    }
}

extension ResponseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .empty:
            return "The response was empty. Try regenerating."
        }
    }
}

extension UIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .editorFailed(let reason):
            return "Editor failed: \(reason). Set $EDITOR to a working editor command."
        }
    }
}

extension GitRunnerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .couldNotLaunch(let reason):
            return "Could not launch git: \(reason). Ensure git is installed and on PATH."
        }
    }
}

extension RewriteFlowError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notARepository:
            return "Not a git repository. Run 'git init' to create one, or change to a directory that is already a repository."
        case .crossBranchRequest(let detail):
            return detail
        case .dirtyTree:
            return "Working tree has uncommitted changes. Commit or stash them first, or add 'autostash = true' under [rewrite] in .gitthat.toml."
        case .planRejected(let raw):
            return "The agent returned a plan that could not be applied.\nRaw output:\n\(raw)"
        case .missingBinaryPath:
            return "Could not resolve the path to the gitthat binary. Run gitthat from its installed location."
        }
    }
}


extension SafetyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .dirtyTree:
            return "Working tree has uncommitted changes. Commit or stash them first."
        case .noUpstreamAndNoDefaultBranch:
            return "Could not determine the commit range: no upstream tracking branch and no default branch (main/master) found. Set an upstream with 'git branch --set-upstream-to=<remote>/<branch>'."
        case .emptyRange:
            return "No commits to rewrite in the current range."
        case .detachedHead:
            return "HEAD is detached. Check out a branch first: 'git checkout -b <name>'"
        case .unbornHead:
            return "No commits yet. Make at least one commit first."
        }
    }
}
