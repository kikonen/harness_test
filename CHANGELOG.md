# Changelog

GENERATED FILE - do not hand-edit it. The procedure, the condensing rule and the
horizon rule: `doc/changelog_generation.md`.

**A merged PR's body IS its changelog entry.** A PR does not touch this file any
more - no section, no entry, no "Record the #N in CHANGELOG" fix-up commit.
Regeneration is its own docs-only PR.

Issue numbers link to https://github.com/kikonen/harness_test/issues/<n>.

Horizon (measured 2026-10-23 against master `c831d76`: 120 merged PRs, 56 in
the horizon (>= 2026-10-10), 64 older):

- 2026-10-23 .. 2026-10-10 (56 merged PRs): one bullet per merged PR, keyed on
  its PR number; a bullet may wrap to at most 5 lines at 80 columns.
- older than 2026-10-10: nothing here. `git log` and `gh pr list --state merged`
  are the archive; the horizon moves on each regeneration.

A subsystem's rationale is NOT here - it is in `doc/<topic>.md` or the issue.
Measured at generation: 14 design docs on master, 12 of them pointed at from
here (its own procedure doc `doc/changelog_generation.md` among them), so every
doc pointer in this file resolves.

## 2026-10-23
- #338 added written-down procedures: `.harness/skills/<name>/SKILL.md`, read
  only by `lib/skills.rb`, surfaced as `skills.list` / `skills.read` / `/skills`
  - a skill body NEVER enters the system prompt. A name must be ONE path
  segment; `.env*` stays blocked in the zone. Design: `doc/skills_design.md`.
  Specs: skills_spec, skills_read_tool_spec, skills_command_spec. 1518 -> 1583.

## 2026-10-22
- #348 tracked `analysis/<n>/` (`repro.rb`, `measure.sh`) for committed
  per-issue evidence, because `tmp/` is gitignored and a keep zone can never
  hold quotable evidence. First content: the repros of #341-#346, each with its
  expected output in its own header. Gotcha: `analysis/*.rb` is rubocop code.
  Design: `doc/sensitive_paths_design.md`. Suite 1513 -> 1518. Merged rebase.

## 2026-10-20
- #329 streamed LLM responses as a TRANSPORT decision per request
  (`BaseBackend#chat(stream:, on_delta:)`); a backend holds no posture, so the
  advisory calls stay buffered. New pieces (StreamReader/Decoder/Accumulator/
  Preview), `/stream [on|off|status]`, spinner `[STREAM]`. A streamed request
  re-sends only while nothing arrived. Design: `doc/streaming_design.md`.
- #331 exempted a scratch zone's nested `.git` from the sensitive guard: inside
  `tmp/scratch/<n>/` or `tmp/keep/<n>/` a nested `.git`/`.harness`/`.env*` is no
  longer sensitive (`<n>` required). `FileList#sensitive?` is the single
  decision point. Design: `doc/sensitive_paths_design.md`.
- #333 printed an auto-approved `run.command` once: the outcome line names it by
  `command_handle` instead of repeating the full text (the approval line keeps
  it as the consent posture trace, per issue #221). Specs: 4 new examples.
- #336 spec'd the mirror-missing tier-A classes: 29 new spec files (12 tools, 11
  commands, plus Command/Tool/ToolRegistry/GitRunner/UI::Console). Re-measured
  35 mirror-missing files, not 36. Suite 1240 -> 1513 (+273), 3 pending.

## 2026-10-19
- #328 asserted the command registry equals the command classes (test-only drift
  guard, issue #327).
- #326 split `/help` into data and renderer; the listing is generated from the
  registry (issue #323). Design: `doc/command_help_design.md`.
- #322 output roles, `UI::Renderer`, named palettes and `/palette` (issue #303,
  first step of #146). Design: `doc/output_rendering_design.md`.

## 2026-10-18
- #320 decided line endings from file BYTES, not a text-mode read (issue #318).
  Design: `doc/file_editing_design.md`.
- #319 split scratch areas into `tmp/scratch/<n>/`, `tmp/keep/<n>/` and the
  owner's `local/` (issue #317); both zones are gitignored and local.
- #308 ran rubocop with loosened defaults and enforced the house rules in CI
  (issue #302). Design: `doc/rubocop_style.md`.

## 2026-10-17
- #301 mid-run `/resume` rebuilds a FRESH Harness via `CLI#setup` (#280).
- #297 `CLI#setup(resume_id:)` carries the heavy construction so it can re-run
  (#282).
- #296 recorded the development environments. Design: `doc/dev_environment.md`.
- #293 stopped git's auto maintenance from racing a spec's tmpdir cleanup
  (issue #292).
- #291 `dir.delete` deletes a whole tree and logs every path (issue #290).
- #289 turn elapsed time shown in the spinner (issue #277).
- #288 the compact per-request spinner line (issue #271).

## 2026-10-16
- #287 each LLM request announces its own spinner line (issue #283). Design:
  `doc/task_design.md`.
- #284 made the comment rule enforceable and stripped its offenders (#281).
- #278 resolved the session id before constructing Harness, new SessionLocator
  (issue #276). Design: `doc/session_file_cache_design.md`.
- #273 fixed the first prompt's nil-logger crash when nothing logged first
  (issue #270).

## 2026-10-15
- #272 stopped `TextNormalizer` from destroying multi-byte text from the child
  pipe; a BINARY tag is a BYTE CONTAINER (issue #268). Design:
  `doc/encoding_design.md`.
- #266 added the YOLO consent posture with the disaster denylist (issues #221
  and #254).
- #265 fixed README / harness.md drift against the actual code (issue #264).
- #263 removed the obsolete dry-run mode (issue #262).

## 2026-10-14
- #261 made the user home the default config location (issue #260).
- #259 recorded read-boundary encoding normalization in harness.md (issue #257).
- #258 normalized externally-sourced text at every read boundary (issue #257).
- #256 recorded the post-merge local branch-deletion habit in harness.md.
- #255 ran `/compact` on a Task thread (issue #253).
- #252 offered the short prefix alongside the full invocation (issue #249).
- #250 checked the allowlist before the model safety call, pinned by spec.
- #248 added per-attempt request/response stats in the LLM log.

## 2026-10-13
- #247 skipped the safety-check call for allowlisted commands (issue #241).
- #245 `require_relative` hotfix in `command.rb` (follow-up to PR #243).
- #243 extracted the shared `TaskRunner` wrapper (issue #235 follow-up). Design:
  `doc/task_design.md`.
- #239 ran the `/retry` re-send on a Task thread (issue #235).
- #234 added a model self-check for unapproved shell commands (issue #224).
- #232 turned the system prompt into a file reference read on demand (#223).

## 2026-10-12
- #230 added elapsed-time display with minutes + configurable
  `max_tool_iterations` (issue #226).
- #225 added session-level model parameter overrides, `/param` (issue #219).
- #222 anchored the live context estimate to the server-reported count (#216).

## 2026-10-11
- #217 made the config own LLM params with per-backend wire shapes (#215).
- #215 split the LLM client per backend API type so `num_ctx` is honoured
  (issue #197).
- #213 made multiline input submittable on a remote host via Windows Terminal
  (issue #198).
- #212 moved session JSON into the session dir (issue #207).
- #211 resumed mid-loop after a failed request (issue #208).
- #210 added multiline steering notes and dialog free text via UI::Editor
  (issue #198 phase 4).
- #209 routed the idle prompt through `UI::Editor` multiline (#198 phase 3,
  #91). Design: `doc/reline_cursor_and_enter_handling.md`.

## 2026-10-10
- #205 made `run.command` kill the process tree on timeout (issue #202).
- #204 recorded in harness.md: never commit directly to master.
- #203 added the dialog choice line via UI::Editor on a real tty (#198 phase 2).
- #201 no-reader steering via keypress peek + the Reline note editor (#198
  phase 1).
- #196 added mid-turn steering notes: type a note while the model works (#36).
