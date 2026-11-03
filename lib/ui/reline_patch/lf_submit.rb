# frozen_string_literal: true

require "reline"
require_relative "paste_guard"

# Ctrl+Enter submit on a remote host seen through Windows Terminal (LF, byte 10).
# Guarded by the shared PasteGuard so an LF inside pasted text inserts a newline
# instead of submitting at the first line break.
# Design: doc/editor_input_design.md and doc/reline_cursor_and_enter_handling.md
# section 7.
module UI
  module RelinePatch
    module LFSubmit
      private

      def lf_force_submit(key)
        return key_newline(key) if @in_pasting || PasteGuard.recent?

        ed_force_submit(key)
      end
    end
  end
end
