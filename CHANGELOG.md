# Changelog

Per-issue history of what changed in the harness. This file is NOT injected
into the system prompt - `harness.md` holds only coding rules and guidelines,
so fixed-bug notes and release history belong here (and in the issue/PR).

Issue numbers link to https://github.com/kikonen/harness_test/issues/<n>.
Older history lives in `git log`; this file starts at the 2026-10-10 window.

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
