# frozen_string_literal: true

require_relative "task"
require_relative "ui"

# -- PromptReader ---------------------------------------------------------

# The idle-prompt read of the run loop: render the modeline (model + posture
# tags + context indicator), read one multiline buffer through UI::Editor, and
# re-prompt until the user submits a command (returned) or hits Ctrl-D on an
# empty buffer (nil => quit). The draft persists for the reader's life so an
# Esc'd or edited buffer is prefilled at the next prompt. The harness is a live
# reader (a callable) because a mid-run /resume swaps the Harness the modeline
# reads. Key model and rationale: doc/reline_cursor_and_enter_handling.md.
class PromptReader
  def initialize(ui:, harness:)
    @ui = ui
    @harness = harness # a callable: a mid-run /resume swaps the Harness
    @draft = nil
  end

  # Returns the submitted command, or nil when the user quits (Ctrl-D on an
  # empty buffer). Re-prompts on Esc / Ctrl+G / bare Enter / Ctrl+A instead of
  # returning, so the run loop only ever sees a submitted command or nil.
  def read
    loop do
      harness = @harness.call
      render_modeline(harness)

      result = UI::Editor
        .new(@ui.stdin)
        .read_multiline(prompt: "  ", prefill: @draft)

      # Ctrl+A toggled the consent mode while the prompt was open: ack it and
      # re-prompt (no command was typed); the next turn's badge shows the mode.
      if UI::Editor::CtrlAState.fired
        label = UI::Editor::CtrlAState.label
        UI::Editor::CtrlAState.reset!
        @ui.puts label.nil? ? "  (command mode toggle unavailable - safety check off)" \
                            : "  [mode is now #{label}]"
        next
      end

      case result.status
      when :eof
        return nil # Ctrl-D on an empty buffer => quit
      when :edited
        # Ctrl+G hand-off: the editor's text (or the untouched buffer when the
        # editor could not run) becomes the DRAFT; the submit key still sends it.
        @draft = result.text.to_s
        @ui.puts "  (#{result.note} - draft kept; press the submit key to send)"
        next
      when :cancelled
        @draft = result.text.to_s # Esc: keep the buffer, prefill next
        @ui.puts "  (cancelled - draft kept; press the submit key to send)"
        next
      when :empty
        next # bare Enter: re-prompt, draft untouched
      end

      @draft = nil
      return result.text.to_s.gsub("\r\n", "\n")
    end
  end

  private

  # The modeline: a bracketed model name (effort inside it) then the posture
  # tags, then the context indicator on the SAME line to save vertical space.
  # The posture tags come from the SAME builder the spinner badge uses
  # (Task.mode_badge), so consent and streaming cannot read differently in the
  # two places (the spinner only exists while the model works, not while idle).
  def render_modeline(harness)
    model  = harness.session_manager.active_model_name
    effort = harness.session_manager.param_overrides.reasoning_effort_display
    tags   = ["[#{model ? "#{model} (#{effort})" : effort}]"]
    badge  = Task.mode_badge(harness)
    tags  << badge if badge
    prefix = "#{tags.join(' ')} > "
    ctx = harness.context_indicator
    @ui.puts ctx ? "#{ctx} #{prefix}" : prefix
    @ui.flush
  end
end
