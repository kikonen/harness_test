# Text-shaped tool calls: recovering a call the model wrote as prose (issue #461)

Some models (observed with qwen) emit a tool call as **text** in the answer's
`content` instead of a structured `tool_calls` array, e.g. a `<tool_call>`
wrapper around `<function=NAME>` blocks with `<parameter=KEY>value</parameter>`
bodies. In `Harness#call_llm` the tool round is gated on `message[:tool_calls]`;
a text-shaped call leaves it empty, so the harness took the **final-answer**
branch, committed that pseudo-XML as the assistant's reply, and returned. No tool
ran, no step line appeared, nothing reached the console - the turn just ended.

Claims below marked **(measured)** were run against this repo's tool set /
parser; the harness-side behaviour is asserted by the `#call_llm text-shaped
tool call (issue #461)` examples in `spec/lib/harness_spec.rb`.

---

## The lenient recovery and its one guard

The owner's steer was: *if it looks like XML, parse it and run it, but say out
loud it was not JSON.* So a response with no `tool_calls` but with both a
`TEXT_TOOL_CALL_OPEN` and a `TEXT_TOOL_CALL_CLOSE` marker is parsed by
`Harness#parse_text_tool_calls` into the same synthetic
`[{ id:, function: { name:, arguments: } }]` shape the tool loop already
consumes, and the existing loop then runs it through `execute_tool_call` (so
FileList grants and the CommandRunner consent floor are unchanged).

The single guard against running prose that merely **quotes** a call: a parsed
name only becomes a call when it maps to a registered tool
(`Harness#resolve_text_tool_name`):

- exact registered name (`file.read`) wins first;
- else a **short name** that is unambiguous across the registry (`echo` ->
  `test.echo`) - qwen writes the short form;
- an ambiguous short name (`list` = file.list / tools.list / memory.list /
  plan.list / skills.list; `read`, `delete`, `search`, `add` are likewise
  ambiguous) maps to **nothing**, as does an unknown name.

Unresolved markers never run; they fall through to `report_unresolved_text_tool_call`,
which warns on the console + log so the user sees the model *tried* to act and can
re-prompt. Prose quoting a bogus name is therefore reported, not executed.

---

## Why Nokogiri, not rexml or hand regexes (measured)

The qwen dialect is deliberately **malformed XML**: `<function=NAME>` glues the
name to the tag with `=`, which is not a legal tag name, and real calls arrive
truncated or with unclosed/mismatched tags (issue #332 saw truncated calls). A
small header rewrite (`Harness#normalized_text_call`, `TEXT_EQ_HEADER`) turns
`<function=NAME>` / `<parameter=NAME>` into the parseable `<function name="NAME">`
attribute form, then a real XML parser does the structural work.

Which parser was decided on a probe (issue #461), not on taste. Against the same
normalized input:

- **Nokogiri** (`XML(... ) { |cfg| cfg.recover }`) recovered every shape: the
  `=`-dialect call, a bare `<function=...>` block with no `<tool_call>`
  wrapper, multi-line parameter values, and a **truncated** call whose closing
  tags never arrived.
- **rexml** (stdlib, already in the lock, zero new native dependency) raised
  `REXML::ParseException` on the truncated call and, on another shape, parsed to
  a tree with **no** function element (it silently dropped it) - exactly the
  silent-loss symptom this fix exists to end.

rexml is sufficient only for well-formed documents; recovery is the deciding
property here, and recovery is what Nokogiri has and rexml does not. That is why
the fix commits a native dependency. Nokogiri is required at the top of
`lib/harness.rb` (the same place kramdown-ansi is required), not lazily - a
text-shaped call is rare but the parse must never itself be the thing that
fails.

---

## Synthetic ids stay unique (measured against the registry's short names)

`qwen` re-emits a text call on **every** round of a turn, so recovered calls
accumulate in the committed session chain. Their synthetic ids (`text_call_N`)
must not collide, because a tool result is matched back to its call by
`tool_call_id`. `Harness#next_text_call_index` reads the highest
`text_call_N` already committed in the chain (`TEXT_CALL_ID`) and continues from
one past it, so numbering survives a later round of the same turn, an earlier
turn, and a resumed session.
