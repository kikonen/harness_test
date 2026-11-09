# frozen_string_literal: true

require_relative "task"
require_relative "tool"

# Shared wrapper for running an LLM round on a Task thread (the
# single-thread I/O rule, issue #40): the block runs on a task thread and
# all its console I/O is serialized through the main-thread drain loop.
# Without it, Task.emit events (spinner, response lines) are silently
# dropped and any dialog blocks the console - the log moves but the console
# looks stuck (issue #235). A task error is surfaced as a [task error] line.
#
# Included by anything that drives an LLM round: CommandHandler (direct
# prompts) and the Command subclasses that do (/retry issue #235, /compact
# issue #253). The includer must expose #harness and #ui.
module TaskRunner
  def run_on_task
    ui.puts
    error, task = Task.run(harness:, ui:) { |_t| yield }
    # Feed the turn's buffer tail into the harness' run OutputBuffer (the
    # durable both-sides record) so a later resume can redraw it (issue #458).
    harness.absorb_turn(task) if harness.respond_to?(:absorb_turn)
    ui.puts "  [task error] #{error}" if error
    ui.puts
  end

  # Console line emitted from INSIDE a task block. A task thread must never
  # write to a stream (single-thread I/O rule, issue #40), so the line goes
  # as a :text event onto the active task's outbox and the drain loop renders
  # it in order with the rest of the turn. When no task is active - specs, or
  # a command dispatched directly on the main thread - it writes to the
  # console itself, so output is still captured deterministically.
  def emit_line(text)
    task = defined?(Task) ? Task.current : nil
    if task
      task.push_event(type: :text, origin: :command, content: text.to_s)
    else
      ui.puts(text.to_s)
    end
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
    end
  end

  def main_thread_renderer
    UI::Renderer.new(palette: UI::Renderer.palette_for(ui:, harness:))
  end
end
