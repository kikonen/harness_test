# Reline: cursor position and Enter handling

Notes on reading, preserving and using the cursor position in a Reline
multiline editor, on using it to decide whether Enter inserts a new line
or submits the input, and on keeping pasted line breaks from submitting.

Verified against the **Reline 0.7.0** source. Several pieces rely on Reline
internals (see [Caveats](#caveats)), so pin the Reline version.

---

## 1. How Reline stores the cursor

`Reline::LineEditor` keeps the editing state in three instance variables:

| Variable            | Meaning                                              |
|---------------------|------------------------------------------------------|
| `@buffer_of_lines`  | Array of lines (Strings) making up the buffer        |
| `@line_index`       | Index of the line the cursor is on                   |
| `@byte_pointer`     | Cursor offset within that line, **in bytes**         |

The state survives after `readmultiline` returns. It is only reset when the
next read starts, so it can be read right after a read finishes.

### Public API

| API                     | Returns / does                                        |
|-------------------------|-------------------------------------------------------|
| `Reline.point`          | Byte offset within the **current line**               |
| `Reline.point = n`      | Sets that offset                                      |
| `Reline.line_buffer`    | Whole buffer as one String                            |

These are only meaningful while a read is active, for example inside
`pre_input_hook` or a key action.

There is **no public accessor for `@line_index`**, so the public API alone
cannot tell which line the cursor is on.

---

## 2. Accessors for the full position

Add these to the prepended control module:

```ruby
module RelineControl
  # [line_index, byte_offset_in_line]
  def cursor_position
    [@line_index, @byte_pointer]
  end

  # [line_index, character_offset_in_line], for display or logging
  def cursor_char_position
    line = @buffer_of_lines[@line_index] || ""
    [@line_index, line.byteslice(0, @byte_pointer).length]
  end

  def move_cursor_to(line_index, byte_pointer)
    return if @buffer_of_lines.empty?
    @line_index = line_index.clamp(0, @buffer_of_lines.size - 1)
    line = @buffer_of_lines[@line_index]
    bp = byte_pointer.clamp(0, line.bytesize)
    # never land in the middle of a multibyte character
    bp -= 1 while bp > 0 && !line.byteslice(0, bp).valid_encoding?
    @byte_pointer = bp
  end
end
Reline::LineEditor.prepend(RelineControl)
```

Notes:

- `@byte_pointer` counts **bytes**, not characters. Use
  `cursor_char_position` when a character column is needed.
- `move_cursor_to` clamps both values and backs off to a character boundary,
  so it is safe even if the text changed since the position was captured.
- Assigning `@line_index` and `@byte_pointer` directly is the same thing
  Reline's own history navigation does.

---

## 3. Preserving the cursor across pause / resume

Capture the position together with the text when a read ends, and restore it
in `pre_input_hook` when the read is resumed. The hook runs after the editor
is reset but **before the first render**, so the prompt is drawn with the
cursor already in place.

```ruby
Result = Struct.new(:text, :status, :cursor)   # :submitted, :cancelled, :paused, :eof

def read_multiline(prompt, prefill: nil, cursor: nil)
  if prefill && !prefill.empty?
    Reline.pre_input_hook = -> do
      Reline.insert_text(prefill)
      Reline.line_editor.move_cursor_to(*cursor) if cursor
      Reline.pre_input_hook = nil              # the hook is global: one-shot
    end
  end

  text = Reline.readmultiline(prompt, false) { |input| input.end_with?("\n\n") }
  editor = Reline.line_editor
  pos = editor.cursor_position

  if text.nil?            then Result.new(nil, :eof, nil)
  elsif editor.paused?    then Result.new(text, :paused, pos)
  elsif editor.cancelled? then Result.new(text, :cancelled, pos)
  else
    Reline::HISTORY << text unless text.strip.empty?
    Result.new(text, :submitted, pos)
  end
ensure
  Reline.pre_input_hook = nil
end
```

In the controller loop, keep the cursor next to the draft:

```ruby
case r.status
when :paused, :cancelled
  draft, draft_cursor = r.text, r.cursor
when :submitted
  draft = draft_cursor = nil
  # ...
end

r = read_multiline("prompt> ", prefill: draft, cursor: draft_cursor)
```

Without the cursor restore, `insert_text` leaves the cursor at the end of the
restored text.

---

## 4. What happens when Enter is pressed

Enter is bound to the private action `LineEditor#ed_newline`. In emacs mode
it does the following:

1. `process_insert(force: true)`: flushes any pending typed characters, so
   the buffer and cursor now match exactly what the user sees.
2. If the cursor is **not on the last line**: always inserts a new line at
   the cursor. The termination block is **not called**.
3. If the cursor **is on the last line**: calls the termination block passed
   to `readmultiline` with the whole buffer (joined with `"\n"`, plus a
   trailing `"\n"`).
   - `true` → `finish` (submit)
   - `false` → `key_newline`, which splits the current line at the cursor

Two consequences:

- The cursor position **is accurate at the moment Enter is pressed**.
- The termination block only sees the text, and only runs when the cursor is
  on the last line. It cannot implement a cursor-based policy on its own.

---

## 5. Cursor-aware Enter: overriding `ed_newline`

Override `ed_newline` so that a single policy function decides, for every
line, whether Enter submits or inserts a new line:

```ruby
module RelineControl
  PASTE_GRACE = 0.05   # seconds, see section 6

  class << self
    # ->(lines, line_index, byte_pointer) { true = submit, false = new line }
    attr_accessor :submit_on_enter
  end

  private def ed_newline(key)
    policy = RelineControl.submit_on_enter
    return super unless policy && @is_multiline && @config.editing_mode_is?(:emacs)

    process_insert(force: true)     # flush pending input, as Reline does
    if pasting? || !policy.call(@buffer_of_lines, @line_index, @byte_pointer)
      key_newline(key)              # pasted line break, or policy says new line
    else
      finish                        # submit
    end
  end

  def input_key(key)
    # ... pause / ESC interceptions go here, before super ...
    result = super
    @last_paste_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) if @in_pasting
    result
  end

  private def pasting?
    return true if @in_pasting
    # The final key of a paste has nothing queued behind it, so @in_pasting
    # is false for it. Treat a key arriving right after pasted input as paste too.
    @last_paste_at &&
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_paste_at < PASTE_GRACE
  end
end
```

- Without a policy, or in vi mode or single-line mode, Reline's original
  behaviour is used.
- Line breaks inside pasted text always insert a new line, regardless of the
  policy. Section 6 explains why this is needed and how paste is detected.
- With the override active in emacs mode, the termination block passed to
  `readmultiline` is no longer consulted for Enter. It is still required by
  the method signature.

### Example policies

**Enter at the very end of the text submits; anywhere else inserts a line:**

```ruby
RelineControl.submit_on_enter = ->(lines, line_index, byte_pointer) do
  line_index == lines.size - 1 && byte_pointer == lines.last.bytesize
end
```

**Enter on an empty last line submits (double Enter):**

```ruby
RelineControl.submit_on_enter = ->(lines, line_index, byte_pointer) do
  line_index == lines.size - 1 && lines.last.strip.empty?
end
```

**Commands submit immediately, other text is multiline:**

```ruby
RelineControl.submit_on_enter = ->(lines, line_index, byte_pointer) do
  next true if lines.first.start_with?("/")
  line_index == lines.size - 1 && lines.last.strip.empty?
end
```

---

## 6. Pasted text

### The problem

A policy such as "Enter on the last line submits" breaks with copy-paste.
While pasting, the cursor is on the last line as soon as the first pasted
line break arrives, so the input is submitted at the first newline and the
rest of the paste is lost or treated as new input.

### How Reline detects pastes

| Platform | Mechanism | Pasted line breaks reach `ed_newline`? |
|----------|-----------|----------------------------------------|
| Unix terminals | **Bracketed paste.** Reline enables it by default (`\e[?2004h`). The terminal wraps pasted text in `\e[200~ … \e[201~`, and Reline inserts all of it at once with `insert_multiline_text`. | No |
| Windows console | **Timing heuristic.** A paste arrives as a burst of ordinary key events, including Enter for each line break. Before each key is processed, Reline sets `@in_pasting` on the LineEditor to true if more input is already waiting (`@output_buf` not empty, or `input_pending?`). | **Yes** |

Reline uses `@in_pasting` only to skip redrawing and autocompletion during a
paste. `ed_newline` itself **ignores** it, so on Windows a pasted line break
goes through the normal Enter logic and can submit.

The same timing heuristic is the fallback on Unix when bracketed paste is
disabled (`enable-bracketed-paste off` in inputrc) or the terminal does not
support it.

### The guard

The `ed_newline` override in section 5 checks `pasting?` before the policy:
any Enter that is part of a paste inserts a new line.

`@in_pasting` has one gap: the **last** key of a paste has nothing queued
behind it, so the flag is false for that key. Without handling this, a paste
that ends in a line break would submit at the end. The override therefore
records when pasted input was last seen (in `input_key`) and treats a key
arriving within `PASTE_GRACE` (50 ms) of it as part of the paste too.
50 ms is far below human reaction time, so a real Enter pressed after a paste
still goes through the normal policy.

### Edge cases

- **Type-ahead looks like a paste.** If the user types Enter while the
  program is busy, the queued keys are processed in a burst and that Enter
  becomes a line break instead of a submit. This fails safe: nothing is
  submitted by accident, and the user presses Enter again.
- **Bracketed paste needs terminal support.** Nearly all modern Unix
  terminals support it; without it, the timing heuristic and the guard apply.

---

## 7. Explicit "execute now" key

Reline has a built-in action, `ed_force_submit`, that submits regardless of
the cursor position. Binding it to the Meta+Enter key sequence (ESC followed
by CR, `[27, 13]`) gives users an explicit "run it now" key next to the
cursor-based default for Enter:

```ruby
Reline.core.config.add_default_key_binding_by_keymap(:emacs, [27, 13], :ed_force_submit)
```

The harness (`UI::Editor#install_esc!`) binds a SECOND sequence too:
CSI Ctrl+Enter, `ESC [ 1 3 ~` (bytes `[27, 91, 49, 51, 126]`), to the same
action. See the remote-setup note in the platform table below.

Which physical keys produce that sequence depends on the platform:

| Platform                           | Keys that produce `[27, 13]`                              |
|------------------------------------|-----------------------------------------------------------|
| Windows console / Windows Terminal | **Ctrl+Enter**, **Shift+Enter**                           |
| Unix terminal reached DIRECTLY     | **Alt+Enter** (Ctrl/Shift+Enter usually send a plain CR, indistinguishable from Enter) |
| Remote host THROUGH Windows Terminal (ssh, WSL2) | **Neither.** Windows Terminal consumes Alt+Enter (settings / fullscreen toggle) and has no Ctrl+Enter encoding by default - the key never reaches the remote program. |

- **Windows:** Reline's Windows backend has a key map that translates
  Ctrl+Enter and Shift+Enter into `"\e\r"`; a comment in the source says it
  is treated as Meta+Enter. Alt+Enter **cannot** be used: Windows Terminal and
  the classic console use it to toggle fullscreen, so the key never reaches
  the program.
- **Unix:** terminals send Alt+Enter as ESC CR. Most terminals send the same
  CR for Ctrl+Enter, Shift+Enter and Enter, so those cannot be told apart
  without extended keyboard protocols.
- **Remote via Windows Terminal:** the user's *local* terminal is Windows
  Terminal, so its key handling applies - but the program runs on a remote
  Linux host whose Reline only sees whatever bytes the local terminal
  forwards over ssh. In that topology:
  - Alt+Enter toggles fullscreen (the F11 action) and never reaches the
    remote pty.
  - Ctrl+Enter produces nothing by default (no extended keyboard protocol).
  - ESC then Enter *does* arrive as `[27, 13]` - Reline only accepts it when
    the two bytes land within its `keyseq_timeout` (100 ms in the harness),
    so "tap ESC and Enter quickly" works but is nearly undiscoverable.
  - A terminal with an **extended keyboard protocol** (kitty / kamadb, or
    xterm's `kcm` mode) sends Ctrl+Enter as CSI `ESC [ 1 3 ~`; that sequence
    is bound to `ed_force_submit` as well (verified against Reline 0.7.0:
    `config.add_default_key_binding_by_keymap(:emacs, [27, 91, 49, 51, 126], :ed_force_submit)`).
    On terminals that never emit it the binding is inert.
- Ctrl+Enter is a familiar "send" key from chat and mail apps, which makes it
  a natural choice on Windows.
- Without this binding, Reline's default for `[27, 13]` is to insert a line
  break (the IRB convention: Enter runs, Shift/Ctrl+Enter adds a line).
- The binding does not conflict with the Windows ESC-cancel hook, which only
  matches the Escape key's own virtual key code, not the ESC prefix Reline
  generates for these keys.

### Side note: Ctrl+J (portable, but unintuitive)

Ctrl+J is the one Ctrl-based key that is distinguishable from Enter on
practically every terminal: it is sent as LF (byte 10), while Enter sends CR
(byte 13). By default Reline maps byte 10 to `ed_newline`, the same as Enter,
so it would need its own binding.

It is listed here for awareness only. As a "submit" key it is close to
undiscoverable for users, so it is not part of the recommended setup.

If it is ever used, bind it to an action that respects the paste guard.
Without bracketed paste, pasted text with LF line endings arrives as byte 10
and would otherwise submit at the first line break:

```ruby
module RelineControl
  private def force_submit_unless_pasting(key)
    pasting? ? key_newline(key) : ed_force_submit(key)
  end
end

Reline.core.config.add_default_key_binding_by_keymap(:emacs, [10], :force_submit_unless_pasting)
```

### Conservative Enter policies

The force-submit key is also the reliable way to submit when the Enter policy
is deliberately conservative, for example "Enter always inserts a new line".

Resulting behaviour:

| Situation                        | Behaviour                                                 |
|----------------------------------|-----------------------------------------------------------|
| Line breaks inside pasted text   | Always a new line (Unix: bracketed paste; Windows: guard) |
| Enter typed by the user          | Policy decides: new line or submit, based on cursor       |
| Ctrl+Enter / Shift+Enter (Windows), Alt+Enter (Unix) | Always submit                         |
| ESC                              | Cancel (draft and cursor kept for resume)                 |

---

## Caveats

- **Internal APIs.** `ed_newline`, `key_newline`, `process_insert`, `finish`,
  `input_key`, `@buffer_of_lines`, `@line_index`, `@byte_pointer`,
  `@is_multiline` and `@in_pasting` are Reline internals. Pin the Reline
  version and re-check after upgrades.
- **Startup check.** Fail loudly if the internals change, instead of silently
  falling back to different behaviour. `set_pasting_state` is the method that
  sets `@in_pasting`, so its presence is a good proxy for the paste flag:

  ```ruby
  required = %i[ed_newline key_newline process_insert finish input_key set_pasting_state]
  missing = required.reject { |m| Reline::LineEditor.private_method_defined?(m) ||
                                  Reline::LineEditor.method_defined?(m) }
  abort "Reline #{Reline::VERSION}: missing #{missing.join(', ')}" unless missing.empty?
  ```

- **Bytes vs characters.** Every position Reline stores is a byte offset.
  Convert before showing a column to the user or comparing with character
  indexes.
- **Vi mode.** The override only applies in emacs mode. In vi command mode,
  Enter moves down or submits, and Reline's original logic is kept.
- **Screen position.** Everything above is the position in the *buffer*.
  The on-screen row and column (with line wrapping) are computed separately
  inside LineEditor and are more tied to rendering internals.
