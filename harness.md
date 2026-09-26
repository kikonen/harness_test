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
  error messages), also update the system prompt (`lib/system_prompt.txt`)
  and/or the tool's own description so the LLM (you, in future sessions)
  sees the accurate contract.
- If you change CLI commands or `/help` text, keep them in sync with the
  actual behavior in `lib/cli.rb`.
- The `harness.md` file (this file) is re-read automatically when its
  modification time changes (checked before each prompt), and can be
  force-reloaded with the `/reload` command. If you edit this file, the
  new rules take effect on the next prompt - no restart needed.
- When creating temporary directores or files for testing "tmp" directory,
  not root directory of project

## Code Style

- Ruby, `frozen_string_literal: true` magic comment at the top of every file.
- 2-space indentation, no tabs.
- Prefer small, focused methods; keep classes cohesive.
- Comments explain *why*, not *what*.
- Preserve existing formatting and style when editing - do not reformat
  untouched code.
- Lines should be at maximum 90 characters long.
- All text files must have newline in the end.
- AVOID using "—" emdash use normal dash "-" instead

## Conventions

- All harness state (sessions, log, history) lives in `.harness/` inside
  the working directory - never scatter state files in the project root.
- Sensitive files/dirs (`.env*`, `.git/`, `.harness/`) are blocked from
  LLM access - do not try to work around this.
- Destructive operations (file delete, dir delete) require user
  confirmation via the tool layer - do not bypass.
- Line endings: the harness normalizes to LF for LLM-facing operations
  (read, search, patch matching) but preserves the file's original
  line-ending style on write. Do not introduce mixed line endings.

## Tunable Constants

- `Session::COMPACT_RECENT_MESSAGES` - how many recent messages survive
  `/compact` verbatim (default 6).
- `Harness::MAX_TOOL_ITERATIONS`, `TOOL_LOOP_WARN_THRESHOLD`,
  `TOOL_LOOP_HARD_LIMIT` - tool-loop safety limits.
- `Harness::NUM_CTX` - context window size (default 65536).
- `SensitiveFiles::SENSITIVE_DIRS` / sensitive file patterns - security
  blocklist.

## Pending / Deferred

- `run_command` tool: deferred pending a security model review.
- CRLF handling: implemented in file.read / file.search / file.patch;
  verify end-to-end on Windows if patching still misbehaves.
