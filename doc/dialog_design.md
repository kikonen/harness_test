# UI::Dialog: choice input, free text, and I/O routing

Design of `lib/ui/dialog.rb`: how a dialog renders, what the choice line
accepts, how free text rides along with a selection, and how the dialog is
served when called from a Task thread. Note colour kinds live in
`doc/dialog_colors_design.md`; the shared Reline editor mechanics (Enter,
Esc, Ctrl-D, paste guard) live in `doc/reline_cursor_and_enter_handling.md`.

## What a dialog is

A title (what it is about), a set of options, and a standard "Cancel" option
that is ALWAYS present. Each option has a title, an optional description, and
a value. The value of the selected option is returned; picking Cancel or an
EOF dismiss returns `CANCEL_VALUE`.

## Choice line: option numbers only

The choice line is option numbers only - bare `1`, several in one line
(`1 3`, `1,3`) when multi-select is on, or the cancel number plus a one-line
reason (`5 no, and because X`). Single-select is multi-select with one number.

Any text on the choice line that is NOT `<cancel> <reason>` is stray input (a
paste accident): it re-prompts and is never a selection, a note, or a cancel.
There are no per-option inline notes. An out-of-range number is rejected with
an explanatory line and re-prompts, so a mistyped choice is never silently
reinterpreted.

## Cancel is always explicit

Only picking the Cancel option (alone or in a selection), an attached
`<cancel number> <note>` line, or EOF decides a dialog by cancelling it. In a
non-multi-select dialog, Cancel mixed with another option re-prompts.

## Free text ("Additional details")

When free text is enabled the dialog gets an explicit numbered "Additional
details" option, selectable alone, alongside other options, or alongside Cancel
(`2 3 4` = options 2+3 with a note; `5 4` = cancel with a reason). Picking it
enters a multi-line text block: type or paste, finish with a blank line; EOF
cancels the whole dialog; an empty block re-prompts.

The typed details ride along as `[FREE_TEXT, text]` appended to the result, so
possible return shapes are: the bare value, an array of values, `[FREE_TEXT,
text]`, `[value, [FREE_TEXT, text]]`, `[:cancelled, 'reason']`, or
`[:cancelled, [FREE_TEXT, 'reason']]`.

## Choice-line editing (shared editor)

On a TTY the single-line choice read and the multi-line free-text block both go
through `UI::Editor` (the same Reline editor the steering note uses), so every
in-turn stdin read shares ONE code path: Enter submits, a bare Enter re-prompts,
Esc keeps what was typed as a draft prefilled on the next re-prompt (it never
cancels), Ctrl-D on an empty line cancels like EOF. Non-TTY streams take a plain
`gets()` path with the same blank-line / EOF semantics as before. `tty_input?`
gates this on the stdin being the process's real terminal stdin, so a fake
`tty?` stream in tests stays on the dumb `gets()` path.

## Single-thread I/O rule

When called from within a Task thread, `show` routes the entire interaction
through the task's request/response protocol so stdin/stdout are used only on
the main thread; the caller MUST pass `ui: nil` (naming `$stdout`/`$stdin` from
a task thread would be global stream access from the wrong thread). When no Task
is active (tests, direct CLI commands), an explicit `ui:` (a `UI::Console`) is
REQUIRED and used directly - deliberately no defaults and no global lookup, so
a dialog never silently talks to a stream nobody passed in. `perform_direct` is
the shared body, reached both by `show` (no Task) and by the main thread when
servicing a `:dialog` request.

## Grant dialogs

A GRANT dialog can never be denied for a background job: denying the consent
would stop the job from working at all, so the consent path stays live for it.
Every other dialog kind is deniable. `grant?` reports which kind this is.
