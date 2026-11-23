# frozen_string_literal: true

require_relative "llm/usage_stats"

# The state one turn needs, handed to TurnRunner at construction and nothing
# else (issue #582): Harness#build_turn_context assembles it from the objects
# the run owns, so the turn loop never names Harness. Every value below is a
# collaborator the turn may call directly - no callable standing in for a
# Harness method. What the turn learns goes back through #finish_stats /
# #record_rate and its return value.
class TurnContext
  EMPTY_USAGE = { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 }.freeze

  # Consecutive-call thresholds: warn (inject a stop message), then break.
  TOOL_LOOP_WARN_THRESHOLD = 30
  # After this many consecutive tool-call iterations, force-break and return whatever we have
  TOOL_LOOP_HARD_LIMIT = 50

  # Fed back to the model when it wrote a tool call as text the harness could
  # not run, so it re-issues it instead of the failure only reaching the user
  UNSOLVED_TEXT_CALL_FEEDBACK = "Your previous message contained a tool call the " \
    "harness could not run (its tool name matched no registered tool), so NO tool " \
    "was executed. Re-issue it as a structured tool call using the exact name of a " \
    "registered tool, or answer directly in plain text if you do not need a tool."

  attr_reader :session,
    :session_manager,
    :logger,
    :tool_calls,
    :ports,
    :delivery,
    :max_tool_iterations,
    :mailbox,
    :turn_stats,
    :request_log

  def initialize(session:, session_manager:, logger:, tool_calls:, ports:,
                 delivery:, max_tool_iterations:, mailbox:, turn_stats:, request_log:)
    @session             = session
    @session_manager     = session_manager
    @logger              = logger
    @tool_calls          = tool_calls
    @ports               = ports
    @delivery            = delivery
    @max_tool_iterations = max_tool_iterations
    @mailbox             = mailbox
    @turn_stats          = turn_stats
    @request_log         = request_log
  end

  # Each request announces its own wait, so an earlier re-point (an
  # in-loop compaction) cannot outlive it.
  def announce_request
    @session_manager.request_spinner_detail
  end

  # Before the request leaves: an aborted turn needs to know which one died.
  def open_stats(iteration:, answered:, usage:)
    @turn_stats.open(iteration:, answered:, usage:)
  end

  def finish_stats(iteration:, usage:, prompt_tokens:, performance:)
    @turn_stats.close(
      iteration:,
      usage:,
      prompt_tokens:,
      performance:)
  end

  # The request's own clock and counts, never stats[:elapsed_seconds] (the
  # TURN's time, tool execution included).
  def record_rate(usage)
    @turn_stats.record_rate(usage, @request_log.seconds)
  end

  def performance_snapshot(usage)
    LLM::UsageStats.performance_snapshot(usage)
  end

  def request_chain(messages)
    @request_log.chat(messages)
  end
end
