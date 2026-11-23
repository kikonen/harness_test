# frozen_string_literal: true

require "time"

require_relative "llm/usage_stats"

# One turn's stats bookkeeping (issue #582), owned by the Harness that built it
# so the CLI can still read an aborted turn. An aborted turn reports
# answered-over-sent iterations only: token and performance figures would
# describe requests that never returned.
class TurnStats
  def initialize(job_id_source)
    @job_id_source = job_id_source
    @open = nil
  end

  def open(iteration:, answered:, usage:)
    @open = {
      job_id: @job_id_source.call,
      started_at: Time.now,
      iterations: answered,
      pending_iteration: iteration,
      usage: usage.dup
    }
  end

  def close(iteration:, usage:, prompt_tokens:, performance:)
    closed = { **@open, iterations: iteration, usage: }
    closed.delete(:pending_iteration)
    closed[:prompt_tokens] = prompt_tokens
    closed[:performance] = performance
    closed[:committed] = true
    @open = closed
  end

  # A turn with no answered request reports nothing (elapsed-only would read as
  # the whole turn's duration).
  def aborted(job_id)
    return nil if @open.nil? || @open[:committed]
    return nil if job_id != @open[:job_id]
    return nil if @open[:iterations].to_i.zero?

    @open.merge(
      elapsed_seconds: (Time.now - @open[:started_at]).round(2),
      usage: @open[:usage].dup)
  end

  # The request's own clock and counts, never stats[:elapsed_seconds] (the
  # TURN's time, tool execution included).
  def record_rate(usage, seconds)
    rate = LLM::UsageStats.recent_generation_rate(usage, seconds)
    return nil unless rate

    @last_rate = rate
  end

  # A model switch changes the server, so the old rate describes nothing here.
  def forget_rate
    @last_rate = nil
  end

  # pad gives the spinner a width-stable number; a log line reads it unpadded.
  def rate_segment(pad: false)
    return nil if @last_rate.nil?

    LLM::UsageStats.rate_segment(
      @last_rate[:rate],
      measured_by_server: @last_rate[:server],
      tag: "last",
      pad:)
  end

  # Server-measured, so a resumed session shows a rate immediately; a
  # client-timed one would need seconds it does not have.
  def restore_rate(performance)
    rate = LLM::UsageStats.recent_generation_rate(performance, nil)
    @last_rate = rate if rate
    rate
  end
end
