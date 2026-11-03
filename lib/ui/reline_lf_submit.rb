# frozen_string_literal: true

require "reline"
require_relative "reline_enter_policy"

# Ctrl+Enter submit on a remote host seen through Windows Terminal (LF, byte 10).
# Design: doc/editor_input_design.md and doc/reline_cursor_and_enter_handling.md
# section 7 (paste-guard side note).
module UI
  class Editor
    module RelineLFSubmit
      private

      # Reuses RelineEnterPolicy's PasteGuard so an LF inside pasted text
      # inserts a newline instead of submitting at the first line break.
      def lf_force_submit(key)
        return key_newline(key) if @in_pasting || \
          RelineEnterPolicy::PasteGuard.recent?

        ed_force_submit(key)
      end
    end
  end
end
