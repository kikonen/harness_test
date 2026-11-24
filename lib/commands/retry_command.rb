# frozen_string_literal: true

require_relative "../command"

module Commands
  # /retry - re-send the session message chain (after a failed request).
  #
  # issue #235: the re-send is an LLM round (spinner, tool loop, dialogs),
  # so it MUST run on a Task thread like any other prompt - the shared
  # #run_on_worker wrapper routes all console I/O through the
  # main-thread drain loop (issue #40). Running it synchronously on the
  # main thread broke that rule: no spinner was driven and any dialog
  # blocked the console, so the log moved but the console looked stuck.
  class RetryCommand < Command
    HELP = CommandHelp.new(
      usage: "retry",
      summary: "Re-send the message chain after a failed request. Tool work " \
        "already done is kept, so the turn resumes from exactly there",
      group: :session,
      see_also: %w[conversation session saving])

    # Drives an LLM round: it submits to the run loop's worker, which is only
    # idle between turns. While a turn is live it is refused until it becomes a
    # control event drained beside the note (issue #286 increment 4).
    def self.mid_turn_safe? = false

    def handle(_args)
      run_on_worker do |_t|
        foreground_harness.session_manager.retry
      end
    end
  end
end
