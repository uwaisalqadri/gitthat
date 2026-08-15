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
        let entries = data.split(separator: 0, omittingEmptySubsequences: false) // NUL = 0; must NOT skip empty entries or queue position desyncs

        guard let first = entries.first else {
            return // queue exhausted: git's own message stands
        }

        // Write the message (strip trailing NUL if any)
        let messageURL = URL(fileURLWithPath: messagePath)
        try first.write(to: messageURL)

        // Rewrite queue without the consumed entry
        let rest = entries.dropFirst()
        var newQueue = Data()
        for (i, entry) in rest.enumerated() {
            newQueue.append(contentsOf: entry)
            if i < rest.count - 1 { newQueue.append(0) }
        }
        try newQueue.write(to: queueURL)
    }
}
