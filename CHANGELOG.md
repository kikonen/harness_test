# Changelog

GENERATED FILE - do not hand-edit it. The procedure, the condensing rule and the
window rule: `doc/changelog_generation.md`.

**A merged PR's body IS its changelog entry.** A PR does not touch this file any
more - no section, no entry, no "Record the #N in CHANGELOG" fix-up commit.
Regeneration is its own docs-only PR.

Issue numbers link to https://github.com/kikonen/harness_test/issues/<n>.

Horizon (measured 2026-10-20 against master `a0605c0`: 118 merged PRs, 348
commits, the 2 merge commits both predating the rebase-merge habit):

- last two merge windows (2026-10-19, 2026-10-20): full entries, condensed.
- 2026-10-10 .. 2026-10-18: one line per merged PR.
- older than that: nothing here. `git log` and `gh pr list --state merged` are
  the archive. The horizon moves when the file is regenerated.

A subsystem's rationale is NOT here - it is in `doc/<topic>.md` (nine such docs
exist) or in the issue. Each entry ends with that pointer when there is one.

## 2026-10-20 - streaming, scratch-zone `.git`, one status line, tier-A specs

### #28 - streamed LLM responses (PR #329, transport path + posture)

- Streaming is a TRANSPORT decision made per request by the caller:
  `BaseBackend#chat(..., stream:, on_delta:)`. A backend holds no posture of
  its own, which is what keeps the advisory calls (`SafetyCheck.run`, the
  `/compact` summary) buffered with the full retry policy. Both paths return the
  identical normalized shape, so `Harness#call_llm` - tool loop, usage
  accounting, session chain, compaction - is untouched by the choice.
- New transport pieces, none per-backend: `LLM::StreamReader` (byte-level split:
  a chunk can split a multi-byte character, 0x0A can never split a line),
  `LLM::StreamDecoder` (SSE `data:` / `[DONE]` and native NDJSON in one decoder;
  an odd line yields nil rather than aborting), `LLM::StreamAccumulator` (both
  wire shapes, both usage shapes, `total_tokens` derived when absent),
  `LLM::StreamPreview` (the cross-thread live tail) and `LLM::StreamError` /
  `StreamStatusError`.
- The posture is harness state: `Harness#stream?` from the `streaming` config key
  (global or a profile's own tri-state key), `/stream [on|off|status]`, spinner
  badge `[STREAM]` (`Task.mode_badge` now joins one bracket per NON-default
  posture). Read PER REQUEST in `request_chain`, so a mid-turn toggle applies to
  the NEXT request; saved and restored with the session like the YOLO posture.
  Opt-in everywhere: `stream: false` at every layer.
- The live tail goes to the spinner suffix, never to stdout: `StreamPreview`
  publishes FROZEN snapshots (the writer is the task thread, the reader the
  spinner - a reference assignment is atomic, an in-place append is not);
  `Harness#request_wait_suffix` returns the newest 60 chars once the answer has
  started and falls back to the context estimate before that. It is cleared in
  `request_chain`'s `ensure`, not after the call, so a request that died
  mid-stream cannot leave its tail for the next one.
- The retry boundary, which is the cost of streaming: a streamed request is
  re-sent only while NOTHING has arrived (`StreamAccumulator#started?`); a
  partial answer fails the turn with `LLM::StreamError` - an `LLMError`, so every
  existing lost-turn handler and `/retry` work unchanged. Each attempt builds a
  FRESH transport: a mid-stream abort closes the connection.
- `OpenaiBackend#build_body` sends `stream_options: {include_usage: true}`
  (from the API reference, not measured against the local endpoint) - without it
  the OpenAI schema reports no usage at all on a streamed response.
- Design and every measured transport fact: `doc/streaming_design.md`.
- Specs: 128 new examples (reader 14, decoder 16, accumulator 25, preview 18,
  `base_backend_streaming_spec.rb` 17 against a REAL chunked HTTP server,
  `/stream` 8, plus 25 in harness / harness_config / task / session_manager and 5
  backend stream flags). Suite 1092 -> 1220 examples, 0 failures. CI's 12 rubocop
  offenses were FIXED, not baselined.

### #321 - a scratch zone's nested `.git` is deletable (PR #331)

- `dir.delete tmp/keep/318` refused: #318 had needed REAL repos to measure git's
  line-ending behaviour, and a real repo has a `.git` (measured on that zone: 144
  entries, 3 nested `.git`, 81 files under them; the walk named one and deleted
  nothing). The zone is not repo state - `git ls-files tmp/keep` is empty.
- The guard protects THIS project's git and harness state, not a disposable clone
  the harness created: inside `tmp/scratch/<n>/` or `tmp/keep/<n>/` a nested
  `.git`, `.harness` or `.env*` is no longer sensitive. `<n>` is required (so the
  zone LIST itself stays blocked) and the test runs on the RESOLVED
  workdir-relative path, so `tmp/keep/318/../.git/config` stays blocked. Grants
  are untouched: an exemption makes a path grantable; `dir.delete` still needs
  one recursive DELETE grant and still logs every removed path.
- `FileList#sensitive?` (the instance method - the only one owning a workdir) is
  the single decision point; the zone-free class-level delegator is gone (measured:
  no caller left). `relative_path` replaces the prefix-stripping half of
  `display_path`. Design: `doc/sensitive_paths_design.md`.
- Specs: new `sensitive_files_spec.rb` (9), 4 in `file_list_spec.rb`, 3 in
  `dir_delete_tool_spec.rb`; the zone pattern was mutation-probed (three variants
  each caught). The tool description, harness.md, README, the `/help access` topic
  and `config/system_prompt.txt` all state the exemption.

### #325 - an auto-approved command is no longer printed twice (PR #333)

- The complaint: an auto-approved `run.command` showed the FULL command on two
  consecutive lines (approval line + outcome line). `CommandRunner#execute` gained
  `auto_approved:` and all three no-dialog entry points (stored allowlist grant,
  YOLO / bang consent off, the AUTO-APPROVE verdict) pass it: the outcome and
  timeout lines name the command by `command_handle` - first `HANDLE_TOKENS` (4)
  tokens plus " ..." when a tail was dropped.
- Why the approval line is the one that keeps the full text: issue #221 requires
  every run that skipped consent to leave a visible trace naming the POSTURE that
  let it through. A dialog-approved command keeps its full text in the outcome
  line - that line is its only trace. `harness.log` is unchanged.
- Specs: 4 new examples in `command_runner_spec.rb` (suite 1236 -> 1240).

### #306 - spec files for the mirror-missing classes, tier A (PR #336)

- Re-measured: 35 mirror-missing `lib/**/*.rb` files, not the 36 the issue said
  (`sensitive_files.rb` gained its spec with #321; `lib/ui.rb` is an empty
  module). Tier A = the classes with branching logic; whether `harness.md` should
  say a declarative wrapper needs no spec stays open on the issue.
- 29 new spec files: 12 tools (`file_copy`, `file_delete`, `file_info`,
  `file_list`, `file_rename`, `git_diff`, `git_grep`, `git_log`, `git_show`,
  `git_status`, `tools_list`, `tools_search`), 11 commands (`clear`, `ctx`, `exit`,
  `model`, `models`, `reload`, `save`, `session`, `session_clear`, `tools`), and
  `Command`, `Tool`, `ToolRegistry`, `GitRunner`, `UI::Console`,
  `lib/llm/shared.rb`, `LLM::StreamError` / `StreamStatusError`. `Tool`'s spec was
  renamed from `tools/tool_base_spec.rb`, which mirrored no lib path at all.
  Suite 1240 -> 1513 examples (+273), 0 failures, 1 -> 3 pending.
- Deliberately not spec'd: `echo_tool`, `get_time_tool`, `notify_tool` (name +
  description + a one-line call; the registry spec covers the shape and
  `harness_spec.rb` drives `test.echo` / `ui.notify` through the real tool loop);
  `keep_alive_http_spec.rb` waits for #334; `harness_error.rb` (three exception
  names) and `lib/ui.rb`.
- Five measured git behaviours pinned as UNREACHABLE fallbacks in the tools:
  `git status --branch` always emits a `## <branch>` line; `git log` / `-G` in a
  commit-less repo is exit 128, not an empty result; `git show --stat` emits no
  patch body; a `-G` regex matches the diff as one block, so a line-anchored
  `^[-+]beta` finds nothing; `--max-count` bounds the matches SHOWN, not the
  walk depth.
- 2 pendings mark real bugs rather than pinning them (#335:
  `@session&.file_cache.clear` safe-navigates only the next send, so the cache
  step raises AFTER the file is already gone).

## 2026-10-19 - output roles and palettes, /help from data, registry drift

### #303 - output roles, UI::Renderer, named palettes (PR #322, first step of #146)

- `Harness#print_step_display` emitted ONE type (`:step`) for four roles and baked
  the pattern into every string. The roles are real event types now -
  `:step_label`, `:plan`, `:interstitial`, `:tool_plan` - and no marker string
  exists anywhere in the buffer.
- New `lib/ui/renderer.rb` owns the pattern: labels replace markers, an unknown
  type renders `content [untyped:name]` loudly, and `VERBATIM` names the roles
  whose prefix an emitter still owns - that list IS the remaining scope of #146.
  The response block's `"=" * 80` / `"-" * 80` decoration entries are gone.
- Tool and command status lines: 83 call sites (measured 60 in tools, 9 grant
  reports, 12 shell-runner lines, 2 harness notes) wrote the whole line. They are
  typed by VERDICT now (`:status_ok` / `:status_fail` / `:status_warn` /
  `:status_note` / `:status_same` / `:status_info` via `Tool#status` /
  `Tool.push_status`), the bracket label travels in the event's ORIGIN, and the
  renderer builds the line. A multi-line status message is ONE buffer entry
  rendered with a `  |` gutter on every continuation line. `Tool.puts` is gone.
- The final answer gets the same boundary: `BOUNDARY_ROLES` (`:step_label`,
  `:response`) is framed by one full-width fused gray rule that NAMES the role,
  then the answer EXACTLY as emitted. `STEP_RULE_WIDTH` became `RULE_WIDTH`.
- New `lib/ui/palette.rb` (`default`, `basic16`, `none`) and `/palette
  [name|status]`, which acks with a sample line rendered through the same
  renderer and says plainly it is effective from the NEXT turn. Validation lives
  in `Harness#output_palette=`, so CLI flag, config key, `/palette` and resume
  share one name check. The palette is saved with the session as its NAME; a
  stored name this build lacks falls back to the default (a user-typed name is
  validated strictly, a name read from a file only has to be usable).
- `store_and_render` asks the renderer for the CONSOLE line and stores the plain
  role content: a color baked into the durable record would be permanent, and
  #146's point is re-rendering that record. Asserted in `spec/lib/task_spec.rb`.
- No tty probe (a piped `$stdout.tty?` is false here even though the terminal
  understands SGR): `-p/--palette NAME`, `--no-color`, or `output_palette:`,
  resolved once at construction. Three compaction / auto-save failures move
  `:error` -> `:warn`: they cost bookkeeping, not the turn.
- Colors come from the owner's terminal measurements, not convention (the bright
  90-97 band, backgrounds and bold are unreadable on a light background; 90 is
  indistinguishable from 2 there, so the 16-color band has no way to
  de-emphasize a line): recessive roles use `38;5;240`, warnings `38;5;130`.
  Full list: `doc/output_rendering_design.md`.

### #323 - /help from data: registry, entries, topics, renderer (PR #326)

- `HelpCommand#handle` was one 182-line heredoc printing 169 lines, listing the
  commands a SECOND time (after `CommandHandler::COMMANDS`) while README was the
  third copy - and nothing checked the three agreed (`/palette`'s missing README
  row is what this found).
- Four layers, one owner each: the registry (WHICH commands exist), a
  `HELP = CommandHelp.new(usage:, summary:, group:, forms:, see_also:)` constant
  per command class (WHAT one is), `lib/help_topics.rb` (the prose as named
  topics) and `lib/help_renderer.rb` (HOW it looks). `Command.help` RAISES for a
  command with no `HELP`, so a registered command cannot be silently missing.
  Bare `/help` is 73 lines instead of 169.
- `HelpTopics.validate!` runs at `CommandHandler` construction (topic names must
  not collide with command names - the first set DID collide on `session`, which
  is why that topic is `conversation`), and `HelpRenderer#help_entries` refuses a
  usage that does not start with its registered name.
- Unknown input names the closest registered names (`/garnt` -> `Did you mean
  /grant?`); the typo band `max_distance: 2` is MEASURED over this command set,
  and a prefix counts as exact so `/res` is an abbreviation.
- README's table is checked against the registry by spec, and its `end a line
  with "\"` text was corrected: backslash continuation was REMOVED by #198 phase 3.
- Specs: new `command_help_spec.rb` (11), `help_renderer_spec.rb` (18),
  `help_topics_spec.rb` (10), `commands/help_command_spec.rb` (16, incl. the drift
  contract), 2 dispatcher examples; `doc/command_help_design.md`.

### #327 - the command registry is checked against the command classes (PR #328)

- Every #323 drift example ITERATED the registry, so a class written, required and
  never registered was found by nothing - the symptom was `Unknown command: /foo`
  at runtime. Measured on 2663103: 20 classes, 20 entries, 20 README rows agreed;
  the guard was simply absent.
- Test-only: `spec/lib/commands/help_command_spec.rb` now asserts
  `COMMANDS.values` equals the `Commands` subclasses of `Command` (both
  directions) and that every key is the first word of its usage form - the check
  `HelpRenderer` already makes, asserted without rendering. 16 -> 19 examples.

## 2026-10-18 - rubocop, scratch zones, line endings from bytes

- #302 Rubocop with loosened defaults, house rules enforced by CI (PR #308) -
  `.rubocop.yml` from scratch (`DisabledByDefault`, 37 cops named) + a
  `.rubocop_todo.yml` baseline (46 cops, 740 offenses); `inherit_mode: merge:
  [Exclude]` is load-bearing. Design: `doc/rubocop_style.md`.
- #317 scratch areas split into `tmp/scratch/<n>/`, `tmp/keep/<n>/` and the
  owner's `local/` (PR #319) - convention only, no code (measured: nothing in
  `lib/` references `tmp/`).
- #318 line endings decided from file BYTES, not a text-mode read (PR #320) - new
  `lib/file_text.rb`; `file.patch` no longer rewrites a whole file with the
  opposite style, refuses non-UTF-8 bytes, never amplifies a bare CR.
  `Layout/EndOfLine` disabled with the reason recorded. Design:
  `doc/file_editing_design.md`.

## 2026-10-17 - two refactors, dir.delete trees, three spinner changes

- #280 mid-run `/resume` builds a FRESH Harness by re-running `CLI#setup` (PR #301)
  - every mid-run re-bind API deleted (`rebind_logger`, `client.logger=`,
  `history.bind_session`, `SessionManager#resume_session`).
- #282 `CLI#setup(resume_id:)` carries the heavy construction so it can re-run
  (PR #297) - the precondition for #280.
- #295 development environments documented (PR #296) - `doc/dev_environment.md`.
- #292 spec flake: git's auto maintenance raced a spec's tmpdir cleanup (PR #293)
  - `maintenance.auto=false`, `gc.auto=0` through git's config env.
- #290 `dir.delete` deletes a whole tree and logs every path (PR #291) - post-order
  walk, whole tree validated before anything is removed, one DELETE grant for the
  tree, per-path audit log; `rm -rf` through `run.command` is never needed.
- #277 turn elapsed time in the spinner (PR #289); #271 compact spinner line
  (PR #288).

## 2026-10-16 - spinner ownership, comments, session identity

- #283 each LLM request announces its own spinner line (PR #287) - the spinner was
  left saying "Compacting ..." for the rest of a turn; `SessionManager#request_spinner_detail`
  is now the single source, called before EVERY request.
- #281 the comment rule made enforceable, offenders stripped (PR #284) - comment
  lines 292 -> 33 in `lib/harness.rb`, 279 -> 209 in `lib/task.rb`; design prose
  moved to `doc/task_design.md`, `doc/encoding_design.md`, `doc/output_buffer_design.md`,
  `doc/session_file_cache_design.md`.
- #276 session identity resolved before anything is built (PR #278) - new
  `SessionLocator`; `DeferredLogger` deleted. #270 the first prompt's nil-logger
  crash (PR #273).

## 2026-10-15 - multi-byte text, YOLO consent, docs sync

- #268 `TextNormalizer` stopped destroying multi-byte text from the child pipe (PR #272)
  - a BINARY tag is a BYTE CONTAINER.
- #221 / #254 YOLO consent posture with the disaster denylist (PR #266) - the
  denylist is the floor under EVERY posture and every stored grant.
- #264 README / harness.md drift fixed (PR #265); #262 the obsolete dry-run mode
  removed (PR #263).

## 2026-10-14 - config home, encoding boundary, /compact on a task thread

- #260 the user home is the default config location (PR #261).
- #257 externally-sourced text normalized at every read boundary (PRs #258, #259).
- #253 `/compact` runs on a Task thread (PR #255); #249 the short prefix offered
  alongside the full invocation (PR #252); #240 the allowlist is checked before the
  model safety call, pinned by spec (PR #250); per-attempt request/response stats
  in the LLM log (PR #248); the post-merge branch-deletion habit recorded in
  harness.md (PR #256).

## 2026-10-13 - safety check, /retry, TaskRunner, system prompt file

- #241 the safety-check model call is skipped for allowlisted commands (PR #247);
  #224 model self-check for unapproved shell commands (PR #234); #235 `/retry` on a
  Task thread (PR #239) and the shared `TaskRunner` wrapper extracted (PR #243);
  #243's `require_relative` hotfix (PR #245); #223 the system prompt as a file
  reference read on demand (PR #232).

## 2026-10-12 - /param, context anchor, elapsed time

- #226 elapsed time with minutes + configurable `max_tool_iterations` (PR #230);
  #219 session-level model parameter overrides (`/param`) (PR #225); #216 the live
  context estimate anchored to the server-reported count (PR #222).

## 2026-10-11 - per-backend clients, multiline input phases 3-4, mid-loop resume

- #215 sampling parameters owned by the config, per-backend wire shapes (PR #217);
  #197 the LLM client split per backend API type so `num_ctx` is honoured
  (PR #215); #198 phases 3-4: idle prompt, multiline steering notes and dialog free
  text through `UI::Editor`, plus the portable submit key for remote terminals
  (PRs #209, #210, #213); #208 a failed request resumes mid-loop (PR #211); #207
  session JSON moved into the session directory (PR #212).

## 2026-10-10 - steering notes, run.command timeout, no direct-to-master commits

- #36 mid-turn steering notes (PR #196); #198 phases 1-2: no-reader steering via
  keypress peek + the Reline note editor, dialog choice line on a real tty
  (PRs #201, #203); #202 `run.command` kills the process tree on timeout (PR #205);
  harness.md: never commit directly to master (PR #204).
