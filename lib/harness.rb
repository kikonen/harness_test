# frozen_string_literal: true

require "json"
require "time"
require "thread"
require "fileutils"

require_relative "harness_error"
require_relative "ui"
require_relative "tool"
require_relative "llm_client"
require_relative "file_list"
require_relative "session"
require_relative "session_file_cache"
require_relative "session_locator"
require_relative "task"
require_relative "llm/stream_preview"
require_relative "llm/usage_stats"
require_relative "session_manager"
require_relative "state_migrator"
require_relative "safety_check"
require_relative "text_normalizer"
require_relative "error_text"
require_relative "sandbox_gemfile"
require_relative "tool_result"
require_relative "image_store"
require_relative "image_delivery"
require_relative "output_budget"
require_relative "result_spill"
require_relative "system_settings"
require_relative "model_config"
require_relative "tool_registry_builder"
require_relative "session_logger"

require_relative "text_tool_call_parser"
# -- Harness --------------------------------------------------------------

class Harness
  DEFAULT_SYSTEM_PROMPT_FILE = File.expand_path("../config/system_prompt.txt", __dir__)

  MAX_TOOL_ITERATIONS = 200
  # Consecutive-call thresholds: warn (inject a stop message), then break.
  TOOL_LOOP_WARN_THRESHOLD = 30
  # After this many consecutive tool-call iterations, force-break and return whatever we have
  TOOL_LOOP_HARD_LIMIT = 50

  # The two NORMAL ends of an answer; every other value a server reports
  # ('length', 'content_filter', one this harness has never seen) gets a line.
  # What each endpoint reports: doc/truncation_design.md.
  FINISH_EXPECTED = %w[stop tool_calls].freeze

  EMPTY_USAGE = { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 }.freeze

  HARNESS_DIR = ".harness"

  SESSION_LOG_FILE = SessionLocator::SESSION_LOG_FILE

  # The console line naming WHY a mid-turn note could not be applied (:late -
  # the answer was already being written; :leftover - the turn that received it
  # died before any request could take it).
  NOTE_DISCARD_MESSAGES = {
    late: "arrived too late to steer this answer - it was NOT sent to the model. " \
          "Send it again if you still mean it.",
    leftover: "was left over from your previous turn and never reached the model - " \
              "it is NOT applied. Send it again if you still mean it."
  }.freeze

  # Fed back to the model when it wrote a tool call as text the harness could
  # not run, so it re-issues it instead of the failure only reaching the user
  UNSOLVED_TEXT_CALL_FEEDBACK = "Your previous message contained a tool call the " \
    "harness could not run (its tool name matched no registered tool), so NO tool " \
    "was executed. Re-issue it as a structured tool call using the exact name of a " \
    "registered tool, or answer directly in plain text if you do not need a tool."

  # rules_repair_note: what the last rules-file read had to replace (nil when
  # clean) - a repair must not be silent, so the model's prompt differs from
  # harness.md's bytes. mcp/sandbox_gemfile/image_store are collaborators owned
  # elsewhere (doc/sandbox_gemfile_design.md, doc/mcp_images_design.md).
  attr_reader :logger,
    :settings,
    :sandbox_gemfile,
    :model_config,
    :tool_registry,
    :file_list,
    :session,
    :session_manager,
    :client,
    :rules_repair_note,
    :mcp,
    :image_store,
    :text_tool_call_parser

  attr_accessor :history

  # Set by the main thread, consumed on the JOB's own thread: it only flips
  # this flag, never reads the running chain.
  def request_save
    @save_requested = true
  end

  def save_requested?
    @save_requested == true
  end

  # Only one note is in flight: the latest line wins.
  def user_note_text=(text)
    @user_note = text.to_s.strip.empty? ? nil : text.to_s.strip
  end

  def user_notes
    @user_notes
  end

  # A note still pending when a turn ends is dropped here, not injected into
  # the next prompt as a phantom mid-turn note - only a finished turn can tell
  # a late note from a usable one.
  def discard_pending_user_note(kind)
    return nil if @user_note.nil?

    note = @user_note
    @user_note = nil
    logger.warn "user mid-turn note discarded (#{kind}): #{note}"
    Tool.push_status(
      label: "note",
      verdict: :warn,
      # It must also name WHICH note, or the user can't tell which line to resend.
      message: "#{NOTE_DISCARD_MESSAGES.fetch(kind)} The note was: #{note}"
    )
    note
  end

  def initialize(file_list, settings:, session_id: nil, resume_data: nil, logger: nil)
    @file_list = file_list
    @settings  = settings
    @locator   = SessionLocator.new(file_list.workdir)

    # One shared cache for Session and the tool registry: a digest a tool
    # records must be the one a later write is checked against.
    @file_cache = SessionFileCache.new

    log_id  = session_id || @locator.fresh_id
    @logger = logger || SessionLogger.build(@locator.session_log_path(log_id))

    @session = Session.new(build_system_prompt, session_id: log_id, file_cache: @file_cache)

    if resume_data
      saved_id = resume_data[:session_id]
      if saved_id && saved_id != log_id
        raise HarnessError,
          "session file says id #{saved_id} but it is stored under #{log_id}"
      end
      @session.restore(resume_data, @file_list)
    end

    @user_note     = nil
    @user_notes    = []
    @save_requested = false
    StateMigrator.run(@file_list.workdir, HARNESS_DIR)

    # Seeded here because the model's file tools cannot write .harness/.
    @sandbox_gemfile = SandboxGemfile.new(@file_list.workdir)
    case @sandbox_gemfile.ensure_starter!
    when :seeded_locked
      @logger.info "ruby sandbox seeded and locked offline"
    when :seeded_unlocked
      @logger.info "ruby sandbox seeded but the offline lock failed " \
                   "(a starter gem is absent on this box) - bundle install it"
    when :seeded_unreadable
      @logger.warn "ruby sandbox NOT seeded - the default Gemfile " \
                   "#{SandboxGemfile::STARTER_TEMPLATE_FILE} is unreadable"
    end
    case @sandbox_gemfile.ensure_default_gems!
    when :resynced_locked
      @logger.info "ruby sandbox resynced with the default gems and re-locked"
    when :resynced_unlocked
      @logger.info "ruby sandbox resynced with the default gems but the offline " \
                   "lock failed - bundle install it"
    end

    builder = ToolRegistryBuilder.new(
      file_list: @file_list,
      file_cache: @file_cache,
      settings: @settings,
      logger: @logger,
      locator: @locator,
      harness: self
    )
    @tool_registry = builder.build
    @mcp           = builder.mcp
    @text_tool_call_parser = TextToolCallParser.new(@tool_registry)
    # Per-Harness model state (not shared settings): writing the model there
    # would switch every sub-agent's model at once. doc/harness_job_design.md.
    @model_config = ModelConfig.from_settings(settings)
    @client = LLMClient.new(@model_config, @logger)
    @session_manager = SessionManager.new(self, file_list)

    # The planning posture is per-conversation Harness state, not run-wide
    # settings: a foreground [PLAN] toggle must not drag a sub-agent into planning.
    @plan = settings.plan_seed?
    @stream_preview  = nil

    # A live lambda so a mid-turn /yolo flip applies to the next call and off
    # removes coverage at once; never stored, so a resume can't persist it.
    @file_list.posture      = -> { @settings.yolo? }
    @file_list.audit_logger = @logger

    # A dir under this session id, so a saved path still resolves on resume.
    @image_store = ImageStore.new(
      @file_list.workdir, dir: image_content_dir(@session.session_id))

    # The last completed request's rate, for the spinner; nil until one finishes.
    @last_rate = nil

    apply_resume_state(resume_data) if resume_data
  end

  # Rules file is a read boundary: its result is the first message of every
  # chain and a model-editable file.
  def build_system_prompt
    base = read_system_prompt
    project_file = File.join(@file_list.workdir, "harness.md")
    return base unless File.file?(project_file)

    source  = File.read(project_file)
    content = TextNormalizer.normalize(source).strip

    @rules_repair_note = byte_repair_note(source)
    logger.info "harness.md read: #{@rules_repair_note}" if @rules_repair_note
    return base if content.empty?

    "#{base}\n\n## Project-Specific Rules\n\n#{content}\n"
  end

  def session_log_path
    @locator.session_log_path(@session.session_id)
  end

  # Same payload for every request: omitting tools makes a different prompt.
  def tools_payload
    tool_registry.empty? ? nil : tool_registry.to_openai
  end

  def compact_recent_messages
    settings.compact_recent || Session::COMPACT_RECENT_MESSAGES
  end

  def compact_auto_threshold
    settings.compact_auto_threshold || Session::AUTO_COMPACT_THRESHOLD
  end

  # A small window compacts earlier to leave headroom for the summary call.
  def compact_reserved_tokens
    settings.compact_reserved || Session::COMPACT_RESERVED_TOKENS
  end

  def compact_max_size
    settings.compact_max_size
  end

  def max_tool_iterations
    settings.max_tool_iterations || MAX_TOOL_ITERATIONS
  end

  def plan?
    @plan
  end

  def plan=(val)
    @plan = (val == true)
  end

  def toggle_plan
    self.plan = !plan?
    plan_mode_label
  end

  def plan_mode_label
    plan? ? "PLAN" : nil
  end

  # Per-turn inline budget must not leak to the next turn; vision is a profile
  # fact, never guessed for an unconfigured model.
  def image_delivery
    limits = @session_manager.image_limits
    ImageDelivery.new(
      vision: vision?,
      store: @image_store,
      max_inline_bytes: limits[:inline_max_bytes],
      max_inline_images: limits[:inline_max_images],
      max_inline_tokens: limits[:inline_max_tokens])
  end

  def vision?
    @session_manager.vision?
  end

  def image_content_dir(session_id)
    base = settings.mcp_images_dir || ImageStore::DEFAULT_DIR
    File.join(base, session_id.to_s)
  end

  # Task thread writes it, main thread reads it per spinner frame; StreamPreview
  # publishes a frozen group so the reader never sees a partial append.
  def stream_preview_line
    @stream_preview&.tail_line
  end

  # A live rate is '~' (estimated from stream chars); a "(last)" rate is the
  # previous request's own measurement, never the in-flight request's number.
  def request_wait_suffix
    -> { streaming_wait_line || waiting_line }
  end

  # A tool wait carries NO rate: nothing is in flight, so there is no speed.
  def tool_wait_suffix
    -> { context_indicator_live }
  end

  # pad gives the spinner a width-stable number; a log line reads it unpadded.
  def last_rate_segment(pad: false)
    return nil if @last_rate.nil?

    LLM::UsageStats.rate_segment(
      @last_rate[:rate],
      measured_by_server: @last_rate[:server],
      tag: "last",
      pad:
    )
  end

  def record_last_rate(usage, seconds)
    rate = LLM::UsageStats.recent_generation_rate(usage, seconds)
    @last_rate = rate if rate
  end

  # A model switch changes the server, so the old rate describes nothing here.
  def forget_last_rate
    @last_rate = nil
  end

  # SafetyCheck never touches Session, so a batch check cannot trigger compaction.
  def precheck_batch_safety(message_calls)
    return nil unless @settings.command_safety_check

    # YOLO consumes no verdicts, so pre-checking it pays for a forked round trip.
    if @settings.yolo?
      logger.info "safety pre-check skipped (YOLO consumes no verdicts)"
      return nil
    end

    commands = run_command_batch_commands(message_calls)
    return nil if commands.size < 2

    unapproved = commands.reject { |c| tool_allowlist.allowed?(c) }
    return nil if unapproved.size < 2

    skipped = commands.size - unapproved.size
    logger.info "safety pre-check: #{skipped} allowlisted command(s) skipped" if skipped.positive?

    logger.info "safety pre-check (#{unapproved.size} run.command in batch)"
    Tool.push_status(
      label: "safety",
      verdict: :info,
      message: "checking #{unapproved.size} commands before the consent dialog...")

    Task.emit(
      :spinner_detail,
      origin: :harness,
      content: { message: "Model safety check (#{unapproved.size} commands)" })

    settings.safety_verdicts = SafetyCheck.run(
      client,
      session.messages,
      unapproved,
      tools: tools_payload,
      logger:)
  rescue StandardError => e
    logger.info "safety pre-check failed (#{ErrorText.label(e)}) - continuing without verdicts"
    nil
  end

  # Must match the runner's auto-approve exactly: same list, same matching.
  def tool_allowlist
    CommandAllowlist.new(file_list.workdir, file: CommandAllowlist::TOOL_FILENAME)
  end

  # Duplicates stay: the batch order must remain intact.
  def run_command_batch_commands(message_calls)
    calls = Array(message_calls)
    calls.filter_map do |tc|
      next unless tc.dig(:function, :name) == "run.command"

      args, parse_error = parse_tool_arguments(tc.dig(:function, :arguments))
      if parse_error
        logger.warn "run.command arguments did not parse (#{parse_error}) - " \
          "this command is NOT safety pre-checked"
        next
      end
      tool = tool_registry.get("run.command")
      args = tool ? tool.normalize_arguments(args) : args
      args["command"].to_s
    end.reject(&:empty?)
  end

  # THE single auto-compact trigger for every consumer (SessionManager, /ctx).
  def compact_trigger_tokens
    window = model_config.num_ctx || LLMClient::NUM_CTX
    return nil if window.to_i <= 0

    @session.compact_trigger(
      window,
      compact_auto_threshold,
      reserved_tokens: compact_reserved_tokens)
  end

  # [args, nil] or [{}, err]: rescuing straight to {} hides a call that lost shape.
  def parse_tool_arguments(raw)
    return [{}, nil] if raw.nil? || raw.to_s.strip.empty?

    [JSON.parse(raw), nil]
  rescue JSON::ParserError => e
    [{}, e.message]
  rescue StandardError => e
    [{}, ErrorText.label(e)]
  end

  # Only 'length' makes the tool round report truncation, not a malformed call.
  def report_finish_reason(data, iteration)
    reason = data[:finish_reason]
    return false if reason.nil? || FINISH_EXPECTED.include?(reason)

    message =
      if reason == "length"
        "response cut off by the token budget (iteration #{iteration}, " \
          "#{budget_note(data)})"
      else
        "finish reason '#{reason}' (iteration #{iteration})"
      end
    logger.warn message
    Task.emit(:warn, origin: :harness, content: message)
    reason == "length"
  end

  # An unset key means the server's own default is what cut the answer.
  def budget_note(data)
    limit = [model_config.max_tokens, model_config.num_predict].map(&:to_i).find(&:positive?)
    parts = []
    completion = data.dig(:usage, :completion_tokens)
    parts << "#{completion} completion tokens" if completion
    parts << (limit ? "limit #{limit}" : "no token limit configured (server default)")
    parts.join(", ")
  end

  # Fires only for a text-shaped call with no resolvable name (a recoverable
  # one is parsed and run in call_llm first).
  def report_unresolved_text_tool_call(content)
    return false unless @text_tool_call_parser.text_call?(content)

    msg = "the model wrote a tool call as text the harness could not run " \
          "(no structured tool call was returned and its name matched no tool) " \
          "- it was NOT run. Re-send the request; the model may need the " \
          "call asked differently."

    logger.warn "text-shaped tool call in response (issue #461) - NOT executed\n" \
      "-----text_tool_call-----\n#{content}\n----------------"

    Task.emit(:warn, origin: :harness, content: msg)
    true
  end

  # Log-only variant: the user-facing warn is left to the re-issue path below.
  def log_unresolved_text_tool_call(content)
    return false unless @text_tool_call_parser.text_call?(content)

    logger.warn "text-shaped tool call in response (issue #461) - NOT executed\n" \
      "-----text_tool_call-----\n#{content}\n----------------"
    true
  end

  # Each round is appended as it happens, so a turn that dies mid-loop keeps its
  # rounds and /retry resumes from that point, not from the prompt.
  def call_llm
    messages = @session.messages

    @user_notes = []
    tools = tools_payload

    iteration = 0
    consecutive_tool_calls = 0
    last_tool_name = nil
    loop_warning_injected = false
    loop_hard_break = false
    text_call_retried = false
    total_usage = EMPTY_USAGE.dup

    # Iterations whose request came back: the loop counter runs ahead of it.
    answered = 0

    # One per turn: its inline budget is turn-scoped, and its base64 must reach
    # the token estimate before a request carries it.
    delivery = image_delivery

    # The LAST call's prompt_tokens is the context size: each call already
    # carries the history, so summing over counts.
    last_prompt_tokens = 0
    last_performance   = nil

    max_iters = max_tool_iterations
    loop do
      iteration += 1
      raise ToolLoopError, "exceeded max tool iterations (#{max_iters})" if iteration > max_iters

      # Compact on the last call's real size rather than letting the next
      # request fail server-side; iteration 1 has nothing to summarize.
      if iteration > 1 && last_prompt_tokens > 0 &&
         @session_manager.check_inloop_compaction(messages, last_prompt_tokens)
        consecutive_tool_calls = 0
        loop_warning_injected = false
      end

      if @user_note
        note = @user_note
        @user_note = nil
        @user_notes << note
        logger.info "user mid-turn note injected: #{note}"
        messages << { role: "user", content: "User note (mid-turn): #{note}" }
        Tool.push_status(label: "note", verdict: :info, message: "sent to model")
      end

      # Consumed on the JOB's own thread at the same safe point a note lands, so
      # the agent saves its own chain with no cross-thread read.
      if @save_requested
        @save_requested = false
        @session_manager.save_job_session
        logger.info "save request consumed (job ##{@session_manager.job_id})"
      end

      # Each request announces its own wait, so an earlier re-point (an
      # in-loop compaction) cannot outlive it.
      @session_manager.request_spinner_detail

      # Before the request leaves: an aborted turn needs to know which one died.
      open_turn_stats(iteration:, answered:, usage: total_usage)
      data    = request_chain(messages, tools)
      message = data[:choices][0][:message]

      # The model has seen them; keeping them would re-send the same bytes in
      # every later request. The text naming the stored file survives.
      strip_image_payloads(messages)

      # A text-shaped call is parsed leniently so the turn does not silently
      # break; an unresolvable name stays prose and ends as an answer.
      if !message[:tool_calls] && @text_tool_call_parser.text_call?(message[:content])
        committed = messages.filter_map { |m| m[:tool_calls] }.flatten
        recovered = @text_tool_call_parser.parse(message[:content], committed:)
        if recovered.any?
          message[:tool_calls] = recovered
          logger.warn "tool call arrived as text/XML (issue #461), not JSON - parsed and running"
          Tool.push_status(
            label: "text_call",
            verdict: :warn,
            message: "tool call arrived as text/XML, not JSON - parsed and running")
        end
      end

      emit_step(iteration, message) if message[:tool_calls]

      # AFTER the step line, so the warn lands inside the block it describes.
      truncated = report_finish_reason(data, iteration)

      if data[:usage]
        total_usage[:prompt_tokens]     += data[:usage][:prompt_tokens]     || 0
        total_usage[:completion_tokens] += data[:usage][:completion_tokens] || 0
        total_usage[:total_tokens]      += data[:usage][:total_tokens]      || 0
        last_prompt_tokens              = data[:usage][:prompt_tokens].to_i
      end
      answered = iteration

      # The request's own clock and counts, never stats[:elapsed_seconds] (the
      # TURN's time, tool execution included).
      record_last_rate(data[:usage], @request_seconds)

      # The LAST call describes the next request's state, so it replaces the
      # earlier ones - measurements of different requests cannot be summed.
      last_performance = LLM::UsageStats.performance_snapshot(data[:usage])

      @session.record_prompt_tokens(last_prompt_tokens, messages.size)

      if message[:tool_calls]
        # -- Tool-loop detection --
        current_tool_name = message[:tool_calls].first[:function][:name]
        if current_tool_name == last_tool_name
          consecutive_tool_calls += 1
        else
          consecutive_tool_calls = 1
          last_tool_name = current_tool_name
        end

        if consecutive_tool_calls >= TOOL_LOOP_HARD_LIMIT
          logger.warn "tool-loop hard limit reached (#{consecutive_tool_calls} consecutive calls to '#{current_tool_name}') - forcing final response"
          loop_hard_break = true
        elsif consecutive_tool_calls >= TOOL_LOOP_WARN_THRESHOLD && !loop_warning_injected
          logger.warn "tool-loop warning: #{consecutive_tool_calls} consecutive calls to '#{current_tool_name}' - injecting stop message"
          loop_warning_injected = true
        end

        logger.info "--- tool_calls (iteration #{iteration}, consecutive: #{consecutive_tool_calls}) ---"
        message[:tool_calls].each do |tc|
          logger.info "  calling #{tc[:function][:name]}(#{tc[:function][:arguments]})"
        end

        assistant_msg = { role: "assistant", content: message[:content] }
        assistant_msg[:tool_calls] = message[:tool_calls]
        @session.add_assistant_message(assistant_msg)

        # Single run.command calls check themselves inside CommandRunner.
        precheck_batch_safety(message[:tool_calls])
        message[:tool_calls].each do |tc|
          raw = execute_tool_call(tc, truncated:)
          tool_msg = tool_result_message(tc, raw, delivery)
          record_note(tc, tool_msg[:content])
          messages << tool_msg
        end

        # The model cannot see the harness' budget, so the cut is named once per
        # round - otherwise it retried the same oversized call forever.
        if truncated
          messages << {
            role: "user",
            content: "Your previous response was cut off by the token budget " \
                     "(#{budget_note(data)}). Any tool call in it may be incomplete. " \
                     "Do NOT re-send the same call: split it into smaller calls or " \
                     "shorten its content."
          }
        end

        if loop_hard_break
          messages << {
            role: "user",
            content: "STOP. You are stuck in a tool loop. Do NOT call any more tools. " \
                     "Respond NOW with your final answer. If you were editing files, use the file.write tool to save them. " \
                     "If this was a query, answer it directly in plain text."
          }
          next
        end

        if loop_warning_injected && consecutive_tool_calls == TOOL_LOOP_WARN_THRESHOLD
          messages << {
            role: "user",
            content: "Reminder: You have called the same tool multiple times in a row. " \
                     "If you have enough information, stop calling the same tool and provide your final answer now."
          }
        end

        next
      end

      discard_pending_user_note(:late)

      # An unresolved text call is fed back ONCE (the model would otherwise never
      # learn its call failed); the second occurrence falls through to warn +
      # commit, so quoted prose cannot spin the loop.
      if text_call_retried
        report_unresolved_text_tool_call(message[:content])
      elsif log_unresolved_text_tool_call(message[:content])
        text_call_retried = true
        @session.add_assistant_message({ role: "assistant", content: message[:content] })
        messages << { role: "user", content: UNSOLVED_TEXT_CALL_FEEDBACK }
        Tool.push_status(
          label: "text_call",
          verdict: :warn,
          message: "tool call arrived as text the harness could not run - " \
                   "asked the model to re-issue it")
        next
      end

      stats = close_turn_stats(iteration:, usage: total_usage,
                               prompt_tokens: last_prompt_tokens,
                               performance: last_performance)

      @session.add_assistant(message[:content])
      @session.flush_notes
      @session.record_stats(stats)
      @session.record_reasoning(message[:reasoning])

      # A committed chain is text state: no base64 belongs in it or a session file.
      strip_image_payloads(messages)

      return {
        reasoning: message[:reasoning],
        content:   message[:content],
        stats:
      }
    end
  end

  # A String passes through; a ToolResult goes to ImageDelivery, which names each
  # image's fate and returns the base64 a vision request carries.
  def tool_result_message(tool_call, raw, delivery)
    msg = { role: "tool", tool_call_id: tool_call[:id], content: raw.to_s }
    return msg unless raw.is_a?(ToolResult)

    decisions = delivery.plan(raw)
    msg[:content] = append_image_notes(msg[:content], delivery.describe(decisions))
    payloads = delivery.inlineable?(decisions).map do |decision|
      {
        mime_type: decision.image.mime_type,
        base64: ImageDelivery.base64_of(decision)
      }
    end
    msg[:images] = payloads unless payloads.empty?
    log_image_decision(tool_call[:function][:name], decisions)
    msg
  end

  def append_image_notes(text, notes)
    return text if notes.to_s.empty?
    return notes if text.to_s.empty?

    "#{text}\n#{notes}"
  end

  # Logged inline or not: "the model cannot see it" matters when an answer looks
  # blind to a screenshot.
  def log_image_decision(tool_name, decisions)
    decisions.each do |d|
      detail = d.inline? ? "inlined" : "#{d.mode} (#{d.reason})"
      logger.info "tool #{tool_name} image: #{d.image.mime_type} #{d.image.byte_size}B -> #{detail}"
    end
  end

  # Text naming the stored file stays; only base64 is dropped.
  def strip_image_payloads(messages)
    messages.each { |m| m.delete(:images) }
  end

  # Buffered so it survives the transient tool result and reaches the chain on commit.
  def record_note(tool_call, result)
    return unless tool_call[:function][:name] == "session.note"
    return unless result.is_a?(String) && result.start_with?("ok: noted")

    args, parse_error = parse_tool_arguments(tool_call[:function][:arguments])
    if parse_error
      logger.warn "session.note arguments did not parse (#{parse_error}) - note not buffered"
      return
    end
    @session.add_note(args["text"])
  rescue StandardError
    # A malformed note must never break the turn.
  end

  def aborted_turn_stats_line(job_id)
    snapshot = aborted_turn_stats
    return nil if snapshot.nil? || snapshot[:job_id] != job_id

    stats_line(snapshot)
  end

  def emit_stats(stats)
    line = stats_line(stats)
    return nil if line.nil?

    Task.emit(:stats, origin: :harness, content: line)
  end

  # An aborted turn reports answered-over-sent iterations only: token and
  # performance figures would describe requests that never returned.
  def stats_line(stats)
    return nil if stats.nil?

    elapsed = stats[:elapsed_seconds]
    usage   = stats[:usage]
    aborted = stats[:pending_iteration]
    iters   = stats[:iterations]
    iteration_part =
      if aborted
        "🔄 #{iters} of #{aborted} iterations answered"
      else
        "🔄 #{iters} iteration#{'s' if iters != 1}"
      end

    parts = ["⏱ #{format_elapsed(elapsed)}", iteration_part]
    unless aborted
      parts << "📊 #{usage[:prompt_tokens]}→#{usage[:completion_tokens]} tokens (#{usage[:total_tokens]} total)"
      perf = LLM::UsageStats.performance_parts(stats[:performance])
      parts << "⚡ #{perf.join(' | ')}" unless perf.empty?
    end

    ctx = context_indicator
    parts << ctx if ctx

    "  [#{parts.join(' | ')}]"
  end

  def format_elapsed(seconds)
    s = seconds.to_f
    return "#{s.round(2)}s" if s < 60

    mins = (s / 60).floor
    secs = format("%05.2f", s - mins * 60).sub(".", ",")
    "#{mins}m #{secs}s"
  end

  def context_indicator
    window = model_config.num_ctx || LLMClient::NUM_CTX
    used = @session.context_used
    return nil if used.nil?

    pct = @session.context_pct(window)
    label = used[:estimated] ? "~" : ""
    "🧠 ctx #{label}#{used[:tokens]}/#{window} (#{pct}%)"
  end

  # The SPINNER's context segment: the CURRENT chain (mid-turn results included)
  # as a glanceable percentage. Raw token arithmetic stays in #context_indicator.
  def context_indicator_live(messages = nil)
    window = model_config.num_ctx || LLMClient::NUM_CTX
    if messages
      tokens  = @session.anchored_estimate(messages)
      label   = "~"
    else
      used = @session.context_used
      return nil if used.nil?
      tokens  = used[:tokens]
      label   = used[:estimated] ? "~" : ""
    end

    pct = (tokens.to_f / window * 100).round
    "🧠 #{label}#{pct}% (#{window_label(window)})"
  end

  # Arithmetic stays here, the row shape is UI::Renderer's; nil with nothing to
  # measure.
  def context_usage
    window = model_config.num_ctx || LLMClient::NUM_CTX
    used   = @session.context_used
    return nil if used.nil?

    trigger = compact_trigger_tokens

    pct      = @session.context_pct(window)
    headroom = [window - used[:tokens], 0].max

    {
      window:,
      tokens: used[:tokens],
      estimated: used[:estimated],
      pct:,
      headroom:,
      trigger:,
      trigger_pct: trigger ? (trigger.to_f / window * 100).round : nil,
      due: trigger ? used[:tokens] >= trigger : false
    }
  end

  # The machinery lives in Mcp::Manager; these are its thin delegators.
  def close_mcp
    @mcp.close
  end

  def mcp_status_notes
    @mcp.status_notes
  end

  # Read at save time from the live Manager rather than tracked separately.
  def mcp_connected_summary
    @mcp.connected_summary
  end

  # The backend refuses an over-window request and auto-compact then fails on the
  # same chain, so the cap lands HERE, before the result is a message; full text
  # spills to the session dir. doc/tool_output_budget_design.md.
  def budget_tool_result(name, result)
    return result if result.is_a?(ToolResult)

    if (capped = spill_read_result?(name, result))
      return capped
    end

    text  = result.to_s
    fit   = OutputBudget.fit(text, limit: output_result_bytes)
    return text unless fit.truncated?

    @result_seq = (@result_seq || 0) + 1
    spill       = result_spill.write(name, @result_seq, text)
    @logger.warn "tool #{name} result #{text.bytesize} B capped to " \
                 "#{fit.text.bytesize} B (#{spill || 'not spilled'})"
    fit.text + OutputBudget.notice(fit.bytes_dropped, spill:)
  end

  # A session dir is blocked for the file tools, so the tool that spilled reads
  # its own spill file, capped - reading the overflow cannot overflow again.
  def read_spilled_result(path)
    rel = @file_list.relative_path(@file_list.resolve(path))
    return nil unless rel && result_spill.covers?(rel)

    ResultSpill::ALREADY_CAPPED_MARK +
      OutputBudget.read_capped(@file_list.resolve(path), limit: output_result_bytes)[0]
  rescue SystemCallError => e
    "error: cannot read #{path} (#{e.message})"
  end

  # The mark FileReadTool#read_spilled sets: returns the stripped text, or nil.
  def spill_read_result?(name, result)
    return nil unless name == "file.read" && result.is_a?(String)
    return nil unless result.start_with?(ResultSpill::ALREADY_CAPPED_MARK)

    result[ResultSpill::ALREADY_CAPPED_MARK.length..]
  end

  def output_result_bytes
    settings.output_result_bytes || OutputBudget::DEFAULT_RESULT_BYTES
  end

  # A spill is harness state: the model tells the user where it is, not reads it.
  def result_spill
    return @result_spill if defined?(@result_spill)

    @result_spill = ResultSpill.new(@locator, @session.session_id,
                                    job_id: @session_manager.job_id)
  end

  private

  def open_turn_stats(iteration:, answered:, usage:)
    @turn_stats = {
      job_id: @session_manager.job_id,
      started_at: Time.now,
      iterations: answered,
      pending_iteration: iteration,
      usage: usage.dup
    }
  end

  def close_turn_stats(iteration:, usage:, prompt_tokens:, performance:)
    open = @turn_stats
    closed = { **open, iterations: iteration, usage: }
    closed.delete(:pending_iteration)
    closed[:prompt_tokens] = prompt_tokens
    closed[:performance] = performance
    closed[:committed] = true
    @turn_stats = closed
  end

  # A turn with no answered request reports nothing (elapsed-only would read as
  # the whole turn's duration).
  def aborted_turn_stats
    open = @turn_stats
    return nil if open.nil? || open[:committed]
    return nil if @session_manager.job_id != open[:job_id]
    return nil if open[:iterations].to_i.zero?

    open.merge(
      elapsed_seconds: (Time.now - open[:started_at]).round(2),
      usage: open[:usage].dup
    )
  end

  # Cleared in the ensure, not after the call: a request that died mid-stream
  # must not leave its partial tail for the next request. doc/streaming_design.md.
  def request_chain(messages, tools)
    streaming = @settings.stream?
    # Session owns the ratio the spinner's rate and context indicator need.
    preview = streaming ? LLM::StreamPreview.new(
      chars_per_token: Session::EST_CHARS_PER_TOKEN
    ) : nil
    @stream_preview = preview
    # The callback holds THIS request's object, not the ivar the ensure clears:
    # a late delta would call record on nil.
    on_delta = preview ? ->(delta) { preview.record(delta) } : nil

    # stats[:elapsed_seconds] is the TURN's, so this request needs its own clock.
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      @client.chat(messages, tools:, stream: streaming, on_delta:)
    ensure
      @request_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      @stream_preview = nil
    end
  end

  # No rate: a rate over an arriving-nothing window decays frame by frame
  # (9.0 -> 4.5 -> 2.2), the "connection is dying" reading this replaces.
  def tool_phase_line(phase)
    [phase, context_indicator_live].compact.join(" ")
  end

  # A tool call REPLACES the tail: while one is written no text arrives, so a
  # line built on a stopped tail reads as a frozen connection.
  def streaming_wait_line
    phase = @stream_preview&.tool_call_line
    return tool_phase_line(phase) if phase

    tail = stream_preview_line
    return nil if tail.nil?

    rate = LLM::UsageStats.rate_segment(
      @stream_preview&.live_rate, measured_by_server: false, pad: true
    )
    rate ? "#{tail} #{rate}" : tail
  end

  # nil when neither part has anything: the spinner's contract is "no suffix",
  # not an empty segment.
  def waiting_line
    parts = [context_indicator_live, last_rate_segment(pad: true)].compact
    return nil if parts.empty?

    parts.join(" ")
  end

  def emit_step(iteration, message)
    return if step_display_disabled?

    @session_manager.log_response(reasoning: message[:reasoning], content: message[:content])

    first_line = ->(key) { [message[key]].map { |m| m.to_s.strip }.reject(&:empty?).first }
    reason  = first_line.call(:reasoning)
    content = first_line.call(:content)

    tools = message[:tool_calls].map { |tc| tc[:function][:name] }
    # One ROLE per event so UI::Renderer does not regex markers back out; only
    # the number is emitted here, "step" is the renderer's word.
    Task.emit(:step_label, origin: :harness, content: iteration)
    Task.emit(:plan, origin: :harness, content: reason) if reason
    Task.emit(:interstitial, origin: :harness, content:) if content
    Task.emit(:tool_plan, origin: :harness, content: tools.join(", "))
  end

  def step_display_disabled?
    ENV.fetch("HARNESS_STEP_DISPLAY", "") == "off" || settings.step_display == false
  end

  # A read boundary: it is the first message of every chain, so an unnormalized
  # one would raise in JSON.generate at request or save time.
  def read_system_prompt
    path = settings.system_file
    return TextNormalizer.normalize(File.read(path)) if path && File.file?(path)

    TextNormalizer.normalize(File.read(DEFAULT_SYSTEM_PROMPT_FILE))
  end

  # Counts bytes (the assertion is about bytes); nil when the file read as UTF-8 cleanly.
  def byte_repair_note(source)
    return nil if source.valid_encoding?

    bad = source.each_char.count { |c| !c.valid_encoding? }
    return nil if bad.zero?

    label = bad == 1 ? "1 invalid byte" : "#{bad} invalid bytes"
    "#{label} replaced - harness.md is not valid UTF-8"
  end

  # A window is read as an order of magnitude; five digits is noise in a
  # per-frame line, so windows under 1000 stay exact.
  def window_label(window)
    w = window.to_i
    w < 1000 ? w.to_s : "#{(w / 1000.0).round}K"
  end

  # A waiting tool leaves the outbox quiet, so the drain loop replays the
  # already-finished request - a long command reads as if the model were still
  # generating. Tool NAME only: the spinner adds its own "...".
  def announce_tool_call(name)
    Task.emit(
      :spinner_detail,
      origin: :harness,
      content: { message: name, suffix: tool_wait_suffix })
  end

  # A parse failure on a truncated call is reported as truncation - the honest
  # cause - not a malformed call the model is invited to repeat.
  def execute_tool_call(tool_call, truncated: false)
    func_name = tool_call[:function][:name]
    args, parse_error = parse_tool_arguments(tool_call[:function][:arguments])
    if parse_error
      logger.warn "tool #{func_name} arguments did not parse (#{parse_error})"
      if truncated
        return "error: the response was cut off by the token budget before " \
               "this call's arguments arrived complete, so the call was NOT " \
               "executed. Re-send it as a SMALLER call (shorter content / " \
               "fewer options)."
      end
      return "error: tool call arguments are not valid JSON (#{parse_error})"
    end

    tool = tool_registry.get(func_name)
    unless tool
      return "error: unknown tool '#{func_name}'"
    end

    unwrapped = tool.normalize_arguments(args)
    if unwrapped != args
      logger.info "tool #{func_name} arguments arrived wrapped in an extra 'arguments' key - unwrapped"
    end
    args = unwrapped

    announce_tool_call(func_name)

    begin
      result = tool.execute(args)
      logger.info "tool #{func_name} → #{OutputBudget.log_excerpt(result)}"
      # A ToolResult is normalized where its text is built and carries raw image
      # bytes beside it; flattening the object to #to_s would lose the images.
      text = result.is_a?(ToolResult) ? result : TextNormalizer.normalize(result)
      budget_tool_result(func_name, text)
    rescue => e
      logger.error ErrorText.detailed(e, "tool #{func_name} failed")
      "error: #{ErrorText.label(e)}"
    end
  end

  # Not conversation state, so Session#restore cannot apply it.
  def apply_resume_state(data)
    @session_manager.restore_session_profile(resume_profile_id(data))
    @session_manager.param_overrides.load(data[:param_overrides])
    @session_manager.param_overrides.restore!

    # A key the session does not carry keeps its config value, so a session
    # saved before the posture existed falls back to the default.
    @settings.restore_persisted(data)
    logger.info "yolo posture restored: #{@settings.yolo? ? 'ON' : 'OFF'}"
    logger.info "streaming posture restored: #{@settings.stream? ? 'ON' : 'OFF'}"
    logger.info "markdown posture restored: #{@settings.markdown? ? 'ON' : 'OFF'}"

    # Server-measured, so a resumed session shows a rate immediately; a
    # client-timed one would need seconds it does not have.
    saved_rate = LLM::UsageStats.recent_generation_rate(data.dig(:last_stats, :performance), nil)
    @last_rate = saved_rate if saved_rate
    logger.info "recent generation rate restored: #{last_rate_segment}" if saved_rate

    logger.info "output palette restored: #{@settings.output_palette.name}"

    # Compare the saved session's tools with what this run connected, so a server
    # this run cannot reach is stated out loud, not a tool set the model quietly
    # lost. A session with no key reads as nothing to compare.
    @mcp.report_saved_session(data[:mcp_connected])
  end

  # The profile id a saved session recorded. 'active_model' is the key sessions
  # saved before the selection was renamed, so it is still read.
  def resume_profile_id(data)
    return data[:active_profile_id] if data.key?(:active_profile_id)

    data[:active_model]
  end
end
