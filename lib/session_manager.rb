# frozen_string_literal: true

require 'json'
require 'fileutils'

require_relative 'harness_error'

# Manages all session-related logic: prompt flow, compaction, rules file,
# model switching, and persistence (save/resume/list).
# Extracted from Harness to keep the LLM-call logic focused.
class SessionManager
  HARNESS_DIR  = '.harness'
  SESSIONS_DIR = File.join(HARNESS_DIR, 'sessions')
  RULES_FILE   = 'harness.md'

  def initialize(harness, file_list)
    @harness     = harness
    @file_list   = file_list
    @rules_mtime = current_rules_mtime
  end

  # -- Prompt flow ---------------------------------------------------------

  # Appends a new user prompt to the session and sends the chain to the LLM.
  # If the request fails, the prompt stays in the session (pending) so it can
  # be re-sent with #retry.
  def run_prompt(instruction)
    if check_rules_reload
      puts "  [harness.md reloaded - project rules updated]"
    end

    # Auto-compact BEFORE sending: it must never run after the response,
    # where it would race with a pending dialog (ui.dialog / grant prompt)
    # for stdin and swallow the user's answer as a cancel (issue #64).
    compact_if_due

    user_prompt = build_user_prompt(instruction)

    if @harness.options[:verbose]
      @harness.logger.info("--- system ---\n#{@harness.session.system_prompt}")
      @harness.logger.info("--- user ---\n#{user_prompt}")
      @harness.logger.info("--- #{@harness.options[:model]} @ #{@harness.options[:base_url]} ---")
    end

    @harness.session.add_user(user_prompt)
    send_session
  end

  # True when an error message looks like the model rejected the request
  # because the context window was exceeded (wording varies by server).
  def context_exceeded_error?(msg)
    msg =~ /context|num_ctx|max.*token|too many tokens|exceeds/i
  end

  # Re-sends the current session chain (e.g. after a failed request).
  # Requires a pending user prompt at the end of the chain.
  def retry
    unless @harness.session.pending?
      raise HarnessError, 'nothing to retry - no pending prompt in the session (send a prompt first)'
    end

    # The previous attempt may have failed because the context was full:
    # compact first, then re-send.
    if @harness.session.auto_compact_due?(@harness.options[:num_ctx] || LLMClient::NUM_CTX, @harness.compact_auto_threshold)
      puts "  [context over threshold - compacting before retry...]"
      result = compact_session
      puts "  [compact done: #{result[:before]} -> #{result[:after]} messages]"
      if result[:context_before] && result[:context_line]
        puts "  #{result[:context_before]} -> #{result[:context_line]}"
      end
    end

    @harness.logger.info("--- retry: re-sending session chain (#{@harness.session.messages.size} messages) ---")
    send_session
  end

  # Compact the session: ask the LLM to summarize the conversation, then
  # replace the full message chain with the summary. This frees up context
  # window space while preserving the essential information.
  # The last N recent messages are retained verbatim after the summary.
  def compact_session
    before = @harness.session.messages.size
    # issue #93: capture context BEFORE compaction so callers can show
    # the token reduction (message count alone is misleading).
    context_before = @harness.context_indicator

    if @harness.session.conversation_size < 4
      raise HarnessError, 'session too small to compact (need at least 4 conversation messages)'
    end

    conversation = @harness.session.messages[1..] # skip the system message
    max_words = @harness.compact_max_size || 500
    messages = conversation + [
      {
        role: 'user',
        content: 'Summarize the entire conversation above in a concise, structured format. ' \
                 'Include: (1) what was being worked on, (2) key decisions made, ' \
                 'files that were modified or created, (4) any pending tasks or ' \
                 'unresolved issues, (5) important context needed to continue. ' \
                 "Keep it under #{max_words} words. Do NOT include the summarization instruction itself."
      }
    ]

    spinner = Spinner.new("Compacting session (#{before} messages to summary)")
    @harness.spinner = spinner
    spinner.start

    summary_text = nil
    begin
      data = @harness.client.chat(messages)
      summary_text = data[:choices][0][:message][:content]
    ensure
      spinner.stop
      @harness.spinner = nil
    end

    raise HarnessError, 'LLM returned empty summary' if summary_text.nil? || summary_text.strip.empty?

    summary_text = summary_text.strip
    @harness.session.compact(summary_text, recent_count: @harness.compact_recent_messages)
    after = @harness.session.messages.size
    retained = [after - 3, 0].max

    @harness.logger.info(
      "session compacted: #{before} to #{after} messages " \
      "(summary: #{summary_text.length} chars, #{retained} recent retained)"
    )
    # issue #70: report the resulting context size so the user can verify
    # that compaction freed space without burning tokens on a follow-up.
    { summary: summary_text, before: before, after: after, retained: retained,
      context_before: context_before, context_line: @harness.context_indicator }
  end

  # Sends the session chain to the LLM and prints the response.
  def send_session
    spinner = Spinner.new("Sending to #{@harness.options[:model]}")
    @harness.spinner = spinner
    spinner.start

    response = nil
    begin
      response = @harness.call_llm
    rescue LLMError => e
      # The request may have been rejected because the context window was
      # exceeded: compact and re-send once (the pending prompt is still in
      # the session). Anything else is re-raised for the caller to handle.
      raise unless context_exceeded_error?(e.message) && @harness.session.conversation_size >= 4

      puts "  [context window exceeded - compacting and re-sending...]"
      result = compact_session
      puts "  [compact done: #{result[:before]} -> #{result[:after]} messages, retrying...]"
      if result[:context_before] && result[:context_line]
        puts "  #{result[:context_before]} -> #{result[:context_line]}"
      end
      response = @harness.call_llm
    ensure
      spinner.stop
      @harness.spinner = nil
    end

    if @harness.options[:verbose]
      @harness.logger.info("--- reasoning ---\n#{response[:reasoning]}")
      @harness.logger.info("--- response ---\n#{response[:content]}")
    end

    puts response[:content]
    @harness.print_stats(response[:stats])
  end

  # Silent auto-compaction, run at the start of the NEXT prompt (see
  # #run_prompt): when the context window is at/over the configured
  # threshold, compact the session before sending. This is mandatory
  # bookkeeping - no confirmation dialog. Runs best-effort: a failure here
  # must never break the prompt flow, the next request will simply fail on
  # the server side and the user can /compact manually.
  def compact_if_due
    return unless @harness.session.auto_compact_due?(@harness.options[:num_ctx] || LLMClient::NUM_CTX, @harness.compact_auto_threshold)

    puts "  [context at #{threshold_pct}% of the window - auto-compacting session...]"
    result = compact_session
    puts "  [auto-compact done: #{result[:before]} -> #{result[:after]} messages]"
    if result[:context_before] && result[:context_line]
      puts "  #{result[:context_before]} -> #{result[:context_line]}"
    end
  rescue => e
    puts "  [auto-compact failed: #{e.message} - try /compact manually]"
  end

  # The configured auto-compact threshold as a percentage.
  def threshold_pct
    @harness.compact_auto_threshold
  end

  # -- Rules file (harness.md) ---------------------------------------------

  def build_system_prompt
    @harness.build_system_prompt
  end

  # Current mtime of the rules file (nil if it doesn't exist).
  def current_rules_mtime
    path = File.join(@file_list.workdir, RULES_FILE)
    File.file?(path) ? File.mtime(path) : nil
  end

  # Check whether harness.md has been modified since the last check.
  # If so, rebuild the system prompt and update the session in-place.
  def check_rules_reload
    mtime = current_rules_mtime
    return false if mtime == @rules_mtime

    @rules_mtime   = mtime
    new_prompt     = build_system_prompt
    @harness.session.update_system_prompt(new_prompt)
    @harness.logger.info("harness.md reloaded (mtime changed)")
    true
  end

  # Reset the rules mtime tracker (called after session restore).
  def reset_rules_mtime
    @rules_mtime = current_rules_mtime
  end

  # Explicitly reload harness.md (called by /reload command).
  def reload_rules
    new_prompt = build_system_prompt
    @rules_mtime = current_rules_mtime
    @harness.logger.info("harness.md reloaded (manual /reload)")
    new_prompt
  end

  # -- Model management ----------------------------------------------------

  # All configured model profiles (array of hashes), or [] when none.
  def model_profiles
    Array(@harness.options[:model_profiles])
  end

  # Name (or id) of the configured default model, or nil.
  def default_model_name
    @harness.options[:default_model]
  end

  # Name (or id) of the currently active model.
  def active_model_name
    @harness.options[:active_model] || @harness.options[:model]
  end

  # Switch to a configured model profile by name (or raw model id).
  def switch_model(name)
    name = name.to_s.strip
    raise HarnessError, 'usage: /model <name>' if name.empty?

    profiles = model_profiles
    if profiles.empty?
      @harness.options[:model]        = name
      @harness.options[:active_model] = name
      return { name: name, model: name }
    end

    match = find_profile(name)
    raise HarnessError, "unknown model '#{name}'. Type /models to see the available models." unless match

    apply_profile(match)
    match
  end

  # Find a configured profile by its name or raw model id (nil when absent).
  def find_profile(name)
    model_profiles.find { |p| p[:name] == name || p[:model] == name }
  end

  # Apply a model profile's settings to options in place.
  def apply_profile(profile)
    opts = @harness.options
    opts[:base_url]         = profile[:url] || opts[:base_url]
    opts[:model]            = profile[:model]
    opts[:token]            = profile[:token]
    opts[:num_ctx]          = profile[:num_ctx]
    opts[:reasoning_effort] = profile[:reasoning_effort]
    opts[:temperature]      = profile[:temperature]
    opts[:top_p]            = profile[:top_p]
    opts[:top_k]            = profile[:top_k]
    opts[:min_p]            = profile[:min_p]
    opts[:presence_penalty] = profile[:presence_penalty]
    opts[:repeat_penalty]   = profile[:repeat_penalty]
    opts[:active_model]     = profile[:name] || profile[:model]
  end

  # Restore the model saved in a session.
  def restore_active_model(name)
    return if name.nil?

    name = name.to_s.strip
    return if name.empty?

    match = find_profile(name)
    unless match
      raise HarnessError, "session's model '#{name}' is not configured anymore - reset to the default model"
    end

    apply_profile(match)
  end

  # -- Prompt building -----------------------------------------------------

  def build_user_prompt(instruction)
    parts = ["## Working Directory\n\n#{@file_list.workdir}"]

    access = @file_list.accessible_paths
    any_grants = access.any? do |_mode, section|
      !section[:files].empty? || !section[:dirs].empty? ||
        !(section[:flat_dirs] || []).empty?
    end

    if any_grants
      sections = []
      %i[both read write].each do |mode|
        section = access[mode]
        lines = []
        lines += section[:files].map { |f| @file_list.display_path(f) }
        lines += section[:dirs].map { |d| "#{@file_list.display_path(d)}/ (recursive)" }
        lines += (section[:flat_dirs] || []).map { |d| "#{@file_list.display_path(d)}/ (dir only)" }
        next if lines.empty?

        label = case mode
                when :both then 'Read + write'
                when :read then 'Read only'
                else 'Write only'
                end
        sections << "#{label}:\n#{lines.join("\n")}"
      end
      parts << "## Accessible Paths\n\n#{sections.join("\n\n")}"
    end

    parts << "## Instruction\n\n#{instruction}\n"
    parts.join("\n\n")
  end

  # -- Persistence ---------------------------------------------------------

  # Directory where saved sessions are stored (inside the working directory).
  def sessions_dir
    File.join(@file_list.workdir, SESSIONS_DIR)
  end

  # Save the current session (conversation + file list) to disk.
  def save_session
    FileUtils.mkdir_p(sessions_dir)

    data = @harness.session.to_h(@file_list)
    data[:active_model] = @harness.options[:active_model]
    json = JSON.generate(data)

    id   = @harness.session.session_id
    path = File.join(sessions_dir, "#{id}.json")

    File.write(path, json)
    @harness.logger.info("session saved: #{id} (#{path})")
    id
  end

  # Resume a saved session by id (full or abbreviated UUID).
  def resume_session(id)
    id = id.to_s.strip
    raise HarnessError, 'usage: /resume <session-id>' if id.empty?

    path = find_session_file(id)
    raise HarnessError, "no saved session matching '#{id}' (see /sessions)" unless path

    data = JSON.parse(File.read(path), symbolize_names: true)
    @harness.session.restore(data, @file_list)
    restore_session_model(data[:active_model])
    reset_rules_mtime
    @harness.logger.info("session resumed: #{File.basename(path, '.json')} (#{path})")
    path
  end

  # List saved sessions, newest first.
  def list_sessions
    return [] unless File.directory?(sessions_dir)

    Dir.glob(File.join(sessions_dir, '*.json')).sort_by { |p| File.mtime(p) }.reverse.map do |path|
      data = JSON.parse(File.read(path), symbolize_names: true)
      {
        id:       File.basename(path, '.json'),
        path:     path,
        saved_at: File.mtime(path),
        messages: (data[:messages] || []).size,
        files:    (data[:files] || []).size,
        workdir:  data[:workdir]
      }
    rescue JSON::ParserError, StandardError
      nil
    end.compact
  end

  private

  # Restore the session's model. When the stored model is no longer
  # configured, show an error and reset to the config default model.
  def restore_session_model(name)
    restore_active_model(name)
  rescue HarnessError => e
    puts "  [error] #{e.message}"
    default = default_model_name
    raise HarnessError, "#{e.message} - and no default model is configured either" unless default

    profile = find_profile(default)
    raise HarnessError, "default model '#{default}' not found in config" unless profile

    apply_profile(profile)
  end

  # Find a saved session file by (abbreviated) id.
  def find_session_file(id)
    raise HarnessError, "invalid session id: #{id}" unless id =~ /\A[0-9a-fA-F-]+\Z/

    matches = Dir.glob(File.join(sessions_dir, '*.json')).select do |p|
      File.basename(p, '.json').downcase.start_with?(id.downcase)
    end

    case matches.size
    when 0 then nil
    when 1 then matches.first
    else
      raise HarnessError, "ambiguous session id '#{id}' - matches: #{matches.map { |p| File.basename(p) }.join(', ')}"
    end
  end
end