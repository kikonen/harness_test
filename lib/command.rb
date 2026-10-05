# frozen_string_literal: true

require_relative 'ui'

# Shared base for the slash-command classes in lib/commands/.
#
# Commands take an explicit `ui:` object (UI::Console) so that no command
# code references $stdout/$stdin directly. A TUI can later swap the
# underlying stream for a panel/draw sink without touching any command.
class Command
  attr_reader :harness, :file_list, :options, :ui

  def initialize(harness:, file_list:, options:, ui:)
    @harness   = harness
    @file_list = file_list
    @options   = options
    @ui        = ui
  end
end
