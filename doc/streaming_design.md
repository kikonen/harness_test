# Streaming LLM responses (issue #28)

Design notes for the streamed request path: `lib/llm/base_backend.rb`
(`#chat_streamed` and its helpers) plus `lib/llm/stream_reader.rb`,
`stream_decoder.rb`, `stream_accumulator.rb`, `stream_preview.rb` and
`stream_error.rb`, and the posture that drives them
(`Harness#stream?`, `Harness#request_chain`, `/stream`).

Transport behavior below was measured on Ruby 4.0.1 (2026-10-20) against a local
chunked-response server, and it is asserted end-to-end by
`spec/lib/llm/base_backend_streaming_spec.rb`, which runs a REAL chunked HTTP
server rather than a stubbed response object - that spec IS the surviving probe,
the probe scripts themselves were scratch and went with issue #28.
Claims that come from the API reference rather than from a measurement are marked.

---

## What streaming is for, and what it is not

Streaming exists so the user sees the answer while the model writes it: the
spinner line carries the newest text of the answer (and the rate it is arriving
at, issue #285) instead of only the context estimate, and the spinner badge reads
`[STREAM]` while the posture is on.

It is NOT a second response format. Both paths return the identical normalized
shape (`{ choices: [{ message: { role:, content:, reasoning:, tool_calls: } }],
usage: {...} }`), so `Harness#call_llm` - the tool loop, usage accounting, the
session chain, compaction - is untouched by the choice. That is the invariant
the whole design is built around: streaming is a TRANSPORT decision, and the
transport is where it stays.

## Who owns the posture

Three layers, one owner each:

- `Harness#stream?` - the user's posture for this session. The config key
  `streaming` (global) or a model profile's own `streaming` key (tri-state:
  true, false, or absent = "the global key decides") sets the initial value;
  `/stream on|off|status` switches it live; `SessionManager#save_session`
  persists it and `Harness#apply_resume_state` restores it, exactly like the
  YOLO posture. It is a harness posture, not conversation state, so
  `Session#restore` never sees it.
- `BaseBackend#chat(..., stream:, on_delta:)` - the per-request decision. A
  backend holds NO posture of its own: the caller passes the flag per request.
  That is what keeps the advisory calls buffered - `SafetyCheck.run` and the
  `/compact` summary call `chat` without the flag, so they keep the full retry
  policy and have nothing to show live.
- `Harness#request_chain` - the only caller that streams. It builds the
  `on_delta` callback for the request in flight and clears the preview in an
  `ensure` block.

`stream: false` is the default at every layer, so a server or proxy that
mishandles a streamed response needs no config at all.

## The posture is read PER REQUEST

`request_chain` reads `stream?` inside the tool loop, once per request, so a
mid-turn `/stream` toggle applies to the NEXT request, not the one already in
flight. The same rule as the Ctrl+A / `/yolo` badges: state is re-read every
frame / every request, never cached for the duration of a turn.

The live tail belongs to ONE request. `@stream_preview` is set at the start of
`request_chain` and cleared in its `ensure` - not after the call - because a
request that FAILED mid-stream would otherwise leave a partial answer's tail
set, and the next request (a `/retry`, or the next turn) would show text from an
answer that never completed.

## Transport facts that shaped the code

Measured on Ruby 4.0.1 against a chunked server:

- `resp.read_body { |chunk| ... }` yields chunks AS THEY ARRIVE (three parts
  flushed 0.15 s apart arrived at t=0.00, 0.15, 0.30), and each chunk is
  BINARY-tagged.
- `read_body` WITHOUT a block returns the whole body as a String even inside a
  request block, and `resp.body` inside a request block is a String too. So the
  buffered path stays block-free and unchanged; only the streamed path uses a
  block.
- A chunk boundary can split a UTF-8 character across two chunks. It can NEVER
  split one across two LINES, because 0x0A does not occur inside a multi-byte
  UTF-8 sequence.
- Raising inside the `read_body` block surfaces as the raised error class
  (measured: `IOError`), so a consumer-side failure is not masked as a transport
  error.
- Closing the connection mid-stream ends the read; `StreamAccumulator#started?`
  then reports what (if anything) had arrived.

## Line splitting: bytes first, text per complete line

`StreamReader` keeps a BINARY buffer and cuts on `index("\n")` - not `split`
(`split` drops a terminated trailing line, which is exactly how a stream usually
ends). Bytes accumulate until a newline completes a line, and normalization
(`TextNormalizer`, `doc/encoding_design.md`) runs per COMPLETE line. That order
is the point: a chunk boundary may cut a character in half, but the halves are
re-joined in the buffer before anything decodes them, so a valid multi-byte
character is never mangled. Bytes that genuinely cannot be represented become
one `?` each (measured: an incomplete 2-byte sequence and a lone 0xC3 each
yield exactly one `?`).

A CRLF transport leaves the `\r` on the line; it is stripped before the payload
is parsed, because a trailing `\r` is not content.

`pending_bytes` exists for transport accounting only (the log line's byte count).

## Framing: SSE and NDJSON, one decoder

Both supported endpoints are covered by `StreamDecoder`, so no backend has
streaming code of its own:

- SSE (OpenAI-compatible): `data: {...}`, `data: [DONE]`, plus the non-payload
  fields `event:` / `id:` / `retry:` and `:` comments.
- NDJSON (native `/api/chat`): one JSON object per line.

A line that carries no payload - blank, a field line, an unparseable fragment -
yields nil and the stream continues. A stream must not abort on one odd line,
the same way the buffered path does not abort on a response field it does not
understand. After `[DONE]` everything is ignored (`done?`).

## Folding deltas back into the normalized shape

`StreamAccumulator` reads both wire shapes exactly like `BaseBackend#usage_for`
already reads both usage shapes: OpenAI nests the answer in
`choices[0].delta`, the native endpoint puts `message` at the top level.

- Content: `delta.content`; reasoning: `reasoning_content` (OpenAI-style) or
  `thinking` (native). An empty-string delta is a real delta (servers send it
  as the first chunk) but contributes no text.
- Tool calls are keyed so fragments of the same call land together: OpenAI
  streams them piece by piece with an `index`, the native endpoint sends
  complete calls keyed by `id`. Arguments arrive either as String fragments
  (concatenated) or as a complete Hash (stringified) - both end up as the
  String `execute_tool_call` expects.
- Usage: the OpenAI `usage` object or the native top-level `prompt_eval_count`
  / `eval_count`. A streamed usage block often omits `total_tokens`, and a zero
  total reads as "no tokens" in the stats line, so it is derived. Without
  `stream_options: {include_usage: true}` the OpenAI schema reports NO usage at
  all on a streamed response (OpenAI API reference, not measured against our
  local endpoint), which would silently cost the harness its token accounting
  for every streamed turn - that is why `OpenaiBackend#build_body` sends it. The
  native endpoint reports the eval counts on the final line either way, so
  `OllamaBackend` needs no extra field.
  The optional performance fields ride the same final chunk (llama.cpp attaches
  its `timings` to the last delta, the native endpoint reports its Metrics on
  the done line) - `StreamAccumulator` keeps them until the usage is assembled,
  so the normalized response is identical to the buffered path's (issue #251,
  `doc/llm_stats.md`).
- Finish reason: `choices[0].finish_reason` (OpenAI SSE) or `done_reason`
  (native NDJSON), and a bare `done: true` line with no reason maps to
  `"stop"`. It goes into the normalized response as the top-level
  `finish_reason`; what the harness does with it is `doc/truncation_design.md`
  (issue #345), not this doc.

## The retry boundary (the cost of streaming)

The buffered path retries a transient failure or a 5xx unconditionally: nothing
has been shown, so re-sending is free.

A streamed request may only be re-sent while NOTHING has arrived. Once a delta
has reached the caller, re-sending would duplicate or contradict an answer the
user already saw, and the server may already have charged for the generation.
So `next_attempt_or_raise` checks `StreamAccumulator#started?`:

```
nothing arrived  -> retry (same policy as buffered: 5xx and transport errors)
partial answer   -> LLM::StreamError (an LLMError) - the turn fails, loudly
```

`StreamError` is an `LLMError` subclass, so every existing handler of a lost turn
(`Task`'s error path, `/retry`) works unchanged; the distinct class exists so the
log and the message can say WHY it was not retried.

A non-2xx on the streamed path arrives before any answer, so it is reported as
`StreamStatusError` carrying the server's body: a 5xx is retried, a 4xx is
terminal (issue #215 - the body goes to harness.log, not only to the console).

Each attempt builds a FRESH transport: a mid-stream abort closes the connection,
so a keep-alive session cannot be reused after one. The request body itself is
built once and re-sent byte-identically.

## Where the live text goes: the spinner suffix, not stdout

The task thread never writes to an IO stream (the single-thread I/O rule,
`doc/task_design.md`). So a delta is not printed - it is published as state:

```
task thread (on_delta)  -> StreamPreview#record  -> one frozen [tail, dropped?, rate]
main thread (spinner)   -> Harness#request_wait_suffix -> tail_line / live_rate
```

`SessionManager#request_spinner_detail` hands the spinner the harness's callable
(`request_wait_suffix`). While text is streaming it returns the newest text plus
the rate that text arrived at; before that (prefill) and in buffered mode it
returns `context_indicator_live` plus the rate of the request that last
completed. The spinner evaluates it on every drain frame, so both update without
any extra event on the outbox.

### A tool call being written is NOT text arriving (issue #368)

While the model streams a tool call, `content` / `reasoning` produce NOTHING: the
tool call's arguments arrive as `tool_calls` fragments instead. The tail therefore
stops moving, and the line the user reads is the last reasoning sentence with a rate
that DECAYS frame by frame (measured: 17.4 -> 8.7 -> 5.8 -> 4.3 tok/s over four
fragments), because elapsed advances while no text arrives. That renders as a
connection dying, and it is not one.

So the phase replaces the tail. `StreamAccumulator#feed` reports
`tool_call_names` for ANY chunk that carried tool-call fragments (the NAMES only,
never the arguments: for a file.write the arguments are the whole file and the
consumer draws one line), `StreamPreview` keeps them STICKY for the request (a
later fragment carries no name - the phase is what matters, not the last chunk),
and `#tool_call_line` renders "writing tool call: <names>" with the live context
estimate and **no rate** (the decaying number is the exact reading this segment
exists to remove). `Harness#streaming_wait_line` puts the phase FIRST: when one is
published, the tail is not shown at all.

`StreamPreview` publishes a FROZEN snapshot into one slot rather than appending
to a shared String: the writer is the task thread, the reader is the main thread,
and a reference assignment is atomic where an in-place append is not. The reader
only ever sees a whole snapshot.

The tail is 60 characters of the NEWEST text (`MAX_TAIL`), newlines collapsed to
spaces (a spinner line is one line), with a leading `…` (`TAIL_MARKER`) when it is
a tail. The oldest part is what gets dropped. `MAX_TAIL` is the width of the whole
SEGMENT the spinner draws, the marker counted INSIDE it: a truncated tail is
always exactly 60 characters, so the rate segment and the posture badges drawn
after it never shift (the same reason the rate number keeps its own column, below).

The marker REPLACES what the cut left at the seam (`CUT_SEAM`) instead of being
prepended, and it is one character rather than three dots. The 59-character cut
lands wherever the answer happens to be, and an answer that wrote its own ellipsis
can leave the tail of it (plus the blanks after it) as the kept text's FIRST
characters; prepending `...` there read as `"... ... The bottom` / `.... The
bottom` - dots that look like content and are none. A single `…` that is always
the segment's first character cannot be mistaken for the answer's text, and it
cannot collide with the message's own `...` either (the spinner draws
`message... <suffix>`). Dots FURTHER INSIDE the tail are the answer's own writing
and are left exactly as it wrote them. The order matters: slice to the text budget,
THEN replace the seam, then pad back to it - padding before the strip is what left
a dot glued to the marker, and stripping without padding is what made the segment
jitter by 1-2 characters.

The truncation decision is made against the source ACTUALLY shown, so text that was
never dropped is never marked as if it were: an answer whose REASONING overflowed
but whose own content is short shows its content plain, with no marker.

## The live rate (issue #285)

A tok/s reading on the spinner line cannot wait for the server: a server reports
its own timings only on the LAST chunk of a stream (`doc/llm_stats.md`), and a
buffered or unsupported server reports none at all. So while text is arriving the
rate is measured HERE - `StreamPreview` takes its clock on the FIRST delta and
divides the estimated token count by the seconds since, publishing the rate in the
same snapshot update as the tail so the reader never recomputes from counters the
writer is mutating.

Two labels carry the honesty of the number:

* `~` - the tokens are ESTIMATED from the stream's characters (`chars_per_token`
  is injected from `Session::EST_CHARS_PER_TOKEN`, the same ratio the context
  estimate uses, so the two agree instead of each having its own magic number). A
  server-measured rate gets no `~`.
* `(last)` - the rate describes the request that ALREADY finished, shown during
  the next request's prefill or in buffered mode. A rate for the request in flight
  is never tagged, and a rate of a past request is never shown untagged as if it
  were the current one.

`UsageStats::MIN_RATE_TOKENS` / `MIN_RATE_SECONDS` keep the reading off the line
until there is a real window to measure: the first deltas of an answer, or a
request that finished in a few milliseconds, are noise, not a speed. The clock
starts at the first delta because prefill (processing the prompt, producing no
text) is not generation - a construction-based clock would divide by the prefill
too and report a speed far below the truth.

## A rate column that does not move (issue #364)

The rate is the slot redrawn every frame, so its WIDTH is part of its contract.
`format_rate` (the log / stats-line / `/session` form) drops a trailing `.0`, and
a number that changes width between frames - `9` then `38.0` then `9` - shifts
whatever is drawn after it (the `(last)` tag, the posture badges) and reads as
jumping. The spinner therefore asks for `format_stable_rate`: one decimal ALWAYS
and a leading space reserving the tens column, so every rate up to 99.9 is
exactly `STABLE_RATE_WIDTH` characters (`" 9.0"`, `"99.9"`). Above that band the
number grows naturally (`"292.3"` is 5 characters) - padding a wider number would
only pretend it is smaller. Only the number is padded: the `~` marker and the
unit text ride outside the column, so a `~`-marked segment is one character wider
but still width-stable frame to frame. `pad:` is the spinner's request only; a
log line names the same rate unpadded, because prose does not have a column.

A padded segment survives only if the spinner keeps it: the suffix resolution
strips TRAILING blanks (slack) and must keep a LEADING one (content), and every
frame erases the line before drawing it, because `"\r"` alone returns the cursor
to column 0 without erasing and any SHORTER frame would leave the previous one's
tail visible. Both are per-frame, not per-segment: the badge, the elapsed label
and the rate can each shorten independently.

## Files

```
lib/llm/base_backend.rb        chat / chat_buffered / chat_streamed + retry policy
lib/llm/stream_reader.rb       chunks -> complete lines (byte-level split)
lib/llm/stream_decoder.rb      lines -> payloads (SSE + NDJSON)
lib/llm/stream_accumulator.rb  payloads -> the normalized response
lib/llm/stream_preview.rb      deltas -> the spinner's live tail + live rate (cross-thread)
lib/llm/stream_error.rb        StreamError / StreamStatusError
lib/commands/stream_command.rb /stream on|off|status (toggle)
```

On the harness side: `stream?` / `stream=` / `toggle_stream` /
`stream_mode_label` / `stream_preview_line` / `request_wait_suffix` /
`last_rate_segment` / `record_last_rate` and the private `request_chain` (its own
per-request clock) / `streaming_wait_line` / `waiting_line` own the posture, the
live tail and the recent rate; `Task.mode_badge` renders the `[STREAM]` tag next
to the consent-mode tag, both re-read per frame.

## Known limits

- A streamed turn that dies mid-stream is NOT resumable: the turn fails and
  `/retry` re-sends the request from the last committed round (issue #208's
  trail), which is a NEW generation. That is the accepted cost of showing text
  as it arrives.
- The tail is a display convenience, not a transcript: 60 characters of the
  newest text (59 of them plus the marker once text was dropped), discarded when
  the request ends. The full answer is logged and
  stored by the normal path.
- Streaming is per-request, so a turn that mixes a streamed answer with an
  advisory buffered check shows only the answer live. That is intentional.
