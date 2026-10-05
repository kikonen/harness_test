# frozen_string_literal: true

require_relative '../command'

module Commands
  # /session-clear - reset the session (drop all conversation messages).
  class SessionClearCommand < Command
    def handle(_args)
      @harness.session.clear
      puts "Session cleared (conversation history reset)."
    end
  end
end
