public enum SubjectCaseSetting: String, Sendable, Codable {
    case lower
    case preserve
}

/// Enforces the project's casing rule: every word is entirely lowercase or
/// entirely uppercase.
///
/// A run of letters violates the rule when it starts with a capital and every
/// following letter is lowercase — `Add`, `Working`, `Improvement`. Acronyms
/// pass because they are fully uppercase. Identifiers and proper nouns pass
/// because they carry an internal capital: `iOS`, `GitHub`, `refreshToken`,
/// `TokenStore`.
public enum SubjectCase {

    public static func enforce(_ subject: String, setting: SubjectCaseSetting) -> String {
        guard setting == .lower else { return subject }
        return subject
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { fixToken(String($0)) }
            .joined(separator: " ")
    }

    public static func violates(_ subject: String) -> Bool {
        enforce(subject, setting: .lower) != subject
    }

    /// Tokens that look like paths or code identifiers are left entirely alone,
    /// so `Sources/Git.swift` does not become `sources/git.swift`.
    private static func fixToken(_ token: String) -> String {
        guard !isIdentifierLike(token) else { return token }

        var result = ""
        var run = ""
        for character in token {
            if character.isLetter {
                run.append(character)
            } else {
                result += fixRun(run)
                run = ""
                result.append(character)
            }
        }
        return result + fixRun(run)
    }

    private static func isIdentifierLike(_ token: String) -> Bool {
        if token.contains(where: { "/\\_@`".contains($0) }) { return true }
        // An internal dot, as in `Git.swift` — but not a trailing full stop.
        if let dot = token.firstIndex(of: "."), token.index(after: dot) != token.endIndex {
            return true
        }
        return false
    }

    private static func fixRun(_ run: String) -> String {
        isViolatingRun(run) ? run.lowercased() : run
    }

    private static func isViolatingRun(_ run: String) -> Bool {
        guard run.count >= 2, let first = run.first, first.isUppercase else { return false }
        return run.dropFirst().allSatisfy(\.isLowercase)
    }
}
