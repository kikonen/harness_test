# frozen_string_literal: true

require "reline"
require_relative "reline_esc_cancel"

# Windows IOGate only: a bare Esc arrives as a virtual key, not a byte. Design:
# doc/editor_input_design.md. Translated to EscState::ESC_MARKER, which
# RelineEscCancel consumes in its input_key.
module UI
  class Editor
    module WindowsEscHook
      VK_ESCAPE     = 0x1B
      MODIFIERS     = 0x1F  # Alt/Ctrl/Shift bits; a bare Esc has none set
      REPEAT_WINDOW = 0.6   # seconds - held keys auto-repeat faster

      def process_key_event(_repeat, key_code, _scan, _char, ctrl)
        if key_code == VK_ESCAPE && (ctrl & MODIFIERS).zero?
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
  end
end
