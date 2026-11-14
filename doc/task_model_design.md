# Task model: the registry layer (issue #286 phase 0)

Design notes for the flat task list and the layer that owns it. Verified against
master `97e7d94` (2026-11-14). No production code exists for this layer yet -
this is the shape it must have before any runtime is built.

Cross-refs: #286 (this), #324, #146, #414, #181, #40, #238, #248, #300.
Buffer parts and keying rules live in `doc/output_buffer_design.md`; the single
turn loop in `doc/task_design.md`.

---

## Naming (owner decision, 2026-11-14)

`Task` is taken and load-bearing: `lib/task.rb` `Task` is the foreground
executor - the main-thread drain loop that owns ALL console I/O for one turn.
The graph node is a different thing from the executor, so the split is:

- **Job** - the node in the flat list. Has an id, a kind, a status, dependencies,
  its own buffer, its own inbox and outbox.
- **Task** - keeps the name. The executor that runs a Job in the foreground and
  renders to the console.

`Thread.current[:harness_task]`, `Task.current`, `TaskRunner` and the dialog
routing all resolve to the executor, so nothing has to be renamed. The registry
holds Jobs.

## The registry (owner, 2026-11-14)

The CLI (main thread) owns the Registry. It holds the flat list of Jobs and is
the single poller: it polls over ALL jobs, and when a job has pending events it
updates that job's buffer. It is the only code that touches console and stdin,
which is what makes dialog routing conflict-free even when several jobs run
concurrently.

Jobs run concurrently and emit events concurrently, so the poll loop is the only
place that turns an event into a record entry. A job thread never writes a stream
and never writes a buffer (the single-thread I/O rule, unchanged).

## One buffer per Job (owner, 2026-11-14)

Each Job has its OWN buffer. The registry does not share one store across jobs,
so the harness' role as the buffer's temporary home (issue #286 increment 6) ends
here: the registry owns the buffers.

Consequence for the head key: it stays `(origin, type)` INSIDE each buffer. The
job is not a field in `@head` - the job is supplied by WHICH buffer the cell
lives in. Measured (analysis/286/repro.rb): over one shared buffer, two jobs
writing the same `(origin, type)` stream collapse into ONE cell and their text is
concatenated; over per-job buffers the same two writes stay two cells. Per-job
buffers are what prevent the collapse, so the key does not gain a third field.

The registry's view of a live stream is `(job, origin, type)`, where `job`
selects the buffer and `(origin, type)` is the key inside it.

## Foreground (owner, 2026-11-14)

Exactly one buffer is ACTIVE at a time - the foreground job's. The foreground job
is REMEMBERED in the session, so a resumed run restores which buffer was active.

- Output emitted from the main thread (command reports, status lines) goes into
  the FOREGROUND buffer. That is the single writer rule from increment 6, now
  reading the foreground buffer rather than a run-level one.
- A foreground switch is a question of which job's head is shown, because each
  job already has its own head and tail.

## Input: the note and the prompt are the same thing (owner, 2026-11-14)

There is no separate steering-note mechanism. The initial prompt and a mid-turn
note are ONE input path, and the editor is reached the same way the poll loop
reaches it today: the loop peeks, and once the user starts typing the loop falls
into the edit state. The main thread runs this poll loop constantly, so the edit
state is a state of the poll loop, not a feature of the turn.

The rule that made the current single-slot hack work (latest line wins) only
holds because there is one foreground job. With several jobs, an input event is
routed to a job's inbox. A new steering input overrides a pending note-event ONLY
if that pending event is itself a note-event; if any non-note event arrived in
between, it does not override - it queues behind it. (Owner rule, preserved
exactly.)

Commands the model requires, in the initial design:

- list pending jobs;
- switch the foreground job at any point.

## Dialogs (owner, 2026-11-14)

A job that needs a dialog posts a request; the registry shows it, because only the
registry reads stdin. When the requester is a background job the dialog carries a
bit of context from that conversation, so the user knows what they are being asked
about.

Initial design: dialogs requested by a BACKGROUND job are denied - EXCEPT grant
dialogs, which cannot be denied, because denying them would prevent the job from
working at all. So the consent path stays live for background jobs; the other
dialog kinds are refused with an answer the job can act on.

## Dependency: the response goes back to the requester's inbox

When job A started job B to get a result back, that result is delivered to **job
A's inbox** when B completes. This is the same primitive for a sub-agent return, a
command handle, and a timer fire - a dependency edge is a precondition, not a
message-passing feature. A job's inbox is its own; nothing is shared.

## What the model does NOT collapse

These are orthogonal - the graph does not fix them:

- **FileList shared mutable state** (#300): a task graph LICENSES concurrent file
  reads and writes, which makes #300 mandatory. Today the harness dodges it by
  being sequential.
- **KV cache** (#238, one local slot): applies only to jobs with an LLM round. A
  command job pays nothing. Sub-agent batching (shared system-prompt + tool
  prefix, only the first re-reads) stays a #286-only mitigation, measured via
  RESP log lines tagged per job id (#248).
- **Consent / denylist** (#221, #389): applies to command jobs directly, to
  sub-agents only if they ever get `run.command`.

## Open decisions

1. **The commit point** (carried from increment 5, owner leans (b)): the stream's
   own final event, so a long turn can put a finished answer in the record while
   its spinner cell stays live. This is what gives `OutputBuffer#commit` its first
   production caller. Do not wire a consumer that assumes it.
2. **Which tails a save writes** once several jobs are retained: the foreground
   job's tail, the newest N entries across all retained jobs, or one saved block
   per job. `resume: replay_entries` is one window over one tail today. The
   foreground identity is already persisted; the record rule is not.
3. **Concurrency cap** for parallel command jobs: a fixed number or adaptive to
   CPU/RAM, and how it is measured. The graph permits concurrency; the cap is a
   scheduler knob on top of it.
4. **Is the main turn a job** (job #0 in the list) or a privileged foreground job.
   This decides whether the registry has a special case at all.
5. **Sub-agent consent posture**: inherit the main job's, or carry their own.
   Read-only sub-agents need none initially.

## Kinds

All four are JOB KINDS on one list, not four features: main-turn (foreground),
sub-agent (#286), command (#414), timed/delayed (#181). A timed job's dependency
is a clock predicate, not another job, so dependencies must accept non-job
preconditions: completion-of-a-job, a timer, or user input. A plain job-to-job
DAG is not enough.

## Phasing (bottom-up - no runtime before a feature)

- **Phase 0** (this doc + `analysis/286/`): harden the manager pattern with the
  cheapest job kind first - a background command (#414, no LLM round, no cache,
  no own session) - to settle outbox polling, dialog detection, inbox routing,
  foreground marking and the cap with the easiest probe. Then re-test with a
  trivial one-tool sub-agent and MEASURE the cache cost.
- **Phase 1** (`agent.explore`, #286): read-only sub-agent kind. Own session,
  restricted read-only registry, bounded iterations, returns SHORT FINDINGS rather
  than file contents.
- **Phase 2** (#414): command jobs, real parallel execution under the cap,
  handle/poll API, consent dialog through the registry before start.
- **Phase 3** (#181): timed kind plus clock preconditions.
- **Deferred**: write-capable sub-agents; sub-agents with a different system
  prompt.
