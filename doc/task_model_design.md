# Task model: the registry layer (issue #286 phase 0)

Design notes for the flat task list and the layer that owns it. Verified against
master `bf9938e` (2026-11-14). No production code exists for this layer yet -
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

## The registry

A new class (NOT the CLI, in the MAIN thread) that owns the flat list. It is the
only code that touches console and stdin, which is what makes dialog routing
conflict-free: every Job posts a request, the registry shows the dialog, and it
routes the answer to that Job's own inbox - never a shared one.

The registry is the single poller of every Job's outbox. Today's drain loop polls
one outbox; the registry generalises that to N outboxes while keeping the
single-thread I/O rule (a Job thread never writes to a stream).

## One buffer per retained Job (owner decision, 2026-11-14)

Increment 6 collapsed the run to ONE buffer because only one task was ever live.
Once the registry retains several Jobs at once, each retained Job has its own
buffer, and the registry owns them - the harness' role as temporary home ends
here.

Consequences:

- The head key gains the task part. It is not a field inside `@head` today; the
  registry supplies it. A head cell's full identity becomes `(job, origin, type)`.
  Measured (analysis/286/repro.rb): two Jobs writing the same `(origin, type)`
  stream currently merge into ONE cell and their text is concatenated - which is
  exactly the failure the third key part prevents.
- `output: tasks_kept` gets its first real enforcement point. It is read by
  `HarnessConfig#output_tasks_kept` today and enforced nowhere; the registry is
  the layer that decides how many finished Jobs it keeps and drops the rest.
- The saved record is no longer one tail. A rule is needed for which tails a save
  writes (open decision, below).

## Open decisions

1. **The commit point** (carried from increment 5, owner leans (b)): the stream's
   own final event, so a long turn can put a finished answer in the record while
   its spinner cell stays live. This is what gives `OutputBuffer#commit` its first
   production caller. Do not wire a consumer that assumes it.
2. **Which tails a save writes** once several Jobs are retained: the foreground
   Job's tail, the newest N entries across all retained Jobs, or one saved block
   per Job. `resume: replay_entries` is one window over one tail today; per-Job
   buffers mean the window has to say which Job it is a window of.
3. **Concurrency cap** for parallel command Jobs: a fixed number or adaptive to
   CPU/RAM, and how it is measured. The graph permits concurrency; the cap is a
   scheduler knob on top of it.
4. **Is the main turn a Job** (task #0 in the list) or a privileged foreground
   Job. This decides whether the registry has a special case at all.
5. **Sub-agent dialogs**: inherit the main Job's consent posture, or carry their
   own. Read-only sub-agents need none initially.

## What the model does NOT collapse

These are orthogonal - the graph does not fix them:

- **FileList shared mutable state** (#300): a task graph LICENSES concurrent file
  reads and writes, which makes #300 mandatory. Today the harness dodges it by
  being sequential.
- **KV cache** (#238, one local slot): applies only to Jobs with an LLM round. A
  command Job pays nothing. Sub-agent batching (shared system-prompt + tool
  prefix, only the first re-reads) stays a #286-only mitigation, measured via
  RESP log lines tagged per Job id (#248).
- **Consent / denylist** (#221, #389): applies to command Jobs directly, to
  sub-agents only if they ever get `run.command`.

## Steering-note override (owner rule, preserved exactly)

Today a note is one slot on Harness (`user_note_text=`, latest line wins), polled
from the main thread and injected at the top of the next `call_llm`. It works only
because there is one foreground Job. In the unified model a note is an event in
the Job's inbox queue. The rule:

> a new steering note OVERRIDES the pending note-event only if that pending event
> is itself a steering note. If any non-note event arrived in between, it does NOT
> override - it queues behind it.

This is the generalisation the current single-slot hack cannot express once
several Jobs exist.

## Kinds

All three are JOB KINDS on one list, not three features: main-turn (foreground),
sub-agent (#286), command (#414), timed/delayed (#181). A timed Job's dependency
is a clock predicate, not another Job, so dependencies must accept non-task
preconditions: completion-of-a-Job, a timer, or user input. A plain Job-to-Job
DAG is not enough.

## Phasing (bottom-up - no runtime before a feature)

- **Phase 0** (this doc + `analysis/286/`): harden the manager pattern with the
  cheapest Job kind first - a background command (#414, no LLM round, no cache,
  no own session) - to settle outbox polling, dialog detection, inbox routing,
  foreground marking and the cap with the easiest probe. Then re-test with a
  trivial one-tool sub-agent and MEASURE the cache cost.
- **Phase 1** (`agent.explore`, #286): read-only sub-agent kind. Own session,
  restricted read-only registry, bounded iterations, returns SHORT FINDINGS rather
  than file contents.
- **Phase 2** (#414): command Jobs, real parallel execution under the cap,
  handle/poll API, consent dialog through the registry before start.
- **Phase 3** (#181): timed kind plus clock preconditions.
- **Deferred**: write-capable sub-agents; sub-agents with a different system
  prompt.

## Foreground

Exactly one Job is foreground - it owns the live spinner and the turn. `/task`
lists every Job and marks the foreground one. A foreground switch is then a
question of which Job's head is the shown one, because each retained Job already
has its own head and tail.
