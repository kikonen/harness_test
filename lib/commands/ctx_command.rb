# frozen_string_literal: true

require_relative "../command"

module Commands
  # /ctx - report current context usage on demand (issue #63).
  class CtxCommand < Command
    HELP = CommandHelp.new(
      usage: "ctx",
      summary: "Show context usage now: tokens used, % of the window, " \
        "headroom and whether auto-compact is due",
      group: :session,
      see_also: %w[compact session conversation])

    def handle(_args)
      @ui.puts @harness.context_report
      @ui.puts
    end
  end
end
