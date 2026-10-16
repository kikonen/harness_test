# Project Rules - harness_test

## Self-Awareness: You Are Editing Your Own Harness

You are operating **inside** this harness and editing **its own source code**.
Keep this in mind:

- Changes you make to `lib/*.rb` or `lib/tools/*.rb` affect the very tool
  environment you are running in. Be extra careful: a syntax error or a
  broken tool can break the session you are currently in.
- After modifying harness code, prefer to verify the change is complete and
  consistent (re-read the file, check that referenced methods exist) before
  declaring the task done.
- If you change a tool's behavior (e.g. its parameters, return format, or
  error messages), also update the system prompt (`config/system_prompt.txt`)
  and/or the tool's own description so the LLM (you, in future sessions)
  sees the accurate contract.
- If you change CLI commands or `/help` text, keep them in sync with the
  actual behavior in `lib/cli.rb`.
- When creating temporary directories or files for testing use the "tmp"
  directory, not the root directory of the project.

## Code Style

- Ruby, `frozen_string_literal: true` magic comment at the top of every file.
- 2-space indentation, no tabs.
- Preserve existing formatting and style when editing - do not reformat
  untouched code.
- Comments: hard budget, enforced by a delete test. A comment may say ONLY
  what the code cannot say: an invariant, a gotcha, an ordering constraint,
  a labeled HACK. Never explain the programming language (`== true` is a
  boolean check; `!!` is a truthiness cast - the reader knows both) and never
  restate the line below the comment. Budget: at most ONE *why* sentence per
  method (2-3 lines max); short obvious control flow (label lookups, getters,
  setters, formatting, one-liners) gets NO comment at all. Delete test: if
  deleting a comment loses no information the code does not already carry,
  delete it - a comment that merely restates code is fluff, and one that
  states a wrong mechanism (e.g. calling `val == true` "coercion") is worse
  than none. Issue numbers, bug numbers and design history do NOT belong in
  method bodies - they belong in CHANGELOG, the issue and the commit message.
  When the user flags a comment as useless, the ASSISTANT strips it (never
  the user) and audits the same file for the same pattern in the same pass.
- Prefer small, focused methods; keep classes cohesive.
- Lines should be at maximum 90 characters long.
- Ruby and other text files must retain trailing newline in the end
- AVOID using "—" emdash use normal dash "-" instead

## Conventions

- All harness state (sessions, log, history) lives in `.harness/` inside
  the working directory - never scatter state files in the project root.
- Config (issue #260): the user home (`~/.config/harness/config.yml`) is the
  default config location; `.harness/config.yml` in the working directory is
  a per-project override, and the lookup order is `-c` > `$HARNESS_CONFIG` >
  working-dir `.harness/config.yml` > user home. There is no installation-dir
  tier - `$HARNESS_CONFIG` / `-c` covers that case.
- Sensitive files/dirs (`.env*`, `.git/`, `.harness/`) are blocked from
  LLM access - do not try to work around this.
- Access modes (read / write / delete) are tracked separately: a write grant
  implies read, but neither read nor write implies delete.
- Destructive operations (file delete, dir delete) require a DELETE grant
  from the tool layer - do not bypass it, and never try to reach the same
  result through a shell command instead.
- Consent code: new code must never weaken the disaster denylist
  (`CommandAllowlist.disaster?`) - a well-known disaster keeps the consent
  dialog in EVERY posture with no "Always allow" option - and anything that
  auto-approves a command without a dialog must print a status line AND log
  it to harness.log.
- Consent state is user-side harness state, never conversation state: it is
  not injected into the chain, and every posture setter compares strictly to
  `true` (`val == true`), so only a literal true turns a posture on.
- Resolve identity before constructing what derives from it (issue #276).
  A session id is identity: the log file, the history file and the session
  directory are all DERIVED from it. Constructing an object that derives from
  an id before the id is settled forces every derived resource to be chased
  and re-pointed afterwards (`rebind_logger`, `client.logger=`,
  `history.bind_session` - issues #113 / #119 / #123 / #135 / #270 were all
  one ordering bug). Resolve first (`SessionLocator`), construct once; a
  mid-run identity change (`/resume`) is the only case that rebinds, and it
  says so explicitly.
- Line endings: the harness normalizes to LF for LLM-facing operations
  (read, search, patch matching) but preserves the file's original
  line-ending style on write. Do not introduce mixed line endings.
- Encoding: text that comes from OUTSIDE the process (shell output, file
  reads, model-supplied tool-call arguments, git output, the LLM response
  body) can be byte-invalid in UTF-8 or tagged with a code page, so it is
  normalized once at each read boundary by `TextNormalizer`, which always
  RETURNS valid UTF-8: a BINARY tag is a byte container (read the bytes as
  UTF-8 first, then the ambient code page), a declared code page is
  transcoded, and only bytes that genuinely cannot be represented become the
  printable ASCII replacement `?`. A naive transcode from a BINARY tag
  destroys every multi-byte character (issue #268) - never #encode from
  BINARY yourself. Downstream consumers (strip, split, gsub, regex,
  JSON.generate for the session save) then never raise.
- Spec layout: tests live under `spec/` mirroring the tree they test -
  e.g. `lib/ui/dialog.rb` is tested by `spec/lib/ui/dialog_spec.rb`, and tools
  in `lib/tools/` are tested in `spec/lib/tools/` (e.g.
  `lib/tools/file_read_tool.rb` ->
  `spec/lib/tools/file_read_tool_spec.rb`). Do NOT drop spec files into
  the `spec/` root, or at a level shallower than where they belong; only
  shared helpers (like `spec/spec_helper.rb`) belong in the `spec/` root.
  One spec file per class: each class gets its own `<name>_spec.rb`
  (e.g. `FileReadTool` in `file_read_tool_spec.rb`). Do NOT bundle
  tests for multiple classes into a single "catch-all" spec file.

## PR Workflow

- Never commit directly to `master`. Always create a feature/fix branch
  first, commit there, open a PR, and merge with rebase. Committing on
  `master` and re-branched afterwards is an ugly habit and risks pushing
  unreviewed changes straight to `master`.
- If work was already committed to `master` by mistake, it must be moved off:
  reset `master` back and rebase the branch onto it. Ask before rewriting
  any history that may have been pushed.
- When merging a pull request, use **rebase** (`gh pr merge --rebase`)
  so commits land on `master` as a clean linear history - no merge
  commits. Only fall back to a regular merge if the rebase fails
  (e.g. conflicts) and say so explicitly.
- Do NOT merge a PR automatically. Open the PR, then stop and let the
  user test the changes first - merge only after the user explicitly
  says to.
- The PR body should state that it will be merged with rebase.
- After a merge, delete the local feature branch (the remote ref is already
  removed by GitHub on merge, so `git fetch --prune` clears the stale
  `remotes/origin/...`). No dialog needed - this is the standing habit.
  A rebase merge rewrites the commit so `git branch -d` refuses ("not fully
  merged"): confirm the content is identical to `master` first
  (`git diff <branch> master --stat` is empty), then force-delete.
