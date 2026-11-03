# frozen_string_literal: true

require "reline"
require_relative "paste_guard"

# Opt-in "double Enter submits" policy: Enter submits only when the cursor
# sits on an EMPTY last line of a multiline emacs read, never mid-paste.
# Enabled once at startup from the config key `double_enter_submit`
# (see Editor.submit_on_enter=). Design: doc/editor_input_design.md and
# doc/reline_cursor_and_enter_handling.md sections 6-7.
module UI
  module RelinePatch
    module EnterPolicy
      # Process-global switch, read at keypress time. The accessor lives on the
      # patch module itself; #ed_newline reaches it by the module's name (a
      # prepended instance's self.class is Reline::LineEditor, not this module).
      class << self
        attr_writer :enabled

        def enabled? = !!@enabled
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
        return false unless EnterPolicy.enabled?
        return false unless @is_multiline
        return false unless @config.editing_mode_is?(:emacs)
        return false if @in_pasting || PasteGuard.recent?

        @line_index == @buffer_of_lines.size - 1 &&
          @buffer_of_lines.last.to_s.strip.empty?
      end
    end
  end
end
