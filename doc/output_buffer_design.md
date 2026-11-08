# OutputBuffer: structured output design

Design notes for `lib/output_buffer.rb` - the append-only record of everything
the harness shows the user (single-thread I/O rule).

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

## Ownership

The buffer is owned by the TASK (one per Task instance - see `Task#buffer`).
The DRAIN LOOP fills it (one put per output event it reads from the outbox);
task-thread code NEVER touches the buffer directly. A future TUI can read the
buffer as a durable, inspectable record of everything shown to the user.

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

- `NON_REPLAY` (`:spinner_detail`) is never replayed: it is an animated spinner
  re-point, never a console line, so it is not part of the durable record.
- `#keep_tail(n)` keeps the run record a WINDOW (default 30 entries, config
  `resume: replay_entries:`; 0 disables the whole path). The read waterline is
  pulled back when a window drop removes already-consumed entries, so a later
  drain still yields what survived.
- A session saved by an older build (or with 0 entries) has no tail to redraw;
  the banner then prints nothing.

