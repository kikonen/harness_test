# frozen_string_literal: true

require_relative "../command"

module Commands
  # /session - show a summary of the current session.
  class SessionCommand < Command
    HELP = CommandHelp.new(
      usage: "session",
      summary: "Show a summary of the current session (id, message counts, " \
        "prompts, whether a prompt is pending for /retry, last stats)",
      group: :session,
      see_also: %w[conversation session-clear compact ctx save retry])

    def handle(_args)
      @ui.puts @harness.session.summary
    end
  end
end
