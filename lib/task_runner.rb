# frozen_string_literal: true

require_relative 'task'

# Shared wrapper for running an LLM round on a Task thread (the
# single-thread I/O rule, issue #40): the block runs on a task thread and
# all its console I/O is serialized through the main-thread drain loop.
# Without it, Task.emit events (spinner, response lines) are silently
# dropped and any dialog blocks the console - the log moves but the console
# looks stuck (issue #235). A task error is surfaced as a [task error] line.
#
# Included by anything that drives an LLM round: CommandHandler (direct
# prompts) and the Command subclasses that do (/retry, issue #235). The
# includer must expose #harness and #ui.
module TaskRunner
  def run_on_task
    ui.puts
    error, _task = Task.run(harness: harness, ui: ui) { |_t| yield }
    ui.puts "  [task error] #{error}" if error
    ui.puts
  end
end
