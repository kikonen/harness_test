# frozen_string_literal: true

module Commands
  # /session-clear - reset the session (drop all conversation messages).
  class SessionClearCommand
    def initialize(harness, _file_list, _options)
      @harness = harness
    end

    def handle(_args)
      @harness.session.clear
      puts "Session cleared (conversation history reset)."
    end
  end
end
