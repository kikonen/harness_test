# Output rendering: which layer owns the pattern

Why an output event carries a ROLE and nothing else, and why the label (and
the color, issue #303) is decided by `lib/ui/renderer.rb` instead of
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
| `:step_label` | the iteration NUMBER | fused gray rule (see "Block boundaries") |
| `:plan` | the reasoning digest | `plan:  I will read the tool first` |
| `:interstitial` | the model's interim text | `say:   checking one more site` |
| `:tool_plan` | the tool names | `tools: file.read, file.search` |
| `:response` | the model's answer | fused gray rule + answer verbatim ("Block boundaries") |
| `:warn` | a recovered failure | `warn:  auto-save failed: EACCES` |
| `:error` | a real error | `error: hunk did not apply` |
| `:status_ok` ... `:status_info` | the verdict's message | `  [label] ✓ message` (see below) |
| `:system`, `:text`, `:stats`, `:compact` | unchanged | verbatim (see below) |
| `:spinner_detail` | the spinner payload | no line at all (animated) |

`:warn` and `:error` are now separated by whether the turn survived, not by
which object caught the exception: three compaction/auto-save failures that
only cost bookkeeping moved from `:error` to `:warn`, because rendering a
recoverable bookkeeping failure in the alert color reads as a broken turn.

## Status lines: the verdict is the type, the bracket is the origin

Tool and command status lines were the last pattern an EMITTER owned: 83 call
sites (measured) wrote the whole line - indent, bracket and glyph included -
`Tool.puts "  [file.read] ✓ #{shown}"`, and pushed it as `:text`, i.e. as the
renderer's VERBATIM list: 60 in the tools themselves, 9 grant reports in
`file_list`, 12 shell-runner lines in `command_runner`, 2 harness notes.
Coloring `✓` differently from `✗` was therefore impossible without regexing the
glyph back out of the string, the exact machinery commit 1 removed for `:step`.

They are now typed by VERDICT and the label travels in the event's ORIGIN:

| verdict | type | glyph | rendered line |
| --- | --- | --- | --- |
| `:ok` | `:status_ok` | `✓` | `  [file.read] ✓ lib/foo.rb` |
| `:fail` | `:status_fail` | `✗` | `  [file.read] ✗ lib/foo.rb (not found)` |
| `:warn` | `:status_warn` | `⚠` | `  [dir.delete] ⚠ no harness attached - ...` |
| `:note` | `:status_note` | `!` | `  [file.write] ! lib/foo.rb (line endings repaired)` |
| `:same` | `:status_same` | `=` | `  [dir.create] = tmp/ (already exists)` |
| `:info` | `:status_info` | none | `  [tools.list] 12 tool(s)` |

`Tool#status(verdict, message)` is the emitter API (the bracket label is the
tool's own name); `Tool.push_status(label:, verdict:, message:)` is the same
thing for the emitters that are NOT tools - the shell runner (`run.command` /
bang `shell`), the grant reports (`access`), the safety pre-check (`safety`)
and the harness's own note ack. `:info` deliberately has no glyph: a count or
a progress line is not a verdict about an operation.

**One buffer entry, one OR MORE console lines.** A status message can be
multi-line (a pasted multiline script is the everyday case). The renderer puts a
`  |` gutter on every continuation line and closes the entry with a short gray
rule, so where a command block ENDS is visible instead of blurring into the
next entry. The gutter and the rule are renderer output only: the buffer still
holds the single plain message.

The main-thread bang path renders the SAME pattern itself (`CommandRunner#renderer`,
asking the harness for the palette) so `! cmd` and the tool path look identical.

## What is deliberately NOT moved yet

`:text` (command output, `/compact` report lines) and the bracketed `:system` /
`:stats` / `:compact` notes are rendered VERBATIM: their emitters still own the
indentation and the `[...]` wrapper. `VERBATIM` in `UI::Renderer` is the exact
list of what is still emitter-shaped.

Task's own main-thread acks (`  [note] got it - ...`, `  [YOLO ON]`,
`  [mode is now ...]`) are still hand-written to ui + buffer as `:text`, so
they are not colorable by type and the buffer content is not the printed line
(`commit_note` stores `"note received: ..."`). They sit in the note plumbing the
gesture-dispatch refactor (issue #267) already marks as a HACK.

## Unknown types are loud

A type in neither list renders its content followed by ` [untyped:name]`.
#146 asked for this explicitly: a new output kind must announce itself until a
label is written for it, otherwise a silently unstyled line looks like a
renderer bug.

## Palettes (issue #303)

`UI::Palette` maps a ROLE to SGR parameters; `nil` means "the terminal's own
color". `UI::Renderer` composes them: label first, then color around the whole
line with a trailing reset, so a color can never bleed into the next line.

A status line is TWO runs, not one: the bracket/gutter/rule is the recessive
`marker` / `rule` role and the message carries the verdict's own hue. Both runs
are individually wrapped and reset, so the two-tone line cannot bleed either.

**Color lands on the console line only.** `store_and_render` asks the renderer
for the line it prints and puts the ROLE CONTENT (no escape bytes, no label)
into the `OutputBuffer`. That is load-bearing for #146: the buffer is the
durable, re-renderable record, and a color baked into it is permanent.
`spec/lib/task_spec.rb` asserts exactly this (console colored, buffer plain).

Three named palettes, `default` in use unless told otherwise:

| name | idea |
| --- | --- |
| `default` | hues from the dark 16-color band (30..36) + a real dark gray and a brown from the extended ramp |
| `basic16` | same roles, but every code stays inside 30..37: for a terminal that renders only a 16-color palette, and recessive roles fall back to the terminal's own color |
| `none` | nothing colored (`--no-color` selects it) |

Resolution order is `-p/--palette NAME` > config `output_palette:` > `default`.
The CLI validates the name at parse time, so a typo is reported before the
model is contacted (`--list-sessions`, which never builds a Harness, validates
too). `Harness#output_palette` resolves it ONCE at construction: the drain loop
must not re-resolve a name per rendered line.

### Switching it mid-session: `/palette`

`/palette` reports the current palette and its colored roles; `/palette <name>`
switches it for the rest of the session. The name is validated in
`Harness#output_palette=`, not in the command, so every route (CLI flag, config
key, `/palette`, resume) goes through the same check, and `options` keeps the
name so a mid-run Harness rebuild reproduces it.

The switch takes effect FROM THE NEXT TURN: a Task builds its `UI::Renderer`
once at `Task#run`, so a turn already draining keeps the palette it started
with. The command prints a sample line through the same renderer to make the
change visible at once.

The choice is saved with the session as the palette NAME (never the SGR codes)
and restored on resume; a stored name this build does not have falls back to
`default` instead of raising, because only a name the user typed has to be
valid, whereas a stored one only has to be usable.

**There is no tty probe.** On this setup a piped `$stdout.tty?` is false even
when the user's terminal understands SGR (the spinner has printed raw
`\e[2K` unconditionally since issue #125), so an auto-detecting gate would
silently disable the feature in exactly the setup it was built for. The switch
is explicit instead.

## Block boundaries

Two roles are boundaries of a BLOCK rather than lines inside one, and they get
the SAME shape - `BOUNDARY_ROLES` in `UI::Renderer` is that decision written as
a list:

- `:step_label` IS its rule: the number sits fused inside it, exactly 80
  columns whatever the number is.

    ------------------------------------ step 8 ------------------------------------

- `:response` gets the rule as its own line, naming the role, and the answer
  below it EXACTLY as emitted - no label, no indent, so a model answer keeps
  its own paragraphs and indentation.

    ------------------------------------ model -------------------------------------
    Done. The palette now colors three roles.

    Two things to check in your terminal:
      - the gray bracket vs the green command text

`plan` / `say` / `tools` / `warn` / `error` deliberately keep their plain label:
they are lines INSIDE a block, and giving them a full-width rule too would make
the boundary say nothing.

The complaint this answers: neither a turn's iterations nor where its answer
began could be found by looking at the output at all. Bold was measured as not
perceptible on this terminal, so the boundary's differentiator is SHAPE: the
rules, gray. `:step_label` adds a HUE on the number it fuses; `:response` does
not, because the palette must leave `:response` uncolored for the answer text
itself to stay in the terminal's own color - the renderer paints the rule and
the fused word with the same role code. The width is a constant (`RULE_WIDTH`),
not the terminal width: a boundary that depends on a terminal setting is one
that moves.

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
- ...but a gray is a DE-EMPHASIZER, never a highlight. Measured again while
  fixing issue #388: the owner could not see `38;5;240` in a dialog's option
  list at all ("so close to normal text that it is not visible"). A role the eye
  has to LOCATE in a list - a dialog's option NUMBER - therefore needs a band
  hue, not `marker`. Recessive roles stay correct for what they always were:
  decoration (a bracket, a gutter, a rule).
