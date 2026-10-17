# frozen_string_literal: true

require_relative "task"

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
    error, _task = Task.run(harness: harness, ui: ui) { |_t| yield }
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
end
