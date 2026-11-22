# Session persistence layers: harness-session vs run (system) session (issue #548)

Design notes for splitting session persistence along the ownership seam #286 has
already established. This is a DESIGN document only; no code is written for #548
yet. It states the conflation, the evidence in today's code, the proposed two-layer
shape, the file layout the owner has chosen (dir per job), the log decision that
layout forces, the increments, and the decisions still open. Issue #548 stays OPEN
until the layout is implemented.

Cross-refs: #548 (this), #286 (agent tasks / the Job model), #458 (the system record),
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
- the **system / world** - the `JobRegistry` record (the job list, which job was
  foreground, the replay tail), the system-wide postures (`yolo`/`stream`/`markdown`/
  `output_palette`), and `mcp_connected`.

`doc/harness_job_design.md` already states that a Harness is three things welded
together (the per-LLM turn engine, the conversation, and system/world state) and that
the system/world half is being moved out increment by increment - postures went to
`SystemSettings`, the system record went to `JobRegistry`, the FS-backed stores went
to the tools/commands. **The persistence layer never got that split.** `save_session`
is a method on `SessionManager`, which is built by and owned by ONE Harness, yet
it serializes system-wide keys. The ownership doc names the smell directly in the
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
So the **system's directory name** and the **foreground agent's conversation id** are the
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

The system-level decision ("does this run deserve a saved session?") is made by reading
only the *foreground agent's* emptiness. `state_changed` (a `@history.has_pending_entries?`
heuristic, added by #188) is a bolt-on: it exists because a run that changed settings
(`/model`) or ran a background job but sent no foreground prompt still has state worth
saving, and the foreground conversation alone cannot see that.

## The seam: two sessions, two owners

Split persistence along the ownership line `doc/harness_job_design.md` already draws -
a Harness is ONE LLM tool-loop and belongs to a Job; the CLI/`JobRegistry` is the
"System / world" half, exactly one per process:

- **Harness session** - one per agent/Job. Holds: the `Session` message chain, the
  file digest cache, the access grants, and that agent's own `active_model` /
  `param_overrides`. Owned by that agent's Harness / `SessionManager` (its persistence
  half). Saved under the agent's own session id.
- **System session** - exactly one per process. Holds: the `JobRegistry` record
  (job list, the foreground id, the replay tail), the system-wide postures, `mcp_connected`,
  and a **system -> agent-session-id map** (the piece that does not exist today). Owned by
  CLI / `JobRegistry`.

The distinction is not new vocabulary invented for this issue - it is exactly the
`doc/harness_job_design.md` split of "conversation" from "system / world", applied to the
one subsystem that never received it.

With the seam in place, save is **system-driven, not foreground-driven**: the CLI owns the
system session and, at exit, enumerates the retained Jobs and lets each Job's Harness
persist its own harness session; resume reads the system record first (identity, job list,
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
| `yolo`, `stream`, `markdown`, `output_palette` | system | `SessionManager` (per-Harness) | system session |
| `foreground_job`, `replay_tail` | system | `SessionManager` via injected `registry` | system session (the registry's own data) |
| `mcp_connected` | system | `SessionManager` | system session |

The `yolo`/`stream`/`markdown`/`palette` keys already carry comments calling them
"harness posture, not conversation state" and "harness consent state, not conversation
state" - they are system-level choices the harness happens to read, not part of any one
agent's message chain. They belong to the system session. The `registry` injection exists
only because a per-Harness object was asked to reach the system record; moving the record
to its owner deletes the injection.

## File-layout options (fork resolved: A, as dir per job)

Two shapes were on the table; the owner picked **A**, sharpened into **one directory per
job** (see "The layout decision" below). Recording both because the cost difference is
what the increments are ordered around.

**A. Separate system file plus per-agent files.** `.harness/sessions/<system-id>/system.json`
plus an agent session per job. `system.json` carries the system record and the id list.
- Pros: each layer is a standalone file the locator can read without decoding the
  other; a sub-agent's session becomes a real saved object; the system id and the
  foreground agent id stop being the same number; and a job can own FILES, not just
  keys in a JSON blob - which is what per-job artifacts and per-job cleanup need.
- Cons: identity resolution must now resolve a *run* id and then follow it to agent
  ids; `/sessions` and `--resume` change what they list and what they read.

**B. One file with two blocks.** a single `session.json` holding a `system:` block and an
`agents:` block (the foreground agent's chain living where `messages` is today).
- Pros: keeps today's one-file-per-session directory and the `#207`/`#276` identity
  machinery almost unchanged; resume reads one file.
- Cons: the system record and the conversation still share a file and the system id stays
  coupled to the foreground id; a sub-agent's chain must go in a nested `agents:`
  section rather than its own dir. **Disqualified by dir-per-job**: a single file cannot
  hold "and other files per case", so B cannot express per-job retention at all.

Increment 1 below still writes both halves into the current one file while the seam is
proven, but that is a transitional step with no `agents:` block and no nested keys - not
option B as a destination.

## Increments (a suggested sequence)

1. **Partition `save_session`.** Split it into a harness-session writer (the
   `Session#to_h` keys + `active_model` + `param_overrides`) and a run-record writer
   owned by CLI/`JobRegistry` (jobs/foreground/replay_tail/postures/mcp_connected).
   Delete `SessionManager#registry` and its injection. No layout change yet - the two
   writers can still emit into the existing file while the seam is proven.
2. **Apply the chosen layout** (system.json + `jobs/<id>/`). This is where the system -> agent
   map first appears and where `@next_id` becomes persisted.
3. **`SessionLocator` learns the system record.** It becomes the reader of the system file and
   the resolver that follows a system id to the agent ids it names, so list/resume/delete
   understand both layers.
4. **Save/resume enumerate the retained Jobs.** `CLI#auto_save_session` walks
   `@registry.jobs` and asks each Job's Harness to persist its harness session; resume
   reads the system record, restores postures/foreground, then restores each agent session.
   Sub-agent sessions become saved objects.
5. **Replace `state_changed`.** Exit decides on "any retained job has session state?"
   rather than the history-entry heuristic.

`doc/harness_job_design.md` already defers "the SessionManager split (per-LLM loop vs
persistence/profile catalogue)" to a later increment; #548 is that deferral scheduled.

## What this is NOT

- **Not a rename of `Session`.** The `Session` class stays the conversation chain. The
  new thing is a system-level record and a map to agent sessions, plus moving the system-level
  keys out of a per-Harness writer.
- **Not the KV cache or prefix cache.** Those are about what a single request sends
  (`doc/compaction_cache_design.md`, #238); this is about what a whole run persists.
- **Not #286's task scheduler.** #548 is a prerequisite seam: agent tasks cannot persist
  their sessions until sessions know they are per-agent. It does not build the scheduler.
- **Not a change to identity-first construction (#276).** Identity is still resolved
  before anything is built from it; #548 extends "identity" to include the run-vs-agent
  distinction rather than collapsing it into one id.

## The layout decision: one system file, one directory per job

`system.json` for system state plus a directory holding everything one job owns. The
per-job part is what makes retention work: a job's artifacts are FILES under its own
directory (a sub-agent transcript, a dump, a scratch note), which is exactly what a
single `session.json` cannot express.

```
.harness/
  harness_history              # legacy read-only fallback
  memories/ plans/ skills/     # system-wide ON PURPOSE - never touched by job GC
  sessions/<session-id>/       # SecureRandom.uuid == the run/system id (#276)
    system.json                   # version, session_id, created_at, workdir, postures,
                               # mcp_connected, access + file_cache (system-wide TODAY),
                               # next_id, foreground_job,
                               # jobs: [{id, kind, status, requested_by,
                               #         dependencies, dir}]
    harness.log                # ONE Logger object for the run; delimiter format;
                               # every event stamped with the JOB id, not the thread id
    harness_history            # Reline input only (#119), escaped one-per-line
    jobs/<id>/                 # job.json   (kind, status, result, edges AS IDS)
                               # session.json (that agent's chain; message 0 implicit
                               #              exactly as Session#to_h does today)
                               # replay.json
                               # + any future per-job artifact
```

`memories/`, `plans/` and `skills/` stay outside the session id **on purpose**
(`doc/memory_design.md`: "Not session state"; the owner's note that plans are not bound
to a session). Only the *active-plan pointer* is session state. Per-job GC must never
reach those directories.

### Who writes `system.json` - exactly one writer

**`system.json` has exactly one writer: `SystemSaver#save_run` (or its standalone
twin `save_standalone`), never a job's `SessionManager`.** `system.json` carries the
**system's** `access` list and `file_cache` digest cache, and every job Harness builds
its **own** `SessionFileCache` (`lib/harness.rb`). A per-job writer would rewrite those
system-wide keys with its own job's grants and digests on every auto-save (pre-send,
post-turn, after in-loop compaction) - so `SessionManager#save_session` writes only its
own `jobs/<id>/session.json`. The single system write happens once, by the run owner:
`SystemSaver#save_run` walks every retained job (writing each job's own conversation)
and writes the system record over the registry it holds; the CLI (`auto_save_session`,
`/save`) is its only caller. `save_standalone` is the one-job, registry-less form for a
harness with no run - it writes the same two files and, because it has no registry,
records default postures (the same shape as a session saved before a key existed).

**Which jobs a save writes: every job with an agent, whatever its status.** A status
is a registry fact, not a statement about the chain: a job that ran a turn and was
never `:done` is still `:pending`, so gating the write on `finished?` left every
background chain unwritten - the index and `job.json` named the job, its
`session.json` did not exist, and the resume had nothing to rebuild it from. Only the
foreground job's chain survived. Forcing such a job to `:finished` so it would save
is the other wrong fix: `Job#finish` **delivers its result to a live requester**, so a
restored job marked finished would answer a requester this run never made. The
threading rule stays as it was - a main thread may not read a RUNNING job's messages -
and a save point has no running thread: the exit save runs after every job thread is
joined, and a mid-run save of a running job goes through `Job#request_save` so that
job writes its own file on its own thread.

The system half is still described through the **foreground** job, because that job
carries the run's own `FileList`: its `to_h` is where `access`, the digest cache and
the workdir come from. A foreground id that names no retained job has no system half
to write.

### How a run gets its main harness: the factory, from the first job on

`CLI#setup` no longer builds `Harness.new` and hand-attaches it to a pre-made
job. It calls `HarnessFactory#add_harness_job(kind: :main, ...)` - the factory's
first production caller - so the main turn is created the SAME way a second agent
will be (job added, agent built and attached, `session_manager.job_id` wired in
one step). A run starts with no jobs, so the main add takes id 0.

One deliberate exception: the **initial (main) job reuses the run's own
`FileList`** (`add_harness_job(..., base_file_list: @file_list)`). The main turn's
access grants and digest cache are system-wide state today - the CLI and every
command hold `@file_list` - so the main harness must keep that object. A *second*
agent gets a fresh per-job `FileList` rooted at the run workdir (the isolation the
factory exists for). Making the main turn itself per-job is deferred with Blocker A
(job->id) and the grant-prompt routing it would need.

### How a resumed run restores jobs: the system owner's steps, no foreground fold

Resume is the **system's** work, done in the owner's order - not one flat hash with
a foreground special case merged into it. `SessionLocator#assemble_system` returns
the **system half only** (`system.json` as-is: identity, postures, access,
`file_cache`, `next_id`, the job index) and deliberately carries **no** job
conversation. Then:

1. **Continue numbering.** The registry is seeded `JobRegistry.new(next_id: <saved
   next_id>)`, and `add_job(id:)` accepts an explicit id so a saved job is rebuilt
   at its **saved** id (its live id matches the `jobs/<id>/` dir its files live
   under). next_id stays past every id in use, so a new job never reuses one on
   disk (#548 A).
2. **Rebuild EVERY saved job, not just the foreground one.** `job_restores` yields
   each job's own half (`session:`, the whole `jobs/<id>/session.json`, plus kind,
   status and its `replay.json` tail) and the CLI builds one agent per job through
   the factory with that saved `id:`. A job's half must therefore be **self-
   sufficient**: `version` and `created_at` are in it, because only the foreground
   job's half used to be supplemented from `system.json` at resume and a non-main
   job restored straight from its own file raised `Time.parse(nil)`. A pre-fix
   session file that has no `created_at` resumes anyway - `Session#restore` falls
   back to now, since the cost is one cosmetic `/session` line and not a crash.
   `SystemSaver#resume_main` (the foreground fold) is gone: the system half is no
   longer merged into any job.
3. **Then set the foreground.** `@registry.foreground = <saved fg>` (a plain
   assignment; the old `restore_foreground` special case is gone) and the foreground
   job's own `replay.json` redraws the shown tail. Assigning it LAST is what lets
   step 2 rebuild every job: nothing is foreground while the system is being rebuilt.

Step 2 also **seeds every job's buffer with its own `replay.json`**, not just the
foreground one. The rule that makes this necessary: a save writes what a job's
**buffer** holds, so a restored job whose tail was never read back has an empty
buffer and writes an empty `replay.json` on this run's next save - which is how a
job ended up with a full conversation and `nothing recorded`. Only the foreground
job's tail is *redrawn* in the startup banner (the one exchange the user last saw);
every job's tail has to be **live**.

A saved job whose `session.json` is gone (the drop rule removed it) is not rebuilt
at all and is reported by `dropped_job_ids` - stated, not silently stubbed. A #207
flat session has no `jobs/` tree, so it is rebuilt as the degenerate one-job case
from its own inline conversation.

### MCP when a run has several jobs: one manager per run, shared (DECIDED)

**A run owns exactly one `Mcp::Manager` and one `ToolRegistry`; every job
Harness shares them.** MCP is run/world state, not per-Harness state, and this
decision follows three facts already in the design rather than inventing a new
rule:

1. `doc/harness_job_design.md` already lists `mcp` and `tool_registry` under
   target #3, "Run / world (exactly one per process)" - the machinery is meant
   to leave the per-Harness turn engine; only the code has not moved it yet.
   The `mcp_connected` key is already a **system** key in the layer map above.
2. `settings` is the shared run-wide `SystemSettings` handed to every Harness
   (the CLI's only run-config holder), so `settings.mcp_servers` is identical
   across jobs. Nothing job-specific decides **which** servers to reach.
3. `doc/mcp_design.md` states the tool set is **fixed for the run** and MCP
   tools enter `tools_payload`, which #246 requires to be **identical on every
   request**. Reconnecting per job would mint per-job tool sets that then have
   to be reconciled back into one payload; sharing one set is the invariant,
   not merely the cheaper option. The single-`Logger`-per-path rule (above) is
   the same shape: run-wide machinery is built once by the run owner.

The cost today is latent, not paid: every `Harness.new` runs
`ToolRegistryBuilder#build`, which does `Mcp::Manager.new(logger)` then
`@mcp.load(registry, settings.mcp_servers)` -> `connect_server` ->
`ServerConnection` **spawns a subprocess (or opens an HTTP endpoint) per
declared server**. Because today's run has exactly one Harness (job 0), each
server connects once. The moment `/jobs add` builds a second Harness, every
server is re-spawned, and only `foreground_harness.close_mcp` runs at exit
(`CLI#run`), so a second job's spawned subprocesses **leak** - the leak is a
correctness bug, not only a cost.

**Sharing is conditional on thread safety, and the transport decides it.** A shared
`Mcp::Manager` is safe to *build* once and *close* once, but concurrent `tools/call`
from several job threads on the **same live connection** is a different question - and
the answer is measured in the `mcp` gem (1.10.0 on this box), not inferable from our
`ServerConnection`, which just forwards to `@client.call_tool`:

- **stdio is NOT multiplexed.** `MCP::Client::Stdio#send_request` writes under a
  per-connection `@write_mutex`, then `read_response` reads the single shared stdout
  pipe and **skips every line whose id != its own** `request_id` (ids are per-client
  `SecureRandom.uuid`). If two job threads call one shared stdio client at once, one
  read loop can consume the other's response line (id mismatch, discarded) and then
  both stall. One stdio connection is safe for **one caller at a time**; today that
  holds only because there is exactly one Harness. Sharing it across concurrently
  running jobs therefore needs the call serialized on that connection (or more
  connections) - the pool below is what provides exactly that.
- **HTTP is effectively per-request.** `MCP::Client::HTTP#send_request` issues its own
  `post` with its own `SSEStream` and matches the response by `request_id`, so two
  threads sharing one HTTP client do not cross responses. The only shared mutable is
  `@session_id`/`@protocol_version`, learned once on connect (`capture_session_info`);
  a benign first-time write race, not a per-call one.

The chosen mechanism is a **per-server connection pool**, not a global one and not
a per-Harness one. It is the shape that satisfies the thread-safety rule above for
*every* transport uniformly, so the run does not have to branch on stdio vs HTTP at
the call site.

#### Per-server MCP connection pool (DECIDED; first version implemented)

Each MCP server gets its own pool. `Mcp::Manager` already holds exactly one
`ServerConnection` per connected server, and every `ToolAdapter` for that server
borrows from that server's pool. `Mcp::Manager` now keys a `ConnectionPool` by
server name (`@pools`), so a pool is per server exactly the way the Manager already
keys a connection - `ToolAdapter#execute` -> `pool.checkout { |c| c.call_tool(...) }`.

- **Pool unit = a server's connection. Pool per server, never global.** Two job
  Harnesses calling *different* servers draw from *different* pools and never block
  each other. Contention exists only when two jobs call the *same* server at the same
  time - which is exactly the stdio hazard, and exactly what a size-1 pool forbids.
- **Pool size 1 today, expandable later.** With size 1 the pool is a per-server
  mutex: a tool call takes the connection, runs `tools/call`, and returns it; a
  second call to the same server blocks until the first returns. Growing the size
  later turns the single lock into N connections to that server (each its own
  stdio pipe / HTTP client) so N concurrent calls to one server proceed in parallel -
  the growth knob a heavy stdio server would eventually want. The pool must therefore
  be written as *take-or-block, return-on-release*, sized by a per-server capacity,
  not as an ad-hoc lock, so raising the capacity is a configuration change and not a
  redesign.
- **Call path.** `ToolAdapter#execute` stops holding the raw `ServerConnection` and
  instead borrows one from the server's pool for the duration of the call: take a
  connection (block if none free), `call_tool`, then always return it (an `ensure`),
  so a raising tool cannot strand a pooled connection.
- **Blocking scope is real concurrency only.** A sequential foreground job never
  contends with itself; the pool only ever blocks a call when a second job is
  *actually running* and targets the same server. So the pool costs nothing in today's
  one-job runs and is the guard the moment a second job exists.
- **Close is still once, by the run owner.** The pool owns the connections it handed
  out, so `Mcp::Manager#close` closes the pool's connections (all sizes), and the CLI
  still calls it once at exit - the leak rule is unchanged, just routed through the pool.

Sharing the *machinery* (one `Mcp::Manager` + one `ToolRegistry` per run, close once)
stands; the pool is what makes sharing a live server safe across concurrent jobs. A
run whose servers are all HTTP could in principle share one connection with no
contention, but the pool gives one uniform rule instead of a transport-conditional
exception, and a size-1 pool on an HTTP server is harmless (it just serializes calls,
which a single foreground already does).

Consequences the decision commits to:

- **Sub-agents inherit the run's MCP tools** (the same `tools_payload`); they
  do not get their own server set. The per-job `FileList` isolation the factory
  provides does **not** extend to MCP/ToolRegistry.
- **Per-server pool, size 1 now (expandable), take-or-block + always-return.** A
  call borrows the server's connection and gives it back; a concurrent call to the
  same server waits, a call to a different server does not. See the subsection above.
- **Close once**, by the run owner through the pool (`Mcp::Manager#close` closes the
  pool's connections), not per-Harness. The single `Mcp::Manager` is owned by the
  object that builds the run's Harnesses.
- **`mcp_connected` stays a system key**: one `connected_summary` for the run,
  not one per job, matching the layer map above.

**First version implemented** (in `Mcp::Manager` / `Mcp::ConnectionPool` /
`Mcp::ToolAdapter`): each connected server gets a size-1 `ConnectionPool` in
`Manager`'s `@pools`; `ToolAdapter#execute` borrows through `pool.checkout` (always
returned); `Manager#close` closes every pool's connections. For today's single-Harness
run this is behavior-preserving (one caller, so a size-1 pool never blocks).

**Still deferred** (lands with the main polling loop, when a second job Harness
exists): build the `ToolRegistry` + `Mcp::Manager` ONCE in the run owner/factory and
hand them into `Harness.new` as collaborators instead of every Harness assembling its
own builder - that is what stops the re-spawn/leak, and it is also the point where a
pool is shared across real concurrent jobs. Growing a server's pool size > 1 (N
connections to one server) is a later capacity knob, not a redesign: `ConnectionPool`
already takes the connection list and pops/returns with a `Thread::Queue`.

### Why a directory, not a set of flat per-job files

Cleanup stays O(1) in the **number of file types** rather than O(job x file kind):
dropping a job is one recursive delete. Retention never needs an inventory of what that
job owned, and adding a new per-job artifact needs **no retention change at all**. Flat
per-job files turn `tasks_kept` into a growing list of "which files belong to job 3".
Precedent for the directory as the cleanup unit: `doc/sensitive_paths_design.md`
scratch/keep zone.

### The drop rule

`Job#finish` hands the job to the registry's retention decision. `retain` plus
`tasks_kept` drop **finished** jobs only - never a running job, never the foreground
job - and a drop is two actions in one step:

1. remove the job's entry from `system.json`'s `jobs:` list,
2. `FileUtils.rm_rf` the job's directory.

Unlink **before** deleting, so a crash between the two leaves an orphan directory
(recoverable by a startup sweep that deletes any `jobs/<id>/` with no `system.json` entry)
rather than a dangling id (unrecoverable, because code dereferences an id whose directory is
gone). `@next_id` is persisted in `system.json` and, for legacy files without it, falls back
to `max(existing job id)`; both, so an id is never reused. Job ids do not need to be
globally unique because containment namespaces them: "job 3" always means
`<session-id>/job-3`.

### One source per job fact: index vs job.json (issue #548 E)

A job is described in two files - the `system.json` `jobs[]` **index** and the job's
own `jobs/<id>/job.json`. When both carried the same keys, they were a second source
of one fact and could drift. The split (DECIDED):

- **Index = enumeration + size metadata** (`id`, `kind`, `status`, `dir`,
  `messages`): which jobs the system owns and how big each conversation is - the
  fields `/sessions` and `sessions.search` read **without opening a job file**.
- **`job.json` = the per-job detail** (`result`, `requested_by`, `dependencies`):
  how the job ended and its edges as ids. `result`/`requested_by`/`dependencies`
  live ONLY here - the index no longer writes them, so they have one source.

`kind`/`status` appear in **both** deliberately: the index needs them to list a job
without opening its record, and `job.json` must stay readable on its own (a resume
reads a job dir without the index). They are written from the **same live Job** in
one pass (`SystemRecord#write_system_files` yields each job once and reads the index
entry and the job record off it), so they cannot drift. `result`/edges are not
duplicated because nothing in `lib/` reads them from the index - the only consumer
of edges (`read_job_record`, and the resume increment) reads `job.json`.

This also fixed a latent write bug: the job record was previously *derived from the
index entry* (`entry.reject(...)`), so making the index metadata-only would have
silently dropped the per-job detail from `job.json`. The record is now built from the
live job, independent of the index.

### Saving a running job: async, on the job's own thread (issue #548 F)

**A main thread must never read a running job's messages.** They are being mutated on
the job's task thread; cross-thread reading is unsafe unless a lock/sync layer is
added, and neither is wanted. So a job persists **itself**, on **its own thread**, and
saving separate jobs need not be synchronous. The bug F names is purely on the main
thread: `SystemSaver#save_run` walked every job and read its chain from the main
thread, and had to *refuse* anything unfinished
(`next if !job.equal?(fg) && !job.finished?`) because reading a running job is exactly
the unsafe thing.

The primitive already exists. `SessionManager#maybe_auto_save` saves a job's **own**
conversation on the **job's own thread** at its safe points (pre-send, in-loop
compaction, post-turn), gated by `settings.auto_save` + a min-interval; `save_job_session`
writes only that job's `jobs/<id>/session.json`. That *is* "the task does saving when it
has a chance." The DECIDE-to-save side already agrees: `JobRegistry#any_job_has_session_state?`
counts a job with a harness and a non-empty chain regardless of `finished?`. Only the WRITE
side (the main thread reading) refused - and that refusal was really the correct thread rule
expressed as a save bug.

The model (DECIDED):

- **`save_run` (main thread) reads NO running job.** It writes only what the system
  owns and can read safely: `system.json` + each job's `job.json` + `replay.json` (all
  from the live registry, no message reads), plus the **foreground** job's `session.json`
  when it is quiescent (at exit the foreground turn has finished/joined). A running
  non-foreground job's chain is **not** read by `save_run`.
- **Periodic:** a running job keeps saving itself through its own auto-save points, so a
  crash/interrupt already loses at most one safe-point interval.
- **On-demand:** a save request lets `/save` and exit ask a running job to persist **now**.
  The main thread posts a save request to the job; the job's own loop consumes it at its
  next safe point (the same tool-loop iteration boundary where a mid-turn note is injected
  and where `maybe_auto_save` fires) and calls `save_job_session` on its own thread. The
  request travels like a mid-turn note (a flag read at the iteration top), not through the
  answer/inbox FIFO - so it never collides with the request/answer ordering rules.

**Honest limit:** a job force-killed mid-tool-call can miss one on-demand request (it
never reached the consume point); its last periodic auto-save is still on disk. The main
thread never reads the chain to fill that gap - that refusal is the thread-safety rule, not
a bug. This model is latent in today's single-job run (the only job is the foreground, which
is quiescent at exit) and is the shape the main polling loop needs once a job runs
concurrently.

This also fixed a latent write bug: the job record was previously *derived from the
index entry* (`entry.reject(...)`), so making the index metadata-only would have
silently dropped the per-job detail from `job.json`. The record is now built from the
live job, independent of the index.

### Adding an agent to a run: `/jobs add` (issue #548 G)

The seam this whole layout exists for: a SECOND agent joins the run through the
SAME call the first agent used. `HarnessFactory#add_harness_job` is the only
builder of a job's Harness, so `/jobs add` cannot invent a second path - it passes
along the run owner's factory and the SYSTEM id (the id a job's directory is named
under), which is why `CommandHandler` and `Command` now carry both, the way they
already carry the registry and the saver.

The command's part is ownership, not construction:

- the **factory** builds the job and its agent (`kind: :sub_agent`, `requested_by`
  = the job that was foreground), with a FileList of its own over the run workdir;
- the **registry** marks it foreground, which is what makes it drivable - the idle
  prompt dispatch sends the next prompt to `registry.foreground_job`;
- a prompt typed with the form (`/jobs add <text>`, or `/jobs add sub_agent <text>`)
  is recorded into the new job's buffer, the way a normal prompt line is recorded.

`mid_turn_safe?` is false for `/jobs`: a mid-turn submit would have to hand that
first prompt to the new agent on the MAIN thread, which is the nested-drain-loop
refusal every LLM-driving command already gets (doc/unified_loop_design.md). The
agent waits for the run to be idle.

**Honest limit (what G is NOT yet):** there is no poll loop that drives a
non-foreground job, so an added agent runs only while it IS the foreground one - a
background agent has no scheduler pulling its inbox. G ships the ownership seam and
the plumbing; a concurrent drain loop over several jobs is the next step, and the
same seam is what it will use.

### Which job a run is talking to: the job tag on every wait line

A run that has several jobs cannot be read from the spinner alone: two jobs can be
waiting at the same moment and the console says only "Sending (model)". The tag is
`Poller.job_tag(job)` -> `[job <id> <kind>]`, and it is on **every** line that names
a job - the spinner badge (`Poller.turn_badge`) and the modeline
(`PromptReader#job_tag`, the same builder) - so a prompt line reads
`[model] [MANUAL] [job 0 main] > `.

**The main turn is tagged too.** Leaving job 0 untagged while tagging the others reads
as "no job is active" rather than "job 0 is active", and the whole point of the tag is
that a run with one job and a run with four look like the same kind of thing. The badge
is therefore never nil for a run with a job.

### `/replay`: the same record a resume redraws, shown without leaving the run

`/replay [n] [job <id>|all]` prints the tail of what the run RECORDED - the entries
`print_resume_replay` redraws at startup - so a user can see the record of the job they
are in, or of every job, without restarting. It reads through the registry
(`replay_tail_for_job`), never a saved file: what it shows is what the next resume would
show for that job.

The rendering is the startup replay's shape on purpose - one `UI::Renderer#line` per
entry between two `RULE_WIDTH` rules, with the same roles and palette, and a header that
names which job it is (`Replay [job 0 main] FOREGROUND (main, pending): 3 of 3 recorded
lines`). A flattened table of entries would be a listing, not a replay: the value is
that the line a user saw is the line they get back. `n` picks how many lines of the tail
to show and is the first bare number before a selector word (`all 20` = 20 lines,
`job 1` = job 1); the record itself stays capped by the saved window (`max_saved`).

**Whose record a job carries** (the rule `/replay` depends on): a tail lands in the
buffer of the job that **owns** it, and only there.

- `record_user_prompt`/`record_report_output` take `job:` and write that job's own
  buffer; `/jobs add` records the prompt it was given **before** making the new job
  foreground, because the foreground at the moment of the write is what decides the
  buffer - recording after the switch writes the new job's line into the **old**
  job's record and leaves the new job with an empty one.
- A resume seeds each restored job from **its own** `replay.json`; a job the user
  later switches to already holds its record, so `/jobs switch` reads no file and
  copies nothing. Moving the foreground job's tail into the job switched to would
  relocate one job's history and then save it under the other id.
- Seeding is guarded to a buffer that has recorded nothing yet, so the resume seed
  and any later seed of the same id cannot double a record.

So `nothing recorded` from `/replay` now means the run genuinely recorded nothing for
that job, rather than that its record went missing on the way to disk.

## The log decision the layout forces: one system-wide `harness.log`

Dir-per-job does **not** imply one log per job. The registry has one queue, which gives a
**total order across jobs**; splitting the log discards that order, which is the thing a
troubleshooting reader needs. The log is for finding the right line, and tolerating a
large log is a requirement - it is read per line, never parsed as a whole file (the 8.5 MB
sample is not even valid UTF-8). So: **one file for the run, one `Logger` object, every
event stamped with its job's id.** Format and size are separate problems; delimiters make
the log *attributable*, not small.

Measured on this box (ruby 4.0.7 x64-mingw-ucrt, `logger.rb` v1.7.0) by
`analysis/548/log_format_measure.rb`, which runs from a fresh clone and writes only into
its own directory. Four results constrain the implementation:

- **One `Logger` object per session is a hard requirement, and today's code can mint a
  second one.** Two `Logger` objects opened on the same path share `Logger`'s
  class-level `@log_mutex` (so lines never interleave) yet **lose writes**: 400 concurrent
  writes leave 365-391 lines across eight runs (~10% gone), because each object keeps its
  own file position. One object hammered from two threads leaves 400 lines in every run.
  `Harness#initialize` currently does `@logger = logger || SessionLogger.build(...)`
  (`lib/harness.rb:143`), so a Harness built with an injected session id and no injected
  logger opens its own writer on the same path - which is exactly what a per-job
  sub-agent Harness will do. Enforce one writer per session in the same increment that
  gives sub-agents persistence.
- **Stamp the job id, not the thread id.** One job is serviced by its task thread, by the
  Poller on the main thread, and by nested threads; a thread-id stamp splits a single
  job's output across stamps and defeats "show me job 3's lines". The main thread stamps
  the foreground job (id 0).
- **Whatever channel carries the stamp must be propagated explicitly at every
  `Thread.new`.** `Logger#formatter` runs on the calling thread, so it *can* read
  thread-local state, but `Thread.current.name` is `nil` inside a nested thread - as is
  the channel the tree already uses (`Task` publishes `Thread.current[:harness_task]`,
  `lib/task.rb:107`; `Task.emit` reads it at `:252`). `Logger#progname` does reach the
  formatter as its third argument, and so does the block form `logger.info("tag") { ... }`;
  both are viable per-call carriers.
- **A payload containing a line-start delimiter is parsed as a new event** (tested with a
  `web.fetch`-shaped body). "Unlikely to appear in practice" is not sufficient: escaping
  or a length prefix is required.

The naive delimiter `!E!<job>!<time>!<severity> <body>` with the body running to the next
delimiter is the shape; unreconstructibility is the open part (see below). Today's format
already fails on multi-line messages: of 95,177 lines in the sample only 10,183 carry a
header, so ~89% are continuation lines with no job attribution. Nothing in `lib/` *reads*
`harness.log` - only the path is constructed - so it is write-only and reformatting it
breaks no reader.

## Code constraints the layout imposes

- Job ids are per-run: `@next_id` starts at 0 and increments by 1 (`lib/job_registry.rb`),
  and job 0 exists in every session as the main turn.
- Jobs are not persisted today at all: `foreground_job` (a single int) is the only job
  fact `save_session` writes, and resume's `restore_foreground` early-returns when
  `job(id)` is `nil`.
- **Edges are live object references, not ids.** `Job#ready?` calls `dep.finished?` /
  `dep.call`, and `finish` does `requested_by&.deliver(result)`; nothing serializes them.
  Per-job storage forces edges into ids that resume must re-resolve, and a dropped job's
  id can dangle in another job's `dependencies`. That re-resolution is the real work of
  this change, not the file split.
- Access grants are **system-wide today** (`doc/harness_job_design.md`: `Session#restore_access_grants`
  still reaches the system-wide `FileList`), so `access` and `file_cache` stay in `system.json`
  until `FileList` itself becomes per-job. That is a code dependency, not a design choice.
- `replay_tail` moves to the job directory on **ownership** grounds, not size:
  `JobRegistry#replay_tail_for_save` returns the foreground buffer's replay tail, i.e. a
  system record currently stored in the job's conversation file.
- `SessionLocator#session_files` globs `sessions/*/"session.json"` - exactly one level
  deep - and `list`, `search`, `find_session_file` and `newest_session_path` all derive
  from it. Nesting job directories under the run makes that glob return `[]`, breaking
  `/sessions`, `--resume`, `--continue` and `--delete-session` unless the locator is
  rewritten **in the same increment**. `valid_id?` accepts UUIDs only, and directory names
  are matched by prefix.
- `Session#to_h` persists `@messages[1..]` - message 0 is implicit and rebuilt from the
  current `build_system_prompt`. A per-job chain inherits that convention.
- Existing bug, fix while touching the locator: `SessionLocator#list` reads `data[:files]`
  and nothing ever writes a `:files` key, so `/sessions` always reports `files: 0`.

## Corrections to earlier reasoning (recorded so they are not re-litigated)

- "One file for system state is already true" is **wrong**: that claim read the filename
  instead of the writers. `session.json` mixes system state and foreground-job state, and the
  writers are per-Harness.
- The 370 MB `harness.log` (`stat` size 0, 377,984 blocks allocated) is a **Windows**
  artifact: a file held open by the live `SessionLogger` cannot be truncated, so blocks
  stay allocated after the size is zeroed. Judge log growth by `du`/block count rather
  than size, and check for open handles before trusting a truncated sample.
- The bulk of session volume is the conversation: in a measured 231,914 B `session.json`,
  `messages` is 190,214 B (82%) and `replay_tail` 39,492 B (17%, 30 entries); every other
  key is under 1.2 KB. Per-job storage relocates the bulk rather than shrinking it.
  Log *size* is a separate, larger problem: ~400 MB of growth comes from unbounded raw
  dumps (command output, fetched bodies).

## Open decisions / deferred

- **Unreconstructible delimiters (DECIDED: no change)**: the per-thread stamp shipped; the
  owner declined any escape/length-prefix scheme for multi-line dumps ("logger works fine
  like that"). `harness.log` is write-only, so the ~89% unattributed figure is accepted.
- **Log size control**: cap raw dumps, move dumps into `jobs/<id>/`, or rotate. Delimiters
  do not address this.
- **Stamp channel mechanism**: a thread-local set explicitly at every `Thread.new` with a
  main-thread fallback to the foreground job, versus `Logger#progname` per call. Thread ids
  are rejected.
- **Run id vs job id (DECIDED):** the run/system UUID lives only in the **directory name**
  and **`system.json`** - never in a job's `session.json` / `job.json`. A job is identified by
  its directory (`jobs/<id>/`) plus the `id` in `job.json`; it does not need the run UUID,
  and a job file that also stores a `session_id` is a second source of one identity - which
  is what invites drift bugs. Today's `Harness#initialize` already polices that copy (it
  raises when `resume_data[:session_id]` disagrees with the directory id); dropping the field
  removes that bug class rather than guarding it. The directory name IS the system id - there is
  no separate run-UUID to invent.
- **MCP-per-job reconnect (DECIDED: one manager per run, shared)**: see the section above.
  A run owns one `Mcp::Manager` + one `ToolRegistry` shared into every job Harness; the
  deferred step is to build them in the run owner and hand them to `Harness.new`. Sharing
  a live connection across concurrent jobs is guarded by a **per-server connection pool**
  (size 1 now, expandable): a call borrows the server's connection and always returns
  it, so a concurrent call to the same server waits and a call to a different server does
  not. This satisfies the stdio non-multiplexed-read hazard uniformly, no transport branch.
- **Whether a sub-agent's harness session is auto-saved at all**, or only saved when a
  dependency needs it back (a read-only `agent.explore` may not need its transcript
  persisted; a write-capable sub-agent will).
- **How `/sessions`, `--resume`, `--continue`, and `--delete-session` read a layered
  store** - list runs, list agent sessions, or both; which one `--resume` targets.
- **Backward compatibility**: migrate existing one-file sessions into the layered shape
  (`StateMigrator`), or read them as the degenerate one-job case.
