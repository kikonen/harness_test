# Compaction and the prompt prefix cache (issue #246)

Why the compact summary call sends the FULL chain - system message included - and
what it does NOT fix. Verified against master `f105463` on Windows (ruby 4.0.7
x64-mingw-ucrt); CI runs on ubuntu-latest.

## The claim, and the measurement behind it

A prompt-prefix cache (llama.cpp, Ollama, and the OpenAI-compatible servers that
report `prompt_tokens_details.cached_tokens`) matches the prompt from token 0. A
request is therefore cheap only while it is a byte-identical EXTENSION of a prompt
the server has already prefilled.

Both compact paths used to build the summary call as `messages[1..]` - the chain
minus the system message. That is not a shorter version of the live prompt, it is a
DIFFERENT prompt: index 0 changes role, so nothing the server prefilled can be
reused, and the call re-prefills the whole conversation at the exact moment the
conversation is at its largest (auto-compact fires at 88 % of the window,
`Session::AUTO_COMPACT_THRESHOLD`).

`ruby analysis/246/repro.rb` measures the harness-side half of that, with a real
`Harness`, this project's real `harness.md` in the workdir, and a recording client:

| shape | messages | message 0 | request body | tools |
| --- | --- | --- | --- | --- |
| live turn (`Harness#call_llm`) | 6 | `system`, 18 314 chars | 18 849 B | 32 definitions, 21 075 B |
| summary call, `messages[1..]` | 6 | `user`, 603 B body | 603 B | nil |
| summary call, full chain | 7 | `system` | 19 219 B | nil |

So today the summary call shares **no** prefix with the request that preceded it.
With the full chain it is the live chain plus exactly one new user message (the
instruction), which is the same shape `SafetyCheck` already relies on
(`doc/safety_check_design.md`: "the fork's prefix IS the main prefix").

## What the change is

`SessionManager#generate_compact_summary(chain, instruction)` sends the chain AS IS
and appends the instruction as a new trailing user message. Both callers pass the
whole chain now: `compact_session` passes `session.messages`, and
`check_inloop_compaction` passes the live working chain (it had also been slicing
`[1..]`, and its "real work to summarize" guard now counts messages directly:
`return false if messages.size <= 4`).

The summarization INSTRUCTIONS say "the work done, not the system rules you were
given". That wording is not a mechanical guarantee: the exclusion used to be
structural (the system message was physically absent) and is now a request to the
model, bounded by `compact_max_size` (default 500 words). If a model echoes its
rules into the summary, the harness pays for them twice - once inside the summary,
again in the next chain's own system message.

## What it does NOT fix, and why that is the real blocker

Message 0 is only half of a rendered prompt. A chat template renders the TOOL
definitions too, and neither fork sends them: `SafetyCheck#run` calls
`client.chat(fork, tools: nil)` and `generate_compact_summary` calls `chat` without
the flag, while the live turn sends `tool_registry.to_openai` (32 definitions,
21 075 B here). So the *messages* can be a perfect prefix while the *rendered
prompt* still differs from the live turn's at the tools section. That is issue
**#238**'s territory (the other reported cache-resetting consumer), and #246 cannot
be called fixed until it is settled.

Sending the tools on the summary call is not free either, and the arithmetic is the
reason it was not done here. At the default `LLM::NUM_CTX = 65_536`, using
`Session::EST_CHARS_PER_TOKEN = 4`:

| sent | est tokens |
| --- | --- |
| system message | ~4 579 |
| tools payload | ~5 269 |
| both | ~9 848 |
| `Session::COMPACT_RESERVED_TOKENS` | 8 192 |

The system message alone fits the headroom the summary call already reserves;
system + tools does not. So the affordable step is the message prefix, and the
tools question needs its own decision (a smaller tool set for the summary call, a
larger reservation, or accepting a cache miss for correctness).

## The half that cannot be measured in a checkout

There is no model server in a checkout (`127.0.0.1:11434` and `:8080` are refused),
so no claim about actual speed can come from here. `analysis/246/measure.sh` prints
where the chains are built, where the cache-hit fields are read
(`LLM::UsageStats#extended_usage` -> `cached_tokens` / `prompt_eval_cached_count`,
surfaced as "N cached" on the stats line and in the `RESP:` log line since #251), and
then the three live-server runs that answer the question: prefix-extension with
tools omitted, prefix-extension with message 0 dropped, and the same pair with
tools sent. Compare `prompt_eval_cached_count` across the three.

Pinned by `spec/lib/session_manager_spec.rb` ("summarizes the FULL chain, drops the
verbatim tail, and syncs the session"): the captured call is `chain + instruction`,
`captured.first` is the chain's own system message, and the post-compaction chain
shape (`system, summary, ack, continue`) is unchanged.
