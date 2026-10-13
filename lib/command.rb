# frozen_string_literal: true

require 'ui'
require_relative 'task_runner'

# Shared base for the slash-command classes in lib/commands/.
#
# Commands take an explicit `ui:` object (UI::Console) so that no command
# code references $stdout/$stdin directly. A TUI can later swap the
# underlying stream for a panel/draw sink without touching any command.
#
# Includes TaskRunner (issue #235): a command that drives an LLM round
# (/retry) runs it on a Task thread via #run_on_task, the same shared
# wrapper a direct prompt uses.
class Command
  include TaskRunner

  attr_reader :harness, :file_list, :options, :ui

  def initialize(harness:, file_list:, options:, ui:)
    @harness   = harness
    @file_list = file_list
    @options   = options
    @ui        = ui
  end
end
