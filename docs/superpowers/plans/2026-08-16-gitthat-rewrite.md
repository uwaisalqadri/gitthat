# GITTHAT Plan 2 — `gitthat rewrite` and `gitthat undo`

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `gitthat rewrite` — reshaping the commits on the current branch — and `gitthat undo`, the safety net that makes it usable.

**Architecture:** Same oracle loop as Plan 1. GITTHAT gathers the commit range, asks the provider for a plan, validates it against a closed type, previews before and after, writes a backup ref, then drives `git rebase -i` non-interactively via `GIT_SEQUENCE_EDITOR`. The agent returns JSON and never touches the repository.

**Tech Stack:** Swift 6.3, SwiftPM, Swift Testing, `swift-argument-parser` 1.8.2, `TOMLKit` 0.6.0. All of Plan 1's `GitThatKit` is available.

**Spec:** `docs/superpowers/specs/2026-08-13-gitthat-design.md` is the source of truth — sections "gitthat rewrite", "gitthat undo", "Safety rules", and "Layer 2 — exhaustive permutations". Where this plan and the spec disagree, the spec wins; report the conflict rather than guessing.

## Global Constraints

These apply to every task without being repeated.

- **Swift 6.3**, tools version 6.0, `.macOS(.v13)`.
- **Swift Testing** (`import Testing`, `@Test`, `#expect`). Never XCTest.
- **No user-facing string may contain `rebase`, `squash`, `fixup`, or `pick`.** Plan 1's lint enforces the first three; this plan ADDS `pick` and `todo` to the forbidden list, because this is the plan that introduces them internally. Git's vocabulary is confined to one translation table.
- **`GitThatKit` must not import `ArgumentParser`.** Only the executable target parses arguments.
- **No `@MainActor` anywhere.** The repository has zero and must keep it. For a non-`Sendable` global constant use `nonisolated(unsafe)`.
- **Every type crossing an `async` boundary is `Sendable`.**
- **Tests create repositories in fresh temp directories** and remove them afterwards, with `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM` set to `/dev/null` and `GIT_AUTHOR_*`/`GIT_COMMITTER_*` identities set. Reuse `Tests/GitThatKitTests/Support/TestSupport.swift`.
- **NEVER run `git commit`,** and **never run the `gitthat` binary inside this repository** — it commits. Use a scratch repo under `$(mktemp -d)` with absolute paths and `git -C`. Never chain `cd` with `;`.
- **Safety rules are not configurable.** There is no flag that skips a backup ref, no flag that pushes, no flag that operates on another branch.

## Prior art you must reuse

Plan 1 built these and they are stable. Do not reimplement:

| Existing | Use it for |
| --- | --- |
| `Git(runner:directory:)` | all git access; add methods rather than shelling out separately |
| `GitRunner` / `SystemGitRunner` | process execution, deadlock-free via temp files |
| `Provider` / `CLIProvider` / `StubProvider` | the agent seam |
| `Config` | `[rewrite] autostash`, `verify` already parse |
| `UserInterface` / `TerminalUI` / `RecordingUI` | prompts and confirmation |
| `Render` | preview rendering conventions |
| `RepoFixture` | building real test repositories |
| `SubjectCase` | casing enforcement on reworded messages |

## File Structure

```
Sources/GitThatKit/
  RewritePlan.swift        Codable plan + validation. Inert — never executes.
  TodoFile.swift           the ONLY place git's todo vocabulary exists
  Safety.swift             backup refs, range resolution, pushed detection, dirty guard
  RewritePrompts.swift     prompt construction for plan generation
  RewriteRender.swift      before/after preview
  RewriteFlow.swift        the oracle loop for rewrite
  UndoFlow.swift           reflog reading and restore
Sources/gitthat/
  RewriteCommand.swift     `gitthat rewrite`
  UndoCommand.swift        `gitthat undo`
  EditMessageCommand.swift hidden `__edit-message`, acts as GIT_EDITOR
Tests/GitThatKitTests/
  RewritePlanTests.swift
  TodoFileTests.swift
  SafetyTests.swift
  RewritePromptsTests.swift
  RewriteFlowTests.swift
  UndoFlowTests.swift
  PermutationTests.swift   the exhaustive tier
```

---

### Task 1: Safety — range resolution, pushed detection, backup refs

Nothing else in this plan may run until a rewrite is recoverable.

**Files:**
- Create: `Sources/GitThatKit/Safety.swift`
- Modify: `Sources/GitThatKit/Git.swift` (add the queries Safety needs)
- Test: `Tests/GitThatKitTests/SafetyTests.swift`

**Interfaces:**
- Consumes: `Git`, `GitRunner` from Plan 1.
- Produces:
  - `struct CommitInfo: Sendable, Equatable { let sha: String; let subject: String; let isPushed: Bool }`
  - `struct CommitRange: Sendable, Equatable { let commits: [CommitInfo]; let baseSha: String?; var hasPushed: Bool }` — `commits` is ordered oldest-first, matching todo-file order.
  - `struct Safety: Sendable` with `init(git: Git)`, and methods `resolveRange(count: Int?) throws -> CommitRange`, `createBackupRef() throws -> String`, `backups() throws -> [BackupRef]`, `restore(to sha: String, hard: Bool) throws`, `isClean() throws -> Bool`.
  - `struct BackupRef: Sendable, Equatable { let name: String; let sha: String; let timestamp: Date }`
  - `enum SafetyError: Error, Equatable { case dirtyTree, noUpstreamAndNoDefaultBranch, emptyRange, detachedHead }`
- New `Git` methods: `revList(_ range: String) throws -> [String]`, `subject(of sha: String) throws -> String`, `upstreamRef() throws -> String?`, `defaultBranchRef() throws -> String?`, `mergeBase(_ a: String, _ b: String) throws -> String?`, `updateRef(_ name: String, to sha: String) throws`, `refsMatching(_ prefix: String) throws -> [(String, String)]`, `resetHard(to sha: String) throws`, `resetSoft(to sha: String) throws`, `headSha() throws -> String`, `isAncestor(_ a: String, of b: String) throws -> Bool`.

**Behaviour, from the spec:**
- Range defaults to `@{upstream}..HEAD`. With no upstream, fall back to the merge-base with the default branch. `count` overrides both.
- A commit is `isPushed` when it is an ancestor of the upstream ref. With no upstream, nothing is pushed.
- Backup refs are `refs/gitthat/backup/<unix-timestamp>` and are written BEFORE git is touched. They are retained afterwards.
- Dirty trees are refused unless the caller passes `--autostash`; `Safety` only reports cleanliness, the flow decides.

- [ ] **Step 1: Write the failing tests**

`Tests/GitThatKitTests/SafetyTests.swift` — cover at minimum:

```swift
import Foundation
import Testing
@testable import GitThatKit

@Test func resolvesUnpushedCommitsByDefault() throws {
    let repo = RepoFixture()
        .commit("feat: one", file: "a.txt", contents: "1")
        .commit("feat: two", file: "b.txt", contents: "2")
        .push()                                     // both are now upstream
        .commit("feat: three", file: "c.txt", contents: "3")

    let range = try Safety(git: repo.git).resolveRange(count: nil)

    #expect(range.commits.map(\.subject) == ["feat: three"])
    #expect(range.hasPushed == false)
}

@Test func marksPushedCommitsWhenCountReachesPastUpstream() throws {
    let repo = RepoFixture()
        .commit("feat: one", file: "a.txt", contents: "1")
        .commit("feat: two", file: "b.txt", contents: "2")
        .push()
        .commit("feat: three", file: "c.txt", contents: "3")

    let range = try Safety(git: repo.git).resolveRange(count: 3)

    #expect(range.commits.map(\.subject) == ["feat: one", "feat: two", "feat: three"])
    #expect(range.commits.map(\.isPushed) == [true, true, false])
    #expect(range.hasPushed)
}

@Test func rangeIsOrderedOldestFirst() throws { /* assert explicit ordering */ }

@Test func fallsBackToMergeBaseWithoutUpstream() throws { /* no push(); assert non-empty range */ }

@Test func emptyRangeIsReported() throws {
    let repo = RepoFixture().commit("feat: one", file: "a.txt", contents: "1").push()
    #expect(throws: SafetyError.emptyRange) {
        try Safety(git: repo.git).resolveRange(count: nil)
    }
}

@Test func backupRefPointsAtHeadAndSurvives() throws {
    let repo = RepoFixture().commit("feat: one", file: "a.txt", contents: "1")
    let safety = Safety(git: repo.git)
    let head = try repo.git.headSha()

    let name = try safety.createBackupRef()

    #expect(name.hasPrefix("refs/gitthat/backup/"))
    let found = try safety.backups()
    #expect(found.contains { $0.sha == head })
}

@Test func restoreMovesBranchBackToBackup() throws { /* commit, backup, commit again, restore, assert head */ }

@Test func detectsDirtyTree() throws { /* write without staging; assert isClean() == false */ }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SafetyTests`
Expected: FAIL — `cannot find 'Safety' in scope`.

- [ ] **Step 3: Implement `Git`'s new queries, then `Safety`**

Follow `Git.swift`'s existing conventions exactly: no policy, a `require` helper for commands that must succeed, and a non-zero exit treated as a value where that is meaningful (as `hasStagedChanges` already does). `isAncestor` uses `git merge-base --is-ancestor` and reads its exit code — 0 means yes, 1 means no, anything else is an error.

`Safety` holds the policy: which range, what counts as pushed, where backups live.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SafetyTests`
Expected: PASS.

- [ ] **Step 5: Stage for review**

```bash
git add -A
# Do not commit. Stop here and report.
```

---

### Task 2: The rewrite plan and its validation

**Files:**
- Create: `Sources/GitThatKit/RewritePlan.swift`
- Test: `Tests/GitThatKitTests/RewritePlanTests.swift`

**Interfaces:**
- Consumes: `CommitRange`, `CommitInfo` from Task 1.
- Produces:
  - `enum RewriteAction: String, Sendable, Codable, CaseIterable { case keep, combine, reword, delete }`
  - `struct RewriteStep: Sendable, Codable, Equatable { let sha: String; let action: RewriteAction; let keepMessage: Bool?; let message: String? }`
  - `struct RewritePlan: Sendable, Codable, Equatable { let commits: [RewriteStep] }`
  - `enum PlanError: Error, Equatable { case shaOutsideRange(String), duplicateSha(String), missingCommit(String), firstStepIsCombine, rewordWithoutMessage(String), emptyPlan, notJSON(String) }`
  - `extension RewritePlan { static func decode(_ raw: String) throws -> RewritePlan; func validated(against range: CommitRange) throws -> RewritePlan; var resultingCommitCount: Int }`

**The model, from the spec:** the plan is the history the user wants, IN ORDER. Reordering is not an action — moving a commit means listing it elsewhere. `combine` merges a commit into the one before it; `keepMessage` decides whether its message survives.

**Validation rules — each needs a test:**
1. Every SHA appears in the range. Otherwise `shaOutsideRange`.
2. No SHA appears twice. Otherwise `duplicateSha`.
3. Every commit in the range appears in the plan. Otherwise `missingCommit`.
4. The first step is not `combine` — nothing precedes it. Otherwise `firstStepIsCombine`.
5. A `reword` step carries a non-empty message. Otherwise `rewordWithoutMessage`.
6. A plan with no steps is rejected. Otherwise `emptyPlan`.
7. `decode` tolerates the mess agents produce — fenced JSON, preamble prose — by reusing `ResponseParser.stripFences`. Anything still unparseable throws `notJSON` carrying the raw text, so the flow can show it.

`resultingCommitCount` is the number of steps that are neither `delete` nor `combine`. The permutation tier in Task 8 asserts against it.

Because the type is closed over four actions, a plan cannot express pushing, resetting, or touching another branch. Say so in a comment — it is a safety property, not an implementation detail.

- [ ] **Step 1: Write the failing tests** — one per validation rule plus round-trip `Codable` tests and at least four `decode` tolerance cases (bare JSON, fenced, fenced with language tag, preamble then fenced).
- [ ] **Step 2: Run to verify they fail.** Expected: `cannot find 'RewritePlan' in scope`.
- [ ] **Step 3: Implement.** Pure logic, no git, no I/O.
- [ ] **Step 4: Run to verify they pass.**
- [ ] **Step 5: Stage for review** (`git add -A`, do not commit).

---

### Task 3: Plan to todo-file translation

**Files:**
- Create: `Sources/GitThatKit/TodoFile.swift`
- Test: `Tests/GitThatKitTests/TodoFileTests.swift`

**Interfaces:**
- Consumes: `RewritePlan`, `RewriteStep`, `RewriteAction`.
- Produces: `enum TodoFile { static func render(_ plan: RewritePlan) -> String; static func messageQueue(_ plan: RewritePlan) -> [String] }`

**This is the ONLY file in the project where git's todo vocabulary may appear.** The translation, from the spec:

| Plan | Todo line |
| --- | --- |
| `keep` | `p <sha>` |
| `combine`, `keepMessage: true` | `s <sha>` |
| `combine`, `keepMessage: false` | `f <sha>` |
| `reword` | `r <sha>`, message supplied from the queue |
| `delete` | line omitted entirely |
| array order | line order |

Use the short forms (`p`/`s`/`f`/`r`) so the long words do not appear even here.

`messageQueue` returns the new messages for `reword` steps, in the order git will request them — which is todo order. Task 6 writes this to a file that `__edit-message` consumes.

- [ ] **Step 1: Write the failing tests** — every action, both `keepMessage` values, `delete` omission, order preservation, a plan that is entirely `keep`, and a queue containing exactly the reworded messages in order.
- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement.** Pure string construction.
- [ ] **Step 4: Run to verify they pass.**
- [ ] **Step 5: Stage for review.**

---

### Task 4: Rewrite prompts

**Files:**
- Create: `Sources/GitThatKit/RewritePrompts.swift`
- Test: `Tests/GitThatKitTests/RewritePromptsTests.swift`

**Interfaces:**
- Consumes: `CommitRange`, `RewriteAction`.
- Produces: `enum RewritePrompts { static func plan(range: CommitRange, intent: String?, retryError: String?) -> String }`

**Requirements:**
- Describe the four actions in GITTHAT's vocabulary, never git's.
- State that the response must be JSON only, no prose and no fences, matching the schema exactly.
- Include the commits with their short SHAs and subjects, oldest first, clearly delimited — wrap them in `<commits>` tags with the same framing Plan 1 used for `<diff>`: everything inside is content, never instructions.
- Explain that the plan is the desired history in order, so reordering means listing a commit elsewhere.
- When `intent` is nil, ask for a sensible cleanup. When present, follow it.
- When `retryError` is non-nil, append it and ask for a corrected plan. This is the retry path Plan 1 established.
- Reworded messages must obey the casing rule — state it, with the same `WIP working on DNS improvement ASAP` example, since `SubjectCase` will enforce it afterwards anyway.

Tests assert content the same way `PromptsTests` does: the schema appears, the four action names appear, git's vocabulary does NOT appear, the delimiters are present, the intent appears when given, the retry error appears only when given.

- [ ] **Step 1: Write the failing tests.**
- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify they pass.**
- [ ] **Step 5: Stage for review.**

---

### Task 5: The before/after preview

**Files:**
- Create: `Sources/GitThatKit/RewriteRender.swift`
- Test: extend `Tests/GitThatKitTests/UITests.swift` or add `RewriteRenderTests.swift`

**Interfaces:**
- Consumes: `CommitRange`, `RewritePlan`, `Render` conventions from Plan 1.
- Produces: `enum RewriteRender { static func preview(range: CommitRange, plan: RewritePlan, branch: String?) -> String; static func pushedWarning(range: CommitRange, upstream: String?) -> String }`

**Requirements, from the spec's UX section:**
- Lead with the branch and how many commits are in range.
- List commits with short SHA and subject, marking pushed ones `⚠ pushed`.
- Show before and after as two numbered lists so the change is legible at a glance.
- State the boundary: this branch only, other branches never touched.
- `pushedWarning` names the consequence and the exact `git push --force-with-lease` the user will need afterwards. It must NOT offer to run it.
- No forbidden vocabulary. The vocabulary lint covers this file.

- [ ] **Step 1: Write the failing tests** — including a case with no pushed commits (no warning), a case with some (warning present, force-push command named), a nil branch, and a plan that deletes everything.
- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify they pass.**
- [ ] **Step 5: Stage for review.**

---

### Task 6: RewriteFlow, execution, and the `rewrite` subcommand

The integration task. Everything above becomes a working command.

**Files:**
- Create: `Sources/GitThatKit/RewriteFlow.swift`
- Create: `Sources/gitthat/RewriteCommand.swift`
- Create: `Sources/gitthat/EditMessageCommand.swift`
- Modify: `Sources/gitthat/GitThat.swift` (register both subcommands; `__edit-message` hidden)
- Test: `Tests/GitThatKitTests/RewriteFlowTests.swift`

**Interfaces:**
- Produces:
  - `enum RewriteOutcome: Sendable, Equatable { case rewritten(backupRef: String), cancelled, nothingToRewrite, conflicted }`
  - `struct RewriteFlow` with `init(git:provider:config:ui:safety:)` and `func run(intent: String?, count: Int?, autostash: Bool) async throws -> RewriteOutcome`
  - `enum RewriteFlowError: Error, Equatable { case notARepository, crossBranchRequest(String), dirtyTree, planRejected(raw: String) }`

**The flow, in order — each step is a guard the next depends on:**
1. Verify it is a repository.
2. **Decline cross-branch requests.** If `intent` names another branch, throw `crossBranchRequest` with the spec's exact message pointing at git. Detect by comparing intent words against actual branch names from `git branch --format=%(refname:short)` — do not guess with a keyword list.
3. Refuse a dirty tree unless `autostash`.
4. Resolve the range. Empty range returns `.nothingToRewrite`.
5. Build the prompt, ask the provider, decode and validate. On failure retry ONCE with the validation error appended; a second failure throws `planRejected` carrying the raw output, which the flow shows.
6. Preview. Confirm.
7. If the range includes pushed commits, show `pushedWarning` and require a SEPARATE confirmation.
8. Write the backup ref. Only now is git touched.
9. Write the todo file and the message queue, then run `git rebase -i`.
10. On conflict, return `.conflicted` after telling the user their options — `gitthat rewrite --resume` or `--cancel`. **No AI conflict resolution in this plan;** that is Plan 3.
11. On success, run `[rewrite] verify` if configured. Report failure and name `gitthat undo`; do not roll back automatically.

**Execution mechanics:**
- `GIT_SEQUENCE_EDITOR` is set to a command that writes the generated todo over the file git passes as `$1`. `printf '%s' "$TODO" > "$1"` via `sh -c` is sufficient; pass the todo through the environment, not the command string, so quoting cannot break it.
- `GIT_EDITOR` is set to the absolute path of the running binary plus `__edit-message`, with `GITTHAT_MESSAGE_QUEUE` pointing at a file holding the reworded messages separated by a NUL byte (messages contain newlines, so newline is not a safe separator).
- `EditMessageCommand` reads the queue file, writes the first remaining message to the path git gave it, rewrites the queue without that entry, and exits 0. If the queue is empty it leaves the file untouched and exits 0 — git's own message then stands, which is the safe failure.
- Resolve the running binary's path with `CommandLine.arguments[0]` made absolute; a relative path breaks once git changes directory.

**Interruption:** `--resume` and `--cancel` map to `git rebase --continue` / `--abort` internally, detected by the presence of `.git/rebase-merge` or `.git/rebase-apply`. Accept `--continue` and `--abort` as hidden aliases.

**Tests** use `StubProvider` with canned JSON and `RecordingUI` with scripted answers, over `RepoFixture` repositories. Cover at minimum: a successful combine; a reword landing the exact message; a delete; cancelled at the first confirmation leaves history untouched; pushed commits require the second confirmation and declining it changes nothing; a backup ref exists afterwards and points at the original HEAD; cross-branch intent is declined without touching git; an invalid plan retries once then reports raw output; a dirty tree is refused; `verify` failure is reported without rolling back.

- [ ] **Step 1: Write the failing tests.**
- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement `RewriteFlow`.**
- [ ] **Step 4: Implement the subcommands and register them.**
- [ ] **Step 5: Run the full suite.**
- [ ] **Step 6: Prove the binary works end to end** in a scratch repo under `$(mktemp -d)` with a fake provider script returning fixed JSON. Verify: three commits combine into one; the resulting log is correct; `refs/gitthat/backup/*` exists. **Never run the binary in this repository.**
- [ ] **Step 7: Stage for review.**

---

### Task 7: `gitthat undo`

**Files:**
- Create: `Sources/GitThatKit/UndoFlow.swift`
- Create: `Sources/gitthat/UndoCommand.swift`
- Modify: `Sources/gitthat/GitThat.swift`
- Test: `Tests/GitThatKitTests/UndoFlowTests.swift`

**Interfaces:**
- Produces:
  - `struct UndoEntry: Sendable, Equatable { let sha: String; let description: String; let age: String }`
  - `struct UndoFlow` with `init(git:ui:safety:)` and `func run(hard: Bool) throws -> UndoOutcome`
  - `enum UndoOutcome: Sendable, Equatable { case restored(sha: String), cancelled, nothingToUndo }`

**Requirements, from the spec:** `undo` is deliberately broader than undoing GITTHAT's own actions. It reads the reflog and renders it in plain language:

```
1.  3 min ago   rewrote 4 commits into 2
2.  1 hr ago    committed "fix token refresh"
3.  2 hr ago    switched to feature/sso
```

- Read `git reflog --format=%H%x09%gs%x09%gd%x09%cr` and translate git's reflog subjects into plain language. A reflog entry beginning with `rebase` must be rendered as a rewrite, never with git's word.
- Cross-reference `refs/gitthat/backup/*` so GITTHAT's own operations are described precisely.
- The user picks an entry, sees exactly what moves, and confirms.
- Only the branch ref moves. The working tree is untouched unless `--hard`.
- An empty reflog returns `.nothingToUndo`.

**Tests:** a commit then undo restores the previous HEAD; a rewrite then undo restores the original; declining changes nothing; `--hard` versus default is asserted against the working tree; reflog descriptions contain no forbidden vocabulary.

- [ ] **Step 1: Write the failing tests.**
- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify they pass.**
- [ ] **Step 5: Stage for review.**

---

### Task 8: The exhaustive permutation tier

The spec's Layer 2. This is what makes the rewrite trustworthy.

**Files:**
- Create: `Tests/GitThatKitTests/PermutationTests.swift`
- Modify: `Tests/GitThatKitTests/Support/RepoFixture.swift` (add cheap copying)

**Requirements:**

For a four-commit fixture, each commit takes one of five fates — `keep`, `combine(keepMessage: true)`, `combine(keepMessage: false)`, `reword`, `delete` — across all orderings: `5⁴ × 4! = 15,000` plans.

**Pure tier (always runs).** Enumerate all 15,000, feed each to `validated(against:)` and, when valid, to `TodoFile.render`. Assert the accept/reject decision matches the rules and every accepted plan renders a well-formed todo file. Microseconds each.

**Real-git tier (tiered by cost).** Measured on this machine: building a four-commit repo costs ~2.7s, copying a built `.git` costs ~34ms, one rebase costs ~316ms. **Fixture reuse is load-bearing, not an optimisation** — build each distinct shape once per suite and hand out copies via `RepoFixture.copy()`.

- Default `swift test`: all 625 fate-assignments at natural order plus the 24 orderings of all-`keep`. About 650 real rewrites.
- `swift test --filter Exhaustive`: the full 15,000. Nightly.

**Every executed permutation asserts these eleven invariants:**

1. No `delete` commit appears in the final history.
2. Final commit count equals `plan.resultingCommitCount`.
3. Surviving commits appear in the plan's order.
4. Every `reword` message appears verbatim.
5. `combine(keepMessage: false)` leaves no trace of the absorbed message.
6. The final tree matches the tree produced by applying the same surviving changes — content preserved, only shape changed.
7. A backup ref exists and points at the original HEAD.
8. `gitthat undo` restores the original HEAD SHA exactly.
9. The working tree is clean.
10. **No other branch's ref moved.**
11. **No remote ref moved.**

Invariants 10 and 11 are the product boundary as a test. They run on every permutation, so any future change that reaches beyond the current branch fails hundreds of tests rather than shipping.

Skip permutations that are invalid by construction (first step `combine`, all-`delete` producing an empty branch) — assert they are REJECTED by validation rather than executing them.

- [ ] **Step 1: Add `RepoFixture.copy()`** and prove it is materially cheaper than building, with a measurement in the report.
- [ ] **Step 2: Write the pure tier** and run it. Report how many of the 15,000 validate.
- [ ] **Step 3: Write the real-git tier** with the eleven invariants.
- [ ] **Step 4: Run the default tier** and report wall-clock time. If it exceeds three minutes, reduce the default set and say so.
- [ ] **Step 5: Run the exhaustive tier once** and report the result and duration.
- [ ] **Step 6: Stage for review.**

---

### Task 9: Vocabulary expansion and deferred cleanup

**Files:**
- Modify: `Tests/GitThatKitTests/VocabularyLintTests.swift`
- Modify: files named below
- Modify: `docs/superpowers/specs/2026-08-13-gitthat-design.md` if any behaviour here diverges

**Add `pick` and `todo` to the forbidden list.** Plan 1 deferred them because `pick` is ordinary English and nothing used it. This plan introduces both. Allow them ONLY in `Sources/GitThatKit/TodoFile.swift`, which is the single translation point, and in comments. If the lint then fires on legitimate copy, reword the copy rather than widening the exemption.

**Clear the deferred minors triaged for Plan 2:**
1. `truncatesLargeDiffsAndSaysSo` would pass on an empty string — assert the exact 8192 boundary and a `diff --git` prefix.
2. `TicketID` has no word-boundary anchors, so `myPROJ-1thing` yields `PROJ-1` — anchor it.
3. Prose appearing before an opening fence bypasses `stripFences` — handle it.
4. Config type mismatches (`max_subject = "seventy"`) are silently ignored — throw, matching how invalid enum values already behave.
5. An unreadable config file is treated as missing — distinguish them.
6. ANSI escapes are emitted when piped to a non-TTY — guard with `isatty(STDOUT_FILENO)`.

Each needs a test that fails before the change.

- [ ] **Step 1: Expand the lint and confirm it fails on `pick` outside `TodoFile.swift`.**
- [ ] **Step 2: Fix each deferred minor, test first.**
- [ ] **Step 3: Run the full suite and `scripts/check-own-history.sh`.**
- [ ] **Step 4: Stage for review.**

---

## Definition of done

- `gitthat rewrite` combines, rewords, deletes, and reorders commits on the current branch, driven by natural-language intent.
- `gitthat undo` restores from any reflog entry, and from GITTHAT's own backup refs by name.
- Cross-branch requests are declined; nothing pushes; a backup ref precedes every history operation.
- The permutation tier passes with all eleven invariants.
- `pick` and `todo` join the forbidden vocabulary, confined to `TodoFile.swift`.
- The whole suite passes and `scripts/check-own-history.sh` reports clean.

## Out of scope — Plan 3

- **Conflict resolution.** `rewrite` stops at conflicts and hands back `--resume` / `--cancel`. The per-file AI-drafted resolution, the editor prefill, and safety rule 4 belong to Plan 3.
- **Splitting a commit.** Every action here maps an existing commit to a fate; splitting invents commits that never existed.
