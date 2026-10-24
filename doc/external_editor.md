# External editor: Ctrl+G hands the buffer to $EDITOR (issue #298)

Why the feature is a keyboard shortcut and not a command, what Reline has to
cooperate with for it to be safe, and the measured facts behind each choice.
Verified against Ruby 4.0.7, reline 0.7.0, master `5d7de9c`.

---

## The feature

At the idle prompt, inside a mid-turn note, or in a dialog's free-text answer,
Ctrl+G writes the text you have typed so far to a scratch file, opens it with
the configured editor, and - when the editor exits - puts the result back as the
DRAFT. The submit key is still what SENDS it, exactly like an Esc-cancelled
buffer. Closing an editor is never a submission.

Owner's decision (this issue): the hand-off is a keyboard shortcut, not a slash
command, precisely because the text lives in the live edit buffer. A command
runs after the read has already returned and can only see what was submitted;
only a key handler, running mid-read, can capture the buffer as it stands.

On close behaviour the owner chose DRAFT, not send-immediately: the editor's
output returns as the draft and the submit key still sends it. So "keep it
without sending" stays available (Esc already keeps a draft) and nothing is
dispatched just because an editor was closed. (`--editor` is the CONFIG/flag
tier that selects WHICH editor, below - it is unrelated to this choice.)

## Why Ctrl+G, and not Ctrl+E

Ctrl+E is Reline's `ed_move_to_end` ("jump to end") in the emacs keymap - taking
it would steal a cursor command. Ctrl+G (byte 7, BEL) is mapped to `:ed_insert`
in reline 0.7.0's emacs mapping: pressed today it inserts a literal BEL
character, which is never wanted at a prompt. So the key is effectively free.

Measured in reline 0.7.0 (`key_actor/emacs.rb`): byte 5 (`^E`) is
`:ed_move_to_end`, byte 7 (`^G`) is `:ed_insert`, and `whole_buffer` (the public
accessor the hand-off snapshots) is `whole_lines.join("\n")`.

## The one fact the whole design turns on: the read must close first

`Reline.readmultiline` wraps its read in `io_gate.with_raw_input` and reads
`line_editor.whole_buffer` only AFTER that block returns - i.e. after Reline has
left raw mode and released the terminal. A child editor needs that terminal, so
it may only start once the read is closed. Two halves, in this order:

1. `RelineCtrlGHandoff#input_key` (prepended on `Reline::LineEditor`) snapshots
   `whole_buffer` into `CtrlGState` and calls `finish` - the same close Ctrl+A
   uses. It does not spawn anything: inside the key handler the terminal is still
   raw.
2. The reader (`reline_read_multiline`) sees `CtrlGState.fired` after
   `readmultiline` has returned, and only then runs `UI::ExternalEditor`. By
   then `with_raw_input` is closed.

Both facts were probed against the real Reline path (`KeyStroke.expand ->
input_key`), not a fake.

## Why the key test is on the byte, not a key binding

The patch checks the key in `#input_key` rather than adding a Reline key binding.
A binding installed via `add_default_key_binding_by_keymap` only covers the
editing-mode keymap; consulting the byte in `#input_key` is the same hook point
Esc-cancel and Ctrl+A already use, and it works identically on the Windows IOGate
(this project's own terminal) and the ANSI one.

`#input_key` is consulted for the whole feature's gate: it only takes the key when
`@is_multiline` (a single-line read has no buffer worth editing) AND
`UI::Editor.external_editor` is set. With no editor resolved the key is left
alone and behaves as it always did - the feature is strictly opt-in.

`key.char` for a control key arrives as a ONE-CHARACTER STRING (`"\a"` for
Ctrl+G, `"\u0001"` for Ctrl+A) - `KeyStroke#expand` packs the matched bytes into
a String. It is NOT the integer byte. A pasted block arrives as a longer String,
so the test is `char.size == 1 && char.ord == 7`: a paste whose first byte happens
to be 7 must not fire the hand-off. Probed: a real Ctrl+G yields
`char == "\a"`; a `:insert_multiline_text` paste starting with BEL does not fire.

## Resolution order (issue #298's three sources, plus the CLI flag)

`--editor` > `$HARNESS_EDITOR` > config `editor:` > `$EDITOR` > `$VISUAL`.

The issue listed the two ENV vars and the config key. `$HARNESS_EDITOR` sits
above the config key because it is the explicit override tier - the same role
`$HARNESS_CONFIG` plays in the config-file lookup (issue #260) - and `EDITOR`
before `VISUAL` follows the POSIX convention (`VISUAL` is the full-screen
preference, `EDITOR` the fallback; the harness prefers the value a user set for
a line editor). The resolution runs ONCE, in `CLI#parse_options`; the result is
stored in `options[:editor]` and installed on the process-global
`UI::Editor.external_editor` by `CLI#run`, so the idle prompt, the mid-turn note
editor and every dialog free-text read all honour the key with no per-call
re-resolution. A blank tier is skipped (not treated as a value).

## No shell is involved

`UI::ExternalEditor` splits the command with `Shellwords.shellsplit` and runs it
with `Process.spawn(*argv, draft_path)`. The draft path is the LAST argument
(anything before it is the editor's own flags: `nvim -R` etc.).

Because the command never passes through a shell, nothing in the user's editor
setting can be read as a shell construct: a `&&` or a quoted word is handed to the
child as a literal argument. Probed with `... --flag 'with space' && echo
SHELL_RAN` - the editor received `--flag`, `with space`, `&&`, `echo`,
`SHELL_RAN` as argv words and `SHELL_RAN` was never executed. This is why the
command denylist (`CommandAllowlist`) is not consulted here: there is no shell
for it to police.

## Failure model: the draft is never swallowed

The buffer the user typed always comes back. `open` answers one of:

- `:ok` - the editor ran; the text is the file it wrote.
- `:error` - the program could not be started (`Errno::ENOENT`, measured) or
  exited non-zero (measured with an editor that exits 3). `text` is the ORIGINAL
  draft, unchanged.
- `:unavailable` - no command resolved, or the command holds no program word
  (an unbalanced quote is a bad setting, not a crash: `shellsplit` raises and
  `argv` becomes empty). `text` is again the untouched draft.

The scratch directory is created with `Dir.mktmpdir` and removed in `ensure`, so
a failing editor leaves nothing behind (measured: no `harness-editor*` dir
remains after a failing run). The text that comes back crosses the same file
boundary every other reader uses (`FileText.from_disk`): the model-side text is
LF, whatever line endings the editor wrote on disk (`doc/file_editing_design.md`).

## What each caller does with :edited

`:edited` is a distinct status, never reusing `:submitted`, so no caller can
mistake a hand-off for an answer:

- `CLI#get_command` - the text becomes `@idle_draft`, prefilled at the next
  prompt; a "(<note> - draft kept; press the submit key to send)" line prints.
- `Task.poll_for_note` - the text becomes `@note_draft`, prefilled the next time
  the note editor opens. It shares the branch with `:cancelled` (Esc): an editor
  round-trip is the same kind of "keep, do not send" as a cancel, and is NOT
  committed as a note - a note that reached the model merely because an editor
  closed would inject text the user never sent.
- `UI::Dialog#collect_details` - the text becomes the draft for the next re-ask;
  the dialog stays open. It does not count as a submitted answer.

The mid-turn note path works because the note editor opens on the MAIN thread,
one read at a time, with the same `read_multiline` - so the "close the read
before spawning" rule applies unchanged. The drain loop's spinner simply resumes
after the editor returns.

## Deliberately not built

- No editor is spawned for a non-tty read (a pipe has no Ctrl+G; the dumb
  `gets()` path is untouched).
- No per-call `:editor` re-resolution after startup - the key is a fact about the
  run, set once like `submit_on_enter`.
- No shell interpretation of the command, so no allowlist / safety check on it.
- No Ctrl+G on a single-line read (Reline choice lines, dialog choice keys) -
  those have no multiline buffer to hand over.
