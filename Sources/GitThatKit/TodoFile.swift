// TodoFile.swift
// THE ONLY FILE in GITTHAT where git's todo-file vocabulary may appear.
import Foundation
// All other user-facing text uses GITTHAT's four words: keep, combine, reword, delete.
// Short forms only (p/s/f/r) so the spelled-out words don't exist even here.

public enum TodoFile {

    /// One entry in the editor-invocation queue: either write a message or leave the file alone.
    /// Git opens GIT_EDITOR once per reword step, and once per squash-group (consecutive `s` lines).
    /// The queue must mirror that sequence exactly.
    public enum QueueEntry: Equatable, Sendable {
        /// Write this message to git's COMMIT_EDITMSG file.
        case write(String)
        /// Leave git's COMMIT_EDITMSG file untouched (used for squash-group invocations).
        case leave

        // Serialised as a NUL-delimited record with a 1-byte prefix: "W<message>" or "L".
        // NUL is the record separator; prefix disambiguates leave from write.
        var serialised: Data {
            switch self {
            case .write(let msg): return Data(("W" + msg).utf8)
            case .leave:          return Data("L".utf8)
            }
        }

        init?(data: Data) {
            guard let first = data.first else { return nil }
            switch first {
            case UInt8(ascii: "W"): self = .write(String(data: data.dropFirst(), encoding: .utf8) ?? "")
            case UInt8(ascii: "L"): self = .leave
            default: return nil
            }
        }
    }

    /// Renders a RewritePlan as a git todo-file string.
    /// `delete` steps are omitted. Lines are joined by newlines, with no trailing newline.
    public static func render(_ plan: RewritePlan) -> String {
        plan.commits.compactMap(todoLine).joined(separator: "\n")
    }

    /// Returns the editor-invocation queue for a plan, matching git's GIT_EDITOR call sequence.
    ///
    /// Git opens GIT_EDITOR for:
    ///   - Each `r` (reword) step: write the new message.
    ///   - Once per consecutive group of `s` (squash/keepMessage:true) lines: leave the file alone
    ///     so git uses its own combined-message template.
    ///
    /// `f` (fixup/keepMessage:false), `p` (keep), and deleted steps do not invoke GIT_EDITOR.
    public static func messageQueue(_ plan: RewritePlan) -> [QueueEntry] {
        var result: [QueueEntry] = []
        var inSquashGroup = false

        for step in plan.commits {
            switch step.action {
            case .keep, .delete:
                inSquashGroup = false

            case .combine where step.keepMessage == true:
                // Squash group: git calls editor once when the group ends.
                // We track when a new group starts; the .leave entry is emitted
                // at the first squash step (groups end when a non-squash step follows).
                if !inSquashGroup {
                    result.append(.leave)
                    inSquashGroup = true
                }
                // Subsequent squash steps in the same group: no additional entry.

            case .combine:
                // fixup (keepMessage: false) — no editor invocation.
                inSquashGroup = false

            case .reword:
                inSquashGroup = false
                if let msg = step.message {
                    result.append(.write(msg))
                }
                // nil message: skip (defensive; validated plans never produce this)
            }
        }

        return result
    }

    /// Serialises the queue to NUL-delimited bytes for writing to GITTHAT_MESSAGE_QUEUE.
    public static func serialiseQueue(_ entries: [QueueEntry]) -> Data {
        var data = Data()
        for (i, entry) in entries.enumerated() {
            data.append(contentsOf: entry.serialised)
            if i < entries.count - 1 { data.append(0) }
        }
        return data
    }

    /// Deserialises NUL-delimited bytes back to queue entries.
    public static func deserialiseQueue(_ data: Data) -> [QueueEntry] {
        data.split(separator: 0, omittingEmptySubsequences: false)
            .compactMap { QueueEntry(data: Data($0)) }
    }

    // MARK: - Private

    private static func todoLine(_ step: RewriteStep) -> String? {
        switch step.action {
        case .keep:    return "p \(step.sha)"
        case .reword:  return "r \(step.sha)"
        case .combine:
            // keepMessage is required on combine steps (enforced by validated(against:)).
            // An unvalidated nil falls through to "f" (discard) as a safe non-trapping default.
            return (step.keepMessage == true ? "s" : "f") + " \(step.sha)"
        case .delete:  return nil
        }
    }
}
