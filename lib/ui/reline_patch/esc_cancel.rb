# frozen_string_literal: true

require "reline"
require_relative "esc_state"

# A bare Esc marks the read cancelled; the buffer stays INTACT so the caller
# can hand it back as a prefilled draft on the next read.
# Design: doc/editor_input_design.md.
module UI
  module RelinePatch
    module EscCancel
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
