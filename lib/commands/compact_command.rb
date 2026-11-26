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

    # Mid-turn it sends a RequestEvent to the live turn instead of starting a
    # nested round; the job's own thread compacts at its next request boundary.
    def self.mid_turn_safe? = true

    def handle(_args)
      if turn_live?
        send_request_event
        emit_line "  [compaction requested - applied at the model's next request]"
        return
      end

      submit_turn do |_t|
        emit_compaction(foreground_harness.session_manager.compact_session)
      end
    end

    private

    # issue #70 / #93: report the context size before and after so the user can
    # see how much space was freed (message count alone is misleading - tool
    # calls and long outputs inflate token usage).
    def emit_compaction(result)
      retained = result[:retained]
      emit_line "Session compacted: #{result[:before]} messages -> " \
                "#{result[:after]} messages (#{retained} recent retained)."
      if result[:context_before] && result[:context_line]
        emit_line "  #{result[:context_before]} -> #{result[:context_line]}"
      end
      emit_line ""
      emit_line "Summary:"
      emit_line result[:summary]
      emit_line ""
    end
  end
end
