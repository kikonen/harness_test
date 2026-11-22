# Harness ownership: what lives where (issue #286)

Design rationale for the decomposition of `lib/harness.rb`. Verified against
branch `refactor/286-slice-a-postures`.

## Why Harness must shrink

A Harness owns ONE LLMClient connection and runs ONE conversation turn
(`call_llm` / `request_chain`). Owner's rule: a thing that must be shared across
multiple tasks cannot live in Harness, because a single Harness manages a single
connection. Harness had grown into two welded objects - the per-LLM turn engine
AND run-wide state. The run-wide half is leaving, increment by increment.

The three targets:

1. **Turn engine** (per-LLM) - the request/parse/tool-loop machinery. Stays.
2. **Conversation** - the Session message chain and its context/compaction math.
3. **Run / world** (exactly one per process) - the CLI's natural job:
   `SystemSettings`, the `JobRegistry` (the run record and its job list),
   tool_registry, memories/plans/skills/mcp/file_list, the logger, and the
   save/resume persistence.

## What is already out

- **Posture / consent state -> SystemSettings.** The yolo/stream/markdown/plan/
  palette postures and the two command-safety flags live in `SystemSettings`,
  resolved once from the CLI options and handed around. The CLI's ONLY run-config
  holder is `@settings` - it holds no raw `@options` hash and exposes no `options`
  reader; every startup fact (workdir, resume/continue, the dispatch modes, the
  resolved editor and submit key) is read through a settings accessor, so the CLI
  carries the resolved config, never the bag it was resolved from. Harness holds
  NO posture/consent delegators - every consumer reads the posture off the
  settings it already has (a consumer holding settings reads `settings.X`; one
  holding only a Harness reads `harness.settings.X`, via its `attr_reader
  :settings`). Static config (`markdown_max_width`, the three output-buffer
  limits) is read through the settings too. A resumed run applies its saved
  postures over the settings via `SystemSettings#restore_persisted`.

  The planning posture is the exception that stays Harness-owned (`@plan` ivar,
  `plan?`/`plan=`/`toggle_plan`/`plan_mode_label`): it is per-conversation state
  seeded from the config only, so a #286 sub-agent sharing the settings object
  is NOT forced into planning mode by a `[PLAN]` toggle on the foreground.

- **The run record -> JobRegistry.** The run's OutputBuffer is the FOREGROUND
  job's buffer; the `JobRegistry` owns it, not Harness. The CLI builds the
  registry (from the settings' buffer limits), registers the main turn as job
  #0, seeds a resumed run's record (`restore_replay_tail`) and its foreground
  job (the #548 resume model sets `@registry.foreground` directly - the old
  `restore_foreground` special case is gone), seeds EVERY restored job from its
  own saved tail (`restore_replay_tail(job:)` - a save writes what a buffer
  holds, so an unseeded job saves an empty tail), and injects the registry into
  `SessionManager` so `save_session` writes `foreground_job` and `replay_tail`
  from it. Harness holds ZERO registry references. Buffer rules:
  `doc/output_buffer_design.md`;
  the job/queue model: `doc/task_model_design.md`.

  The Harness itself is now the JOB's, not a CLI- or command-held global: a
  Harness is ONE LLM tool-loop, so it belongs to a Job. `Job` owns a `#harness`
  reference (nil until it is driven); `JobRegistry#add_job` takes a `harness:`
  and its `#run` reads it off the job (`Task.run(harness: job.harness)`) rather
  than from the caller. The CLI builds the Harness, attaches it to the main job
  through `HarnessFactory#add_harness_job(kind: :main, base_file_list:)` and keeps
  no `@harness` ivar; it reaches it through `CLI#foreground_harness` =
  `@registry&.foreground_job&.harness`.
  A command reaches it the same way (`Command#foreground_harness` =
  `registry&.foreground_job&.harness`); a command constructor takes NO `harness:`
  and there is no `attr_reader :harness` on a command. Naming it after the job it
  reads off (foreground_harness) is deliberate: a later background/sub-agent
  harness reads the same way off its own job. The factory and the SYSTEM id are
  now handed down the same way a command already receives the registry
  (`CommandHandler#build_command`), which is what `/jobs add` uses to add a
  second agent through the SAME builder the main turn used.

- **FS-backed stores (memories/plans/skills) -> the tools/commands.** Each is a
  stateless reader over its on-disk dir, so it is not Harness's own state.
  `build_tool_registry` now builds one instance per store as a local and hands
  it to the tools; `/memory`, `/plans` and `/skills` build their own from the
  same `FileList` workdir. The dir is the single source of truth, so the tool
  side and the command side cannot drift. Harness holds no `@skills`,
  `@memories` or `@plans` and exposes no reader for them.

## What is still in Harness (deferred)

The SessionManager split (per-LLM loop vs persistence/profile catalogue) and
collapsing the LLM loop into a dedicated turn engine are later increments. The
persistence half of that split - moving the run-level keys (`yolo`/`stream`/
`markdown`/palette, the run record, `mcp_connected`) out of the per-Harness
`save_session` into a run-owned writer - is issue #548, designed in
`doc/session_layers_design.md`. The one known leak: `Session#restore_access_grants`
still reaches the run-wide `FileList` from conversation restore.
