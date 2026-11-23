# frozen_string_literal: true

require_relative "harness_error"

# The compact fork: turn a message chain into one summary via an LLM request.
# Extracted from SessionManager (#503) because the fork has its own failure
# mode - it is larger than the request that just failed, so it can be rejected
# for the same reason. Design: doc/compaction_cache_design.md.
class Compactor
  # Mid-turn there is no verbatim tail, so the summary carries the whole state.
  INLOOP_INSTRUCTION = "Summarize the ENTIRE conversation and tool work above " \
    "(the work done, not the system rules you were given) as a " \
    "hand-off for continuing an in-progress task. Include: " \
    "(1) the original goal, (2) every step already completed with its " \
    "concrete results (file paths, SHAs, command outputs when available), " \
    "(3) key decisions made, (4) files modified or created and their " \
    "current state, (5) the exact next step to take. " \
    "Do NOT call any tools - answer with text only. "

  END_INSTRUCTION = "Summarize the entire CONVERSATION above (the work done, not the " \
    "system rules you were given) in a concise, structured format. " \
    "Include: (1) what was being worked on, (2) key decisions made, " \
    "(3) files that were modified or created, (4) any pending tasks or " \
    "unresolved issues, (5) important context needed to continue. " \
    "Do NOT call any tools - answer with text only. "

  # Conversation entries dropped per retry round (#503). Fixed-size rounds so a
  # chain of many small messages recovers in a few attempts, not hundreds.
  DROP_ROUND = 10

  def initialize(client:, tools_payload:, max_words:, logger:)
    @client        = client
    @tools_payload = tools_payload
    @max_words     = max_words
    @logger        = logger
  end

  # True when an error message looks like the model rejected the request
  # because the context window was exceeded (wording varies by server).
  def self.context_exceeded?(msg)
    msg =~ /context|num_ctx|max.*token|too many tokens|exceeds/i
  end

  # Summarize a chain, dropping OLDEST conversation entries and retrying while
  # the summary request is itself rejected for a full context (issue #503).
  #
  # The first attempt sends the chain AS IS, which is what keeps it a prefix of
  # the live prompt (doc/compaction_cache_design.md). That rule is only worth
  # paying for while the request can actually be served: once the server has
  # rejected the chain for size, the prefilled prefix it protects no longer
  # exists, so a truncated retry costs nothing it had not already lost.
  #
  # Message 0 (the system message) is NEVER dropped - it is the prefix the cache
  # matches from, and every server request needs it. Drops are whole messages
  # from the oldest end of the CONVERSATION, so a chain with many small messages
  # recovers in a few attempts rather than hundreds.
  #
  # Giving up: a chain cannot shrink below one conversation message. A single
  # message larger than the window can never fit, and that is reported rather
  # than looped on. A non-context failure (empty summary, a tool-call answer) is
  # NOT retried by dropping - dropping does not fix it, so it re-raises.
  def summarize(chain, instruction)
    attempts = 0
    loop do
      attempts += 1
      begin
        summary = request_summary(chain, instruction)
        note_rounds(attempts - 1)
        return summary
      rescue LLMError => e
        raise unless self.class.context_exceeded?(e.message)
        raise if chain.size <= 2 # system + one conversation message: nothing left to drop

        dropped = drop_oldest_entries(chain)
        raise if dropped.size >= chain.size # no progress possible

        chain = dropped
        emit(
          "  [compact summary over the context window - retrying with the " \
            "#{chain.size} newest messages...]")
      end
    end
  end

  # Ask the LLM for a summary of a message chain. The chain rides AS IS (system
  # message included) with the live turn's own tools payload, so the request
  # stays a prefix of the live prompt - doc/compaction_cache_design.md.
  # chain: the messages to summarize, AS IS for the first attempt. A caller that
  # already knows the full chain cannot fit (the #503 fallback) passes a
  # truncated one; the prefix-cache rule only holds for the untruncated case.
  def request_summary(chain, instruction)
    messages = chain + [
      {
        role: "user",
        content: "#{instruction} " \
          "Keep it under #{@max_words} words. " \
          "Do NOT include the summarization instruction itself."
      }
    ]

    data    = @client.chat(messages, tools: @tools_payload)
    message = data[:choices][0][:message]
    calls   = Array(message[:tool_calls]).filter_map { |tc| tc.dig(:function, :name) }
    text    = message[:content]
    if text.nil? || text.strip.empty?
      named = calls.join(", ")
      raise HarnessError,
        calls.empty? ? "LLM returned empty summary" :
          "LLM answered the summary request with a tool call (#{named}) " \
            "instead of a summary"
    end
    if calls.any?
      @logger.info "summary call returned tool calls (#{calls.join(', ')}) - ignored"
    end

    text.strip
  end

  # The chain with the oldest DROP_ROUND conversation entries removed, message 0
  # kept. A cut landing on a tool result would orphan the assistant message that
  # called it, so the cut walks forward off tool rows.
  def drop_oldest_entries(chain)
    head = chain[0, 1]
    tail = chain[1..] || []
    return chain if tail.size <= 1

    cut = [DROP_ROUND, tail.size - 1].min
    cut += 1 while tail[cut] && tail[cut][:role] == "tool"
    cut = tail.size - 1 if cut >= tail.size
    head + tail[cut..]
  end

  private

  def note_rounds(rounds)
    return if rounds.zero?

    emit(
      "  [compact summary succeeded after dropping #{rounds} " \
        "oldest-entry round(s) - the full chain did not fit]")
  end

  def emit(content)
    Task.emit(:compact, origin: :compactor, content:)
  end
end
