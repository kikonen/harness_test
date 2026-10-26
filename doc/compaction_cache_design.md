# Compaction, safety forks, and the prompt prefix cache (issue #246)

Why every advisory fork - the two compact summary calls and the command safety
check - sends the FULL chain AND the live turn's own tool definitions. Verified
against `lib/` on the `fix/issue-246-compact-prefix-cache` branch on Windows
(ruby 4.0.7 x64-mingw-ucrt); CI runs on ubuntu-latest.

## The rule

A prompt-prefix cache (llama.cpp, Ollama, and the OpenAI-compatible servers that
report `prompt_tokens_details.cached_tokens`) matches the prompt from token 0. A
request is cheap only while it is a byte-identical EXTENSION of a prompt the
server has already prefilled. The prompt a server prefills is the RENDERED one,
and a chat template renders BOTH of these into it:

1. the message chain, starting at message 0 (the system message);
2. the tool definitions, when the request sends any.

So a fork has to match on both axes. `Harness#tools_payload` is the single
source of the tool definitions, and the three advisory callers now send it:

| request | chain | tools |
| --- | --- | --- |
| live turn (`Harness#call_llm`) | `session.messages` | `tools_payload` |
| `SessionManager#generate_compact_summary` (both compact paths) | the chain AS IS | `tools_payload` |
| `SafetyCheck.run` (both callers) | `truncate_for_check(chain)` | caller's `tools:` |

## Why it was expensive before: measured, on a live server

From a real session's `harness.log` (2026-10-23, an OpenAI-compatible endpoint,
`num_ctx` 140K-ish). In-loop compaction, taken straight from the log:

```
22:02:18 REQ: POST .../v1/chat/completions (385358 bytes, attempt 1/3, streaming)
22:02:18 RESP: ... 113587 -> 738 tokens              (the live turn's round)
22:02:18 REQ: POST .../v1/chat/completions (359048 bytes, attempt 1/3)
22:03:40 RESP: ... 107347 -> 1976 tokens   [INFO] in-loop compaction: 259 -> 4
             timings: {"cache_n": 0, "prompt_n": 107347, "prompt_ms": 59016.3}
22:03:40 REQ: POST .../v1/chat/completions (33413 bytes, attempt 1/3, streaming)
22:03:47 RESP: ... 8312 -> 107 tokens                 (post-compaction turn)
```

The summary request got `cache_n: 0` on a 107 347-token prompt: 59.0 s of prefill
inside an 82.2 s request. The turn that followed compaction was prefilled from
the 4-message chain in 6.9 s. The compaction itself cost more than the rest of
the turn, and the server reported zero reuse.

That is the shape the harness-side half explains, in order of how much they cost:

- **`messages[1..]` at the whole prompt's largest moment.** Both compact paths
  sliced the system message off, so index 0 changed role. Nothing prefilled could
  be reused: the call was a DIFFERENT prompt, not a longer one.
- **`tools: nil` on both forks while the live turn sends 32 definitions
  (21 075 B here).** Even with the chain fixed, the rendered prompt diverged at
  the tools region, so the prefix still broke. This is the half the first commit
  of this issue missed - and the half that also applies to the safety fork, which
  is issue **#238**'s subject ("auto approve (safe check) resets context cache").
- **`SafetyCheck`'s chain half was already fine.** `truncate_for_check` drops the
  unresolved assistant tool_calls message, which is exactly the one message
  appended after the request that just ran, so the fork's MESSAGES are that
  request plus one question. Only its `tools: nil` broke the prefix - which is
  why #238's cache reset persisted even though its prefix reasoning was right.
- **A buffered request builds a fresh `KeepAliveHTTP` per call**
  (`BaseBackend#chat_buffered`), so the HTTP connection is not reused either -
  unlike `chat_streamed`, which calls `.start`. Whether this matters to a
  server-side slot cache is untested; it is listed because it is the remaining
  known difference between the two paths, not because it was measured.

## What the forks cost now

`estimate_tokens` counts message CONTENT only, so the harness' own estimate never
sees the tools region the server tokenizes - a 21 075 B tools payload is invisible
to it (~5269 est tokens at `EST_CHARS_PER_TOKEN = 4`).

The headroom question that stopped the first commit was framed wrong. The live
turn ALREADY pays for system + tools in its own `prompt_tokens`, and
`context_used` compares THAT number to the trigger (57 344 at the default
`LLM::NUM_CTX = 65_536`: `min(88 % of window, window - 8192 reserved)`). The
summary call is the same prompt plus one user message of 394-441 chars - a few
tokens of new prefill, not a fresh system + tools bill. A 500-word summary cap
(`compact_max_size`) keeps its completion bounded.

New failure mode, handled: sending tools lets the model answer a summary request
with a tool call instead of text. Both instructions now say "Do NOT call any
tools - answer with text only" (the safety prompt already said it), and
`generate_compact_summary` reports the shape it actually got: a tool-call answer
with no text raises naming the tool(s) (in-loop compaction degrades to keeping
the chain), and a text-plus-tool-calls answer keeps the text and logs the ignored
calls. Those tool calls are never executed - the fork has no tool loop.

## Why the fork payload cannot be a subset (the tempting wrong optimization)

Sending the summary call a SMALLER tool set is the obvious way to pay for the
tools region, and it is exactly what breaks the cache: a subset is a different
payload, and a different payload is a different rendered prompt - the same failure
`tools: nil` had. For a prefix hit the fork's payload must be byte-identical to
the payload of the request the fork extends, so `Harness#tools_payload` is shared
by all of them rather than tuned per fork.

What CAN be limited is the payload EVERY request pays, and the numbers say where
the bulk of it is (this project's 32 tools): 21 075 B total = ~5269 est tokens,
split ~310 B names / 9572 B descriptions / 8796 B parameter schemas. Trimming
descriptions is therefore the lever that shrinks every request at once while
keeping all requests identical to each other - a separate decision about what the
model is allowed to know, not a compaction decision, and it would free window
space at the trigger too (`compact_reserved_tokens` exists because the summary
call needs room).

## Measuring it

`ruby analysis/246/repro.rb` (no server needed) builds a real `Harness` with this
project's real `harness.md` and reports, for `#compact_session`,
`#check_inloop_compaction` and `SafetyCheck.run`, whether each fork's chain is a
byte-identical extension and whether its tools payload equals the live turn's. It
exits non-zero when either axis fails, so the tools half cannot regress silently.

`sh analysis/246/measure.sh` states what the harness can and cannot answer and
runs the live-server A/B: send a long prompt, then a prefix-extension of it with
tools sent, with tools omitted, and with message 0 dropped, comparing
`prompt_tokens_details.cached_tokens` / `prompt_eval_cached_count` (surfaced as
"N cached" on the stats line and in the `RESP:` log line since #251).

## Not proven by this change

Whether the owner's server actually speeds up. `prompt_tokens` is the server's
count for its OWN rendered prompt; only the cached-count fields say what was
reused, and there is no model server in a checkout (`127.0.0.1:11434` / `:8080`
are refused). The harness-side precondition is now satisfied on both axes and
pinned by specs; the speed claim belongs to `measure.sh` on a live server.

`doc/safety_check_design.md` and `doc/truncation_design.md` describe the fork
contract these changes touch.
