# frozen_string_literal: true

require_relative "requester"
require_relative "error_text"
require_relative "harness_error"
require_relative "text_normalizer"

# A round: its own thread, its own job, its own chain, its own read-only tool
# set. Every exit path must DELIVER, because the requester blocks on its inbox.
# Design: doc/task_model_design.md.
class SubAgent
  include Requester

  DEFAULT_MAX_ITERATIONS = 12
  DEFAULT_MAX_FINDINGS = 2000

  attr_reader :job, :registry, :instruction

  def initialize(
    harness:,
    job:,
    registry:,
    instruction:,
    max_iterations: DEFAULT_MAX_ITERATIONS,
    max_findings: DEFAULT_MAX_FINDINGS
  )
    @harness        = harness
    @job            = job
    @registry       = registry
    @instruction    = instruction.to_s
    @max_iterations = max_iterations.to_i
    @max_findings   = max_findings.to_i
  end

  # Spawn the round. The :done event is what answers the requester (the registry
  # finishes the job with its result), so it is pushed on EVERY path - including
  # the one where the round raises.
  def start
    @job.mark_running

    Thread.new do
      Thread.current[:harness_sub_agent] = self
      begin
        push_event(type: :done, result: run_rounds)
      rescue => e
        push_event(type: :done, result: "error: #{ErrorText.label(e)}")
      end
    end
  end

  def push_event(type:, origin: nil, content: nil, **extra)
    @job.push_event(type:, origin:, content:, **extra)
  end

  def run_rounds
    messages = [
      { role: "system", content: @harness.build_system_prompt },
      { role: "user", content: @instruction }
    ]
    payload = @registry.empty? ? nil : @registry.to_openai
    iteration = 0

    loop do
      iteration += 1
      if iteration > @max_iterations
        raise HarnessError, "sub agent exceeded its iteration limit (#{@max_iterations})"
      end

      # A sub-agent request is always buffered: the streaming posture belongs to
      # the foreground turn, and a background job has no spinner to feed.
      data    = @harness.client.chat(messages, tools: payload, stream: false)
      message = data[:choices][0][:message]

      if message[:tool_calls]
        names = message[:tool_calls].map { |tc| tc[:function][:name] }.join(", ")
        push_event(
          type: :text,
          origin: :sub_agent,
          content: "iteration #{iteration}: #{names}")
        messages << {
          role: "assistant",
          content: message[:content],
          tool_calls: message[:tool_calls]
        }
        message[:tool_calls].each do |tc|
          answer = @harness.execute_tool_call(tc, registry: @registry)
          messages << {
            role: "tool",
            tool_call_id: tc[:id],
            content: TextNormalizer.normalize(answer)
          }
        end
        next
      end

      push_event(type: :text, origin: :sub_agent, content: message[:content].to_s)
      return clamp(message[:content])
    end
  end

  # The cap is enforced in code, not by asking the model to be short - the point
  # of a sub-agent is that the main context stays small.
  def clamp(text)
    text = text.to_s.strip
    return text if text.length <= @max_findings

    "#{text[0, @max_findings]}\n(sub-agent findings truncated at #{@max_findings} chars)"
  end
end
