# Harness is a god-object: the job/harness split

Design for correcting the ownership model behind issue #286. Verified against
master `9af6fa0` (2026-11). Read `doc/task_model_design.md` and
`doc/task_design.md` first: the Job/registry layer this doc depends on already
exists.

---

## The problem (owner, 2026-11)

`Harness` is one run-wide singleton that every command reaches into and mutates,
seeded from the giant `options` hash. That is the wrong shape. A harness should
be ONE LLM tool-loop that lives inside one job, and there can be many of them
(sub-agents, #286 phase 1). Run-wide state belongs to a separate run/session
object that those harness instances share.

Concrete, today (verified):

- **23 command classes hold `@harness`**, and several mutate it:
  `@harness.plan=` (`plan_command.rb`), `@harness.stream=`, `@harness.yolo=`,
  `@harness.markdown=` / `@harness.output_palette=`, and `/model` + `/param`
  rewrite `@harness.options`. Postures are seeded into the harness at
  `Harness.new` from `options[:plan]` / `options[:stream]` / `options[:yolo]` ...
- **The `options` hash is the carrier.** It is a mutable bag threaded into
  `Harness`, `LLMClient`, `SessionManager` and `ParamOverrides`; `harness.rb`
  reads `options[...]` ~30 times and several code paths write into it
  (`apply_profile`, `switch_model`, `param_overrides`). As long as it is the
  carrier, any consumer can (re)own anything.
- **The dependency points the wrong way.** A `Job` carries no harness (its
  fields are `id/kind/status/result/registry/buffer/inbox/dependencies/
  requested_by`), yet the single run-wide `Harness` **builds and owns the
  `JobRegistry`** (`@registry = JobRegistry.new(...)` in `Harness#initialize`,
  then `add_job(kind: :main)`). Jobs are created by, and hang off, the
  god-object - a job cannot outlive or out-number its harness.
- **`Harness.new` builds subsystems from config keys**: `@registry` from
  `options[:output_tail_memory] / [:resume_replay_entries] / [:output_tasks_kept]`,
  `Memories` from `options[:max_memories]`, MCP from `options[:mcp_servers]`.
  That is run-wiring, not the job of a tool-loop.

The display-state change in #286 Step A (`UI::RenderSettings`) is a SYMPTOM of
this, not the disease. PR #544 moved the palette/markdown storage into a new
class but every consumer still read it *through the harness handle* and the
harness still held the object - that is a relabel, not an ownership transfer.

## The model this doc targets

Two distinct things, currently fused into one `Harness`:

| thing | scope | owns |
|---|---|---|
| **RunContext** (a run/session object) | one per run | the Session + `SessionManager`, the `JobRegistry`, memories/plans/skills, file list, history, consent posture, model/config, display settings, and the session round-trip |
| **Harness** (an LLM tool-loop) | one per job | the tool loop for ONE job: its chain, its tools, its client call, its logger; reads posture/config from RunContext, never stores it |

`Job#kind` is already `%i[main sub_agent command timed]`. A main-turn job and a
sub-agent job each run *their own* harness tool-loop over *their own* Session,
against the *one* RunContext.

Commands act on **RunContext + the foreground job**, not on a hardcoded
`@harness`. The foreground-job notion already exists and is wired exactly this
way for input: `cli.rb` sets `input_path.target = -> { @harness.registry.foreground_job }`
and `JobRegistry#foreground_job` resolves it. The refactor moves the *commands*
onto that same target instead of onto the run-level harness.

### Where each current `Harness` responsibility goes

| Harness responsibility today | moves to |
|---|---|
| `call_llm` tool loop, `execute_tool_call`, finish-reason/text-call recovery | **Harness** (per job) - this is its whole job |
| `Session`, `SessionManager`, session save/restore, model switching | **RunContext** (one Session per job, owned by the run object) |
| `JobRegistry` construction + `add_job` | **RunContext** (or the CLI), built from a resolved config - not from `Harness.new` digging `options[...]` |
| postures: `@plan/@stream/@yolo` + their labels | **RunContext** (run-wide posture), read at request/turn boundaries |
| display settings (`UI::RenderSettings`) | **RunContext** / the CLI (never on a Harness) |
| model config, `num_ctx`, compaction thresholds | a **resolved RunConfig** (replaces the `options` bag), read by both |
| `logger` | RunContext supplies it to each Harness (a job may scope its own) |

## Sequencing (each its own PR, suite-green, rebase-merge only on owner word)

The blast radius is large and touches live harness source, so it is staged
bottom-up: kill the carrier first, then lift run state, then split the loop.

1. **PR0 - this design doc only.** No code. Owner tunes the boundary
   (esp. RunContext vs CLI responsibility, and posture granularity) before any
   implementation. Also re-scopes #286 Step A in `doc/unified_loop_design.md`.
2. **PR1 - replace the `options` god-hash at the seams.** Introduce a resolved
   `RunConfig` (named fields, immutable where possible) built once by the CLI
   from `CLIOptions`/`HarnessConfig`; pass named params + collaborators into
   `Harness.new` instead of the raw hash. Touches `LLMClient`, `SessionManager`,
   `ParamOverrides`, compaction getters, tool constructors. Fixes the
   `Harness.new`-builds-subsystems-from-config-keys problem: the run object (or
   CLI) builds the `JobRegistry` from config and injects it.
3. **PR2 - extract `RunContext`.** Lift the run-wide state out of `Harness`
   (Session/SessionManager/registry/postures/display). Commands take
   `RunContext` (+ the foreground job) instead of `@harness`.
4. **PR3 - split the per-job tool-loop.** `Harness` becomes the narrow loop;
   commands target the foreground job; multiple harness instances per run become
   real (this is the prerequisite for #286 phase 1, `agent.explore`).

This arc *is* the #286 "task is a generic async runner" cleanup at its root:
Step A/B/C were the leaf symptoms; this is the trunk. Increment 4 (control
events drained at the request boundary) lands naturally once a command enqueues
onto the foreground job rather than mutating a global harness.

## Invariants that MUST survive every step

- single-thread I/O rule: a task thread never writes a stream or a buffer.
- per-job buffers + the ONE registry fan-in queue (`doc/task_model_design.md`).
- streaming/posture is read per request - a change lands on the next request,
  never on a connection already in flight.
- issue #303: the OutputBuffer record stays pattern-free; the palette reaches the
  console only.
- the session round-trip still carries postures + display (but that state does
  not live on a Harness).

## Status

No code for this model is written. The display-state WIP that was half-applied
on `feature/286-render-settings` was discarded (it is a symptom fix); the tree
is green at the committed base. PR #544 (the cosmetic Step A) stays open pending
this decision.
