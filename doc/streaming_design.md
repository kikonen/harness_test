# Streaming LLM responses (issue #28)

Design notes for the streamed request path: `lib/llm/base_backend.rb`
(`#chat_streamed` and its helpers) plus `lib/llm/stream_reader.rb`,
`stream_decoder.rb`, `stream_accumulator.rb`, `stream_preview.rb` and
`stream_error.rb`.

Transport behavior below was measured on Ruby 4.0.1 (2026-01-13) against a
local chunked-response server (probes kept in `tmp/keep/28/` while issue #28 is
open) and is asserted end-to-end by `spec/lib/llm/base_backend_streaming_spec.rb`,
which runs a REAL chunked HTTP server rather than a stubbed response object.
Claims that come from the API reference rather than from a probe are marked.

---

## What streaming is for, and what it is not

Streaming exists so the user sees the answer while the model writes it.

It is NOT a second response format. Both paths return the identical normalized
shape (`{ choices: [{ message: { role:, content:, reasoning:, tool_calls: } }],
usage: {...} }`), so `Harness#call_llm` - the tool loop, usage accounting, the
session chain, compaction - is untouched by the choice. That is the invariant
the whole design is built around: streaming is a TRANSPORT decision, and the
transport is where it stays.

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

## Who decides per request

`BaseBackend#chat(..., stream:, on_delta:)` takes the decision from its CALLER:
a backend holds NO posture of its own. That is what keeps the advisory calls
buffered - `SafetyCheck.run` and the `/compact` summary call `chat` without the
flag, so they keep the full retry policy and have nothing to show live.
`stream: false` is the default, so a server or proxy that mishandles a streamed
response needs no config at all.

## Files (transport half)

```
lib/llm/base_backend.rb       chat / chat_buffered / chat_streamed + retry policy
lib/llm/stream_reader.rb      chunks -> complete lines (byte-level split)
lib/llm/stream_decoder.rb     lines -> payloads (SSE + NDJSON)
lib/llm/stream_accumulator.rb payloads -> the normalized response
lib/llm/stream_error.rb       StreamError / StreamStatusError
```

## Known limits

- A streamed turn that dies mid-stream is NOT resumable: the turn fails and
  `/retry` re-sends the request from the last committed round (issue #208's
  trail), which is a NEW generation. That is the accepted cost of showing text
  as it arrives.
- Streaming is per-request, so a turn that mixes a streamed answer with an
  advisory buffered check shows only the answer live. That is intentional.
