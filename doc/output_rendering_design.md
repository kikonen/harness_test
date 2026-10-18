# Output rendering: which layer owns the pattern

Why an output event carries a ROLE and nothing else, and why the label (and
from issue #303 on, the color) is decided by `lib/ui/renderer.rb` instead of
being written into the string by the emitter. Issues #303 / #146.

---

## The rule

An emitter states ONE role's content. `UI::Renderer#line` decides how the user
sees it. The `OutputBuffer` stores the role content, never the formatted line.

That separation is what makes the durable record re-renderable: a future TUI
(#146) can render the same entries as blocks, folds or colors, because the
record does not contain this week's label wording.

## Before: one type carrying four roles

`Harness#print_step_display` emitted ONE type (`:step`) for four different
things, and baked the pattern into every string:

    Task.emit(:step, content: "[step #{iteration}]")
    Task.emit(:step, content: ">>> #{reason} <<<")
    Task.emit(:step, content: "||| #{content} |||")
    Task.emit(:step, content: "    -> #{tools.join(', ')}")

A renderer given those entries has one way to tell them apart: **regex the
markers back out**. That was measured while prototyping the color layer for
#303 - the prototype could only color `plan` differently from `tools` by
matching `/\A>>> /` on the content, which is precisely the machinery a renderer
must not have.

`session_manager.rb` did the same for the response block: three buffer entries
(`"=" * 80`, the content, `"-" * 80`) where the framing is two lines of
decoration that a renderer can produce itself.

## After: one role per event

| type | emitted content | rendered line |
| --- | --- | --- |
| `:step_label` | the iteration NUMBER | `step 3` |
| `:plan` | the reasoning digest | `plan:  I will read the tool first` |
| `:interstitial` | the model's interim text | `say:   checking one more site` |
| `:tool_plan` | the tool names | `tools: file.read, file.search` |
| `:response` | the model's answer | `model: Done.` |
| `:warn` | a recovered failure | `warn:  auto-save failed: EACCES` |
| `:error` | a real error | `error: hunk did not apply` |
| `:system`, `:text`, `:stats`, `:compact` | unchanged | verbatim (see below) |
| `:spinner_detail` | the spinner payload | no line at all (animated) |

`:warn` and `:error` are now separated by whether the turn survived, not by
which object caught the exception: three compaction/auto-save failures that
only cost bookkeeping moved from `:error` to `:warn`, because rendering a
recoverable bookkeeping failure in the alert color reads as a broken turn.

## What is deliberately NOT moved yet

`:text` (tool status lines, command output) and the bracketed `:system` /
`:stats` / `:compact` notes are rendered VERBATIM: their emitters still own the
indentation and the `[...]` wrapper. Moving those into the renderer is the rest
of #146 and touches every tool, so it is tracked there rather than smuggled
into this change. `VERBATIM` in `UI::Renderer` is the exact list of what is
still emitter-shaped.

## Unknown types are loud

A type in neither list renders its content followed by ` [untyped:name]`.
#146 asked for this explicitly: a new output kind must announce itself until a
label is written for it, otherwise a silently unstyled line looks like a
renderer bug.

## Terminal measurements (measured on the owner's setup, light background)

Recorded here because they constrain any palette (#303), and because they
contradict the obvious choices:

- The 16-color "bright" band is unusable there: 97 invisible, 93 unreadable as
  text, 37 and 92 barely readable.
- 90 (dim) and 2 (faint) look IDENTICAL and both read as light gray, so the
  16-color band has no usable way to de-emphasize a line at all.
- Background colors (41) were reported 100% unreadable.
- Bold was not perceptible, so bold can never be the only differentiator: every
  distinction must be a HUE.
- 256-color and truecolor both work: `38;5;240` reads as a dark gray and
  `38;5;130` as a readable brown/orange, which is what recessive lines and
  warnings need on a light background.
