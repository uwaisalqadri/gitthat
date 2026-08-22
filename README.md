# <img width="500" alt="Frame 110" src="https://github.com/user-attachments/assets/43b85a36-6758-423a-b5ea-d31a344c9673" />

**Rewrite history without remembering how.**

Git records what happened. What you want to publish is what you *meant* to do —
a clean sequence of changes, each with a message that explains itself. GITTHAT
gets you from one to the other.

```
$ gitthat commit
$ gitthat rewrite "combine the wip commits and reword the first"
$ gitthat undo
```

It runs on the agent CLI you already have installed and logged in — `claude`,
`codex`, `ollama`, or anything else that reads a prompt and writes text. No API
key, no second subscription.

---

> **Status: `gitthat commit`, `gitthat rewrite`, and `gitthat undo` are
> implemented and covered by the test suite.** When a rewrite hits a conflict,
> GITTHAT shows both sides, proposes a resolution via the configured AI agent,
> and lets you accept, edit, take one side, or skip each file.
> Nothing is staged without your review — this is enforced structurally, not by convention.

---

## What it does

### `gitthat commit`

Reads your staged diff and writes the message.

Style comes from your repository, not from configuration. If your last twenty
commits are Conventional Commits, you get one back. If they are plain sentences,
you get a plain sentence. Ticket IDs are lifted from the branch name when your
history shows you use them.

You see the message before it lands: accept, edit, regenerate, or cancel.

### `gitthat rewrite`

Reshapes the commits on your current branch into the ones you meant to write.

You describe what you want. GITTHAT produces a plan, shows you the history
before and after, and only touches anything once you say yes.

```
⎇  feature/sso   ·   4 commits not yet pushed

   a3f21c9  wip                       local
   8b02de1  fix typo                  local
   c4e7a10  add token refresh      ⚠  pushed
   1d9f003  wip auth scaffolding   ⚠  pushed
```

Four operations cover it: **keep**, **combine**, **reword**, **delete**.
Reordering is not an operation — the plan is the history you want, in order, so
moving a commit means listing it somewhere else.

### `gitthat undo`

Puts it back. Reads the reflog and shows it in plain language:

```
1.  3 min ago   rewrote 4 commits into 2
2.  1 hr ago    committed "fix token refresh"
3.  2 hr ago    switched to feature/sso
```

Works on anything git did, not only on what GITTHAT did.

## What it will not do

These are deliberate, and they are what make the rest safe to use.

**It only touches the branch you are on.** No moving work between branches, no
merges, no cherry-picks. Ask for one and it declines and points you at the git
command that does it.

**It never pushes.** Not behind a flag. When a rewrite leaves your branch
diverged, GITTHAT prints the `git push --force-with-lease` for you to run
yourself.

**It never rewrites without a backup.** A backup ref is written before git is
touched, every time, not behind a flag. That is what `gitthat undo` restores
from, and it is kept afterwards rather than cleaned up.

**It never stages a conflict resolution you have not seen.** Proposed
resolutions open in your editor as real text. There is no setting to skip this.

**The agent never touches your repository.** It receives a string and returns a
string. Every git command that runs is chosen, validated, and executed by
GITTHAT.

## Providers

A subscription is not API access — Claude Pro/Max gives you nothing at
`api.anthropic.com`, and ChatGPT Plus gives you nothing at OpenAI's. The only
way to spend one is through the vendor's own CLI, already logged in on your
machine. So that is what GITTHAT uses.

```toml
# ~/.config/gitthat/config.toml
provider = "claude"

[providers.claude]
command = ["claude", "-p"]
timeout = 60

[providers.ollama]
command = ["ollama", "run", "qwen2.5-coder"]
```

The prompt goes in on stdin, the text comes back on stdout. That is the entire
integration, which means a local model works exactly as well as a hosted one,
and a new agent CLI needs three lines of config rather than a GITTHAT release.

On first run GITTHAT scans your `PATH` and configures whatever it finds.

## Configuration

Global defaults live in `~/.config/gitthat/config.toml`. A `.gitthat.toml` in
your repository overlays it per key and is meant to be committed, so your team
shares a commit style without anyone configuring anything.

```toml
[commit]
style        = "auto"      # auto | conventional | plain
subject_case = "lower"     # lower | preserve
max_subject  = 72

[rewrite]
autostash = false
verify    = ""             # e.g. "swift test" — runs after every rewrite
```

Every key has a working default. A repository with no config at all behaves
correctly.

### Subject casing

Every word in a subject must be entirely lowercase or entirely uppercase. Words
wearing only a leading capital are corrected.

```
feat(a-feature): WIP working on DNS improvement ASAP   ✓
feat(a-feature): WIP Working on DNS Improvement ASAP   ✗
```

Acronyms pass because they are fully uppercase. Identifiers and proper nouns
pass because they carry an internal capital — `iOS`, `GitHub`, `refreshToken`,
`TokenStore`. Only ordinary words with a stray capital are touched. Set
`subject_case = "preserve"` to turn it off.

## Building

Requires Swift 6.3 or later.

```sh
swift build -c release
```

macOS needs nothing else; the Swift runtime ships with the OS. Linux needs
`--static-swift-stdlib`, producing a roughly 40MB binary. Windows is not
supported.

## Testing

```sh
swift test                                        # unit, integration, conflicts, failures (~3 min)
GITTHAT_EXHAUSTIVE=1 swift test --filter Exhaustive   # every rewrite permutation against real git (~35 min)
```

The suite enumerates all `5⁴ × 4! = 15,000` possible rewrite plans over a
four-commit repository rather than sampling them. Every executed permutation
asserts eleven invariants, two of which are the product boundary itself: no
other branch's ref moved, and no remote ref moved.

GITTHAT is also developed using GITTHAT. Its own history is a test fixture — CI
validates every commit in this repository against the rules the tool enforces.

## Contributing

Read [the design spec](docs/superpowers/specs/2026-08-13-gitthat-design.md)
first. It is the source of truth for behaviour, and it explains why the
boundaries are where they are.

Commits in this repository are generated with `gitthat commit` and must pass
`scripts/check-own-history.sh`.
