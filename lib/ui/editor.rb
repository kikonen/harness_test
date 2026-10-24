# frozen_string_literal: true

require "reline"
require_relative "external_editor"

# -- UI::Editor -------------------------------------------------------------
#
# The shared editor primitive (issue #36 / #198). Three users, one code path:
#   * the mid-turn steering flow - the Task drain loop peeks
#     `stdin.input_pending?` on every tick (cross-platform, no reader
#     thread - see Task); on a hit it opens this editor ON THE MAIN THREAD
#     with PROMPT 'note> ', so nothing can race for the keyboard
#     (issue #198's stuck-dialog / lost-line bug class dies by
#     construction).
#   * UI::Dialog's choice line (issue #198 phase 2) - on a tty the dialog
#     routes its single-line choice read through this editor too.
#   * the CLI idle prompt (issue #198 phase 3) - multiline input
#     (#read_multiline): Enter inserts a newline (typed or pasted),
#     the submit key (Ctrl+Enter family, see SUBMIT_KEY_SEQ /
#     CSI_CTRL_ENTER_SEQ) submits the whole buffer (issue #91: no backslash or
#     paste-speed tricks, so a paste can never submit mid-block), and an
#     Esc'd draft is NOT discarded - it is prefilled on the next prompt.
#
# Two read paths, chosen at read time:
#   * tty: Reline reads (single-line #read / multiline #read_multiline).
#     Esc keeps the buffer as a draft (cancelled? + whole buffer), ^C
#     aborts with a clean Interrupt, Ctrl-D on an empty line is :eof. A
#     previously cancelled draft comes back prefilled via the Reline
#     pre_input_hook.
#   * non-tty (pipes in specs, dumb terminals): plain gets(), one line per
#     read (a pipe has no Ctrl+Enter) - a line is :submitted, a blank line
#     is :empty, stream close is :eof. Backslashes are content.
#
# Returns an EditorResult(text, status); status is one of :submitted /
# :empty / :cancelled / :eof. Each caller interprets the statuses in its
# own domain: the steering flow treats :empty as "no note" and :eof as
# "abort turn"; a dialog treats :empty as "re-prompt" and :eof as
# "cancel the dialog"; the CLI treats :cancelled as "keep draft" and
# :eof as "quit".

module UI
  class Editor
    DEFAULT_PROMPT = "note> "
    # Reline's PROMPT for dialog choice lines (the steering note uses
    # DEFAULT_PROMPT).
    DIALOG_PROMPT = "> "
    # note carries the reader's own explanation of a non-standard status
    # (today: why an external-editor hand-off produced no text to send).
    EDITOR_RESULT = Struct.new(:text, :status, :note)

    # Key bytes (Reline keymap sequences; see doc/reline_cursor_and_
    # enter_handling.md section 7 for why these are the portable choices).
    ESC_KEY_BYTE = 27   # Escape character (bare Esc cancels the read)
    CR_KEY_BYTE  = 13   # Carriage Return (plain Enter inserts a newline)
    # Ctrl+G (BEL) is the byte this key arrives as - measured: Reline hands a
    # control key's char to #input_key as the one-character String "\a".
    # Taken by RelineCtrlGHandoff only when UI::Editor.external_editor is set;
    # otherwise the key keeps what Reline's own emacs mapping does with it.
    CTRL_G_BYTE = 7
    # The submit key: ESC then CR. The Windows IOGate maps Ctrl+Enter and
    # Shift+Enter to these bytes; Unix terminals produce them with
    # Alt+Enter (Ctrl/Shift+Enter there are indistinguishable from a plain
    # Enter, so that is the documented platform split). AltGr+Enter sends
    # the same bytes on most layouts (AltGr is ESC-prefixed, like Meta).
    # CAVEAT: a remote host seen through Windows Terminal (ssh / WSL2) gets
    # neither plain Alt+Enter (fullscreen toggle) nor a default Ctrl+Enter;
    # but Ctrl+Enter arrives as LF (CTRL_ENTER_LF_BYTE below) and AltGr+
    # Enter works when the keyboard has one - both are bound (issue #198).
    SUBMIT_KEY_SEQ = [ESC_KEY_BYTE, CR_KEY_BYTE].freeze
    # Probe finding (issue #198, showkey over ssh / WSL2): plain Enter
    # arrives as CR (byte 13) but Ctrl+Enter arrives as LF (byte 10) - the
    # two are distinguishable at the Reline level. Bound to force-submit
    # with a paste guard (see install_esc!), so Ctrl+Enter submits on the
    # remote-via-Windows-Terminal setups where no other submit key reaches
    # the pty.
    CTRL_ENTER_LF_BYTE = 10
    # CSI (Control Sequence Introducer) pieces of the "ESC [ 1 3 ~"
    # sequence: [ is 0x5b (91), '1'/'3' are their digit bytes, ~ is 0x7e
    # (126). Kept as named bytes because a CSI sequence is exactly this:
    # ESC, '[', parameters, terminator.
    CSI_OPEN_BYTE   = 91   # '[' - starts the CSI parameter field
    DIGIT_1_BYTE    = 49   # '1'
    DIGIT_3_BYTE    = 51   # '3'
    CSI_END_TILDE   = 126  # '~' - terminates this CSI sequence
    # CSI Ctrl+Enter ("ESC [ 1 3 ~"), sent for Ctrl+Enter by terminals with
    # an extended keyboard protocol (kitty/kamadb/kcm mode - e.g. recent
    # Windows Terminal + kitty keyboard enhancement). Harmless to bind on
    # terminals that never send it; on the ones that do it is the only
    # submit key when running a remote host via Windows Terminal (issue #198).
    CSI_CTRL_ENTER_SEQ = [ESC_KEY_BYTE, CSI_OPEN_BYTE, DIGIT_1_BYTE,
                         DIGIT_3_BYTE, CSI_END_TILDE].freeze

    # Opt-in fallback for setups where NO submit key reaches the terminal
    # (a remote host seen through Windows Terminal - issue #198): with
    # `submit_on_enter` set, Enter on an EMPTY LAST LINE submits the whole
    # buffer. Every other Enter inserts a newline as usual. Pasted line
    # breaks are excluded (RelineEnterPolicy's paste guard) so pasted
    # blank lines cannot submit mid-paste. Only multiline reads are
    # affected; single-line reads and vi mode keep Reline's behaviour.

    # Ctrl+G hands the buffer being edited to an external editor (issue #298).
    # Process-global because it is a fact about how this run reads input, like
    # submit_on_enter: the CLI resolves the command once at startup and every
    # multiline read then honours the key. The setting is read AT KEYPRESS time
    # (not install time), so nil simply means the key is not taken.
    def self.external_editor=(value)
      @external_editor = value.to_s.strip.empty? ? nil : value.to_s.strip
    end

    def self.external_editor
      @external_editor
    end

    # Process-global switch for the opt-in Enter policy (default off -
    # plain Enter always inserts a newline). Set once at startup from the
    # 'double_enter_submit' config key (see CLI); covers the idle prompt
    # and the mid-turn note editor alike.
    def self.submit_on_enter=(value)
      EnterState.enabled = value
    end

    def self.submit_on_enter?
      !!EnterState.enabled
    end

    def initialize(stdin)
      @stdin = stdin
    end

    # Shared state for the opt-in Enter policy (RelineEnterPolicy lives on
    # a different object - the LineEditor - so the flag rides on a module,
    # like EscState).
    module EnterState
      class << self
        attr_writer :enabled

        def enabled? = !!@enabled
      end
    end

    # Read one line from stdin. `prompt` is the editor prompt string;
    # `prefill` (a draft from a previously cancelled editor) is inserted
    # into the Reline buffer on tty only.
    def read(prompt: DEFAULT_PROMPT, prefill: nil)
      tty? ? reline_read(prompt, prefill) : dumb_read
    end

    # Read a FULL (possibly multiline) input - the idle prompt's reader
    # (issue #198 phase 3). Same status contract as #read, plus:
    #   * tty: Reline.readmultiline - bracketed paste, line editing; ENTER
    #     inserts a real newline (typed or pasted); the submit key (see
    #     SUBMIT_KEY_SEQ / CSI_CTRL_ENTER_SEQ, bound to Reline's
    #     ed_force_submit by install_esc!) commits the whole buffer.
    #     Backslashes are content - never
    #     continuation markers
    #     (issue #91). Committed text lands in Reline::HISTORY so
    #     HistoryManager persists it.
    #   * non-tty: plain gets() - one line per read, backslashes kept as
    #     content (the tty-only key model does not apply to pipes).
    # A cancelled Esc returns the buffer intact as `text`; bare Enter is
    # :empty; Ctrl-D on an empty buffer is :eof.
    def read_multiline(prompt: DEFAULT_PROMPT, prefill: nil)
      tty? ? reline_read_multiline(prompt, prefill) : dumb_read
    end

    # The single line of defense against Reline's real-$stdin attach: take
    # the Reline path only when $stdin IS a terminal AND `io` is that same
    # stream (same object, or the same file descriptor). A fake tty? stream
    # with its own fileno therefore always falls to the dumb gets() path -
    # a spec can never accidentally block on the real console (the bug
    # class behind issue #202's "stuck" look; see UI::Editor routing tests).
    def self.is_real_tty_stdin?(io) = tty_stream?($stdin) && real_io?(io, $stdin)

    # Shared Esc-state between the LineEditor patch and the Windows key
    # hook (they live on different objects; the hook signals the editor).
    module EscState
      ESC_MARKER = "\x1D"

      class << self
        attr_accessor :esc_pending
      end
    end

    # Marks a bare Esc as "cancelled" instead of letting it act as an
    # escape-prefix. The current buffer is left INTACT - the caller hands
    # it back as a prefilled draft on the next read.
    module RelineEscCancel
      def reset_variables(prompt = "")
        super
        @cancelled = false
      end

      def cancelled?
        !!@cancelled
      end

      def input_key(key)
        if EscState.esc_pending && key.char == EscState::ESC_MARKER
          EscState.esc_pending = false
          cancel_input(key)
          return false
        end
        super
      end

      private

      # :cancel_input is the bound action for bare Esc on Unix; on Windows
      # the hook injects the marker byte and this consumes it. Either way
      # the buffer stays intact (see cancelled? / whole_buffer).
      def cancel_input(_key)
        @cancelled = true
        finish
      end
    end

    # issue #224 follow-up: shared state for the Ctrl+A mode toggle. The
    # RelineCtrlAToggle patch (prepended on LineEditor) fires the toggle
    # when Ctrl+A is pressed while a read is open; the reader
    # (reline_read_multiline) then clears it and hands the resulting MODE
    # label back to the caller so the Task can print an ack line.
    module CtrlAState
      class << self
        attr_accessor :fired, :label

        def reset!
          @fired = false
          @label = nil
        end

        def fire!(label)
          @fired = true
          @label = label
        end
      end
    end

    # Ctrl+G hand-off state (issue #298): the key patch snapshots the buffer
    # being edited and closes the read; the READER performs the editor spawn,
    # because Reline must have left raw mode before a child process is given
    # the terminal. text is the buffer as it stood at the keypress.
    module CtrlGState
      class << self
        attr_accessor :fired, :text

        def reset!
          @fired = false
          @text  = nil
        end

        def fire!(text)
          @fired = true
          @text  = text
        end
      end
    end

    # Ctrl+G hands the buffer being edited to an external editor (issue #298).
    # Detected on the KEY BYTE rather than through a key binding, so the same
    # code path serves the Windows IOGate and the ANSI one. With no editor
    # resolved the key is not taken at all and Reline's own behaviour stands.
    module RelineCtrlGHandoff
      def input_key(key)
        return super unless ctrl_g?(key.char)
        # A single-line read has no buffer worth editing, and the whole
        # feature is opt-in: no editor resolved, no hand-off.
        return super unless @is_multiline && UI::Editor.external_editor

        # Snapshot BEFORE finishing: finish() is what releases the terminal for
        # the child editor, and the buffer must survive it.
        CtrlGState.fire!(whole_buffer)
        finish
        false
      end

      private

      # Reline delivers a control key's char as a one-character String ("\a"
      # for Ctrl+G); a pasted block arrives as a longer String, whose first
      # byte must not be mistaken for the key.
      def ctrl_g?(char)
        char.is_a?(String) ? (char.size == 1 && char.ord == UI::Editor::CTRL_G_BYTE) \
                           : char == UI::Editor::CTRL_G_BYTE
      end
    end

    # Ctrl+A toggles the command consent MODE (issue #224 follow-up).
    # Detected in #input_key - the same hook point as Esc-cancel - so it
    # works in the tty multiline read (note editor / idle prompt). Ctrl+A
    # is Reline's "beginning of line" cursor move; we CONSUME it and CLOSE
    # the read (finish) so the editor does not stay open after the toggle.
    # The MODE label produced is parked on CtrlAState for the reader to
    # hand back. A harness with no toggle (unit tests) makes the key a
    # no-op (label = nil) but still closes the read.
    module RelineCtrlAToggle
      # Ctrl+A arrives as a single byte (char == 1) - distinct from a
      # plain "a" (char == 97) and from ESC-prefixed keys.
      CTRL_A_CHAR = 1

      def input_key(key)
        if key.char == CTRL_A_CHAR
          CtrlAState.fire!(run_mode_toggle)
          finish
          return false
        end
        super
      end

      private

      # Flip the MODE on the shared harness (if one is reachable) and
      # return the new label (nil when there is no harness / no toggle).
      def run_mode_toggle
        harness = ::Task.current&.harness
        harness.respond_to?(:toggle_command_mode) ? harness.toggle_command_mode : nil
      rescue StandardError
        nil
      end
    end

    # Opt-in "double Enter submits" policy (issue #198 fallback for setups
    # where no submit key reaches the terminal - e.g. a remote host seen
    # through Windows Terminal). When `submit_on_enter` is enabled, Enter
    # on an EMPTY LAST LINE of a multiline emacs-mode buffer submits it;
    # every other Enter inserts a newline as usual. Pasted text never
    # triggers it: with bracketed paste the whole blob arrives at once so
    # ed_newline is not consulted for pasted breaks, and without bracketed
    # paste the PASTE_GRACE window after any observed paste suppresses the
    # policy (doc/reline_cursor_and_enter_handling.md section 6). Trade-off:
    # the buffer cannot END with a blank line as content while enabled.
    module RelineEnterPolicy
      PASTE_GRACE = 0.05

      class PasteGuard
        @last_seen = nil

        class << self
          def mark
            @last_seen = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end

          def clear!
            @last_seen = nil
          end

          def recent?
            return false if @last_seen.nil?

            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            now - @last_seen < PASTE_GRACE
          end
        end
      end

      def input_key(key)
        PasteGuard.mark if @in_pasting
        super
      end

      private

      def ed_newline(key)
        return super unless submit_on_empty_last_line?

        process_insert(force: true)
        finish
      end

      def submit_on_empty_last_line?
        return false unless EnterState.enabled?
        return false unless @is_multiline
        return false unless @config.editing_mode_is?(:emacs)
        return false if @in_pasting || PasteGuard.recent?

        @line_index == @buffer_of_lines.size - 1 &&
          @buffer_of_lines.last.to_s.strip.empty?
      end
    end
    # Ctrl+Enter submit (issue #198): byte 10 (LF) is Reline's default
    # mapping for a plain line break; on Windows Terminal reaching a remote
    # host (ssh / WSL2) Ctrl+Enter arrives as exactly this byte while Enter
    # sends CR (verified via showkey). The action respects the paste guard
    # (doc/reline_cursor_and_enter_handling.md section 7): an LF inside
    # pasted text without bracketed paste would otherwise submit at the
    # first line break.
    module RelineLFSubmit
      private

      def lf_force_submit(key)
        return key_newline(key) if @in_pasting || \
          RelineEnterPolicy::PasteGuard.recent?

        ed_force_submit(key)
      end
    end

    # Windows: a bare Esc arrives as a virtual key, not a byte. Translate
    # the first press (auto-repeat guarded) into the marker byte that
    # RelineEscCancel consumes in input_key.
    module WindowsEscHook
      VK_ESCAPE     = 0x1B
      MODIFIERS     = 0x1F  # Alt/Ctrl/Shift bits; a bare Esc has none set
      REPEAT_WINDOW = 0.6   # seconds - held keys auto-repeat faster

      def process_key_event(_repeat, vk, _scan, _char, ctrl)
        if vk == VK_ESCAPE && (ctrl & MODIFIERS).zero?
          now   = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          first = !@last_esc_at || now - @last_esc_at >= REPEAT_WINDOW
          @last_esc_at = now
          if first
            EscState.esc_pending = true
            @output_buf.push(EscState::ESC_MARKER.ord)
          end
          return
        end
        super
      end
    end

    private

    # True when this stream IS the process's real terminal stdin: a tty AND
    # the same IO (or same fileno) as $stdin. Reline.readline ignores the
    # stream handed to the editor and attaches to $stdin, so a fake-tty
    # stream in tests must never take this path.
    def tty?
      self.class.is_real_tty_stdin?(@stdin)
    end

    def self.tty_stream?(io)
      io.respond_to?(:tty?) && io.tty?
    end

    # True when two streams are the same IO: identical objects, or both
    # real file descriptors pointing at the same fd (e.g. $stdin re-read
    # through a wrapper). Non-file streams (StringIO, fakes) never match.
    def self.real_io?(io, other)
      return true if io.equal?(other)
      return false unless io.respond_to?(:fileno) && other.respond_to?(:fileno)

      a = io.fileno rescue nil
      b = other.fileno rescue nil
      !a.nil? && a == b
    end

    def dumb_read
      line = @stdin.gets
      return EDITOR_RESULT.new(nil, :eof) if line.nil?

      line = line.chomp
      return EDITOR_RESULT.new(line, :empty) if line.strip.empty?

      EDITOR_RESULT.new(line, :submitted)
    end

    def reline_read(prompt, prefill)
      self.class.install_esc!
      if prefill && !prefill.empty?
        Reline.pre_input_hook = -> do
          Reline.insert_text(prefill)
          Reline.pre_input_hook = nil
        end
      end
      text = Reline.readline(prompt, false) # add_history: false - editor lines are not commands
      return EDITOR_RESULT.new(nil, :eof) if text.nil?

      cancelled = Reline.line_editor.cancelled?
      status =
        if cancelled
          :cancelled
        elsif text.strip.empty?
          :empty
        else
          :submitted
        end
      EDITOR_RESULT.new(text, status)
    ensure
      Reline.pre_input_hook = nil
    end

    # TTY multiline read (issue #198 phase 3): same single-consumer rule as
    # reline_read - while open, Reline owns $stdin. Enter never submits; the
    # SUBMIT_KEY_SEQ key (bound by install_esc!) commits the buffer. The
    # block passed to readmultiline only guards the LAST line's Enter: it
    # returns false there so a plain Enter always inserts a newline (the
    # block is not even consulted mid-buffer - see Reline ed_newline). A
    # cancelled Esc returns the buffer intact as `text` - the CLI keeps it
    # as a draft for the next prompt.
    def reline_read_multiline(prompt, prefill)
      self.class.install_esc!
      if prefill && !prefill.empty?
        Reline.pre_input_hook = -> do
          Reline.insert_text(prefill)
          Reline.pre_input_hook = nil
        end
      end
      text = Reline.readmultiline(
        prompt, false, rprompt: prompt
      ) { |_buf| false }  # Enter always inserts a newline; submit is the key
      # Ctrl+G hand-off (issue #298): Reline is out of raw mode here (readmultiline
      # closes with_raw_input before returning), so the child editor may have the
      # terminal. :edited carries whatever the editor produced (nil when the editor
      # could not run) - the buffer stays the caller's draft either way.
      if CtrlGState.fired
        snapshot = CtrlGState.text.to_s
        CtrlGState.reset!
        return ctrl_g_result(snapshot)
      end
      return EDITOR_RESULT.new(nil, :eof) if text.nil?

      # The committed buffer may carry a trailing newline (readmultiline's
      # terminator); a cancelled Esc returns the raw buffer without one.
      text = text.chomp
      status = self.class.last_read_cancelled? ? :cancelled \
              : (text.strip.empty? ? :empty : :submitted)
      Reline::HISTORY << text if status == :submitted && !text.empty?
      EDITOR_RESULT.new(text, status)
    ensure
      # CtrlGState is captured into the hand-off above; clearing it here too
      # means a read that raised after fire! cannot leak the flag into the next.
      CtrlGState.reset!
      Reline.pre_input_hook = nil
    end

    # Run the external editor on the buffer Ctrl+G snapshotted and turn the
    # outcome into a read result. :edited always - never :submitted: an editor
    # hand-off is not a submission, so a caller that cannot treat a draft
    # (a dialog's choice loop) can mistake nothing for an answer.
    def ctrl_g_result(snapshot)
      result = ExternalEditor.new(self.class.external_editor).open(snapshot)
      EDITOR_RESULT.new(result.text, :edited, result.note)
    end

    # Install the editor key bindings exactly once per process. This mutates
    # GLOBAL Reline state (LineEditor prepended module + key bindings), so
    # it also affects the CLI's idle prompt: there a bare Esc cancels the
    # read and keeps the buffer as a draft for the next prompt (see
    # CLI#get_command), and SUBMIT_KEY_SEQ submits the multiline buffer
    # (issue #91 key model). The module is prepended only if not already
    # present, so repeated calls are safe.
    def self.install_esc!
      unless Reline::LineEditor.ancestors.include?(RelineEscCancel)
        Reline::LineEditor.prepend(RelineEscCancel)
      end
      # Opt-in double-Enter submit (issue #198): inert until
      # `submit_on_enter` is enabled - see the module's own docs.
      unless Reline::LineEditor.ancestors.include?(RelineEnterPolicy)
        Reline::LineEditor.prepend(RelineEnterPolicy)
      end
      # Ctrl+Enter submit on remote hosts seen through Windows Terminal:
      # Ctrl+Enter arrives as LF (byte 10) where plain Enter sends CR.
      unless Reline::LineEditor.ancestors.include?(RelineLFSubmit)
        Reline::LineEditor.prepend(RelineLFSubmit)
      end
      # Ctrl+A command-consent mode toggle (issue #224 follow-up): works in
      # any tty read; the reader surfaces the fired state to its caller.
      unless Reline::LineEditor.ancestors.include?(RelineCtrlAToggle)
        Reline::LineEditor.prepend(RelineCtrlAToggle)
      end
      # Ctrl+G external-editor hand-off (issue #298): taken only when
      # `external_editor` is set, so the key stays Reline's own by default.
      unless Reline::LineEditor.ancestors.include?(RelineCtrlGHandoff)
        Reline::LineEditor.prepend(RelineCtrlGHandoff)
      end
      cfg = Reline.core.config
      cfg.keyseq_timeout = 100
      # SUBMIT_KEY_SEQ: submit the whole multiline buffer. The Windows
      # IOGate maps Ctrl+Enter/Shift+Enter to these bytes; Unix terminals
      # produce them with Alt+Enter (see doc/reline_cursor_and_enter_
      # handling.md, section 7). On a remote host seen through Windows
      # Terminal (ssh / WSL2) plain Alt+Enter and Ctrl+Enter never arrive,
      # but AltGr+Enter does - and the CSI binding below covers kcm setups.
      # add is idempotent for a repeated key -> action pair.
      cfg.add_default_key_binding_by_keymap(:emacs, SUBMIT_KEY_SEQ, :ed_force_submit)
      # CTRL_ENTER_LF_BYTE: on those same remote setups Ctrl+Enter arrives
      # as LF (byte 10) while Enter sends CR (showkey-verified). Replaces
      # Reline's default ed_newline mapping; the guard keeps pasted LFs
      # from submitting (doc section 7 side note).
      cfg.add_default_key_binding_by_keymap(:emacs, [CTRL_ENTER_LF_BYTE],
                                           :lf_force_submit)
      # CSI_CTRL_ENTER_SEQ: the portable submit key (issue #198). Sent for
      # Ctrl+Enter only by terminals with an extended keyboard protocol;
      # everywhere else it is never received and stays an inert binding.
      cfg.add_default_key_binding_by_keymap(:emacs,
                                           CSI_CTRL_ENTER_SEQ,
                                           :ed_force_submit)
      # Reline::Windows exists only on the Windows IOGate (undefined on Unix),
      # so it must be guarded before the is_a? check.
      if defined?(Reline::Windows) && Reline::IOGate.is_a?(Reline::Windows)
        Reline::Windows.prepend(WindowsEscHook)
      else
        cfg.add_default_key_binding_by_keymap(:emacs, [ESC_KEY_BYTE], :cancel_input)
      end
    end

    # True when the LAST Reline read was cancelled with Esc (the buffer
    # is still intact and readable via whole_buffer). Used by UI::Editor
    # itself to map a cancelled multiline read onto its :cancelled status.
    def self.last_read_cancelled?
      Reline.line_editor.respond_to?(:cancelled?) ? !!Reline.line_editor.cancelled? : false
    end
  end
end
