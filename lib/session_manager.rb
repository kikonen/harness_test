# frozen_string_literal: true

require "json"
require "fileutils"

require_relative "harness_error"
require_relative "session_locator"
require_relative "param_overrides"
require_relative "error_text"
require_relative "harness_config"
require_relative "compactor"

# Manages all session-related logic: prompt flow, compaction, rules file,
# model switching, and persistence (save/resume/list).
# Extracted from Harness to keep the LLM-call logic focused.
class SessionManager
  SESSION_FILE = SessionLocator::SESSION_FILE

  RULES_FILE   = "harness.md"

  # De-dups the pre-send and post-turn saves when the round trip is fast.
  AUTOSAVE_MIN_INTERVAL = 0.5

  def initialize(harness, file_list)
    @harness     = harness
    @file_list   = file_list
    @locator     = harness.locator
    @rules_mtime = current_rules_mtime
    @last_autosave = 0
    @job_id = 0
  end

  # A save writes this job's OWN jobs/<id>/session.json, never the foreground's.
  # The run's owner sets it; the main turn is job 0 (the default).
  attr_accessor :job_id

  # A failed request leaves the prompt pending so #retry can re-send it.
  def run_prompt(instruction)
    # A new prompt is a new turn: a note left by an aborted turn must not ride
    # along as a phantom mid-turn note. /retry continues the same turn.
    @harness.discard_pending_user_note(:leftover)

    if check_rules_reload
      Task.emit(
        :system,
        origin: :session_manager,
        content: "  [harness.md reloaded - project rules updated]")
    end

    # Auto-compact BEFORE sending: a post-response compaction would race a
    # pending dialog for stdin and swallow the user's answer as a cancel.
    compact_if_due

    user_prompt = build_user_prompt(instruction)

    if @harness.settings.verbose
      @harness.logger.info "--- system ---\n#{@harness.session.system_prompt}"
      @harness.logger.info "--- user ---\n#{user_prompt}"
      config = @harness.model_config
      @harness.logger.info "--- #{config.active_profile_name} @ #{config.base_url} ---"
    end

    @harness.session.add_user(user_prompt)

    # Persist BEFORE sending so an in-flight prompt survives a mid-turn death.
    maybe_auto_save("pre-send")
    send_session
  end

  # Resumes from the pending point the session ends on (unanswered prompt, or
  # a tool round killed mid-loop).
  def retry
    unless @harness.session.pending?
      raise HarnessError,
        "nothing to retry - the session ends on an answered reply (send a prompt first)"
    end

    # The previous attempt may have failed because the context was full:
    # compact first, then re-send.
    if @harness.session.auto_compact_due?(
      @harness.model_config.num_ctx || LLMClient::NUM_CTX,
      @harness.settings.compact_auto_threshold,
      reserved_tokens: @harness.settings.compact_reserved_tokens)

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

  # A save with no saver saves nothing: a saver-less write would replace a
  # real multi-job system.json with a degenerate one-job record.
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

  # The fork that turns a chain into a summary lives in Compactor; it reads this
  # harness live, so a /model switch or a rebuilt tool registry reaches the next
  # compaction instead of being captured at startup.
  def compactor
    Compactor.new(
      client: @harness.client,
      tools_payload: @harness.tools_payload,
      max_words: @harness.settings.compact_max_size,
      logger: @harness.logger)
  end

  def compact_session
    before = @harness.session.messages.size
    # Message count alone understates the token reduction.
    context_before = @harness.context_indicator

    if @harness.session.conversation_size < 4
      raise HarnessError,
        "session too small to compact (need at least 4 conversation messages)"
    end

    # The FULL chain keeps the summary call a prefix of the live prompt.
    chain = @harness.session.messages

    # A callable suffix re-evaluates the CURRENT chain every frame.
    Task.emit(
      :spinner_detail,
      origin: :session_manager,
      content: {
        message: "Compacting session (#{before} messages to summary)",
        suffix: -> { @harness.context_indicator_live }
      })

    summary_text = compactor.summarize(chain, Compactor::END_INSTRUCTION)
    @harness.session.compact(summary_text, recent_count: @harness.settings.compact_recent_messages)
    after = @harness.session.messages.size
    retained = [after - 3, 0].max

    # Dump the whole post-compaction chain so the summary itself is inspectable.
    log_retained_window(@harness.session.messages)

    # The previews that cited the oldest spills just left the chain.
    prune_spills

    @harness.logger.info "session compacted: #{before} to #{after} messages " \
      "(summary: #{summary_text.length} chars, #{retained} recent retained)"

    # Report the resulting context size without a follow-up request.
    {
      summary: summary_text,
      before:,
      after:,
      retained:,
      context_before:,
      context_line: @harness.context_indicator
    }
  end

  # Summarizes the full local working chain (mid-turn tool trail included) into
  # one hand-off, with NO verbatim tail. The chain is synced back into the
  # session in place and persisted immediately, so a crash mid-loop resumes with
  # the complete summarized history. Returns true when compaction ran (the
  # caller must then drop loop state such as loop_warning_injected).
  def check_inloop_compaction(messages, last_prompt_tokens)
    window  = @harness.model_config.num_ctx || LLMClient::NUM_CTX
    trigger = compact_trigger_tokens

    return false if trigger.nil? || last_prompt_tokens.to_i < trigger

    # Guard an absurdly small window against a huge system prompt.
    return false if messages.size - 1 < 4

    Task.emit(
      :compact,
      origin: :session_manager,
      content: "  [context at #{last_prompt_tokens}/#{window} tokens (trigger #{trigger}) - in-loop compaction...]")

    # Re-points the already-running spinner with one :spinner_detail.
    Task.emit(
      :spinner_detail,
      origin: :session_manager,
      content: {
        message: "Compacting session mid-task (summarizing full work trail)",
        suffix: -> { @harness.context_indicator_live(messages) }
      })

    # The same #503 fallback applies here: the in-loop chain is the largest chain
    # a run ever holds, so it is the one most likely to reject its own summary call.
    summary_text = compactor.summarize(messages, Compactor::INLOOP_INSTRUCTION)
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
    before = messages.size

    @harness.session.messages.replace(new_chain)
    @harness.session.reset_stats
    # In production `messages` IS the session's array; this covers a caller
    # that passed its own chain.
    messages.replace(new_chain)
    @harness.session.flush_notes # pending notes must survive the compaction
    log_retained_window(messages)

    # The whole work trail - every spill path it named - is now only in the summary.
    prune_spills

    @harness.logger.info "in-loop compaction: #{before} -> #{messages.size} messages " \
      "(summary: #{summary_text.length} chars)"
    maybe_auto_save("in-loop compact")
    true
  rescue StandardError => e
    # A failed compaction must not abort a healthy turn: the next request
    # hits the server-side limit and the context-exceeded path recovers.
    Task.emit(
      :warn,
      origin: :session_manager,
      content: "in-loop compaction failed: #{ErrorText.label(e)} - keeping the existing chain")
    false
  end

  # Only the API TYPE is named here: the endpoint path is already in the
  # startup banner and printed by /model, and was the longest part of the line.
  def request_spinner_detail
    who = [@harness.model_config.active_profile_name.to_s.strip, api_type_label].reject(&:empty?)
    Task.emit(
      :spinner_detail,
      origin: :session_manager,
      content: {
        message: who.empty? ? "Sending" : "Sending (#{who.join(' / ')})",
        suffix: @harness.request_wait_suffix
      })
  end

  def send_session
    response = nil
    begin
      response = @harness.call_llm
    rescue LLMError => e
      # A context-exceeded rejection: compact and re-send once (the pending
      # prompt and any mid-loop tool trail survive). Anything else re-raises.
      raise unless Compactor.context_exceeded?(e.message) &&
        @harness.session.conversation_size >= 4

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

    # harness.log is the authoritative record, so this is never gated on --verbose.
    log_response(reasoning: response[:reasoning], content: response[:content])

    reason = [response[:reasoning]].map { |m| m.to_s.strip }.reject(&:empty?).first
    Task.emit(:plan, origin: :session_manager, content: reason) if reason

    Task.emit(:response, origin: :session_manager, content: response[:content].to_s)

    @harness.emit_stats(response[:stats])

    # Persist the reply too, so a crash right after the response loses nothing.
    maybe_auto_save("post-turn")
  end

  # Best-effort: a failure here must not break the prompt flow.
  def compact_if_due
    return unless @harness.session.auto_compact_due?(
      @harness.model_config.num_ctx || LLMClient::NUM_CTX,
      @harness.settings.compact_auto_threshold,
      reserved_tokens: @harness.settings.compact_reserved_tokens)

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

  def compact_trigger_tokens
    @harness.compact_trigger_tokens
  end

  def log_response(reasoning:, content:)
    @harness.logger.info "--- reasoning ---\n#{log_text_or_none(reasoning)}"
    @harness.logger.info "--- response ---\n#{log_text_or_none(content)}"
  end

  def log_text_or_none(text)
    s = text.to_s.strip
    s.empty? ? "(none)" : text.to_s
  end

  # The system prompt is identical every compaction, so it is skipped; content
  # is logged in full because the summary is exactly what is being inspected.
  def log_retained_window(messages)
    lines = messages.reject { |m| m[:role] == "system" }.map do |m|
      %(#{m[:role]}:\n#{m[:content].to_s})
    end
    @harness.logger.info "retained after compaction:\n" + lines.join("\n")
  end

  # Compaction is when a spill stops being reachable: the tool result that named
  # its path leaves the chain, and only the summary's prose may still cite it.
  # So the job's spill dir is trimmed to its newest window here and nowhere else
  # (issue #595). Best-effort: a harness double without a spill, or a failed
  # remove, must not fail the compaction that already succeeded.
  def prune_spills
    removed = @harness.result_spill.prune if @harness.respond_to?(:result_spill)
    return if removed.nil? || removed.empty?

    @harness.logger.info "spill files pruned: #{removed.size} (kept the newest " \
      "#{ResultSpill::DEFAULT_KEEP} or the configured output_spill_keep)"
  rescue SystemCallError => e
    @harness.logger.warn "spill prune failed: #{ErrorText.label(e)}"
  end

  def build_system_prompt
    @harness.build_system_prompt
  end

  def current_rules_mtime
    path = File.join(@file_list.workdir, RULES_FILE)
    File.file?(path) ? File.mtime(path) : nil
  end

  # Rebuild the system prompt and update the session in-place when harness.md changed.
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

  def active_profile
    find_profile(@harness.model_config.active_profile_id)
  end

  def vision?
    active_profile&.vision == true
  end

  # Active profile's mcp_images block, else config-level, else built-in defaults.
  def image_limits
    (active_profile&.mcp_images) ||
      @harness.model_config.mcp_image_limits ||
      HarnessConfig::MCP_IMAGE_LIMIT_DEFAULTS
  end

  def active_profile_name
    @harness.model_config.active_profile_name
  end

  def target_display
    backend = @harness.client.backend
    "#{backend.api_type} #{backend.endpoint_path}"
  end

  def switch_profile(profile_id)
    profile = find_profile(profile_id.to_s.strip)
    raise HarnessError, "no such profile '#{profile_id}' - list them with /models" if profile.nil?

    # The recent tok/s rate was measured against the server being left.
    @harness.forget_last_rate

    apply_profile(profile)
    profile
  end

  # The catalogue is run-wide static config; which profile this Harness is on
  # is live state owned here.
  def find_profile(id)
    @harness.settings.find_profile(id)
  end

  def apply_profile(profile)
    # Per-connection values land in THIS Harness' ModelConfig, never the
    # settings a sub-agent shares.
    @harness.model_config.apply_profile(profile)

    # A profile change resets parameters; re-apply overrides so a /model
    # switch does not silently undo /param tweaks made this session.
    param_overrides.restore!
  end

  def restore_active_profile(id)
    return if id.nil?

    id = id.to_s.strip
    return if id.empty?

    match = find_profile(id)
    unless match
      raise HarnessError,
        "session's profile '#{id}' is not configured anymore - reset to the default profile"
    end

    apply_profile(match)
  end

  # ParamOverrides owns the logic; this wires in one instance shared with the
  # /param and /model commands and persisted with the session.
  def param_overrides
    @param_overrides ||= ParamOverrides.new(
      @harness.model_config,
      profile: -> {
        find_profile(@harness.model_config.active_profile_id)
      })
  end

  def build_user_prompt(instruction)
    parts = ["## Working Directory\n\n#{@file_list.workdir}"]

    # Stated to the MODEL every turn while on (rebuilt here, not in the system
    # prompt, so it survives compaction and a rules re-read and vanishes when
    # off). Advisory only - it states an expectation, it gates no tool.
    if @harness.plan?
      parts << "## Planning mode (advisory)\n\n" \
        "Planning mode is ON. Draft and iterate a plan with plan.add before " \
        "modifying code, and keep it in the durable store. Do not rush to edit " \
        "files: agree the approach first."
    end

    parts << "## Instruction\n\n#{instruction}\n"
    parts.join("\n\n")
  end

  # WHERE a session lives is SessionLocator's knowledge.
  def session_file_path = @locator.system_file_path

  # Saves only this job's own conversation file. system.json and the per-job
  # job.json/replay.json are the run owner's (SystemSaver#save_run): a per-job
  # writer would overwrite the foreground's grants and digests with its own.
  def save_job_session
    write_own_job_session(@harness.session.to_h(@file_list))
  end

  alias_method :save_session, :save_job_session

  def restore_session_profile(id)
    restore_active_profile(id)
  rescue HarnessError => e
    Task.emit(:error, origin: :session_manager, content: e.message)

    profile = @harness.settings.active_profile
    apply_profile(profile) if profile
  end

  private

  def write_json(path, data)
    File.write(path, JSON.generate(data))
  end

  def write_own_job_session(session_h)
    FileUtils.mkdir_p(@locator.job_dir(job_id))
    write_json(@locator.job_session_file_path(job_id), job_session_json(session_h))
  end

  # Carries NO session_id: a job is named by its directory plus the id
  # system.json records (doc/session_layers_design.md), so the run UUID is never
  # duplicated in a job file. version/created_at are read unconditionally by
  # Session#restore, so a job restored from its own file must supply them.
  def job_session_json(session_h)
    {
      version: session_h[:version],
      created_at: session_h[:created_at],
      messages: session_h[:messages],
      user_prompts: session_h[:user_prompts],
      last_stats: session_h[:last_stats],
      active_profile_id: @harness.model_config.active_profile_id,
      param_overrides: param_overrides.to_h
    }
  end

  # '' when the client has no backend (a stub).
  def api_type_label
    return "" unless @harness.client.respond_to?(:backend)

    (@harness.client.backend&.api_type).to_s.strip
  end
end
