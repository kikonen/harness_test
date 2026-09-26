# frozen_string_literal: true

module Commands
  # /exit - exit the harness.
  class ExitCommand
    def initialize(_harness, _file_list, _options)
      @exited = false
    end

    def exited?
      @exited
    end

    def handle(_args)
      @exited = true
    end
  end
end