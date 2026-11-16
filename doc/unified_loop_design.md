# Unified loop: the poll loop as the harness main loop

Target design for the task/job/registry division of work (issue #286). Verified
against the Poller-extraction baseline `3739f17` (2026-11). Cross-refs:
#286, #36/#198 (steering notes), #221 (the /yolo gesture hack), #267 (its tech
debt, #424. Read `doc/task_model_design.md` and `doc/task_design.md` first.
This doc assumes the run-wide `Harness` may be mutated by any command; the
ownership model that assumption rests on is being replaced - read
`doc/harness_job_design.md` (the god-object -> per-job tool-loop split) first.

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
shared read (`cli.rb` wires one `PromptReader` whose `input_path` the poll loop
also uses; `PromptReader#edit_state?` already exists). The unification is to
stop routing a mid-turn submit through the special-cased note plumbing and
route it through the one command handler instead.

## Why (the hack this removed)

Before the mid-turn dispatch landed, a mid-turn submit was a "note," and the
ONLY command it could honour was a hardcoded `Poller#commit_note` gesture:

```ruby
if (toggle = self.class.yolo_note_action(note))   # ugly, not scalable (#221/#267)
```

Every other command the user might want "at any time" (`/stream`, `/model`,
`/compact`, ...) is swallowed as plain steering text. A single loop whose edit
mode submits to the one CommandHandler makes the gesture-dispatch hack
unnecessary: a bare word is a note-event, a `/x` is a command, both in one path.

## Shipped: mid-turn dispatch (state-only inline)

The first routing step is in. A submitted block in the poll loop
(`Poller#commit_read`) classifies itself:

- a `"/"`-prefixed submit (edit mode) goes to the run's `CommandHandler` through
  the shared `InputPath#command_handler` (a callable wired by the CLI like
  `target`/`registry`, so a `/resume` rebuild repoints it). The handler is a
  loop-level collaborator, NOT on the Harness - the model layer must not own the
  CLI dispatcher.
- bare text keeps the note route exactly (`route_input` + `commit_note`), byte
  for byte.

`CommandHandler#run_mid_turn` dispatches a `"/command"` INLINE on the main
thread (the poll loop IS the main thread), gated by `Command.mid_turn_safe?`:

- **default true** (edit mode allows all commands); a command opts OUT when it
  cannot run safely while a turn is live. The hazard is `#run_on_task` - driving
  an LLM round would start a SECOND drain loop over the single queue (double
  render, lost events) - so `/retry` and `/compact` opt out and are refused with
  a hint. `/resume` and `/exit` opt out: they rebuild/quit the run, with no live
  loop to act in. The posture toggles (`/yolo`, `/stream`, `/plan`) are pure
  Harness state writes and stay safe.

This is what deleted `Poller#yolo_note_action` and the `commit_note` gesture
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
| /resume  | likely REMOVED - owner sees no use case for it          |

(`resume` is flagged, not yet removed. Confirm before deleting the command and
its specs.)

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
- `PromptReader#edit_state?` - "idle and mid-turn share the edit state because
  they share this one reader" (`doc/reline_cursor_and_enter_handling.md`).
- `CommandHandler` already receives `input_path.target` / `input_path.registry`
  (`cli.rb`), i.e. it already reaches into the loop's foreground-job notion.
- `Poller` owns the drain loop + spinner + note path (this commit), so the
  loop's mid-turn logic is already in one class to edit.

## Suggested increments (small, each shippable)

1. Add a mode/state to the poll loop (spinner vs edit) without changing routing
   yet - the shared `InputPath#edit_state?` is the seed.
2. SHIPPED (state-only inline). Route a mid-turn `/command` submit to the shared
   `CommandHandler` via `CommandHandler#run_mid_turn` + `Command.mid_turn_safe?`.
   State-only commands run inline; a model/rebuild command is refused (see
   "Shipped" above).
3. SHIPPED. Deleted `Poller#yolo_note_action` + the `commit_note` gesture
   branch; `/yolo` is an ordinary command through the handler.
4. Make `/model` and `/compact` event-to-task instead of shared-state writes /
   refusals (the next step: replace the mid-turn refusal with a live-task event).
5. Decide the task-thread lifecycle (on-demand vs always-running) once the
   event path is stable.
