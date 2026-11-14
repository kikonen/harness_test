# OutputBuffer: structured output design

Design notes for `lib/output_buffer.rb` - the append-only record of everything
the harness shows the user, split into the two parts a per-task buffer needs
(issue #286). Single-thread I/O rule.

---

## The key idea

Task-thread code NEVER writes to an IO stream. Instead it appends a typed,
origin-tagged entry to the buffer. The main thread (the CLI drain loop, and
later a TUI) advances a read waterline (`#drain`) and renders whatever is new.
This replaces fire-and-forget "puts to stdout" with a durable, inspectable log
of `{type, origin, content}` blobs:

- `type` - what KIND of output this is (`:response`, `:stats`, `:plan`,
  `:status_ok`, `:system`, `:error`, ...), so a renderer can style it distinctly.
- `origin` - WHERE it came from (`:session_manager`, `:harness`, ...). For a
  STATUS entry it is the tool or caller NAME (`"file.read"`, `"run.command"`,
  `"access"`): the bracket label a renderer needs in order to rebuild the line.
- `content` - the text itself. A status entry may hold a MULTI-LINE message (a
  pasted multiline command); the renderer turns that into several console lines
  with a gutter, but the entry stays ONE plain string.

## Two parts: tail and head (issue #286)

The record and the live view are not the same thing, and once several tasks run
at once they cannot share one list. The buffer is therefore two parts:

- **tail** - the durable history. Append-only, `Entry` objects,
  **IMMUTABLE BY CONSTRUCTION**. This is the half a renderer can re-lay out: a
  remote page refreshed later redraws from the tail, so the tail must never hold
  a string already chopped for today's terminal.
- **head** - the live state of the streams still arriving: one mutable cell per
  stream, replaced as it grows. A stream cell is the WHOLE stream so far, so a
  refresh reads it as one snapshot instead of rebuilding it from a pile of
  chunks. Immutability holds for the **tail only**; a head cell is mutable on
  purpose.

`#put` decides the part by the mode the CALLER states (`HEAD_MODES`): a live
update says `mode: :append` (the content arrives in chunks) or `mode: :replace`
(a re-point of the live status). A call with no mode states a FINAL item and is
committed to the tail. That is the invariant that keeps the split honest: **the
head must never be the only copy of an answer.** `HEAD_TYPES`
(`:spinner_detail`) is the type that is transient by nature and lands in the
head with no mode, so the drain loop keeps its old call shape.

Head cells are keyed by **`(origin, type)`** (owner decision, 2026-11-14),
resolved through the drain-loop binding. A single task can hold SEVERAL head
cells live at once - the spinner cell AND the LLM streamed-response cell, both
from `:session_manager` - so origin alone is not enough: it would collapse those
two streams into one cell. `#cell(origin, type)` reads one stream;
`#commit(origin, type)` promotes that one cell to the tail.

The task is the OUTER part of the key, not a field inside `@head` (owner,
2026-11-14): in the unified model (#286) each task owns its own `OutputBuffer`,
so a head cell's full identity is `(task, origin, type)` where `task` is supplied
by WHICH BUFFER the cell lives in. A buffer never holds more than one task, so
storing `task` inside each buffer's key would just repeat the buffer name within
itself; the task enters the key at the TaskManager layer that selects which buffer
is foreground.

`#commit(origin, type)` promotes a finished cell to the tail as ONE immutable entry
holding its final content and removes it from the head. A stream that keeps going
after a commit starts a new cell, so the head never holds both the history and
the live view of the same stream.

Polling is per part: the tail has the read waterline (`#drain`), the head has a
per-cell dirty flag (`#dirty_head`) - a replaced cell is not an append, so a
waterline cannot express it. `#pending?` is true when either half has something
new to show. The tail has TWO limits, per buffer and configurable (issue #286):
`max_memory` bounds how much of the tail lives in RAM and gates the
consumed-front trim, `max_saved` is the window a session save writes.
`max_saved <= max_memory`, so the saved window is always inside what memory
holds, and `max_memory` never cuts a PENDING entry - a renderer that polls later
still sees everything it has not read. `max_memory`, `#keep_tail` and `#restore`
apply to the tail only; the head is bounded by its own rule (it is current state,
never an accumulation) and is never windowed.

## Ownership

The buffer is owned by the TASK (one per Task instance - see `Task#buffer`).
The DRAIN LOOP fills it (one put per output event it reads from the outbox);
task-thread code NEVER touches the buffer directly. A future TUI can read the
buffer as a durable, inspectable record of everything shown to the user.

Under the unified task model (issue #286) the split names the owner precisely:
the task owns its HEAD (its live view), the run record holds TAILS only. A
foreground switch is then just a question of which task's head is the shown one,
because every task already has its own head + tail.

## Threading

Main-thread-only access. The task thread communicates through the outbox and
never reaches the buffer; every put/drain in production is driven by the single
drain loop on the main thread. There is therefore no synchronization here - it
would be dead weight. If a future TUI ever reads the buffer from a second thread
while the drain loop writes, put a Mutex back at that point.

## Resume replay (issue #458)

The buffer is the single record of everything the user SAW, so it is what a
RESUMED session redraws: the user's own submitted line is just another entry
(role `:user`, so UI::Renderer labels it), alongside the model/tool side of the
same turn. There is no separate "echo" mechanism - replay is a re-render of the
buffer tail through the same `UI::Renderer` the live drain loop uses, so the
redrawn exchange looks like the original one (labels, colors, markdown posture
all respected).

Ownership at the run level: a Task owns the buffer its turn fills, and the
Harness owns ONE run-level `OutputBuffer` (`#output_log`). After each turn the
Harness harvests the task buffer's replayable tail into it (`#absorb_turn`) and
records each user prompt directly (`#record_user_prompt`). `save_session` writes
that window's tail (`#replay_tail_for_save`, the `Entry#to_h` form) into the
session JSON; a resumed Harness rehydrates it with `OutputBuffer#restore` before
the drain loop first runs, and the CLI banner redraws it.

- Replay reads the **tail** only, so the head is never replayed: a spinner
  re-point and a still-growing stream are live state, not part of the durable
  record. `#absorb_turn` is exactly the tail-half operation.
- `#keep_tail(n)` keeps the run record a WINDOW (default 30 entries, config
  `resume: replay_entries:`; 0 disables the whole path). The read waterline is
  pulled back when a window drop removes already-consumed entries, so a later
  drain still yields what survived.
- A session saved by an older build (or with 0 entries) has no tail to redraw;
  the banner then prints nothing.

