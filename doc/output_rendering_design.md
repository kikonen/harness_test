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
| `:plan` | the reasoning digest | `plan:  I will read the tool first` (wrapped to RULE_WIDTH, continuation aligned under the label; #485) |
| `:interstitial` | the model's interim text | `say:   checking one more site` (wrapped like `:plan`) |
| `:tool_plan` | the tool names | `tools: file.read, file.search` |
| `:response` | the model's answer | fused gray rule + answer verbatim ("Block boundaries") |
| `:warn` | a recovered failure | `warn:  auto-save failed: EACCES` |
| `:error` | a real error | `error: hunk did not apply` |
| `:status_ok` ... `:status_info` | the verdict's message | `  [label] ✓ message` (see below) |
| `:ack` | the badge word | `  [YOLO ON]` (bracketed ack, unpainted; issue #466) |
| `:kind` | the message after the kind | `  [LLM error] rate limited` (bracket names a kind, unpainted; #466) |
| `:note` | ONE or MORE unwrapped paragraphs | each re-wrapped to a fixed width, indented (harness prose, unpainted; #470) |
| `:list` | a structured payload `{ title:, kind:, columns:, items:, footer:, gap: }` | rows laid out from the FIELDS (bullet `  - v`, arrow `  a -> b @ c`, kv `  n - d`, numbered_kv `  N. n - d`, table rendered as a markdown table via kramdown); footer indents from its LEVEL; unpainted; #474 |
| `:system`, `:text`, `:stats`, `:compact` | unchanged | verbatim (see below) |
| `:rule` | the rule line the emitter drew | content verbatim, painted with the palette `rule` role (see below) |
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

The verdict column feeds `Tool.status_type` (verdict `:note` becomes the TYPE
`:status_note`); it is NOT the `:note` ROLE of the table above. A verdict always
carries the bracket + glyph; the `:note` role is a wrapped paragraph with neither.

`Tool#status(verdict, message)` is the emitter API (the bracket label is the
tool's own name); `Tool.push_status(label:, verdict:, message:)` is the same
thing for the emitters that are NOT tools - the shell runner (`run.command` /
bang `shell`), the grant reports (`access`), the safety pre-check (`safety`)
and the harness's own note ack. A slash command states a verdict through
`TaskRunner#emit_status(label:, verdict:, message:)`, which is the same event on
a live task and the same rendered line on the main thread; the store commands
(`memory`, `plans`, `skills`) name the store as the origin for a refused name or
a missing entry. `:info` deliberately has no glyph: a count or
a progress line is not a verdict about an operation.

`/clear` is the case that shows the distinction: a revocation that removed
something is `:ok`, and a store that was already empty is `:info`, because
"nothing to remove" reports the state of the store rather than an outcome.

**One buffer entry, one OR MORE console lines.** A status message can be
multi-line (a pasted multiline script is the everyday case). The renderer puts a
`  |` gutter on every continuation line and closes the entry with a short gray
rule, so where a command block ENDS is visible instead of blurring into the
next entry. The gutter and the rule are renderer output only: the buffer still
holds the single plain message.

The main-thread bang path renders the SAME pattern itself (`CommandRunner#renderer`,
asking the harness for the palette) so `! cmd` and the tool path look identical.

## Harness prose: the wrap is the renderer's too (issue #470)

Command report bodies were the last pattern an EMITTER owned after #466 - not the
label, but the LINE BREAK. A posture command wrote its prose as Ruby source
continuations:

    @ui.puts "  Responses stream in: the spinner shows the answer as it " \
      "arrives with the rate ... the idle " \
      "prompt line (issue #387)."

The break column is then whatever the author happened to type, so the paragraph
reads ragged and, worse, a remote/browser client receives a string already chopped
at a column it cannot change. `:note` moves the wrap here too: the emitter states
ONE or MORE unwrapped paragraphs with NO leading indent, and `#note_line` re-wraps
each to a fixed width and indents every line. UNPAINTED (`NOTE` has no palette
entry): only the wrap/indent move, so no line changes color.

The wrap width is the constant `NOTE_WIDTH` (= `RULE_WIDTH - INDENT`), NOT the
terminal width - the same reason `RULE_WIDTH` is fixed: a paragraph that re-wraps
on every resize is as unlocatable as a boundary that moves. A word wider than the
wrap gets its own line rather than being split mid-word (a command name or URL is
one token).

**A whole report body is ONE note call.** `emit_role(:note, ...)` accepts an ARRAY
of paragraphs; `TaskRunner#status_event` newline-joins them into ONE event, and
`#note_line` lays out every paragraph of it. So a contiguous run of a report's
prose (what / why / how, an imperative pointer, and a standalone labeled sentence
like `Current model: ...`, `Table width basis: ...`, or the `Saved with the session
... / Startup choice: ...` tail) is a single `:note` block, NOT a `:note` line
beside an `@ui.puts` line. A report split across the two mechanisms is what makes
classification indefensible: an adjacent sentence and label become different
mechanisms for an arbitrary reason (whether a string was concatenated), and the
same sentence classifies differently across commands. Folding a contiguous run
into one array removes that arbitrariness.

The only thing a block stays verbatim `@ui.puts` for is when **its value IS its
column alignment**: a multi-row aligned block (role groups `plan=34 warn=38`,
`name - desc` rows, usage columns). Word-wrap
would destroy that alignment, so those are the note array's
boundaries. A `Heading: value` line with NO columns to align is not such a block -
it is prose, and folds into the array. A genuinely tabular block with named
columns (the param listing, the server, tool and session reports) moves onto the
structured `:list`/`:table` role (see the next section) instead: the column
boundaries then survive as DATA that a browser can re-lay out, rather than as a
fused row string. The remaining aligned tables move onto it incrementally.

The `/palette` role groups were listed here as alignment blocks and are not: a
`heading: role=code role=code` line pads nothing (the codes print unpainted), and
the longest is already past 80 columns. The rule above would make them prose, but
the legend is the only part of that report that was genuinely tabular - its
name/description pairs were a real padded block, and those moved to `:table`, so
the alignment is now kramdown's column sizing rather than baked spaces. The role
groups stay verbatim for now.



## Structured list/table reports (issue #474)

`:list` is the groundwork that closes the "fused row string" half of #474. A
command report states the DATA - `{ title:, kind:, columns:, items:, footer:,
gap: }` where `items` are Hashes keyed by the column names - and `UI::Renderer#list_line`
draws the rows from those fields. A kind per report shape:

- `:bullet` `  - value` - `/grant` hosts, the command-prefix lists, the `/yolo`
  denylist examples and the `/mcp` collision names. Its title renders at level 0
  and its items at level 1, so a block that was nested deeper inside a prose
  report (header at level 1, rows at level 2) RE-INDENTS when it converts - it
  was never byte-identical. A single-field list has no column alignment to
  preserve, so it is structure rather than an alignment block and converts; the
  `/mcp` names gained the dash the renderer owns.
- `:arrow` `  name -> target @ location` - `/models`
- `:kv` `  name - description` (+ optional `annotation`) - `/skills`, `/memory`
- `:numbered_kv` `  N. name - description` (+ `annotation`) - `/plans`; the
  ordinal is a named `number` field, right-aligned by the renderer to the width
  of the largest (the `format("%{w}d")` alignment moved out of the emitter)
- `:table` - `/sessions`, the `/param` and `/model` parameter listing, the
  `/mcp` and `/tools` tool listings, `/session` (its field/value rows) and the
  `/grant` store lists (number, path, annotation - the ordinal is a field the
  payload carries, so the number is no longer baked into the row string). The
  `/grant` lists were the last numbered rows kept for their alignment; only the
  ordinal was aligned, so they are a table rather than an alignment block;
  the payload's `columns` array IS the schema and a cell is read BY NAME from the
  item. The renderer states the fields as a **markdown table** and hands it to
  the kramdown `MarkdownRenderer` (#106), which owns the column sizing and
  word-wrap - the harness does NOT re-invent padding here. The table is built
  with the renderer's `markdown_max_width` basis even when markdown opt-in is
  off, so a configured width (`--markdown-width` / `markdown_max_width:`)
  constrains it (clamped to the terminal, else 80% of it). A colored sink gets
  kramdown's bordered box table; a sink with no palette (a plain console, a
  spec) gets the raw markdown itself, the re-lay-out-able table form the buffer
  keeps. A multi-paragraph cell (an MCP description - servers send real prose)
  is EXPANDED into simulated rows, one per paragraph, the item's name on its
  first row and a blank continuation cell after (`#table_rows` /
  `#cell_paragraphs`), because kramdown-ansi cannot stack paragraphs in one
  cell; a single-paragraph cell stays one row, so `/sessions` is unchanged. See
  `#table_lines` / `#markdown_table`.

`:table` goes through kramdown rather than a harness-side layout on purpose.
kramdown is the markdown engine already in the repo (issue #106) and it has TWO
backends: the ANSI one the colored terminal uses (the bordered box table) and its
HTML output (a real `<table>`). The markdown the harness builds for the terminal is
the same form a remote/browser sink turns into a genuine HTML table, so #474's
deferred remote half reuses this data with no second table engine and no harness
layout in either direction - the reason a markdown table (not a hand-padded row)
is the right carrier.

The renderer owns the indent and the join glyphs, reproducing the old `@ui.puts`
rows byte-for-byte (no terminal regression). UNPAINTED like `:note`: only the
layout moves, so a colored or plain console prints identical bytes.

A row's fields are read BY NAME (`LIST_KIND_FIELDS`: bullet `value`, arrow
`name`/`model`/`location` plus an optional `note`), never by reading the `columns`
array by position - so a payload that lists its columns in a different order
renders the same row. The `columns` array is only checked to confirm it NAMES the
kind's required fields; an unknown kind or missing field is a loud diagnostic,
never a garbled or field-dropping row (the same #146 rule ` [untyped:...]` follows).

A footer line carries an indent LEVEL, not baked leading spaces: a footer entry
is `{ text:, indent: n }` (or a plain String at level 0) and `#footer_line` turns
the level into columns (`INDENT * n`) for the terminal. A browser maps the same
level to CSS margin. Baked leading spaces are fragile the moment a sink is not a
fixed-width monospace grid (a variable-width font, HTML collapsing leading
whitespace) - so the level is the only form that survives being re-laid out, the
same #146 rule the rows follow.

The point of `:list` is not the terminal (a terminal was already fine with the
string) - it is that the field boundaries no longer die at the emitter. The
payload is stored in the run record as the structure, so `Harness#record_report_output`
puts the Hash (not a rendered line) into the `OutputBuffer`, it survives the
save -> resume JSON round trip symbol-keyed, and `print_resume_replay` redraws
it through the renderer. A future remote sink lays out a real list/table from
the fields instead of regexing the separators back out (#146's forbidden
machinery). The browser/SSE side is the deliberately-deferred half of #474.

The `OutputBuffer` stores the RAW paragraph, not the wrapped lines - so a browser
can re-wrap it in CSS (issue #146 / the #324 remote client) instead of inheriting
this terminal's column choice. `spec/lib/ui/renderer_spec.rb` pins the wrap width
and the unpainted-ness; `spec/lib/task_runner_spec.rb` pins that an array is ONE
joined note block.

## What is deliberately NOT moved yet

`:text` (command output, `/compact` report lines) and the bracketed `:system` /
`:stats` / `:compact` notes are rendered VERBATIM: their emitters still own the
indentation and the `[...]` wrapper. `VERBATIM` in `UI::Renderer` is the exact
list of what is still emitter-shaped.

A `:rule` joins that list for one reason: the content IS the dashes the emitter drew,
so the emitter still owns the shape. The type exists to make the rule COLORABLE -
the palette has always had a `rule` role, but no type could name it, so a rule the
emitter wrote could never be painted. `#segment(:rule, ...)` was reachable only
inside `status_line` / `boundary_line`. The store-command headers (`/memory`,
`/plans`, `/skills`) and the `/reasoning` rules now go through it, so they paint
with the same role as every other rule; plain and no-palette output is unchanged.

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
