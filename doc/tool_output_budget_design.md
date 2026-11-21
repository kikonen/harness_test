# Issue #551: the conversation's size gate, and the OVERFLOW it prevents.

A tool result big enough to push the next request past the backend's context
window makes that backend **refuse the whole request** - the harness cannot
recover, because the repair (compaction) is itself a request carrying the same
oversized chain. That is issue #551 and the sibling #503.

---

## Why this exists

Every output cap in the harness counted LINES (`CommandRunner#truncate`,
`GitRunner#truncate_output`, `WebFetchTool#truncate_body`). A line count is not a
size limit: output with few newlines and huge lines - a base64 dump, minified
JSON, a one-line blob - passes a 500-line gate WHOLE. Measured
(`analysis/551/measure.rb`, runs from a fresh clone):

```
5000 short lines     in     48,892 B -> out     4,752 B   truncated? true   (gate works)
500 x 20KB blobs     in 10,000,499 B -> out 10,000,499 B   truncated? false
1 line, 4 MB         in  4,000,000 B -> out  4,000,000 B   truncated? false
1000 x 4KB json      in  4,008,999 B -> out  2,004,609 B   truncated? true (still MBs)
```

The harness also cannot cap the server: `lib/llm/openai_backend.rb:12` records
that the OpenAI-compatible schema has no `num_ctx` and that such requests are
never truncated. So the only enforceable budget is local, applied before a result
becomes a message.

## The shape of the failure (measured, not inferred)

```
HTTP 400: request exceeds the context window: prompt (494588 tokens) leaves no
room to answer in the context (256000); requests are never truncated
```

`SessionManager#send_session` catches it as a context-exceeded error and calls
`compact_session`, which summarizes `@harness.session.messages` - the chain that
still holds the giant tool result - so it fails with the identical 400, and a
manual `/compact` fails the same way. `Session#compact` retains
`conversation.last(recent_count)`, so an oversized message inside the retained
tail survives compaction too. The run is bricked until a message is deleted from
the session file by hand.

## The compromise

1. **BYTES bounded as well as lines, with a per-line clip** -
   `OutputBudget.fit` (`lib/output_budget.rb`). The head+tail line split stays
   (issue #537's win: a runner's failure block is at the tail), and any single
   line over `OVERSIZED_LINE_BYTES` is clipped within itself, head and tail of
   THAT line, on character boundaries via `split_bytes`. `clamp_bytes` then drops
   WHOLE lines if clipping alone did not fit, and the notice names the bytes
   dropped plus what to do about it.
2. **Overflow goes to disk** - `ResultSpill` (`lib/result_spill.rb`) files the
   full text at `.harness/sessions/<id>/jobs/<job>/results/<tool>-<seq>.txt`,
   beside the job that produced it.
3. **The cap is configured, not magic** - `output_result_bytes:` (config-only, no
   CLI flag: the overflow cannot be repaired from inside the run that caused it),
   default `OutputBudget::DEFAULT_RESULT_BYTES`. Read per Harness, because a #286
   sub-agent can run a different profile with a different window.
4. **Reading the overflow back is capped too** - `OutputBudget.read_capped` reads
   a file's head and tail BYTES without ever loading it whole. `FileReadTool`
   uses it on any file over its `byte_budget`, `Harness#read_spilled_result` on
   any spill, and `OutputBudget.log_excerpt` bounds the `tool <name> -> ...` line
   in harness.log. Without this the fix would only move the overflow one step
   later: the model reads its own 4 MB spill whole.

## Why `OVERSIZED_LINE_BYTES` is below the byte budget

`clamp_bytes` drops WHOLE lines. If every line is longer than the byte budget it
keeps nothing. The per-line clip is therefore what catches the single-huge-line
shape, and it has to stay smaller than `DEFAULT_RESULT_BYTES` for that to work -
including for a `file.read` of a minified-JSON file. Lowering
`OVERSIZED_LINE_BYTES` to something "tidy" (4 KB) would start silently shortening
ordinary whole-file reads; that coupling is the reason it is stated here.

## Where the gate sits

`Harness#budget_tool_result` (lib/harness.rb), called from `execute_tool_call`
after `TextNormalizer` and before the result becomes a `role: "tool"` message.
That seam is the last point where the size is still the harness' own decision, and
it covers EVERY tool - `run.command`, `file.read`, `file.search`, `git.*`,
`web.fetch`, MCP text - not only `run.command`. Each tool keeps its own line
limits and its own user-facing `limit` parameter: the byte budget is the outer
bound, not a replacement. A `ToolResult` (MCP image blocks) is left to
ImageDelivery - flattening it here would drop the images (issue #449).

It is deliberately NOT derived from `Session#context_used`: that is the LAST
response's number (issue #81), so mid-turn it is stale relative to the chain the
tool result is about to grow.

## A spill is harness state, so the reader asks its owner

`FileList#sensitive?` blocks `.harness` for every path component (only a scratch
zone and `.harness/skills` are exempt - `SensitiveFiles::SENSITIVE_DIRS`), so
`file.read` cannot open a spill path and no grant can make it readable. The bypass
therefore runs BEFORE the grant dialog: `FileReadTool` asks
`spill_reader` (the Harness, wired by `ToolRegistryBuilder`) via
`read_spilled_result`, which `ResultSpill#covers?` restricts to this job's own
results dir and which refuses a name carrying `..`. Measured in a second session:
a spill path reached `file.read`'s denial first and the bypass was never consulted
- the order is the bug, not the guard.

### A spill read is already capped, so it is not capped again

A spill file is slightly BIGGER than the byte budget, because the "bytes omitted"
notice is added on the way out. So a spill read handed back through
`budget_tool_result` re-fit a text that was already inside the budget: it spilled
the spill (`results/file.read-2.txt`) and `harness.log` reported a cap the model
never received. `ResultSpill::ALREADY_CAPPED_MARK` is what makes such a read
recognisable to the guard, and `FileReadTool` only accepts the bypass result that
carries it.

### The shell is the other way in, and it is not closed

A second session pulled a spilled result into its chain with `cat
.harness/sessions/.../results/...` after `file.read` denied it. A shell is not
path-scoped, so no file-tool rule can refuse that; what limits it is the run.command
consent model (a redirect makes a segment non-auto-approvable, so the recovery route
is an explicit user Allow, not a silent read) plus the byte budget every command
result passes through. `file.list` on a spill dir stays refused: listing harness
state would expose other sessions' and other jobs' files to one job's agent.

## Not done, deliberately

- **No pre-request `MAX_REQUEST_BYTES` gate.** It cannot shrink a chain that is
  already oversized, so it would brick the turn instead of preventing the overflow.
- **No new output-slicing tool.** The cap, the spill pointer, and the existing
  `file.search` / shell pipes cover the recovery path.
- **The cap still runs AFTER the tool produced its result.** A tool-side pre-check
  (`web.fetch` already caps what it fetches; `file.read` now caps what it loads) is
  a separate improvement per tool, not what this increment does.
