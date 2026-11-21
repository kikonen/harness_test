# frozen_string_literal: true

require "json"
require "fileutils"

require_relative "harness_error"
require_relative "session_locator"
require_relative "param_overrides"
require_relative "error_text"
require_relative "harness_config"
require_relative "system_record"

# Manages all session-related logic: prompt flow, compaction, rules file,
# model switching, and persistence (save/resume/list).
# Extracted from Harness to keep the LLM-call logic focused.
class SessionManager
  # issue #207: the session JSON lives INSIDE the session's own directory
  # (.harness/sessions/<id>/session.json), alongside its log and history.
  SESSION_FILE = SessionLocator::SESSION_FILE

  RULES_FILE   = "harness.md"

  # Minimum seconds between two auto-saves inside the same run_prompt cycle
  # (de-dups the pre-send and post-turn saves when the round trip is fast).
  AUTOSAVE_MIN_INTERVAL = 0.5

  # issue #108: in-loop compaction instruction - mid-turn, there is no verbatim
  # tail to carry detail, so the summary must be a complete hand-off of the
  # work state (including tool results) for continuing the task in progress.
  INLOOP_SUMMARY_INSTRUCTION = "Summarize the ENTIRE conversation and tool work above " \
    "(the work done, not the system rules you were given) as a " \
    "hand-off for continuing an in-progress task. Include: " \
    "(1) the original goal, (2) every step already completed with its " \
    "concrete results (file paths, SHAs, command outputs when available), " \
    "(3) key decisions made, (4) files modified or created and their " \
    "current state, (5) the exact next step to take. " \
    "Do NOT call any tools - answer with text only. "

  def initialize(harness, file_list)
    @harness     = harness
    @file_list   = file_list
    @locator     = SessionLocator.new(file_list.workdir)
    @rules_mtime = current_rules_mtime
    @last_autosave = 0
    @job_id = 0
  end

  # The system/world persistence record the system's owner injects (#286 / #548): the
  # foreground job id and the foreground replay tail, read through SystemRecord so
  # a per-Harness SessionManager never reaches a scheduling registry it does not
  # own. nil for a Harness built without an owner that injects one - a save then
  # writes neither system-record key.
  attr_accessor :system_record

  # The id of the job this Harness lives in (issue #548 increment 4b): a save
  # writes this job's OWN jobs/<id>/session.json, so a background/sub-agent
  # harness no longer writes into the foreground job's dir. The run's owner sets
  # it when wiring a harness into a job; the main turn is job 0 (the default).
  attr_accessor :job_id

  # -- Prompt flow ---------------------------------------------------------

  # Appends a new user prompt to the session and sends the chain to the LLM.
  # If the request fails, the prompt stays in the session (pending) so it can
  # be re-sent with #retry.
  def run_prompt(instruction)
    # A new prompt is a new turn: a note left pending by a turn that ended
    # abnormally must not ride along as a phantom mid-turn note (issue #430).
    # /retry deliberately does NOT do this - it continues the same turn.
    @harness.discard_pending_user_note(:leftover)

    if check_rules_reload
      Task.emit(
        :system,
        origin: :session_manager,
        content: "  [harness.md reloaded - project rules updated]")
    end

    # Auto-compact BEFORE sending: it must never run after the response,
    # where it would race with a pending dialog (ui.dialog / grant prompt)
    # for stdin and swallow the user's answer as a cancel (issue #64).
    compact_if_due

    user_prompt = build_user_prompt(instruction)

    if @harness.settings.verbose
      @harness.logger.info "--- system ---\n#{@harness.session.system_prompt}"
      @harness.logger.info "--- user ---\n#{user_prompt}"
      model = @harness.model_config
      @harness.logger.info "--- #{model.model} @ #{model.base_url} ---"
    end

    @harness.session.add_user(user_prompt)

    # issue #107: persist BEFORE sending so the in-flight prompt is on disk
    # and can be /retry'd from a fresh process if this one dies mid-turn.
    maybe_auto_save("pre-send")
    send_session
  end

  # True when an error message looks like the model rejected the request
  # because the context window was exceeded (wording varies by server).
  def context_exceeded_error?(msg)
    msg =~ /context|num_ctx|max.*token|too many tokens|exceeds/i
  end

  # Re-sends the current session chain (e.g. after a failed request).
  # issue #208: requires a PENDING chain at the end - either a user prompt
  # that never got an answer, or an interrupted tool round (the session is
  # the working chain, so a turn killed mid-loop ends on a `tool` result or
  # an assistant message with unanswered tool_calls). /retry resumes from
  # exactly that point; the model sees every tool call and result it made.
  def retry
    unless @harness.session.pending?
      raise HarnessError,
        "nothing to retry - the session ends on an answered reply (send a prompt first)"
    end

    # The previous attempt may have failed because the context was full:
    # compact first, then re-send.
    if @harness.session.auto_compact_due?(
      @harness.model_config.num_ctx || LLMClient::NUM_CTX,
      @harness.compact_auto_threshold,
      reserved_tokens: @harness.compact_reserved_tokens)

      Task.emit(
        :compact,
        origin: :session_manager,
        content: "  [context over threshold - compacting before retry...]")
      result = compact_session

      Task.emit(
        :compact,
        origin: :session_manager,
        content: "  [compact done: #{result[:before]} -> #{result[:after]} messages]")

      if result[:context_before] && result[:context_line]
        Task.emit(
          :compact,
          origin: :session_manager,
          content: "  #{result[:context_before]} -> #{result[:context_line]}")
      end
    end

    @harness.logger.info "--- retry: re-sending session chain (#{@harness.session.messages.size} messages) ---"
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
    return unless @harness.settings.auto_save
    return if @harness.session.empty?

    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return if now - @last_autosave < AUTOSAVE_MIN_INTERVAL

    @last_autosave = now
    begin
      save_session
      @harness.logger.info "auto-save (#{tag})"
    rescue StandardError => e
      Task.emit(
        :warn,
        origin: :session_manager,
        content: "auto-save failed: #{ErrorText.label(e)}")
    end
  end

  # Ask the LLM for a summary of an arbitrary message chain. The chain rides AS
  # IS (system message included) with the live turn's own tools payload, so the
  # request stays a prefix of the live prompt - doc/compaction_cache_design.md.
  def generate_compact_summary(chain, instruction)
    max_words = @harness.compact_max_size || 500
    messages = chain + [
      {
        role: "user",
        content: "#{instruction} " \
          "Keep it under #{max_words} words. " \
          "Do NOT include the summarization instruction itself."
      }
    ]

    data    = @harness.client.chat(messages, tools: @harness.tools_payload)
    message = data[:choices][0][:message]
    calls   = Array(message[:tool_calls]).filter_map { |tc| tc.dig(:function, :name) }
    text    = message[:content]
    if text.nil? || text.strip.empty?
      named = calls.join(", ")
      raise HarnessError,
        calls.empty? ? "LLM returned empty summary" :
          "LLM answered the summary request with a tool call (#{named}) instead of a summary"
    end
    if calls.any?
      @harness.logger.info "summary call returned tool calls (#{calls.join(', ')}) - ignored"
    end

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
      raise HarnessError,
        "session too small to compact (need at least 4 conversation messages)"
    end

    # The FULL chain, so the summary call is a prefix of the live prompt (#246).
    chain = @harness.session.messages
    end_instruction = "Summarize the entire CONVERSATION above (the work done, not the " \
      "system rules you were given) in a concise, structured format. " \
      "Include: (1) what was being worked on, (2) key decisions made, " \
      "(3) files that were modified or created, (4) any pending tasks or " \
      "unresolved issues, (5) important context needed to continue. " \
      "Do NOT call any tools - answer with text only. "

    # issue #115 / #126: show the LIVE context usage next to the spinner -
    # a callable suffix is re-evaluated every frame from the CURRENT chain,
    # not the "before" snapshot (already visible above).
    Task.emit(
      :spinner_detail,
      origin: :session_manager,
      content: {
        message: "Compacting session (#{before} messages to summary)",
        suffix: -> { @harness.context_indicator_live }
      })

    summary_text = generate_compact_summary(chain, end_instruction)
    @harness.session.compact(summary_text, recent_count: @harness.compact_recent_messages)
    after = @harness.session.messages.size
    retained = [after - 3, 0].max

    # issue #139: dump exactly which messages survived the compaction so the
    # retained window is inspectable from harness.log (message counts alone
    # leave it a guess).
    # issue #178: the full post-compaction chain - with only the tail dumped,
    # the summary itself (the valuable part) was never in the log at all.
    log_retained_window(@harness.session.messages)

    @harness.logger.info "session compacted: #{before} to #{after} messages " \
      "(summary: #{summary_text.length} chars, #{retained} recent retained)"

    # issue #70: report the resulting context size so the user can verify
    # that compaction freed space without burning tokens on a follow-up.
    {
      summary: summary_text,
      before:,
      after:,
      retained:,
      context_before:,
      context_line: @harness.context_indicator
    }
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
  # - issue #208: the working chain IS the session's, so there is no separate
  #   local copy and no steering notes to carry over - a mid-turn note is
  #   already a message in the chain being summarized.
  # Returns true when compaction ran (the caller must drop any
  # loop-specific state such as the 'loop_warning_injected' flag), false
  # otherwise (not due yet, too small to compact, or the summary call
  # failed - the turn then simply continues with the existing chain).
  def check_inloop_compaction(messages, last_prompt_tokens)
    window  = @harness.model_config.num_ctx || LLMClient::NUM_CTX
    trigger = compact_trigger_tokens

    # issue #151: the trigger depends on the context size - min of the
    # %-threshold and window - reserved headroom for the summary call.
    return false if trigger.nil? || last_prompt_tokens.to_i < trigger

    # Only compact when there is real work to summarize: a single short
    # exchange never reaches the threshold anyway, but guard against an
    # absurdly small window combined with a huge system prompt.
    return false if messages.size - 1 < 4 # the guard counts conversation messages

    # issue #151: report the effective trigger for THIS window (it depends
    # on context size), not just the raw usage percentage.
    Task.emit(
      :compact,
      origin: :session_manager,
      content: "  [context at #{last_prompt_tokens}/#{window} tokens (trigger #{trigger}) - in-loop compaction...]")

    # The spinner Harness left animating (this runs from inside
    # Harness#call_llm) is re-pointed for the summary call's wait only: one
    # :spinner_detail, no start/stop pair.
    Task.emit(
      :spinner_detail,
      origin: :session_manager,
      content: {
        message: "Compacting session mid-task (summarizing full work trail)",
        suffix: -> { @harness.context_indicator_live(messages) }
      })

    summary_text = generate_compact_summary(messages, INLOOP_SUMMARY_INSTRUCTION)
    new_chain = [
      { role: "system", content: @harness.session.system_prompt },
      {
        role: "user",
        content: "This is a summary of our previous conversation:\n\n#{summary_text}"
      },
      {
        role: "assistant",
        content: "Understood. I have the context from our previous conversation. How can I help you continue?"
      },
      {
        role: "user",
        content: "Continuing the in-progress task from the summary above. " \
          "Do not repeat steps that are already completed - pick up where it left off."
      }
    ]
    before = messages.size # captured BEFORE the replace below

    # Sync back into the session (in place) and persist immediately, so a
    # crash mid-loop resumes with the complete summarized history.
    @harness.session.messages.replace(new_chain)
    @harness.session.reset_stats

    # issue #208: in production `messages` IS the session's array (the same
    # object was mutated by call_llm); this line keeps the contract for a
    # caller passing its own chain.
    messages.replace(new_chain)

    # issue #138: fold any pending ui.note facts (grants) into the new chain
    # so they survive the compaction.
    @harness.session.flush_notes

    # issue #139: log the fresh post-compaction chain (no retained tail -
    # see INLOOP_SUMMARY_INSTRUCTION).
    log_retained_window(messages)

    @harness.logger.info "in-loop compaction: #{before} -> #{messages.size} messages " \
      "(summary: #{summary_text.length} chars)"
    maybe_auto_save("in-loop compact")
    true
  rescue StandardError => e
    # Best-effort: a failed compaction must not abort an otherwise healthy
    # turn - the next request will simply hit the server-side limit and the
    # existing context-exceeded recovery path applies.
    Task.emit(
      :warn,
      origin: :session_manager,
      content: "in-loop compaction failed: #{ErrorText.label(e)} - keeping the existing chain")
    false
  end

  # The spinner line for ONE outgoing LLM request. Harness#call_llm is its
  # only caller, so each request re-announces its own wait and a re-point
  # made earlier in the loop cannot outlive it.
  #
  # Issue #271 compacted the form: WHO the request goes to sits in
  # parentheses after the verb, and only the API TYPE is named - the endpoint
  # path #217 added was the longest part of the line and is already in the
  # startup banner and printed by /model. A client with no backend (a stub)
  # gets the model alone.
  # The suffix is the harness's callable for THIS request: while an answer is
  # streaming it shows the newest text of that answer, otherwise the live
  # context estimate (see Harness#request_wait_suffix, issue #28).
  def request_spinner_detail
    who = [@harness.model_config.model.to_s.strip, api_type_label].reject(&:empty?)
    Task.emit(
      :spinner_detail,
      origin: :session_manager,
      content: {
        message: who.empty? ? "Sending" : "Sending (#{who.join(' / ')})",
        suffix: @harness.request_wait_suffix
      })
  end

  # Sends the session chain to the LLM and prints the response. Each request's
  # spinner line belongs to #request_spinner_detail; only waits owned here
  # re-point it.
  def send_session
    response = nil
    begin
      response = @harness.call_llm
    rescue LLMError => e
      # The request may have been rejected because the context window was
      # exceeded: compact and re-send once (the pending prompt is still in
      # the session; issue #208 also leaves a mid-loop tool trail behind,
      # which survives here too). Anything else re-raises for the caller.
      raise unless context_exceeded_error?(e.message) && @harness.session.conversation_size >= 4

      Task.emit(
        :compact,
        origin: :session_manager,
        content: "  [context window exceeded - compacting and re-sending...]")

      result = compact_session

      Task.emit(
        :compact,
        origin: :session_manager,
        content: "  [compact done: #{result[:before]} -> #{result[:after]} messages, retrying...]")

      if result[:context_before] && result[:context_line]
        Task.emit(
          :compact,
          origin: :session_manager,
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
    Task.emit(:plan, origin: :session_manager, content: reason) if reason

    # ONE entry for the answer (issue #146): the "=" * 80 and "-" * 80 rules
    # were two buffer entries whose only job was to frame a line the renderer
    # can frame itself. The rules are gone; the model's text is the content.
    Task.emit(:response, origin: :session_manager, content: response[:content].to_s)

    @harness.emit_stats(response[:stats])

    # issue #107: persist the completed turn. The pre-send save already
    # captured the pending prompt; this snapshot makes sure the model's
    # reply is on disk too, so a crash right after the response loses
    # nothing (de-duplicated by AUTOSAVE_MIN_INTERVAL when the round trip
    # was very fast).
    maybe_auto_save("post-turn")
  end

  # Silent auto-compaction, run at the start of the NEXT prompt (see
  # #run_prompt): when the context window is at/over the configured
  # threshold, compact the session before sending. This is mandatory
  # bookkeeping - no confirmation dialog. Runs best-effort: a failure here
  # must never break the prompt flow, the next request will simply fail on
  # the server side and the user can /compact manually.
  def compact_if_due
    return unless @harness.session.auto_compact_due?(
      @harness.model_config.num_ctx || LLMClient::NUM_CTX,
      @harness.compact_auto_threshold,
      reserved_tokens: @harness.compact_reserved_tokens)

    # issue #151: report the effective trigger for THIS window (it depends
    # on context size), not just the raw percentage.
    trigger = compact_trigger_tokens
    Task.emit(
      :compact,
      origin: :session_manager,
      content: "  [context over #{trigger} tokens (trigger) - auto-compacting session...]")

    result = compact_session

    Task.emit(
      :compact,
      origin: :session_manager,
      content: "  [auto-compact done: #{result[:before]} -> #{result[:after]} messages]")

    if result[:context_before] && result[:context_line]
      Task.emit(
        :compact,
        origin: :session_manager,
        content: "  #{result[:context_before]} -> #{result[:context_line]}")
    end
  rescue => e
    Task.emit(
      :warn,
      origin: :session_manager,
      content: "auto-compact failed: #{ErrorText.label(e)} - try /compact manually")
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
    @harness.logger.info "--- reasoning ---\n#{log_text_or_none(reasoning)}"
    @harness.logger.info "--- response ---\n#{log_text_or_none(content)}"
  end

  def log_text_or_none(text)
    s = text.to_s.strip
    s.empty? ? "(none)" : text.to_s
  end

  # issue #139 / #178: dump the messages that SURVIVED a compaction (the
  # summary + retained tail, or the fresh in-loop chain) to harness.log.
  # The system
  # prompt is identical every compaction and would only be noise, so it is
  # skipped. Content is logged IN FULL, no preview truncation: the summary
  # is exactly what is being inspected here (issue #178), and these dumps
  # are rare enough that harness.log size is a non-issue.
  def log_retained_window(messages)
    lines = messages.reject { |m| m[:role] == "system" }.map do |m|
      %(#{m[:role]}:\n#{m[:content].to_s})
    end
    @harness.logger.info "retained after compaction:\n" + lines.join("\n")
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
    @harness.logger.info "harness.md reloaded (mtime changed)"
    true
  end

  # -- Model management ----------------------------------------------------

  # The profile the active model resolved to (nil when no profiles are
  # configured, or the model was set by -m to a raw id). issue #449.
  def active_profile
    find_profile(active_model_name)
  end

  # True when the ACTIVE model can be sent images: only a profile that declares
  # 'vision: true' in the config. No profiles configured = a raw model id the
  # harness knows nothing about = text-only (the safe reading of an unknown).
  def vision?
    active_profile&.fetch(:vision, false) == true
  end

  # The image inline budget in force for this run: the active profile's own
  # 'mcp_images:' block, else the config-level one, else the built-in defaults
  # (HarnessConfig#normalize_mcp_images fills every key).
  def image_limits
    (active_profile&.dig(:mcp_images)) ||
      @harness.model_config.mcp_image_limits ||
      HarnessConfig::MCP_IMAGE_LIMIT_DEFAULTS
  end

  # Name (or id) of the currently active model, or nil.
  def active_model_name
    @harness.model_config.active_model_name
  end

  # Where the active backend actually sends its calls: the API type and the
  # endpoint path it appends to the configured base URL, e.g.
  # "openai /v1/chat/completions" or "ollama /api/chat". Shown by the UI
  # (startup banner, /model, /models) so a /model switch between API types is
  # visible without reading harness.log (issue #217). The spinner names only
  # the API type (see #request_spinner_detail, issue #271).
  def target_display
    backend = @harness.client.backend
    "#{backend.api_type} #{backend.endpoint_path}"
  end

  # Switch to a configured model profile by name (or raw model id).
  def switch_model(name)
    name = name.to_s.strip
    raise HarnessError, "usage: /model <name>" if name.empty?

    # The spinner's recent tok/s rate (issue #285) was measured against the
    # server being switched away from, so it no longer describes anything this
    # run will do.
    @harness.forget_last_rate

    profiles = @harness.settings.model_profiles
    if profiles.empty?
      @harness.model_config.model        = name
      @harness.model_config.active_model = name
      return { name:, model: name }
    end

    match = find_profile(name)
    raise HarnessError,
      "unknown model '#{name}'. Type /models to see the available models." unless match

    apply_profile(match)
    match
  end

  # Find a configured profile by its name or raw model id (nil when absent).
  def find_profile(name)
    # The catalogue is system-wide static config (#286); the active-model name
    # that feeds it is runtime state owned here.
    @harness.settings.find_profile(name)
  end

  # Apply a model profile to this Harness' ModelConfig in place.
  def apply_profile(profile)
    # The live per-connection values land in THIS Harness' ModelConfig, never
    # in the system-wide settings a #286 sub-agent also shares. A profile with no
    # 'mcp_images:' block says nothing, so ModelConfig#apply_profile leaves the
    # seeded budget intact.
    @harness.model_config.apply_profile(profile)

    # issue #219: a profile change resets the parameter values above - re-
    # apply any session-level overrides so they keep winning (a /model
    # switch should not silently undo /param tweaks made this session).
    param_overrides.restore!
  end

  # Restore the model saved in a session.
  def restore_active_model(name)
    return if name.nil?

    name = name.to_s.strip
    return if name.empty?

    match = find_profile(name)
    unless match
      raise HarnessError,
        "session's model '#{name}' is not configured anymore - reset to the default model"
    end

    apply_profile(match)
  end

  # -- Session-level parameter overrides (issue #219) --------------------
  #
  # The override logic itself lives in ParamOverrides (issue #219) - it owns
  # the adjustable-parameter set, value parsing, and the effective/default
  # lookup. SessionManager only wires it in: a single instance shared with
  # the /param and /model commands, re-applied after a profile change, and
  # persisted/restored with the session.
  def param_overrides
    @param_overrides ||= ParamOverrides.new(
      @harness.model_config,
      profile: -> {
        find_profile(active_model_name)
      })
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

    # issue #359: the planning expectation, stated to the MODEL every turn while
    # the mode is on. This is the whole point of the mode: the USER already knows
    # they are planning; the value is that the model knows too and holds back from
    # editing. It lives HERE (rebuilt every turn) rather than in the system prompt
    # so it survives both compaction paths and a rules re-read, and disappears the
    # moment the mode is off. config/system_prompt.txt is never touched by a
    # posture. Advisory: it states an expectation, it gates no tool.
    if @harness.plan?
      parts << "## Planning mode (advisory)\n\n" \
        "Planning mode is ON. Draft and iterate a plan with plan.add before " \
        "modifying code, and keep it in the durable store. Do not rush to edit " \
        "files: agree the approach first."
    end

    parts << "## Instruction\n\n#{instruction}\n"
    parts.join("\n\n")
  end

  # -- Persistence ---------------------------------------------------------

  # issue #548: a saved SYSTEM is a directory holding system.json (the system/world half)
  # and jobs/<id>/ (each job's own files). The file a save writes - what the save
  # log line and the UI report - is system.json, the system's entry point.
  # issue #276: WHERE a session lives is SessionLocator's knowledge.
  def session_file_path(id) = @locator.system_file_path(id)

  # Save this job's conversation and the system record (issue #548 increment 4a).
  # The ownership seam: this Harness' SessionManager writes ONLY its own job's
  # session.json - the conversation this single LLM loop owns, safe to read on
  # this thread. The system half (system.json + the foreground replay.json) is the
  # SystemRecord's to write, so this object never assembles the system file. A
  # save with no injected record writes a degenerate one-job system (job 0 = the
  # main turn), which is what a standalone SessionManager produces today.
  def save_session
    id        = @harness.session.session_id
    session_h = @harness.session.to_h(@file_list)
    record    = system_record || SystemRecord.new(nil)

    write_own_job_session(id, session_h)
    record.write_system_files(@locator, id, session_h, @harness)

    @harness.logger.info "session saved: #{id} (#{@locator.system_file_path(id)})"
    id
  end

  # Save ONLY this job's own conversation file (issue #548 increment 4b), no
  # system half. At exit the run's owner (CLI) calls it on each finished job
  # whose threads are quiescent, so every job's chain lands in its own dir; the
  # system.json + per-job replay.json are written once by the foreground save.
  # run_id is the SESSION DIRECTORY key (the run's id), not this harness' own
  # session id: a #286 sub-agent harness may mint its own uuid, and its chain
  # must land under this run's jobs/<id>/, not a stray top-level session dir.
  # It defaults to this harness' id only for a standalone (single-job) save.
  def save_job_session(run_id = nil)
    id        = run_id || @harness.session.session_id
    session_h = @harness.session.to_h(@file_list)
    write_own_job_session(id, session_h)
    id
  end

  # Restore the model a session was saved with. Harness#apply_resume_state
  # calls it while building a resumed run (issue #276), so it cannot stay
  # private. When the stored model is no longer configured, report it and
  # fall back to the config default model.
  def restore_session_model(name)
    restore_active_model(name)
  rescue HarnessError => e
    Task.emit(:error, origin: :session_manager, content: e.message)

    default = @harness.settings.default_model
    raise HarnessError,
      "#{e.message} - and no default model is configured either" unless default

    profile = find_profile(default)
    raise HarnessError, "default model '#{default}' not found in config" unless profile

    apply_profile(profile)
  end

  private

  # Write a hash as JSON to a path (the two per-job files share this).
  def write_json(path, data)
    File.write(path, JSON.generate(data))
  end

  # Write this job's own jobs/<job_id>/session.json (the conversation half).
  def write_own_job_session(id, session_h)
    FileUtils.mkdir_p(@locator.job_dir_path(id, job_id))
    write_json(@locator.job_session_file_path(id, job_id), job_session_json(session_h))
  end

  # The foreground agent's own conversation half: its message chain (message 0
  # implicit, exactly as Session#to_h stores @messages[1..]), its per-agent model
  # state, and its parameter overrides (#219). It carries NO session_id - a job is
  # named by its directory plus the id system.json records (DECIDED,
  # doc/session_layers_design.md), so the run UUID is never duplicated in a job
  # file: that is the drift bug Harness#initialize otherwise has to guard.
  def job_session_json(session_h)
    {
      messages: session_h[:messages],
      user_prompts: session_h[:user_prompts],
      last_stats: session_h[:last_stats],
      active_model: @harness.model_config.active_model,
      param_overrides: param_overrides.to_h
    }
  end

  # The API type of the active backend ('openai' / 'ollama'); '' when the
  # client has no backend (a stub).
  def api_type_label
    return "" unless @harness.client.respond_to?(:backend)

    (@harness.client.backend&.api_type).to_s.strip
  end
end
