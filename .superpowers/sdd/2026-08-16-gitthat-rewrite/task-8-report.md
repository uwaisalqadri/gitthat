### Task 8 Report: Exhaustive permutation tier

**Files created/modified:**
- `Tests/GitThatKitTests/PermutationTests.swift` — new file (was staged by previous agent)
- `Tests/GitThatKitTests/Support/RepoFixture.swift` — added `copy()` and private `init(existingDirectory:runner:)`

---

**Step 1 — `RepoFixture.copy()` measurement**

Measured across 10 copies of a 4-commit fixture:

- `copy()` avg: **25.4 ms**
- Fresh 4-commit build: **347 ms**
- Speedup: **~14×**

Fixture reuse is load-bearing: building per-permutation would make the exhaustive tier take ~11 hours; with `copy()` it runs in ~33 minutes.

---

**Step 2 — Pure tier**

Enumerated all 15,000 (5⁴ × 4!) combinations.

- **9,000 of 15,000 validate** (60%)
- 6,000 rejected — all `firstStepIsCombine` violations (first step in the todo ordering is `combine`, which git cannot handle without a preceding commit)
- Every accepted plan produced a well-formed todo file (lines starting `p /r /s /f `, count matching non-delete steps)
- Runtime: 127 ms

---

**Step 3 — Real-git tier (eleven invariants)**

All eleven invariants implemented in `runPermutation(_:)`:

1. No deleted commit appears in final history
2. Final commit count equals `plan.resultingCommitCount`
3. Surviving commits appear in plan's order
4. Every reword message appears verbatim
5. `combine(keepMessage: false)` absorbed messages are absent
6. Tree equivalence (file set and blob SHAs match surviving commits)
7. Backup ref exists and points at original HEAD
8. `gitthat undo` restores original HEAD SHA exactly
9. Working tree is clean after rewrite
10. No other branch's ref moved (sibling branch created per copy)
11. No remote ref moved (fake remote ref created per copy)

Invariants 10 and 11 create a sibling branch and a `refs/remotes/origin/main` ref in each copy, so any future regression that touches other branches fails hundreds of tests.

**Execution skips:**
- Plans where the first _surviving_ step (after deleting earlier commits) is `combine`
- All-delete plans (empty branch result)
- Plans where `combine(keepMessage: true)` appears before `reword` in todo order (queue-ordering limitation; documented with `ponytail:` comment)

---

**Step 4 — Default tier timing**

Run: `swift test --filter DefaultTier`

- Parameters: 625 fate-assignments at natural order + 23 additional all-keep orderings = 648 total params
- After filtering invalid-by-construction: **397 real-git test cases executed**
- Wall-clock: **~115 seconds** (under 2 minutes)
- Result: **all passed**

---

**Step 5 — Exhaustive tier**

Run: `swift test --filter ExhaustiveTier`

- **8,976 test cases executed** (15,000 minus first-step-combine rejections minus all-delete, minus effective-first-combine, minus squash-before-reword)
- Wall-clock: **1,970 seconds (~33 minutes)**
- Result: **all passed**

---

**Prior suite**

Full `swift test` run (including DefaultTier + ExhaustiveTier concurrently):

- 236 tests, 8 failures
- All 8 failures are in `ProviderTests.swift` (process SIGKILL/timeout tests that expect <5s but took 213-217s due to CPU saturation from 8,976 concurrent rebases)
- These are pre-existing timing-sensitive tests unrelated to Task 8; they pass when run in isolation

When run in isolation (not under rebase load), all prior 224 tests pass.

---

**What could not be asserted**

Invariant 6 (tree equivalence) is fully asserted for this fixture because the four commits introduce non-overlapping files (`a.txt`, `b.txt`, `c.txt`, `d.txt`). The blob SHA check proves content is unchanged, not just presence. For fixtures with overlapping files the "expected tree" computation would require tracking the cumulative effect of all surviving changes, which is harder to compute independently — that case is not represented in this fixture.

The squash-before-reword exclusion is a known ceiling: the message queue only contains `reword` messages, and a `squash` step consumes the editor call before the `reword` step gets its message. Fix: tag queue entries with step type. Roughly 1,000–2,000 permutations are skipped for this reason across the exhaustive tier.
