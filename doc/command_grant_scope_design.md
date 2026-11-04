# Command grant scope: what an "Always allow" option actually saves

Why a stored command prefix covers more than the command you were asked about,
what each candidate shape therefore claims for itself in the dialog, and why the
answer to issue #96 was a wording change rather than a new rule.

Verified against master `c98b619` (git 2.56.0). Measurement: `analysis/96/repro.rb`.

---

## The issue

`git branch` on its own is safe; `git branch -D` is not. The consent dialog for a
read-only run offered `Always allow 'git branch', 'git log'` - a grant whose
scope was never stated, in an option chosen in a fraction of a second.

## The rule every grant follows

`CommandAllowlist#segment_allowed?` compares the stored grant's tokens against
the command's **leading words**, token for token. So:

> A grant matches the opening words. **Everything after the saved words is free.**

That single rule explains both halves of the report - `git` reaching
`git push origin main`, and `git branch` reaching `git branch -D main` - and it is
not a defect: it is what makes a grant worth having. `git log --oneline` is
useful precisely because it covers `git log --oneline -5`.

The measured scope per candidate shape:

| stored grant | also covered | NOT covered |
|---|---|---|
| `git` | `git status`, `git branch -D x`, `git push origin main` | - |
| `git branch` | `-D main`, `--delete x`, `-m a b` | - |
| `git branch -D` | `git branch -D x`, bare `git branch -D` | `-d x`, `--delete x` |
| `git log --oneline` | `git log --oneline -5` | `git log --graph`, plain `git log` |
| `cd C:/work/x` | `cd C:/work/x extra` | `cd C:/work/y`, bare `cd` |
| `ruby -c` | `ruby -c lib/a.rb` | `ruby lib/a.rb` |
| `bin/rspec` | any arguments of that program | `bin/other` |
| `bin/*` | every program directly in `bin` | `bin/sub/tool` |

Two shapes fall out of the table:

- **Run-shaped** - the saved words end with a program (`git`, `git branch`,
  `bin/rspec`, `bundle exec rspec`). Flag-blind by design.
- **Pinned** - the saved words already name a flag or an argument
  (`git branch -D`, `git log --oneline`, `cd C:/work/x`, `ruby -c`). A different
  flag at that position asks again.

## Why wording, not a new rule (owner decision, 2026-11-03)

Three options were on the table:

1. **State the scope** where the grant is chosen. No new matching rule.
2. **Stop offering the flag-blind parent** for a command that carries a flag.
   Rejected: it also removes the useful case - `git log --oneline` would then
   only ever grant that exact invocation, so every new flag combination asks again.
3. **Add a mutation floor** (a second denylist of state-changing forms).
   Rejected after the owner's point that git-internal damage is recoverable:
   git prints the SHA on a branch delete, `origin` covers pushed work, and the
   reflog covers the rest. A second list buys protection against the recoverable
   cases and a maintenance burden, for no gain on the unrecoverable ones.

Option 1 was chosen. `CommandAllowlist.grant_scope_note` returns the sentence for
a candidate (`SCOPE_RUN` / `SCOPE_PIN`, plus the existing directory-glob note from
#417), and `CommandRunner` passes it as the description of every "Always allow"
option. Before this change only a `bin/*` candidate had a description; an exact
prefix had **none**, which is exactly the gap #96 hit.

## What the wording does not claim

It does not promise safety. A run-shaped grant still authorizes any flag, and a
verb grant (`rm`, `del`) still authorizes `rm -f tmp/x.txt` - while the
`file.delete` tool needs its own DELETE grant for the same file. That asymmetry
is real and out of scope here: the dialog's job is to state the scope honestly,
not to make every scope safe. The disaster denylist (#221) remains the floor that
no grant can cross.
