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
- The `harness.md` file (this file) is re-read automatically when its
  modification time changes (checked before each prompt), and can be
  force-reloaded with the `/reload` command. If you edit this file, the
  new rules take effect on the next prompt - no restart needed.
- When creating temporary directories or files for testing use the "tmp"
  directory, not the root directory of the project.

## Code Style

- Ruby, `frozen_string_literal: true` magic comment at the top of every file.
- 2-space indentation, no tabs.
- Prefer small, focused methods; keep classes cohesive.
- Comments explain *why*, not *what*.
- Preserve existing formatting and style when editing - do not reformat
  untouched code.
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
- Line endings: the harness normalizes to LF for LLM-facing operations
  (read, search, patch matching) but preserves the file's original
  line-ending style on write. Do not introduce mixed line endings.
- Encoding: text that comes from OUTSIDE the process (shell output, file
  reads, model-supplied tool-call arguments, git output, the LLM response
  body) can be byte-invalid in UTF-8 or tagged with a code page, so it is
  normalized once at each read boundary by `TextNormalizer` - bytes that
  cannot be represented become the printable ASCII replacement `?`, which
  keeps output inspectable and cannot itself break JSON or the console.
  Already-valid UTF-8 is returned untouched. Downstream consumers (strip,
  split, gsub, regex, JSON.generate for the session save) then never raise.
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

## Tunable Constants

- `Session::COMPACT_RECENT_MESSAGES` - how many recent messages survive
  `/compact` verbatim (default 6).
- `Session::AUTO_COMPACT_THRESHOLD` - auto-compact when context usage
  reaches this % of the window (default 88); config key
  `compact.auto_threshold`; set to 100+ to disable.
- `Session::COMPACT_RESERVED_TOKENS` - absolute headroom (tokens) kept free
  before auto-compact fires (default 8192, issue #151); config key
  `compact.reserved_tokens`. Trigger is the stricter of pct and reserve.
- `Harness::MAX_TOOL_ITERATIONS`, `TOOL_LOOP_WARN_THRESHOLD`,
  `TOOL_LOOP_HARD_LIMIT` - tool-loop safety limits.
- `LLM::NUM_CTX` - context window size (default 65536) and `LLM::RETRY_COUNT`
  / `LLM::RETRY_DELAY` (transient-error retries) live in `lib/llm/shared.rb`;
  `LLMClient` only aliases them. There are no code-side sampling constants:
  sampling values are owned by the config and an unset key is not sent
  (issue #215).
- `SensitiveFiles::SENSITIVE_DIRS` / sensitive file patterns - security
  blocklist.

## Pending / Deferred

- Shell command safety check: the follow-ups are tracked as open issues
  (#244: use the shell parse for the check; #254: model-decided safety for
  the unsafe case). The `run.command` tool itself is implemented and wired -
  it is no longer "deferred".
- CRLF handling: implemented in file.read / file.search / file.patch;
  verify end-to-end on Windows if patching still misbehaves.
