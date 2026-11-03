# frozen_string_literal: true

require "reline"

# Opt-in "double Enter submits" policy. Design: doc/editor_input_design.md and
# doc/reline_cursor_and_enter_handling.md sections 6-7 (paste guard rationale).
module UI
  class Editor
    # Process-global flag (set once at startup from the config key
    # `double_enter_submit`; see Editor.submit_on_enter=).
    module EnterState
      class << self
        attr_writer :enabled

        def enabled? = !!@enabled
      end
    end

    module RelineEnterPolicy
      PASTE_GRACE = 0.05

      # Shared by RelineEnterPolicy and RelineLFSubmit: the last time a paste
      # was observed. Any Enter/LF inside or just after a paste inserts a
      # newline instead of submitting.
      class PasteGuard
        @last_seen = nil

        class << self
          def mark
            @last_seen = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end

          def clear!
            @last_seen = nil
          end

          def recent?
            return false if @last_seen.nil?

            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            now - @last_seen < PASTE_GRACE
          end
        end
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
        return false unless EnterState.enabled?
        return false unless @is_multiline
        return false unless @config.editing_mode_is?(:emacs)
        return false if @in_pasting || PasteGuard.recent?

        @line_index == @buffer_of_lines.size - 1 &&
          @buffer_of_lines.last.to_s.strip.empty?
      end
    end
  end
end
