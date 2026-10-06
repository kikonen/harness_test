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
  # Minimum seconds between two auto-saves inside the same run_prompt cycle
  # (de-dups the pre-send and post-turn saves when the round trip is fast).
  AUTOSAVE_MIN_INTERVAL = 0.5

  def initialize(harness, file_list)
    @harness     = harness
    @file_list   = file_list
    @rules_mtime = current_rules_mtime
    @last_autosave = 0
  end

  # -- Prompt flow ---------------------------------------------------------

  # Appends a new user prompt to the session and sends the chain to the LLM.
  # If the request fails, the prompt stays in the session (pending) so it can
  # be re-sent with #retry.
  def run_prompt(instruction)
    if check_rules_reload
      Task.emit(:system, origin: :session_manager,
                content: '  [harness.md reloaded - project rules updated]')
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
    # issue #107: persist BEFORE sending so the in-flight prompt is on disk
    # and can be /retry'd from a fresh process if this one dies mid-turn.
    maybe_auto_save('pre-send')
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
    if @harness.session.auto_compact_due?(
      @harness.options[:num_ctx] || LLMClient::NUM_CTX, @harness.compact_auto_threshold,
      reserved_tokens: @harness.compact_reserved_tokens
    )
      Task.emit(:compact, origin: :session_manager,
                content: '  [context over threshold - compacting before retry...]')
      result = compact_session
      Task.emit(:compact, origin: :session_manager,
                content: "  [compact done: #{result[:before]} -> #{result[:after]} messages]")
      if result[:context_before] && result[:context_line]
        Task.emit(:compact, origin: :session_manager,
                  content: "  #{result[:context_before]} -> #{result[:context_line]}")
      end
    end

    @harness.logger.info("--- retry: re-sending session chain (#{@harness.session.messages.size} messages) ---")
    send_session
  end

  # -- Auto-save -----------------------------------------------------------

  # issue #107: auto-save the session at every prompt boundary (before send
  # and after a successful turn), so a crash / kill mid-session loses at most
  # the in-flight LLM call rather than the whole conversation. Best-effort:
  # a save failure never breaks the prompt flow (it only warns). Silent on
  # success - these saves are routine bookkeeping, not a user action.
  # De-duplicated within a fast round trip via AUTOSAVE_MIN_INTERVAL.
  def maybe_auto_save(tag)
    return unless @harness.options[:auto_save]
    return if @harness.session.empty?

    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return if now - @last_autosave < AUTOSAVE_MIN_INTERVAL

    @last_autosave = now
    begin
      save_session
      @harness.logger.info("auto-save (#{tag})")
    rescue StandardError => e
      Task.emit(:error, origin: :session_manager,
                content: "  [warning] auto-save failed: #{e.message}")
    end
  end
  # issue #108: in-loop compaction instruction - mid-turn, there is no verbatim
  # tail to carry detail, so the summary must be a complete hand-off of the
  # work state (including tool results) for continuing the task in progress.
  INLOOP_SUMMARY_INSTRUCTION = 'Summarize the ENTIRE conversation and tool work above as a ' \
                               'hand-off for continuing an in-progress task. Include: ' \
                               '(1) the original goal, (2) every step already completed with its ' \
                               'concrete results (file paths, SHAs, command outputs when available), ' \
                               '(3) key decisions made, (4) files modified or created and their ' \
                               'current state, (5) the exact next step to take. '

  # issue #108: ask the LLM for a summary of an arbitrary message chain.
  # conversation is expected WITHOUT the system message. Returns the
  # stripped summary text. Used by both #compact_session (end-of-turn, with a
  # retained tail) and Harness#check_inloop_compaction (mid-turn, no tail).
  def generate_compact_summary(conversation, instruction)
    max_words = @harness.compact_max_size || 500
    messages = conversation + [
      {
        role: 'user',
        content: "#{instruction} " \
                 "Keep it under #{max_words} words. " \
                 'Do NOT include the summarization instruction itself.'
      }
    ]

    data = @harness.client.chat(messages)
    text = data[:choices][0][:message][:content]
    raise HarnessError, 'LLM returned empty summary' if text.nil? || text.strip.empty?

    text.strip
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
    end_instruction = 'Summarize the entire conversation above in a concise, structured format. ' \
                      'Include: (1) what was being worked on, (2) key decisions made, ' \
                      '(3) files that were modified or created, (4) any pending tasks or ' \
                      'unresolved issues, (5) important context needed to continue. '
    # issue #115 / #126: show the LIVE context usage next to the spinner -
    # a callable suffix is re-evaluated every frame from the CURRENT chain,
    # not the "before" snapshot (already visible above).
    Task.emit(:spinner_detail, origin: :session_manager,
              content: { message: "Compacting session (#{before} messages to summary)",
                         suffix: -> { @harness.context_indicator_live } })

    summary_text = generate_compact_summary(conversation, end_instruction)
    @harness.session.compact(summary_text, recent_count: @harness.compact_recent_messages)
    after = @harness.session.messages.size
    retained = [after - 3, 0].max
    # issue #139: dump exactly which messages survived the compaction so the
    # retained window is inspectable from harness.log (message counts alone
    # leave it a guess).
    log_retained_window(@harness.session.messages.last(retained)) if retained.positive?

    @harness.logger.info(
      "session compacted: #{before} to #{after} messages " \
      "(summary: #{summary_text.length} chars, #{retained} recent retained)"
    )
    # issue #70: report the resulting context size so the user can verify
    # that compaction freed space without burning tokens on a follow-up.
    { summary: summary_text, before: before, after: after, retained: retained,
      context_before: context_before, context_line: @harness.context_indicator }
  end

  # issue #108: in-loop compaction. Called at the top of each tool-loop
  # iteration (from Harness#call_llm) when the LAST call's prompt_tokens have
  # reached the auto-compact threshold: instead of letting the next request
  # hit the server-side context limit mid-turn and abort the whole work, the
  # full local working chain (which contains the mid-turn tool trail not yet
  # in @harness.session) is summarized into a single hand-off summary.
  #
  # Design notes:
  # - NO verbatim tail is retained: keeping only the last N messages would
  #   drop the rest of the work trail, which is exactly what auto-save and
  #   --continue (issue #107) exist to protect. The
  #   summary therefore carries the whole chain's state.
  # - The compacted chain is synced back into @harness.session IN PLACE and
  #   immediately persisted, so a crash mid-loop resumes with the complete
  #   (summarized) history, not a partial one.
  # Returns true when compaction ran (the caller must drop any
  # loop-specific state such as the 'loop_warning_injected' flag), false
  # otherwise (not due yet, too small to compact, or the summary call
  # failed - the turn then simply continues with the existing chain).
  def check_inloop_compaction(messages, last_prompt_tokens)
    window  = @harness.options[:num_ctx] || LLMClient::NUM_CTX
    trigger = compact_trigger_tokens
    # issue #151: the trigger depends on the context size - min of the
    # %-threshold and window - reserved headroom for the summary call.
    return false if trigger.nil? || last_prompt_tokens.to_i < trigger

    # Only compact when there is real work to summarize: a single short
    # exchange never reaches the threshold anyway, but guard against an
    # absurdly small window combined with a huge system prompt.
    conversation = messages.size > 1 ? messages[1..] : []
    return false if conversation.size < 4

    # issue #151: report the effective trigger for THIS window (it depends
    # on context size), not just the raw usage percentage.
    Task.emit(:compact, origin: :session_manager,
              content: "  [context at #{last_prompt_tokens}/#{window} tokens (trigger #{trigger}) - in-loop compaction...]")

    # issue #116: the send_session spinner is still animating here (this
    # runs from inside Harness#call_llm). The task has exactly ONE spinner;
    # our :spinner_detail simply re-points its message/suffix for the rest
    # of the wait (the "Sending to ..." line becomes our compaction line).

    Task.emit(:spinner_detail, origin: :session_manager,
              content: { message: 'Compacting session mid-task (summarizing full work trail)',
                         suffix: -> { @harness.context_indicator_live(messages) } })

    summary_text = generate_compact_summary(conversation, INLOOP_SUMMARY_INSTRUCTION)
    new_chain = [
      { role: 'system', content: @harness.session.system_prompt },
      { role: 'user', content: "This is a summary of our previous conversation:\n\n#{summary_text}" },
      { role: 'assistant', content: 'Understood. I have the context from our previous conversation. How can I help you continue?' },
      { role: 'user', content: 'Continuing the in-progress task from the summary above. ' \
                               'Do not repeat steps that are already completed - pick up where it left off.' }
    ]
    before = messages.size # captured BEFORE the replace below

    # Sync back into the session (in place) and persist immediately, so a
    # crash mid-loop resumes with the complete summarized history.
    @harness.session.messages.replace(new_chain)
    @harness.session.reset_stats
    messages.replace(new_chain)
    # issue #138: fold any pending ui.note facts (grants) into the new chain
    # so they survive the compaction.
    @harness.session.flush_notes
    # issue #139: log the fresh post-compaction chain (no retained tail -
    # see INLOOP_SUMMARY_INSTRUCTION).
    log_retained_window(messages)

    @harness.logger.info(
      "in-loop compaction: #{before} -> #{messages.size} messages " \
      "(summary: #{summary_text.length} chars)"
    )
    maybe_auto_save('in-loop compact')
    true
  rescue StandardError => e
    # Best-effort: a failed compaction must not abort an otherwise healthy
    # turn - the next request will simply hit the server-side limit and the
    # existing context-exceeded recovery path applies.
    Task.emit(:error, origin: :session_manager,
              content: "  [in-loop compaction failed: #{e.message} - continuing with the existing chain]")
    false
  end

  # Sends the session chain to the LLM and prints the response.
  def send_session
    # issue #115 / #126: show the LIVE context usage estimate next to the
    # spinner (re-evaluated each frame from the current chain, not a snapshot).
    # We describe the wait; the runner decides when to show / hide the
    # spinner (always while waiting on us).
    Task.emit(:spinner_detail, origin: :session_manager,
              content: { message: "Sending to #{@harness.options[:model]}",
                         suffix: -> { @harness.context_indicator_live } })

    response = nil
    begin
      response = @harness.call_llm
    rescue LLMError => e
      # The request may have been rejected because the context window was
      # exceeded: compact and re-send once (the pending prompt is still in
      # the session). Anything else is re-raised for the caller to handle.
      raise unless context_exceeded_error?(e.message) && @harness.session.conversation_size >= 4

      Task.emit(:compact, origin: :session_manager,
                content: '  [context window exceeded - compacting and re-sending...]')
      result = compact_session
      Task.emit(:compact, origin: :session_manager,
                content: "  [compact done: #{result[:before]} -> #{result[:after]} messages, retrying...]")
      if result[:context_before] && result[:context_line]
        Task.emit(:compact, origin: :session_manager,
                  content: "  #{result[:context_before]} -> #{result[:context_line]}")
      end
      response = @harness.call_llm
    end

    # issue #131: the full reasoning and content of every response go to
    # harness.log ALWAYS (not gated on --verbose): the log is the
    # authoritative record of what the model said, independent of console
    # output. Empty fields are labeled "(none)" to avoid blank sections.
    log_response(reasoning: response[:reasoning], content: response[:content])

    reason = [response[:reasoning]].map { |m| m.to_s.strip }.reject(&:empty?).first
    Task.emit(:response, origin: :session_manager,
              content: ">>> #{reason} <<<") if reason

    Task.emit(:response, origin: :session_manager, content: '=' * 80)
    Task.emit(:response, origin: :session_manager, content: response[:content].to_s)
    Task.emit(:response, origin: :session_manager, content: '-' * 80)

    @harness.print_stats(response[:stats])

    # issue #107: persist the completed turn. The pre-send save already
    # captured the pending prompt; this snapshot makes sure the model's
    # reply is on disk too, so a crash right after the response loses
    # nothing (de-duplicated by AUTOSAVE_MIN_INTERVAL when the round trip
    # was very fast).
    maybe_auto_save('post-turn')
  end

  # Silent auto-compaction, run at the start of the NEXT prompt (see
  # #run_prompt): when the context window is at/over the configured
  # threshold, compact the session before sending. This is mandatory
  # bookkeeping - no confirmation dialog. Runs best-effort: a failure here
  # must never break the prompt flow, the next request will simply fail on
  # the server side and the user can /compact manually.
  def compact_if_due
    return unless @harness.session.auto_compact_due?(
      @harness.options[:num_ctx] || LLMClient::NUM_CTX, @harness.compact_auto_threshold,
      reserved_tokens: @harness.compact_reserved_tokens
    )

    # issue #151: report the effective trigger for THIS window (it depends
    # on context size), not just the raw percentage.
    trigger = compact_trigger_tokens
    Task.emit(:compact, origin: :session_manager,
              content: "  [context over #{trigger} tokens (trigger) - auto-compacting session...]")
    result = compact_session
    Task.emit(:compact, origin: :session_manager,
              content: "  [auto-compact done: #{result[:before]} -> #{result[:after]} messages]")
    if result[:context_before] && result[:context_line]
      Task.emit(:compact, origin: :session_manager,
                content: "  #{result[:context_before]} -> #{result[:context_line]}")
    end
  rescue => e
    Task.emit(:error, origin: :session_manager,
              content: "  [auto-compact failed: #{e.message} - try /compact manually]")
  end

  # The effective auto-compact trigger for the active window (issue #151):
  # min(threshold% of window, window - reserved headroom); nil when invalid.
  def compact_trigger_tokens
    @harness.compact_trigger_tokens
  end

  # issue #131: log the full text of a response (reasoning + content) to
  # harness.log unconditionally (see #send_session). Empty sections are
  # labeled "(none)" so responses without reasoning don't leave blank
  # "--- reasoning ---" blocks.
  def log_response(reasoning:, content:)
    @harness.logger.info("--- reasoning ---\n#{log_text_or_none(reasoning)}")
    @harness.logger.info("--- response ---\n#{log_text_or_none(content)}")
  end

  def log_text_or_none(text)
    s = text.to_s.strip
    s.empty? ? '(none)' : text.to_s
  end

  # issue #139: dump the messages that SURVIVED a compaction (the retained
  # tail, or the fresh in-loop chain) to harness.log. One line per message:
  # role + a ~80-char content preview - enough to see exactly what is still
  # in context without flooding the log with full contents.
  def log_retained_window(messages)
    lines = messages.map do |m|
      %(#{m[:role]}: #{m[:content].to_s.strip[0, 80]})
    end
    @harness.logger.info("retained after compaction:\n" + lines.join("\n"))
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

  # Name (or id) of the currently active model, or nil.
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

    # issue #138: the full grant list is NO LONGER dumped into every prompt.
    # It was redundant noise: static (so repeated verbatim each turn and on
    # every /retry), out of sync after /clear, and irrelevant meta to the
    # model - permissions are enforced by the tools anyway (an unauthorized
    # attempt prompts the user, whose decision then lands in the chain).
    # Task-relevant permission changes (a grant just made) reach the model
    # as system notes via ui.note instead.

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
    # issue #113: the log path is per-session, and resume swaps in a saved
    # session with a different id than the fresh one built at startup -
    # re-point the logger so it follows the resumed session.
    @harness.rebind_logger
    # issue #119: command history is per session too - re-point the history
    # manager so up/down arrows and the saved file follow the new session.
    @harness.history&.bind_session(@harness.session.session_id)
    restore_session_model(data[:active_model])
    reset_rules_mtime
    @harness.logger.info("session resumed: #{File.basename(path, '.json')} (#{path})")
    path
  end

  # issue #107: find the most recently saved session in this workdir's
  # sessions dir (returns a full path). Used by --continue. Returns nil
  # when no sessions exist yet.
  def newest_session_path
    return nil unless File.directory?(sessions_dir)

    Dir.glob(File.join(sessions_dir, '*.json')).max_by { |p| File.mtime(p) }
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
    Task.emit(:error, origin: :session_manager, content: "  [error] #{e.message}")
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
