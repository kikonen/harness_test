# frozen_string_literal: true

require_relative '../command'

module Commands
  # /exit - exit the harness.
  class ExitCommand < Command
    def exited?
      @exited
    end

    def handle(_args)
      @exited = true
    end
  end
end
