# Changelog

Per-issue history of what changed in the harness. This file is NOT injected
into the system prompt - `harness.md` holds only coding rules and guidelines,
so fixed-bug notes and release history belong here (and in the issue/PR).

Issue numbers link to https://github.com/kikonen/harness_test/issues/<n>.
Older history lives in `git log`; this file starts at the 2026-10-10 window.

## Unreleased - compact spinner line (issue #271)

- The per-request spinner line was the longest UI line of a turn and its
  numbers were unglanceable:
  "Sending to qwen2.5-coder:32b (ollama /api/chat)... 🧠 ctx 19514/160000 (12%)".
- New format: "Sending (qwen2.5-coder:32b / openai)... 🧠 12% (160K)".
  - `SessionManager#request_spinner_detail`: the recipient moves into
    parentheses after the verb and only the API TYPE is named. The endpoint
    path issue #217 added was the longest part of the line and is already in
    the startup banner and printed by /model, so it left the spinner;
    `target_suffix` became `api_type_label`. `#target_display` (and with it
    /model, /models and the banner) still shows api type + endpoint path.
  - `Harness#context_indicator_live` - the spinner's context segment - now
    leads with the percentage and names the window it is a percentage of,
    rounded to whole thousands by the new `#window_label` (65536 -> 66K,
    160000 -> 160K; a window under 1000 stays exact). The used-token count is
    dropped: the percentage is what the eye tracks frame to frame.
- The compact form is the spinner's ONLY: `#context_indicator` (the modeline
  and the per-turn stats line) and `#context_report` (/ctx) keep the full
  token arithmetic, so /compact's before/after lines stay verbose.

## Unreleased - each LLM request announces its own spinner line (issue #283)

- Fix: after an in-loop compaction the spinner kept saying
  "Compacting session mid-task ..." for the REST of the turn, even though the
  compaction was long done and the model request was running.
- Cause: `send_session` emitted the "Sending to ..." `:spinner_detail` ONCE
  before the whole tool loop, while `Harness#call_llm` iterates many times.
  The compaction re-point won the race and nothing re-pointed it back, because
  the runner replays the last remembered line whenever it rebuilds the spinner.
- Fix shape (the agreed design): a wait that starts says what it is doing.
  New `SessionManager#request_spinner_detail` is the single source of the
  request line (model + ` (api path)` tail + live ctx suffix), and
  `Harness#call_llm` calls it before EVERY `@client.chat` of the loop. There is
  no "clear the spinner" logic anywhere: the next wait overwrites the previous
  one, and `#send_session` no longer emits it at all.
- `target_suffix` keeps the issue #217 target tail and drops it for a client
  without a `#backend` (test doubles), so describing a wait can never break it.
- doc/task_design.md: the spinner-ownership section now states the rule the
  bug was missing - a re-point describes ONE wait; the runner only remembers it
  so a spinner rebuilt INSIDE that wait keeps its message.

## Unreleased - comment rule made enforceable; offenders stripped (issue #281)

- `harness.md` Code Style: the descriptive WWWW rule becomes a hard budget with a
  delete test. A comment may only say what the code cannot (invariant, gotcha,
  ordering constraint, labeled HACK), at most one *why* sentence per method; short
  obvious control flow (getters, setters, label lookups, one-liners) gets NO
  comment; the programming language is never explained (`== true` is a boolean
  check, `!!` a truthiness cast); a comment that restates the line under it is
  fluff and one that names the wrong mechanism (calling `val == true` "coercion")
  is worse than none; issue/bug numbers and design history move out of method
  bodies to CHANGELOG, the issue and the commit message. A comment the user flags
  as useless is stripped by the ASSISTANT, and the same file is audited for the
  same pattern in the same pass.
- `harness.md` Conventions: the "posture flags are coerced to real booleans" line
  was itself the wrong-mechanism kind - it now states what the setters do
  (`val == true`, a strict comparison, so only a literal true turns a posture on).
- Strip: the flagged 10-line comment on the 3-line `Harness#command_mode_label`,
  every comment inside `Harness#initialize` (all of them restated the assignment
  under them), and the same pattern across `lib/harness.rb` and `lib/task.rb`
  (comment lines 292 -> 33 and 279 -> 209; zero issue-number references left in
  either file).
- New rule: design documentation lives in `doc/<topic>.md`, not in a source-file
  header. A long file-level header (the prose explaining a subsystem's
  architecture, protocol or ownership rules) moves to `doc/`; the source keeps at
  most a 3-line header naming the invariant and pointing at the doc. Docs hold
  what a reader needs BEFORE reading the code; comments stay for what a specific
  line cannot say. `README.md` gained the `doc/` line in its project layout.
- Move: four such headers became docs (`doc/task_design.md` 63 header lines,
  `doc/encoding_design.md` 32, `doc/output_buffer_design.md` 30,
  `doc/session_file_cache_design.md` 30); each source file now carries a
  2-3-line pointer instead (`lib/task.rb` 209 -> 149 comment lines). The two
  medium headers that do not warrant a doc file of their own (`lib/ui/spinner.rb`,
  `lib/ui/console.rb`) were trimmed to the same 3-line form: invariant kept,
  history and forward-looking notes dropped. No file-level header of 8+ lines is
  left in `lib/`. harness.md's
  own Encoding convention shrank to the actionable rule plus the pointer, since
  its rationale now lives in `doc/encoding_design.md` and harness.md is injected
  into every system prompt.

## Unreleased - session identity resolved before anything is built (issue #276)

- Refactor: the session id is now settled BEFORE `Harness` is constructed, so
  the log file, the history file and the session directory are all created
  once, under one id. New `SessionLocator` (`lib/session_locator.rb`) is the
  single place that knows WHERE a session lives and WHICH session this run is;
  it needs the workdir and nothing else (constructing it touches no disk).
- `CLI#initialize` order is now: parse options -> resolve the id
  (`--resume <id>` / `--continue` newest / a fresh UUID) -> read the saved data
  -> construct Harness -> bind history to the settled id. `Session` takes its
  id as a parameter (`session_id:`) and `Harness` takes `session_id:` /
  `resume_data:`.
- Delete: `lib/deferred_logger.rb` (the #270 stopgap), the lazy `Harness#logger`
  accessor and the #123 deferral. `Harness#logger` is a real Logger from
  `#initialize` on every path (fresh, `-r`, `--continue`, mid-run `/resume`),
  and the client holds that same Logger, so no consumer can hold a placeholder.
- Trade-off of the eager logger: a fresh run now creates its own
  `.harness/sessions/<id>/` at startup (its log file), where the #123 deferral
  created it only on the first log line. The deferral existed to protect the
  RESUMED case (no dir for an id the run threw away) and that case is now
  correct by construction; the log file of the id a run actually owns is not
  throwaway state.
- `rebind_logger` survives ONLY as the mid-run `/resume` case (identity changes
  while everything is already running); startup resume no longer rebinds
  anything, and `SessionManager#resume_session` is now the mid-run path alone.
- Startup resume also applies the session's harness-side state (model profile,
  param overrides, YOLO posture) during construction via
  `Harness#apply_resume_state`, so a `--resume` run no longer silently drops
  the posture and overrides the mid-run `/resume` used to restore.
- A session file whose stored `session_id` is not the directory name it lives
  under is now refused (it would split the run's state across two dirs), and a
  typo'd `--resume` id raises BEFORE any session directory is created.
- `--list-sessions` lists through `SessionLocator` (it used to construct a whole
  Harness - client, logger, tool registry - just to read a few JSON files, and
  minted a fresh random id on the way). `CommandHandler#list_sessions` is gone.
- Fix found while testing the real CLI: mid-run `/resume` printed
  `File.basename(path, '.json')`, which has never been the id since the #207
  layout moved the JSON to `<sessions>/<id>/session.json`.
- harness.md: the "a deferred value must be resolved lazily" rule (which
  advertised `DeferredLogger` as a reusable pattern) is replaced by the
  ordering rule - resolve identity before constructing what derives from it.
  Issues #113 / #119 / #123 / #135 / #270 were five symptoms of this one bug.

## Unreleased - first prompt no longer dies on a nil logger (issue #270)

- Fix: with `auto_save: false` (and verbose off), the FIRST prompt of a run
  ended in `[task error] NoMethodError: undefined method 'info' for nil`.
- Cause (stopgap; superseded by #276 above): `Harness#initialize` passed the
  deliberately-deferred logger (nil
  until first use, issue #123) straight into `LLMClient`, and the backend logs
  unconditionally on the first attempt of every request. The lazy `Harness#logger`
  accessor and its client rebind could never help: the crash happened before
  anything had asked for the logger, so the rebind never ran.
- New `DeferredLogger` (`lib/deferred_logger.rb`, DELETED by #276): what such a
  consumer got
  instead of the nil. It resolves the source's `#logger` at CALL time, so it can
  never hold a nil and never pins a logger the owner is about to replace. The
  deferral itself (#123: no throwaway log dir for a fresh id) is unchanged.
- The rule this taught (superseded by the ordering rule in harness.md): a
  deferred value is only correct if RESOLVING it is
  deferred too - a nil placeholder is a snapshot of "not yet", not a deferred
  value.

## Unreleased - TextNormalizer preserves multi-byte text (issue #268)

- Fix: command output lost every non-ASCII character. The child pipe
  accumulator is BINARY (the #257 design), and `String#encode` FROM a BINARY
  tag maps each byte separately, so a valid UTF-8 character was destroyed one
  byte at a time - a 2-byte letter became two '?' and a 3-byte glyph became
  three. A native Finnish `wc -c` total line arrived as `yhteens??`, i.e.
  command output with non-ASCII text was simply unreadable.
- `normalize` now treats a BINARY tag as a BYTE CONTAINER rather than a text
  encoding: read the bytes as UTF-8 first, fall back to the ambient code page
  only when they are not valid UTF-8, and only then replace what genuinely
  cannot be mapped. The fallback refuses BINARY as `default_external`.
- Fix: a string byte-invalid in its OWN declared code page was returned still
  tagged with that code page (scrub in place), re-introducing the
  Encoding::CompatibilityError the #257 boundary exists to prevent. scrub now
  runs on a UTF-8 copy, so the return type is always valid UTF-8.

## Unreleased - YOLO consent posture (PR #266, issues #221 / #254)

- YOLO posture: `/yolo [on|off|status]` skips the `run.command` consent
  dialog (and the model safety check) for every command. Initial posture
  from the config `yolo:` key; the state is saved with the session, so a
  resume keeps it. Mid-turn steering note `/yolo` flips it live.
- Disaster denylist (`CommandAllowlist.disaster?`) is the floor under EVERY
  posture and every stored allowlist grant: `rm -rf`, `mkfs`, `dd of=/dev/`,
  fork bombs, `sudo`, `git push -f`, `curl | sh`, `format C:`, `diskpart`,
  `del /s /q`, `takeown`, `icacls`, `Remove-Item -Recurse -Force`, ... keep
  the dialog, with no "Always allow" option (one-off Allow only). Every
  auto-approved run prints a status line and is logged.
- Bang syntax (`! cmd`) is governed by the new `bang_requires_confirmation:`
  config key (default true), NOT by YOLO - a human-typed command is already
  consent. The denylist still applies.
- Allowlist regex bugs found by the new specs and fixed: bare `takeown` was
  not matched, `ircacls?` typo, bogus `rdel` plus duplicate `erase` entries,
  and `disaster_label` returning an empty label on zero-width lookahead
  matches.
- `Task#yolo_note_action` returned `nil` for a bare `/yolo` (unmatched
  optional group), so the gesture silently fell through into the
  conversation chain; `on` / `off` forms were ignored. Now returns
  `:toggle` / `:on` / `:off`.
- Review fixes: the spinner keeps its real message instead of resetting to
  the bare "Working..." default when the drain loop rebuilds it; the consent
  posture is always labeled (`Harness#command_mode_label` no longer returns
  nil for a real harness) in the startup banner, the prompt modeline and the
  spinner badge at the END of the spinner line; the tag is the bare bracketed
  label (`[YOLO]`), a `cmd:` prefix inside the brackets being noise.
- harness.md de-bloat: the file is injected into every system prompt, so it
  holds coding rules only. Tunable Constants and the Pending / Deferred
  sections were dropped (constants live in the code, deferred work in open
  issues #244 / #254 / #183 / #267), as were the self-descriptive notes about
  how harness.md itself is loaded - the model does not need them to code.
- Code Style now states the WWWW comment rule (What / Why / When / Who / *,
  the star being what the code cannot tell the reader): lead with *why*,
  document *what* only where a complex algorithm hides it, say each thing
  once. It replaces the bare "comments explain why, not what" line.
- Follow-up: issue #267 for the mid-turn gesture-dispatch refactor (remove
  the labeled `/yolo` HACK in `Task#commit_note`).

## 2026-10-15

- #260: the user home config (`~/.config/harness/config.yml`) is the default
  location; `.harness/config.yml` is a per-project override. Lookup order
  `-c` > `$HARNESS_CONFIG` > working dir > user home; the installation-dir
  tier is gone.
- #262: removed the obsolete dry-run mode.
- #264: docs sync - README / harness.md corrected against the actual code.
- #257: externally-sourced text (shell output, file reads, tool-call
  arguments, git output, LLM bodies) is normalized once at each read boundary
  by `TextNormalizer`, so invalid bytes cannot break JSON generation or the
  console.

## 2026-10-14

- #253: `/compact` runs on a Task thread (its output and dialogs follow the
  single-thread I/O rule).
- #249: the consent dialog offers the short prefix alongside the full
  invocation when saving an "always allow" grant.
- #241: allowlisted commands never reach the model safety check (the batch
  precheck skips exactly what the runner auto-approves).
- #240: spec locks the allowlist check ahead of the model safety check.
- LLM log now records per-attempt request/response stats.
- Fix: `require_relative` for `ui` in `command.rb` (the runtime bootstrap was
  broken).

## 2026-10-13

- #235: `/retry` re-sends on a Task thread; the shared `TaskRunner` wrapper
  (Task.run + `[task error]` line) extracted for `/retry` and `/compact`.
- #224: model self-check for unapproved shell commands (advisory verdict in
  the consent dialog), plus the Ctrl+A AUTO-APPROVE toggle and the spinner's
  live mode badge.
- #223: the system prompt is a file reference read on demand, so `/reload`
  picks up edits without a restart.
- #226: elapsed time formatted with minutes for long turns;
  `max_tool_iterations` configurable.

## 2026-10-12

- #219: session-level model parameter overrides (`/param`), unified with
  `/model` param listing; overridden lines show the config value.
- #216: the live context estimate is anchored to the server-reported
  prompt-token count instead of drifting from a rough estimate.

## 2026-10-11

- #217: the active backend target (API type + endpoint path) is surfaced in
  the banner and the spinner.
- #215: the config owns LLM sampling parameters; per-backend wire shapes; an
  unset key is not sent.
- #197: the LLM client is split per backend API type (`openai` / `ollama`) so
  `num_ctx` is honoured.
- #207: session JSON moves into the session directory
  (`.harness/sessions/<id>/session.json`).
- #208: a failed request resumes mid-loop (the working chain IS the session),
  so `/retry` continues from exactly where it stopped, including tool work.
- #198 phases 3-4: idle prompt and steering notes through the multiline
  `UI::Editor` (Enter inserts a newline, the submit key sends the whole
  buffer, Esc keeps a draft), plus CSI Ctrl+Enter bound as a portable submit
  key for remote terminals.
- #202: `run.command` owns the child process group so a timeout can never
  wedge the harness; CI fixes for the platform-specific spawn key and
  `Reline::Windows`.

## 2026-10-10

- #198 phases 1-2: mid-turn steering without a reader thread (keypress peek +
  Reline note editor), dialog choice lines through the same editor, stuck
  grant dialogs fixed (a channel can never be left open with a dead reader).
- Steering note contract documented and specced: one note in flight, the
  latest line wins.
- Workflow rule added: never commit to `master` directly - branch, PR, rebase.
