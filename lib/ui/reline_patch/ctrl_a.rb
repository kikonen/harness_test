# frozen_string_literal: true

require "reline"

# Ctrl+A command-consent MODE toggle. The MODE itself is documented in
# doc/safety_check_design.md; this file covers the key interception. The
# fired/label state the reader hands back rides on this module's own accessor
# (PromptReader#read and Task.poll_for_note read it). Shared detection rule:
# UI::Editor.control_key? (doc/editor_input_design.md).
module UI
  module RelinePatch
    # Ctrl+A is Reline's "beginning of line" cursor move; we consume it and
    # finish so the editor does not stay open after the toggle. A harness
    # with no toggle (unit tests) makes the key a no-op (label = nil) but
    # still closes the read.
    module CtrlAToggle
      # Process-global parked state; the accessor lives on the patch module
      # itself. A prepended instance's #input_key reaches it by the module's
      # name (its self.class is Reline::LineEditor, not this module).
      class << self
        attr_accessor :fired, :label

        def reset!
          @fired = false
          @label = nil
        end

        def fire!(label)
          @fired = true
          @label = label
        end
      end

      def input_key(key)
        if UI::Editor.control_key?(key.char, UI::Editor::CTRL_A_BYTE)
          CtrlAToggle.fire!(run_mode_toggle)
          finish
          return false
        end
        super
      end

      private

      # Flip the MODE on the shared harness (if one is reachable) and return
      # the new label (nil when there is no harness / no toggle).
      def run_mode_toggle
        harness = ::Task.current&.harness
        harness.respond_to?(:toggle_command_mode) ? harness.toggle_command_mode : nil
      rescue StandardError
        nil
      end
    end
  end
end
