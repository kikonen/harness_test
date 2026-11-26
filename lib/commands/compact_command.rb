# frozen_string_literal: true

require_relative "../command"

module Commands
  # /compact - compact the session (summarize conversation to free context).
  #
  # issue #253: the summary is an LLM round, so it MUST run on a Task thread
  # like any other prompt (same bug class as issue #235). Running it
  # synchronously on the main thread broke the single-thread I/O rule
  # (issue #40): the compaction spinner was never driven and any dialog
  # blocked the console - the log moved while the console looked stuck.
  # Output lines go through Reporting#emit_line (the event queue), never
  # straight to the stream.
  class CompactCommand < Command
    HELP = CommandHelp.new(
      usage: "compact",
      summary: "Summarize the conversation to free context window space (an " \
               "LLM round: reports the message and context size before/after)",
      group: :session,
      see_also: %w[ctx session conversation])

    # Mid-turn it posts a :compact block event to the live turn instead of
    # starting a nested round; the job's own thread compacts at its next
    # request boundary (Task#service_pending_requests).
    def self.mid_turn_safe? = true

    def handle(_args)
      if turn_live?
        send_block_event(
          kind: :compact,
          block: -> { foreground_harness.session_manager.compact_session })
        emit_line "  [compaction requested - applied at the model's next request]"
        return
      end

      harness = foreground_harness
      submit_turn(
        kind: :compact,
        job_id: registry.foreground_job.id,
        block: -> { emit_compaction(harness.session_manager.compact_session) })
    end
  end
end
