import Foundation
@testable import GitThatKit

/// Returns queued responses and records the prompts it was given.
///
/// Queued responses are consumed in order. When the queue empties, the last
/// response repeats — so a single-response stub answers any number of calls.
final class StubProvider: Provider, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String]
    private var error: ProviderError?
    private(set) var receivedPrompts: [String] = []

    init(responses: [String]) {
        self.responses = responses
    }

    init(response: String) {
        self.responses = [response]
    }

    init(error: ProviderError) {
        self.responses = []
        self.error = error
    }

    func complete(_ prompt: String) async throws -> String {
        try lock.withLock {
            receivedPrompts.append(prompt)
            if let error { throw error }
            guard !responses.isEmpty else { return "" }
            return responses.count == 1 ? responses[0] : responses.removeFirst()
        }
    }
}
