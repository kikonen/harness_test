# frozen_string_literal: true

require 'json'
require 'logger'
require 'time'
require 'thread'
require 'digest'
require 'fileutils'

require_relative 'harness_error'
require_relative 'spinner'
require_relative 'tool'
require_relative 'llm_client'
require_relative 'file_list'
require_relative 'session'
require_relative 'tools/echo_tool'
require_relative 'tools/notify_tool'
require_relative 'tools/dialog_tool'
require_relative 'tools/get_time_tool'
require_relative 'tools/file_read_tool'
require_relative 'tools/file_write_tool'
require_relative 'tools/file_sha_tool'
require_relative 'tools/file_rename_tool'
require_relative 'tools/file_delete_tool'
require_relative 'tools/file_list_tool'
require_relative 'tools/file_search_tool'
require_relative 'tools/file_patch_tool'
require_relative 'tools/file_copy_tool'
require_relative 'tools/file_info_tool'
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

# -- Harness --------------------------------------------------------------

class Harness
  SYSTEM_PROMPT = File.read(File.join(__dir__, 'system_prompt.txt'))

  MAX_TOOL_ITERATIONS = 100
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
  attr_accessor :spinner

  def initialize(options, file_list)
    @options       = options
    @file_list     = file_list
    @session       = Session.new(build_system_prompt)
    # issue #113: move the legacy shared harness.log into this session's own
    # directory. Runs before build_logger so the logger writes to the new,
    # per-session location from the first line onward.
    StateMigrator.run(@file_list.workdir, HARNESS_DIR, @session.session_id)
    @logger        = build_logger
    @tool_registry = build_tool_registry
    @client        = LLMClient.new(options, @logger)
    @session_manager = SessionManager.new(self, file_list)
    @spinner       = nil
  end

  # Base system prompt (from config or built-in default) plus optional
  # project-specific rules from a harness.md file in the working directory.
  def build_system_prompt
    base = options[:system]
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

  # issue #113: rebuild the logger for the CURRENT session id. The logger is
  # created in #initialize for a fresh (random) session id; when a saved
  # session is resumed/continued the id changes, so the log must follow it or
  # it would land in the throwaway fresh-id directory. Closes the old logger
  # and re-points the LLM client, which holds its own reference.
  def rebind_logger
    @logger.close if @logger.respond_to?(:close)
    @logger = build_logger
    @client.logger = @logger if @client.respond_to?(:logger=)
    @logger
  end

  def build_tool_registry
    registry = ToolRegistry.new
    registry.register(Tools::EchoTool.new)
    registry.register(Tools::NotifyTool.new)
    registry.register(Tools::DialogTool.new)
    registry.register(Tools::GetTimeTool.new)
    registry.register(Tools::FileListTool.new(@file_list))
    registry.register(Tools::FileReadTool.new(@file_list))
    registry.register(Tools::FileWriteTool.new(@file_list, @options))
    registry.register(Tools::FileShaTool.new(@file_list))
    registry.register(Tools::FileRenameTool.new(@file_list, @options))
    registry.register(Tools::FileDeleteTool.new(@file_list, @options))
    registry.register(Tools::FileSearchTool.new(@file_list))
    registry.register(Tools::FilePatchTool.new(@file_list, @options))
    registry.register(Tools::FileCopyTool.new(@file_list, @options))
    registry.register(Tools::FileInfoTool.new(@file_list))
    registry.register(Tools::DirCreateTool.new(@file_list))
    registry.register(Tools::DirDeleteTool.new(@file_list, @options))
    # Git tools (operate on the repository containing the working dir).
    registry.register(Tools::GitDiffTool.new(@file_list))
    registry.register(Tools::GitShowTool.new(@file_list))
    registry.register(Tools::GitStatusTool.new(@file_list))
    registry.register(Tools::GitLogTool.new(@file_list))
    registry.register(Tools::GitGrepTool.new(@file_list))
    registry.register(Tools::GitApplyTool.new(@file_list))
    # Shell execution. Commands not in the user's allowlist require
    # explicit confirmation (issue #69, CommandAllowlist).
    registry.register(Tools::RunCommandTool.new(@file_list, @options))
    # Meta-tools (discovery): registered last so they appear at the end
    # of the sorted tool list. They take the registry itself as an
    # argument (built before the tools are instantiated).
    registry.register(Tools::ToolsListTool.new(registry))
    registry.register(Tools::ToolsSearchTool.new(registry))
    registry
  end

  def compact_recent_messages
    options[:compact_recent] || Session::COMPACT_RECENT_MESSAGES
  end

  def compact_auto_threshold
    options[:compact_auto_threshold] || Session::AUTO_COMPACT_THRESHOLD
  end

  def compact_max_size
    options[:compact_max_size]
  end

  # -- LLM call logic -------------------------------------------------------

  # Sends the current session message chain to the LLM (with the tool loop).
  # On success the final assistant reply is appended to the session and the
  # stats are recorded. On failure the session is left untouched (the pending
  # user message stays in the chain) so it can be retried.
  def call_llm
    messages = @session.messages.dup

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

    loop do
      iteration += 1
      raise ToolLoopError, "exceeded max tool iterations (#{MAX_TOOL_ITERATIONS})" if iteration > MAX_TOOL_ITERATIONS

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

      data    = @client.chat(messages, tools: tools)
      message = data[:choices][0][:message]

      # Accumulate usage stats
      if data[:usage]
        total_usage[:prompt_tokens]     += data[:usage][:prompt_tokens]     || 0
        total_usage[:completion_tokens] += data[:usage][:completion_tokens] || 0
        total_usage[:total_tokens]      += data[:usage][:total_tokens]      || 0
        last_prompt_tokens              = data[:usage][:prompt_tokens].to_i
      end

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
        messages << assistant_msg

        # Execute each tool call and append results
        message[:tool_calls].each do |tc|
          result = execute_tool_call(tc)
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
      @session.record_stats(stats)
      # issue #98: keep the reasoning of the last response so it can be
      # shown on demand with /reasoning (it is only logged when verbose).
      @session.record_reasoning(message[:reasoning])

      return {
        reasoning: message[:reasoning],
        content:   message[:content],
        stats:     stats
      }
    end
  end

  # Prints the response stats line.
  def print_stats(stats)
    return unless stats

    elapsed = stats[:elapsed_seconds]
    iters   = stats[:iterations]
    usage   = stats[:usage]

    parts = ["⏱ #{elapsed}s"]
    parts << "🔄 #{iters} iteration#{'s' if iters != 1}"
    if usage && usage[:total_tokens] > 0
      parts << "📊 #{usage[:prompt_tokens]}→#{usage[:completion_tokens]} tokens (#{usage[:total_tokens]} total)"
    end
    ctx = context_indicator
    parts << ctx if ctx

    puts "  [#{parts.join(' | ')}]"
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

  # Multi-line context report for the /ctx command: usage, window size,
  # headroom and whether auto-compaction is due at the current threshold.
  def context_report
    window = options[:num_ctx] || LLMClient::NUM_CTX
    used   = @session.context_used
    return "No conversation yet - nothing to measure." if used.nil?

    pct      = @session.context_pct(window)
    headroom = [window - used[:tokens], 0].max
    due      = @session.auto_compact_due?(window, compact_auto_threshold)

    status = due ? 'due' : 'not due'
    lines = []
    lines << "🧠 Context usage"
    lines << "  Used:        #{used[:tokens]} tokens (#{pct}% of #{window})"
    lines << "  Source:      #{used[:estimated] ? 'estimate (~4 chars/token)' : 'last LLM response'}"
    lines << "  Headroom:    #{headroom} tokens"
    lines << "  Auto-compact: #{status} (threshold #{compact_auto_threshold}%)"
    lines.join("\n")
  end

  private

  def execute_tool_call(tool_call)
    func_name = tool_call[:function][:name]
    args_json = tool_call[:function][:arguments]
    args      = args_json ? JSON.parse(args_json) : {}

    tool = tool_registry.get(func_name)
    unless tool
      return "error: unknown tool '#{func_name}'"
    end

    spinner_paused = false
    if @spinner
      @spinner.pause
      spinner_paused = true
    end

    begin
      result = tool.execute(args)
      logger.info("tool #{func_name} → #{result}")
      result.to_s
    rescue => e
      logger.error("tool #{func_name} failed: #{e.message}")
      "error: #{e.message}"
    ensure
      @spinner&.resume if spinner_paused
    end
  end
end