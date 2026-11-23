# Changelog

GENERATED FILE - do not hand-edit it. The procedure, the condensing rule and the
horizon rule: `doc/changelog_generation.md`.

**A merged PR's body IS its changelog entry.** A PR does not touch this file any
more - no section, no entry, no "Record the #N in CHANGELOG" fix-up commit.
Regeneration is its own docs-only PR.

Issue numbers link to https://github.com/kikonen/harness_test/issues/<n>.

Horizon (measured 2026-11-23 against master `d2ece8a`: 263 merged PRs, 199 in
the horizon (>= 2026-10-10), 64 older):

- 2026-11-23 .. 2026-10-10 (199 merged PRs): one bullet per merged PR, keyed on
  its PR number; a bullet may wrap to at most 5 lines at 80 columns.
- older than 2026-10-10: nothing here. `git log` and `gh pr list --state merged`
  are the archive; the horizon moves on each regeneration.

A subsystem's rationale is NOT here - it is in `doc/<topic>.md` or the issue.
Measured at generation: 47 design docs on master, all of them pointed at from
here (its own procedure doc `doc/changelog_generation.md` among them), so every
doc pointer in this file resolves.

## 2026-11-23
- #579 fixed steps repeated / jumping backwards (issue #577): the `step N`
  label was the per-`call_llm` loop counter, reset on every turn restart, so a
  continuous console saw 11,11,12,12. It is now a Harness-level monotonic
  `@step_number`; same PR: a tool-call count in the label (`step 8 [2]`) and a
  guard so in-loop compaction cannot fire on consecutive iterations.
- #576 renamed the `ui.note` tool to `session.note` (issue #550): the note is
  model-side state, never a UI message; the `ui.` namespace made notes read like
  user steering. `record_note` matcher, system prompt, README and docs updated.
- #581 split `spec/lib/harness_spec.rb` (3370 lines) into ten scoped files plus
  `harness_spec_support.rb` under `spec/lib/harness/` (issue #580). No test
  changed: 224 examples before and after, whole suite 3164 / 0.
- #578 drew the resume replay BEFORE the startup banner (issue #553): the saved
  tail was printed partway through the banner, so the run's facts wrapped around
  the replay. New `resume.replay_on_startup` gate (default on);
  `print_startup_banner` refactored.
## 2026-11-22
- #549 recorded the #548 design: session persistence as a harness session
  (per-agent conversation) vs a run (system) session (the JobRegistry record,
  postures, the run -> agent-session map). Design:
  `doc/session_layers_design.md` .
- #554 continued #548: `/jobs add` builds a real second agent through the run's
  `HarnessFactory`; `/replay` shows the recorded tail; a resume rebuilds EVERY
  saved job (the old `finished?` gate left background chains unwritten); a job
  carries only its own record - record before the foreground switch, seed every
  restored job from its own tail.
- #575 added `file.touch` (issue #552): the external-change reconciliation tool
  the write/patch errors already promised - re-baselines the cached digest,
  never creates or modifies the file, never bypasses a grant.
- #566 fixed the renderer width falling back to 80 columns (issue #561):
  `#width` asked only the sink, so `RULE_FALLBACK_WIDTH` became the width and
  the 80% rule was never taken. Specs pin SPEC_TERMINAL_COLUMNS=176 so a
  wrapped spec cannot pass locally and fail in CI.
- #565 fixed the steering note ack and body being two lines at different widths
  (#561): new `:ack_note` role - ack + body as ONE block at the note width.
- #563 excluded `analysis/**` from rubocop: CI was red on every run - 26 of 329
  files' offenses were in `analysis/551/measure.rb`; a repro script's style is
  not what its issue is about.
- #562 printed the resume line the user can actually run (issue #502):
  `bin/harness` is the entry point (.env, BUNDLE_GEMFILE); `-m` can contradict
  the session's saved `active_model`. Five sites fixed, not the three named.
- #569 closed #551 by measurement: the byte-budget fix (OutputBudget + spill,
  `doc/tool_output_budget_design.md`) already caps every shape the issue names
  (a 4 MB single line lands at 20,042 B); the issue's figures are a historical
  baseline.
- #571 gave a model profile three distinct facts (issues #556, #572): id (the
  selector, unique), name (display), and a required `model:` field the backends
  send on the wire - only the profile knows which model its endpoint answers
  for. Pre-id configs and pre-`model:` sessions still resume. Design:
  `doc/model_identity_design.md` .
- #573 added `/jobs delete <id>` (issue #558) and prune-at-save (issue #557):
  `JobRegistry#remove_job` + `SystemSaver#remove_job` (unlink the `system.json`
  entry first, then the job dir); `Job#interrupt` answers only a truly-awaiting
  job; the foreground job is refused.
- #564 fixed the invisible mid-turn prompt (issue #561): `poll_for_note` reuses
  the run's shared InputPath, whose `PROMPT = "  "` is a continuation marker -
  no modeline above a mid-turn read made it look like a frozen turn.
- #570 reported the stats line of a turn that aborted (issue #567): `call_llm`
  publishes the turn's measurements as state; an aborted turn prints answered-
  over-sent iterations, no `📊`/`⚡` (those describe requests that returned).
- #574 briefened comments across lib/ (issue #558): code byte-identical, long
  class headers moved to doc/ (3-line max), method comments trimmed to the house
  budget, issue refs dropped from method bodies. Suite 3132 / 0.
- #559 made the sandbox starter a repo config file (#340):
  `config/sandbox_gemfile.example.rb` is the single source `ensure_starter!`
  copies verbatim; the default gem list gained `fiddle` + `reline` (measured:
  reline is no longer a default gem and its Windows IO gate needs fiddle).
- #560 fixed the sandbox template header (#340): the seed copies the file
  VERBATIM, so text written from the template's own point of view contradicts
  itself inside the copy; rewritten true in both roles.
## 2026-11-20
- #546 moved the postures and consent flags out of the options carrier (PR1
  slice A of the #286 god-object refactor): `Harness#initialize` no longer seeds
  yolo/stream/markdown/plan/palette/safety-approve from `options`; the creator
  (`CLI#apply_initial_postures`) sets them. The four session-persisted postures
  still restore over it (#221). Design: `doc/system_settings_design.md` .
## 2026-11-15
- #530 settled the registry shape (#286 phase 0): one buffer per JOB, so the
  head key stays origin + type and the job is supplied by WHICH buffer is read
  (measured: one shared buffer collapses two live tasks into ONE cell).
- #531 landed #286 increment 1: `Job` (graph node: id, kind, status, deps, own
  buffer, own inbox, NO outbox - events go to the registry's ONE fan-in queue
  tagged with the job id, which keeps cross-job order defined) and `Registry`
  (the single poller; each event lands in the event's own job buffer). The
  main turn is job #0. Design: `doc/task_design.md` .
- #534 landed #286 increment 2: `TaskRunner#run_on_task` AWAITs a job; a task
  built for a job (its inbox IS the job inbox, its buffer IS the job buffer,
  poll reads the ONE registry queue); a background dialog denial returns
  `Job::DENIED_ANSWER` (grant dialogs excepted); `lib/input_path.rb` makes
  prompt and mid-turn note ONE read with edit state in the poll loop.
- #536 fixed an interrupted turn answering what it owes (refs #473, #424): a
  force-stopped turn answers every open request with `Job::INTERRUPTED_ANSWER`
  (STOP is not an answer, so `request()` raised); `Job#respond` is the single
  answer primitive; the raw-stdin hold is gated to POSIX hosts.
- #542 made edit mode dispatch commands mid-turn (#286 inc1): a `/command`
  submitted during a turn goes through `CommandHandler#run_mid_turn`, gated by
  `Command#mid_turn_safe?` - the `/yolo` note-gesture hack is deleted. Bare text
  keeps the note route byte-for-byte. Design: `doc/unified_loop_design.md` .
- #541 extracted the `Poller` off `Task` (#286 inc 2a): the drain loop, spinner
  control, note read and raw-stdin hold belong to whoever polls, not to a Task.
  Mechanical, no behavior change.
- #540 renamed `Registry` to `JobRegistry` (#286): the job layer and the tool
  layer shared a bare "Registry" suffix, and the class actively owns the ONE
  fan-in queue, not a lookup table.
- #538 kept head AND tail when truncating `run.command` (issue #537): a test
  runner prints its failure block at the TAIL, which head-only truncation cut -
  exactly the "missing errors" complaint. `DEFAULT_LIMIT` 200 -> 500.
- #539 gave each dialog request a dedicated reply channel (issue #424):
  `Task#request` popped the shared inbox, so a steering note queued ahead became
  the dialog's choice and the real answer leaked to the next request. `#request`
  now opens a private `@pending_reply` queue.
## 2026-11-14
- #529 documented the registry layer before any runtime (#286 phase 0): the head
  key's task part (measured: two live tasks on one (origin, type) stream
  collapse into ONE cell) and `output: tasks_kept`'s first enforcement point.
  Naming decided: the graph node is Job, the executor keeps Task.
- #528 collapsed the two output stores into ONE OutputBuffer per run (#286
  inc6): `absorb_turn` existed only to copy between a per-Task buffer and the
  run-level `@output_log`; the drain loop is now the single main-thread writer,
  so a turn's output lands in the record a save reads.
- #526 split the OutputBuffer record into the durable tail (append-only
  immutable Entries - the half a renderer re-lays out) and the live head (one
  mutable cell per stream, `:append` vs `:replace` modes), bound into the drain
  loop, with two tail limits (memory + saved). Refs #286.
- #525 moved `HelpRenderer` into `UI` and banned the hand-built `ljust` table
  (#474 inc24): the command table, topic index and usage block state named
  fields laid out by `UI::Renderer` `:table`; a width is chars or a percentage.
## 2026-11-13
- #522 made `/ctx` a field/value `:table` (#474 inc21): `Harness#context_report`
  became `Harness#context_usage` answering the facts the compaction decision
  already computes; the row shape belongs to the renderer.
- #519 added the `:body` role (#474 inc19): `PlansCommand` was the only command
  building its own renderer; all three stores now state role + raw text and
  `UI::Renderer#body_line` renders it - one mechanism, no markdown markers
  leaking from `/memory` / `/skills`.
- #511 rendered the `/mcp` server report as a `:table` (#474 inc16): name /
  transport / target / status as named fields; the status carries either the
  tool count or the failure reason - data, not a sub-line.
- #512 turned `/clear` outcomes into verdicts (#474 inc17): a revocation that
  removed something is `:ok`, an already-empty store is `:info` (a count is a
  statement about the store, not a verdict) - the case that makes the split
  worth having, recorded in the doc.
- #513 made the `/palette` role groups a `:table` (#474 inc18): group | role |
  code per row; a nil-mapped role states `(terminal color)`.
- #521 gave `/memory` and `/plans` a `:table` listing with a number the payload
  carries (#474 inc20): `memory <N>` works like `plans <N>`; the body rule shows
  the number only when the entry was opened by number.
- #517 raised `Plans::MAX_BODY_CHARS` 8000 -> 12000 (addresses #515): every
  message quotes the constant, so one line changed everything; measured need was
  a real plan refused at 8274 chars.
- #524 made the blank line framing a turn the `:gap` role (#474 inc23): a
  `ui.puts` call is never in the record, so a replay had nothing to lay out.
- #514 renamed the emit-only methods for what they do (#474):
  `print_step_display` -> `emit_step`, `print_stats` -> `emit_stats`,
  `print_params` -> `emit_params`, `dump_verbatim` -> `emit_verbatim`.
- #516 renamed `PaletteCommand#print_roles` -> `#emit_roles` (#474); after this
  every remaining `print_*` name is accurate (measured by reading each body).
- #523 stated the TaskRunner error line and `#emit_line` as roles (#474 inc22):
  the `:kind` role with origin `task error`, and ONE router (`#status_event`)
  instead of a second direct-`ui.puts` path.
## 2026-11-12
- #498 rendered the `/mcp` tool listing as a `:table` (#474 inc6): MCP tool
  descriptions are genuinely multi-paragraph markdown; kramdown owns the cells.
- #499 rendered `/tools` as a `:table` and dropped the dead `:grouped_kv` kind
  (#474 inc7); tool names are already namespaced, so no group column.
- #500 rendered `/param` and `/session` as `:table`s (#474 inc8): `list_items` /
  `summary` return named-field rows; the #219 shared-listing invariant holds.
- #501 folded the remaining prose acks into `:note` (#474 inc9); data-source
  `:text` (help, ctx, clear) stays verbatim - its value IS its alignment.
- #505 folded the yolo denylist and mcp collision blocks onto `:bullet`
  (#474 inc10), with the correction recorded: they were NOT byte-identical -
  `:bullet` re-indents them out of the report nesting.
- #506 rendered the palette legend as a `:table` (#474 inc11); doc correction:
  the role groups were listed as alignment blocks and are not (longest line 106
  chars, nothing padded).
- #507 folded the batch-B prose lines onto `:note` (#474 inc12): nine verbatim
  `@ui.puts` lines across five commands.
- #508 rendered the grant store lists as a `:table` (#474 inc13): the ordinal is
  data the payload carries; reusing `:numbered_kv` with an empty description
  renders a dangling ` - `, so the owner chose the table.
- #509 stated the store errors as a verdict (#474 inc14): `[error]` lines in
  memory/plans/skills became `:fail` with the store as origin - a refused name
  is a hard stop, not a `:warn`.
- #510 registered `:rule` in `VERBATIM` so a rule line can be painted
  (#474 inc15): the palette always had a `rule` role but no renderer type could
  name it; `emit_role(:rule, ...)` hit the #146 untyped diagnostic.
## 2026-11-10
- #492 landed the #474 groundwork: a command report emits structure - a
  `{ title:, kind:, columns:, items: }` payload drawn from fields by
  `UI::Renderer#list_line`; the browser half is deliberately deferred. Footer
  indent is a LEVEL, not baked spaces. Design:
  `doc/output_rendering_design.md` .
- #493 added the `:kv` list kind for `/skills` and `/memory` (#474 inc1): a
  row's fields are read BY NAME, so the `columns` order never decides what a
  field is.
- #494 added `:numbered_kv` for `/plans` (#474 inc2): the ordinal is a named
  field the renderer right-aligns, not the array position.
- #495 added `:grouped_kv` for `/tools` (#474 inc3): each item is a section
  (header + rows), the registry's caching order passed through.
- #496 added `:session` for `/sessions` (#474 inc4): the separators are renderer
  layout; the same PR stripped the restating #474 comments.
- #497 replaced the bespoke `:session` kind with a generic `:table` rendered via
  kramdown (#474 inc5): the payload's `columns` array IS the schema; column
  sizing and word-wrap are kramdown's, the hand-rolled padding was removed.
- #490 fed the first unresolved text-shaped tool call back to the model (refs
  #487, option C): a call whose name matches no tool previously failed only to
  the user, so the model repeated it; a `user` message now names the ambiguity.
  #487 stays open on purpose (options A/B undecided).
- #491 restored Ctrl+C on Windows (#473): the raw-stdin hold's guard was true on
  every Windows turn but `input_pending?` does not exist there, so the hold
  served nothing and broke Ctrl+C; the hold is gated on `input_pending?`.
- #488 held a real-tty stdin in raw mode for the turn wait (#473): a cooked tty
  line-buffers, so `stdin.input_pending?` never fired and a lone keypress never
  opened the note editor on a Linux/KDE console. `raw!(intr: true)` keeps Ctrl-C
  raising Interrupt.
- #489 wrapped a markdown-off `:plan` / `:interstitial` line to RULE_WIDTH
  (#485): the markdown-ON path wrapped, the default path emitted one unbounded
  line; continuations align under the label.
## 2026-11-09
- #484 salvaged the leading array from double-encoded dialog options (issue
  #468): a model that stringified `options` AND fused the sibling keys into
  that string produced an unparseable value; `salvage_leading_array`
  bracket-scans the array out, with a sharp error when nothing salvageable
  remains.
- #472 moved the LINE BREAK to the renderer (issue #470): the `:note` role -
  unwrapped paragraphs, re-wrapped to a fixed NOTE_WIDTH (78 content cols), not
  the terminal width; a report's contiguous prose is ONE `:note` array call.
  Design: `doc/output_rendering_design.md` .
- #486 rendered a command's bad-argument usage from its HELP (#471): five
  commands carried a hand-aligned `def usage` duplicating their `HELP`;
  `HelpRenderer#render_inline` + optional `CommandHelp#form_notes` is now the
  one source. Design: `doc/command_help_design.md` .
- #477 stopped a markdown `:response` dropping angle-bracket content (issue
  #475): kramdown-ansi renders an unknown html_element to nothing - even the
  text after an inline tag. `#escape_angle` escapes `<` outside code spans; `>`
  is never escaped so blockquotes still work.
- #478 wrapped dialog notes and option descriptions to a fixed width (issue
  #476); a fitting note prints verbatim, so 72 dialog specs pass untouched.
- #483 reopened #476: the fixed 80 was a picked value, not a rule - on a
  narrower terminal the wrapped lines overflow and option titles were never
  wrapped. The dialog now wraps to the same percentage-of-terminal basis the
  plan/say markdown path uses.
- #480 rendered a steering note as `:note` (issue #479): the committed note was
  one hand-baked string whose header ran past 80 columns and whose body dumped
  at column 0, stored `:text` so the resume replayed it misaligned; now a
  `:kind` ack + a renderer-wrapped body.
- #482 dropped `rprompt` from the note editor's readmultiline (issue #481):
  Reline paints rprompt on the first visible row, gluing a copy of `note> ` to
  the right edge. A live probe disproved the buffer-vs-window theory: Reline
  tracks the window LIVE.
## 2026-11-08
- #463 regenerated this file (issue #305): dataset rebuilt with gh - 188 merged
  PRs, 124 in the horizon; the previous file declared 77, so its own lag check
  named exactly the 47 uncovered PRs. Docs-only. The gotcha a regeneration
  cannot fix: it cannot bullet its own PR.
- #465 stopped persisting the system prompt in the session file (issue #464):
  `Session#to_h` serialized it twice (`system_prompt:` and `messages[0]`), and
  resume REPLACED the freshly built prompt with the save-time one, so a
  `harness.md` edit after a save was silently ignored. `to_h` now serializes
  only `@messages[1..]`; resume rebuilds from `build_system_prompt`.
- #467 made the renderer own labels/brackets and the sink own the palette
  (issue #466): emitters state ONE role (+ origin), `UI::Renderer` decides the
  label/glyph/bracket, `UI::Palette` the color; a browser sink paints nothing;
  terminal bytes stay identical. Design: `doc/output_rendering_design.md` .
- #462 ran a tool call a model wrote as TEXT (issue #461, qwen pseudo-XML): it
  left `message[:tool_calls]` empty, so the pseudo-XML was committed as the
  final answer and the turn ended silently. `TextToolCallParser` rebuilds the
  synthetic array the tool loop runs; only the OPEN marker gates it - the safety
  is name resolution. Design: `doc/text_tool_call_design.md` .
- #460 named the DROPPED steering note on the console discard line (issue #450):
  the log line carried the text, the console did not, so the user could not tell
  which of their steering lines to resend.
- #459 replayed the tail the user SAW when a session is resumed (issue #458):
  one run OutputBuffer holds both sides (a user line is a `:user` entry, there
  is no separate echo), `replay_tail` /`restore`/`keep_tail`, `NON_REPLAY` skips
  the animated `:spinner_detail` , config `resume: replay_entries:` (30, 0 off).
  Design: `doc/output_buffer_design.md` .
## 2026-11-07
- #457 stopped hijacking Ctrl+A (issue #454): it is Reline's 'beginning of
  text', so the consent-mode key conflicted with the standard edit. The
  AUTO-APPROVE posture itself is unchanged - config-derived for the whole run.
- #456 set CI `ruby-version: '4.0'` : ubuntu-26.04 ships only the latest patch
  of a series, so the pinned `ruby-4.0.1` 404'd in 'Set up Ruby' before any test
  ran. Local `.ruby-version` untouched. Refs #455.
- #453 gave the model pixels from disk and the web (issue #451): `file.image`
  reads an image under file.read's grant rules and sniffs the type from magic
  bytes (a PNG renamed `.txt` is still a PNG); `web.fetch` keeps an image body a
  BYTE container. Design: `doc/mcp_images_design.md` .
- #452 delivered an MCP image content block to the model (issue #449): it had
  reached it as a bare `[image: image/png]` . `ToolResult` carries the bytes,
  `ImageStore` saves per session id, `ImageDelivery` decides inline / file /
  drop against three budgets, `vision:` per profile gates pixels. Design:
  `doc/mcp_images_design.md` .
## 2026-11-04
- #447 stated what the disaster floor does NOT see (issue #392, docs half): a
  quoted wipe (`sh -c "rm -fr ~/"`) is NOT flagged; `mkfs` / `sudo` payloads are
  caught by whole-text markers only. `analysis/392/repro.rb` classifies strings,
  runs nothing. Design: `doc/denylist_safe_approve_design.md` .
- #446 stopped offering a shell reserved word as an 'Always allow' grant (issue
  #148): prefix extraction exploded `for f in ...; do ...; done` into a 9-option
  wall of keyword grants. `program_token?` rejects `SHELL_RESERVED_WORDS` before
  the subcommand test, so a control-flow segment yields no candidate.
- #444 stated the scope every command-grant offer saves (issue #96, option 1):
  `grant_scope_note` describes each candidate shape - "any command starting with
  these words, whatever follows" vs "only commands starting with exactly these
  words". Matching is byte-for-byte unchanged. Design:
  `doc/command_grant_scope_design.md` .
## 2026-11-03
- #443 fixed a glob's base directory (issue #152): `file.search` and `file.list`
  cut the pattern at the first wildcard, so a brace glob asked for a nonsense
  path; `glob_base_dir` takes the leading literal segments. `/clear` gained
  forms (`clear commands` / `shell` / `hosts` / `all` ) to revoke a stored
  command prefix or web.fetch host (issue #104).
- #442 started a run with ONE recursive read+write+delete grant on the working
  directory (issue #384, `grant_workdir:` default true) and made the consent
  dialog offer the widest scope first. `.env*` , `.git/` , `.harness/` and a
  path outside the workdir are still asked for. Design:
  `doc/standing_grant_design.md` .
- #441 split the 605-line `ui/editor.rb` monolith (issue #440): each Reline
  patch is one module under `UI::RelinePatch` , and `grep "class Editor"` hits
  exactly one file. No behavior change. Design: `doc/editor_input_design.md` .
- #439 made the Ctrl+A consent toggle fire in a real terminal (issue #236):
  `key.char == 1` never matched Reline's `"\^A"` String.
  `UI::Editor.control_key?` is now shared by every intercepted control key. The
  old specs fed `key(1)` - the shape the bug expected - so they stayed green
  while it was broken.
## 2026-11-02
- #438 added `sessions.search` (issue #279): `SessionLocator#search` runs a
  case-insensitive substring over every saved session's message text and id,
  newest-first - the model finds a past session by what it was ABOUT.
  `--delete-session <id>` is a one-shot CLI action with no dialog.
- #437 made the memory note cap config-only via `max_memories` (issue #435) and
  raised the built-in default 40 -> 50. The display sites read the configured
  cap. Design: `doc/memory_design.md` .
- #436 revoked grants on the EXACT path a delete removed (issue #105):
  `FileList#revoke_grants` drops every mode and tier for that path; an ancestor
  RECURSIVE grant stays. Prune-on-nonexistent was the tempting wrong fix -
  `grant_access` deliberately grants write/delete to a not-yet-existing path.
- #434 saved the session when a run changed STATE, not only on a prompt (issue
  #188): `/model x` then `/exit` saved nothing, because `empty?` meant "no
  messages". `HistoryManager#has_pending_entries?` is read BEFORE `#save` clears
  it. A run that typed nothing still saves nothing.
- #433 scoped a steering note to the turn it was typed in (issue #430): a note
  arriving during the final-answer request leaked into the NEXT prompt as a
  phantom mid-turn note. `:late` and `:leftover` discards clear the slot and
  name the case. `/retry` KEEPS a pending note - same turn. Design:
  `doc/task_design.md` .
- #432 fixed `ui.dialog` "rejecting a valid title" (issue #427): 61 October
  rejections, none was bad JSON. An `options` blob re-encoded as a JSON string
  is parsed back, a missing title is told from a blank one and named by option
  index, and the title is model-optional.
- #431 read config secrets from ENV via a dollar-brace placeholder (issue #422):
  expansion is an identifier regex plus `ENV[name]` - NEVER eval, never ERB -
  and an unset variable raises a `HarnessError` naming it. The secret never
  reaches a session file. Design: `doc/config_secrets_design.md` .
## 2026-11-01
- #429 locked the seeded sandbox offline (follow-up to PR #428): a fresh seed
  runs `bundle lock --local` (it exits 7 with NO partial lock on an absent gem),
  so `bundle exec ruby` of the starter gems works out of the box. A fresh seed
  costs ~1.1s; the `exist?` early return 0.0s. Design:
  `doc/sandbox_gemfile_design.md` .
- #428 seeded a per-project Ruby sandbox at `.harness/sandbox/Gemfile` (issue
  #340): `CommandRunner` wraps every command in `Bundler.with_unbundled_env` ,
  so a bare `ruby` saw the box's ambient gems. Gotcha: `bundle exec` ISOLATES
  the load path - an unlisted gem is a LoadError even when installed. Harness
  seeds, the model manages. Design: `doc/sandbox_gemfile_design.md` .
- #425 made `/mcp` a report, not a toggle (issue #405): `Mcp::Manager` keeps one
  ServerState per DECLARED server; `data[:mcp_connected]` is saved with the
  session and `report_saved_session` names a server the saved conversation used
  but this run cannot reach. No live toggle (tools ride `tools_payload` , which
  #246 needs identical). Design: `doc/mcp_design.md` .
- #423 added the MCP HTTP/SSE transport (issue #402): an `mcp_servers:` entry
  may name `url:` (+ `headers:` ) instead of `command:` , exactly one (they
  reach different trust boundaries). The `mcp` gem does the protocol;
  `ServerConnection#connect` is the only place touching it. Design:
  `doc/mcp_design.md` .
## 2026-10-31
- #421 made the denylist see a path-invoked recursive-force delete (issue #417):
  `recursive_force_rm?` matched only the bare token `rm` , so
  `disaster?("bin/rm -rf /")` was false. Basename matching first, then
  path-shaped commands (`bin/rspec`) can be granted by glob.
- #419 rendered `/plans <name>` through the renderer that already exists (issue
  #416): `UI::MarkdownRenderer` , palette-seeded, same `markdown_max_width`
  basis, so a plan table is sized like an answer table; palette `none` keeps
  structure with no markers or ANSI.
- #418 fitted each spinner frame to the terminal width (issue #401): a frame
  wider than the terminal soft-wraps and the next `\r\e[2K` erases only the row
  under the cursor, leaving residue. `analysis/401/repro.rb` builds the
  worst-case live frame: 141 display columns.
- #415 made `bin/rspec` run the whole suite in parallel by default (issue #396).
  Anything WITH arguments stays serial rspec - `parallel_tests` groups by FILE,
  so one file is faster alone (dialog_spec 2.4s serial, 11s across processes).
  `PARALLEL=false` reproduces a parallel run serially.
## 2026-10-30
- #413 rendered the 9 known-degrade rescues through `ErrorText.label` (issue
  #409 Tier C): hand-built `"#{e.class}: #{e.message}"` in CommandRunner,
  `precheck_batch_safety` , `parse_tool_arguments` and friends. Typed rescues
  stay out of scope - naming a class the rescue already named says nothing.
- #412 made logger calls read without argument parentheses (closes #411): the
  cop STAYS `require_parentheses` and the five log levels join `AllowedMethods`
  - enforcement lands before the sweep. 69 single-line rewrites, 11 multi-line
  continuations re-indented, 3 safe-navigation sites kept out of a mechanical
  conversion. Design: `doc/rubocop_style.md` .
- #410 logged the frames at the Tier B crash sites (issue #409):
  `CLI#auto_save_session` logged nothing at all and `execute_tool_call` logged
  only `e.message` , so an unexpected tool crash left no backtrace.
## 2026-10-29
- #408 stopped `--list-sessions` from exiting inside `CLI#initialize` (issue
  #299): it records `@listing` and returns before `setup` , so it builds no
  Harness or session; `run` dispatches the status. Same branch moved argument
  parsing into `CLIOptions` and the idle read into `PromptReader` .
## 2026-10-28
- #407 made the protected dirs configurable (`protected_dirs:`, issue #385): the
  posture never auto-covers them, but a HUMAN grant still does - only the
  posture's auto-approval is blocked. Absent key = `[local]` , empty = nothing.
- #406 let KeepAliveHTTP reach the real socket (issue #334): since Ruby 4.0
  `Net::HTTP#connect` wraps it in a BufferedIO, so `respond_to?(:setsockopt)`
  was false and keepalive was silently never set. Unwrapped through
  `BufferedIO#io` ; the spec reads options back off a real TCPServer.
- #400 made the harness an MCP client, phase 1 (issue #48): client-only,
  tools-only, stdio-only. `Mcp::ServerConnection` , `Mcp::ToolAdapter` ; a
  server that fails to start degrades to a status note (never crashes the run)
  and a colliding name never shadows a built-in tool. Gemfile gained `mcp` plus
  `base64` . Design: `doc/mcp_design.md` .
## 2026-10-27
- #399 rendered the assistant's answer as markdown (issue #106): kramdown-ansi,
  roles seeded from `UI::Palette` so color stays owned in one place, a
  table-width cap (the gem sizes tables from terminal columns), `/markdown` as
  an OUTPUT posture with no spinner badge. Design:
  `doc/markdown_rendering_design.md` .
- #397 added the advisory `/plan` posture and the `[PLAN]` badge (issue #359
  phase 2): no tool gate, ever. `[PLAN]` shows in the spinner AND the idle
  prompt with no new plumbing - the shared badge builder PR #394 introduced.
  Design: `doc/planning_mode_design.md` .
- #395 landed the durable plan store (issue #359 phase 1): a plan must live
  OUTSIDE the message chain, because both compaction paths replace the chain
  with a summary. `Plans` is the single reader/writer, behind `plan.*` tools and
  `/plans` . Design: `doc/planning_mode_design.md` .
- #394 made the idle prompt line show `[STREAM]` (issue #387): the spinner and
  the prompt read the same posture differently. `CLI#get_command` now calls the
  same `Task.mode_badge` the spinner uses, so the tags cannot drift again.
- #393 committed the evidence for #392: `analysis/392/repro.rb` CLASSIFIES
  command strings and executes nothing. `-fr` is caught because
  `recursive_force_rm?` tests the flag COMBINATION, not a phrase; the same
  payload in a quoted argument is not flagged unless a marker word carries it.
- #391 made a dialog note carry a KIND, never a color (issue #388): `context` ,
  `warn` , `alert` , `safe` , the console choosing the hue. `context` is
  unpainted in every palette - a note is content the user must read. Design:
  `doc/dialog_colors_design.md` .
## 2026-10-26
- #390 folded both relaxations into one enum key, `command_safety_auto_approve`
  : `manual | safe | denylist | safe_denylist` (issue #389). A `safe:` verdict
  may relax the denylist floor, config-only, on the tool path only. DETECTION is
  never weakened. Design: `doc/denylist_safe_approve_design.md` .
- #386 let the YOLO posture cover file access in the workdir (issue #274):
  `FileList` had no notion of a posture, so a run asked once per candidate file
  and a `dir only` grant did not cover what was under it. The posture is a live
  lambda, so a flip applies to the next call and a resume cannot make it
  standing. Design: `doc/standing_grant_design.md` .
- #383 stopped YOLO paying for a batch safety pre-check it cannot consume (issue
  #382): measured across 4 denylisted commands x 3 postures, the check is NOT
  blocked by the denylist - YOLO's auto-approval returns before a verdict could
  be read, so the fork only cost tokens. Design: `doc/safety_check_design.md` .
- #381 made every advisory fork keep the prompt prefix on BOTH axes (issue
  #246): a chat template renders the chain AND the tool definitions, so a
  compact path sending `tools: nil` while the live turn sent 32 definitions (21
  075 B) diverged at the tools region. `analysis/246/repro.rb` judges each fork
  on both axes. Design: `doc/compaction_cache_design.md` .
## 2026-10-25
- #380 regenerated this file from merged PR bodies (issue #305): 141 merged
  PRs, 77 in the horizon against master `ccbd1ac`; the file it replaced
  declared 59, so the lag check named exactly the 18 uncovered PRs. Docs-only,
  no lib/ or spec/ touched. Gotcha a regeneration cannot fix: it cannot
  bullet its own PR.
- #379 fixed a streamed request's delta callback holding its OWN preview:
  `request_chain` built `on_delta` from the `@stream_preview` ivar its own
  `ensure` clears, so a late delta hit `undefined method 'record' for nil`
  (reproduced single-threaded, analysis/378/repro.rb). The ivar stays the main
  thread's reader handle; the callback captures this request's preview object.
- #377 made a task-thread crash diagnosable from the logs (issue #376):
  `Task#start` pushed only `"#{e.class}: #{e.message}"` as `:error_ctrl`, so no
  backtrace ever survived and every crash inside a turn was undiagnosable.
  `Task#record_task_error` logs the exception WITH its backtrace through the
  harness logger; the event is pushed FIRST so a failing logger cannot hide it.
- #375 reported a truncated answer as truncation instead of blaming the model
  (#345): `finish_reason` now rides at the TOP LEVEL beside `usage` (OpenAI
  `choices[0].finish_reason`, native `done_reason`, bare `done: true` ->
  "stop"), where each wire shape puts it; anything outside `FINISH_EXPECTED`
  warns in the log AND the console. Design: `doc/truncation_design.md`.
- #374 bound a model verdict to its command by NUMBER, never by line position
  (#344): `SafetyCheck` mapped `lines[idx] -> commands[idx]`, so one preamble
  line shifted every verdict (measured: `rm -rf /tmp/x` read as SAFE under
  AUTO-APPROVE). A bad ordinal yields no verdict, and the drop is logged.
  Design: `doc/safety_check_design.md`.
- #373 removed the last pending example: the symlink case of
  `dir_delete_tool_spec` now runs on Windows through a directory junction
  (`mklink /J`), because `File.symlink` needs developer mode. A junction IS a
  link to Ruby (`File.symlink? true`) while `File.directory?` is also true - the
  reason the tool checks the link predicate before `File.directory?`.
- #372 stopped a nil Session reporting a successful delete/rename as a failure
  (#335): `@session&.file_cache.clear(path)` guards only the NEXT send, so the
  file was already gone when the raise reached the model as an error. The cop
  that prevents it, `Lint/SafeNavigationChain`, had ALREADY found both sites -
  `.rubocop_todo.yml` excluded those very files, so the entry is now gone.
- #370 added `web.fetch`, the second network surface, with guards the model
  cannot widen: a host grant only says the host may be ASKED for, for ONE exact
  host (`example.com` never covers `evil.example.com`); `WebFetcher` resolves
  ONCE, connects to the address it checked, refuses loopback and private
  ranges, stops at the byte cap. Design: `doc/web_fetch_design.md`.
- #369 stopped the spinner looking FROZEN while a streamed model writes a tool
  call (#368): the fragments reached the harness and were dropped, so the tail
  sat on the last reasoning sentence while the rate decayed. `feed` now reports
  `tool_call_names` for ANY chunk carrying them - names only, never arguments -
  the preview keeps them sticky and the phase line carries no rate.

## 2026-10-24
- #367 made the spinner name the tool that is RUNNING: nothing re-pointed the
  detail for a tool round, so during a 40-second `run.command` the line still
  read as if the model were generating. `Harness#announce_tool_call` names the
  tool before `Tool#execute` (arguments are NEVER shown on a one-line spinner);
  `CommandRunner#announce_run` swaps in the command's handle for the child.
- #366 fixed four independent defects on the spinner line (issue #364): the rate
  slot jumped up to 4 characters between frames (`9.0` rendered as `9`), `\r`
  left the previous frame's tail, the cut marker glued itself onto the answer's
  own dots, and a truncated tail was 63 wide for a 60-char budget. The rate got
  a fixed column, every frame erases, and `MAX_TAIL` counts its marker.
- #363 added memory the model maintains itself (#10): `Memories` is the only
  reader and writer of `.harness/memories/`, behind `memory.list` / `read` /
  `add` / `delete` and `/memory`. A memory names a note NAME, never a path, so
  the store cannot become a general writer inside `.harness/`; nothing it holds
  is injected into the system prompt. Design: `doc/memory_design.md`.
- #361 put a tok/s rate ON the spinner line (#285): `StreamPreview#live_rate`
  measures it where the deltas arrive, its clock taken on the FIRST delta
  (prefill produces no text, so a rate from before the answer started is not a
  generation rate). `~` means the HARNESS estimated it, `(last)` means the
  number describes a FINISHED request; nothing measured, nothing shown.
- #360 captured the server-reported performance of a response (#251):
  `cached_tokens`, the llama.cpp `timings` object and Ollama's
  `prompt_eval_duration` / `eval_duration` were on the wire and thrown away.
  `LLM::UsageStats` normalizes them; a prompt rate divides the UNCACHED tokens
  and per-request rates are never summed. Design: `doc/llm_stats.md`.
- #358 gave Ctrl+G to an external editor for the buffer being typed (#298): a
  KEYBOARD shortcut, not a slash command - a command runs after the read returns
  and can only see what was SUBMITTED. `UI::ExternalEditor` spawns argv words,
  never a shell, and closing the editor leaves the text as the DRAFT. Design:
  `doc/external_editor.md`.

## 2026-10-23
- #357 made `verify.rb` report the changelog's LAG instead of failing on it: a
  regeneration is always behind the merged-PR list, so PASS had only been
  reachable with a dataset frozen at the file's own writing time.
  `declared_horizon` + `lag_of` tolerate exactly the newest `horizon.size - N`
  PRs, so a hole in the middle (the #205 bullet deleted) still FAILS.
- #356 made `file.search` validate an INVALID regex instead of raising (#346):
  the exception escaped the tool and the model read the generic
  `execute_tool_call` rescue string, indistinguishable from a harness failure,
  so it retried the SAME pattern. The answer now names the rejected pattern, and
  the search half sits in the rescue's `else` - it never starts the file walk.
- #354 normalized the `harness.md` rules read at its boundary (issue #341):
  `File.read(project_file).strip` raised `Encoding::CompatibilityError` at
  startup, before any session state existed, and the same read runs again at
  every prompt. `TextNormalizer` now touches the bytes first, and a repair is
  NOT silent: the count of replaced bytes is named in the log and the banner.
- #353 extended the 2026-10-23 section with the bullets the previous runs had
  left out (#350, #351, #352) and corrected the preamble's doc-pointer count:
  three CONSECUTIVE runs had each left their own PR's bullet behind, because a
  number is absent from a dataset of merged PRs at generation time. Docs-only;
  every older date section stayed byte-identical.
- #338 added written-down procedures: `.harness/skills/<name>/SKILL.md`, read
  only by `lib/skills.rb`, surfaced as `skills.list` / `skills.read` / `/skills`
  - a skill body NEVER enters the system prompt. A name must be ONE path
  segment; `.env*` stays blocked in the zone. Design: `doc/skills_design.md`.
  Specs: skills_spec, skills_read_tool_spec, skills_command_spec. 1518 -> 1583.
- #350 appended the #338 bullet the generation rule had left out: that run
  measured its horizon against its own branch, so the PR that introduced the
  rule had none in the file it generated. Gotcha: a regeneration cannot bullet
  its own PR (the number exists only once the PR is opened) - the NEXT run
  absorbs it. Check: verify.rb with --against, run twice.
- #351 stopped a denylisted command printing its full text twice (issue #349):
  the pre-dialog refusal line already names it, so `execute`'s flag
  `auto_approved:` became `full_shown:` and the denylist branch sets it too. A
  plain dialog-approved run keeps the full text - for it the outcome line is
  its only trace. Evidence: analysis/349/repro.rb. 1583 -> 1584.
- #352 normalized the prompt-file read: `read_system_prompt` returned File.read
  as-is, so a --system-file with invalid bytes became the FIRST message of every
  chain and died later in JSON.generate - the request body AND the session save
  (issue #342). harness.md is the one prompt read still unnormalized (#341).
  Design: `doc/encoding_design.md`. Suite 1584 -> 1586.

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
