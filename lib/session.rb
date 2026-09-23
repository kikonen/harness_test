# frozen_string_literal: true

require 'time'
require 'securerandom'

# -- Session --------------------------------------------------------------
#
# Holds the conversation message chain (OpenAI chat format) for the current
# harness run. New user prompts are appended to the chain so that follow-up
# messages build on previous context. If a request to the LLM fails, the
# chain is kept intact so it can be retried (/retry). The session can be
# inspected (/session) and reset (/session-clear).
#
# The allowed file list logically belongs to the session (it is part of the
# working context), so it is serialized/restored together with the session
# (see #to_h / #restore).
#
# Each session has a stable UUID id (#session_id). Saving the session
# (possibly multiple times) always writes to the same file, so a session can
# be continued and re-saved under the same id instead of creating a new
# session file each time.

class Session
  UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  attr_reader :messages, :created_at, :system_prompt, :session_id

  def initialize(system_prompt)
    @system_prompt = system_prompt
    @created_at    = Time.now
    @session_id    = SecureRandom.uuid
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
    lines << "Session id:      #{session_id}"
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

  # Serialize the session (including the file list) into a plain hash that
  # can be JSON-encoded. The file list is part of the session state, so it
  # is saved/restored together with the conversation.
  def to_h(file_list)
    {
      version:       1,
      session_id:    @session_id,
      created_at:    created_at.iso8601,
      system_prompt: @system_prompt,
      user_prompts:  @user_prompts,
      last_stats:    @last_stats,
      messages:      @messages,
      workdir:       file_list.workdir,
      files:         file_list.to_a
    }
  end

  # Restore the session from a hash (as produced by #to_h, after a JSON
  # round trip with symbolized names). Also restores the given file list:
  # it is cleared and re-populated from the saved file list.
  def restore(data, file_list)
    @system_prompt = data[:system_prompt]
    @created_at    = Time.parse(data[:created_at])
    @session_id    = data[:session_id] if data[:session_id]
    @user_prompts  = data[:user_prompts] || 0
    @last_stats    = data[:last_stats]
    @messages      = data[:messages] || [system_message]

    file_list.clear
    (data[:files] || []).each { |f| file_list.add(f) }
    self
  end

  private

  def system_message
    { role: 'system', content: @system_prompt }
  end
end
