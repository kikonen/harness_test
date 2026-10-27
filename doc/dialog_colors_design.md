# Dialog colors: what a note states, and who decides the hue

Verified against `lib/ui/dialog.rb`, `lib/ui/console.rb`, `lib/ui/palette.rb`,
`lib/command_runner.rb`, `lib/file_list.rb` and `lib/cli.rb` on branch
`feature/issue-388-dialog-colors` (ruby 4.0.7, RuboCop 1.92). Issue #388.
Repro: `analysis/388/repro.rb`. Rendering rules in general:
`doc/output_rendering_design.md`.

## The complaint

Issue #388, in the owner's own words: "Dialogs could use also color schema to
highlight important parts", followed by three pasted dialogs (two `run.command`
consent dialogs and a grant dialog) where every line - the model verdict, the
DENYLISTED line, the command, the option list - printed in one color.

The issue names a QUALITY, not a target: WHICH parts are important is the
owner's call. The first cut of this fix made that call silently - it painted the
option NUMBERS in the recessive `marker` gray and labeled them chrome - and that
choice was then measured on the owner's terminal and found to be no highlight at
all ("not seeing gray, might be that it's so close to normal text that it is not
visible"). A DE-EMPHASIZING color cannot make something the eye has to LOCATE in
a list stand out: a recessive role is right for decoration (the `[dialog]`
bracket, a status bracket, a rule) and wrong for an anchor.

## The rule: the emitter states WHAT a line is, the console decides how it looks

Same separation `doc/output_rendering_design.md` established for status lines,
applied to dialogs. A dialog note carries a **kind**, never a color:

| kind | meaning | default palette |
| --- | --- | --- |
| `context` | neutral background (a purpose line, an explanation) | terminal's own color |
| `warn` | a refusal that is not a disaster match (`UNSAFE:` construct, path outside the workdir) | brown `38;5;130` |
| `alert` | the hard floor (`DENYLISTED:`) or a `dangerous:` model verdict | red `31` |
| `safe` | a reassuring model verdict line (`MODEL VERDICT (advisory): safe:`) | green `32` |

The dialog has ONE role that is not a note kind: **`dialog_option`**, the option
NUMBER a choice line names. It is the anchor of the interaction, so it gets a
visible hue - the step-label cyan `36`, a band code, so it survives `basic16` and
any terminal that drops the 256-color ramp.

`UI::Dialog::NOTE_KINDS` is the closed set (`Note.new` rejects an unknown kind
instead of guessing one), `NOTE_ROLES` maps each kind to its palette role, and
the hues live in `UI::Palette` like every other role - `basic16` keeps the same
four kinds inside the 16-color band, `none` paints nothing.

**`context` is unpainted in every palette on purpose.** A note is content the
user must read - a model-asked dialog's entire question IS a note - and the
measured recessive gray (`38;5;240`) reads as decoration on this terminal. Only
a kind that IS a highlight gets a hue. That is why the option DESCRIPTIONS and
the choice-prompt lines stay plain too.

The `[dialog] ⚠` marker keeps the recessive `marker` role, the same gray a status
line's bracket already uses: it is decoration and de-emphasizing it is correct.
An option's own WORDS are content the user reads: `1) Allow` colors the `1)` in
cyan, not `Allow`.

## Where the palette lives: on the console, not in the call

The first wiring attempt passed the palette into the dialog
(`palette: task.renderer&.palette` in `Task.handle_request`). That is the leak
this issue is about: a caller of a dialog has no reason to know which renderer a
turn chose, and every call site that learned it would have to keep learning it.

So presentation hangs off the sink the dialog was ALREADY handed:

- `UI::Console` takes `palette:` - a `UI::Palette`, `nil`, or a zero-arg callable
  answered per line (the live-reader pattern `FileList#posture` uses for YOLO,
  issue #274) - and answers `#paint(role, text)`. With no palette the text comes
  back byte-for-byte unchanged, which is what `--no-color`, a StringIO console in
  a spec, and any console built before the Harness exists need.
- `UI::Dialog` asks the console it was given, guarded by
  `respond_to?(:paint)`, so a sink that only answers `puts`/`print` still gets a
  plain dialog.
- One wiring point: `CLI#initialize` builds the single console every dialog and
  status line reaches, with `palette: -> { @harness&.output_palette }`. The
  console exists before the Harness that resolves the palette and `/palette` can
  change it mid-run, hence the callable.
- `Task.handle_request` serves a task-routed dialog on **the task's own console**
  - the same stream pair the drain loop renders to, so it already carries the
  run's presentation. It used to rebuild a second `UI::Console` from
  `task.ui.stdout/stdin`, which duplicated the sink while dropping its palette.

`CommandRunner`'s main-thread status lines keep their existing route (they build
a `UI::Renderer` from the harness palette) - the console palette is for the lines
the dialog owns.

## The emitter side

- `note:` accepts one String (kind `context`), one `Dialog::Note`, or an Array of
  either. `normalize_notes` splits multi-line notes into one Note per line, keeps
  each part's kind, and drops blank lines so a computed note with a nil part
  prints nothing instead of empty indented lines. `Array()` is NOT used: a Struct
  answers `#to_a`, so it would splat a Note into its fields.
- `CommandRunner` states `warn` for `UNSAFE:`, `alert` for `DENYLISTED:`, and
  colors the model verdict by the verdict's own kind (`verdict_kind`: `safe` /
  `alert`) - the two verdict lines the owner pasted were indistinguishable before.
- `FileList#grant_access` states `warn` for the OUTSIDE-the-workdir WARNING and
  leaves the purpose line as context.
- A String note is unchanged, so `ui.dialog`'s free-form note and `web.fetch`
  needed no edit at all.

## Plain output is byte-identical

The marker part keeps the exact pre-#388 bytes - two spaces after the glyph - and
`paint` is a no-op without a palette. So a plain console must print the dialog it
always did; `spec/lib/ui/dialog_spec.rb` asserts both halves (the colored drive
and "byte-for-byte plain"), and `spec/lib/command_runner_spec.rb` asserts that a
colored drive and a plain drive produce the same text once the escape bytes are
stripped.

`/palette` lists the five dialog roles under "dialog roles" so the hues are not
guesswork, and prints `(terminal color)` for a group the palette leaves plain.
