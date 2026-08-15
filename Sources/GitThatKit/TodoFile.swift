// TodoFile.swift
// THE ONLY FILE in GITTHAT where git's todo-file vocabulary may appear.
// All other user-facing text uses GITTHAT's four words: keep, combine, reword, delete.
// Short forms only (p/s/f/r) so the spelled-out words don't exist even here.

public enum TodoFile {

    /// Renders a RewritePlan as a git todo-file string.
    /// `delete` steps are omitted. Lines are joined by newlines, with no trailing newline.
    public static func render(_ plan: RewritePlan) -> String {
        plan.commits.compactMap(todoLine).joined(separator: "\n")
    }

    /// Returns the new commit messages for all `reword` steps, in todo-file order.
    /// Steps with a nil message are skipped (defensive; a validated plan won't have them).
    public static func messageQueue(_ plan: RewritePlan) -> [String] {
        plan.commits.compactMap { step in
            step.action == .reword ? step.message : nil
        }
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
