import ArgumentParser
import Foundation
import GitThatKit

/// Hidden subcommand invoked by git as GIT_EDITOR during an interactive rebase.
/// Called as: `gitthat __edit-message <COMMIT_EDITMSG-path>`
/// Reads the first NUL-delimited message from GITTHAT_MESSAGE_QUEUE,
/// writes it to the path git gave us, and removes it from the queue.
/// If the queue is empty or missing, leaves git's file untouched and exits 0.
struct EditMessageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__edit-message",
        abstract: "Internal: write the next reword message during an interactive history edit.",
        shouldDisplay: false
    )

    @Argument(help: "Path to the commit message file (provided by git).")
    var messagePath: String

    mutating func run() throws {
        guard let queuePath = ProcessInfo.processInfo.environment["GITTHAT_MESSAGE_QUEUE"],
              !queuePath.isEmpty,
              FileManager.default.fileExists(atPath: queuePath) else {
            return // safe: leave git's file untouched
        }

        let queueURL = URL(fileURLWithPath: queuePath)
        let data = (try? Data(contentsOf: queueURL)) ?? Data()
        var entries = TodoFile.deserialiseQueue(data)

        guard !entries.isEmpty else {
            return // queue exhausted: git's own message stands
        }

        let first = entries.removeFirst()

        // Only overwrite git's file for .write entries; .leave means let git's combined message stand.
        if case .write(let message) = first {
            let messageURL = URL(fileURLWithPath: messagePath)
            try Data(message.utf8).write(to: messageURL)
        }

        // Rewrite queue with the remaining entries.
        try TodoFile.serialiseQueue(entries).write(to: queueURL)
    }
}
