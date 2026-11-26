# Task: async turn design

Design notes for `lib/task.rb` (a job's runner) and `lib/main_loop.rb` (the run's
main loop): how a turn runs on a background thread while all console I/O stays on
the main thread.

---

## Single-thread I/O rule

The Task runs a block on a background thread and owns ALL console I/O for that
turn. The task thread NEVER writes to an IO stream. It pushes typed events onto
the SINGLE event queue (the outbox); the main thread's drain loop reads from
that queue, stores each output event into the OutputBuffer (structured log),
and renders to stdout in order. There is no second channel - one queue
guarantees total ordering.

## Single event queue

The outbox (`Thread::Queue`) is the ONLY task-to-main channel. Both output
events (`:text`, `:spinner_detail`, ...) AND control events (`:done`,
`:error_ctrl`, `:__request__`) travel on it. The drain loop pops one message at
a time and dispatches by type. Total ordering of all visible output follows
because every event flows through exactly one FIFO.

Under the registry design (issue #286 phase 0, `doc/task_model_design.md`) the queue
belongs to the registry, not to one task: every job pushes onto that ONE queue and each
event carries the job id. Fan-in keeps this guarantee across jobs - one queue per job
would leave cross-job order undefined.

The loop that reads it is `MainLoop` (renamed from `Poller`: polling is one step of
the loop, not its identity). The loop owns the registry it polls and records EVERY
job's event; it renders only the job it shows. A Task hands the loop nothing but its
own runner state - `Task#poll` is the unfiltered queue read.

Protocol:

```
Task thread -> Main thread: push_event(type:, origin:, content:) [outbox]
Task thread -> Main thread: request(type, **payload)             [outbox, blocking]
Main thread -> Task thread: task.respond(value)                  [reply channel]
Main thread (drain loop):   poll outbox, dispatch by type
```

## The parked worker (issue #286 increment 2)

A worker is PARKED, not per-turn: `#start` spawns ONE thread per job that takes a
`WORK` item, runs it as a turn (`service_turn`), and waits for the next. A turn ends
with a `:done` event; the THREAD ends only on a `STOP`. `JobRegistry#await_turn`
submits a turn's block and awaits its `:done` while the caller's own loop drains the
queue - this is what removes `TaskRunner#run_on_task`'s nested drain loop.

Two queues, one reader each: the job **inbox** is the drain loop's (steering notes
land there and stay there), and the worker's own **`@await_work`** is the worker's.
`Job#deliver` routes to `@await_work` while a parked worker lives (`job.worker` names
it), else to the inbox. `submit_work` delivers a `WORK` item through the job, so a
caller never touches the thread.

Increment 3 deleted the per-turn `Task.run` form: the run's ONE `MainLoop` drains
the queue (`MainLoop#run_turn`), and the worker stays parked between turns. The CLI
no longer builds a worker at all: the loop acts on `shown_job.worker` and builds
it lazily on first use. A worker belongs to its JOB - `#start` sets `job.worker`,
and a `#stop` KEEPS the (stopped) Task on the job so the loop can REVIVE the same
Task by re-`start`ing it on its own queue (a STOP left in the queue belongs to
the thread that died for it, so a revived worker skips it and keeps parking).
A second `#start` on a LIVE worker would spawn a second thread and is refused.

## Request events: a mini-turn inside the live turn

A `RequestEvent` (issue #286 increment 4, `lib/request_event.rb`) is a command's
ask delivered on `@await_work` while a turn is live. `service_turn` drains the
request items already queued and runs each as a mini-turn (`service_request`)
BEFORE pushing the turn's `:done`: the `:done` finishes the JOB, so servicing
after it - or pushing a `:done` from the mini-turn - would finish the job
mid-turn and drop the turn's result.

## A task error: one line out, the frames into harness.log

A task thread owns no console (single-thread I/O rule), so an exception raised
inside the turn block cannot be printed where it happened. It travels as one
`:error_ctrl` event carrying `"Class: message"`; `MainLoop#run_turn` collects it
and `CommandHandler#report_turn_error` states it as the `:kind` role with origin `task error`
(issue #474, increment 22), so `UI::Renderer` draws the bracket - the emitter holds
the message alone, which is what lets a replay redraw the line from the record rather
than inherit this emitter's prefix.

That line is the whole story on the CONSOLE by design: a multi-line backtrace
there would be interleaved with the turn's own output. It is NOT the whole
story anywhere else, which was the bug - the frames died with the thread, so a
crash reported as `[task error] NoMethodError: undefined method 'record' for
nil` left nothing to trace it back from. `Task#record_task_error` logs the
exception WITH ITS BACKTRACE via the harness logger (the session's
`harness.log`) from inside the rescue, so the trace exists where the failure
occurred. The event is pushed FIRST: a logger that cannot write must not swallow
the error line the user is owed. A harness with no logger (a spec double, a Task
run with `harness: nil`) still yields the one-line error - logging is additive,
never load-bearing on the error path.

## Structured log

There is ONE OutputBuffer per run (issue #286). `Task#prepare` hands the task the
harness' single buffer, so every put the drain loop makes lands in the same record
a save reads - no harvest step, no second store. At the registry layer (issue #286)
each job gets its OWN buffer, so this becomes the buffer of the foreground job.
A task with no buffer to use builds none: `buffer:` is required, so a caller (the
harness, the future registry, or a spec double) must supply one. The drain loop is
the single main-thread writer; the task thread never touches the buffer
(single-thread I/O rule). The single writer enforces the
buffer's own saved window right after a tail put (`OutputBuffer#keep_window`).
See `doc/output_buffer_design.md`.

## Spinner ownership - the runner decides, trivially

The drain loop shows the spinner while the outbox is EMPTY (the task is
silently working - i.e. while waiting for a slow operation such as an LLM
request). A `:spinner_detail` event re-points what the current wait looks like
(message + optional suffix) and keeps the spinner alive after that batch. Any
OTHER data clears the spinner line BEFORE it is rendered (output lines must
never land under a stale spin frame). It comes back on the next tick only if
the outbox is empty again.

A re-point describes ONE wait. The runner remembers it only so a spinner
rebuilt inside that same wait keeps its message instead of falling back to the
bare default; it is NOT a turn-wide state to be cleaned up. So every wait
emits its own `:spinner_detail` when it starts - whoever finishes a wait does
not have to clear anything, because whoever starts the next one overwrites it.

The re-point is the spinner's live state, and the head cell holds it (issue
#286). The ORDER in `Task.store_and_render` is the point: the raw event content
lands in the buffer HEAD first, and the spinner content is then built FROM that
head cell - not from the event. The head is the single source of the live state,
so the spinner and any refreshed remote sink read the same object. The rebuild
path (`ensure_spinner_running`) reads the newest spinner head cell, so the head
is both the live view and the memory a rebuilt spinner replays.

Harness code never starts or stops spinners - it just emits `:spinner_detail`
(or nothing at all) and is done. Tool execution renders output, it does not
wait, so its OUTPUT never re-points the spinner. The EXECUTION, though, is a
wait: a tool that waits (a slow command, a consent dialog, a model safety check)
leaves the outbox quiet, so the drain loop animates - and what it animates is the
detail the last wait left behind, i.e. the LLM request that already finished, so
a long tool run reads as "Sending (model)..." (issue #362). A tool round therefore
announces itself: `Harness#announce_tool_call` names the TOOL before the call
runs, and `CommandRunner#announce_run` replaces that with the run's own handle
while the child process runs. The suffix of a tool wait is the context estimate
and NO rate segment - no request is in flight, so there is no speed to show.

The LLM-request wait is announced by `SessionManager#request_spinner_detail`,
which `Harness#call_llm` calls before EACH request of the tool loop (the only
caller of it) - see issue #283.

The spinner's own segments (elapsed turn time, posture badge) come from
the runner too, always as callables: the drain loop rebuilds the spinner
whenever the outbox empties again, so anything the spinner computed itself
would restart on every rebuild. Only the runner knows how long the turn has
been running (issue #277). The badge is `MainLoop.mode_badge` - one bracket per
NON-default posture - and it is the SAME builder the idle prompt line uses, so a
posture cannot read differently in the spinner and the prompt (issue #387).

## Console injection

`Task#prepare` takes a `ui:` (a `UI::Console` wrapping an explicit stdout/stdin
pair). The same console is used for spinner frames, text output, and dialog
prompts so tests can capture everything through a single StringIO-backed
console. It is published on the task instance and passed explicitly to every
I/O call.

## Ctrl+C

While `MainLoop#run` runs, SIGINT is trapped so an interrupt targets the loop,
not a random thread. Ctrl+C during a LIVE turn is a TURN abort: the worker is
force-stopped (no background work survives the turn), the loop prints
`[interrupted]`, and the shown job's SAME Task is revived (re-`start`ed on its
own queue) so the run re-prompts instead of exiting. Ctrl+C AT the idle read
(no live turn) is the quit gesture: it re-raises for the CLI's cleanup path,
like Ctrl-D.

`Task#stop` answers what the turn OWES before stopping it. STOP is not an answer,
so a blocked requester that got STOP instead of a value raises "task was stopped
while waiting for response". An interrupted turn therefore delivers
`Job::INTERRUPTED_ANSWER` to every request it left owed:

- A request this task issued (`#request` posted, no answer yet) blocks on its
  **reply channel** (`@pending_reply`, see issue #424 below), not the inbox. So
  `stop` pushes the interrupted answer onto that channel and clears the owning
  job from the owed set so the same answer is not also queued into its inbox.
- A request owned by ANOTHER awaiting job blocks on that job's inbox; `stop`
  delivers the interrupted answer via `Job#respond` (the single answer primitive).
- STOP lands on the worker's own queue (`@await_work`), never the job inbox: the
  parked worker pops `@await_work`, and `@await_work << STOP` unblocks a pending
  pop and ends the worker loop. The job inbox stays the drain loop's reader-side
  queue, so a steering note resident there is never mistaken for a wake-up.

The join grace is short (`DEFAULT_STOP_JOIN_TIMEOUT`, 0.5s): a task thread blocked
in a long call (the LLM read) never reads the STOP, so the old 5s join was why
Ctrl+C stalled ~5s before killing it.

## Request replies - a dedicated channel (issue #424)

A `#request` blocks until the main thread answers it. It used to `pop` the task's
inbox, which assumed the front item WAS the answer - the strict-sync assumption
that broke when steering notes share that inbox (issue #424). With the registry
path (production), a steering note typed earlier in the turn is routed into the
foreground job's inbox (`route_input`/`Job#deliver`); if that note is at the front
when a dialog request pops, the dialog receives the note-hash as its "choice" and
the real answer leaks to the next request.

The fix: a task issues at most one request at a time (it is single-threaded), so
`#request` opens a private `@pending_reply` queue and blocks on THAT. Only
`#respond` and `#stop` ever write it, so a note (which stays in `@inbox`) can
never be mistaken for the answer. `@inbox` keeps carrying steering notes (the
drain loop reads them); a parked worker's deliveries arrive on its own
`@await_work` via `Job#deliver`. Multiple tasks asking the user a question
do not conflict: each has its own reply channel. (Async answers from sub-agent
jobs are a separate future concern; on master `requested_by` is never set, so no
inbox value is legitimately delivered to a live `#request`.)

Each drain tick PEEKS `stdin.input_pending?` (nil on streams that do not
support it); if the user is at the keyboard the MAIN thread opens a
`UI::Editor` - tty gets Reline multiline (Enter = newline, submit key = one
note, Esc = draft kept, Ctrl-D on an empty buffer = abort the turn), non-tty
gets one line per read (a pipe has no submit key). The note is acked and stored
on the harness (`Harness#user_note_text=`), where `Harness#call_llm` injects it
into the chain before the next LLM call.

`input_pending?` is a core `io/console` peek that only reports a keypress once
the tty hands bytes over one at a time. A cooked tty (measured on Linux/KDE;
issue #473) buffers a whole line, so a lone keypress never fired the peek and no
editor opened. `MainLoop#run` therefore holds a real-tty stdin in raw mode for the
wait (`raw!(intr: true)`, restored by `cooked!` in its `ensure`); the hold is
guarded to a stream answering `#raw`, a true `#tty?`, AND `#input_pending?`, on a
host that supports the hold (see the host gate below).

The host gate is the load-bearing part (issue #473 follow-up). The first fix
(c65d59d) gated on `#input_pending?`, the capability `poll_for_note` consumes,
on the theory that raw mode is a pure cost wherever the peek never runs - but
that mis-read Windows: msys2 (the owner's box) DOES answer `#input_pending?` and
opens the editor there. On a Windows console `raw!(intr:true)` cannot make
Ctrl+C a signal at all (Windows has no POSIX ISIG), so the held `0x03` byte is
read by the peek as a keystroke - the note editor opens and the turn never
aborts. The hold is therefore a POSIX-tty tool, not a capability: the guard is
a host gate (`MainLoop.raw_hold_host_supported?`), so on a Windows host the stdin
stays cooked and Ctrl+C aborts as it did before #473, while the Linux/KDE raw
hold stays where it helps. A redirected stdin and every spec stdin (StringIO,
pipe, plain Object) still fail the `#raw`/`#tty?` guards.

The commit-time ack cannot know whether the note will still be in time, so a
note still pending when a turn ENDS is dropped, not carried: `call_llm` discards
it at the final-answer return (it could no longer steer that answer, kind
`:late`) and `SessionManager#run_prompt` discards anything left over from a turn
that died mid-loop before a NEW prompt starts (kind `:leftover`), each via
`Harness#discard_pending_user_note` with a `#note` warn line naming the case
AND the note text, so the user knows WHICH steering line to resend (issue
#430; #450). `/retry` deliberately keeps a pending note - it continues the
same turn. A note is therefore scoped to its own turn: the
user re-sends it with the next prompt if they still mean it.

Because nothing else is ever parked on stdin, dialogs served by this same loop
route their tty choice line through the SAME `UI::Editor`: one code path,
nothing to race for the keyboard. See also
`doc/reline_cursor_and_enter_handling.md` for the editor mechanics.
