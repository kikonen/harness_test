# SafetyCheck: the pre-dialog command safety check, and how a verdict is bound

Verified against `lib/safety_check.rb`, `lib/command_runner.rb` and
`lib/harness.rb` on master-branch commits of 2026-10-26 (ruby 4.0.7, RuboCop
1.92). Issue #224 built the check; issue #344 fixed the
binding. Repro: `analysis/344/repro.rb`.

## What the check is, and what it is for

Before the confirmation dialog for an unapproved `run.command`, the harness may
ask the model - in a FORK of the current conversation - whether the command(s)
look safe (`command_safety_check`, an opt-in config key). The verdict is advisory
text in the dialog; it never widens the allowlist and never bypasses the user's
Allow. It has exactly two consumers:

- `CommandRunner#prepend_safety_verdict` shows it as `MODEL VERDICT (advisory):`
  in the consent dialog;
- `CommandRunner#auto_approve_safe?` decides whether a `safe:` verdict skips the
  dialog entirely in the AUTO-APPROVE posture.

The second is the reason the binding matters. This is the only place where model
output is presented to the user as a fact about a command they are about to run,
and a wrong `safe:` label is not cosmetic there - it is what makes the harness
run without asking. The disaster denylist still catches `rm -rf` and friends, but
the commands a mis-binding corrupts are precisely the unapproved ones the check
exists to inform.

## Purity contract (critical)

`SafetyCheck` is a free function over a plain chain array and a client. It NEVER
touches Session, Harness state or the Task, so it cannot trigger in-loop
compaction, prompt-token anchoring (the spinner ctx estimate), auto-save or any
session mutation. Do not route it through `Harness#call_llm` - that loop owns all
of those. The only sink it may write to is a logger the CALLER injects, and only
for the reason a verdict was dropped.

It runs BEFORE the dialog opens, so it never competes for the single stdin owner
(#198): it is an HTTP call, not a dialog. Any failure - LLM error, blank answer,
an answer that cannot be placed - yields no verdict, and consent proceeds exactly
as it would have without the check.

## Why the fork is cheap (local-LLM KV caching)

- The fork is a byte-identical PREFIX of the live chain, truncated at the last
  COMPLETE round: `truncate_for_check` drops the trailing assistant tool_calls
  message whose tool results do not exist yet (the dialog fires exactly at that
  point, mid tool loop) because backends reject tool_calls without their results.
  The whole prefix is therefore a cache hit, and only the short check question is
  new prefill. The caller's array is never mutated.
- "Prefix" is about the RENDERED prompt, and a chat template renders the tool
  definitions into it too, so the chain alone is not enough: `run` takes a
  `tools:` payload and both callers pass `Harness#tools_payload` - the same
  definitions the live turn sent. A fork that omits them is a different prompt,
  not a longer one, and re-prefills cold (issue #246, measured there:
  `doc/compaction_cache_design.md`; this was issue #238's cache reset).
- The fork is disposable and SHARED: a batch of several unapproved `run.command`
  calls is covered by ONE check call, one verdict line per command
  (`Harness#precheck_batch_safety`), not one call per command.
- The main conversation's cache is NOT evicted: the fork's prefix IS the main
  prefix, so the next real turn re-prefills only the one dropped assistant
  tool_call message.

## The bug the binding used to have (issue #344)

`run` did `lines[idx] -> commands[idx]`: line position was the ONLY identity a
verdict had. The old prompt numbered the COMMANDS in the question (`1. cmd`) but
demanded an unnumbered answer (`"safe: <short reason>"`, "EXACTLY one line per
command (same order)") and nothing verified either the count or the shape.
Measured (see `analysis/344/repro.rb`):

```
answer:  "Here are my verdicts:\nsafe: syntax check\ndangerous: deletes files"
commands: ["ruby -c a.rb", "rm -rf /tmp/x"]
result:  {"ruby -c a.rb" => "Here are my verdicts:",
          "rm -rf /tmp/x" => "safe: syntax check"}
```

The destructive command is labelled `safe:` and, under AUTO-APPROVE, that label
auto-approves it. Its real verdict was discarded because there was no third slot.
A preamble line is the single most common thing a chat model does, so this was a
question of *when*, not *if*.

The same code had a second, independent half (also measured, same script): a
model that echoed the numbering of the list it was shown - `1: safe: ...`, the
natural thing to do when the commands are numbered for it - had its verdict
stored VERBATIM, `"1: safe: syntax check"`, which `auto_approve_safe?`
(`/\Asafe:/`) can never match. So the ordinal-carrying answer silently disabled
AUTO-APPROVE for every command, while the answer with no ordinals at all kept it
alive - on the wrong command. The fix takes the ordinal the model already offers
and makes it the binding.

## The rule now: identity by ordinal, position only as a fallback

The prompt renders the commands **numbered** and demands that the answer name the
number back (`1: safe: <reason>`). The ordinal is the only identity a verdict
line carries, so it is what survives a preamble line or an out-of-order answer:

| Answer (2 commands) | Result |
|---|---|
| `1: safe: a` + `2: dangerous: b` | both verdicts, ordinal-matched |
| `2: dangerous: b` + `1: safe: a` (reversed order) | both verdicts, still correct |
| preamble + `1: safe: a` + `2: dangerous: b` | both verdicts; the preamble is dropped |
| `1: safe: a` twice (duplicate ordinal) | ordinal 1 has NO verdict |
| `3: safe: c` (ordinal names no command) | dropped |
| `safe: a` + `safe: b` (no ordinals, count exact) | positional fallback |
| `safe: a` (one unnumbered line, two commands) | NO verdicts |
| preamble + `safe: a` + `safe: b` | NO verdicts - the issue #344 symptom |
| `safe: a`, `safe: b`, `safe: c` (three lines, two commands) | NO verdicts |

Position is consulted **only** when the whole answer is unnumbered, every line is
a well-formed verdict, and the counts match exactly - i.e. only in the one case
where position is provably the same information an ordinal would carry. Anything
ambiguous is dropped rather than guessed.

`VERDICT_LINE` is the shape test: an optional ordinal (`1:`, `1.`, `1)`, `1 `),
then `safe:` or `dangerous:` (case-insensitive, rebuilt **lowercase** because the
consumer matches the exact `safe:` prefix), then a non-empty reason. A line that
is not that shape is not a verdict, so `auto_approve_safe?` never sees a
half-sentence like `not really safe, just checking` as a verdict at all - which
is also why a verdict stored by `run` always starts with `safe:` or `dangerous:`.

The reason text is kept **verbatim** (the advisory value is in the model's
wording); only the kind is normalized, and the ordinal prefix is removed. That is
what makes the compliant answer work in AUTO-APPROVE again.

## Degrade, and audit the degrade

`nil` already meant "no verdict - plain dialog", so an unverifiable answer returns
all-nil and nothing else changes: the dialog opens exactly as it would have
without the check. A failed check must never break the consent flow.

Because "no verdict" is now produced by a *decision* (a dropped line) rather than
only by a network error, `run` takes an optional `logger:` and writes one line
per CHECK (all the drop reasons joined) - measured output for the preamble
answer: `safety check: line "Here are my verdicts:" carries no safe:/dangerous:
shape; 2 unnumbered verdict line(s) cannot be placed`. Both consumers pass their
harness logger in. The purity contract (above) forbids SafetyCheck from touching
Session, Harness or the Task - an injected logger is the only sink it may write
to, and it is inert without one. Without this line, "AUTO-APPROVE silently
stopped approving" would be the symptom and harness.log would have nothing to
say about it.

The same reasoning covers the answer's SHAPE, not only a dropped line. Because
the fork carries the live tool payload (issue #246, above), the model can answer
with a tool call instead of verdict lines; the prompt says "Do NOT call any
tools" but that is a request, not a guarantee. When no text comes back, `run`
logs `safety check: no verdict lines (answer was a tool call: run.command)`
(or `(answer was blank)`), because that no-verdict state is a model behaviour
that will otherwise look like a broken check. The calls in such an answer are
never parsed and never executed - the fork has no tool loop.

## When the check actually runs, per posture (issue #382)

Which of the two call sites runs is a posture question, and the two sites are not
interchangeable:

| posture | a batch of >= 2 unapproved `run.command` | a single call | a DENYLISTED command |
|---|---|---|---|
| MANUAL | batch pre-check | check in `CommandRunner#run` | check in `CommandRunner#run` |
| AUTO-APPROVE | batch pre-check | check in `CommandRunner#run` | check in `CommandRunner#run`, verdict shown, never acted on |
| YOLO | **skipped** | skipped | check in `CommandRunner#run`, verdict shown, never acted on |

`Harness#precheck_batch_safety` skips YOLO because YOLO's auto-approval branch
returns before `safety_verdict_for` is reached: batch verdicts written there
could only be thrown away, so the batch would pay a forked round trip (and print
"checking N commands before the consent dialog...") for a dialog that never
opens. The skip is logged (`safety pre-check skipped (YOLO consumes no verdicts)`).

The denylist path is the one YOLO case that does check, and that is deliberate:
the verdict is the first note line on a dialog the model cannot clear, so the
verdict can be judged against a command the denylist already refuses. Showing it
changes nothing about who may run what - the floor and `auto_approve_safe?` are
untouched - and it is pinned for all three postures in `spec/lib/command_runner_spec.rb`.

## Not changed by #344

- The denylist floor: a disaster command reaches the dialog in every posture,
  whatever the model says (`README.md`, access model). #389 later made that
  floor relaxable for a real `safe:` verdict, config-only and logged -
  `doc/denylist_safe_approve_design.md`. Neither change touches `disaster?`
  detection.
- The fork/truncation contract and the KV-cache reasoning (the two sections
  above; `lib/safety_check.rb` now carries the invariants only).
- `auto_approve_safe?` itself: the matching rule stays `\Asafe:`. #344 made the
  input it receives trustworthy; it did not loosen the test.
