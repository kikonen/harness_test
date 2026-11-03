# UI::Editor input design

Design doc for `lib/ui/editor.rb` and the prepended Reline patch modules split
out alongside it (`reline_esc_cancel.rb`, `reline_enter_policy.rb`,
`reline_lf_submit.rb`, `reline_ctrl_a.rb`, `reline_ctrl_g.rb`,
`windows_esc_hook.rb`). The source files keep a 3-line pointer here; the
rationale lives here.

Verified against reline 0.7.0 / Ruby 4.0 as of 2026-11-03.

## One primitive, three users

`UI::Editor` is the shared keyboard reader (issue #36 / #198). Three callers
share one code path so no two can race for the keyboard:

- **Mid-turn steering** - the Task drain loop peeks `stdin.input_pending?` on
  every tick (cross-platform, no reader thread - see `doc/task_design.md`); on a
  hit it opens the editor ON THE MAIN THREAD with prompt `note> `. Because the
  main thread owns the keyboard for the whole read, the #198 stuck-dialog /
  lost-line bug class dies by construction.
- **Dialog choice line** (issue #198 phase 2) - on a tty the dialog routes its
  single-line choice read through the editor too.
- **CLI idle prompt** (issue #198 phase 3) - multiline `#read_multiline`: Enter
  inserts a newline (typed or pasted); the submit key submits the whole buffer;
  an Esc'd draft is NOT discarded, it is prefilled on the next prompt.

## Two read paths, chosen at read time

- **tty** - Reline reads (`#read` single-line, `#read_multiline` multiline). Esc
  keeps the buffer as a draft (`cancelled?` + `whole_buffer`), ^C aborts with a
  clean Interrupt, Ctrl-D on an empty line is `:eof`. A previously cancelled
  draft returns prefilled via Reline's `pre_input_hook`.
- **non-tty** (pipes in specs, dumb terminals) - plain `gets()`, one line per
  read (a pipe has no Ctrl+Enter): a line is `:submitted`, a blank line is
  `:empty`, stream close is `:eof`. Backslashes are content, never continuation
  markers (issue #91).

The routing guard is `is_real_tty_stdin?`: take the Reline path ONLY when
`$stdin` IS a terminal AND the passed io is that same stream (same object or
same fileno). A fake `tty?` stream with its own fileno falls to the dumb path,
so a spec can never block on the real console (the bug class behind issue #202's
"stuck" look).

## EditorResult status contract

`EditorResult(text, status)`. `status` is one of `:submitted / :empty /
:cancelled / :eof` (plus `:edited` after a Ctrl+G hand-off). Each caller
interprets a status in its own domain:

| status | steering flow | dialog | CLI idle prompt |
|--------|---------------|--------|-----------------|
| `:submitted` | send as note | record choice | send to model |
| `:empty` | "no note" | re-prompt | (idle: ignored) |
| `:cancelled` | - | cancel dialog | keep draft, prefill next prompt |
| `:eof` | abort turn | cancel dialog | quit |
| `:edited` | buffer edited out-of-band | - | - |

## Prepended Reline patch modules

`install_esc!` mutates GLOBAL Reline state once per process: it prepends each
patch module onto `Reline::LineEditor` (idempotently - only if not already
present) and binds the submit keys. Each patch is a small `module UI::Editor::*`
in its own file, kept nested under `UI::Editor` so callers reach them as
`UI::Editor::RelineCtrlAToggle` etc. Install order in `install_esc!` is the
prepend order and is load-bearing (last prepended = highest priority on a
keypress); the existing install-idempotency and key-binding specs pin it.

- `RelineEscCancel` - a bare Esc marks the read cancelled and leaves the buffer
  INTACT (the caller hands it back as a prefilled draft). `EscState` carries the
  marker byte shared with the Windows hook.
- `RelineEnterPolicy` + `PasteGuard` - opt-in "double Enter submits" for setups
  where no submit key reaches the terminal; `EnterState` is its process-global
  flag. Paste guard so a pasted blank line never submits mid-paste.
- `RelineLFSubmit` - Ctrl+Enter arriving as LF (byte 10) on a remote host seen
  through Windows Terminal; guarded by the same `PasteGuard`.
- `RelineCtrlAToggle` - toggles the command-consent MODE on Ctrl+A; the new
  label rides on `CtrlAState` for the reader to ack (see
  `doc/safety_check_design.md` for the MODE itself).
- `RelineCtrlGHandoff` - Ctrl+G hands the buffer to an external editor; the
  snapshot rides on `CtrlGState`, and the READER (not the key patch) spawns the
  editor because Reline must have left raw mode first. Full design:
  `doc/external_editor.md`.
- `WindowsEscHook` - on the Windows IOGate a bare Esc is a virtual key, not a
  byte; translated to `EscState::ESC_MARKER` (auto-repeat guarded).

## Control-key detection

Reline hands a control key's char to `#input_key` as a **one-character String**
(`"\u0001"` for Ctrl+A, `"\a"` for Ctrl+G), not an Integer; a pasted block
arrives as a longer String whose first byte must not be mistaken for the key.
`UI::Editor.control_key?(char, byte)` is the ONE rule every intercepted control
key shares - a new control key costs a byte constant plus one call, not another
hand-copied String-vs-Integer test (issue #236).
