import Foundation

public enum TicketID {
    /// Two or more uppercase alphanumerics, a hyphen, then digits — `PROJ-421`.
    /// Requiring two characters keeps single-letter branch segments from
    /// registering as tickets.
    // ponytail: nonisolated(unsafe) because Regex is not Sendable but this value
    // is immutable after init and never mutated; computed-property alternative
    // would rebuild Regex on every call.
    nonisolated(unsafe) private static let pattern = try! Regex(#"[A-Z][A-Z0-9]+-[0-9]+"#)

    public static func extract(fromBranch branch: String?) -> String? {
        guard let branch else { return nil }
        guard let match = branch.firstMatch(of: pattern) else { return nil }
        return String(branch[match.range])
    }

    /// Whether the repository's own history shows ticket IDs in subjects. Used
    /// to decide whether including one is appropriate.
    public static func appearsIn(subjects: [String]) -> Bool {
        subjects.contains { $0.firstMatch(of: pattern) != nil }
    }
}
