import ArgumentParser
import Foundation
import GitThatKit

struct UndoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "undo",
        abstract: "Step back through history to any earlier state."
    )

    @Flag(name: .long, help: "Also reset the working tree (default: leave files unchanged).")
    var hard: Bool = false

    mutating func run() throws {
        do {
            try _run()
        } catch let code as ExitCode {
            throw code
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            throw ExitCode(1)
        }
    }

    private func _run() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let git = Git(runner: SystemGitRunner(), directory: directory)
        let safety = Safety(git: git)
        let flow = UndoFlow(git: git, ui: TerminalUI(), safety: safety)

        let outcome = try flow.run(hard: hard)
        switch outcome {
        case .restored(let sha):
            print("   ✓ restored to \(sha.prefix(8))\(hard ? " (working tree reset)" : "")")
        case .cancelled:
            print("   nothing changed")
            throw ExitCode(1)
        case .nothingToUndo:
            print("   nothing to undo")
            throw ExitCode(1)
        }
    }
}
