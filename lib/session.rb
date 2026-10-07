# frozen_string_literal: true

require 'time'
require 'securerandom'

require_relative 'session_file_cache'

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
  # issue #170: key under which the file digest cache is serialized.
  FILE_CACHE_KEY = 'file_cache'

  # How many recent messages to retain verbatim after compaction, so the
  # immediate working context (exact file contents, tool outputs, etc.)
  # is not lost to summarization.
  # This is the built-in default; it can be overridden per run via the
  # config 'compact.recent_messages' key or the --compact-recent CLI flag.
  COMPACT_RECENT_MESSAGES = 6

  # Default auto-compact threshold as a fraction of the context window
  # (0.88 = compact once the last request used ~88% of num_ctx tokens).
  # Configurable via the 'compact.auto_threshold' config key; set it to
  # 100 (or higher) to effectively disable auto-compaction.
  AUTO_COMPACT_THRESHOLD = 88

  # Default absolute headroom reserved for the compaction summary call
  # (issue #151): a fixed percentage of the window reserves MORE room on
  # larger windows than needed and LESS relative room on smaller ones.
  # Reserving an absolute number of tokens keeps the same room for
  # generating the summary regardless of context size - a 32K window then
  # compacts proportionally earlier than a 100K one. Configurable via
  # the 'compact.reserved_tokens' config key.
  COMPACT_RESERVED_TOKENS = 8192

  # Rough chars-per-token ratio used only for fallback context estimates.
  EST_CHARS_PER_TOKEN = 4

  attr_reader :messages, :created_at, :system_prompt, :session_id,
              :last_reasoning, :file_cache

  def initialize(system_prompt)
    @system_prompt = system_prompt
    @created_at    = Time.now
    @session_id    = SecureRandom.uuid
    @user_prompts  = 0
    @last_stats    = nil
    @last_reasoning = nil
    # issue #170: one cache per session - restored with a resumed session,
    # untouched by compaction (a compacted file is still the same file).
    @file_cache    = SessionFileCache.new
    @messages      = [system_message]
  end

  # True when the session holds nothing but the system message.
  def empty?
    @messages.size == 1
  end

  # True when the chain ends with a user message that has not been answered
  # yet (e.g. after a failed request) - i.e. there is something to retry.
  def pending?
    @messages.last[:role] == 'user'
  end

  def add_user(content)
    @messages << { role: 'user', content: content }
    @user_prompts += 1
    self
  end

  # issue #138: notes recorded with ui.note during a tool loop are held here
  # until the turn commits (then appended as system messages, see
  # SessionManager#send_session / #check_inloop_compaction). Tool-call
  # trails are local to a turn and never commit into the chain, so the NOTE
  # is what persists - not the transient tool result it followed.
  def add_note(text)
    text = text.to_s.strip
    return if text.empty?

    (@notes ||= []) << text
    self
  end

  # Append all pending notes to the chain as system messages and clear the
  # buffer. Called at every commit point (end of turn, in-loop compaction)
  # so the facts survive past the current turn - including across /retry
  # (the notes live in the persisted session chain).
  def flush_notes
    return unless (@notes || []).any?

    @notes.each { |t| @messages << { role: 'system', content: "Note: #{t}" } }
    @notes = []
  end

  def add_assistant(content)
    @messages << { role: 'assistant', content: content }
    self
  end

  def record_stats(stats)
    @last_stats = stats
  end

  # Store the reasoning text of the last LLM response (issue #98), so it
  # can be shown on demand with /reasoning. nil when the model did not
  # return any reasoning for that response.
  def record_reasoning(reasoning)
    @last_reasoning = reasoning.to_s.strip.empty? ? nil : reasoning
    self
  end

  # issue #108: drop the stale stats / reasoning after an in-loop compaction,
  # so auto_compact_due? can re-evaluate from the (much smaller) compacted
  # chain instead of tripping on the pre-compaction prompt_tokens that just
  # caused the compaction.
  def reset_stats
    @last_stats     = nil
    @last_reasoning = nil
    self
  end

  # Reset the session: drop all conversation messages, keep the system prompt.
  def clear
    @messages     = [system_message]
    @user_prompts = 0
    @last_stats   = nil
    @last_reasoning = nil
    @notes        = []
    # issue #170: a fresh conversation has read nothing - the cache is stale.
    @file_cache.clear_all
    @created_at   = Time.now
    self
  end

  # Replace the system prompt in-place (e.g. after harness.md is updated).
  # Updates both the stored prompt and the first message in the chain.
  def update_system_prompt(new_prompt)
    @system_prompt = new_prompt
    @messages[0][:content] = new_prompt
    self
  end

  # Compact the session: replace all conversation messages with a summary.
  # The system prompt is preserved. After compaction the session contains:
  #   [system, user (summary), assistant (acknowledgment), ...recent messages]
  # so the next prompt builds naturally on the summarized context.
  #
  # The last N recent messages (default COMPACT_RECENT_MESSAGES) are retained
  # verbatim after the summary so the immediate working context (exact file
  # contents, tool outputs, precise wording) is not lost to summarization.
  #
  # The retained window is trimmed so it never begins with a `tool` message:
  # a `tool` result must be preceded by the assistant message that carries
  # the matching `tool_calls`, and if that assistant message fell into the
  # summarized (dropped) region the API would reject the chain. Dropping
  # leading `tool` messages guarantees the window starts on a safe boundary.
  #
  # issue #139: the trim is effectively dead code today - in practice this
  # method only sees committed chains, which never contain tool messages
  # (mid-turn tool trails live in the local working copy and are never
  # committed; only the final reply enters the chain). The in-loop path
  # (issue #108) does NOT use a retained tail at all. If an empty retained
  # window were ever produced it degrades gracefully too: the window is
  # simply skipped and the summary stands on its own - the session never
  # ends up with fewer messages than before compaction.
  #
  # issue #170: the file digest cache (@file_cache) is deliberately NOT
  # touched here: a compacted file is still the same file, so the digests
  # of files read in this session stay valid across compaction.
  def compact(summary_text, recent_count: COMPACT_RECENT_MESSAGES)
    # Grab the last N conversation messages (excluding system) before we
    # replace the chain.
    conversation = @messages[1..]
    recent = nil
    if recent_count > 0 && conversation.size > recent_count
      recent = conversation.last(recent_count)
      # Trim leading `tool` messages (orphaned by the summarization boundary).
      recent = recent.drop_while { |m| m[:role] == 'tool' }
    end

    @messages = [
      system_message,
      { role: 'user', content: "This is a summary of our previous conversation:\n\n#{summary_text}" },
      { role: 'assistant', content: 'Understood. I have the context from our previous conversation. How can I help you continue?' }
    ]
    @messages.concat(recent) if recent && !recent.empty?
    # issue #138: pending ui.note facts must not be dropped by compaction -
    # append them as system messages on the fresh chain.
    (@notes || []).each { |t| @messages << { role: 'system', content: "Note: #{t}" } }
    @notes = []
    @last_stats = nil
    @last_reasoning = nil
    self
  end

  # Tokens currently used by the session, as reported by the last LLM
  # response. For multi-iteration turns this is the prompt_tokens of the
  # LAST LLM call in the turn (each call's prompt already includes the full
  # history, so it is the true current context size - summing across
  # iterations would overcount, issue #81). Older stats without that field
  # fall back to usage.prompt_tokens. When the API did not report usage at
  # all, falls back to a rough estimate of the message-chain size. Returns
  # nil when there is no conversation yet and nothing to estimate.
  def context_used
    if @last_stats
      if @last_stats[:prompt_tokens].to_i > 0
        return { tokens: @last_stats[:prompt_tokens], estimated: false }
      end
      usage = @last_stats[:usage] || {}
      if usage[:prompt_tokens].to_i > 0
        return { tokens: usage[:prompt_tokens], estimated: false }
      end
    end

    conversation = @messages[1..]
    return nil if conversation.nil? || conversation.empty?

    context_estimate
  end

  # Rough token estimate of the CURRENT message chain, independent of any
  # reported stats. This is what the spinner shows so it always reflects the
  # chain being sent NOW rather than the previous response's number (issue
  # #126) - including mid-turn tool results that are not yet in last_stats.
  # Returns nil when there is no conversation yet and nothing to estimate.
  def context_estimate
    conversation = @messages[1..]
    return nil if conversation.nil? || conversation.empty?

    { tokens: estimate_tokens(@messages), estimated: true }
  end

  # Pure rough token estimate for an explicit message chain (system message
  # included). Used by the live spinner indicator, which may need to measure
  # a local working chain that is not yet part of this session (issue #126,
  # in-loop compaction). Returns an integer token count.
  def estimate_tokens(messages)
    chars = messages.sum { |m| m[:content].to_s.length }
    (chars / EST_CHARS_PER_TOKEN).ceil
  end

  # Context usage as an integer percentage of the window size (0-100,
  # rounded). Returns nil when there is nothing to measure yet or the
  # window size is invalid. Pure calculation, so it can be tested without
  # touching the harness display layer.
  def context_pct(window_size)
    used = context_used
    return nil if used.nil? || window_size.to_i <= 0

    (used[:tokens].to_f / window_size * 100).round
  end

  # True when the context usage has reached the auto-compact threshold.
  # window_size is the model's context window in tokens; threshold_pct is
  # the threshold as a percentage (0-100, or higher to disable). Returns
  # false when there is nothing to measure yet.
  #
  # reserved_tokens (issue #151): absolute headroom that must stay free for
  # the compaction summary call - compaction is due as soon as usage
  # reaches window_size - reserved_tokens, regardless of threshold_pct.
  # nil disables the headroom check (percentage-based behavior only).
  def auto_compact_due?(window_size, threshold_pct, reserved_tokens: nil)
    used = context_used
    return false if used.nil? || window_size.to_i <= 0

    used[:tokens] >= compact_trigger(window_size, threshold_pct, reserved_tokens: reserved_tokens)
  end

  # The usage level (in tokens) at which auto-compaction fires: the lower
  # of the percentage threshold and the headroom-reserve trigger
  # (issue #151). A non-positive reserve, or a reserve that covers the whole
  # window (nothing could fit in it), leaves the percentage trigger.
  def compact_trigger(window_size, threshold_pct, reserved_tokens: nil)
    trigger = (window_size * (threshold_pct.to_f / 100.0)).ceil
    reserve = reserved_tokens.to_i
    if reserve.positive? && reserve < window_size
      trigger = [trigger, [window_size - reserved_tokens, 0].max].min
    end
    trigger
  end

  # Number of conversation messages (excluding the system message).
  def conversation_size
    @messages.size - 1
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
    lines << "Pending prompt:  #{pending? ? 'yes (last request failed - use /retry)' : 'no'}"
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
      # issue #170: the file digest cache is session state - a resumed
      # session must keep knowing what it last read so write/patch can
      # still detect external changes (and only those).
      FILE_CACHE_KEY => @file_cache.to_h,
      workdir:       file_list.workdir,
      # Access grants are saved per mode (read / write / both) so that
      # separate read and write permissions survive a session round trip.
      # The sections are disjoint (a path granted for read AND write only
      # appears under "both"), so restore re-adds each grant exactly once.
      # Delete is its own independent section (issue #92).
      access:        {
        both:  file_list.accessible_paths[:both],
        read:  file_list.accessible_paths[:read],
        write: file_list.accessible_paths[:write],
        delete: file_list.accessible_paths[:delete]
      }
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
    @notes         = [] # pending notes are per-process; saved ones are already in the chain
    # issue #170: restore the digest cache. The JSON round trip stringifies
    # symbol keys, so both key forms are checked; a missing key means the
    # session was saved before this feature and starts with an empty cache.
    @file_cache.restore(data[FILE_CACHE_KEY] || data[:FILE_CACHE_KEY] || {})

    restore_access_grants(data, file_list)
    self
  end

  # Re-populate the file list from saved access grants. New session files
  # carry a per-mode "access" hash; older files used flat "files", "dirs"
  # and "trees" lists (granted for read AND write).
  def restore_access_grants(data, file_list)
    file_list.clear

    access = data[:access] || data['access']
    if access.is_a?(Hash)
      # Section names -> FileList grant modes (:rw / :r / :w).
      { both: :rw, read: :r, write: :w, delete: :d }.each do |section_key, mode|
        section = access[section_key] || {}
        (section[:files] || []).each { |f| file_list.add_file(f, mode) }
        (section[:dirs]  || []).each { |d| file_list.add_dir(d, mode) }
        (section[:flat_dirs] || []).each { |d| file_list.add_flat_dir(d, mode) }
      end
      return
    end

    # Legacy format: everything was granted read+write.
    (data[:files] || []).each { |f| file_list.add_file(f) }
    (data[:dirs]  || []).each { |d| file_list.add_dir(d) }
    (data[:trees] || []).each { |t| file_list.add_tree(t) }
  end

  private

  def system_message
    { role: 'system', content: @system_prompt }
  end
end
