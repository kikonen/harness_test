# frozen_string_literal: true

require_relative 'ui'
require_relative 'task_runner'

# Shared base for the slash-command classes in lib/commands/.
#
# Commands take an explicit `ui:` object (UI::Console) so that no command
# code references $stdout/$stdin directly. A TUI can later swap the
# underlying stream for a panel/draw sink without touching any command.
#
# Includes TaskRunner (issue #235): a command that drives an LLM round
# (/retry issue #235, /compact issue #253) runs it on a Task thread via
# #run_on_task, the same shared wrapper a direct prompt uses, and prints
# through #emit_line so its lines stay on the event queue.
class Command
  include TaskRunner

  attr_reader :harness, :file_list, :options, :ui

  # on_resume: the mid-run /resume action (issue #280) - a callable that
  # takes a session id and rebuilds the whole run under it. Only the owner
  # of the run (CLI) can do that, so the action arrives as a callable
  # instead of the command reaching for a live Harness to mutate. nil for
  # every other command.
  def initialize(harness:, file_list:, options:, ui:, on_resume: nil)
    @harness    = harness
    @file_list  = file_list
    @options    = options
    @ui         = ui
    @on_resume  = on_resume
  end
end
