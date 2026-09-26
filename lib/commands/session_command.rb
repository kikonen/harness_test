# frozen_string_literal: true

module Commands
  # /session - show a summary of the current session.
  class SessionCommand
    def initialize(harness, _file_list, _options)
      @harness = harness
    end

    def handle(_args)
      puts @harness.session.summary
    end
  end
end
