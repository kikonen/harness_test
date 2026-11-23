# frozen_string_literal: true

require_relative "harness_error"
require_relative "tool"
require_relative "turn_context"

# The per-turn tool loop extracted off Harness (issue #582). One short-lived
# object per turn: everything it needs arrives in the TurnContext built by
# Harness#call_llm, and what the turn learns goes back through that context
# (stats, the last request's rate) and its return value. Nothing here names
# Harness.
class TurnRunner
  def initialize(context)
    @ctx = context
  end

  # notes: the caller's turn-local injected-note list, appended in place.
  def run(notes)
    ctx = @ctx
    session = ctx.session
    session_manager = ctx.session_manager
    logger = ctx.logger
    tool_calls = ctx.tool_calls
    ports = ctx.ports
    messages = session.messages

    iteration = 0
    consecutive_tool_calls = 0
    last_tool_name = nil
    loop_warning_injected = false
    loop_hard_break = false
    text_call_retried = false
    total_usage = TurnContext::EMPTY_USAGE.dup

    # Iterations whose request came back: the loop counter runs ahead of it.
    answered = 0

    # One per turn: its inline budget is turn-scoped, and its base64 must reach
    # the token estimate before a request carries it.
    delivery = ctx.delivery

    # The LAST call's prompt_tokens is the context size: each call already
    # carries the history, so summing over counts.
    last_prompt_tokens = 0
    last_performance   = nil

    # A compaction cannot fire on two consecutive iterations: the request made
    # right after one has not been re-measured yet, so a back-to-back pair reads
    # as "compact done twice" (issue #577).
    compacted_iteration = nil

    max_iters = ctx.max_tool_iterations
    loop do
      iteration += 1
      raise ToolLoopError, "exceeded max tool iterations (#{max_iters})" if iteration > max_iters

      # Compact on the last call's real size rather than letting the next
      # request fail server-side; iteration 1 has nothing to summarize.
      if iteration > 1 && last_prompt_tokens > 0 && iteration != compacted_iteration&.+(1) &&
         session_manager.check_inloop_compaction(messages, last_prompt_tokens)
        compacted_iteration = iteration
        consecutive_tool_calls = 0
        loop_warning_injected = false
      end

      if (note = ctx.mailbox.take_user_note)
        notes << note
        logger.info "user mid-turn note injected: #{note}"
        messages << { role: "user", content: "User note (mid-turn): #{note}" }
        Tool.push_status(label: "note", verdict: :info, message: "sent to model")
      end

      # Consumed on the JOB's own thread at the same safe point a note lands, so
      # the agent saves its own chain with no cross-thread read.
      if ctx.mailbox.take_save_request
        session_manager.save_job_session
        logger.info "save request consumed (job ##{session_manager.job_id})"
      end

      ctx.announce_request

      # Before the request leaves: an aborted turn needs to know which one died.
      ctx.open_stats(iteration:, answered:, usage: total_usage)
      data    = ctx.request_chain(messages)
      message = data[:choices][0][:message]

      # The model has seen them; keeping them would re-send the same bytes in
      # every later request. The text naming the stored file survives.
      tool_calls.strip_image_payloads(messages)

      # A text-shaped call is parsed leniently so the turn does not silently
      # break; an unresolvable name stays prose and ends as an answer.
      if !message[:tool_calls] && ports.text_tool_call_parser.text_call?(message[:content])
        committed = messages.filter_map { |m| m[:tool_calls] }.flatten
        recovered = ports.text_tool_call_parser.parse(message[:content], committed:)
        if recovered.any?
          message[:tool_calls] = recovered
          logger.warn "tool call arrived as text/XML (issue #461), not JSON - parsed and running"
          Tool.push_status(
            label: "text_call",
            verdict: :warn,
            message: "tool call arrived as text/XML, not JSON - parsed and running")
        end
      end

      tool_calls.emit_step(message, ports) if message[:tool_calls]

      # AFTER the step line, so the warn lands inside the block it describes.
      truncated = tool_calls.truncated_by_finish_reason?(data, iteration, ports)

      if data[:usage]
        total_usage[:prompt_tokens]     += data[:usage][:prompt_tokens]     || 0
        total_usage[:completion_tokens] += data[:usage][:completion_tokens] || 0
        total_usage[:total_tokens]      += data[:usage][:total_tokens]      || 0
        last_prompt_tokens              = data[:usage][:prompt_tokens].to_i
      end
      answered = iteration

      ctx.record_rate(data[:usage])

      # The LAST call describes the next request's state, so it replaces the
      # earlier ones - measurements of different requests cannot be summed.
      last_performance = ctx.performance_snapshot(data[:usage])

      session.record_prompt_tokens(last_prompt_tokens, messages.size)

      if message[:tool_calls]
        # -- Tool-loop detection --
        current_tool_name = message[:tool_calls].first[:function][:name]
        if current_tool_name == last_tool_name
          consecutive_tool_calls += 1
        else
          consecutive_tool_calls = 1
          last_tool_name = current_tool_name
        end

        if consecutive_tool_calls >= TurnContext::TOOL_LOOP_HARD_LIMIT
          logger.warn "tool-loop hard limit reached (#{consecutive_tool_calls} consecutive calls to '#{current_tool_name}') - forcing final response"
          loop_hard_break = true
        elsif consecutive_tool_calls >= TurnContext::TOOL_LOOP_WARN_THRESHOLD && !loop_warning_injected
          logger.warn "tool-loop warning: #{consecutive_tool_calls} consecutive calls to '#{current_tool_name}' - injecting stop message"
          loop_warning_injected = true
        end

        logger.info "--- tool_calls (iteration #{iteration}, consecutive: #{consecutive_tool_calls}) ---"
        message[:tool_calls].each do |tc|
          logger.info "  calling #{tc[:function][:name]}(#{tc[:function][:arguments]})"
        end

        assistant_msg = { role: "assistant", content: message[:content] }
        assistant_msg[:tool_calls] = message[:tool_calls]
        session.add_assistant_message(assistant_msg)

        # Single run.command calls check themselves inside CommandRunner.
        tool_calls.precheck_batch_safety(message[:tool_calls], ports)
        message[:tool_calls].each do |tc|
          raw = tool_calls.execute(tc, ports, truncated:)
          tool_msg = tool_calls.result_message(tc, raw, delivery, ports)
          tool_calls.capture_note(tc, tool_msg[:content], ports)
          messages << tool_msg
        end

        # The model cannot see the harness' budget, so the cut is named once per
        # round - otherwise it retried the same oversized call forever.
        if truncated
          messages << {
            role: "user",
            content: "Your previous response was cut off by the token budget " \
                     "(#{tool_calls.budget_note(data, ports)}). Any tool call in it may be incomplete. " \
                     "Do NOT re-send the same call: split it into smaller calls or " \
                     "shorten its content."
          }
        end

        if loop_hard_break
          messages << {
            role: "user",
            content: "STOP. You are stuck in a tool loop. Do NOT call any more tools. " \
                     "Respond NOW with your final answer. If you were editing files, use the file.write tool to save them. " \
                     "If this was a query, answer it directly in plain text."
          }
          next
        end

        if loop_warning_injected && consecutive_tool_calls == TurnContext::TOOL_LOOP_WARN_THRESHOLD
          messages << {
            role: "user",
            content: "Reminder: You have called the same tool multiple times in a row. " \
                     "If you have enough information, stop calling the same tool and provide your final answer now."
          }
        end

        next
      end

      ctx.mailbox.discard_pending_user_note(:late)

      # An unresolved text call is fed back ONCE (the model would otherwise never
      # learn its call failed); the second occurrence falls through to warn +
      # commit, so quoted prose cannot spin the loop.
      if text_call_retried
        tool_calls.warn_unresolved_text_tool_call?(message[:content], ports)
      elsif tool_calls.log_unresolved_text_tool_call?(message[:content], ports)
        text_call_retried = true
        session.add_assistant_message({ role: "assistant", content: message[:content] })
        messages << { role: "user", content: TurnContext::UNSOLVED_TEXT_CALL_FEEDBACK }
        Tool.push_status(
          label: "text_call",
          verdict: :warn,
          message: "tool call arrived as text the harness could not run - " \
                   "asked the model to re-issue it")
        next
      end

      stats = ctx.finish_stats(iteration:, usage: total_usage,
                               prompt_tokens: last_prompt_tokens,
                               performance: last_performance)

      session.add_assistant(message[:content])
      session.flush_notes
      session.record_stats(stats)
      session.record_reasoning(message[:reasoning])

      # A committed chain is text state: no base64 belongs in it or a session file.
      tool_calls.strip_image_payloads(messages)

      return {
        reasoning: message[:reasoning],
        content:   message[:content],
        stats:
      }
    end
  end
end
