# frozen_string_literal: true

require 'json'
require 'logger'
require 'time'
require 'thread'
require 'digest'
require 'fileutils'

require_relative 'harness_error'
require_relative 'ui'
require_relative 'tool'
require_relative 'llm_client'
require_relative 'file_list'
require_relative 'session'
require_relative 'task'
require_relative 'tools/echo_tool'
require_relative 'tools/notify_tool'
require_relative 'tools/dialog_tool'
require_relative 'tools/get_time_tool'
require_relative 'tools/file_read_tool'
require_relative 'tools/file_write_tool'
require_relative 'tools/file_rename_tool'
require_relative 'tools/file_delete_tool'
require_relative 'tools/file_list_tool'
require_relative 'tools/file_search_tool'
require_relative 'tools/file_patch_tool'
require_relative 'tools/file_copy_tool'
require_relative 'tools/file_info_tool'
require_relative 'tools/note_tool'
require_relative 'tools/dir_create_tool'
require_relative 'tools/dir_delete_tool'
require_relative 'tools/git_diff_tool'
require_relative 'tools/git_show_tool'
require_relative 'tools/git_status_tool'
require_relative 'tools/git_log_tool'
require_relative 'tools/git_grep_tool'
require_relative 'tools/git_apply_tool'
require_relative 'tools/run_command_tool'
require_relative 'tools/tools_list_tool'
require_relative 'tools/tools_search_tool'
require_relative 'tool_registry'
require_relative 'session_manager'
require_relative 'state_migrator'
require_relative 'safety_check'
require_relative 'text_normalizer'

# -- Harness --------------------------------------------------------------

class Harness
  # Built-in system prompt (issue #223): the default file is referenced by
  # path and read on demand (not loaded at class load time) so a /reload
  # after editing it takes effect without a restart. --system-file and the
  # config system_prompt_file key override it.
  DEFAULT_SYSTEM_PROMPT_FILE = File.expand_path('../config/system_prompt.txt', __dir__)

  # issue #158: 100 was too low for long multi-step tasks (bumped to 200).
  # issue #226: configurable via the 'max_tool_iterations' config key.
  MAX_TOOL_ITERATIONS = 200
  # After this many consecutive tool-call iterations, inject a "stop looping" message
  TOOL_LOOP_WARN_THRESHOLD = 10
  # After this many consecutive tool-call iterations, force-break and return whatever we have
  TOOL_LOOP_HARD_LIMIT = 20

  # All harness state (saved sessions, log, history) lives in this
  # directory inside the working directory, so it can be ignored from
  # git with a single entry (.harness/).
  HARNESS_DIR = '.harness'

  # Log file name (inside the session's own directory, see #session_log_path).
  SESSION_LOG_FILE = 'harness.log'

  attr_reader :options, :logger, :tool_registry, :file_list, :session, :session_manager, :client
  attr_accessor :history

  # issue #36: store a pending mid-turn steering note (set by the Task
  # drain loop's UI::Editor when input_pending? triggers). Blank/nil clears
  # the slot.
  #
  # Only ONE note is in flight at a time: a new assignment REPLACES any
  # earlier note that has not been injected yet - the user is correcting
  # their course, so the latest line wins. A note already injected by
  # #call_llm stays in the chain; this becomes the new pending one.
  def user_note_text=(text)
    @user_note = text.to_s.strip.empty? ? nil : text.to_s.strip
  end

  # issue #36: the steering notes injected into THIS turn's working chain,
  # in order. issue #208: with the session as the working chain they are
  # committed DIRECTLY (each note is a message in @session.messages), so
  # this list only serves specs and observability.
  def user_notes
    @user_notes
  end

  def initialize(options, file_list)
    @options       = options
    @file_list     = file_list
    @session       = Session.new(build_system_prompt)
    # issue #36 / #198 phase 1: mid-turn steering notes. A pending note
    # (set by the Task drain loop's UI::Editor while the model works) is
    # injected into the chain by #call_llm (issue #208: that chain IS
    # @session.messages, so the note commits with it) and tracked in
    # @user_notes for specs and observability.
    @user_note     = nil
    @user_notes    = []
    # One-time migration of legacy state (.sessions/, .harness_history) into
    # the .harness directory. Best-effort: failures are reported but never
    # block startup (issue #120).
    StateMigrator.run(@file_list.workdir, HARNESS_DIR)
    # The logger is DEFERRED: it is only created on first use
    # (#rebind_logger), so a startup that resumes a saved session never
    # leaves a throwaway log directory behind for the fresh random id
    # (issue #123).
    @logger        = nil
    @tool_registry = build_tool_registry
    @client        = LLMClient.new(options, @logger)
    @session_manager = SessionManager.new(self, file_list)
    # issue #224 follow-up: session-level auto-approve toggle for the
    # command safety check. NOT persisted with the session - it is a
    # per-run consent posture (toggled live with Ctrl+A), so every
    # fresh run starts with the config default.
    @command_safety_auto_approve = options[:command_safety_auto_approve] == true
    # issue #221: YOLO posture - skip the shell consent dialog entirely for
    # the run.command tool (the disaster denylist still applies, see
    # CommandAllowlist::DISASTER_PATTERNS). Unlike the #224 posture above,
    # this ONE IS persisted with the session (SessionManager#save_session /
    # #resume_session write and read the session JSON's 'yolo' key): the user
    # turned it on deliberately and a resume must not silently restore the
    # prompts they opted out of. Toggled live with /yolo.
    @yolo = options[:yolo] == true
  end

  # Build the system prompt: the base prompt (read from options[:system_file]
  # when set, else the built-in default file) plus the project-specific rules
  # from a harness.md file in the working directory, when present. The base
  # is read fresh each call (issue #223) so a /reload after editing the file
  # picks up the change without a restart.
  def build_system_prompt
    base = read_system_prompt
    project_file = File.join(@file_list.workdir, 'harness.md')
    if File.file?(project_file)
      content = File.read(project_file).strip
      return "#{base}\n\n## Project-Specific Rules\n\n#{content}\n" unless content.empty?
    end
    base
  end

  # issue #113: each session logs to its own file inside its session dir
  # (.harness/sessions/<session-id>/), so concurrent sessions in the same
  # workdir do not interleave in one shared log. The session id is stable
  # within a run, EXCEPT that resume/continue swaps in a saved session with
  # a different id; that re-points the logger via #rebind_logger (see
  # SessionManager#resume_session).
  def session_log_path
    File.join(@file_list.workdir, HARNESS_DIR, 'sessions', @session.session_id, SESSION_LOG_FILE)
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

  # issue #113 / #123: create (or rebuild) the logger for the CURRENT
  # session id. Deferred from #initialize so a fresh random id never gets a
  # throwaway log directory when the run resumes a saved session instead.
  # When the session id changes (resume/continue), closes the old logger and
  # re-points the LLM client, which holds its own reference.
  def rebind_logger
    @logger.close if @logger.respond_to?(:close)
    @logger = build_logger
    @client.logger = @logger if @client.respond_to?(:logger=)
    @logger
  end

  # Lazy accessor: the logger is created on first use (issue #123), so code
  # that logs before any rebind still gets a working logger for the current
  # session id.
  def logger
    @logger ||= rebind_logger
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
    registry.register(Tools::DirDeleteTool.new(@file_list))
    # Context note (issue #138): records transient facts (e.g. just-granted
    # paths) in the chain instead of re-dumping the grant list per prompt.
    registry.register(Tools::NoteTool.new)
    # Git tools (operate on the repository containing the working dir).
    registry.register(Tools::GitDiffTool.new(@file_list))
    registry.register(Tools::GitShowTool.new(@file_list))
    registry.register(Tools::GitStatusTool.new(@file_list))
    registry.register(Tools::GitLogTool.new(@file_list))
    registry.register(Tools::GitGrepTool.new(@file_list))
    registry.register(Tools::GitApplyTool.new(@file_list, @session))
    # Shell execution. Commands not in the user's allowlist require
    # explicit confirmation (issue #69, CommandAllowlist).
    registry.register(Tools::RunCommandTool.new(@file_list, @options,
                                                harness: self))
    # Meta-tools (discovery): registered last so they appear at the end
    # of the sorted tool list. They take the registry itself as an
    # argument (built before the tools are instantiated).
    registry.register(Tools::ToolsListTool.new(registry))
    registry.register(Tools::ToolsSearchTool.new(registry))
  end

  def compact_recent_messages
    options[:compact_recent] || Session::COMPACT_RECENT_MESSAGES
  end

  def compact_auto_threshold
    options[:compact_auto_threshold] || Session::AUTO_COMPACT_THRESHOLD
  end

  # Absolute headroom (tokens) that must stay free before auto-compaction
  # fires (issue #151): the compaction summary call needs room to send and
  # generate, so a small window compacts proportionally earlier than a big
  # one. nil/0 disables the headroom check (percentage trigger only).
  def compact_reserved_tokens
    options[:compact_reserved] || Session::COMPACT_RESERVED_TOKENS
  end

  def compact_max_size
    options[:compact_max_size]
  end

  # issue #226: max tool-loop iterations for a single turn (config key).
  def max_tool_iterations
    options[:max_tool_iterations] || MAX_TOOL_ITERATIONS
  end

  # issue #224: opt-in pre-dialog command safety check (config
  # 'command_safety_check'). The model's verdict is shown as an advisory
  # note in the consent dialog (and, when auto-approve is on, can skip
  # the dialog for commands the model calls safe - see
  # #command_safety_auto_approve).
  def command_safety_check
    options[:command_safety_check] == true
  end

  # issue #224 follow-up: session-level auto-approve toggle. When ON, a
  # command the model verdicts as "safe:" skips the consent dialog and
  # runs immediately. It NEVER widens the allowlist and it is inert
  # without command_safety_check (no verdict, no auto-approve). Toggled
  # live with Ctrl+A (the note editor / idle prompt consume the key);
  # not persisted with the session - a consent posture, not conversation
  # state.
  def command_safety_auto_approve
    @command_safety_auto_approve
  end

  def command_safety_auto_approve=(val)
    @command_safety_auto_approve = (val == true)
  end

  # The auto-approve posture only makes sense with the safety check on:
  # without a verdict there is nothing to auto-approve from.
  def command_safety_auto_approve_effective?
    command_safety_check && command_safety_auto_approve
  end

  # -- YOLO posture (issue #221) ------------------------------------------
  #
  # The user's own answer to consent fatigue (issue #221 / #254): with YOLO
  # on, EVERY run.command call skips the consent dialog - no per-command
  # 1+ENTER, and deliberately NO model safety-check call either (issue #238:
  # the check adds an LLM round trip per batch and trashes the local KV
  # cache, which is exactly the performance pain the check was supposed to
  # avoid). What does NOT change in YOLO:
  #   * the disaster denylist (CommandAllowlist.disaster?) - a well-known
  #     disaster command still gets the dialog in every posture;
  #   * file/dir/git tool grants (YOLO is a SHELL consent posture only -
  #     it never grants file write access);
  #   * the audit trail: every YOLO run prints a status line and is logged.
  # The model cannot turn it on; only /yolo, the config initial posture, a
  # mid-turn steering note carrying /yolo, or a resumed session can.
  def yolo?
    @yolo
  end

  def yolo=(val)
    # Coerce to a real boolean: a truthy junk value must not make YOLO look
    # ON while the code still treats it as a non-boolean (issue #221, same
    # shape as the #224 setter).
    @yolo = (val == true)
  end

  # Flip the YOLO posture (the /yolo slash command and the mid-turn
  # /yolo steering marker both use this). Returns the new state as a label
  # so the caller can ack it. The state travels with the session save.
  def toggle_yolo
    @yolo = !@yolo
    yolo_mode_label
  end

  # The full command-consent MODE as one short label: YOLO wins over the
  # #224 AUTO-APPROVE / MANUAL pair (YOLO means no consent check at all).
  # nil renders no badge - shown only when something is switchable: with
  # YOLO off and the safety check off there is no posture to display.
  def command_mode_label
    return 'YOLO' if @yolo
    return nil unless command_safety_check

    command_safety_auto_approve ? 'AUTO-APPROVE' : 'MANUAL'
  end

  # Short label for the /yolo ack line.
  def yolo_mode_label
    @yolo ? 'YOLO ON' : 'YOLO OFF'
  end

  # issue #224 follow-up: flip the command consent MODE live (Ctrl+A).
  # Returns the new MODE as a label ("AUTO-APPROVE" / "MANUAL"), or nil
  # when the safety check is off (there is no mode to switch, so the
  # toggle is a no-op). The state change is immediate - the spinner's
  # live badge re-reads it on the very next frame.
  def toggle_command_mode
    return nil unless command_safety_check

    @command_safety_auto_approve = !@command_safety_auto_approve
    command_safety_auto_approve ? 'AUTO-APPROVE' : 'MANUAL'
  end

  # issue #224: one check call covering ALL run.command calls of a tool
  # batch (never one call per command). Returns {command => verdict} on
  # success, nil on LLM error/timeout (consent flow simply continues
  # without a verdict). Purity: SafetyCheck never touches Session, so it
  # cannot trigger in-loop compaction or token anchoring.
  # issue #241: commands the allowlist already auto-approves never reach a
  # consent dialog (CommandRunner#run runs them right away and never
  # consumes a verdict), so the model is never asked about them.
  def precheck_batch_safety(message_calls)
    return nil unless command_safety_check

    commands = run_command_batch_commands(message_calls)
    return nil if commands.size < 2
    unapproved = commands.reject { |c| tool_allowlist.allowed?(c) }
    return nil if unapproved.size < 2
    skipped = commands.size - unapproved.size
    logger.info("safety pre-check: #{skipped} allowlisted command(s) skipped") if skipped.positive?

    logger.info("safety pre-check (#{unapproved.size} run.command in batch)")
    Task.emit(:text, origin: :harness,
              content: "  [safety] checking #{unapproved.size} commands before the consent dialog...")
    # issue #224 follow-up: re-point the spinner so it is clear the wait
    # is the model safety check (the mode badge is appended separately by
    # the Task spinner and keeps showing the current posture).
    Task.emit(:spinner_detail, origin: :harness,
              content: { message: "Model safety check (#{unapproved.size} commands)" })
    options[:safety_verdicts] =
      SafetyCheck.run(client, session.messages, unapproved)
  rescue StandardError => e
    logger.info("safety pre-check failed (#{e.class}: #{e.message}) - continuing without verdicts")
    nil
  end

  # The run.command allowlist as the tool runner consults it (issue #241:
  # the precheck must skip exactly the commands the runner will
  # auto-approve - same list, same matching). Read-only here.
  def tool_allowlist
    CommandAllowlist.new(file_list.workdir, file: CommandAllowlist::TOOL_FILENAME)
  end

  # The run.command commands of one tool batch, in order (empty when the
  # batch has none). Duplicate commands are kept - the verdict map handles
  # them fine and the batch order must stay intact.
  def run_command_batch_commands(message_calls)
    calls = Array(message_calls)
    calls.filter_map do |tc|
      next unless tc.dig(:function, :name) == 'run.command'

      JSON.parse(tc.dig(:function, :arguments).to_s) rescue {}
    end.map { |a| a['command'].to_s }.reject(&:empty?)
  end

  # The effective auto-compact usage level (tokens) for the active window:
  # min(threshold_pct% of window, window - reserved tokens). nil when no
  # valid window size is configured. Shared by every auto-compact decision
  # (SessionManager, /ctx report) so the trigger stays in ONE place
  # (issue #151).
  def compact_trigger_tokens
    window = options[:num_ctx] || LLMClient::NUM_CTX
    return nil if window.to_i <= 0

    @session.compact_trigger(window, compact_auto_threshold,
                             reserved_tokens: compact_reserved_tokens)
  end

  # -- LLM call logic -------------------------------------------------------

  # Sends the current session message chain to the LLM (with the tool loop).
  # issue #208: the session IS the working chain - every round (assistant
  # tool_calls + tool results, steering notes) is appended to
  # @session.messages AS IT HAPPENS, so a turn that fails or is killed
  # mid-loop keeps every round already made and /retry resumes from exactly
  # that point instead of replaying the prompt from zero. On success the
  # final assistant reply is appended and the stats are recorded.
  def call_llm
    messages = @session.messages

    # issue #36 / #208: steering notes injected this turn - with the
    # session as the working chain they ARE committed (they are messages in
    # @session.messages); the list is kept for specs and observability.
    @user_notes = []
    tools = tool_registry.empty? ? nil : tool_registry.to_openai

    iteration = 0
    consecutive_tool_calls = 0
    last_tool_name = nil
    loop_warning_injected = false
    loop_hard_break = false
    total_usage = { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 }
    # Prompt tokens of the LAST LLM call in this turn. Each call's
    # prompt_tokens already includes the full history (previous turns
    # plus all earlier tool results), so the last call is the true size
    # of the current context - summing across iterations would
    # overcount (issue #81).
    last_prompt_tokens = 0
    start_time = Time.now

    max_iters = max_tool_iterations
    loop do
      iteration += 1
      raise ToolLoopError, "exceeded max tool iterations (#{max_iters})" if iteration > max_iters

      # issue #108: in-loop compaction. The context window may already be
      # exhausted by the LAST call's prompt_tokens; compact now rather than
      # letting the NEXT request fail server-side mid-turn. Only relevant
      # after at least one tool round (iteration 1 has nothing to summarize).
      if iteration > 1 && last_prompt_tokens > 0 &&
         @session_manager.check_inloop_compaction(messages, last_prompt_tokens)
        # Compaction rewrote the chain - any loop-detection state built on
        # the pre-compaction tool calls is stale and must be reset.
        consecutive_tool_calls = 0
        loop_warning_injected = false
      end

      # issue #36: a steering note the user typed mid-turn is injected into
      # the working chain (= the session chain, issue #208) BEFORE the next
      # LLM call, so the model can react to it immediately (course-correct a
      # long tool loop). It is tracked in @user_notes as well.
      if @user_note
        note = @user_note
        @user_note = nil
        @user_notes << note  # still tracked for specs / observability
        logger.info("user mid-turn note injected: #{note}")
        messages << { role: 'user', content: "User note (mid-turn): #{note}" }
        # issue #198: the commit ack ("[note] got it") fires the moment the
        # user hits Enter; THIS line is the proof the model actually received
        # the note, without reading harness.log or waiting for the reply.
        Task.emit(:text, origin: :harness, content: '  [note] sent to model')
      end

      data    = @client.chat(messages, tools: tools)
      message = data[:choices][0][:message]

      # issue #131: show reasoning in each step - surface what the model is
      # thinking on this iteration so the user can follow the work live.
      # Full text stays in harness.log and /reasoning. Disabled with
      # HARNESS_STEP_DISPLAY=off.
      print_step_display(iteration, message) if message[:tool_calls]

      # Accumulate usage stats
      if data[:usage]
        total_usage[:prompt_tokens]     += data[:usage][:prompt_tokens]     || 0
        total_usage[:completion_tokens] += data[:usage][:completion_tokens] || 0
        total_usage[:total_tokens]      += data[:usage][:total_tokens]      || 0
        last_prompt_tokens              = data[:usage][:prompt_tokens].to_i
      end

      # issue #216: anchor the live estimate to the server-reported size of
      # THIS chain (its message count right now, before the reply below is
      # appended) so spinner numbers grow from the true count (issue #216).
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

        # Append assistant message with tool_calls
        assistant_msg = { role: 'assistant', content: message[:content] }
        assistant_msg[:tool_calls] = message[:tool_calls]
        @session.add_assistant_message(assistant_msg)

        # Execute each tool call and append results
        # issue #224: when a batch holds SEVERAL run.command calls, ask the
        # model ONE safety-check call for all of them BEFORE the first
        # consent dialog (one line per command); single calls check
        # themselves inside CommandRunner.
        precheck_batch_safety(message[:tool_calls])
        message[:tool_calls].each do |tc|
          result = execute_tool_call(tc)
          record_note(tc, result)
          messages << {
            role: 'tool',
            tool_call_id: tc[:id],
            content: result
          }
        end

        # If we hit the hard limit, inject a strong "stop" message
        if loop_hard_break
          messages << {
            role: 'user',
            content: 'STOP. You are stuck in a tool loop. Do NOT call any more tools. ' \
                     'Respond NOW with your final answer. If you were editing files, use the file.write tool to save them. ' \
                     'If this was a query, answer it directly in plain text.'
          }
          next
        end

        # If we hit the warning threshold, inject a gentle reminder
        if loop_warning_injected && consecutive_tool_calls == TOOL_LOOP_WARN_THRESHOLD
          messages << {
            role: 'user',
            content: 'Reminder: You have called the same tool multiple times in a row. ' \
                     'If you have enough information, stop calling the same tool and provide your final answer now.'
          }
        end

        next
      end

      # No tool calls - final response
      elapsed = (Time.now - start_time).round(2)
      stats = {
        elapsed_seconds: elapsed,
        iterations:      iteration,
        usage:           total_usage,
        prompt_tokens:   last_prompt_tokens
      }

      # Commit the successful exchange to the session.
      @session.add_assistant(message[:content])
      # issue #138: persist any grants recorded with ui.note this turn as
      # system messages in the chain, so the fact survives past this turn
      # (the tool-call trail itself is never committed into the session).
      @session.flush_notes
      @session.record_stats(stats)
      # issue #98: keep the reasoning of the last response so it can be
      # shown on demand with /reasoning. The full text goes to harness.log
      # always (see SessionManager#send_session, issue #131).
      @session.record_reasoning(message[:reasoning])

      return {
        reasoning: message[:reasoning],
        content:   message[:content],
        stats:     stats
      }
    end
  end

  # issue #138: a successful ui.note call carries its fact in the argument.
  # Buffer it into the session so it is flushed into the chain when the turn
  # commits (see #call_llm) - this is what makes the grant survive past the
  # transient tool result and across /retry.
  def record_note(tool_call, result)
    return unless tool_call[:function][:name] == 'ui.note'
    return unless result.is_a?(String) && result.start_with?('ok: noted')

    args = tool_call[:function][:arguments] ? JSON.parse(tool_call[:function][:arguments]) : {}
    @session.add_note(args['text'])
  rescue StandardError
    # A malformed note must never break the turn.
  end

  # Prints the response stats line.
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
    ctx = context_indicator
    parts << ctx if ctx

    # issue #40 follow-up: structured output sink - emit to the Task-owned
    # buffer; the drain loop renders it on the main thread.
    Task.emit(:stats, origin: :harness, content: "  [#{parts.join(' | ')}]")
  end

  # issue #226: format elapsed seconds for the stats line. Under 60s the
  # bare value is fine (e.g. "42.37s"); at 60s or above the minutes are
  # factored out (e.g. "84m 59,17s") so the line stays compact.
  def format_elapsed(seconds)
    s = seconds.to_f
    return "#{s.round(2)}s" if s < 60

    mins = (s / 60).floor
    secs = format('%05.2f', s - mins * 60).sub('.', ',')
    "#{mins}m #{secs}s"
  end

  # Context-usage indicator, e.g. "🧠 ctx 42133/65536 (64%)". Shown on every
  # response so the user always sees how much of the context window is used.
  # Also printed above the prompt at turn start (see CLI#run) so it is
  # visible even when idle. Uses the last reported usage when available,
  # otherwise a rough estimate (marked with "~"). Returns nil when there
  # is no conversation yet (nothing to measure).
  def context_indicator
    window = options[:num_ctx] || LLMClient::NUM_CTX
    used = @session.context_used
    return nil if used.nil?

    pct = @session.context_pct(window)
    label = used[:estimated] ? '~' : ''
    "🧠 ctx #{label}#{used[:tokens]}/#{window} (#{pct}%)"
  end

  # Live context indicator for the spinner (issue #126): unlike
  # #context_indicator, which reports the LAST response's number, this
  # measures the CURRENT message chain, so it reflects the chain being sent
  # right now - including mid-turn tool results not yet in last_stats.
  # Uses the last reported usage when available (exact, no "~"), otherwise a
  # rough estimate of the chain (marked "~"). nil when there is nothing to
  # measure.
  #
  # messages: optional explicit chain to estimate from (the in-loop compaction
  # operates on a local working chain that is not yet in @session - always an
  # estimate). Defaults to the session's own chain.
  def context_indicator_live(messages = nil)
    window = options[:num_ctx] || LLMClient::NUM_CTX
    if messages
      # issue #216: anchored to the last server-reported count when this
      # chain extends it (see Session#anchored_estimate).
      tokens  = @session.anchored_estimate(messages)
      label   = '~'
    else
      used    = @session.context_used
      return nil if used.nil?
      tokens  = used[:tokens]
      label   = used[:estimated] ? '~' : ''
    end

    pct = (tokens.to_f / window * 100).round
    "🧠 ctx #{label}#{tokens}/#{window} (#{pct}%)"
  end

  # Multi-line context report for the /ctx command: usage, window size,
  # headroom and whether auto-compaction is due at the current threshold.
  def context_report
    window = options[:num_ctx] || LLMClient::NUM_CTX
    used   = @session.context_used
    return "No conversation yet - nothing to measure." if used.nil?

    # issue #151: the auto-compact trigger depends on the context size
    # (min of the %-threshold and window - reserved headroom), so report
    # the effective level for THIS window instead of a bare percentage.
    trigger = compact_trigger_tokens

    pct      = @session.context_pct(window)
    headroom = [window - used[:tokens], 0].max
    due      = trigger && (used[:tokens] >= trigger)

    status = due ? 'due' : 'not due'
    lines = []
    lines << "🧠 Context usage"
    lines << "  Used:        #{used[:tokens]} tokens (#{pct}% of #{window})"
    lines << "  Source:      #{used[:estimated] ? 'estimate (~4 chars/token)' : 'last LLM response'}"
    lines << "  Headroom:    #{headroom} tokens"
    lines << "  Auto-compact: #{status} (fires at #{trigger} tokens, #{(trigger.to_f / window * 100).round}% of the window)" if trigger
    lines.join("\n")
  end

  private

  # issue #131: one-line per-iteration display for tool-loop steps.
  # Prints the model's step reasoning (first non-empty of reasoning/content)
  # plus the tools it is about to call, e.g.:
  #   [step 3 - checking existing spinner API]
  #     -> file.search, file.read
  def print_step_display(iteration, message)
    return if step_display_disabled?

    @session_manager.log_response(reasoning: message[:reasoning], content: message[:content])

    first_line = ->(key) { [message[key]].map { |m| m.to_s.strip }.reject(&:empty?).first }
    reason  = first_line.call(:reasoning)
    content = first_line.call(:content)

    tools  = message[:tool_calls].map { |tc| tc[:function][:name] }
    # The step header uses the reasoning when present, otherwise the
    # content (a response with no reasoning still shows a readable step).
    # issue #40 follow-up: structured output sink - no direct puts.
    Task.emit(:step, origin: :harness, content: "[step #{iteration}]")
    Task.emit(:step, origin: :harness, content: ">>> #{reason} <<<") if reason
    Task.emit(:step, origin: :harness, content: "||| #{content} |||") if content

    Task.emit(:step, origin: :harness, content: "    -> #{tools.join(', ')}")
  end

  def step_display_disabled?
    ENV.fetch('HARNESS_STEP_DISPLAY', '') == 'off' || options[:step_display] == false
  end

  # The base system prompt text: the configured file (options[:system_file],
  # set from --system-file or the config system_prompt_file key) when it
  # exists, else the built-in default file. issue #223: read on demand so
  # an edited file takes effect on the next /reload without a restart.
  def read_system_prompt
    path = options[:system_file]
    return File.read(path) if path && File.file?(path)

    File.read(DEFAULT_SYSTEM_PROMPT_FILE)
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
      # issue #257: the tool result goes straight back into the message
      # chain, so a byte that is invalid in UTF-8 would make the next
      # JSON.generate (the request body AND the session save) raise
      # JSON::GeneratorError - and the failure is invisible, because the
      # save that should record it fails on the same byte. Normalize here so
      # every tool result entering the chain is plain valid UTF-8.
      TextNormalizer.normalize(result)
    rescue => e
      logger.error("tool #{func_name} failed: #{e.message}")
      "error: #{e.message}"
    end
  end
end
