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

- `type` - what KIND of output this is (`:response`, `:stats`, `:step`,
  `:system`, `:error`, ...), so a renderer can style it distinctly.
- `origin` - WHERE it came from (`:session_manager`, `:harness`, a tool name,
  ...), so a renderer or future TUI can attribute it.
- `content` - the text itself (a single line; multi-part output is either one
  blob or several entries, in order).

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
