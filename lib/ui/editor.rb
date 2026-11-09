# frozen_string_literal: true

require "reline"
require_relative "external_editor"
require_relative "reline_patch/esc_state"
require_relative "reline_patch/esc_cancel"
require_relative "reline_patch/paste_guard"
require_relative "reline_patch/enter_policy"
require_relative "reline_patch/lf_submit"
require_relative "reline_patch/ctrl_g"
require_relative "reline_patch/windows_esc_hook"

# UI::Editor: the shared keyboard reader for the note editor, dialog choice
# line, and CLI idle prompt. The Reline-level key patches live in UI::RelinePatch
# (lib/ui/reline_patch/); this file holds only the Editor core. Architecture and
# the EditorResult status contract: doc/editor_input_design.md.
module UI
  class Editor
    DEFAULT_PROMPT = "note> "
    # Reline's PROMPT for dialog choice lines (the steering note uses DEFAULT_PROMPT).
    DIALOG_PROMPT = "> "
    # note carries the reader's own explanation of a non-standard status
    # (today: why an external-editor hand-off produced no text to send).
    EDITOR_RESULT = Struct.new(:text, :status, :note)

    # Key bytes (Reline keymap sequences; see doc/reline_cursor_and_enter_handling.md
    # section 7 for why these are the portable choices).
    ESC_KEY_BYTE = 27
    CR_KEY_BYTE  = 13
    # Ctrl+G (BEL) arrives to #input_key as a one-character String ("\a"),
    # not an Integer. See control_key?.
    CTRL_G_BYTE = 7
    # The submit key ESC-then-CR. Platform split (Windows IOGate vs Unix Alt+Enter
    # vs remote-via-Windows-Terminal LF) is explained in
    # doc/reline_cursor_and_enter_handling.md section 7 and doc/editor_input_design.md.
    SUBMIT_KEY_SEQ = [ESC_KEY_BYTE, CR_KEY_BYTE].freeze
    # Ctrl+Enter arrives as LF (byte 10) on a remote host seen through Windows
    # Terminal, where plain Enter sends CR - distinguishable at the Reline level.
    CTRL_ENTER_LF_BYTE = 10
    CSI_OPEN_BYTE   = 91   # '['
    DIGIT_1_BYTE    = 49
    DIGIT_3_BYTE    = 51
    CSI_END_TILDE   = 126  # '~'
    # CSI Ctrl+Enter ("ESC [ 1 3 ~"), sent by terminals with an extended keyboard
    # protocol (kitty/kamadb/kcm). Inert on terminals that never send it.
    CSI_CTRL_ENTER_SEQ = [ESC_KEY_BYTE, CSI_OPEN_BYTE, DIGIT_1_BYTE,
                         DIGIT_3_BYTE, CSI_END_TILDE].freeze

    # The RelinePatch modules, in prepend order. Kept as the single ordered list
    # so the load-bearing precedence is stated once.
    PATCH_ORDER = [
      RelinePatch::EscCancel,
      RelinePatch::EnterPolicy,
      RelinePatch::LFSubmit,
      RelinePatch::CtrlGHandoff
    ].freeze

    # Does this keypress carry the control key whose byte is `byte`? Every
    # intercepted control key shares this one rule: match the byte whether Reline
    # sent a one-character String or an Integer, and reject a longer String (a
    # pasted block) so its first byte is not mistaken for the key.
    def self.control_key?(char, byte)
      char.is_a?(String) ? (char.size == 1 && char.ord == byte) \
                         : char == byte
    end

    # Ctrl+G external-editor command. Process-global (a fact about how this run
    # reads input, like submit_on_enter); read AT KEYPRESS time, so nil means the
    # key is not taken.
    def self.external_editor=(value)
      @external_editor = value.to_s.strip.empty? ? nil : value.to_s.strip
    end

    def self.external_editor
      @external_editor
    end

    def self.submit_on_enter=(value)
      RelinePatch::EnterPolicy.enabled = value
    end

    def self.submit_on_enter?
      RelinePatch::EnterPolicy.enabled?
    end

    def initialize(stdin)
      @stdin = stdin
    end

    # Read one line. `prefill` (a draft from a previously cancelled editor) is
    # inserted into the Reline buffer on tty only.
    def read(prompt: DEFAULT_PROMPT, prefill: nil)
      tty? ? reline_read(prompt, prefill) : dumb_read
    end

    def read_multiline(prompt: DEFAULT_PROMPT, prefill: nil)
      tty? ? reline_read_multiline(prompt, prefill) : dumb_read
    end

    # Take the Reline path only when $stdin IS a terminal AND `io` IS that same
    # stream (same object or same fd). A fake tty? stream with its own fileno
    # falls to the dumb path, so a spec can never block on the real console
    # (issue #202's "stuck" look; see UI::Editor routing tests).
    def self.is_real_tty_stdin?(io) = tty_stream?($stdin) && real_io?(io, $stdin)

    private

    def tty?
      self.class.is_real_tty_stdin?(@stdin)
    end

    def self.tty_stream?(io)
      io.respond_to?(:tty?) && io.tty?
    end

    # True when two streams are the same IO: identical objects, or both real
    # fds pointing at the same fd. Non-file streams (StringIO, fakes) never match.
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
      self.class.install_reline_patches!
      install_prefill(prefill)
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

    # Enter never submits; the SUBMIT_KEY_SEQ key commits the buffer. The
    # readmultiline block returns false so a plain Enter always inserts a
    # newline. A cancelled Esc returns the buffer intact (the CLI keeps it as a
    # draft. Do NOT pass rprompt to readmultiline: Reline paints rprompt
    # right-aligned on the first visible row, so a rprompt equal to the left
    # prompt glues a stray copy of 'note> ' to the right edge of the terminal
    # (issue #481). Design in doc/editor_input_design.md.
    def reline_read_multiline(prompt, prefill)
      self.class.install_reline_patches!
      install_prefill(prefill)
      text = Reline.readmultiline(prompt, false) do |_buf|
        false # Enter always inserts a newline; submit is the key
      end
      if RelinePatch::CtrlGHandoff.fired
        snapshot = RelinePatch::CtrlGHandoff.text.to_s
        RelinePatch::CtrlGHandoff.reset!
        return ctrl_g_result(snapshot)
      end
      return EDITOR_RESULT.new(nil, :eof) if text.nil?

      text = text.chomp
      status = self.class.last_read_cancelled? ? :cancelled \
              : (text.strip.empty? ? :empty : :submitted)
      Reline::HISTORY << text if status == :submitted && !text.empty?
      EDITOR_RESULT.new(text, status)
    ensure
      # Clearing CtrlGHandoff here too means a read that raised after fire! cannot
      # leak the flag into the next.
      RelinePatch::CtrlGHandoff.reset!
      Reline.pre_input_hook = nil
    end

    def install_prefill(prefill)
      return if prefill.nil? || prefill.empty?

      Reline.pre_input_hook = -> do
        Reline.insert_text(prefill)
        Reline.pre_input_hook = nil
      end
    end

    # :edited always - never :submitted: an editor hand-off is not a submission,
    # so a caller that cannot treat a draft (a dialog's choice loop) cannot
    # mistake nothing for an answer.
    def ctrl_g_result(snapshot)
      result = ExternalEditor.new(self.class.external_editor).open(snapshot)
      EDITOR_RESULT.new(result.text, :edited, result.note)
    end

    # Prepends each RelinePatch LineEditor module (idempotently, only if not
    # already present) and binds the submit keys, mutating GLOBAL Reline state
    # once per process. Prepend ORDER (last prepended = highest keypress
    # priority) is load-bearing. Design: doc/editor_input_design.md.
    def self.install_reline_patches!
      PATCH_ORDER.each do |patch|
        Reline::LineEditor.prepend(patch) unless Reline::LineEditor.ancestors.include?(patch)
      end
      cfg = Reline.core.config
      cfg.keyseq_timeout = 100
      # add is idempotent for a repeated key -> action pair.
      cfg.add_default_key_binding_by_keymap(:emacs, SUBMIT_KEY_SEQ, :ed_force_submit)
      cfg.add_default_key_binding_by_keymap(:emacs, [CTRL_ENTER_LF_BYTE],
                                           :lf_force_submit)
      cfg.add_default_key_binding_by_keymap(:emacs, CSI_CTRL_ENTER_SEQ, :ed_force_submit)
      # Reline::Windows exists only on the Windows IOGate (undefined on Unix),
      # so guard before the is_a? check.
      if defined?(Reline::Windows) && Reline::IOGate.is_a?(Reline::Windows)
        Reline::Windows.prepend(RelinePatch::WindowsEscHook)
      else
        cfg.add_default_key_binding_by_keymap(:emacs, [ESC_KEY_BYTE], :cancel_input)
      end
    end

    # True when the LAST Reline read was cancelled with Esc (the buffer is still
    # intact via whole_buffer).
    def self.last_read_cancelled?
      Reline.line_editor.respond_to?(:cancelled?) ? !!Reline.line_editor.cancelled? : false
    end
  end
end
