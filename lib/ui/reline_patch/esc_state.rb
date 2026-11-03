# frozen_string_literal: true

require "reline"

# Shared Esc-state between the LineEditor Esc patch and the Windows key hook.
# Design: doc/editor_input_design.md.
module UI
  module RelinePatch
    module EscState
      ESC_MARKER = "\x1D"

      class << self
        attr_accessor :esc_pending
      end
    end
  end
end
