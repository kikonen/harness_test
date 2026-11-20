# Session persistence layers: harness-session vs run (system) session (issue #548)

Design notes for splitting session persistence along the ownership seam #286 has
already established. This is a DESIGN document only; no code is written for #548
yet. It states the conflation, the evidence in today's code, the proposed two-layer
shape, the file-layout options with their costs, the increments, and the decisions
still open. Issue #548 stays OPEN until the owner picks the layout.

Cross-refs: #548 (this), #286 (agent tasks / the Job model), #458 (the run record),
#207 (session dir layout), #276 (identity resolution), #188 (the `state_changed`
workaround this replaces), #405 (`mcp_connected`). Ownership decomposition:
`doc/harness_job_design.md`; the job/queue model: `doc/task_model_design.md`.

Verified against `master` `7ecb88c` (the merged slice-A postures branch).

---

## The conflation #548 names

Session persistence has **one owner and one file** but carries **two structurally
different kinds of state welded together**:

- the **per-agent conversation** - a Harness' `Session` message chain, its file
  digest cache, its access grants, and that agent's own model / param-override
  state; and
- the **run / world** - the `JobRegistry` record (the job list, which job was
  foreground, the replay tail), the run-wide postures (`yolo`/`stream`/`markdown`/
  `output_palette`), and `mcp_connected`.

`doc/harness_job_design.md` already states that a Harness is three things welded
together (the per-LLM turn engine, the conversation, and run/world state) and that
the run/world half is being moved out increment by increment - postures went to
`SystemSettings`, the run record went to `JobRegistry`, the FS-backed stores went
to the tools/commands. **The persistence layer never got that split.** `save_session`
is a method on `SessionManager`, which is built by and owned by ONE Harness, yet
it serializes run-wide keys. The ownership doc names the smell directly in the
present tense:

> "SessionManager is built by Harness, which holds no registry, so its owner
> injects it."

That injection is the tell: an object is being made to serialize a run it does not
own. `#548` is that sentence turned into a fix.

## Evidence in today's code

The conflation is not hypothetical; three concrete facts in the current tree make
it concrete.

**1. One id is shared between the run and the foreground agent.**
`CLI#setup` resolves `@session_id` exactly once (`@locator.resolve_id`), and keys
everything off it: the session directory, `SessionLogger.build(@locator.session_log_path(session_id))`,
`HistoryManager.new(@file_list.workdir, session_id:)`, and the saved `session.json`.
That same id is passed straight into `Harness.new(..., session_id:)`, which feeds it
to `Session.new(..., session_id: log_id ...)` where `log_id = session_id || @locator.fresh_id`.
So the **run's directory name** and the **foreground agent's conversation id** are the
same number, and there is no place left for a second id that means "this run".

**2. A sub-agent's session is minted but never saved.**
`Job::KINDS` already includes `:sub_agent`, and `doc/task_model_design.md` Phase 1
gives a sub-agent "its own session". `Session#initialize` defaults `@session_id ||=
SecureRandom.uuid`, so a sub-agent Harness built without an injected id gets its own
id, would resolve its own directory, and its own log - but **nothing ever saves it**.
Every save trigger in the codebase is the *foreground* Harness' `SessionManager`:
`CLI#auto_save_session` -> `foreground_harness.session_manager.save_session`,
`SaveCommand` -> `foreground_harness.session_manager.save_session`, and
`SessionManager#maybe_auto_save` from inside the foreground turn loop. A `#286`
agent that does real work has no persistence path at all.

**3. The exit save decides for the whole run from one agent's conversation.**
`CLI#auto_save_session`:

```ruby
return nil if foreground_harness.session.empty? && !state_changed
foreground_harness.session_manager.save_session
```

The run-level decision ("does this run deserve a saved session?") is made by reading
only the *foreground agent's* emptiness. `state_changed` (a `@history.has_pending_entries?`
heuristic, added by #188) is a bolt-on: it exists because a run that changed settings
(`/model`) or ran a background job but sent no foreground prompt still has state worth
saving, and the foreground conversation alone cannot see that.

## The seam: two sessions, two owners

Split persistence along the ownership line `doc/harness_job_design.md` already draws -
a Harness is ONE LLM tool-loop and belongs to a Job; the CLI/`JobRegistry` is the
"Run / world" half, exactly one per process:

- **Harness session** - one per agent/Job. Holds: the `Session` message chain, the
  file digest cache, the access grants, and that agent's own `active_model` /
  `param_overrides`. Owned by that agent's Harness / `SessionManager` (its persistence
  half). Saved under the agent's own session id.
- **Run / system session** - exactly one per process. Holds: the `JobRegistry` record
  (job list, the foreground id, the replay tail), the run-wide postures, `mcp_connected`,
  and a **run -> agent-session-id map** (the piece that does not exist today). Owned by
  CLI / `JobRegistry`.

The distinction is not new vocabulary invented for this issue - it is exactly the
`doc/harness_job_design.md` split of "conversation" from "run / world", applied to the
one subsystem that never received it.

With the seam in place, save is **run-driven, not foreground-driven**: the CLI owns the
run session and, at exit, enumerates the retained Jobs and lets each Job's Harness
persist its own harness session; resume reads the run record first (identity, job list,
postures) and then restores each retained agent's harness session. `auto_save_session`
then asks the honest question - "did ANY job in this run accumulate session-worthy
state?" - instead of "is the foreground conversation empty?", and `state_changed`
becomes unnecessary.

## What each layer owns (the full key map)

The keys `save_session` writes today, partitioned by which layer they belong to:

| key | layer | today's owner | honest owner |
|-----|-------|---------------|--------------|
| `messages`, `file_cache`, `access`, `workdir`, `user_prompts`, `last_stats`, `created_at`, `session_id` | harness | `Session#to_h` | Harness session (correct already) |
| `active_model`, `param_overrides` | harness | `SessionManager` | Harness session (per-agent model state) |
| `yolo`, `stream`, `markdown`, `output_palette` | run | `SessionManager` (per-Harness) | run session |
| `foreground_job`, `replay_tail` | run | `SessionManager` via injected `registry` | run session (the registry's own data) |
| `mcp_connected` | run | `SessionManager` | run session |

The `yolo`/`stream`/`markdown`/`palette` keys already carry comments calling them
"harness posture, not conversation state" and "harness consent state, not conversation
state" - they are run-level choices the harness happens to read, not part of any one
agent's message chain. They belong to the run session. The `registry` injection exists
only because a per-Harness object was asked to reach the run record; moving the record
to its owner deletes the injection.

## File-layout options (the open fork)

Two shapes, both workable; the choice is the owner's and changes the increments.

**A. Two files per run.** `.harness/sessions/<run-id>/run.json` plus per-agent
`<agent-id>/session.json` (each agent dir already keyed by its own id, as logs and
history are). `run.json` carries the run record and the `agents:` id list.
- Pros: each layer is a standalone file the locator can read without decoding the
  other; a sub-agent's session already looks like the existing per-session dir; the
  run id and the foreground agent id stop being the same number.
- Cons: identity resolution must now resolve a *run* id and then follow it to agent
  ids; `/sessions` and `--resume` change what they list and what they read.

**B. One file with two blocks.** a single `session.json` that holds a `run:` block and
an `agents:` block (the foreground agent's chain living where `messages` is today).
- Pros: keeps today's one-file-per-session directory and the `#207`/`#276` identity
  machinery almost unchanged; resume reads one file.
- Cons: the run record and the conversation still share a file and (if the foreground
  agent's chain stays under `messages`) the run id and the foreground id stay coupled;
  a sub-agent's chain must go in a nested `agents:` section rather than its own dir.

The design leans toward **A** because it is what makes a sub-agent's session a real
saved object and is what the ownership split actually implies - but it is the costlier
migration, and **B** may be the right first increment if the owner wants the seam
without re-doing identity resolution yet. This is the central open decision.

## Increments (a suggested sequence)

1. **Partition `save_session`.** Split it into a harness-session writer (the
   `Session#to_h` keys + `active_model` + `param_overrides`) and a run-record writer
   owned by CLI/`JobRegistry` (jobs/foreground/replay_tail/postures/mcp_connected).
   Delete `SessionManager#registry` and its injection. No layout change yet - the two
   writers can still emit into one file (option B) while the seam is proven.
2. **Choose and apply the layout** (option A or B). This is where the run -> agent-id
   map first appears.
3. **`SessionLocator` learns the run record.** It becomes the reader of the run file and
   the resolver that follows a run id to the agent ids it names, so list/resume/delete
   understand both layers.
4. **Save/resume enumerate the retained Jobs.** `CLI#auto_save_session` walks
   `@registry.jobs` and asks each Job's Harness to persist its harness session; resume
   reads the run record, restores postures/foreground, then restores each agent session.
   Sub-agent sessions become saved objects.
5. **Replace `state_changed`.** Exit decides on "any retained job has session state?"
   rather than the history-entry heuristic.

`doc/harness_job_design.md` already defers "the SessionManager split (per-LLM loop vs
persistence/profile catalogue)" to a later increment; #548 is that deferral scheduled.

## What this is NOT

- **Not a rename of `Session`.** The `Session` class stays the conversation chain. The
  new thing is a run-level record and a map to agent sessions, plus moving the run-level
  keys out of a per-Harness writer.
- **Not the KV cache or prefix cache.** Those are about what a single request sends
  (`doc/compaction_cache_design.md`, #238); this is about what a whole run persists.
- **Not #286's task scheduler.** #548 is a prerequisite seam: agent tasks cannot persist
  their sessions until sessions know they are per-agent. It does not build the scheduler.
- **Not a change to identity-first construction (#276).** Identity is still resolved
  before anything is built from it; #548 extends "identity" to include the run-vs-agent
  distinction rather than collapsing it into one id.

## Open decisions / deferred

- **Layout A vs B** (the central fork above): separate run file, or one file with a
  `run:` + `agents:` block.
- **Is the run id the foreground agent's id, or a separate id?** Option B keeps them
  the same (cheaper); option A separates them (what the split implies).
- **Where the run -> agent map is stored and how it survives Job retention**
  (`tasks_kept`): a dropped job cannot be answered or read, so its session must not be
  orphaned by the map - decide whether a dropped job's session is deleted or retained.
- **Whether a sub-agent's harness session is auto-saved at all**, or only saved when a
  dependency needs it back (a read-only `agent.explore` may not need its transcript
  persisted; a write-capable sub-agent will).
- **How `/sessions`, `--resume`, `--continue`, and `--delete-session` read a layered
  store** - do they list runs, list agent sessions, or both; which one `--resume` targets.
- **Whether the run record and the agent sessions share a directory** (one
  `<run-id>/` dir holding `run.json` + nested agent dirs) or separate top-level dirs.
- **Backward compatibility**: existing one-file sessions from older builds - migrate them
  into the layered shape (`StateMigrator`), or read them as the degenerate one-agent case.
