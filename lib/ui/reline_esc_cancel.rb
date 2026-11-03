# frozen_string_literal: true

require "reline"

# Esc-cancel LineEditor patch. Design: doc/editor_input_design.md.
module UI
  class Editor
    # Shared Esc-state between the LineEditor patch and the Windows key hook.
    module EscState
      ESC_MARKER = "\x1D"

      class << self
        attr_accessor :esc_pending
      end
    end

    # A bare Esc marks the read cancelled; the buffer stays INTACT so the
    # caller can hand it back as a prefilled draft on the next read.
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

      # :cancel_input is the bound action for bare Esc on Unix; on Windows the
      # hook injects the marker byte and this consumes it.
      def cancel_input(_key)
        @cancelled = true
        finish
      end
    end
  end
end
