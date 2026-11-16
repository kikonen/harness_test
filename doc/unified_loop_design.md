# Unified loop: the poll loop as the harness main loop

Target design for the task/job/registry division of work (issue #286). Verified
against the Poller-extraction baseline `3739f17` (2026-11). Cross-refs:
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

## The dependency cleanup that must precede the loop unification

Owner decision (2026-11): a **Task is a generic async thread runner**, not a
harness-specific object. "Harness" is one *thing you run in* a Task, not a type a
Task depends on. The current deps point the wrong way (the worker-side harness
defining presentation), and they block increment 4/5, so they are cleaned first,
as three PRs (A -> B -> C), each rubocop + full-suite gated.

### The deps today (what Task.run / Poller pull off the harness)

| pulled off harness | real concern | belongs to |
|---|---|---|
| `output_palette`, `markdown?`, `markdown_max_width` (`task.rb:335-343`, baked into a per-turn renderer) | presentation | the **UI sink** |
| `output_log` (`task.rb:326`) | the record | the **registry** (job buffer) |
| `command_mode_label` / `stream_mode_label` / `plan_mode_label` (`poller.rb:153-174`) | posture | a narrow **posture** interface |
| `user_note_text=` (`poller.rb:256`) | live-turn input | a narrow **input-sink** interface |
| `logger` (`task.rb:217`, task-thread error frames) | logging | a **logger** role object |

`attr_accessor :harness` on Task (`task.rb:49`) is public and read at
`task.rb:331`, `poller.rb:152/197/256` - only 4 real sites, so the strip is small.
The generic handle `Thread.current[:harness_task]` (`task.rb:110/259`) leaks
"harness" into a generic mechanism; `Task.current` itself is used correctly by
`command_runner`/`tool`/`task_runner`/`dialog` only to push onto the running task's
queue - keep that method, rename only the Thread key.

### Step A - presentation deps -> the sink

`UI::Renderer.palette_for(ui:, harness:)` ALREADY prefers `ui.palette` over
`harness.output_palette` (`renderer.rb:153`), and `Console#palette` can be a live
callable that lazily resolves the harness palette (`console.rb:34`). So the palette
is already half-moved: owned-by-harness, read-through-sink. Finish it: the sink
(UI layer) is the source of truth for palette, markdown, and table width;
`Task.run` builds its renderer through the sink, not by reading three display
getters off the harness. The harness becomes a *config source that configures the
sink*, not something the worker path reads directly.

**Ownership (owner, 2026-11): the CLI owns it.** A small `UI::RenderSettings`
holds the `(palette, markdown, markdown_max_width)` tuple that `UI::Renderer.new`
already takes. The CLI builds it once (from `options`/config) and injects it into
every consumer. The harness does NOT own render state - it is fully background and
renders nothing - so it must stop being the holder or the session round-trip hop.

**Shipped (CLI owns + injects + harness delegates).** The CLI builds ONE
`UI::RenderSettings` from `options` and:
- makes the `Console` palette callable read it live (the
  `-> { @render_settings.palette }` passed to `UI::Console.new`);
- injects it into every `Harness` it builds through the new
  `Harness#initialize(render_settings:)` kwarg, so a mid-run `/resume` reuses the
  SAME object the sink already reads (a restored palette lands on it);
- uses it for the resume-replay renderer (`CLI#print_resume_replay`).

The harness no longer holds palette/markdown state of its own. It keeps
`output_palette`, `output_palette=`, `markdown?`, `markdown=`, `markdown_max_width`
as thin DELEGATORS onto the one settings object (the `attr_accessor :render_settings`
set in `#initialize`). That keeps the session round-trip (save reads the delegators,
`apply_resume_state` writes them) and every existing harness-double spec green,
while the single source of truth is the CLI-owned object. Construction stays
eagerly validating the palette NAME: `#initialize` builds the default
`RenderSettings` when none is injected, so an unknown `--palette` raises before any
LLM call - the boundary the old `@output_palette` assignment enforced.

**Deferred to Step C - repointing the worker path.** `task.rb`'s per-turn renderer,
`task_runner.rb#main_thread_renderer`, and `command_handler.rb` still read the three
getters off `harness`. That is not a wrong-way dependency to fix here: it is the
SAME `harness.<x>` read Step C removes when it replaces `attr_accessor :harness` with
the narrow sink handle. Repointing them to `harness.render_settings.<x>` now would
change no coupling and force rewriting the ~9 spec doubles that answer the three
getters - it belongs with the handle replacement, not before it.

### Step B - the incoming queue: one honest thing (blocks increment 4)

`Task#@inbox` is literally `job.inbox` (`task.rb:59`) - a borrowed alias called the
"task's inbox." Its only reader, `Job#poll` (`job.rb:136`), has NO production
caller. The LIVE note channel is a different mechanism: `poller.rb:256` writes the
shared `harness.user_note_text` ivar, and `Harness#request_chain` (the model's tool
loop) drains `@user_note` at the request boundary (`harness.rb:863`). So today two
similarly-named "incoming" channels exist and only the ivar one is live. Resolve
this into ONE documented incoming path BEFORE increment 4 adds control events, or
inc4 gets a confusing third channel.

### Step C - strip harness out of Task/Poller (the generic-runner payoff)

Replace `attr_accessor :harness` with the narrow role objects the table names
(sink, posture-source, input-sink, logger); rename the Thread handle to a neutral
key. After this, a Task is harness-agnostic, and increment 5 (the non-blocking
unified read loop, where a worker is an optional thing the loop drives) becomes
coherent instead of fighting harness coupling.

## Increment 4: control events drained at the request boundary

The note already works this way and increment 4 just generalizes it. There is NO
inbox-reading loop in the task block: a steering note is a SHARED Harness ivar.
`Poller#commit_note` writes `harness.user_note_text = note`; the model's own tool
loop, `Harness#request_chain`, drains `@user_note` at the top of the NEXT request
and injects it as a user message (see the `if @user_note` block in
`request_chain`). So the injection seam is per-request and already live.

Generalize that one ivar into a small queue of pending control events the same
way: `harness.enqueue_control(type:, payload:)` (a thread-safe append), drained by
`request_chain` at the same boundary. `/retry` and `/compact` then stop being
refused mid-turn: `run_mid_turn` enqueues a control for the live task instead of
erroring. `/compact` is the first concrete consumer - it mirrors the compaction
`request_chain` ALREADY does at this boundary (`check_inloop_compaction`), so a
user `/compact` drains into the same code path the loop uses for itself.
`/stream`/`/yolo`/`/plan` stay direct Harness state writes (posture is re-read per
request; no queue needed).

Scope (owner 2026-11): increment 4 is a PoC carrying ONE command, `/compact`.
`/retry` is NOT wired as a mid-turn event - it is a failed-session concept (the
connection to the model was lost, so there is no live tool loop to inject into),
and sending it as an event into a live task accomplishes nothing. `/retry` stays
refused mid-turn; revisit only when increment 5 changes the worker's shape and the
"restart the in-flight request" question is real.

This is why increment 4 is the safe ramp to increment 5: it moves model/rebuild
commands onto the live-turn event path WITHOUT touching `cli.rb`'s loop or the
task-thread lifecycle yet. The hazard it removes is only the nested `run_on_task`
drain loop; the worker thread stays exactly as it is (one-shot per turn).

The streaming invariant survives unchanged: a drained control applies at the
request boundary it is drained at, never to a connection already in flight.

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
