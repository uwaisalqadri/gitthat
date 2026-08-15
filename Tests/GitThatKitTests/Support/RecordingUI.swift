import Foundation
@testable import GitThatKit

/// A scripted interface. Answers come from queues; output is recorded.
///
/// Queued answers are consumed in order. When one remains it repeats for every
/// later call — matching StubProvider's queue semantics.
final class RecordingUI: UserInterface, @unchecked Sendable {
    private let lock = NSLock()
    private var commitChoices: [CommitChoice]
    private var styleChoices: [CommitStyle]
    private var confirmations: [Bool]
    var editResult: String?
    private(set) var shown: [String] = []
    private(set) var questions: [String] = []

    init(
        commitChoices: [CommitChoice] = [.accept],
        styleChoices: [CommitStyle] = [.conventional],
        confirmations: [Bool] = [true]
    ) {
        self.commitChoices = commitChoices
        self.styleChoices = styleChoices
        self.confirmations = confirmations
    }

    func show(_ text: String) { lock.withLock { shown.append(text) } }

    func askCommitChoice() -> CommitChoice {
        lock.withLock {
            guard !commitChoices.isEmpty else { return .cancel }
            return commitChoices.count > 1 ? commitChoices.removeFirst() : commitChoices[0]
        }
    }

    func askStyle() -> CommitStyle {
        lock.withLock {
            guard !styleChoices.isEmpty else { return .conventional }
            return styleChoices.count > 1 ? styleChoices.removeFirst() : styleChoices[0]
        }
    }

    func confirm(_ question: String) -> Bool {
        lock.withLock {
            questions.append(question)
            guard !confirmations.isEmpty else { return false }
            return confirmations.count > 1 ? confirmations.removeFirst() : confirmations[0]
        }
    }

    func edit(_ text: String) throws -> String { editResult ?? text }

    var allOutput: String { lock.withLock { shown.joined(separator: "\n") } }
}
