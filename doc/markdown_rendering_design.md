# Markdown rendering in the console (issue #106)

Why the assistant's prose is rendered as markdown (headings, bold/italic, code,
tables) with ANSI instead of printed raw, why the feature is opt-in, and how its
colors stay inside the harness' own palette. `lib/ui/markdown_renderer.rb` and
the `MARKDOWN_ROLES` / `boundary_body` branches in `lib/ui/renderer.rb`.

---

## The problem

A model answer is markdown. Printed raw it shows `**bold**`, `#` headings and
pipe tables as literal punctuation - the structure the model chose is visible
only as its source syntax, and a wide pipe table overflows the terminal.

Rendering it means turning that markdown into ANSI the terminal understands.

## Why a gem, and which one

Three options were weighed:

- **tty-markdown** - rejected: its plain (no-color) mode destroys inline
  emphasis, so `**bold**` would be dropped rather than styled. Preserving
  bold/italic/inline code is the whole point of rendering markdown, so a gem
  that discards it on the `--no-color` path fails the requirement.
- **hand-rolled** - rejected: a markdown parser (tables, lists, nested emphasis,
  block quotes) is a large correctness surface for no benefit.
- **kramdown-ansi 0.7.0** - chosen: it preserves inline emphasis, draws rounded
  box tables, uses a `·` bullet, and - decisively - its colored roles are
  configurable, which is what lets the harness keep color ownership (below).

## Color ownership: seed the gem, do not add a second stack

`UI::Palette` is the harness' single color source (issue #303, see
`output_rendering_design.md`). kramdown-ansi colors spans through its own
term-ansicolor tokens, which would be a second, independent color stack.

To keep the "color lives in the renderer" invariant, the gem's colored roles are
SEEDED from the active palette's hues (`HUE_SOURCE`): the markdown `header`
borrows the `step_label` hue (cyan), `code` borrows the `plan` hue (blue). Only
HUES are seeded - the gem's structural attributes (bold, underline, italic) stay
its own defaults, so markdown reads as the same color family as the harness'
lines rather than inventing colors.

A seeding subtlety the code encodes: kramdown-ansi `configure` MERGES the seed
over the gem's default style list, so seeding `header: :cyan` alone would REPLACE
`[bold, underline]` and erase the heading's structure. The renderer therefore
APPENDS the palette token to the gem's own default for that role
(`Array(defaults[role]) + [token]`). An unmapped palette hue (an extended
256-color code with no term-ansicolor name) yields no seed at all, so that role
keeps the gem default rather than a wrong color.

The `none` palette (`--no-color`) has no hues: the render still runs (structure
matters without color) but the escape codes are stripped afterwards, so the
output stays byte-clean. A nil palette (a bare console, a Task with no harness)
returns the text unchanged - there is nothing to seed from.

## Opt-in, default OFF

Rendering is a posture, not a default. `UI::Renderer` takes `markdown:` (default
false); `Harness#markdown?` / `markdown=` / `toggle_markdown` own the posture;
`/markdown [on|off|status]` switches it; `--markdown` and the config `markdown:`
key seed it at startup; the choice is saved with the session and restored on
resume - the same shape as `/palette` (see `output_rendering_design.md`).

Default-off is load-bearing: the `:response`-verbatim invariant (the answer is
printed EXACTLY as emitted) is what every existing renderer spec asserts. Only an
opted-in run renders, so a markdown-off run is byte-for-byte the old output.

Like `/palette`, markdown is an OUTPUT posture: it changes how a line is drawn,
not what the model is asked or allowed to do, so it carries no spinner badge and
never touches the conversation chain. A mid-run toggle lands on the NEXT turn
(a Task builds its renderer once at `Task#run`), exactly as a palette switch does.

## What renders, and what stays byte-exact

Rendering is for MODEL PROSE only:

- `:response` - the final answer, rendered inside its boundary rule
  (`boundary_body`).
- `:plan` and `:interstitial` (`say:`) - in-loop model prose that routinely
  carries bold and lists (`MARKDOWN_ROLES`).

Everything else stays verbatim, byte-exact:

- Tool output (code, logs, diffs) is never rendered - it must be exactly what the
  tool produced.
- `:tool_plan` is a comma-joined tool list, not prose, so it keeps its plain
  label even when markdown is on.
- `:warn` / `:error` are harness messages, not model prose.

### The labeled-prose shape (plan / say)

`:plan` and `:interstitial` are LABELED roles (`plan:  text`), not boundaries,
but their markdown renders multi-line. The chosen shape keeps the block reading
as one labeled entry: the label stays on the FIRST line in the role's color, and
every continuation line is padded to align under the label text. The body carries
the gem's own (palette-seeded) colors; only the label run is painted by the
renderer. A markdown-off run never reaches this branch at all.

## The table-width cap

kramdown-ansi sizes a table from `Tins::Terminal.columns` (90% of it, plus border
overhead). On a wide terminal that is wider than the harness' FIXED 80-column
chrome (`RULE_WIDTH`), so a table overflows the boundary rules around it - the
owner measured a rendered table clearly wider than the terminal.

The fix caps the width the gem sees during OUR render: `MarkdownRenderer`
temporarily overrides `Tins::Terminal.columns` to `min(detected, RULE_WIDTH)`
around the `Kramdown::ANSI.parse` call and restores the original method in an
`ensure`, so the cap is scoped to our render and never global - no other
`Tins::Terminal` caller (the spinner, a future probe) sees it, and the restore
holds even when the parse raises. The cap is passed in from the renderer
(`width: RULE_WIDTH`), so the 80 stays the renderer's constant, not a second
number.

The cap is a CAP, not a guarantee that a table is exactly 80 wide: the gem adds
border overhead, so a capped table lands a few columns under the chrome. What it
guarantees is that a table never exceeds the fixed boundary width the way an
uncapped one did.

## Parse failure never aborts an answer

A model answer must not crash rendering. `render` rescues any parse error and
returns the raw text unchanged, so a malformed or pathological markdown block
degrades to the old raw print rather than losing the answer.
