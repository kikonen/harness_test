# Task: async turn design

Design notes for `lib/task.rb`: how a turn runs on a background thread while
all console I/O stays on the main thread.

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

Protocol:

```
Task thread -> Main thread: push_event(type:, origin:, content:) [outbox]
Task thread -> Main thread: request(type, **payload)             [outbox, blocking]
Main thread -> Task thread: task.respond(value)                  [inbox]
Main thread (drain loop):   poll outbox, dispatch by type
```

## Structured log

The Task instance owns one OutputBuffer, filled by the drain loop and never
touched by task code - see `doc/output_buffer_design.md`.

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

The spinner's own segments (elapsed turn time, consent-mode badge) come from
the runner too, always as callables: the drain loop rebuilds the spinner
whenever the outbox empties again, so anything the spinner computed itself
would restart on every rebuild. Only the runner knows how long the turn has
been running (issue #277).

## Console injection

`Task.run` REQUIRES a `ui:` (a `UI::Console` wrapping an explicit stdout/stdin
pair). The same console is used for spinner frames, text output, and dialog
prompts so tests can capture everything through a single StringIO-backed
console. It is published on the task instance and passed explicitly to every
I/O call.

## Ctrl+C

While `Task.run` is draining, SIGINT is trapped so an interrupt targets the
drain loop, not a random thread. The task thread is force-stopped (no
background work survives the turn) and the Interrupt is re-raised for the CLI's
cleanup path.

## Mid-turn user notes - no reader thread

Each drain tick PEEKS `stdin.input_pending?` (nil on streams that do not
support it); if the user is at the keyboard the MAIN thread opens a
`UI::Editor` - tty gets Reline multiline (Enter = newline, submit key = one
note, Esc = draft kept, Ctrl-D on an empty buffer = abort the turn), non-tty
gets one line per read (a pipe has no submit key). The note is acked and stored
on the harness (`Harness#user_note_text=`), where `Harness#call_llm` injects it
into the chain before the next LLM call.

Because nothing else is ever parked on stdin, dialogs served by this same loop
route their tty choice line through the SAME `UI::Editor`: one code path,
nothing to race for the keyboard. See also
`doc/reline_cursor_and_enter_handling.md` for the editor mechanics.
