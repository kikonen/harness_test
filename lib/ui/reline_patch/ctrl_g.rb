# frozen_string_literal: true

require "reline"

# Ctrl+G external-editor hand-off. Design: doc/external_editor.md. The READER
# spawns the child (not this patch) because Reline must have left raw mode
# before a child process gets the terminal; the snapshot rides on this module.
module UI
  module RelinePatch
    # The hand-off fires only when the read is multiline AND external_editor
    # is resolved; otherwise the key keeps what Reline's own emacs mapping
    # does with it. The parked snapshot lives on the patch module itself.
    module CtrlGHandoff
      class << self
        attr_accessor :fired, :text

        def reset!
          @fired = false
          @text  = nil
        end

        def fire!(text)
          @fired = true
          @text  = text
        end
      end

      def input_key(key)
        return super unless UI::Editor.control_key?(key.char, UI::Editor::CTRL_G_BYTE)
        return super unless @is_multiline && UI::Editor.external_editor

        # Snapshot BEFORE finishing: finish() is what releases the terminal for
        # the child editor, and the buffer must survive it.
        CtrlGHandoff.fire!(whole_buffer)
        finish
        false
      end
    end
  end
end
