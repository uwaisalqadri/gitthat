import Foundation

public enum CommitStyle: String, Sendable, Codable {
    case conventional
    case plain
}

public enum StyleSetting: String, Sendable, Codable {
    case auto
    case conventional
    case plain
}

public enum StyleInference {
    /// `type(scope)!: description` — lowercase type, optional scope, optional
    /// breaking marker, a space after the colon, and a non-empty description.
    // ponytail: nonisolated(unsafe) because Regex is not Sendable but this value
    // is immutable after init and never mutated; computed-property alternative
    // would rebuild Regex on every call.
    nonisolated(unsafe) private static let pattern = try! Regex(#"^[a-z]+(\([^)]+\))?!?: .+$"#)

    private static let minimumSampleSize = 5
    private static let conventionalThreshold = 0.70
    private static let plainThreshold = 0.30

    public static func isConventional(_ subject: String) -> Bool {
        subject.wholeMatch(of: pattern) != nil
    }

    /// Returns `nil` when history cannot settle the question — too few commits,
    /// or a genuinely mixed repository. The caller asks the user.
    public static func infer(from subjects: [String]) -> CommitStyle? {
        guard subjects.count >= minimumSampleSize else { return nil }

        let ratio = Double(subjects.filter(isConventional).count) / Double(subjects.count)
        if ratio >= conventionalThreshold { return .conventional }
        if ratio <= plainThreshold { return .plain }
        return nil
    }
}
