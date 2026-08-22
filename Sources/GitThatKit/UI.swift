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
    func askConflictChoice() -> ConflictChoice
    func askStyle() -> CommitStyle
    func confirm(_ question: String) -> Bool
    func edit(_ text: String) throws -> String
}

public enum Render {
    private static let isTTY = isatty(STDOUT_FILENO) == 1
    private static let dim   = isTTY ? "\u{001B}[2m"  : ""
    private static let bold  = isTTY ? "\u{001B}[1m"  : ""
    private static let reset = isTTY ? "\u{001B}[0m"  : ""

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
            guard let line = readLine() else { return .cancel } // EOF: treat as cancel
            switch line.trimmingCharacters(in: .whitespaces).lowercased() {
            case "a":     return .accept
            case "e":     return .edit
            case "r":     return .regenerate
            case "c":     return .cancel
            default:      print("   Please answer a, e, r, or c.")
            }
        }
    }

    public func askConflictChoice() -> ConflictChoice {
        while true {
            print("\n   [a] accept into editor   [e] edit manually")
            print("   [o] take ours            [t] take theirs   [s] skip: ", terminator: "")
            guard let line = readLine() else { return .skip }
            switch line.trimmingCharacters(in: .whitespaces).lowercased() {
            case "a": return .acceptIntoEditor
            case "e": return .editManually
            case "o": return .takeOurs
            case "t": return .takeTheirs
            case "s": return .skip
            default:  print("   Please answer a, e, o, t, or s.")
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
            guard let line = readLine() else { return .conventional } // EOF: default to conventional
            switch line.trimmingCharacters(in: .whitespaces) {
            case "1", "": return .conventional
            case "2":     return .plain
            default:      print("   Please answer 1 or 2.")
            }
        }
    }

    public func confirm(_ question: String) -> Bool {
        print("\n   \(question) [y/N]: ", terminator: "")
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }

    /// Writes the text to a temp file, opens `$EDITOR` on it, and returns what
    /// the user saved. Cleans up the temp file on every path, including thrown errors.
    public func edit(_ text: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("COMMIT_EDITMSG-\(UUID().uuidString)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "vi"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // Shell is intentional: $EDITOR may be multi-word ("code -w", "emacsclient -t"),
        // matching git's own GIT_EDITOR handling. The path goes through $1 — a positional
        // argument — so a path containing spaces or quotes cannot break the command string.
        process.arguments = ["sh", "-c", "\(editor) \"$1\"", "sh", url.path]

        do {
            try process.run()
        } catch {
            throw UIError.editorFailed("\(editor): \(error.localizedDescription)")
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw UIError.editorFailed("\(editor) exited \(process.terminationStatus)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
