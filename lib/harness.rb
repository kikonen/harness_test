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
require_relative "turn_runner"
require_relative "turn_mailbox"
require_relative "turn_stats"
require_relative "request_log"
require_relative "tool_call_runner"
require_relative "tool_call_ports"
require_relative "turn_context"
require_relative "context_lines"

require_relative "text_tool_call_parser"
# -- Harness --------------------------------------------------------------

class Harness
  DEFAULT_SYSTEM_PROMPT_FILE = File.expand_path("../config/system_prompt.txt", __dir__)

  HARNESS_DIR = ".harness"

  SESSION_LOG_FILE = SessionLocator::SESSION_LOG_FILE

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
    :locator,
    :session,
    :session_manager,
    :client,
    :rules_repair_note,
    :mcp,
    :image_store,
    :text_tool_call_parser,
    :tool_call_runner,
    :tool_call_ports,
    :turn_stats,
    :request_log,
    :context_lines

  attr_accessor :history

  # The note/save mailbox is its own collaborator (issue #582): the main thread
  # writes it, the job's own thread reads it, and the turn consumes it - none
  # of them reaches into Harness to do that.
  def mailbox
    @mailbox
  end

  def request_save        = @mailbox.request_save
  def save_requested?     = @mailbox.save_requested?

  def user_note_text=(text)
    @mailbox.user_note_text = text
  end

  def discard_pending_user_note(kind)
    @mailbox.discard_pending_user_note(kind)
  end

  def initialize(
    file_list,
    settings:,
    locator:,
    logger:,
    resume_data: nil
  )
    @file_list = file_list
    @settings  = settings
    @locator   = locator

    # One shared cache for Session and the tool registry: a digest a tool
    # records must be the one a later write is checked against.
    @file_cache = SessionFileCache.new

    @logger = logger
    @session = Session.new(build_system_prompt, file_cache: @file_cache)

    @session.restore(resume_data, @file_list) if resume_data

    @mailbox = TurnMailbox.new(@logger)
    StateMigrator.run(@file_list.workdir, HARNESS_DIR)

    @sandbox_gemfile = SandboxGemfile.new(@file_list.workdir).setup!(@logger)

    builder = ToolRegistryBuilder.new(
      file_list: @file_list,
      file_cache: @file_cache,
      settings: @settings,
      logger: @logger,
      locator: @locator,
      # A spill belongs to the job running NOW, so the reader resolves it live.
      result_spill: -> { result_spill },
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

    # A live lambda so a mid-turn /yolo flip applies to the next call and off
    # removes coverage at once; never stored, so a resume can't persist it.
    @file_list.posture      = -> { @settings.yolo? }
    @file_list.audit_logger = @logger

    # A dir under this session id, so a saved path still resolves on resume.
    @image_store = ImageStore.new(
      @file_list.workdir,
      dir: @locator.image_content_dir(settings.mcp_images_dir || ImageStore::DEFAULT_DIR))

    # The tool-call half of a turn (issue #582): it sees the ports below and
    # never reads back into Harness.
    @tool_call_runner = ToolCallRunner.new
    @tool_call_ports  = build_tool_call_ports

    # The last completed request's rate lives here, for the spinner; nil until
    # one finishes. The turn's stats bookkeeping and its per-request plumbing
    # are Harness-owned objects the turn is handed (issue #582).
    @context_lines = ContextLines.new(
      session: @session,
      window_source: -> { model_config.num_ctx || LLMClient::NUM_CTX }
    )
    @turn_stats = TurnStats.new(-> { @session_manager.job_id })
    @request_log = RequestLog.new(client_source: -> { @client },
                                  tools_source: -> { tools_payload },
                                  settings: @settings,
                                  context_lines: @context_lines)

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

  # Same payload for every request: omitting tools makes a different prompt.
  def tools_payload
    tool_registry.empty? ? nil : tool_registry.to_openai
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

  # A live rate is '~' (estimated from stream chars); a "(last)" rate is the
  # previous request's own measurement, never the in-flight request's number.
  def request_wait_suffix
    -> { @request_log.wait_line(->(pad: false) { last_rate_segment(pad:) }) }
  end

  # A tool wait carries NO rate: nothing is in flight, so there is no speed.
  def tool_wait_suffix
    -> { @request_log.tool_wait_line }
  end

  # pad gives the spinner a width-stable number; a log line reads it unpadded.
  def last_rate_segment(pad: false)
    @turn_stats.rate_segment(pad:)
  end

  def record_last_rate(usage, seconds)
    @turn_stats.record_rate(usage, seconds)
  end

  # A model switch changes the server, so the old rate describes nothing here.
  def forget_last_rate
    @turn_stats.forget_rate
  end

  # THE single auto-compact trigger for every consumer (SessionManager, /ctx).
  def compact_trigger_tokens
    window = model_config.num_ctx || LLMClient::NUM_CTX
    return nil if window.to_i <= 0

    @session.compact_trigger(
      window,
      settings.compact_auto_threshold,
      reserved_tokens: settings.compact_reserved_tokens)
  end

  # Each round is appended as it happens, so a turn that dies mid-loop keeps its
  # rounds and /retry resumes from that point, not from the prompt.
  # The turn engine entry: hand this turn its context and let the runner loop.
  # The loop state lives in TurnRunner and everything it may touch is in the
  # TurnContext (issue #582), so the loop never names Harness.
  # notes: optional caller-owned list; the turn's injected notes land in it.
  def call_llm(notes: [])
    TurnRunner.new(build_turn_context).run(notes)
  end

  # The one place that reads Harness ivars for a turn (issue #582): the turn is
  # handed the collaborator objects, not this object.
  def build_turn_context
    TurnContext.new(
      session: @session,
      session_manager: @session_manager,
      logger: @logger,
      tool_calls: @tool_call_runner,
      ports: @tool_call_ports,
      delivery: image_delivery,
      max_tool_iterations: @settings.max_tool_iterations,
      mailbox: @mailbox,
      turn_stats: @turn_stats,
      request_log: @request_log
    )
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

  # The context text is ContextLines' (issue #582); these are the delegators
  # the UI, the stats line and SessionManager already call.
  def context_indicator
    @context_lines.indicator
  end

  def context_indicator_live(messages = nil)
    @context_lines.live(messages)
  end

  def context_usage
    @context_lines.usage(compact_trigger_tokens)
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

  # A spill is harness state: the model tells the user where it is, not reads it.
  def result_spill
    return @result_spill if defined?(@result_spill)

    @result_spill = ResultSpill.new(
      @locator,
      job_id: @session_manager.job_id,
      keep: settings.output_spill_keep || ResultSpill::DEFAULT_KEEP)
  end

  # The narrow view the tool-call half is allowed to see (issue #582). State
  # that changes mid-run arrives as a callable so a port reads the live value.
  def build_tool_call_ports
    ToolCallPorts.new(
      logger: @logger,
      settings: @settings,
      tool_registry: @tool_registry,
      session: @session,
      # A model switch replaces @client; a tool call after it uses the new one.
      client: -> { @client },
      model_config: @model_config,
      file_list: @file_list,
      spill_reader: SpillReader.new(
        file_list: @file_list,
        result_spill: -> { result_spill },
        output_result_bytes: @settings.output_result_bytes ||
          OutputBudget::DEFAULT_RESULT_BYTES),
      result_spill: -> { result_spill },
      text_tool_call_parser: @text_tool_call_parser,
      tool_wait_suffix:,
    )
  end

  # The CLI reads an aborted turn through the TurnStats object the turn wrote.
  def aborted_turn_stats
    @turn_stats.aborted(@session_manager.job_id)
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
    rate = @turn_stats.restore_rate(data.dig(:last_stats, :performance))
    logger.info "recent generation rate restored: #{last_rate_segment}" if rate

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
