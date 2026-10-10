# frozen_string_literal: true

require 'reline'

# -- UI::Editor -------------------------------------------------------------
#
# The shared single-line editor primitive (issue #36 / #198). Two users:
#   * the mid-turn steering flow - the Task drain loop peeks
#     `stdin.input_pending?` on every tick (cross-platform, no reader
#     thread - see Task); on a hit it opens this editor ON THE MAIN THREAD
#     with PROMPT 'note> ', so nothing can race for the keyboard
#     (issue #198's stuck-dialog / lost-line bug class dies by
#     construction).
#   * UI::Dialog's choice line (issue #198 phase 2) - on a tty the dialog
#     routes its single-line choice read through this editor too, so EVERY
#     in-turn stdin read goes through one code path.
#
# Two read paths, chosen at read time:
#   * tty: Reline single-line read. Esc keeps the draft (cancelled? + the
#     editor buffer), ^C aborts with a clean Interrupt, Ctrl-D on an empty
#     line is :eof. A previously cancelled draft comes back prefilled via
#     the Reline pre_input_hook.
#   * non-tty (pipes in specs, dumb terminals): plain gets() - Enter
#     commits, a blank/bare Enter is :empty, stream close is :eof.
#
# Returns an EditorResult(text, status); status is one of :submitted /
# :empty / :cancelled / :eof. Each caller interprets the statuses in its
# own domain: the steering flow treats :empty as "no note" and :eof as
# "abort turn"; a dialog treats :empty as "re-prompt" and :eof as
# "cancel the dialog".

module UI
  class Editor
    DEFAULT_PROMPT = 'note> '
    # Reline's PROMPT for dialog choice lines (the steering note uses
    # DEFAULT_PROMPT).
    DIALOG_PROMPT = '> '
    EDITOR_RESULT = Struct.new(:text, :status)

    def initialize(stdin)
      @stdin = stdin
    end

    # Read one line from stdin. `prompt` is the editor prompt string;
    # `prefill` (a draft from a previously cancelled editor) is inserted
    # into the Reline buffer on tty only.
    def read(prompt: DEFAULT_PROMPT, prefill: nil)
      tty? ? reline_read(prompt, prefill) : dumb_read
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

    # Install the Esc-cancels binding exactly once per process. This mutates
    # GLOBAL Reline state (LineEditor prepended module + key bindings), so
    # it also affects the CLI's idle prompt: there a bare Esc now cancels
    # the input line without sending it (like bash's Ctrl+U) - see
    # CLI#get_command, which discards cancelled input. The module is
    # prepended only if not already present, so repeated calls are safe.
    def self.install_esc!
      unless Reline::LineEditor.ancestors.include?(RelineEscCancel)
        Reline::LineEditor.prepend(RelineEscCancel)
      end
      # Reline::Windows exists only on the Windows IOGate (undefined on Unix),
      # so it must be guarded before the is_a? check.
      if defined?(Reline::Windows) && Reline::IOGate.is_a?(Reline::Windows)
        Reline::Windows.prepend(WindowsEscHook)
      else
        cfg = Reline.core.config
        cfg.add_default_key_binding_by_keymap(:emacs, [27], :cancel_input)
        cfg.keyseq_timeout = 100
      end
    end

    # True when the LAST Reline read was cancelled with Esc (the buffer
    # is still intact and readable via whole_buffer). CLI#get_command uses
    # this to drop cancelled input instead of sending it to the model;
    # UI::Dialog uses it as a "draft kept" signal on re-prompt.
    def self.last_read_cancelled?
      Reline.line_editor.respond_to?(:cancelled?) ? !!Reline.line_editor.cancelled? : false
    end
  end
end
