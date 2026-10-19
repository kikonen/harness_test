# frozen_string_literal: true

require_relative "../command"

module Commands
  # /exit - exit the harness.
  class ExitCommand < Command
    HELP = CommandHelp.new(
      usage: "exit",
      summary: "Quit the harness (the session is auto-saved on the way out)",
      group: :general,
      see_also: %w[save help])

    def exited?
      @exited
    end

    def handle(_args)
      @exited = true
    end
  end
end
