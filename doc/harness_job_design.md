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
  resolved once from the CLI options and handed around. Harness keeps thin
  delegators so existing consumers keep one read surface. Static config
  (`markdown_max_width`, the three output-buffer limits) is read once there too.
  A resumed run applies its saved postures over the settings via
  `SystemSettings#restore_persisted`.

- **The run record -> JobRegistry.** The run's OutputBuffer is the FOREGROUND
  job's buffer; the `JobRegistry` owns it, not Harness. The CLI builds the
  registry (from the settings' buffer limits), registers the main turn as job
  #0, seeds a resumed run's record (`restore_replay_tail`) and its foreground
  job (`restore_foreground`), and injects the registry into `SessionManager` so
  `save_session` writes `foreground_job` and `replay_tail` from it. Harness
  holds ZERO registry references. Buffer rules: `doc/output_buffer_design.md`;
  the job/queue model: `doc/task_model_design.md`.

## What is still in Harness (deferred)

The SessionManager split (per-LLM loop vs persistence/profile catalogue) and
collapsing the LLM loop into a dedicated turn engine are later increments. The
one known leak: `Session#restore_access_grants` still reaches the run-wide
`FileList` from conversation restore.
