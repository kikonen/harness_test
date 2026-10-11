# frozen_string_literal: true

require 'reline'

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
#     Ctrl+Enter submits the whole buffer (issue #91: no backslash or
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
    DEFAULT_PROMPT = 'note> '
    # Reline's PROMPT for dialog choice lines (the steering note uses
    # DEFAULT_PROMPT).
    DIALOG_PROMPT = '> '
    EDITOR_RESULT = Struct.new(:text, :status)

    # Key bytes (Reline keymap sequences; see doc/reline_cursor_and_
    # enter_handling.md section 7 for why these are the portable choices).
    ESC_KEY_BYTE = 27   # Escape character (bare Esc cancels the read)
    CR_KEY_BYTE  = 13   # Carriage Return (plain Enter inserts a newline)
    # The submit key: ESC then CR. The Windows IOGate maps Ctrl+Enter and
    # Shift+Enter to these bytes; Unix terminals produce them with
    # Alt+Enter (Ctrl/Shift+Enter there are indistinguishable from a plain
    # Enter, so that is the documented platform split).
    SUBMIT_KEY_SEQ = [ESC_KEY_BYTE, CR_KEY_BYTE].freeze

    def initialize(stdin)
      @stdin = stdin
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
    #     SUBMIT_KEY_SEQ, bound to Reline's ed_force_submit by install_esc!;
    #     Ctrl/Shift+Enter on Windows, Alt+Enter on most Unix terminals)
    #     commits the whole buffer. Backslashes are content - never
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
      def reset_variables(prompt = '')
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
      return EDITOR_RESULT.new(nil, :eof) if text.nil?

      # The committed buffer may carry a trailing newline (readmultiline's
      # terminator); a cancelled Esc returns the raw buffer without one.
      text = text.chomp
      status = self.class.last_read_cancelled? ? :cancelled \
              : (text.strip.empty? ? :empty : :submitted)
      Reline::HISTORY << text if status == :submitted && !text.empty?
      EDITOR_RESULT.new(text, status)
    ensure
      Reline.pre_input_hook = nil
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
      cfg = Reline.core.config
      cfg.keyseq_timeout = 100
      # SUBMIT_KEY_SEQ: submit the whole multiline buffer. The Windows
      # IOGate maps Ctrl+Enter/Shift+Enter to these bytes; Unix terminals
      # produce them with Alt+Enter (see doc/reline_cursor_and_enter_
      # handling.md, section 7). add is idempotent for a repeated key ->
      # action pair.
      cfg.add_default_key_binding_by_keymap(:emacs, SUBMIT_KEY_SEQ, :ed_force_submit)
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
