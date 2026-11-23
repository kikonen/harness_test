# frozen_string_literal: true

require "time"

require_relative "session_file_cache"
require_relative "llm/usage_stats"

# The session IS the working chain: a failed turn keeps its rounds so /retry
# resumes from that point. The file list is part of the session state and
# travels with it (#to_h / #restore).

class Session
  UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  FILE_CACHE_KEY = "file_cache"

  # Rough chars-per-token ratio used only for fallback context estimates.
  EST_CHARS_PER_TOKEN = 4

  attr_reader :messages, :created_at, :system_prompt,
              :last_reasoning, :file_cache

  # A conversation has no identity: the run's owner names it by the session
  # directory its files live under (SessionLocator), never by a value it carries.
  def initialize(system_prompt, file_cache:)
    @system_prompt = system_prompt
    @created_at    = Time.now
    @user_prompts  = 0
    @last_stats    = nil
    @last_reasoning = nil
    @file_cache    = file_cache
    @messages      = [system_message]
    @token_anchor  = nil
  end

  def empty?
    @messages.size == 1
  end

  # True when the chain ends on an unfinished turn: an unanswered user
  # message, a tool result with no follow-up, or an assistant with tool_calls
  # that never produced results.
  def pending?
    last = @messages.last
    case last[:role]
    when "user" then true
    when "tool" then true
    else last[:role] == "assistant" && Array(last[:tool_calls]).any?
    end
  end

  def add_user(content)
    @messages << { role: "user", content: }
    @user_prompts += 1
    self
  end

  # Buffered until commit; a tool-call trail is transient but the note must
  # survive into the chain.
  def add_note(text)
    text = text.to_s.strip
    return if text.empty?

    (@notes ||= []) << text
    self
  end

  # Called at every commit point so facts survive /retry.
  def flush_notes
    return unless (@notes || []).any?

    @notes.each { |t| @messages << { role: "system", content: "Note: #{t}" } }
    @notes = []
  end

  def add_assistant(content)
    @messages << { role: "assistant", content: }
    self
  end

  # tool_calls stay verbatim so a killed mid-turn run keeps the round it made.
  def add_assistant_message(message)
    @messages << message
    self
  end

  def record_stats(stats)
    @last_stats = stats
  end

  # The chain prefix the server saw, frozen so compaction cannot invalidate it.
  # Call from Harness#call_llm before appending this response, so the anchor
  # always describes exactly what the server counted.
  def record_prompt_tokens(tokens, chain_size)
    return unless tokens.to_i.positive?

    prefix = @messages[0, chain_size]
    @token_anchor = { tokens: tokens.to_i, size: chain_size, prefix: prefix&.freeze }
  end

  def record_reasoning(reasoning)
    @last_reasoning = reasoning.to_s.strip.empty? ? nil : reasoning
    self
  end

  # Without this, auto_compact_due? re-trips on the pre-compaction prompt_tokens.
  def reset_stats
    @last_stats     = nil
    @last_reasoning = nil
    # The compacted chain no longer starts with the anchor's prefix.
    @token_anchor   = nil
    self
  end

  def clear
    @messages     = [system_message]
    @user_prompts = 0
    @last_stats   = nil
    @last_reasoning = nil
    @notes        = []
    @token_anchor = nil
    @file_cache.clear_all
    @created_at = Time.now
    self
  end

  # harness.md is re-read live; the first chain message must follow it.
  def update_system_prompt(new_prompt)
    @system_prompt = new_prompt
    @messages[0][:content] = new_prompt
    self
  end

  # The retained window never begins on a `tool` message: an orphaned tool
  # result without its assistant tool_calls would fail the API. @file_cache
  # is deliberately untouched - a compacted file is still the same file.
  def compact(summary_text, recent_count:)
    conversation = @messages[1..]
    recent = nil
    if recent_count > 0 && conversation.size > recent_count
      recent = conversation.last(recent_count)
      recent = recent.drop_while { |m| m[:role] == "tool" }
    end

    @messages = [
      system_message,
      { role: "user", content: "This is a summary of our previous conversation:\n\n#{summary_text}" },
      { role: "assistant", content: "Understood. I have the context from our previous conversation. How can I help you continue?" }
    ]
    @messages.concat(recent) if recent && !recent.empty?
    (@notes || []).each { |t| @messages << { role: "system", content: "Note: #{t}" } }
    @notes = []
    @last_stats = nil
    @last_reasoning = nil
    self
  end

  # The LAST call's prompt_tokens is the true size: each call's prompt already
  # carries the history, so summing iterations would overcount.
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

  def context_estimate
    conversation = @messages[1..]
    return nil if conversation.nil? || conversation.empty?

    { tokens: anchored_estimate(@messages), estimated: true }
  end

  # Images are counted as their base64 length: an uncounted 1.6 MB data URI
  # is four times a 65536-token window and would never trigger compaction.
  def estimate_tokens(messages)
    chars = messages.sum do |m|
      m[:content].to_s.length + image_chars(m)
    end
    (chars / EST_CHARS_PER_TOKEN).ceil
  end

  def image_chars(message)
    Array(message[:images]).sum do |img|
      (img[:base64] || img["base64"]).to_s.length
    end
  end

  # Anchors to the last server-measured prefix because chars/4 disagrees
  # with the server's tokenizer by tens of percent. Without an anchor it
  # degrades to the raw estimate.
  def anchored_estimate(messages)
    anchor = @token_anchor
    if anchor && messages.size >= anchor[:size] &&
       anchor[:prefix] && messages.first(anchor[:size]) == anchor[:prefix]
      new_msgs = messages[anchor[:size]..]
      return anchor[:tokens] + estimate_tokens(new_msgs)
    end

    estimate_tokens(messages)
  end

  def context_pct(window_size)
    used = context_used
    return nil if used.nil? || window_size.to_i <= 0

    (used[:tokens].to_f / window_size * 100).round
  end

  def auto_compact_due?(window_size, threshold_pct, reserved_tokens: nil)
    used = context_used
    return false if used.nil? || window_size.to_i <= 0

    used[:tokens] >= compact_trigger(window_size, threshold_pct, reserved_tokens:)
  end

  def compact_trigger(window_size, threshold_pct, reserved_tokens: nil)
    trigger = (window_size * (threshold_pct.to_f / 100.0)).ceil
    reserve = reserved_tokens.to_i
    if reserve.positive? && reserve < window_size
      trigger = [trigger, [window_size - reserved_tokens, 0].max].min
    end
    trigger
  end

  def conversation_size
    @messages.size - 1
  end

  # process_id: a RUN fact the caller supplies (#527). Session is the per-LLM
  # conversation and has no business knowing the OS process, so the value is
  # passed in and only displayed here; nil (the default) shows no row.
  def summary(process_id: nil)
    counts = Hash.new(0)
    @messages.each { |m| counts[m[:role]] += 1 }

    items = [
      { field: "Session started", value: created_at.strftime("%Y-%m-%d %H:%M:%S") },
      { field: "Messages", value: "#{@messages.size} total" }
    ]
    counts.each { |role, n| items << { field: role, value: n.to_s } }
    items << { field: "User prompts", value: @user_prompts.to_s }
    items << {
      field: "Pending prompt",
      value: pending? ? "yes (last request failed - use /retry)" : "no"
    }
    items << { field: "Process id", value: process_id.to_s } if process_id
    if @last_stats
      usage = @last_stats[:usage]
      parts = ["#{@last_stats[:elapsed_seconds]}s, #{@last_stats[:iterations]} iteration(s)"]
      if usage && usage[:total_tokens] > 0
        parts << "#{usage[:prompt_tokens]}→#{usage[:completion_tokens]} tokens (#{usage[:total_tokens]} total)"
      end
      perf = LLM::UsageStats.performance_parts(@last_stats[:performance])
      parts << perf.join(", ") unless perf.empty?
      items << { field: "Last request", value: parts.join(", ") }
    else
      items << { field: "Last request", value: "no successful requests yet" }
    end
    items
  end

  # The system prompt is NOT saved: it is derived harness state, rebuilt each
  # run from base file + harness.md.
  def to_h(file_list)
    {
      version:       1,
      created_at:    created_at.iso8601,
      user_prompts:  @user_prompts,
      last_stats:    @last_stats,
      messages:      @messages[1..],
      FILE_CACHE_KEY => @file_cache.to_h,
      workdir:       file_list.workdir,
      # Sections are disjoint so restore re-adds each grant exactly once.
      access:        {
        both:  file_list.accessible_paths[:both],
        read:  file_list.accessible_paths[:read],
        write: file_list.accessible_paths[:write],
        delete: file_list.accessible_paths[:delete]
      }
    }
  end

  # The chain is rebuilt from the system message THIS session was constructed
  # with (current build_system_prompt), so a resumed run follows the rules as
  # they are now.
  def restore(data, file_list)
    # A half saved before per-job created_at has none; parsing nil would crash
    # the whole resume for the cost of one cosmetic /session line.
    created = data[:created_at]
    @created_at = created ? Time.parse(created) : Time.now
    @user_prompts  = data[:user_prompts] || 0
    @last_stats    = data[:last_stats]
    conversation   = data[:messages] || []
    # A legacy file stored the prompt twice (a system_prompt key AND a leading
    # system message); drop that stored message so the built prompt wins.
    conversation   = conversation.drop(1) if data.key?(:system_prompt) &&
                                             conversation.first&.fetch(:role, nil) == "system"
    @messages      = [system_message] + conversation
    @notes         = [] # saved notes are already in the chain
    @file_cache.restore(data[FILE_CACHE_KEY] || data[:FILE_CACHE_KEY] || {})

    restore_access_grants(data, file_list)
    self
  end

  # Older files used flat "files"/"dirs"/"trees" lists (read AND write).
  def restore_access_grants(data, file_list)
    file_list.clear

    access = data[:access] || data["access"]
    if access.is_a?(Hash)
      { both: :rw, read: :r, write: :w, delete: :d }.each do |section_key, mode|
        section = access[section_key] || {}
        (section[:files] || []).each { |f| file_list.add_file(f, mode) }
        (section[:dirs]  || []).each { |d| file_list.add_dir(d, mode) }
        (section[:flat_dirs] || []).each { |d| file_list.add_flat_dir(d, mode) }
      end
      return
    end

    (data[:files] || []).each { |f| file_list.add_file(f) }
    (data[:dirs]  || []).each { |d| file_list.add_dir(d) }
    (data[:trees] || []).each { |t| file_list.add_tree(t) }
  end

  private

  def system_message
    { role: "system", content: @system_prompt }
  end
end
