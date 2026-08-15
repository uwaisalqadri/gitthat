import ArgumentParser
import Foundation
import GitThatKit

/// Hidden subcommand used by scripts/check-own-history.sh.
/// Reads subjects one-per-line from stdin, prints violations, exits 1 if any found.
/// Not intended for end-users; hidden from --help.
struct CheckSubjectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__check-subject",
        abstract: "Internal: check commit subjects for casing violations.",
        shouldDisplay: false
    )

    mutating func run() throws {
        var failed = false
        while let line = readLine() {
            let subject = line.trimmingCharacters(in: .whitespaces)
            guard !subject.isEmpty else { continue }
            if SubjectCase.violates(subject) {
                print("casing: \(subject)")
                failed = true
            }
        }
        if failed { throw ExitCode(1) }
    }
}
