# frozen_string_literal: true

require_relative "../command"

module Commands
  # /session-clear - reset the session (drop all conversation messages).
  class SessionClearCommand < Command
    HELP = CommandHelp.new(
      usage: "session-clear",
      summary: "Start a fresh conversation (drops the messages; the saved " \
        "session file on disk is left alone)",
      group: :session,
      see_also: %w[session compact save resume conversation])

    def handle(_args)
      @harness.session.clear
      @ui.puts "Session cleared (conversation history reset)."
    end
  end
end
