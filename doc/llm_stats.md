# Response performance stats (issue #251)

The harness already logged what IT could measure: request bytes, per-attempt
duration and the token counts (`RESP:` in harness.log, the `📊` part of the
stats line). Issue #251 asks for what the SERVER measured instead - a server
knows how much of the prompt it re-used from its KV cache and how long each
phase took, and neither is inferable from the client's wall clock.

`LLM::UsageStats` (lib/llm/usage_stats.rb) is the single place that names
these fields. It normalizes them from either wire shape and formats them; the
backends only hand it the parsed JSON.

## The rule: normalize what the server actually sent

Every extended key is OPTIONAL and appears only when the response carried it.
Zero-valued fields are dropped (a cache miss is not a measurement), malformed
ones are dropped, and nothing is ever derived from a field the server did not
report. The three core keys (`prompt_tokens`, `completion_tokens`,
`total_tokens`) are unchanged: `Harness#call_llm` sums them and compaction /
`/ctx` read them, so the arithmetic that decides a compaction is untouched.

## Wire names, and where each was read

Verified against upstream sources on 2026-10-24 (no live local server here -
the specs' fixtures are synthesized from these published shapes, which is why
they are quoted here rather than "measured").

### Native Ollama `POST /api/chat` (ollama/ollama, `api/types.go`, `Metrics`)

| wire field | on the wire | normalized to |
| --- | --- | --- |
| `prompt_eval_cached_count` | int | `cached_tokens` |
| `prompt_eval_duration` | integer **nanoseconds** | `prompt_eval_ms` |
| `eval_duration` | integer **nanoseconds** | `eval_ms` |

`docs/api.md` states the nanosecond unit and gives the rate recipe
(`eval_count / eval_duration * 10^9`), and its own example body carries
`"prompt_eval_duration": 130079000`. `api.Duration.MarshalJSON` marshals a Go
duration as a string ("1m2.5s"), and that form belongs to the `keep_alive`
REQUEST field - but because the type is the same, `duration_ms` accepts the
string form too rather than betting on one marshal path. `total_duration` and
`load_duration` are deliberately not read: they cover model loading and the
whole request, not the phase the harness would act on.

### llama.cpp `POST /v1/chat/completions` (ggml-org/llama.cpp, master)

`tools/server/server-task.cpp` `usage_json_oaicompat()` adds
`usage.prompt_tokens_details.cached_tokens`; the same file attaches a
`timings` object to the response (`stats.to_json()`, on the LAST chunk when
streaming). `tools/server/server-common.cpp` `server_slot_stats::to_json()`
is what `timings` holds:

| `timings` field | normalized to |
| --- | --- |
| `prompt_ms` | `prompt_eval_ms` |
| `predicted_ms` | `eval_ms` |
| `prompt_per_second` | `prompt_tokens_per_second` |
| `predicted_per_second` | `completion_tokens_per_second` |
| `draft_n`, `draft_n_accepted` | kept as-is (speculative decoding) |

`cache_n`, `prompt_n`, `predicted_n` and the per-token columns are NOT read:
each is another route to a number already normalized (cached count, token
counts, one token divided by a duration), and keeping the server's rate is a
single-source decision - a reported rate wins over a derived one.
`draft_n`/`draft_n_accepted` appear only when drafting is on, so they are
shown as a pair or not at all.

Ollama's `/v1` shim (`openai/openai.go`) produces the same
`prompt_tokens_details.cached_tokens` on the OpenAI shape, so one reader
covers both endpoints.

## The prompt rate uses the UNCACHED prompt tokens

`prompt_eval_duration` is the time over the tokens the server actually
processed, and `prompt_eval_cached_count` / `cache_n` say how many it skipped.
Dividing the whole `prompt_tokens` by that duration overstates the speed by
exactly the cache hit, so `uncached_prompt_tokens` does the subtraction both
servers do in their own CLIs (`ollama` prints `prompt eval rate` from
`(PromptEvalCount - cached) / PromptEvalDuration`; llama.cpp's `prompt_n` is
the processed count). A cache hit therefore shows up as "N cached", not as a
prompt that got mysteriously fast.

## Per-request numbers never get summed

Cache depth and durations describe ONE request. A turn is a loop of requests,
and summing their cache depths would report a total no measurement supports.
`performance_snapshot` therefore captures one response's performance with its
own token counts riding along (a rate is never displayed next to another
request's counts), and `Harness#call_llm` keeps the LAST request's snapshot -
the last call describes the cache state the next request will face, which is
the same reason `last_prompt_tokens` is not summed (issue #81).

`stats[:performance]` (nil when the server reported nothing) travels into
`Session#record_stats` and is saved with the session, so /session after a
resume still reports the last measured turn.

## Where it surfaces

- harness.log `RESP:` line: `... in 4.21s - 1000 -> 50 tokens | 768 cached |
  prompt 565.2 tok/s | gen 38.2 tok/s`. When the response reported neither
  counts nor performance the note is empty, exactly as before.
- stats line (`⏱ … | 🔄 … | 📊 … | ⚡ 768 cached | prompt 200 tok/s | gen 38.2
  tok/s | ctx`) - the `⚡` part is absent when nothing was measured.
- `/session` last-request line, same fragments.

Related: #285 wants a live tok/s in the spinner. That needs a rate DURING the
request, which only a streamed transport can provide; this issue only fixes
what is recorded once the response is in, and the normalized keys above are
the vocabulary such a spinner would read.
