# GITTHAT — Design

**Date:** 2026-08-13
**Status:** Approved for planning
**Diagrams:** [`docs/architecture.puml`](../../architecture.puml)

## What it is

A Swift CLI for **rewriting history** — reshaping the commits on your current
branch into the ones you meant to write. It writes commit messages, restructures
the commits already made, and undoes either.

It uses whichever agent CLI the user already has installed and logged in, so it
spends an existing subscription rather than requiring an API key.

## Why

Git records what happened. What people want to publish is what they *meant* to
do — a clean sequence of changes, each with a message that explains itself.
Getting from one to the other is the daily work this tool does, and it splits
into two problems.

Commit messages are friction. People write `fix stuff` because writing a good
message costs more attention than the commit is worth in the moment.

Rewriting history is understood as a concept and memorised as a procedure. Most
people know exactly what they want — fold these three into one, fix that
message, drop the debug commit — and then have to translate it into a todo-file
syntax they relearn every time, hoping nothing stops halfway. The intent is
easy. The mechanism is what stops them.

So GITTHAT takes the intent and produces the mechanism. Existing tools solve the
message problem and not the history problem; the history problem is the
differentiator.

## Boundaries

These are product decisions, not implementation limits. Each one exists to make
the tool explainable in a sentence.

**Current branch only.** GITTHAT edits the history of the branch you are
standing on. It has no concept of `--onto`, no cross-branch operations, no
merges, no cherry-picks. Requests that imply another branch are declined by
name, with a pointer to the git command that does it.

**Never pushes.** Not behind a flag, not after a rewrite, not ever. When a
rewrite leaves the branch diverged from its remote, GITTHAT prints the
`git push --force-with-lease` command for the user to run themselves.

**Rewriting pushed commits is allowed, but marked.** The default range is
unpushed work. Reaching past that line is permitted and requires a separate,
explicit confirmation that names the consequence.

**The agent never touches the repository.** It receives a string and returns a
string. Every git command that runs is chosen and executed by GITTHAT.

## Architecture: the oracle model

The agent CLI is a pure function from text to text. GITTHAT gathers context,
builds a prompt, sends it, parses what comes back, validates it, shows it to the
user, and then runs git itself.

```
gather git context → build prompt → Provider.complete() → parse
    → validate → preview → confirm → GITTHAT runs git
```

Every command is a variation on this loop.

Three consequences justify the extra code over simply delegating to a
tool-capable agent:

**Any provider works.** `ollama run qwen2.5-coder` cannot call tools; it can only
produce text. Delegation would restrict the tool to `claude` and `codex`.
Oracle works with anything that emits a string.

**History operations can be gated.** A preview-and-confirm step is only possible
for operations GITTHAT executes. Under delegation the agent has already acted by
the time the user sees anything.

**It is testable.** `Provider` is the single seam where non-determinism enters,
so stubbing one protocol makes the entire system deterministic under test. The
alternative is asserting on live LLM output, which fails randomly.

### Modules

One SwiftPM package, two targets. The executable is thin — argument parsing
only — so all logic is testable without spawning a binary.

| Module | Responsibility |
| --- | --- |
| `Git` | Process wrapper. Runs git, returns stdout/stderr/exit code. Typed queries: `stagedDiff()`, `log(n)`, `status()`, `reflog()`, `rangeInfo()`. Makes no decisions. |
| `Provider` | `protocol Provider { func complete(_ prompt: String) async throws -> String }`. One implementation, `CLIProvider`, spawns a configured command with the prompt on stdin. |
| `Config` | Loads `~/.config/gitthat/config.toml`, overlaid by `./.gitthat.toml`. |
| `Prompts` | Builds prompts per task. Pure string construction. |
| `Plan` | `Codable` description of a history rewrite. Validates against an allowlist. Inert — never executes anything. |
| `Safety` | Backup refs, dirty-tree guards, pushed-commit detection. |
| `UI` | ANSI rendering, previews, confirmation prompts, `$EDITOR` handoff. |

Two boundaries carry the design: `Git` holds no policy, and `Plan` holds no
behaviour. Policy lives in the command layer between them, which is the only
place that needs reasoning about when something goes wrong.

### Dependencies

- `swift-argument-parser` — Apple-maintained, the standard choice.
- `TOMLKit` — config parsing. JSON would avoid the dependency but has no
  comments, which is worse for a file meant to be hand-edited.

Swift 6.3, Swift Testing rather than XCTest.

## Providers

A subscription does not grant API access. Claude Pro/Max gives nothing at
`api.anthropic.com`; ChatGPT Plus gives nothing at OpenAI's API. The only way to
spend a subscription programmatically is through the vendor's own CLI, already
authenticated on the machine.

So there is one provider implementation: spawn a configured command, write the
prompt to stdin, read stdout.

```toml
provider = "claude"

[providers.claude]
command = ["claude", "-p"]
timeout = 60

[providers.codex]
command = ["codex", "exec"]

[providers.ollama]
command = ["ollama", "run", "qwen2.5-coder"]
```

This covers every subscription-backed agent and every local model with the same
code path. When a new agent CLI ships, the user adds three lines rather than
waiting for a GITTHAT release.

The cost is latency: roughly 2–4 seconds for `claude -p` against roughly 800ms
for a direct API call. Accepted. The `Provider` protocol leaves room for an HTTP
implementation later if this proves annoying in practice.

On first run with no config, GITTHAT scans `PATH` for known agent CLIs and
writes a config selecting the first one found.

## Configuration reference

`~/.config/gitthat/config.toml` holds defaults. `./.gitthat.toml` overlays it
per key and is meant to be committed, so a team shares commit style without
anyone configuring anything.

```toml
provider = "claude"

[providers.claude]
command = ["claude", "-p"]
timeout = 60

[commit]
style        = "auto"      # auto | conventional | plain
subject_case = "lower"     # lower | preserve
max_subject  = 72

[rewrite]
autostash = false
verify    = ""             # e.g. "swift test" — runs after every rewrite
```

There is deliberately no setting that skips the per-file conflict review.
Safety rule 4 is not configurable; a knob that silently disables it would be
found only after it had already caused damage.

Every key has a working default. A repository with no config file at all
behaves correctly.

## Commands

### `gitthat commit`

Reads the staged diff. If nothing is staged, offers to stage everything.

Context sent to the agent: the staged diff (truncated to 8KB, with an explicit
note in the prompt when truncation occurred), the last 20 commit subjects, and
the current branch name.

#### Choosing a style

Two styles are supported, and the user is never stuck with a guess.

`conventional` produces Conventional Commits — `type(scope): description`. Type
comes from the nature of the diff; scope is optional and inferred from the
changed paths, omitted when changes span unrelated areas.

`plain` produces an ordinary subject line with no type prefix.

Selection resolves in this order, first match winning:

1. `--conventional` / `--plain` on the invocation, for a one-off override.
2. `commit.style` in `./.gitthat.toml`, then `~/.config/gitthat/config.toml`.
3. Inference from the last 20 subjects. At least 70% parsing as Conventional
   Commits selects `conventional`; 30% or fewer selects `plain`. A ratio
   between the two is treated as ambiguous and falls through to step 4.
4. If history is ambiguous — mixed, or fewer than five commits — GITTHAT asks
   once, then writes the answer to `./.gitthat.toml` so the repo is settled and
   the team inherits it.

Step 4 is the only interactive prompt about style, and it happens at most once
per repository.

#### Subject casing

Every word in the subject must be either entirely lowercase or entirely
uppercase. Words carrying only a leading capital are rejected.

```
feat(a-feature): WIP working on DNS improvement ASAP   ✓
feat(a-feature): WIP Working on DNS Improvement ASAP   ✗
```

The test is a single pattern: a word violates the rule when it matches
`^[A-Z][a-z]+$`. Nothing else is examined, and no word list is maintained.

This is deliberately narrow, and the narrowness is what makes it correct.
Acronyms (`DNS`, `WIP`, `API`) are fully uppercase and pass. Identifiers and
proper nouns carry an internal capital — `iOS`, `GitHub`, `refreshToken`,
`TokenStore` — and pass. Only ordinary English words wearing a stray capital
match, and for those, lowercasing is unambiguously safe.

So enforcement is deterministic post-processing, not a re-prompt. The rule is
stated in the prompt with examples, and any violation that survives is corrected
by lowercasing the offending word. Models drift on instructions; a regex does
not, and a repair costs nothing where a retry costs seconds.

Controlled by `commit.subject_case`, default `lower`. Set `preserve` to disable
enforcement entirely — appropriate for repositories following git's own
convention of capitalising the subject. Applies to both styles.

The branch name feeds ticket-ID extraction: `feature/PROJ-421-sso` yields
`PROJ-421`, which is included if the repo's history shows ticket IDs in commit
messages.

The response is stripped of markdown fences and split into subject and body.
The user sees a preview and chooses: accept, edit in `$EDITOR`, regenerate, or
cancel. On accept, `git commit -F -` with the message on stdin.

### `gitthat rewrite`

Rewrites the history of the current branch.

The word "rebase" does not appear anywhere the user can see it — not in help
text, previews, prompts, or errors. Rebasing means moving work onto a different
base, which this tool cannot do. What it does is reshape a sequence of commits
into the sequence they should have been. `git rebase` is an implementation
detail, mentioned only where the spec describes execution.

#### Vocabulary

Git's todo-file verbs are not the user's vocabulary, and they are not GITTHAT's
either. Four operations cover everything v1 does:

| Operation | Meaning |
| --- | --- |
| `keep` | Leave this commit as it is. |
| `combine` | Merge this commit into the one before it. `keepMessage` decides whether its message survives. |
| `reword` | Change the message. The changes are untouched. |
| `delete` | Remove this commit and its changes entirely. |

Reordering is not an operation. **The plan is the history the user wants, in
order** — moving a commit means listing it somewhere else. That is the whole
model, and it is why the schema is smaller than git's.

#### Range

Defaults to `@{upstream}..HEAD` — unpushed work. With no upstream configured,
falls back to the merge-base with the default branch. `-n <count>` overrides
explicitly.

Any commit in range that also exists on the upstream ref is marked `⚠ pushed`
in the preview. If the range includes any, a second confirmation appears before
execution, naming the consequence and the `git push --force-with-lease` the user
will need afterwards.

Cross-branch requests are declined, not guessed at. `--onto` is not a flag.
Intent mentioning another branch produces:

```
GITTHAT rewrites the current branch only.
To move work between branches, use `git rebase main` directly.
```

That message is the single place the word appears, and it is pointing at git
rather than describing GITTHAT.

#### The plan

Intent is optional. Bare `gitthat rewrite` asks the agent to propose a cleanup;
`gitthat rewrite "combine the wip commits and reword the first"` does what was
asked.

The plan comes back as JSON — an ordered array describing the desired history:

```json
{
  "commits": [
    { "sha": "1d9f003", "action": "reword",
      "message": "feat(auth): add token refresh" },
    { "sha": "c4e7a10", "action": "combine", "keepMessage": false },
    { "sha": "8b02de1", "action": "delete" },
    { "sha": "a3f21c9", "action": "keep" }
  ]
}
```

Validation rejects a plan when a SHA falls outside the range, a SHA appears more
than once, a commit in range is missing, the first entry is `combine` (there is
nothing before it to combine into), or `reword` arrives without a message. A
rejected plan is retried once with the validation error appended to the prompt;
a second failure shows the raw output and exits.

Because the plan is a closed type over four operations, it cannot express
`push`, `reset`, or anything touching another branch. The safety boundary is
enforced by the type, not by checking strings.

#### Preview and execution

The preview renders before and after as numbered commit lists. On confirmation,
`Safety` writes a backup ref, then execution begins.

Execution translates the plan into a `git rebase -i` todo file. This mapping is
the only place git's vocabulary exists:

| Plan | Todo line |
| --- | --- |
| `keep` | `pick` |
| `combine`, `keepMessage: true` | `squash` |
| `combine`, `keepMessage: false` | `fixup` |
| `reword` | `reword`, message supplied from a queue |
| `delete` | line omitted |
| array order | line order |

Two environment variables make it non-interactive:

- `GIT_SEQUENCE_EDITOR` emits the generated todo file, so git never opens an
  editor for it.
- `GIT_EDITOR` is `gitthat __edit-message`, a hidden subcommand that pops the
  next prepared message off a queue — how rewritten messages land without
  prompting the user once per commit.

#### Interruption

If a rewrite stops partway, the user resumes with `gitthat rewrite --resume` or
discards it with `gitthat rewrite --cancel`. `--continue` and `--abort` are
accepted as undocumented aliases, so existing muscle memory works.

### Conflict resolution

Reachable only from `rewrite`. Combining and rewording cannot conflict;
reordering and deleting sometimes can.

When git stops, GITTHAT collects conflicted files via
`git diff --name-only --diff-filter=U`. For each file it sends the agent both
sides of the conflict plus **the message of the commit being applied** — that
intent is what separates a plausible merge from a correct one.

Nothing is staged silently. Per file, the user sees ours, theirs, and the
proposed resolution as actual resulting text, and chooses: accept into editor,
edit manually, take ours, take theirs, or skip. "Accept into editor" writes the
proposal into the file and opens `$EDITOR` on it — the user reviews real text in
their own editor, not a summary.

No resolution reaches the index until the user has seen the file it produced.

### Verification hook

An optional command run after **every** completed rewrite, not only conflicted
ones. It catches rewrites that read correctly and behave incorrectly — the
failure mode a preview cannot show:

```toml
[rewrite]
verify = "swift test"
```

Unset by default. On failure, GITTHAT reports it and names `gitthat undo` as the
recovery. It does not roll back automatically; the user decides.

### `gitthat undo`

Deliberately broader than undoing GITTHAT's own actions. It reads the reflog and
renders it in plain language:

```
1.  3 min ago   rewrote 4 commits into 2
2.  1 hr ago    committed "fix token refresh"
3.  2 hr ago    switched to feature/sso
```

The user picks an entry, sees exactly what moves, and confirms. Only the branch
ref moves; the working tree is untouched unless `--hard` is passed.

This is the feature that makes the other two trustworthy.

## Safety rules

1. **Current branch only.** No cross-branch operation exists in the tool.
2. **Never pushes.** GITTHAT prints push commands; the user runs them.
3. **Backup ref before every history operation.** `refs/gitthat/backup/<timestamp>`,
   written before git is invoked, not behind a flag. Retained afterwards so
   `undo` remains available.
4. **Never stage a resolution the user has not seen.**
5. **Pushed commits require separate confirmation.** Marked in the preview,
   confirmed independently of the main plan confirmation.
6. **Dirty trees are refused** for history operations unless `--autostash`.

## UX: teaching the boundary

Every invocation leads with location and range, so the constraint is learned by
exposure rather than documentation:

```
⎇  feature/sso   ·   4 commits not yet pushed

   a3f21c9  wip                       local
   8b02de1  fix typo                  local
   c4e7a10  add token refresh      ⚠  pushed
   1d9f003  wip auth scaffolding   ⚠  pushed

   GITTHAT edits this branch only. Other branches are never touched.
```

## Failure handling

The governing rule: **GITTHAT never leaves the repository in a state it did not
report.** Every failure path either completes or names the command that recovers.

| Failure | Behaviour |
| --- | --- |
| Not a git repository | Clear message, exit 1. |
| Provider not on `PATH` | Name it, list what was found: `found: codex — set provider = "codex"`. |
| Provider timeout | Kill the process, exit clean, nothing written. |
| Malformed response | Retry once with the parse error appended, then show raw output and exit. |
| Git command fails | Surface git's stderr verbatim, never paraphrased. |
| Conflict during rewrite | Not an error. A state, with `resolve · --resume · --cancel` offered. |

## Testing

Swift Testing throughout, using `@Test(arguments:)` for parameterised cases —
which is what makes exhaustive permutation coverage practical.

### What gets faked and what does not

One rule decides this: **fake the things whose behaviour we define, use the real
thing for behaviour we merely depend on.**

The agent is always faked. Its output is our contract, and asserting on live LLM
responses produces tests that fail on Tuesdays.

Git is real by default. Mocking git would test our beliefs about git rather than
git, and every interesting bug in this tool lives in the gap between the two. A
`git init` in a temp directory costs about 10ms, so there is no reason to avoid
it.

Git is faked only for **failure injection** — making git return a specific
stderr, a specific exit code, or die halfway through. Those states are hard to
provoke honestly and easy to script. So `Git` sits behind a `GitRunner` protocol
with two implementations: `SystemGitRunner` (real, the default everywhere) and
`ScriptedGitRunner` (returns queued results, used only in failure tests).

### Test doubles

**`StubProvider`** returns queued responses and records the prompts it received.
It simulates how real agent CLIs actually misbehave, not an idealised version:

| Simulated behaviour | Why it exists |
| --- | --- |
| Clean expected output | The happy path. |
| Wrapped in ` ```json ` fences | Every model does this sometimes. |
| Conversational preamble — "Here's the commit message:" | Common; the parser must survive it. |
| Trailing commas, single quotes | Malformed JSON that looks fine to a human. |
| Truncated mid-object | Output limits hit. |
| Empty output | CLI produced nothing. |
| Non-zero exit with stderr | Not logged in, quota exhausted. |
| Hangs past `timeout` | Verifies the process is actually killed. |
| Valid but semantically wrong — SHA outside range, duplicate SHA, first entry `combine`, `reword` with no message | Each maps to one validation rule. |
| Malformed, then valid on retry | The retry path succeeds. |
| Malformed twice | The retry path gives up correctly. |

**`RepoFixture`** builds real repositories declaratively, so integration tests
read as intent rather than shell:

```swift
let repo = RepoFixture()
    .commit("a3f21c9", "wip",                   file: "a.swift", body: "1")
    .commit("8b02de1", "fix typo",              file: "b.swift", body: "2")
    .push()                                      // everything so far is upstream
    .commit("c4e7a10", "add token refresh",     file: "c.swift", body: "3")
    .build()
```

`push()` creates a local bare repo and pushes to it, so upstream tracking and
pushed-commit detection are exercised against real refs rather than a stub.

**Fixtures are built once and copied.** Measured on an M-series Mac:

| Operation | Cost |
| --- | --- |
| Building a four-commit repository | 2758 ms |
| `cp -R` of a prebuilt `.git` | 34 ms |
| One `git rebase -i` | 316 ms |

Constructing a fixture per test would cost roughly 30 minutes across the
permutation suite; copying one costs about 22 seconds. `RepoFixture` therefore
builds each distinct shape once per suite and hands out copies. This is not an
optimisation to apply later — the permutation tier is only affordable because of
it.

### Layer 1 — pure unit tests

No git, no processes. Milliseconds. Table-driven with `@Test(arguments:)`.

| Under test | Cases |
| --- | --- |
| Plan validation | Each rejection rule, plus the boundary that should pass. |
| Plan → todo translation | All four operations, `keepMessage` both ways, `delete` omission, order preservation. |
| Subject casing | `Add` → `add`; `DNS`, `WIP`, `iOS`, `GitHub`, `refreshToken`, `TokenStore` unchanged; `preserve` disables it; empty and single-character words. |
| Style inference | The 70% threshold at 69/70/71; fewer than five commits; zero commits; all-conventional; all-plain. |
| Config merge | Repo overlays global per key; missing files; partial files; every default applies when nothing is set. |
| Ticket extraction | `feature/PROJ-421-sso`, no ticket, several tickets, ticket-like noise. |
| Response parsing | Every `StubProvider` malformation above. |

### Layer 2 — exhaustive permutations

The combinatorial space is small enough to enumerate rather than sample, which
removes the question of whether the sample was representative.

For a four-commit fixture, each commit takes one of five fates — `keep`,
`combine(keepMessage: true)`, `combine(keepMessage: false)`, `reword`, `delete`
— across all orderings:

```
5⁴ × 4! = 625 × 24 = 15,000 plans
```

Run exhaustively at the **pure** layer, where each case costs microseconds. Every
plan is fed to the validator and, when valid, to the translator. Two assertions:
the accept/reject decision matches the rules, and every accepted plan produces a
well-formed todo file.

At the **real-git** layer each permutation costs about 400 ms — a fixture copy,
a rewrite, and the assertion queries. The full 15,000 is therefore roughly 100
minutes serially, so execution is tiered:

- **Every pull request** — all 625 fate-assignments at natural order, plus the
  24 orderings with all-`keep`. About 650 rewrites: roughly 4 minutes serially,
  under a minute with Swift Testing's default parallelism.
- **Nightly** — the full 15,000. Roughly 100 minutes serially, 15–20 minutes
  parallel.

These budgets assume parallel execution. Tests must therefore share no mutable
state and no fixed paths, which the temp-directory discipline below enforces.

Each executed permutation asserts the same invariant set:

1. No `delete` commit appears in the final history.
2. Final commit count equals the number of entries that are neither `delete` nor
   `combine`.
3. Surviving commits appear in the plan's order.
4. Every `reword` message appears verbatim.
5. `combine(keepMessage: false)` leaves no trace of the absorbed message.
6. The final tree matches the tree produced by applying the same surviving
   changes — content is preserved, only history shape changed.
7. A backup ref exists and points at the original `HEAD`.
8. `gitthat undo` restores the original `HEAD` SHA exactly.
9. The working tree is clean.
10. **No other branch's ref moved.**
11. **No remote ref moved.**

Invariants 10 and 11 are the product boundary expressed as a test. They run on
every permutation, so any future change that reaches beyond the current branch
fails 650 tests rather than shipping.

### Layer 3 — integration

Real git, real repositories, one behaviour each.

- Each rewrite operation end to end, asserting `git log --oneline`.
- `GIT_SEQUENCE_EDITOR` and `GIT_EDITOR` wiring — the reword-message queue
  delivering the right message to the right commit when several are reworded.
- Range resolution: with upstream, without upstream, `-n` override, empty range,
  range of one.
- Pushed-commit detection against the bare-repo remote, including the partially
  pushed case.
- Dirty-tree refusal, and `--autostash` restoring the stash afterwards.
- `commit` with nothing staged, with a huge diff (8KB truncation), with binary
  files only, with a rename.
- `undo` after each of: commit, rewrite, and a plain `git` operation performed
  outside GITTHAT.

### Layer 4 — conflict scenarios

Constructed deliberately, since they are the least predictable path.

- Reorder producing a conflict; delete producing a conflict.
- Conflicts in two files at once, exercising the per-file loop.
- Each per-file choice: accept-into-editor, edit manually, ours, theirs, skip.
- `$EDITOR` is faked as a script that writes known content and exits, so the
  review step is asserted rather than skipped.
- Nothing is staged before the editor step — asserted directly against the
  index, since this is safety rule 4.
- `--resume` and `--cancel` from a conflicted state.
- `verify` configured and failing: the failure is reported, nothing is rolled
  back automatically, and `gitthat undo` still restores.

### Layer 5 — failure injection

Using `ScriptedGitRunner` and `StubProvider`.

- Provider missing from `PATH`, timing out, exiting non-zero, returning nothing.
- Retry exhaustion showing raw output.
- Git failing mid-rewrite; assert the repository is left in a reported state and
  the backup ref survives.
- `SIGINT` during a rewrite — assert recoverability.
- Unwritable todo file.
- Not a git repository; detached `HEAD`; a repository with zero commits.

### Layer 6 — vocabulary lint

A test that fails if git's internal vocabulary reaches the user.

It collects every user-facing string — help text, prompts, previews, errors —
and asserts that none matches `rebase`, `squash`, `fixup`, `pick`, or `todo`,
with a small allowlist for the two places the spec permits: the cross-branch
refusal that points at `git rebase`, and the plan-to-todo translation table.

The naming decision is a product commitment, and a commitment nothing checks
degrades on contact with the first hurried patch.

### Layer 7 — the project's own repository

GITTHAT is developed using GITTHAT. Its own repository is a permanent test
environment, and the only one that evaluates *judgment* rather than mechanism.

Layers 1–6 answer "did the tool do what the plan said." They cannot answer "was
the message any good" or "was that the cleanup a person actually wanted," because
both require a human reading real output about real work. Development supplies a
steady stream of exactly that.

**Bootstrap order.** Commits before `gitthat commit` passes its own tests are
written by hand. From that point the repository switches, and every subsequent
commit is generated. `rewrite` joins once its permutation tier is green, used for
branch cleanup before merge. The switchover commit is tagged, so the history
carries a visible line between hand-written and generated.

**The repository configures itself.** A committed `.gitthat.toml` at the root is
both real configuration and the worked example the documentation refers to:

```toml
[commit]
style        = "conventional"
subject_case = "lower"

[rewrite]
verify = "swift test"
```

`verify` matters here more than anywhere: this repository is where a bad rewrite
costs the most.

**The edit rate is the quality metric.** Each `commit` invocation records whether
the user accepted, edited, or regenerated. Accept means the prompt is working;
a persistent edit rate means it is not. No unit test can produce this number, and
it is the most direct evidence of whether the tool is worth using. It is reviewed
when it moves, not tracked as a dashboard.

**Real conflicts become fixtures.** Layer 4 constructs conflicts deliberately,
which means they are the conflicts we thought of. Development produces the ones
we did not. Every real conflict met while rewriting a branch here is captured as
a `RepoFixture` and added to the suite, so the conflict corpus grows from
practice rather than imagination.

**The history is itself a test.** CI runs the casing validator and style parser
across the project's own `git log`. Every commit must satisfy the rules the tool
enforces. This catches a hand-written message that slipped past, and it grows
into a larger fixture with every commit — by the time v1 ships, style inference
is being exercised against hundreds of real subjects rather than a table of
invented ones.

**Honest limits.** Dogfooding is evidence, not coverage: it exercises the paths
this project happens to take, on one repository, with one workflow. It cannot
replace the permutation tier and is not credited as if it could. And a tool that
rewrites the history of its own source can destroy its own source, so two rules
apply while developing: push before any rewrite session, making the remote the
backstop behind the backup ref, and never run `rewrite` on `main`.

### Running

| Command | Contents | Budget |
| --- | --- | --- |
| `swift test` | Layers 1, 3, 4, 5, 6 plus the 650-case permutation tier | Around 2 minutes parallel |
| `swift test --filter Exhaustive` | The full 15,000 against real git | 15–20 minutes parallel, nightly |
| `scripts/check-own-history.sh` | Layer 7 — casing and style across this repository's `git log` | Seconds, runs in CI |

Every test creates its repository in a fresh temp directory and removes it
afterwards, so the suite is parallel-safe and touches nothing outside its own
sandbox. `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` are pointed at empty files
in every test, so a developer's personal git config — `commit.gpgsign`,
`rebase.autosquash`, a custom `core.editor` — cannot change the result.

## Out of scope for v1

Deferred deliberately, each with a reason:

- **Cross-branch operations** — the product boundary, not a limitation.
- **Pushing** — safety rule 2.
- **TUI mode** — Swift has no mature terminal UI ecosystem; verbs-first needs
  only ANSI codes.
- **Direct HTTP providers** — the protocol accommodates them; latency has not
  yet proven to be a problem worth solving.
- **Splitting a commit** — the one rewrite the plan model cannot express. Every
  operation in v1 maps an existing commit to a fate; splitting invents commits
  that did not exist, so it needs hunk-level decisions about which change lands
  where. A different feature wearing the same word. Later, on its own.
- **Natural-language fallback for arbitrary git** — the three verbs cover the
  stated pain. Revisit once they are solid.
- **Windows** — Swift support is immature. macOS is native; Linux works via
  `--static-swift-stdlib` at roughly 40MB.
