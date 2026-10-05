# frozen_string_literal: true

# Shared base for the slash-command classes in lib/commands/.
#
# Commands run on the main thread but are still required to take their
# output stream explicitly (the same contract as Task.run and
# Dialog#show) so that a TUI can later replace the terminal stdout with a
# panel/draw sink without touching any command code.
class Command
  attr_reader :harness, :file_list, :options, :stdout

  def initialize(harness:, file_list:, options:, stdout:)
    @harness   = harness
    @file_list = file_list
    @options   = options
    @stdout    = stdout
  end

  private

  # Print to the command's explicit stream - never to $stdout, so a TUI
  # can substitute its own sink later.
  def puts(*args)
    @stdout.puts(*args)
  end
end
