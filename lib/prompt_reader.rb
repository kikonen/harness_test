# frozen_string_literal: true

require_relative "input_path"
require_relative "poller"
require_relative "ui"

# -- PromptReader ---------------------------------------------------------

# The idle-prompt read of the run loop: render the modeline (model + posture
# tags + context indicator), read one multiline buffer through the ONE input
# path, and re-prompt until the user submits a command (returned) or hits
# Ctrl-D on an empty buffer (nil => quit). The draft persists for the reader's
# life so an Esc'd or edited buffer is prefilled at the next prompt. The harness
# is a live reader (a callable) so the modeline always reads the current Harness.
# Key model and rationale: doc/reline_cursor_and_enter_handling.md.
class PromptReader
  # The prompt the idle read uses (the input path's own default is the note
  # prompt; the two are the SAME read, only the label differs).
  PROMPT = "  "

  attr_reader :input_path

  def initialize(ui:, harness:, input_path: nil)
    @ui = ui
    @harness = harness # a live reader: the modeline reads the current Harness
    @draft = nil
    @input_path = input_path || InputPath.new(ui:, prompt: PROMPT)
  end

  # Returns the submitted command, or nil when the user quits (Ctrl-D on an
  # empty buffer). Re-prompts on Esc / Ctrl+G / bare Enter instead of returning,
  # so the run loop only ever sees a submitted command or nil.
  def read
    loop do
      harness = @harness.call
      render_modeline(harness)

      result = input_path.read(prefill: @draft)

      case result.status
      when :eof
        return nil # Ctrl-D on an empty buffer => quit
      when *InputPath::ROUND_TRIP
        # The buffer is kept as the DRAFT; the submit key still sends it. An
        # editor round-trip is never a submission (issue #155: cancel is
        # explicit), so the read re-prompts with the prefill.
        @draft = result.text.to_s
        note = result.note
        @ui.puts "  (#{note} - draft kept; press the submit key to send)" if note
        next
      end

      @draft = nil
      return result.text.to_s.gsub("\r\n", "\n")
    end
  end

  # True while the run's single poll loop is in the edit state - the state the
  # loop enters when typing starts. Idle and mid-turn share it because they
  # share this one reader (issue #286).
  def edit_state?
    input_path.edit_state?
  end

  private

  # The modeline: a bracketed model name (effort inside it) then the posture
  # tags, then the context indicator on the SAME line to save vertical space.
  # The posture tags come from the SAME builder the spinner badge uses
  # (Poller.mode_badge), so consent and streaming cannot read differently in the
  # two places (the spinner only exists while the model works, not while idle).
  def render_modeline(harness)
    model  = harness.session_manager.active_model_name
    effort = harness.session_manager.param_overrides.reasoning_effort_display
    tags   = ["[#{model ? "#{model} (#{effort})" : effort}]"]
    badge  = Poller.mode_badge(harness)
    tags  << badge if badge
    prefix = "#{tags.join(' ')} > "
    ctx = harness.context_indicator
    @ui.puts ctx ? "#{ctx} #{prefix}" : prefix
    @ui.flush
  end
end
