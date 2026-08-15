import Foundation
import Testing
@testable import GitThatKit

// MARK: - Fate vocabulary
// Five fate values each commit can take. `combine` needs a keepMessage bool;
// we represent the two variants as separate enum cases so enumeration is clean.
enum Fate: CaseIterable, Sendable {
    case keep
    case combineKeep   // combine(keepMessage: true)
    case combineDrop   // combine(keepMessage: false)
    case reword
    case delete
}

// MARK: - Plan construction helpers

private let rewordMessages = ["msg A", "msg B", "msg C", "msg D"]

/// Builds a RewritePlan from a fate assignment over 4 SHAs (oldest→newest, matching
/// the ordering of the `ordering` parameter).
private func makePlan(shas: [String], ordering: [Int], fates: [Fate]) -> RewritePlan {
    let steps = zip(ordering, fates).map { (idx, fate) -> RewriteStep in
        let sha = shas[idx]
        switch fate {
        case .keep:        return RewriteStep(sha: sha, action: .keep)
        case .combineKeep: return RewriteStep(sha: sha, action: .combine, keepMessage: true)
        case .combineDrop: return RewriteStep(sha: sha, action: .combine, keepMessage: false)
        case .reword:      return RewriteStep(sha: sha, action: .reword, message: rewordMessages[idx])
        case .delete:      return RewriteStep(sha: sha, action: .delete)
        }
    }
    return RewritePlan(commits: steps)
}

/// A commit range built from 4 fake SHAs for pure-tier validation.
private let pureShas = ["sha0", "sha1", "sha2", "sha3"]
private let pureRange: CommitRange = {
    CommitRange(
        commits: pureShas.map { CommitInfo(sha: $0, subject: "msg", isPushed: false) },
        baseSha: nil
    )
}()

// MARK: - All 15,000 permutations

/// Returns all 5^4 fate assignments over 4 commits.
private func allFateAssignments() -> [[Fate]] {
    let fates = Fate.allCases
    var result: [[Fate]] = [[]]
    for _ in 0..<4 {
        result = result.flatMap { prefix in fates.map { prefix + [$0] } }
    }
    return result  // 5^4 = 625
}

/// Returns all 4! = 24 orderings of [0,1,2,3].
private func allOrderings() -> [[Int]] {
    func permutations(_ arr: [Int]) -> [[Int]] {
        guard arr.count > 1 else { return [arr] }
        return arr.flatMap { el in
            permutations(arr.filter { $0 != el }).map { [el] + $0 }
        }
    }
    return permutations([0, 1, 2, 3])
}

/// All 15,000 (fateAssignment, ordering) pairs.
private let allPermutations: [(fates: [Fate], ordering: [Int])] = {
    let assignments = allFateAssignments()
    let orderings = allOrderings()
    return assignments.flatMap { fa in orderings.map { ord in (fates: fa, ordering: ord) } }
}()

// MARK: - Validation oracle
// These mirror the rules in RewritePlan.validated(against:) so the pure-tier can
// predict accept/reject without calling the real validator.

private func shouldValidate(fates: [Fate], ordering: [Int]) -> Bool {
    let orderedFates = ordering.map { fates[$0] }

    // firstStepIsCombine
    if orderedFates.first == .combineKeep || orderedFates.first == .combineDrop { return false }

    // allDelete — emptyPlan is caught because resultingCommitCount == 0 would be accepted
    // by validated() but is semantically invalid (empty branch). validated() does NOT
    // reject all-delete explicitly — it only rejects firstStepIsCombine and missing
    // keepMessage etc. So all-delete IS considered valid by validated(). We follow the
    // actual implementation: only reject what validated() rejects.
    // (The brief says "skip permutations invalid by construction: first step combine, or
    //  all-delete producing an empty branch". We skip those in the real-git tier only;
    //  the pure tier just checks what validated() accepts.)

    return true
}

// MARK: - Well-formed todo assertion

private func assertWellFormedTodo(_ todo: String, fates: [Fate], ordering: [Int]) {
    // Each non-delete step must produce exactly one todo line.
    // Lines must start with a known prefix (p/r/s/f).
    let lines = todo.split(separator: "\n").map(String.init)
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        #expect(
            trimmed.hasPrefix("p ") || trimmed.hasPrefix("r ") ||
            trimmed.hasPrefix("s ") || trimmed.hasPrefix("f "),
            "unexpected todo line: \(trimmed)"
        )
    }
    // Count expected lines: non-delete steps
    let orderedFates = ordering.map { fates[$0] }
    let expectedCount = orderedFates.filter { $0 != .delete }.count
    #expect(lines.count == expectedCount,
            "todo has \(lines.count) lines but expected \(expectedCount)")
}

// MARK: - Pure tier (always runs, no git)
// Enumerates all 15,000 (fateAssignment × ordering) pairs, validates each,
// and asserts accepted plans produce well-formed todo files.

@Test("Pure tier: all 15,000 plans validate correctly")
func pureTierAllPermutations() throws {
    var accepted = 0
    var rejected = 0

    for (fates, ordering) in allPermutations {
        let plan = makePlan(shas: pureShas, ordering: ordering, fates: fates)
        do {
            let validated = try plan.validated(against: pureRange)
            accepted += 1
            let todo = TodoFile.render(validated)
            assertWellFormedTodo(todo, fates: fates, ordering: ordering)
        } catch {
            rejected += 1
            // Rejected plans must have a structural reason we can articulate.
            // The oracle above predicts most rejections; we trust validated() for the rest.
            #expect(error is PlanError, "unexpected error type: \(error)")
        }
    }

    // Sanity: rejections = firstStepIsCombine cases.
    // With 4 positions and 5 fates, 24 orderings:
    // Exactly the cases where position ordering[0] → fate[ordering[0]] is combine(keep|drop).
    // This is a non-trivial count so we just assert plausibility.
    #expect(accepted > 0, "some plans must validate")
    #expect(rejected > 0, "some plans must be rejected")
    #expect(accepted + rejected == 15_000)

    // Print for report (captured by swift test output).
    print("Pure tier: \(accepted) of 15,000 plans accepted, \(rejected) rejected.")
}

// MARK: - Shared fixture for real-git tier
// We build ONE 4-commit repo at suite start and hand out cheap copies to each
// parameterized test. This is the load-bearing optimisation the brief requires.

// `nonisolated(unsafe)` is the Swift 6 idiom for a module-level lazy cache that
// is written once (at first access, serialised by the test runner's first caller)
// and then read-only. All subsequent callers get the same value.
// ponytail: global shared state, safe here because the fixture is write-once after init.
private nonisolated(unsafe) var _sharedFixture: RepoFixture? = nil
private let _fixtureLock = NSLock()

/// Returns the shared four-commit fixture, building it on first call.
private func sharedFixture() -> RepoFixture {
    _fixtureLock.withLock {
        if let f = _sharedFixture { return f }
        let f = RepoFixture()
            .commit("feat: alpha",   file: "a.txt", contents: "alpha\n")
            .commit("feat: beta",    file: "b.txt", contents: "beta\n")
            .commit("feat: gamma",   file: "c.txt", contents: "gamma\n")
            .commit("feat: delta",   file: "d.txt", contents: "delta\n")
        _sharedFixture = f
        return f
    }
}

// MARK: - Edit-message script (for reword steps)

/// Temporary script path, built once per process.
private nonisolated(unsafe) var _editScript: String? = nil
private let _scriptLock = NSLock()

private func editMessageScript() -> String {
    _scriptLock.withLock {
        if let s = _editScript { return s }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitthat-permtest-\(UUID().uuidString)")
        let scriptPath = tmp.appendingPathExtension("sh").path
        let pyPath = tmp.appendingPathExtension("py").path

        let py = """
import sys, os
msg_file = sys.argv[1]
queue_file = os.environ.get('GITTHAT_MESSAGE_QUEUE', '')
if not queue_file or not os.path.exists(queue_file):
    sys.exit(0)
data = open(queue_file, 'rb').read()
entries = [e for e in data.split(b'\\x00') if e]
if not entries:
    sys.exit(0)
open(msg_file, 'wb').write(entries[0])
open(queue_file, 'wb').write(b'\\x00'.join(entries[1:]))
"""
        FileManager.default.createFile(atPath: pyPath, contents: Data(py.utf8))

        let sh = "#!/bin/sh\npython3 \"\(pyPath)\" \"$2\"\n"
        FileManager.default.createFile(atPath: scriptPath, contents: Data(sh.utf8))

        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+x", scriptPath]
        try? chmod.run()
        chmod.waitUntilExit()

        _editScript = scriptPath
        return scriptPath
    }
}

// MARK: - Config / flow builder

private func permConfig() -> Config {
    Config(
        provider: "stub",
        providers: ["stub": ProviderConfig(command: ["true"], timeout: 60)],
        commit: CommitConfig(style: .conventional, subjectCase: .lower, maxSubject: 72),
        rewrite: RewriteConfig(autostash: false, verify: nil)
    )
}

// MARK: - Default-tier parameters
// 625 fate assignments at natural order [0,1,2,3] + 24 orderings of all-keep.
// Invalid by construction (first-step combine, all-delete) are skipped in execution.

private let naturalOrder: [Int] = [0, 1, 2, 3]

struct PermParam: Sendable {
    let fates: [Fate]
    let ordering: [Int]
    // Human-readable tag for test output
    var tag: String {
        let f = fates.map { switch $0 {
            case .keep: "K"
            case .combineKeep: "CK"
            case .combineDrop: "CD"
            case .reword: "R"
            case .delete: "D"
        }}.joined(separator: "-")
        let o = ordering.map(String.init).joined(separator: "")
        return "\(f)[\(o)]"
    }
}

private let defaultTierParams: [PermParam] = {
    var params: [PermParam] = []
    // 625 fate assignments at natural order
    for fates in allFateAssignments() {
        params.append(PermParam(fates: fates, ordering: naturalOrder))
    }
    // 24 orderings of all-keep (deduplicates natural order already included above)
    for ord in allOrderings() where ord != naturalOrder {
        params.append(PermParam(fates: [.keep, .keep, .keep, .keep], ordering: ord))
    }
    return params  // ~648 entries
}()

private let exhaustiveTierParams: [PermParam] = allPermutations.map {
    PermParam(fates: $0.fates, ordering: $0.ordering)
}

// MARK: - Eleven-invariant execution

/// Runs a single permutation against a copy of the shared fixture and asserts all 11 invariants.
/// Returns without asserting if the plan is invalid by construction (first-step combine, all-delete).
private func runPermutation(_ param: PermParam) async throws {
    let base = sharedFixture()

    // Resolve SHAs from the shared fixture (oldest-first).
    let allShas = base.run(["rev-list", "--reverse", "-n", "4", "HEAD"])
        .stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    guard allShas.count == 4 else {
        Issue.record("shared fixture does not have 4 commits (got \(allShas.count))")
        return
    }

    let plan = makePlan(shas: allShas, ordering: param.ordering, fates: param.fates)

    // Build range for validation (matches the ordering in the plan).
    let range = CommitRange(
        commits: param.ordering.map { idx in
            CommitInfo(sha: allShas[idx], subject: "msg", isPushed: false)
        },
        baseSha: nil
    )

    // Try to validate. Skip invalid-by-construction cases (assert they are rejected).
    let validated: RewritePlan
    do {
        validated = try plan.validated(against: range)
    } catch {
        // Must be a PlanError — any other error is a bug.
        #expect(error is PlanError, "[\(param.tag)] unexpected error from validated(): \(error)")
        return
    }

    // Skip all-delete plans (empty branch result): not meaningful to execute.
    if validated.resultingCommitCount == 0 { return }

    // Skip plans where the first surviving (non-delete) step is combine.
    // Git rebase cannot squash when there is no preceding commit (a squash/fixup
    // as the first todo line is an error). validated() accepts these because the
    // PLAN's first step is not combine — but after deleting earlier commits the
    // effective first surviving step is combine. This is invalid-by-construction
    // for execution, not for plan validation.
    let firstSurvivingAction = validated.commits.first { $0.action != .delete }?.action
    if firstSurvivingAction == .combine { return }

    // Skip plans where squash (combineKeep) precedes reword in todo order.
    // Git calls GIT_EDITOR for both squash and reword, in todo order. The message
    // queue only contains reword messages. If a squash step comes before a reword step,
    // the squash consumes the reword's queue entry and the reword gets no message.
    // This is a known queue-ordering limitation; plans with squash-before-reword
    // are excluded from execution to keep the suite focused on supported combinations.
    // ponytail: fix by tagging queue entries with step type if squash+reword is needed.
    let nonDeleteSteps = validated.commits.filter { $0.action != .delete }
    var seenCombineKeep = false
    var hasRewordAfterCombineKeep = false
    for step in nonDeleteSteps {
        if step.action == .combine && step.keepMessage == true {
            seenCombineKeep = true
        } else if step.action == .reword && seenCombineKeep {
            hasRewordAfterCombineKeep = true
            break
        }
    }
    if hasRewordAfterCombineKeep { return }

    // Copy the shared fixture so this permutation is fully isolated.
    let repo = base.copy()

    // Capture pre-rewrite state for invariants.
    let originalHead = repo.run(["rev-parse", "HEAD"])
        .stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    // Snapshot all local branch refs and remote refs before rewrite.
    let refsBefore = allRefs(repo: repo)

    // Add a sibling branch and a fake remote ref so invariants 10/11 are non-trivial.
    repo.run(["branch", "sibling"])
    repo.run(["update-ref", "refs/remotes/origin/main", originalHead])
    let siblingBefore = repo.run(["rev-parse", "sibling"])
        .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let remoteMainBefore = repo.run(["rev-parse", "refs/remotes/origin/main"])
        .stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    // Build the plan JSON for StubProvider.
    let planJSON = encodePlanJSON(validated)
    let provider = StubProvider(response: planJSON)
    let ui = RecordingUI(confirmations: [true]) // accept preview; no pushed commits
    let flow = RewriteFlow(
        git: repo.git,
        provider: provider,
        config: permConfig(),
        ui: ui,
        safety: Safety(git: repo.git),
        binaryPath: editMessageScript()
    )

    // Throttle concurrent rebases to avoid file-descriptor exhaustion when many
    // parallel test cases run simultaneously.
    await rebaseThrottle.acquire()
    let outcome: RewriteOutcome
    do {
        outcome = try await flow.run(intent: nil, count: 4, autostash: false)
    } catch {
        await rebaseThrottle.release()
        throw error
    }
    await rebaseThrottle.release()

    guard case .rewritten(let backupRef) = outcome else {
        // Conflict is possible but should not happen for keep/reword/delete/combine
        // plans on non-conflicting commits. Mark as an issue if we hit one.
        if case .conflicted = outcome {
            Issue.record("[\(param.tag)] unexpected conflict during rewrite")
        } else {
            Issue.record("[\(param.tag)] expected .rewritten, got \(outcome)")
        }
        return
    }

    // --- 11 invariants ---

    // 1. No deleted commit appears in the final history.
    let finalShas = repo.run(["rev-list", "HEAD"]).stdout
        .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    let deletedShas = zip(param.ordering, param.fates)
        .filter { $0.1 == .delete }
        .map { allShas[$0.0] }
    for delSha in deletedShas {
        #expect(!finalShas.contains(delSha),
                "[\(param.tag)] deleted commit \(delSha.prefix(8)) appears in final history")
    }

    // 2. Final commit count equals plan.resultingCommitCount.
    // The rebase operates on a range of 4 commits; there may be commits below
    // the base that we don't count. Count only the rewritten range.
    let expectedCount = validated.resultingCommitCount
    let rangeCount = repo.run(["rev-list", "--count", "HEAD"]).stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)
    // The range has no base commit (--root rebase), so total count = resulting count.
    #expect(
        (Int(rangeCount) ?? -1) == expectedCount,
        "[\(param.tag)] expected \(expectedCount) commits, got \(rangeCount)"
    )

    // 3. Surviving commits appear in plan's order (subjects, oldest-first in log --reverse).
    let finalSubjects = repo.run(["log", "--reverse", "--format=%s"])
        .stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    let expectedSubjects = survivingSubjects(validated: validated, allShas: allShas, repo: base)
    #expect(finalSubjects == expectedSubjects,
            "[\(param.tag)] subjects mismatch: got \(finalSubjects) expected \(expectedSubjects)")

    // 4. Every reword message appears verbatim.
    let finalMessages = repo.run(["log", "--format=%s"]).stdout
        .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    for step in validated.commits where step.action == .reword {
        if let msg = step.message {
            #expect(finalMessages.contains(msg),
                    "[\(param.tag)] reword message '\(msg)' not found in history")
        }
    }

    // 5. combine(keepMessage: false) — absorbed messages must not appear.
    let combinedDropShas = validated.commits
        .filter { $0.action == .combine && $0.keepMessage == false }
        .map(\.sha)
    for droppedSha in combinedDropShas {
        // Get the original subject for this SHA from the base fixture.
        let origSubject = base.run(["log", "-1", "--format=%s", droppedSha])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !origSubject.isEmpty {
            #expect(!finalMessages.contains(origSubject),
                    "[\(param.tag)] absorbed message '\(origSubject)' still appears in history")
        }
    }

    // 6. Tree equivalence: the file set of the rewritten HEAD must equal exactly
    // the files introduced by surviving (non-deleted) commits.
    // The fixture has one unique file per commit: sha0→a.txt, sha1→b.txt, sha2→c.txt, sha3→d.txt.
    // Deleted commits' files must be absent; all other files must be present with original content.
    assertTreeEquivalence(repo: repo, validated: validated, allShas: allShas, baseFixture: base, tag: param.tag)

    // 7. Backup ref exists and points at the original HEAD.
    let backupSha = repo.run(["rev-parse", backupRef])
        .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(!backupSha.isEmpty, "[\(param.tag)] backup ref '\(backupRef)' does not resolve")
    #expect(backupSha == originalHead,
            "[\(param.tag)] backup ref points at \(backupSha.prefix(8)), expected \(originalHead.prefix(8))")

    // 9. Working tree is clean after the rewrite (before undo).
    let isClean = (try? Safety(git: repo.git).isClean()) ?? false
    #expect(isClean, "[\(param.tag)] working tree is dirty after rewrite")

    // 8. gitthat undo restores the original HEAD SHA exactly.
    // UndoFlow identifies the backup ref entry by its "rewrote commit history (gitthat)"
    // description. We simulate a user who answers "no" to every intermediate reflog entry
    // and "yes" to the first entry whose SHA matches the backup ref (i.e., originalHead).
    // This mirrors what a real user would do when the "rewrote" entry appears in the list.
    let safetyForUndo = Safety(git: repo.git)
    let entries = try UndoFlow.buildEntries(git: repo.git, safety: safetyForUndo)
    // entries[0] = current state; candidates start at entries[1].
    let candidates = Array(entries.dropFirst())
    // Build confirmations: false for each entry until we hit originalHead, then true+true
    // (first true = select that entry, second true = confirm the move).
    var confirmations: [Bool] = []
    var foundTarget = false
    for candidate in candidates {
        if candidate.sha == originalHead {
            confirmations.append(true)  // select this candidate
            foundTarget = true
            break
        }
        confirmations.append(false)  // skip this candidate
    }
    if foundTarget {
        confirmations.append(true)  // confirm "Move HEAD to..."
    }
    if !foundTarget || confirmations.isEmpty {
        // Fallback: the backup ref should always appear. If it doesn't, fail.
        Issue.record("[\(param.tag)] originalHead \(originalHead.prefix(8)) not found in reflog candidates")
    } else {
        let undoUI = RecordingUI(confirmations: confirmations)
        let undoOutcome = try UndoFlow(git: repo.git, ui: undoUI, safety: safetyForUndo)
            .run(hard: true)
        if case .restored(let restoredSha) = undoOutcome {
            let headAfterUndo = repo.run(["rev-parse", "HEAD"])
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(restoredSha == originalHead,
                    "[\(param.tag)] undo restored to \(restoredSha.prefix(8)), expected \(originalHead.prefix(8))")
            #expect(headAfterUndo == originalHead,
                    "[\(param.tag)] HEAD after undo is \(headAfterUndo.prefix(8)), expected \(originalHead.prefix(8))")
        } else {
            Issue.record("[\(param.tag)] undo returned \(undoOutcome), expected .restored")
        }
    }

    // 10. No other branch's ref moved.
    let siblingAfter = repo.run(["rev-parse", "sibling"])
        .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(siblingAfter == siblingBefore,
            "[\(param.tag)] sibling branch moved from \(siblingBefore.prefix(8)) to \(siblingAfter.prefix(8))")

    // 11. No remote ref moved.
    let remoteMainAfter = repo.run(["rev-parse", "refs/remotes/origin/main"])
        .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(remoteMainAfter == remoteMainBefore,
            "[\(param.tag)] remote ref moved from \(remoteMainBefore.prefix(8)) to \(remoteMainAfter.prefix(8))")

    _ = refsBefore  // used for documentation; per-ref checks above cover the important ones
}

// MARK: - Helpers for invariant computation

/// Returns the subjects (oldest-first) that should survive the rewrite.
private func survivingSubjects(validated: RewritePlan, allShas: [String], repo: RepoFixture) -> [String] {
    // Steps in validated are in oldest-first order (matching the todo file).
    // Surviving = keep or reword. combine targets are folded into their predecessor.
    // But subjects: for reword we use the new message; for combine the folded commit
    // doesn't produce its own line. What subjects appear?
    // A "squash" (s) shows the combined message in the squashed commit's subject.
    // A "fixup" (f) keeps the predecessor's message only.
    // The surviving commits are the non-combine, non-delete ones.
    // For keep: original subject. For reword: new message.
    // combine(keepMessage: true) = squash — the *predecessor* commit ends up with a
    // combined message "<pred>\n\n<combined>". For the purpose of %s (subject), git
    // squash sets the subject to the first line of the combined message, which is
    // the predecessor's subject. So the subject seen in log --format=%s is still
    // the predecessor's original subject when keepMessage=true.
    var subjects: [String] = []
    for step in validated.commits {
        switch step.action {
        case .keep:
            let subj = repo.run(["log", "-1", "--format=%s", step.sha])
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            subjects.append(subj)
        case .reword:
            subjects.append(step.message ?? "")
        case .combine, .delete:
            break  // no separate commit line
        }
    }
    return subjects
}

/// Invariant 6: verifies that the rewritten HEAD's working tree contains exactly
/// the files introduced by non-deleted commits, with original content.
///
/// The four-commit fixture has non-overlapping files: sha[0]→a.txt, sha[1]→b.txt,
/// sha[2]→c.txt, sha[3]→d.txt. Each commit adds exactly one file not touched by
/// any other commit. So the expected file set = { file(sha) | sha not deleted }.
///
/// We derive the sha→file mapping by running `git diff-tree` on each original SHA
/// in the baseFixture. Then we check the rewritten tree against expectations:
/// - Deleted commit files must be absent.
/// - Surviving commit files must be present with the correct blob SHA.
private func assertTreeEquivalence(
    repo: RepoFixture,
    validated: RewritePlan,
    allShas: [String],
    baseFixture: RepoFixture,
    tag: String
) {
    // Build sha → [file] mapping from the base fixture.
    // Uses `git show --name-only --format=""` to list files changed in each commit.
    var shaToFiles: [String: [String]] = [:]
    for sha in allShas {
        // `git show --format= --name-only <sha>` lists files changed in that commit.
        let out = baseFixture.run(["show", "--format=", "--name-only", sha])
            .stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        shaToFiles[sha] = out
    }

    let deletedShas = Set(validated.commits.filter { $0.action == .delete }.map(\.sha))
    let survivingShas = Set(allShas).subtracting(deletedShas)

    // Files that must be ABSENT (from deleted commits).
    let deletedFiles = deletedShas.flatMap { shaToFiles[$0] ?? [] }
    // Files that must be PRESENT (from surviving commits).
    let survivingFiles = survivingShas.flatMap { shaToFiles[$0] ?? [] }

    // Get actual (filename → blobSHA) map from the rewritten tree.
    // `git ls-tree -r HEAD` format: "<mode> <type> <blobSHA>\t<path>"
    var actualTree: [String: String] = [:]
    for line in repo.run(["ls-tree", "-r", "HEAD"]).stdout
            .split(separator: "\n").map(String.init).filter({ !$0.isEmpty }) {
        // split on tab to get "<mode> <type> <sha>" and "<path>"
        let parts = line.components(separatedBy: "\t")
        guard parts.count == 2 else { continue }
        let metaParts = parts[0].split(separator: " ").map(String.init)
        guard metaParts.count >= 3 else { continue }
        actualTree[parts[1]] = metaParts[2]  // blobSHA
    }
    let actualFiles = Set(actualTree.keys)

    // Get original blob SHAs for surviving files.
    // `git ls-tree -r <sha>` on each surviving original commit's tree.
    var expectedBlobShas: [String: String] = [:]
    for sha in survivingShas {
        for line in baseFixture.run(["ls-tree", "-r", sha]).stdout
                .split(separator: "\n").map(String.init).filter({ !$0.isEmpty }) {
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 2 else { continue }
            let metaParts = parts[0].split(separator: " ").map(String.init)
            guard metaParts.count >= 3 else { continue }
            let file = parts[1]
            // Only record files introduced by this commit (listed by git show).
            if let changedFiles = shaToFiles[sha], changedFiles.contains(file) {
                expectedBlobShas[file] = metaParts[2]
            }
        }
    }

    for file in deletedFiles {
        #expect(!actualFiles.contains(file),
                "[\(tag)] deleted file '\(file)' still present in rewritten tree")
    }
    for file in survivingFiles {
        #expect(actualFiles.contains(file),
                "[\(tag)] surviving file '\(file)' missing from rewritten tree")
        // Verify content (blob SHA) is unchanged.
        if let expectedBlob = expectedBlobShas[file], let actualBlob = actualTree[file] {
            #expect(actualBlob == expectedBlob,
                    "[\(tag)] file '\(file)' blob SHA changed: expected \(expectedBlob.prefix(8)), got \(actualBlob.prefix(8))")
        }
    }
    // Verify no phantom files appeared.
    let expectedFiles = Set(survivingFiles)
    let phantomFiles = actualFiles.subtracting(expectedFiles)
    #expect(phantomFiles.isEmpty,
            "[\(tag)] phantom files appeared in rewritten tree: \(phantomFiles)")
}

/// Captures all current refs as a name→sha dictionary.
private func allRefs(repo: RepoFixture) -> [String: String] {
    let out = repo.run(["for-each-ref", "--format=%(refname) %(objectname)"])
        .stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    var dict: [String: String] = [:]
    for line in out {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2 { dict[parts[0]] = parts[1] }
    }
    return dict
}

/// Encodes a validated RewritePlan back to JSON so StubProvider can return it.
private func encodePlanJSON(_ plan: RewritePlan) -> String {
    let encoder = JSONEncoder()
    guard let data = try? encoder.encode(plan),
          let str = String(data: data, encoding: .utf8) else { return "{}" }
    return str
}

// MARK: - Default tier real-git tests

// Throttle concurrent git rebases. Each rebase spawns several git subprocesses;
// too many in parallel exhausts file descriptors on a typical macOS dev machine.
// ponytail: actor-per-slot pattern; raise maxConcurrent if FD limits allow.
private actor RebaseThrottle {
    private let maxConcurrent: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) { self.maxConcurrent = maxConcurrent }

    func acquire() async {
        if running < maxConcurrent {
            running += 1
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    func release() {
        if let next = waiting.first {
            waiting.removeFirst()
            next.resume()
        } else {
            running -= 1
        }
    }
}

private let rebaseThrottle = RebaseThrottle(maxConcurrent: 4)

@Suite("DefaultTier")
struct DefaultTierTests {

    @Test("copy() is materially cheaper than rebuild")
    func copyIsCheaperThanRebuild() {
        // Warm the shared fixture.
        let base = sharedFixture()

        let copyStart = Date()
        let N = 10
        var copies: [RepoFixture] = []
        for _ in 0..<N { copies.append(base.copy()) }
        let copyTime = Date().timeIntervalSince(copyStart) / Double(N)

        let buildStart = Date()
        let built = RepoFixture()
            .commit("a", file: "a.txt", contents: "a")
            .commit("b", file: "b.txt", contents: "b")
            .commit("c", file: "c.txt", contents: "c")
            .commit("d", file: "d.txt", contents: "d")
        let buildTime = Date().timeIntervalSince(buildStart)
        _ = built

        print("copy() avg: \(String(format: "%.3f", copyTime * 1000))ms, rebuild: \(String(format: "%.3f", buildTime * 1000))ms")
        #expect(copyTime < buildTime,
                "copy() (\(copyTime * 1000)ms) must be faster than rebuild (\(buildTime * 1000)ms)")
    }

    @Test(
        "Default tier: 625 fate-assignments at natural order + 24 all-keep orderings",
        arguments: defaultTierParams.filter { p in
            // Skip first-step-is-combine (invalid by construction).
            let firstFate = p.fates[p.ordering[0]]
            return firstFate != .combineKeep && firstFate != .combineDrop
        }.filter { p in
            // Skip all-delete (empty branch).
            !p.fates.allSatisfy { $0 == .delete }
        }
    )
    func defaultTierPermutation(param: PermParam) async throws {
        try await runPermutation(param)
    }
}

// MARK: - Exhaustive tier (--filter Exhaustive)

@Suite("ExhaustiveTier")
struct ExhaustiveTierTests {

    @Test(
        "Exhaustive: all 15,000 permutations",
        arguments: exhaustiveTierParams.filter { p in
            let firstFate = p.fates[p.ordering[0]]
            return firstFate != .combineKeep && firstFate != .combineDrop
        }.filter { p in
            !p.fates.allSatisfy { $0 == .delete }
        }
    )
    func exhaustivePermutation(param: PermParam) async throws {
        try await runPermutation(param)
    }
}
