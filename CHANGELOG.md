# Changelog

GENERATED FILE - do not hand-edit it. The procedure, the condensing rule and the
horizon rule: `doc/changelog_generation.md`.

**A merged PR's body IS its changelog entry.** A PR does not touch this file any
more - no section, no entry, no "Record the #N in CHANGELOG" fix-up commit.
Regeneration is its own docs-only PR.

Issue numbers link to https://github.com/kikonen/harness_test/issues/<n>.

Horizon (measured 2026-11-08 against master `22f80a2`: 188 merged PRs, 124 in
the horizon (>= 2026-10-10), 64 older):

- 2026-11-08 .. 2026-10-10 (124 merged PRs): one bullet per merged PR, keyed on
  its PR number; a bullet may wrap to at most 5 lines at 80 columns.
- older than 2026-10-10: nothing here. `git log` and `gh pr list --state merged`
  are the archive; the horizon moves on each regeneration.

A subsystem's rationale is NOT here - it is in `doc/<topic>.md` or the issue.
Measured at generation: 33 design docs on master, all of them pointed at from
here (its own procedure doc `doc/changelog_generation.md` among them), so every
doc pointer in this file resolves.

## 2026-11-08
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
