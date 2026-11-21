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

  HARNESS_DIR = ".harness"

  SESSION_LOG_FILE = SessionLocator::SESSION_LOG_FILE

  # The console line naming WHY a mid-turn note could not be applied (:late -
  # the answer was already being written; :leftover - the turn that received it
  # died before any request could take it). Issue #430.
  NOTE_DISCARD_MESSAGES = {
    late: "arrived too late to steer this answer - it was NOT sent to the model. " \
          "Send it again if you still mean it.",
    leftover: "was left over from your previous turn and never reached the model - " \
              "it is NOT applied. Send it again if you still mean it."
  }.freeze

  # Fed back to the model when it wrote a tool call as text the harness could
  # not run, so it re-issues it instead of the failure only reaching the user
  # (issue #487).
  UNSOLVED_TEXT_CALL_FEEDBACK = "Your previous message contained a tool call the " \
    "harness could not run (its tool name matched no registered tool), so NO tool " \
    "was executed. Re-issue it as a structured tool call using the exact name of a " \
    "registered tool, or answer directly in plain text if you do not need a tool."

  # rules_repair_note: what the LAST rules-file read had to replace (nil when the
  # file was clean). A repair must not be silent - the prompt the model was given
  # is then not byte-for-byte what harness.md holds.
  # mcp: the Mcp::Manager that owns the declared servers, their connections and
  # startup notes (issue #48). The MCP machinery lives there, not in Harness.
  # sandbox_gemfile: the harness-seeded, model-managed project Ruby sandbox
  # (issue #340). doc/sandbox_gemfile_design.md.
  # image_store: the harness' own blob store for tool-result images
  # (issue #449). doc/mcp_images_design.md.
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

  # Only one note is in flight: a new assignment replaces the note that has
  # not been injected yet - the latest line wins.
  def user_note_text=(text)
    @user_note = text.to_s.strip.empty? ? nil : text.to_s.strip
  end

  def user_notes
    @user_notes
  end

  # The commit-time ack is optimistic - only a finished turn can tell a late
  # note from a usable one - so a note still pending when a turn ends is
  # dropped here rather than injected into the NEXT prompt as a phantom
  # mid-turn note (issue #430).
  def discard_pending_user_note(kind)
    return nil if @user_note.nil?

    note = @user_note
    @user_note = nil
    logger.warn "user mid-turn note discarded (#{kind}): #{note}"
    Tool.push_status(
      label: "note",
      verdict: :warn,
      # The console line names WHY it was dropped; it must also name WHICH
      # note, or the user cannot tell which of their steering lines to resend
      # (issue #450 - the log line already had the text, the console did not).
      message: "#{NOTE_DISCARD_MESSAGES.fetch(kind)} The note was: #{note}"
    )
    note
  end

  def initialize(file_list, settings:, session_id: nil, resume_data: nil, logger: nil)
    @file_list = file_list
    @settings  = settings
    @locator   = SessionLocator.new(file_list.workdir)

    # The digest cache is SHARED (#286): this run builds ONE SessionFileCache
    # and hands the same object to Session and to the tool registry, so the
    # digests a tool records on read/write are exactly the ones this session
    # compares a later write against. Ownership sits with the run, not Session.
    @file_cache = SessionFileCache.new

    # The per-session log path is keyed by the session id. The run's owner (CLI)
    # injects a finished logger; when none is passed Harness builds it from the
    # id this run resolves, so every consumer reads one logger (#286).
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
    StateMigrator.run(@file_list.workdir, HARNESS_DIR)

    # Harness-seeded because the model's file tools cannot write the sensitive
    # .harness/. A fresh seed also locks it offline (no network); the outcome is
    # logged so a seed that could NOT lock (a gem absent on this box) is visible
    # rather than surfacing as a mid-run LoadError. doc/sandbox_gemfile_design.md.
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
    # The default gem list is a floor even for a sandbox this model has edited:
    # a gem the starter declares that went missing mid-run would otherwise only
    # surface as a LoadError in the middle of a script.
    case @sandbox_gemfile.ensure_default_gems!
    when :resynced_locked
      @logger.info "ruby sandbox resynced with the default gems and re-locked"
    when :resynced_unlocked
      @logger.info "ruby sandbox resynced with the default gems but the offline " \
                   "lock failed - bundle install it"
    end

    # The tool registry and the MCP machinery are built by ToolRegistryBuilder
    # from collaborators handed in (#286), not from Harness state: it owns the
    # Mcp::Manager it connects and exposes it, so Harness only reads it back.
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
    # issue #461: recovers a tool call a model wrote as text instead of a
    # structured tool_calls array (see doc/text_tool_call_design.md).
    @text_tool_call_parser = TextToolCallParser.new(@tool_registry)
    # Each Harness owns ONE LLM connection, so its model / endpoint / token /
    # sampling / context-window parameters are per-Harness live state in a
    # ModelConfig seeded from the run-wide settings - NOT the shared settings
    # object (a #286 sub-agent shares settings; writing the model there would
    # switch every agent's model at once). /model and /param mutate only this
    # view; settings stays the seed + catalogue carrier. Ownership:
    # doc/harness_job_design.md.
    @model_config = ModelConfig.from_settings(settings)
    @client = LLMClient.new(@model_config, @logger)
    @session_manager = SessionManager.new(self, file_list)

    # Consent + display postures (yolo/stream/markdown/palette, the two
    # command-safety flags) are run-wide SystemSettings state read through
    # @settings (#286). The planning posture is the exception - per-conversation
    # Harness state, seeded from the config only - so a #286 sub-agent is NOT
    # forced into planning mode by a [PLAN] toggle on the foreground
    # (doc/planning_mode_design.md).
    @plan = settings.plan_seed?
    @stream_preview  = nil

    # The same posture the shell consent reads live (issue #274): a lambda, so a
    # /yolo at the idle prompt or a mid-turn flip applies to the very next tool
    # call and switching it off removes the coverage at once. FileList never
    # stores a grant from it, so a resume cannot turn it into a standing grant.
    @file_list.posture      = -> { @settings.yolo? }
    @file_list.audit_logger = @logger

    # The blob store for tool-result images (issue #449): the harness' own
    # content dir under THIS session's id, so a path a saved session names still
    # resolves when that session is resumed.
    @image_store = ImageStore.new(
      @file_list.workdir, dir: image_content_dir(@session.session_id))

    # The rate of the request that last completed, for the spinner's "recent"
    # segment (issue #285). nil until a request of THIS process has finished;
    # a resumed session seeds it from its saved per-request performance when
    # the server measured one.
    @last_rate = nil

    apply_resume_state(resume_data) if resume_data
  end

  # The rules file read is a read boundary like every other (issue #341): the
  # result is the FIRST message of every chain, and a raw File.read of a file the
  # model is invited to edit raised in .strip - at startup, and again on the next
  # prompt through SessionManager#check_rules_reload.
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

  # EVERY request - the live turn and both advisory forks - must send THIS same
  # payload: a chat template renders the tools into the prompt, so a fork that
  # omits them is a different prompt, not a longer one (#246,
  # doc/compaction_cache_design.md).
  def tools_payload
    tool_registry.empty? ? nil : tool_registry.to_openai
  end

  def compact_recent_messages
    settings.compact_recent || Session::COMPACT_RECENT_MESSAGES
  end

  def compact_auto_threshold
    settings.compact_auto_threshold || Session::AUTO_COMPACT_THRESHOLD
  end

  # The summary call itself needs headroom, so a small window compacts
  # proportionally earlier. nil/0 = percentage trigger only.
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

  # -- Tool-result images (issue #449) --------------------------------------
  #
  # Built per TURN: the inline budget it carries is turn-scoped and must not
  # leak into the next turn. Whether the model may see images at all is a
  # PROFILE fact (SessionManager#vision?), so a /model switch between a vision
  # profile and a text profile changes what the NEXT tool result does with its
  # image - the harness never guesses that an unconfigured model can see.
  def image_delivery
    limits = @session_manager.image_limits
    ImageDelivery.new(
      vision: vision?,
      store: @image_store,
      max_inline_bytes: limits[:inline_max_bytes],
      max_inline_images: limits[:inline_max_images],
      max_inline_tokens: limits[:inline_max_tokens])
  end

  # True when the ACTIVE model may be sent images (startup banner, /model,
  # the delivery decision).
  def vision?
    @session_manager.vision?
  end

  # Workdir-relative blob dir for one session id.
  def image_content_dir(session_id)
    base = settings.mcp_images_dir || ImageStore::DEFAULT_DIR
    File.join(base, session_id.to_s)
  end

  # The live tail of the answer currently streaming, for the spinner suffix.
  # nil when nothing has arrived yet (prefill) or when not streaming - the
  # caller then shows the waiting line (context + the last request's rate,
  # see #request_wait_suffix).
  # THREADING: written by the task thread (the on_delta callback) and read by
  # the main thread (the spinner's per-frame suffix call); StreamPreview
  # publishes one frozen group so the reader never sees a partial append.
  def stream_preview_line
    @stream_preview&.tail_line
  end

  # The spinner suffix for the wait this request owns (issue #285):
  #   while a streamed answer is arriving  "<newest text> ~38 tok/s"
  #   before that (prefill) or when buffered  "🧠 12% (160K) 31 tok/s (last)"
  #   while a streamed TOOL CALL is being written  "writing tool call: file.write
  #   🧠 12% (160K)" - no rate, and the (frozen) tail is not shown either
  #   (issue #368).
  # The live rate is '~' because its tokens are ESTIMATED from the stream's
  # characters; the "(last)" rate is the previous request's own measurement,
  # '~' only when the server did not measure it. Neither is ever shown for the
  # request it describes as if it were that request's number.
  def request_wait_suffix
    -> { streaming_wait_line || waiting_line }
  end

  # The spinner suffix for a TOOL wait (issue #362): the live context estimate
  # and NO rate segment - no request is in flight while a tool runs, so there is
  # no speed to show. CommandRunner's own re-point reads it through this one
  # place: a :spinner_detail payload with no suffix key would silently drop the
  # suffix from the runner's remembered detail, so every tool wait carries it.
  def tool_wait_suffix
    -> { context_indicator_live }
  end

  # The rate shown for the wait BEFORE the answer's text starts (prefill, or a
  # buffered request): the request that last completed. nil when this process
  # has not finished one yet - a spinner must not invent a speed.
  # pad: the width-stable number for the SPINNER (issue #364). A log line that
  # names the same rate reads it without padding - prose does not need a column.
  def last_rate_segment(pad: false)
    return nil if @last_rate.nil?

    LLM::UsageStats.rate_segment(
      @last_rate[:rate],
      measured_by_server: @last_rate[:server],
      tag: "last",
      pad:
    )
  end

  # Called after each completed request with that request's usage and its own
  # elapsed seconds: the server's number is preferred over the harness's wall
  # clock. A request that supports no rate at all keeps the previous measurement
  # rather than blanking the segment (the "(last)" tag is what says the number
  # is not the request in flight's).
  def record_last_rate(usage, seconds)
    rate = LLM::UsageStats.recent_generation_rate(usage, seconds)
    @last_rate = rate if rate
  end

  # A model switch changes the server a rate was measured against, so the
  # previous one no longer describes anything this run will do.
  def forget_last_rate
    @last_rate = nil
  end

  # ONE check call per tool batch (never one per command). SafetyCheck
  # never touches Session, so it cannot trigger in-loop compaction.
  def precheck_batch_safety(message_calls)
    return nil unless @settings.command_safety_check

    # YOLO's auto-approval branch in CommandRunner#run returns before
    # safety_verdict_for is reached, so a batch check here would pay for a
    # forked round trip whose verdicts can only be thrown away (#238's cost).
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

  # Returns [args, nil] or [{}, error_message]: rescuing straight to {} erased
  # the difference between "no arguments sent" and "this call lost its shape".
  def parse_tool_arguments(raw)
    return [{}, nil] if raw.nil? || raw.to_s.strip.empty?

    [JSON.parse(raw), nil]
  rescue JSON::ParserError => e
    [{}, e.message]
  rescue StandardError => e
    [{}, ErrorText.label(e)]
  end

  # Returns true only for 'length' - the reason that makes the tool round below
  # report truncation rather than a malformed call.
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

  # The OpenAI endpoint reads max_tokens, the native one num_predict; an unset
  # key means the SERVER's own default is what cut the answer.
  def budget_note(data)
    limit = [model_config.max_tokens, model_config.num_predict].map(&:to_i).find(&:positive?)
    parts = []
    completion = data.dig(:usage, :completion_tokens)
    parts << "#{completion} completion tokens" if completion
    parts << (limit ? "limit #{limit}" : "no token limit configured (server default)")
    parts.join(", ")
  end

  # Name a text-shaped tool call the harness could NOT recover on the console +
  # log (issue #461). The parsing lives in TextToolCallParser; a recoverable call
  # is parsed and run in call_llm before this is reached, so this fires only for
  # markers with no resolvable name - the user then sees the model tried to act
  # and can re-prompt.
  def report_unresolved_text_tool_call(content)
    #logger.info "-----text_tool_call-----\n#{content}\n----------------"

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

  # True when content carries a text-shaped call the harness could not run;
  # records it to the log only. The user-facing warn is left to the terminal
  # fallback (report_unresolved_text_tool_call) so the first occurrence can
  # instead be fed back to the model (issue #487).
  def log_unresolved_text_tool_call(content)
    return false unless @text_tool_call_parser.text_call?(content)

    logger.warn "text-shaped tool call in response (issue #461) - NOT executed\n" \
      "-----text_tool_call-----\n#{content}\n----------------"
    true
  end

  # -- LLM call logic -------------------------------------------------------

  # The session IS the working chain: every round is appended AS IT HAPPENS,
  # so a turn that dies mid-loop keeps its rounds and /retry resumes from
  # exactly that point instead of replaying the prompt from zero.
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
    total_usage = { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 }

    # One ImageDelivery per turn: its inline budget is turn-scoped (issue #449).
    # Tool results that carried images append base64 to the WORKING chain only
    # - the token estimate and the compact trigger must see the cost - and the
    # payload is stripped as soon as a request has carried it (see #sent_images).
    delivery = image_delivery

    # The LAST call's prompt_tokens is the context size: each call already
    # carries the history, so summing over counts.
    last_prompt_tokens = 0
    last_performance   = nil
    start_time = Time.now

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

      # Each request announces its own wait, so an earlier re-point (an
      # in-loop compaction) cannot outlive it.
      @session_manager.request_spinner_detail

      data    = request_chain(messages, tools)
      message = data[:choices][0][:message]

      # The image payloads this request carried have been SEEN by the model.
      # Keeping them would re-send the same megabytes in every later request of
      # the turn (issue #449); the text beside them - which names the stored
      # file - is what survives.
      strip_image_payloads(messages)

      # issue #461: no structured tool_calls, but the model may have written one
      # as text. Parse and run it (lenient) so the turn does not silently break;
      # a name that matches no tool stays prose and the round ends as an answer.
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

      # #285: this request's rate is now the RECENT one the spinner can show
      # during the next request's prefill (or in buffered mode). It is taken
      # from the request's own clock and its reported counts, never from
      # stats[:elapsed_seconds] (the TURN's time, tool execution included).
      record_last_rate(data[:usage], @request_seconds)

      # #251: the server-side performance of THIS request only (cache depth,
      # durations, draft counts). The LAST call describes the state the next
      # request will face, so it replaces the earlier ones instead of adding
      # to them - measurements of different requests cannot be summed.
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

        # The model cannot see this harness' token budget, so the cut is named
        # once per round (issue #332: it retried the same shape forever).
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

      # issue #461 / #487: a text-shaped call whose name matched no tool (or an
      # ambiguous short name the harness will not guess). A name that DID resolve
      # was recovered above and ran. For one that did NOT:
      #   - the first time this turn produces it, feed it back so the model can
      #     re-issue it (issue #487 - the model never learned its call failed);
      #   - bounded to ONE retry (text_call_retried), so prose that merely QUOTES
      #     a call cannot spin the loop - the second occurrence falls through to
      #     the honest warn + commit.
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

      elapsed = (Time.now - start_time).round(2)
      stats = {
        elapsed_seconds: elapsed,
        iterations:      iteration,
        usage:           total_usage,
        prompt_tokens:   last_prompt_tokens,
        performance:     last_performance
      }

      @session.add_assistant(message[:content])
      @session.flush_notes
      @session.record_stats(stats)
      @session.record_reasoning(message[:reasoning])

      # A committed chain is text state: no base64 belongs in it or in a
      # session file (issue #449).
      strip_image_payloads(messages)

      return {
        reasoning: message[:reasoning],
        content:   message[:content],
        stats:
      }
    end
  end

  # Turn a tool's raw result into the message that goes into the chain
  # (issue #449). A String result is the ordinary case and passes through
  # untouched. A ToolResult (an MCP server returned image blocks) is handed to
  # this turn's ImageDelivery, which names each image's fate in the text and
  # returns the base64 payloads a vision request may carry.
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

  # Every image decision is logged - inline or not - because "the model cannot
  # see it" is a fact the user needs when the answer looks blind to a screenshot.
  def log_image_decision(tool_name, decisions)
    decisions.each do |d|
      detail = d.inline? ? "inlined" : "#{d.mode} (#{d.reason})"
      logger.info "tool #{tool_name} image: #{d.image.mime_type} #{d.image.byte_size}B -> #{detail}"
    end
  end

  # Drop the base64 payloads from a chain once they have been sent (or the turn
  # has committed). The text that names the stored file stays.
  def strip_image_payloads(messages)
    messages.each { |m| m.delete(:images) }
  end

  # Buffer the note fact so it survives the transient tool result and reaches
  # the chain on the turn commit.
  def record_note(tool_call, result)
    return unless tool_call[:function][:name] == "ui.note"
    return unless result.is_a?(String) && result.start_with?("ok: noted")

    args, parse_error = parse_tool_arguments(tool_call[:function][:arguments])
    if parse_error
      logger.warn "ui.note arguments did not parse (#{parse_error}) - note not buffered"
      return
    end
    @session.add_note(args["text"])
  rescue StandardError
    # A malformed note must never break the turn.
  end

  def emit_stats(stats)
    return unless stats

    elapsed = stats[:elapsed_seconds]
    iters   = stats[:iterations]
    usage   = stats[:usage]

    parts = ["⏱ #{format_elapsed(elapsed)}"]
    parts << "🔄 #{iters} iteration#{'s' if iters != 1}"
    if usage && usage[:total_tokens] > 0
      parts << "📊 #{usage[:prompt_tokens]}→#{usage[:completion_tokens]} tokens (#{usage[:total_tokens]} total)"
    end
    perf = LLM::UsageStats.performance_parts(stats[:performance])
    parts << "⚡ #{perf.join(' | ')}" unless perf.empty?

    ctx = context_indicator
    parts << ctx if ctx

    Task.emit(:stats, origin: :harness, content: "  [#{parts.join(' | ')}]")
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

  # Unlike #context_indicator (the LAST response's number), this measures the
  # CURRENT chain, including mid-turn tool results. An explicit messages:
  # chain (in-loop compaction's local chain) is always an estimate.
  #
  # This one is the SPINNER's context segment, so it is the glanceable form
  # (issue #271): the percentage, plus the window it is a percentage of. The
  # raw token arithmetic stays in #context_indicator (modeline, stats line)
  # and in the /ctx report.
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

  # The context facts as DATA (issue #474, increment 21): the arithmetic that
  # decides a compaction stays here, and the row shape belongs to UI::Renderer, so
  # /ctx states these fields rather than baking a padded value column. nil when
  # there is nothing to measure yet (the command then answers with the prose note).
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

  # Thin delegators to the Mcp::Manager (issue #48). The CLI calls close_mcp on
  # shutdown and reads mcp_status_notes for the banner; the machinery itself
  # lives in Mcp::Manager, not here.
  def close_mcp
    @mcp.close
  end

  def mcp_status_notes
    @mcp.status_notes
  end

  # issue #405: what THIS run connected, for the saved session. The saved run's
  # own servers are what the conversation had tools from, so the summary is read
  # at save time from the live Manager rather than tracked separately.
  def mcp_connected_summary
    @mcp.connected_summary
  end

  # The conversation's size gate (issue #551): a tool result that would make the
  # NEXT request exceed the backend's context window is refused by that backend
  # outright ("requests are never truncated"), and the auto-compact retry then
  # fails on the same oversized chain. So the cap is applied HERE, before the
  # result becomes a message; the full text goes to the session's own dir so
  # nothing is invented about what the command printed. A ToolResult is left to
  # ImageDelivery (its bytes are images, not text). doc/tool_output_budget_design.md.
  def budget_tool_result(name, result)
    return result if result.is_a?(ToolResult)

    # A spill read came back already capped and is exempt: re-fitting it would
    # spill the spill and log a cap the model never received.
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

  # A spilled result is harness state the file tools cannot open (a session dir is
  # blocked for every component), so the tool that spilled answers a read of its
  # own spill file - capped, so reading the overflow back cannot overflow again.
  # nil when the path names no spill of this job.
  def read_spilled_result(path)
    rel = @file_list.relative_path(@file_list.resolve(path))
    return nil unless rel && result_spill.covers?(rel)

    # read_capped so an oversized spill is never loaded whole; the mark tells
    # budget_tool_result this text is already inside the byte budget.
    ResultSpill::ALREADY_CAPPED_MARK +
      OutputBudget.read_capped(@file_list.resolve(path), limit: output_result_bytes)[0]
  rescue SystemCallError => e
    "error: cannot read #{path} (#{e.message})"
  end

  # The mark a spill read carries (FileReadTool#read_spilled sets it): the text
  # with the mark stripped, or nil when this result is not one.
  def spill_read_result?(name, result)
    return nil unless name == "file.read" && result.is_a?(String)
    return nil unless result.start_with?(ResultSpill::ALREADY_CAPPED_MARK)

    result[ResultSpill::ALREADY_CAPPED_MARK.length..]
  end

  def output_result_bytes
    settings.output_result_bytes || OutputBudget::DEFAULT_RESULT_BYTES
  end

  # The session dir is harness state, so the spill path is named as such: the
  # model tells the USER where the full output is instead of trying to read it.
  def result_spill
    return @result_spill if defined?(@result_spill)

    @result_spill = ResultSpill.new(@locator, @session.session_id,
                                    job_id: @session_manager.job_id)
  end

  private

  # One LLM request. The streaming posture applies to THIS request only, so a
  # streamed turn publishes its live tail for the spinner. The preview is
  # cleared in the ensure, not after the call: a request that died mid-stream
  # must not leave its partial tail for the NEXT request to show. Posture
  # ownership and the retry boundary: doc/streaming_design.md.
  def request_chain(messages, tools)
    streaming = @settings.stream?
    # The estimate ratio is injected, not fixed here: the token estimate the
    # spinner's rate and the context indicator both need belongs to Session.
    preview = streaming ? LLM::StreamPreview.new(
      chars_per_token: Session::EST_CHARS_PER_TOKEN
    ) : nil
    @stream_preview = preview
    # The callback holds THIS request's object, not the ivar: the ivar is the
    # main thread's reader handle and the ensure below clears it, so a delta
    # that arrives after a clear would call record on nil (issue #378).
    on_delta = preview ? ->(delta) { preview.record(delta) } : nil

    # The request's OWN clock: stats[:elapsed_seconds] is the TURN's (tool
    # execution included), so it can never serve as a request's speed.
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      @client.chat(messages, tools:, stream: streaming, on_delta:)
    ensure
      @request_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      @stream_preview = nil
    end
  end

  # The tool-call segment plus the live context estimate, and NO rate: with no
  # text arriving there is nothing to measure, and a rate computed over an
  # arriving-nothing window decays frame by frame (9.0 -> 4.5 -> 2.2, measured),
  # which is the exact "connection is dying" reading this segment exists to
  # replace. The context estimate is the live part that stays on the line.
  def tool_phase_line(phase)
    [phase, context_indicator_live].compact.join(" ")
  end

  # The streaming segment of the spinner suffix, or nil while nothing has
  # arrived so the waiting line applies instead. A tool call being written
  # REPLACES the tail: while the model writes one, no text is arriving, so the
  # tail has stopped moving and a line built on it reads as a frozen connection
  # (issue #368).
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

  # The wait before an answer's text starts (prefill, or a buffered request): the
  # live context estimate, plus the last request's rate when this process has one
  # to show. nil when NEITHER has anything (no conversation yet and no completed
  # request) - the spinner's contract is "no suffix", not an empty segment.
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
    # One ROLE per event (issue #146): the old single :step type carried the
    # label, the reasoning digest, the interstitial and the tool list, with the
    # pattern baked into each string - a renderer could not tell them apart
    # without regexing the markers back out. The number is emitted here, the
    # word "step" belongs to UI::Renderer.
    Task.emit(:step_label, origin: :harness, content: iteration)
    Task.emit(:plan, origin: :harness, content: reason) if reason
    Task.emit(:interstitial, origin: :harness, content:) if content
    Task.emit(:tool_plan, origin: :harness, content: tools.join(", "))
  end

  def step_display_disabled?
    ENV.fetch("HARNESS_STEP_DISPLAY", "") == "off" || settings.step_display == false
  end

  # A prompt file is the FIRST message of every chain this harness will ever send
  # or save, so it is a read boundary: an unnormalized one survives until
  # JSON.generate (the request body AND the session save) raises on its bytes.
  def read_system_prompt
    path = settings.system_file
    return TextNormalizer.normalize(File.read(path)) if path && File.file?(path)

    TextNormalizer.normalize(File.read(DEFAULT_SYSTEM_PROMPT_FILE))
  end

  # Names what a rules-file read had to replace, so the repair is not silent: the
  # prompt the model got is then NOT byte-for-byte what harness.md holds. Counts
  # bytes (the assertion is about bytes, the #318 rule); nil when the file read
  # as UTF-8 cleanly.
  def byte_repair_note(source)
    return nil if source.valid_encoding?

    bad = source.each_char.count { |c| !c.valid_encoding? }
    return nil if bad.zero?

    label = bad == 1 ? "1 invalid byte" : "#{bad} invalid bytes"
    "#{label} replaced - harness.md is not valid UTF-8"
  end

  # 65536 -> "66K", 160000 -> "160K", 1000 -> "1K". A window size is only
  # ever read as an order of magnitude, and five digits of it is noise in a
  # per-frame line; windows under 1000 stay exact.
  def window_label(window)
    w = window.to_i
    w < 1000 ? w.to_s : "#{(w / 1000.0).round}K"
  end

  # Re-points the spinner for ONE tool execution (issue #362). A tool that waits
  # (a slow command, a consent dialog, a model safety check) leaves the outbox
  # quiet, so the drain loop animates - and the detail it replays is the LLM
  # request that already finished, so a long run.command reads as if the model
  # were still generating. The message is the tool NAME only: the spinner appends
  # its own "..." to every message, so a marker here would double the dots.
  def announce_tool_call(name)
    Task.emit(
      :spinner_detail,
      origin: :harness,
      content: { message: name, suffix: tool_wait_suffix })
  end

  # truncated: the request that produced this call was cut by the token budget.
  # A parse failure is then reported as truncation - the honest cause - instead
  # of a malformed call the model is invited to repeat.
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
      # A byte invalid in UTF-8 would make the NEXT JSON.generate raise -
      # including the save that should record the failure.
      # A ToolResult is normalized where its text is built (ToolResult#new) and
      # carries raw image bytes beside it - normalizing the OBJECT would flatten
      # it to its #to_s and lose the images (issue #449).
      text = result.is_a?(ToolResult) ? result : TextNormalizer.normalize(result)
      budget_tool_result(func_name, text)
    rescue => e
      logger.error ErrorText.detailed(e, "tool #{func_name} failed")
      "error: #{ErrorText.label(e)}"
    end
  end

  # Not conversation state, so Session#restore cannot apply it.
  def apply_resume_state(data)
    @session_manager.restore_session_model(data[:active_model])
    @session_manager.param_overrides.load(data[:param_overrides])
    @session_manager.param_overrides.restore!

    # The four session-persisted postures (yolo/stream/markdown/palette) are
    # applied over the resolved settings by SystemSettings#restore_persisted;
    # a key the session does not carry keeps its config value (a session saved
    # before the posture existed falls back to the default, #28/#106/#303).
    @settings.restore_persisted(data)
    logger.info "yolo posture restored: #{@settings.yolo? ? 'ON' : 'OFF'}"
    logger.info "streaming posture restored: #{@settings.stream? ? 'ON' : 'OFF'}"
    logger.info "markdown posture restored: #{@settings.markdown? ? 'ON' : 'OFF'}"

    # #285: the saved per-request performance (#251) is a server measurement, so
    # a resumed session can show a recent rate immediately - a client-timed one
    # would need seconds it does not have, hence nil there.
    saved_rate = LLM::UsageStats.recent_generation_rate(data.dig(:last_stats, :performance), nil)
    @last_rate = saved_rate if saved_rate
    logger.info "recent generation rate restored: #{last_rate_segment}" if saved_rate

    logger.info "output palette restored: #{@settings.output_palette.name}"

    # issue #405: the saved session names the MCP tools its conversation had.
    # THIS run already connected what its own config declared (the tool-registry
    # builder runs before this), so the two can be compared: a server the saved
    # conversation used that this run cannot reach is stated out loud rather than
    # left as a tool set the model quietly lost. The notes land in the startup
    # banner next to the run's own MCP lines.
    # A session saved before #405 has no key at all, which reads as nothing to
    # compare - the run's own banner is then the whole story.
    @mcp.report_saved_session(data[:mcp_connected])
  end
end
