# frozen_string_literal: true

# -- Session --------------------------------------------------------------
#
# Holds the conversation message chain (OpenAI chat format) for the current
# harness run. New user prompts are appended to the chain so that follow-up
# messages build on previous context. If a request to the LLM fails, the
# chain is kept intact so it can be retried (/retry). The session can be
# inspected (/session) and reset (/session-clear).

class Session
  attr_reader :messages, :created_at

  def initialize(system_prompt)
    @system_prompt = system_prompt
    @created_at    = Time.now
    @user_prompts  = 0
    @last_stats    = nil
    @messages      = [system_message]
  end

  # True when the session holds nothing but the system message.
  def empty?
    @messages.size == 1
  end

  # True when the chain ends with a user message that has not been answered
  # yet (e.g. after a failed request) — i.e. there is something to retry.
  def pending?
    @messages.last[:role] == 'user'
  end

  def add_user(content)
    @messages << { role: 'user', content: content }
    @user_prompts += 1
    self
  end

  def add_assistant(content)
    @messages << { role: 'assistant', content: content }
    self
  end

  def record_stats(stats)
    @last_stats = stats
  end

  # Reset the session: drop all conversation messages, keep the system prompt.
  def clear
    @messages     = [system_message]
    @user_prompts = 0
    @last_stats   = nil
    @created_at   = Time.now
    self
  end

  # Human-readable summary of the session state.
  def summary
    counts = Hash.new(0)
    @messages.each { |m| counts[m[:role]] += 1 }

    lines = []
    lines << "Session started: #{created_at.strftime('%Y-%m-%d %H:%M:%S')}"
    lines << "Messages:        #{@messages.size} total"
    counts.each { |role, n| lines << "  - #{role}: #{n}" }
    lines << "User prompts:    #{@user_prompts}"
    lines << "Pending prompt:  #{pending? ? 'yes (last request failed — use /retry)' : 'no'}"
    if @last_stats
      usage = @last_stats[:usage]
      parts = ["last request: #{@last_stats[:elapsed_seconds]}s, #{@last_stats[:iterations]} iteration(s)"]
      if usage && usage[:total_tokens] > 0
        parts << "#{usage[:prompt_tokens]}→#{usage[:completion_tokens]} tokens (#{usage[:total_tokens]} total)"
      end
      lines << parts.join(', ')
    else
      lines << 'No successful requests yet.'
    end
    lines.join("\n")
  end

  private

  def system_message
    { role: 'system', content: @system_prompt }
  end
end
