# frozen_string_literal: true

require_relative "ui/editor"

# The ONE input path: prompt and mid-turn note are the same read, and the edit
# state belongs to the poll loop, not to a turn. Design: doc/task_model_design.md.
class InputPath
  # An editor round-trip is never a submission (Esc keeps the buffer, Ctrl+G is
  # the same round-trip, a bare Enter means the user changed their mind). The
  # caller keeps its own draft, so one reader can serve the idle prompt and the
  # running turn without a closed editor reading as a submission.
  ROUND_TRIP = %i[edited cancelled empty].freeze

  # Read live so the TARGET can point at another foreground job without
  # rebuilding the reader: a foreground switch changes which job an input
  # event goes to.
  attr_accessor :registry, :target, :command_handler
  attr_accessor :edit_state

  def initialize(
    ui:,
    registry: nil,
    target: nil,
    editor: nil,
    prompt: nil
  )
    @ui         = ui
    @registry   = registry
    @target     = target
    @editor     = editor
    @prompt     = prompt
    @edit_state = false
  end

  # The peek: the loop falls into the edit state when a keypress is seen. A
  # stream that cannot answer the peek never enters it (issue #473).
  def pending?
    return false unless stdin.respond_to?(:input_pending?)
    return false unless stdin.input_pending? == true

    @edit_state = true
    true
  end

  def edit_state?
    @edit_state
  end

  def round_trip?(status)
    ROUND_TRIP.include?(status)
  end

  # Read one block: Enter inserts a newline, the submit key commits the whole
  # block. The caller passes its own draft as the prefill and decides what EOF
  # means for itself (the idle prompt quits, a running turn aborts).
  def read(prefill: nil)
    @edit_state = true
    result = editor.read_multiline(**prompt_kwargs, prefill:)
    @edit_state = false
    result
  end

  # Route one submitted block as ONE input event to the target job's inbox. The
  # override rule (a note replaces a pending note only) lives in Job#deliver, so
  # this names the target and nothing else. Without a registry there is no inbox
  # to write, which is what keeps the FIFO rule: a note must never steal the
  # answer a pending dialog request is waiting for.
  def route(text)
    event = resolved_registry ? resolved_registry.note_event(text) :
      { type: :note, content: text }
    resolved_registry&.route_input(job_id, event)
    event
  end

  def stdin
    @ui.respond_to?(:stdin) ? @ui.stdin : editor.stdin
  end

  private

  def prompt_kwargs
    @prompt.nil? ? {} : { prompt: @prompt }
  end

  def resolved_registry
    @registry.respond_to?(:call) ? @registry.call : @registry
  end

  def editor
    @editor ||= UI::Editor.new(stdin)
  end

  def job_id
    target = @target.respond_to?(:call) ? @target.call : @target
    target&.id
  end
end
