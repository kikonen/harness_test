# Truncation: what a finish reason is for, and what it cannot say (issue #345)

Why the normalized response carries `finish_reason`, what each wire shape
reports, and what `Harness` does with it. Read this before treating a tool
error as "the model wrote a bad call".

Claims below marked **(ref)** come from the Ollama / OpenAI API reference; they
were not measured against our local server. The harness-side behavior is
asserted by `spec/lib/harness_spec.rb`, the plumbing by the `spec/lib/llm/`
specs.

---

## The bug in one line

`StreamAccumulator` read `finish_reason`, exposed it as `attr_reader`, and
`to_response` left it out. `grep -rn "\.finish_reason" lib/ spec/` on master
before this fix returned **nothing**: the reader was never called, and no spec
asserted the value survives. `OpenaiBackend#parse_response` and
`OllamaBackend#parse_response` never looked at it either. A response cut by the
token budget was therefore indistinguishable from a model that wrote a bad
answer - and the model was told only the tool's own validation text, so it
retried the same shape until the tool-loop warn / hard limit broke the pair.
That is the mechanism issue #332 observed (three `ui.dialog` calls in one turn,
two failing with `'options' must be a non-empty array`, the third - with
shorter text - succeeding).

A second gap the issue did not name: on the **native** endpoint the field is
`done_reason` (top level), not `finish_reason`. `grep -rn done_reason lib/ spec/`
returned **nothing** either, so the buffered Ollama path had no reason at all -
not even a value it was throwing away.

## What the servers report (ref)

| endpoint | field | values that matter here |
| --- | --- | --- |
| OpenAI `/v1/chat/completions` | `choices[0].finish_reason` | `stop`, `tool_calls`, `length` |
| native `/api/chat` | `done_reason` (top level) | `stop`, `length` |

`Harness::FINISH_EXPECTED = %w[stop tool_calls]` - the two NORMAL ends.
`length` means the budget ran out. A server may also report `content_filter` or
a value this harness has never seen; anything not in the expected list gets a
line, so an unknown value is visible rather than silently normal.

The streamed native shape also sends a bare `{"done":true}` line; the
accumulator has always mapped that to `"stop"`, and it keeps doing so - a
`done` line that carries no `done_reason` still means the answer ended.

## The normalized shape

`finish_reason` sits at the TOP LEVEL beside `usage`, and is present only when
the server reported one:

```ruby
{ choices: [{ message: { role:, content:, reasoning:, tool_calls: } }],
  usage:   { prompt_tokens:, completion_tokens:, total_tokens: },
  finish_reason: "length" }
```

Top level rather than `choices[0][:finish_reason]` because the two wire shapes
put the value in different places (inside `choices[0]` vs top level), and the
normalized response has exactly one `choices[0]` member of our own making - the
message. A sibling of `usage` is the one slot both paths can fill without
inventing a member; `Harness` already reads `data[:usage]` the same way.

Omitting the key when the server sent nothing is deliberate (the same rule as
`usage`): a spec or a consumer can then tell "no reason reported" from
`finish_reason: nil` meaning "the reason was none".

## What Harness does with it

1. **`report_finish_reason(data, iteration)`**, called once per request in
   `call_llm`. A reason outside `FINISH_EXPECTED` gets `logger.warn` (so it is
   in the session's `harness.log`) AND a `Task.emit(:warn, ...)` line (so it is
   on the console - `:warn` is the existing "the turn survived, but" role in
   `UI::Renderer`, see `doc/output_rendering_design.md`). It returns true only
   for `length`.
2. **The budget is named.** `length` alone is not actionable: the limit is this
   harness' own setting (`max_tokens` on the OpenAI path, `num_predict` on the
   native one, both config- and `/param`-owned). `budget_note` prints the
   reported `completion_tokens` and the configured limit, or says plainly that
   NO limit was configured and the server's default is what cut the answer.
   Nothing compares `completion_tokens` against the limit (that comparison was
   part of #345's symptom); the line only puts both numbers where a reader can
   compare them.
3. **A truncated tool round reports truncation.** When the reason is `length`,
   `execute_tool_call` is called with `truncated: true`: a call whose arguments
   do not parse is then reported as "the response was cut off before this call's
   arguments arrived complete, so the call was NOT executed - re-send it as a
   SMALLER call" instead of the tool's own validation text (or a generic parse
   error). After the round, a `role: "user"` line tells the model the same thing
   once - the injected-message shape the tool-loop warning already uses.
   A call whose arguments parse fine still runs normally: truncation is not a
   reason to refuse a well-formed call.
4. **Not recorded in `stats`.** `finish_reason` is per-request; `stats` is the
   turn's bookkeeping (summed usage, the last request's performance). A turn
   that truncated on request 3 and finished cleanly on request 4 would persist a
   misleading "truncated" tag into the session JSON and a `/resume` would show
   it as the turn's state. The durable record is the warn line in `harness.log`,
   which already names the iteration.

## The silent swallows (issue #332's candidates 2 and 3)

`parse_tool_arguments(raw)` returns `[args, nil]` or `[{}, error_message]`.
Three sites used to rescue straight to `{}`, which erases the difference between
"the model sent no arguments" and "this call lost its shape":

| site | before | after |
| --- | --- | --- |
| `run_command_batch_commands` | `JSON.parse(...) rescue {}` - the command vanished, so a batch of two truncated `run.command` calls was safety pre-checked as ZERO commands | the command is skipped AND `logger.warn` names it |
| `execute_tool_call` | `JSON.parse` raised into the generic `error: <msg>` rescue | the parse error is in the tool result and in `harness.log`, with the truncation branch above |
| `record_note` | `rescue StandardError` to nothing - a `ui.note` whose arguments did not arrive was silently not buffered | the drop is logged, the turn still does not break |

`record_note` keeps its outer `rescue StandardError`: a malformed note must
never break a turn, and that is the point of the swallow - it is the *logging*
that was missing, not the rescue.

## What finish_reason still cannot do

- **It does not prove the content is broken.** `length` says the budget ran out;
  a truncated answer can still be complete in every part the harness looks at.
  That is why the tool result only changes when the arguments ALSO failed to
  parse, and why a well-formed truncated round still executes.
- **The buffered OpenAI path can report nothing.** `parse_response` omits the
  key when the response has no `finish_reason` (a server that never fills it is
  legal in the OpenAI schema). No reason is reported as no reason - it is not
  guessed.
- **A streamed turn lost mid-stream is still `LLM::StreamError`**, not a finish
  reason: no chunk said `length`, the connection did. `doc/streaming_design.md`
  owns that boundary.
- **Only `call_llm` consumes the reason.** `SessionManager#generate_compact_summary`
  and `SafetyCheck.run` call `client.chat` directly, so a truncated summary or a
  truncated verdict answer is still reported by their own checks (an empty summary
  raises - naming a tool-call answer if that is what came back; an unplaceable
  verdict yields no verdict). Both are advisory calls that keep the buffered
  posture, and neither one has a tool round to blame - which is exactly why they
  were left alone rather than given a warn line of their own. Both send the live
  tool payload (#246), so a tool-call answer IS possible; nothing in a fork is
  executed, only its text is used.
- `content_filter` and unknown reasons get the same warn line as `length` but do
  NOT change the tool round: only a budget cut is reported as truncation.
