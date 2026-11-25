# Unified loop: the poll loop as the harness main loop

Target design for the task/job/registry division of work (issue #286). Verified
against the Poller (now MainLoop) extraction baseline `3739f17` (2026-11). Cross-refs:
#286, #36/#198 (steering notes), #221 (the /yolo gesture hack), #267 (its tech
debt, #424. Read `doc/task_model_design.md` and `doc/task_design.md` first.

---

## The idea (owner, 2026-11)

The polling loop IS the harness main loop. There is no "enter running task"
step and no separate execution path: starting a turn is just "send a
note/prompt event to the foreground job." One loop, two *modes* of that loop:

- **Spinner mode** - the foreground job's worker thread is live; the loop
  renders the spinner and drains the event queue. This is what runs when you
  "start typing" is false.
- **Edit mode** - the user starts typing; the loop enters the edit state and a
  submit is read. From edit mode, **all commands are allowed** - the full
  CommandHandler registry, idle or mid-turn alike.

So "prompt" and "steering note" are the SAME submit reaching the foreground
job; the only difference is whether a worker thread happened to be alive
(prompt starts one, note lands beside one). The `InputPath` is already this one
shared read (`cli.rb` wires one `InputPath` both the idle read and a note read
use). The unification is to stop routing a mid-turn submit through the
special-cased note plumbing and route it through the one command handler instead.

## Why (the hack this removed)

Before the mid-turn dispatch landed, a mid-turn submit was a "note," and the
ONLY command it could honour was a hardcoded `MainLoop#commit_note` gesture:

```ruby
if (toggle = self.class.yolo_note_action(note))   # ugly, not scalable (#221/#267)
```

Every other command the user might want "at any time" (`/stream`, `/model`,
`/compact`, ...) is swallowed as plain steering text. A single loop whose edit
mode submits to the one CommandHandler makes the gesture-dispatch hack
unnecessary: a bare word is a note-event, a `/x` is a command, both in one path.

## Shipped: mid-turn dispatch (state-only inline)

The first routing step is in. A submitted block in the poll loop
(`MainLoop#commit_read`) classifies itself:

- a `"/"`-prefixed submit (edit mode) goes to the run's `CommandHandler` through
  the shared `InputPath#command_handler` (a callable wired by the CLI like
  `target`/`registry`). The handler is a loop-level collaborator, NOT on the
  Harness - the model layer must not own the CLI dispatcher.
- bare text keeps the note route exactly (`route_input` + `commit_note`), byte
  for byte.

`CommandHandler#run_mid_turn` dispatches a `"/command"` INLINE on the main
thread (the poll loop IS the main thread), gated by `Command.mid_turn_safe?`:

- **default true** (edit mode allows all commands); a command opts OUT when it
  cannot run safely while a turn is live. The hazard is `#run_on_task` - driving
  an LLM round would start a SECOND drain loop over the single queue (double
  render, lost events) - so `/retry` and `/compact` opt out and are refused with
  a hint. `/exit` opts out: it quits the run, with no live loop to act in. The
  posture toggles (`/yolo`, `/stream`, `/plan`) are pure
  Harness state writes and stay safe.

This is what deleted `MainLoop#yolo_note_action` and the `commit_note` gesture
branch: `/yolo` mid-turn is now just `CommandHandler#run_mid_turn('/yolo')`.

## Command routing in the unified loop

A submit from edit mode is classified once:

- **bare text** -> a note/input event to the foreground job (`route_input`,
  the override rule from `doc/task_model_design.md` preserved exactly).
- **`/command`** -> the shared `CommandHandler` registry, on the MAIN thread
  (commands always run inline; only *prompts/notes* touch the job queue).

A `/command` that mutates the *running turn* must reach the foreground job as
an event rather than mutate shared state from the loop (the "more event-based
logic for various commands" the owner wants):

| command  | unified-loop behavior                                   |
|----------|---------------------------------------------------------|
| /yolo    | posture write on Harness (main thread), no task event   |
| /model   | event to the foreground job: "change model" for its turn|
| /compact | event to the foreground job to compact (improvement on  |
|          | the current main-thread implementation)                 |
| /retry   | push event to the task, or restart its thread, per the  |
|          | task-thread lifecycle chosen below                      |

(The `/resume` slash command has since been REMOVED: resuming a saved session is
a startup option only - `--resume <id>` / `--continue`.)

## Task-thread lifecycle (both open, undecided)

The task stays a **separate thread** (owner). Two workable lifecycles, both
acceptable; pick when the first slice needs an answer:

- **Start/stop on demand** (current model): a submit that finds no live worker
  starts the thread; `:done` ends it. Smallest change to `TaskRunner`.
- **Always-running worker**: one foreground worker parked on its inbox, woken by
  each input event; the loop never starts/stops it. Cleaner "one loop" story,
  bigger change to Task/Job.

## What already exists (so this is unification, not a new subsystem)

- One `InputPath` shared by idle prompt and mid-turn note (`lib/input_path.rb`).
- `MainLoop` owns the drain loop + spinner + note path (this commit), so the
  loop's mid-turn logic is already in one class to edit.

## SHIPPED: the loop reads the queue for every job (increment 1)

`MainLoop` (renamed from `Poller` - polling is one step of the loop, not its
identity) now owns the registry it polls and reads the ONE queue for EVERY job:
`#next_shown_event` records each event into its own job's buffer and keeps pulling
until an event for the SHOWN job arrives. Only the shown job's events are rendered;
a background job's output is read through `/jobs` rather than interleaved with a live
turn (owner decision). A foreign `:done` is recorded and its result delivered but does
not end the loop. `Task#poll` lost its job-id filter: a Task is a job's runner, not the
queue's reader.

This is the prerequisite for the rest of the plan: a loop that filters the queue by one
job id can never BE the run loop, and a parked worker alone buys nothing while a
per-turn loop is still built for each turn.

## Suggested increments (small, each shippable)

1. Add a mode/state to the poll loop (spinner vs edit) without changing routing
   yet - the shared `InputPath#edit_state?` is the seed.
2. SHIPPED (state-only inline). Route a mid-turn `/command` submit to the shared
   `CommandHandler` via `CommandHandler#run_mid_turn` + `Command.mid_turn_safe?`.
   State-only commands run inline; a model/rebuild command is refused (see
   "Shipped" above).
3. SHIPPED. Deleted `MainLoop#yolo_note_action` + the `commit_note` gesture
   branch; `/yolo` is an ordinary command through the handler.

## Remaining increments (owner order, 2026-11-24)

The lifecycle question is ANSWERED: an ALWAYS-RUNNING worker parked on its job
inbox, not a thread started per turn. `MainLoop` is to REPLACE `CLI#run` - a run
must not have two mains. Order:

2. SHIPPED (mechanism). A worker parks on its own `@await_work` queue (NOT the job
   inbox - the drain loop is the inbox's reader, so a steering note stays there);
   `Job#deliver` routes a delivery to the live worker's `@await_work` (via
   `job.worker`), else to the inbox. `JobRegistry#await_turn` delivers a WORK item
   and awaits its `:done`; `worker_for` parks a worker.
3. SHIPPED (the run loop). ONE `MainLoop` for the whole run: `CLI#run` builds the
   shared `InputPath` + the foreground job's parked worker and runs the loop; the
   idle prompt read (`read_prompt`, modeline from CLI) and a turn's drain
   (`run_turn`: submit WORK, drain to the shown job's `:done`) are two modes of it.
   Deleted: `Task.run`, `JobRegistry#run`/`#await_turn`, `PromptReader` (folded
   into `read_prompt` + `CLI#render_modeline`), `TaskRunner` (the mixin survives as
   `Reporting` - console roles only; `Command#run_on_worker` is the wrapper and
   `MainLoop#run_turn` reports a worker error via `CommandHandler#report_turn_error`).
   Spinner storage moved onto the loop.
4. Live `/compact` and `/retry` as control events drained beside the note in
   `TurnRunner`; their `mid_turn_safe? = false` refusals deleted. `/jobs add` last
   (it builds an agent).
5. Interrupt and shutdown semantics for a parked worker.

4a. SHIPPED (the request event, `/compact` half). A mid-turn command that wants
   work on the live turn sends a `RequestEvent` (`lib/request_event.rb`): the
   loop pushes it straight onto the worker's own `@await_work` (the channel WORK
   and STOP already use - the Thread::Queue is the synchronization; no mailbox
   flag, no mutex) and the worker services it as a mini-turn INSIDE the live
   turn, before that turn's `:done`. A mini-turn pushes NO `:done` of its own:
   the `:done` finishes the JOB (`Job#finish` is once-only), so a mini-turn
   `:done` would finish the job mid-turn and drop the real turn result. Live-
   ness lives on the JOB: `Task#service_turn` marks the job running, and
   `Command#turn_live?` reads `main_loop.shown_job.running?` - the loop holds no
   live-ness flag. `/retry` is NOT yet converted; `/jobs add` last.

4b. SHIPPED (the loop holds no worker). `MainLoop` had a `@worker` ivar -
   duplicate state: a worker belongs to its JOB (`job.worker`), and the loop
   shows the FOREGROUND job, so the worker it acts on is always
   `shown_job.worker` (built lazily on first use; `CLI#run` builds none). A
   `/jobs` foreground switch repoints only `registry.foreground` - it NEVER
   stops a worker; every job keeps its own parked Task alive (`repoint_worker`
   deleted). An interrupt stops the shown job's worker and the next `#worker`
   call REVIVES the same Task (a `#stop` keeps the stopped Task on the job; a
   STOP left in the queue belongs to the thread that died for it).

Do NOT park a worker before the loop owns the queue: a parked loop and a
per-turn loop reading the same queue steal each other's events (measured - the suite
hangs). Increment 3 removed the per-turn loop, so one reader remains.
