# frozen_string_literal: true

require_relative '../command'

module Commands
  # /session - show a summary of the current session.
  class SessionCommand < Command
    def handle(_args)
      @ui.puts @harness.session.summary
    end
  end
end
