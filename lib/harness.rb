# frozen_string_literal: true

require "json"
require "logger"
require "time"
require "thread"
require "digest"
require "fileutils"

require_relative "harness_error"
require_relative "ui"
require_relative "tool"
require_relative "llm_client"
require_relative "file_list"
require_relative "session"
require_relative "memories"
require_relative "session_locator"
require_relative "task"
require_relative "llm/stream_preview"
require_relative "llm/usage_stats"
require_relative "tools/echo_tool"
require_relative "tools/notify_tool"
require_relative "tools/dialog_tool"
require_relative "tools/get_time_tool"
require_relative "tools/file_read_tool"
require_relative "tools/file_write_tool"
require_relative "tools/file_rename_tool"
require_relative "tools/file_delete_tool"
require_relative "tools/file_list_tool"
require_relative "tools/file_search_tool"
require_relative "tools/file_patch_tool"
require_relative "tools/file_copy_tool"
require_relative "tools/file_info_tool"
require_relative "tools/note_tool"
require_relative "tools/dir_create_tool"
require_relative "tools/dir_delete_tool"
require_relative "tools/git_diff_tool"
require_relative "tools/git_show_tool"
require_relative "tools/git_status_tool"
require_relative "tools/git_log_tool"
require_relative "tools/git_grep_tool"
require_relative "tools/git_apply_tool"
require_relative "tools/run_command_tool"
require_relative "tools/tools_list_tool"
require_relative "tools/tools_search_tool"
require_relative "skills"
require_relative "tools/skills_list_tool"
require_relative "tools/skills_read_tool"
require_relative "tool_registry"
require_relative "tools/memory_list_tool"
require_relative "tools/memory_read_tool"
require_relative "tools/memory_add_tool"
require_relative "tools/memory_delete_tool"
require_relative "session_manager"
require_relative "state_migrator"
require_relative "safety_check"
require_relative "text_normalizer"

# -- Harness --------------------------------------------------------------

class Harness
  DEFAULT_SYSTEM_PROMPT_FILE = File.expand_path("../config/system_prompt.txt", __dir__)

  MAX_TOOL_ITERATIONS = 200
  # Consecutive-call thresholds: warn (inject a stop message), then break.
  TOOL_LOOP_WARN_THRESHOLD = 10
  # After this many consecutive tool-call iterations, force-break and return whatever we have
  TOOL_LOOP_HARD_LIMIT = 20

  HARNESS_DIR = ".harness"

  SESSION_LOG_FILE = SessionLocator::SESSION_LOG_FILE

  # rules_repair_note: what the LAST rules-file read had to replace (nil when the
  # file was clean). A repair must not be silent - the prompt the model was given
  # is then not byte-for-byte what harness.md holds.
  attr_reader :options, :logger, :tool_registry, :file_list, :session, :session_manager,
              :client, :skills, :memories, :rules_repair_note
  attr_accessor :history

  # Only one note is in flight: a new assignment replaces the note that has
  # not been injected yet - the latest line wins.
  def user_note_text=(text)
    @user_note = text.to_s.strip.empty? ? nil : text.to_s.strip
  end

  def user_notes
    @user_notes
  end

  def initialize(options, file_list, session_id: nil, resume_data: nil)
    @options       = options
    @file_list     = file_list
    @locator       = SessionLocator.new(file_list.workdir)
    @skills        = Skills.new(file_list.workdir)
    # The project's durable notes (issue #10): one reader for the store, shared by
    # memory.* and /memory so the two sides cannot drift.
    @memories      = Memories.new(file_list.workdir)
    @session       = Session.new(build_system_prompt, session_id:)
    if resume_data
      saved_id = resume_data[:session_id]
      if saved_id && saved_id != session_id
        raise HarnessError,
              "session file says id #{saved_id} but it is stored under #{session_id}"
      end
      @session.restore(resume_data, @file_list)
    end
    @user_note     = nil
    @user_notes    = []
    StateMigrator.run(@file_list.workdir, HARNESS_DIR)
    @logger        = build_logger
    @tool_registry = build_tool_registry
    @client        = LLMClient.new(options, @logger)
    @session_manager = SessionManager.new(self, file_list)
    @command_safety_auto_approve = options[:command_safety_auto_approve] == true
    @yolo = options[:yolo] == true
    self.output_palette = options[:output_palette]
    # Streaming posture (issue #28): the initial value comes from the config
    # (global key or a profile's own key); /stream switches it for the rest of
    # the session. Read per request, so a mid-turn toggle applies to the next.
    @stream = options[:stream] == true
    @stream_preview = nil
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
    @logger&.info("harness.md read: #{@rules_repair_note}") if @rules_repair_note
    return base if content.empty?

    "#{base}\n\n## Project-Specific Rules\n\n#{content}\n"
  end

  def session_log_path
    @locator.session_log_path(@session.session_id)
  end

  def build_logger
    log_file = session_log_path
    FileUtils.mkdir_p(File.dirname(log_file))
    logger = Logger.new(log_file)
    logger.formatter = proc { |severity, datetime, _progname, msg|
      "#{datetime.strftime('%Y-%m-%d %H:%M:%S')} [#{severity}] #{msg}\n"
    }
    logger
  end

  def build_tool_registry
    registry = ToolRegistry.new
    registry.register(Tools::EchoTool.new)
    registry.register(Tools::NotifyTool.new)
    registry.register(Tools::DialogTool.new)
    registry.register(Tools::GetTimeTool.new)
    registry.register(Tools::FileListTool.new(@file_list))
    registry.register(Tools::FileReadTool.new(@file_list, @session))
    registry.register(Tools::FileWriteTool.new(@file_list, @session))
    registry.register(Tools::FileRenameTool.new(@file_list, @session))
    registry.register(Tools::FileDeleteTool.new(@file_list, @session))
    registry.register(Tools::FileSearchTool.new(@file_list))
    registry.register(Tools::FilePatchTool.new(@file_list, @session))
    registry.register(Tools::FileCopyTool.new(@file_list))
    registry.register(Tools::FileInfoTool.new(@file_list))
    registry.register(Tools::DirCreateTool.new(@file_list))
    registry.register(Tools::DirDeleteTool.new(
      @file_list,
      session: @session,
      harness: self
    ))
    registry.register(Tools::NoteTool.new)
    registry.register(Tools::GitDiffTool.new(@file_list))
    registry.register(Tools::GitShowTool.new(@file_list))
    registry.register(Tools::GitStatusTool.new(@file_list))
    registry.register(Tools::GitLogTool.new(@file_list))
    registry.register(Tools::GitGrepTool.new(@file_list))
    registry.register(Tools::GitApplyTool.new(@file_list, @session))
    registry.register(Tools::RunCommandTool.new(@file_list, @options,
                                                harness: self))
    registry.register(Tools::ToolsListTool.new(registry))
    registry.register(Tools::ToolsSearchTool.new(registry))
    registry.register(Tools::SkillsListTool.new(@skills))
    registry.register(Tools::SkillsReadTool.new(@skills))
    registry.register(Tools::MemoryListTool.new(@memories))
    registry.register(Tools::MemoryReadTool.new(@memories))
    registry.register(Tools::MemoryAddTool.new(@memories))
    registry.register(Tools::MemoryDeleteTool.new(@memories))
  end

  def compact_recent_messages
    options[:compact_recent] || Session::COMPACT_RECENT_MESSAGES
  end

  def compact_auto_threshold
    options[:compact_auto_threshold] || Session::AUTO_COMPACT_THRESHOLD
  end

  # The summary call itself needs headroom, so a small window compacts
  # proportionally earlier. nil/0 = percentage trigger only.
  def compact_reserved_tokens
    options[:compact_reserved] || Session::COMPACT_RESERVED_TOKENS
  end

  def compact_max_size
    options[:compact_max_size]
  end

  def max_tool_iterations
    options[:max_tool_iterations] || MAX_TOOL_ITERATIONS
  end

  # The rendered-output palette for this run (issue #303). Always a
  # UI::Palette: an absent option resolves to the default one, and 'none'
  # paints nothing.
  def output_palette
    @output_palette
  end

  # /palette switches it mid-session. Resolved and validated HERE, not in the
  # command, so every route (CLI flag, config key, /palette, resume) goes
  # through the same name check. options keeps the name so a later rebuild of
  # the Harness (a mid-run /resume) reproduces the choice.
  def output_palette=(name)
    palette = UI::Palette.fetch(name)
    @output_palette = palette
    options[:output_palette] = palette.name
  end

  def command_safety_check
    options[:command_safety_check] == true
  end

  def command_safety_auto_approve
    @command_safety_auto_approve
  end

  def command_safety_auto_approve=(val)
    @command_safety_auto_approve = (val == true)
  end

  def command_safety_auto_approve_effective?
    command_safety_check && command_safety_auto_approve
  end

  def yolo?
    @yolo
  end

  def yolo=(val)
    @yolo = (val == true)
  end

  def toggle_yolo
    @yolo = !@yolo
    yolo_mode_label
  end

  def command_mode_label
    return "YOLO" if @yolo
    return "AUTO-APPROVE" if command_safety_auto_approve_effective?

    "MANUAL"
  end

  def yolo_mode_label
    @yolo ? "YOLO ON" : "YOLO OFF"
  end

  # -- Streaming posture (issue #28) -----------------------------------------

  def stream?
    @stream
  end

  def stream=(val)
    @stream = (val == true)
  end

  def toggle_stream
    @stream = !@stream
    stream_mode_label
  end

  # Badge label only when streaming is ON: the badge names a NON-default
  # posture (the same rule as YOLO / AUTO-APPROVE), and buffered is the
  # default. /stream status reports the off state.
  def stream_mode_label
    @stream ? "STREAM" : nil
  end

  # The live tail of the answer currently streaming, for the spinner suffix.
  # nil when nothing has arrived yet (prefill) or when not streaming - the
  # caller then shows the waiting line (context + the last request's rate,
  # see #request_wait_suffix).
  # THREADING: written by the task thread (the on_delta callback) and read by
  # the main thread (the spinner's per-frame suffix call); StreamPreview
  # publishes frozen snapshots so the reader never sees a partial append.
  def stream_preview_line
    @stream_preview&.tail_line
  end

  # The spinner suffix for the wait this request owns (issue #285):
  #   while a streamed answer is arriving  "<newest text> ~38 tok/s"
  #   before that (prefill) or when buffered  "🧠 12% (160K) 31 tok/s (last)"
  # The live rate is '~' because its tokens are ESTIMATED from the stream's
  # characters; the "(last)" rate is the previous request's own measurement,
  # '~' only when the server did not measure it. Neither is ever shown for the
  # request it describes as if it were that request's number.
  def request_wait_suffix
    -> { streaming_wait_line || waiting_line }
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

  def toggle_command_mode
    return nil unless command_safety_check

    @command_safety_auto_approve = !@command_safety_auto_approve
    command_safety_auto_approve ? "AUTO-APPROVE" : "MANUAL"
  end

  # ONE check call per tool batch (never one per command). SafetyCheck
  # never touches Session, so it cannot trigger in-loop compaction.
  def precheck_batch_safety(message_calls)
    return nil unless command_safety_check

    commands = run_command_batch_commands(message_calls)
    return nil if commands.size < 2
    unapproved = commands.reject { |c| tool_allowlist.allowed?(c) }
    return nil if unapproved.size < 2
    skipped = commands.size - unapproved.size
    logger.info("safety pre-check: #{skipped} allowlisted command(s) skipped") if skipped.positive?

    logger.info("safety pre-check (#{unapproved.size} run.command in batch)")
    Tool.push_status(label: "safety", verdict: :info,
                     message: "checking #{unapproved.size} commands before the consent dialog...")
    Task.emit(:spinner_detail, origin: :harness,
              content: { message: "Model safety check (#{unapproved.size} commands)" })
    options[:safety_verdicts] =
      SafetyCheck.run(client, session.messages, unapproved)
  rescue StandardError => e
    logger.info("safety pre-check failed (#{e.class}: #{e.message}) - continuing without verdicts")
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

      JSON.parse(tc.dig(:function, :arguments).to_s) rescue {}
    end.map { |a| a["command"].to_s }.reject(&:empty?)
  end

  # THE single auto-compact trigger for every consumer (SessionManager, /ctx).
  def compact_trigger_tokens
    window = options[:num_ctx] || LLMClient::NUM_CTX
    return nil if window.to_i <= 0

    @session.compact_trigger(window, compact_auto_threshold,
                             reserved_tokens: compact_reserved_tokens)
  end

  # -- LLM call logic -------------------------------------------------------

  # The session IS the working chain: every round is appended AS IT HAPPENS,
  # so a turn that dies mid-loop keeps its rounds and /retry resumes from
  # exactly that point instead of replaying the prompt from zero.
  def call_llm
    messages = @session.messages

    @user_notes = []
    tools = tool_registry.empty? ? nil : tool_registry.to_openai

    iteration = 0
    consecutive_tool_calls = 0
    last_tool_name = nil
    loop_warning_injected = false
    loop_hard_break = false
    total_usage = { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 }
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
        logger.info("user mid-turn note injected: #{note}")
        messages << { role: "user", content: "User note (mid-turn): #{note}" }
        Tool.push_status(label: "note", verdict: :info, message: "sent to model")
      end

      # Each request announces its own wait, so an earlier re-point (an
      # in-loop compaction) cannot outlive it.
      @session_manager.request_spinner_detail

      data    = request_chain(messages, tools)
      message = data[:choices][0][:message]

      print_step_display(iteration, message) if message[:tool_calls]

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
          logger.warn("tool-loop hard limit reached (#{consecutive_tool_calls} consecutive calls to '#{current_tool_name}') - forcing final response")
          loop_hard_break = true
        elsif consecutive_tool_calls >= TOOL_LOOP_WARN_THRESHOLD && !loop_warning_injected
          logger.warn("tool-loop warning: #{consecutive_tool_calls} consecutive calls to '#{current_tool_name}' - injecting stop message")
          loop_warning_injected = true
        end

        logger.info("--- tool_calls (iteration #{iteration}, consecutive: #{consecutive_tool_calls}) ---")
        message[:tool_calls].each do |tc|
          logger.info("  calling #{tc[:function][:name]}(#{tc[:function][:arguments]})")
        end

        assistant_msg = { role: "assistant", content: message[:content] }
        assistant_msg[:tool_calls] = message[:tool_calls]
        @session.add_assistant_message(assistant_msg)

        # Single run.command calls check themselves inside CommandRunner.
        precheck_batch_safety(message[:tool_calls])
        message[:tool_calls].each do |tc|
          result = execute_tool_call(tc)
          record_note(tc, result)
          messages << {
            role: "tool",
            tool_call_id: tc[:id],
            content: result
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

      return {
        reasoning: message[:reasoning],
        content:   message[:content],
        stats:
      }
    end
  end

  # Buffer the note fact so it survives the transient tool result and reaches
  # the chain on the turn commit.
  def record_note(tool_call, result)
    return unless tool_call[:function][:name] == "ui.note"
    return unless result.is_a?(String) && result.start_with?("ok: noted")

    args = tool_call[:function][:arguments] ? JSON.parse(tool_call[:function][:arguments]) : {}
    @session.add_note(args["text"])
  rescue StandardError
    # A malformed note must never break the turn.
  end

  def print_stats(stats)
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
    window = options[:num_ctx] || LLMClient::NUM_CTX
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
    window = options[:num_ctx] || LLMClient::NUM_CTX
    if messages
      tokens  = @session.anchored_estimate(messages)
      label   = "~"
    else
      used    = @session.context_used
      return nil if used.nil?
      tokens  = used[:tokens]
      label   = used[:estimated] ? "~" : ""
    end

    pct = (tokens.to_f / window * 100).round
    "🧠 #{label}#{pct}% (#{window_label(window)})"
  end

  def context_report
    window = options[:num_ctx] || LLMClient::NUM_CTX
    used   = @session.context_used
    return "No conversation yet - nothing to measure." if used.nil?

    trigger = compact_trigger_tokens

    pct      = @session.context_pct(window)
    headroom = [window - used[:tokens], 0].max
    due      = trigger && (used[:tokens] >= trigger)

    status = due ? "due" : "not due"
    lines = []
    lines << "🧠 Context usage"
    lines << "  Used:        #{used[:tokens]} tokens (#{pct}% of #{window})"
    lines << "  Source:      #{used[:estimated] ? 'estimate (~4 chars/token)' : 'last LLM response'}"
    lines << "  Headroom:    #{headroom} tokens"
    lines << "  Auto-compact: #{status} (fires at #{trigger} tokens, #{(trigger.to_f / window * 100).round}% of the window)" if trigger
    lines.join("\n")
  end

  private

  # One LLM request. The streaming posture applies to THIS request only, so a
  # streamed turn publishes its live tail for the spinner. The preview is
  # cleared in the ensure, not after the call: a request that died mid-stream
  # must not leave its partial tail for the NEXT request to show. Posture
  # ownership and the retry boundary: doc/streaming_design.md.
  def request_chain(messages, tools)
    streaming = stream?
    # The estimate ratio is injected, not fixed here: the token estimate the
    # spinner's rate and the context indicator both need belongs to Session.
    @stream_preview = streaming ? LLM::StreamPreview.new(
      chars_per_token: Session::EST_CHARS_PER_TOKEN
    ) : nil
    on_delta = @stream_preview ? ->(delta) { @stream_preview.record(delta) } : nil

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

  # The streaming segment of the spinner suffix: the tail plus the rate its own
  # text arrived at, or nil while nothing has arrived so the waiting line applies
  # instead.
  def streaming_wait_line
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

  def print_step_display(iteration, message)
    return if step_display_disabled?

    @session_manager.log_response(reasoning: message[:reasoning], content: message[:content])

    first_line = ->(key) { [message[key]].map { |m| m.to_s.strip }.reject(&:empty?).first }
    reason  = first_line.call(:reasoning)
    content = first_line.call(:content)

    tools  = message[:tool_calls].map { |tc| tc[:function][:name] }
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
    ENV.fetch("HARNESS_STEP_DISPLAY", "") == "off" || options[:step_display] == false
  end

  # A prompt file is the FIRST message of every chain this harness will ever send
  # or save, so it is a read boundary: an unnormalized one survives until
  # JSON.generate (the request body AND the session save) raises on its bytes.
  def read_system_prompt
    path = options[:system_file]
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

  def execute_tool_call(tool_call)
    func_name = tool_call[:function][:name]
    args_json = tool_call[:function][:arguments]
    args      = args_json ? JSON.parse(args_json) : {}

    tool = tool_registry.get(func_name)
    unless tool
      return "error: unknown tool '#{func_name}'"
    end

    begin
      result = tool.execute(args)
      logger.info("tool #{func_name} → #{result}")
      # A byte invalid in UTF-8 would make the NEXT JSON.generate raise -
      # including the save that should record the failure.
      TextNormalizer.normalize(result)
    rescue => e
      logger.error("tool #{func_name} failed: #{e.message}")
      "error: #{e.message}"
    end
  end

  # Not conversation state, so Session#restore cannot apply it.
  def apply_resume_state(data)
    @session_manager.restore_session_model(data[:active_model])
    @session_manager.param_overrides.load(data[:param_overrides])
    @session_manager.param_overrides.restore!
    self.yolo = data[:yolo] == true
    logger.info("yolo posture restored: #{yolo? ? 'ON' : 'OFF'}")
    self.stream = data[:stream] == true
    logger.info("streaming posture restored: #{stream? ? 'ON' : 'OFF'}")
    # #285: the saved per-request performance (#251) is a server measurement, so
    # a resumed session can show a recent rate immediately - a client-timed one
    # would need seconds it does not have, hence nil there.
    saved_rate = LLM::UsageStats.recent_generation_rate(data.dig(:last_stats, :performance), nil)
    @last_rate = saved_rate if saved_rate
    logger.info("recent generation rate restored: #{last_rate_segment}") if saved_rate
    # issue #303: the palette the session was saved with. Unknown names are
    # NOT fatal here (a session saved by another build may name a palette this
    # one does not have) - HarnessConfig/CLI validate a name the user typed,
    # a stored name only has to be usable.
    restored = UI::Palette.names.include?(data[:output_palette].to_s) ? data[:output_palette] : nil
    self.output_palette = restored
    logger.info("output palette restored: #{output_palette.name}")
  end
end
