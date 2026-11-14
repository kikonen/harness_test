# frozen_string_literal: true

require_relative "task"
require_relative "tool"

# Shared wrapper for running an LLM round on a Task thread (the
# single-thread I/O rule, issue #40): the block runs on a task thread and
# all its console I/O is serialized through the main-thread drain loop.
# Without it, Task.emit events (spinner, response lines) are silently
# dropped and any dialog blocks the console - the log moves but the console
# looks stuck (issue #235). A task error is the :kind role, so the bracket shape
# belongs to UI::Renderer and not to this emitter (#474, increment 22).
#
# Included by anything that drives an LLM round: CommandHandler (direct
# prompts) and the Command subclasses that do (/retry issue #235, /compact
# issue #253). The includer must expose #harness and #ui.
module TaskRunner
  def run_on_task
    emit_role(:gap, "")
    error, task = Task.run(harness:, ui:) { |_t| yield }
    # Feed the turn's buffer tail into the harness' run OutputBuffer (the
    # durable both-sides record) so a later resume can redraw it (issue #458).
    harness.absorb_turn(task) if harness.respond_to?(:absorb_turn)
    emit_role(:kind, error, origin: "task error") if error
    emit_role(:gap, "")
  end

  # Console line emitted from INSIDE a task block. A task thread must never
  # write to a stream (single-thread I/O rule, issue #40), so the line goes
  # as the :text role through the one router, #status_event - the only place that
  # asks for the active Task.
  def emit_line(text)
    status_event(:text, text, "command")
  end

  # Main-thread counterpart to Tool.push_status. A command runs on the main
  # thread with no active Task, so there is no outbox to carry a typed event:
  # the role is rendered to the console directly through the SAME UI::Renderer
  # the drain loop and CommandRunner use, painted with the palette the SINK owns
  # (#466 - the emitter states the role, never the label or a color). Inside a
  # task it defers to Tool.push_status so the line lands on the outbox and the
  # OutputBuffer record stays pattern-free (issue #146).
  def emit_status(label:, verdict:, message:)
    status_event(Tool.status_type(verdict), message, label)
  end

  # Emit a plain labeled role (:warn, :error, :system ...). The renderer adds
  # the label; the emitter states only the role and content (#146). A :note may
  # take an ARRAY of paragraphs: they become ONE event whose content is the
  # paragraphs newline-joined, so a contiguous run of report prose is a single
  # note block the renderer lays out as a whole.
  def emit_role(role, content, origin: nil)
    status_event(role, content, origin)
  end

  # Emit a structured list/table report (issue #474). The emitter states the
  # DATA - title, kind, columns and per-item field values - never a fused row
  # string, so the durable record and a future remote sink carry the fields
  # themselves (#146). UI::Renderer owns the row shape. Main-thread only (a
  # slash command runs with no active Task); the payload is recorded so resume
  # replay redraws the structure, not a pre-rendered string.
  def emit_list(title:, items:, columns: nil, kind: :bullet,
                footer: nil, gap: false, origin: nil)
    payload = {
      title:,
      kind:,
      columns: Array(columns),
      items:,
      footer: Array(footer),
      gap:
    }
    ui.puts(main_thread_renderer.line(type: :list, content: payload))
    if harness.respond_to?(:record_report_output)
      harness.record_report_output(type: :list, content: payload, origin:)
    end
  end

  private

  # Route a typed role to the right sink: a live Task carries it as an event
  # (rendered by the drain loop with the harness palette), the main thread
  # renders it with the SINK palette so a non-terminal sink stays plain.
  def status_event(role, content, origin)
    type = role.to_sym
    text = content.is_a?(Array) ? content.join("\n") : content.to_s
    task = defined?(Task) ? Task.current : nil
    if task
      task.push_event(type:, origin: origin&.to_s, content: text)
    else
      line = main_thread_renderer.line(type:, content: text, origin:)
      ui.puts(line)
      # :body is the one main-thread role whose RECORD is the raw text, not the
      # printed line, so a replay redraws it through the renderer (#146).
      if type == :body && harness.respond_to?(:record_report_output)
        harness.record_report_output(type: :body, origin:, content: text)
      end
    end
  end

  def main_thread_renderer
    width = harness.respond_to?(:markdown_max_width) ? harness.markdown_max_width : nil
    UI::Renderer.new(
      palette: UI::Renderer.palette_for(ui:, harness:),
      ui:,
      markdown_max_width: width)
  end
end
