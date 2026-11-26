# frozen_string_literal: true

require_relative "task"
require_relative "tool"

# Shared console-reporting mixin for the run's LLM-round hosts (issue #235):
# CommandHandler (direct prompts) and the Command subclasses that drive a round
# (/retry issue #235, /compact issue #253). The includer must expose #ui and
# #settings; a host that starts a round submits it to the run loop's worker
# (Command#submit_turn / CommandHandler#submit_turn). Without this, Task.emit
# events (spinner, response lines) are silently dropped and any dialog blocks
# the console - the log moves but the
# console looks stuck. A task error is the :kind role, so the bracket shape
# belongs to UI::Renderer and not to this emitter (#474, increment 22).
module Reporting
  # Issue #286: the JobRegistry the RUN owns is the home of the run record, so
  # main-thread reports land in its buffers. The host's registry is never nil:
  # every Reporting host (Command, CommandHandler) is built by the run with it.
  attr_accessor :registry

  # The run's single SystemSaver (issue #548): the /save command's writer of the
  # whole layered system, passed down from the run owner like the registry.
  attr_accessor :system_saver

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

  # The before/after report a /compact round produces (issue #70 / #93: message
  # AND context size before/after - message count alone is misleading). Shared
  # by CompactCommand and the worker's :compact mini-turn (issue #286 step 3)
  # so both emit the same lines from inside a task.
  def emit_compaction(result)
    emit_line(
      "Session compacted: #{result[:before]} messages -> " \
        "#{result[:after]} messages (#{result[:retained]} recent retained).")
    if result[:context_before] && result[:context_line]
      emit_line "  #{result[:context_before]} -> #{result[:context_line]}"
    end
    emit_line ""
    emit_line "Summary:"
    emit_line result[:summary]
    emit_line ""
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
    if registry
      registry.record_report_output(type: :list, content: payload, origin:)
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
      if type == :body && registry
        registry.record_report_output(type: :body, origin:, content: text)
      end
    end
  end

  def main_thread_renderer
    # Palette and table width are the run's settings (#286): every Reporting host
    # (Command, CommandHandler) carries settings, so no harness fallback here.
    UI::Renderer.new(
      palette: UI::Renderer.palette_for(ui:, settings:),
      ui:,
      markdown_max_width: settings&.markdown_max_width)
  end
end
