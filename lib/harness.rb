# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'logger'
require 'time'
require 'thread'
require 'digest'
require 'fileutils'

require_relative 'keep_alive_http'
require_relative 'harness_error'
require_relative 'spinner'
require_relative 'tool'
require_relative 'file_list'
require_relative 'session'
require_relative 'tools/echo_tool'
require_relative 'tools/notify_tool'
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
require_relative 'tools/git_apply_tool'
require_relative 'tools/tools_list_tool'
require_relative 'tools/tools_search_tool'
require_relative 'tool_registry'
require_relative 'session_manager'

# -- Harness --------------------------------------------------------------

class Harness
  SYSTEM_PROMPT = File.read(File.join(__dir__, 'system_prompt.txt'))

  MAX_TOOL_ITERATIONS = 100
  # After this many consecutive tool-call iterations, inject a "stop looping" message
  TOOL_LOOP_WARN_THRESHOLD = 10
  # After this many consecutive tool-call iterations, force-break and return whatever we have
  TOOL_LOOP_HARD_LIMIT = 20

  # Generous HTTP timeouts for local / slow model servers.
  # open_timeout: how long to wait for the TCP connection to establish.
  # read_timeout: how long to wait between bytes of the response (per read).
  DEFAULT_OPEN_TIMEOUT = 120
  DEFAULT_READ_TIMEOUT = 1800

  # How long (seconds) an idle keep-alive connection may sit unused before
  # Net::HTTP closes it and re-establishes a new one. The default is only
  # 2 seconds, which is too short for the tool loop (tool execution between
  # requests easily exceeds it), so we raise it.
  KEEP_ALIVE_TIMEOUT = 60

  # Transient network errors that are safe to retry (the request was never
  # completed, so re-sending it is idempotent from the server's perspective).
  RETRYABLE_ERRORS = [
    Errno::ECONNRESET,
    Errno::EPIPE,
    Errno::ECONNREFUSED,
    Errno::ETIMEDOUT,
    Errno::EHOSTUNREACH,
    OpenSSL::SSL::SSLError,
    IOError,
    Net::OpenTimeout,
    Net::ReadTimeout
  ].freeze

  # Automatic retry settings for transient network errors.
  # RETRY_COUNT: total number of attempts (1 initial + N-1 retries).
  # RETRY_DELAY: base delay in seconds (exponential backoff: 2s, 4s, 8s, ...).
  RETRY_COUNT = 3
  RETRY_DELAY = 2

  # Ollama generation limits. -1 means "no limit" (generate until the model
  # stops on its own). num_ctx is the context window size (65K tokens).
  NUM_PREDICT = -1
  NUM_CTX     = 65536

  # Default reasoning effort (NOTE KI default for qwen is xhigh)
  REASONING_EFFORT = "medium"

  # Sampling parameters (defaults). temperature controls randomness
  # (lower = more deterministic); top_p is nucleus sampling.
  TEMPERATURE = 0.2
  TOP_P       = 0.9
  TOP_K       = 20
  MIN_P       = 0
  PRESENCE_PENALTY = 1.0
  REPEAT_PENALTY   = 1.05

  # All harness state (saved sessions, log, history) lives in this
  # directory inside the working directory, so it can be ignored from
  # git with a single entry (.harness/).
  HARNESS_DIR = '.harness'

  # Log file name (inside HARNESS_DIR).
  LOG_FILE = 'harness.log'

  attr_reader :options, :logger, :tool_registry, :file_list, :session, :session_manager
  attr_accessor :spinner

  def initialize(options, file_list)
    @options       = options
    @file_list     = file_list
    @logger        = build_logger
    @tool_registry = build_tool_registry
    @session       = Session.new(build_system_prompt)
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

  def build_logger
    log_file = File.join(@file_list.workdir, HARNESS_DIR, LOG_FILE)
    FileUtils.mkdir_p(File.dirname(log_file))
    logger = Logger.new(log_file)
    logger.formatter = proc { |severity, datetime, _progname, msg|
      "#{datetime.strftime('%Y-%m-%d %H:%M:%S')} [#{severity}] #{msg}\n"
    }
    logger
  end

  def build_tool_registry
    registry = ToolRegistry.new
    registry.register(EchoTool.new)
    registry.register(NotifyTool.new)
    registry.register(GetTimeTool.new)
    registry.register(FileListTool.new(@file_list))
    registry.register(FileReadTool.new(@file_list))
    registry.register(FileWriteTool.new(@file_list, @options))
    registry.register(FileShaTool.new(@file_list))
    registry.register(FileRenameTool.new(@file_list, @options))
    registry.register(FileDeleteTool.new(@file_list, @options))
    registry.register(FileSearchTool.new(@file_list))
    registry.register(FilePatchTool.new(@file_list, @options))
    registry.register(FileCopyTool.new(@file_list, @options))
    registry.register(FileInfoTool.new(@file_list))
    registry.register(DirCreateTool.new(@file_list))
    registry.register(DirDeleteTool.new(@file_list, @options))
    # Git tools (operate on the repository containing the working dir).
    registry.register(GitDiffTool.new(@file_list))
    registry.register(GitShowTool.new(@file_list))
    registry.register(GitStatusTool.new(@file_list))
    registry.register(GitLogTool.new(@file_list))
    registry.register(GitApplyTool.new(@file_list))
    # Meta-tools (discovery): registered last so they appear at the end
    # of the sorted tool list. They take the registry itself as an
    # argument (built before the tools are instantiated).
    registry.register(ToolsListTool.new(registry))
    registry.register(ToolsSearchTool.new(registry))
    registry
  end

  # -- Config accessors (request parameters) --------------------------------

  def num_ctx
    options[:num_ctx] || NUM_CTX
  end

  def reasoning_effort
    options[:reasoning_effort] || REASONING_EFFORT
  end

  def temperature
    options[:temperature] || TEMPERATURE
  end

  def top_p
    options[:top_p] || TOP_P
  end

  def top_k
    options[:top_k] || TOP_K
  end

  def min_p
    options[:min_p] || MIN_P
  end

  def presence_penalty
    options[:presence_penalty] || PRESENCE_PENALTY
  end

  def repeat_penalty
    options[:repeat_penalty] || REPEAT_PENALTY
  end

  def compact_recent_messages
    options[:compact_recent] || Session::COMPACT_RECENT_MESSAGES
  end

  def compact_max_size
    options[:compact_max_size]
  end

  def retry_count
    options[:retry_count] || RETRY_COUNT
  end

  def retry_delay
    options[:retry_delay] || RETRY_DELAY
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
    start_time = Time.now

    loop do
      iteration += 1
      raise ToolLoopError, "exceeded max tool iterations (#{MAX_TOOL_ITERATIONS})" if iteration > MAX_TOOL_ITERATIONS

      data    = make_request(options[:base_url], options[:model], messages, auth_token: options[:token], tools: tools)
      message = data[:choices][0][:message]

      # Accumulate usage stats
      if data[:usage]
        total_usage[:prompt_tokens]     += data[:usage][:prompt_tokens]     || 0
        total_usage[:completion_tokens] += data[:usage][:completion_tokens] || 0
        total_usage[:total_tokens]      += data[:usage][:total_tokens]      || 0
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
        usage:           total_usage
      }

      # Commit the successful exchange to the session.
      @session.add_assistant(message[:content])
      @session.record_stats(stats)

      return {
        reasoning: message[:reasoning],
        content:   message[:content],
        stats:     stats
      }
    end
  end

  # Makes a single LLM API request with retry logic.
  def make_request(base_url, model, messages, auth_token: nil, timeout: DEFAULT_READ_TIMEOUT, tools: nil)
    uri  = URI("#{base_url}/chat/completions")
    http = KeepAliveHTTP.new(uri.host, uri.port)
    http.logger       = logger
    http.use_ssl      = (uri.scheme == 'https')
    http.open_timeout = DEFAULT_OPEN_TIMEOUT
    http.read_timeout = timeout
    http.keep_alive_timeout = KEEP_ALIVE_TIMEOUT

    body = {
      model: model,
      messages: messages,
      temperature: temperature,
      top_p: top_p,
      top_k: top_k,
      min_p: min_p,
      presence_penalty: presence_penalty,
      repeat_penalty: repeat_penalty,
      max_tokens: NUM_PREDICT,
      reasoning_effort: reasoning_effort,
      options: {
        num_predict: NUM_PREDICT,
        num_ctx: num_ctx
      }
    }
    body[:tools] = tools if tools && !tools.empty?

    req = Net::HTTP::Post.new(uri.request_uri)
    req['Content-Type'] = 'application/json'
    req['Authorization'] = "Bearer #{auth_token}" if auth_token
    req.body = JSON.generate(body)

    attempts = retry_count
    result = nil
    attempts.times do |attempt|
      begin
        resp = http.request(req)
      rescue *RETRYABLE_ERRORS => e
        if attempt < attempts - 1
          delay = retry_delay * (2 ** attempt)
          logger.warn("network error (attempt #{attempt + 1}/#{attempts}): #{e.class}: #{e.message} - retrying in #{delay}s")
          sleep(delay)
          next
        end
        raise LLMError, "LLM request failed after #{attempts} attempts: #{e.message}"
      end

      unless resp.is_a?(Net::HTTPSuccess)
        if resp.code.to_i >= 500 && attempt < attempts - 1
          delay = retry_delay * (2 ** attempt)
          logger.warn("HTTP #{resp.code} (attempt #{attempt + 1}/#{attempts}) - retrying in #{delay}s")
          sleep(delay)
          next
        end
        raise LLMError, "LLM error (HTTP #{resp.code}):\n#{resp.body}"
      end

      logger.info("=" * 50)
      logger.info(resp.body)
      logger.info("=" * 50)

      begin
        result = JSON.parse(resp.body, symbolize_names: true)
      rescue JSON::ParserError => e
        raise LLMError, "LLM returned invalid JSON: #{e.message}"
      end
      break
    end
    result
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
    puts "  [#{parts.join(' | ')}]"
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
