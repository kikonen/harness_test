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

    # Ends the whole run; there is no live loop to end from a mid-turn submit.
    # Quit is Ctrl-D / /exit at the idle prompt.
    def self.mid_turn_safe? = false

    def exited?
      @exited
    end

    def handle(_args)
      @exited = true
    end
  end
end
