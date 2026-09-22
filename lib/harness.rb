# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'logger'
require 'time'
require 'thread'
require 'digest'
require 'fileutils'

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
require_relative 'tools/file_add_tool'
require_relative 'tool_registry'

# -- KeepAliveHTTP --------------------------------------------------------

# Net::HTTP with TCP keepalive enabled on the underlying socket, so that
# long-running LLM generations are not cut off by idle-connection timeouts
# (NATs, proxies, or the server itself dropping quiet connections).
class KeepAliveHTTP < Net::HTTP
  # Optional logger for diagnostics (e.g. unsupported keepalive options).
  attr_writer :logger

  def logger
    @logger || Logger.new(File::NULL)
  end

  def connect
    super
    # NOTE: Net::HTTP#socket is private (and was removed/changed across
    # Ruby versions), so reach the socket via the instance variable.
    socket = @socket
    if socket.respond_to?(:setsockopt)
      socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, 1)
      begin
        socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPIDLE,  Harness::KEEPALIVE_IDLE)
        socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPINTVL, Harness::KEEPALIVE_INTERVAL)
        socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPCNT,   Harness::KEEPALIVE_COUNT)
      rescue StandardError => e
        # TCP_KEEP* options are not available on all platforms (e.g. Windows)
        logger.debug("TCP_KEEP* keepalive options not applied: #{e.class}: #{e.message}")
      end
    end
  end
end

# -- Harness --------------------------------------------------------------

class Harness
  SYSTEM_PROMPT = <<~'TEXT'
    You are a precise code editor and assistant. You have access to tools for reading and writing files.

    When the task involves editing files:
    1. Use the "file_read" tool to read the current contents of files you need to modify. It returns the file's SHA-256 digest along with its contents.
    2. Make the requested changes.
    3. Use the "file_write" tool to write the complete modified file content back. You must pass the SHA-256 digest you obtained from file_read (or file_sha) as the "sha" argument; it is verified to match the file on disk before writing. If the file has changed since you read it, the write is rejected — re-read the file and retry.
    4. Only modify files that are in the provided list of available files.
    5. Each file write must contain the COMPLETE file content (not a diff or snippet).
    6. Preserve original formatting, indentation, and style unless the instruction says otherwise.
    7. If you need to work with a file that is NOT in the allowed list, use the "file_add" tool to request adding it. The user will be asked for confirmation.
    8. Use the "file_sha" tool to check a file's SHA-256 digest without reading its contents, e.g. to verify the file is still up to date before writing.
    9. All file paths are relative to the harness working directory (shown in the available files list).

    When the instruction is a query, conversation, or does not involve file editing, respond with plain text.

    Use the "notify" tool to send progress or status messages to the user.
    Do NOT use the "echo" tool for user communication — it is test-only.
  TEXT

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
  # Net::HTTP closes it and re-establishes a new one for the next request.
  # The default is only 2 seconds, which is too short for the tool loop
  # (tool execution between requests easily exceeds it), so we raise it.
  KEEP_ALIVE_TIMEOUT = 60

  # TCP keepalive settings (see KeepAliveHTTP): prevent idle connections
  # from being cut off by NATs/proxies/servers during long generations.
  KEEPALIVE_IDLE     = 60   # seconds of idle before the first keepalive probe
  KEEPALIVE_INTERVAL = 10   # seconds between keepalive probes
  KEEPALIVE_COUNT    = 6    # unanswered probes before the connection is dropped

  # Ollama generation limits. -1 means "no limit" (generate until the model
  # stops on its own). num_ctx is the context window size (65K tokens).
  NUM_PREDICT = -1
  NUM_CTX     = 65536

  # Default reasoning effort (NOTE KI default for qwen is xhigh)
  REASONING_EFFORT = "medium"

  # Saved sessions live in this directory (inside the working directory).
  SESSIONS_DIR = '.sessions'
  # How many hex chars of the SHA-256 digest are used as the session id.
  SESSION_ID_LENGTH = 8

  attr_reader :options, :logger, :tool_registry, :file_list, :session

  def initialize(options, file_list)
    @options       = options
    @file_list     = file_list
    @logger        = build_logger
    @tool_registry = build_tool_registry
    @session       = Session.new(options[:system])
    @spinner       = nil
  end

  def build_logger
    # Log file lives in the working directory so different harness
    # instances (different working directories) do not share a log.
    log_file = File.join(@file_list.workdir, LOG_FILE)
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
    registry.register(FileReadTool.new(@file_list))
    registry.register(FileWriteTool.new(@file_list, @options))
    registry.register(FileShaTool.new(@file_list))
    registry.register(FileAddTool.new(@file_list))
    registry
  end

  def build_user_prompt(file_list, instruction)
    files = file_list.to_a
    if files.empty?
      "## Working Directory\n\n#{file_list.workdir}\n\n## Instruction\n\n#{instruction}\n"
    else
      "## Working Directory\n\n#{file_list.workdir}\n\n## Available Files\n\n#{files.map { |f| "- #{file_list.display_path(f)}" }.join("\n")}\n\n## Instruction\n\n#{instruction}\n"
    end
  end

  # Context window size: prefer the value from options (CLI flag or
  # $HARNESS_NUM_CTX), falling back to the built-in default.
  def num_ctx
    options[:num_ctx] || NUM_CTX
  end

  # Reasoning effort: prefer the value from options (CLI flag or
  # $HARNESS_REASONING_EFFORT), falling back to the built-in default.
  def reasoning_effort
    options[:reasoning_effort] || REASONING_EFFORT
  end

  # -- Session persistence ------------------------------------------------
  #
  # Sessions are saved as JSON files in the .sessions directory inside the
  # working directory. Each session is identified by the first
  # SESSION_ID_LENGTH hex chars of the SHA-256 digest of the saved file
  # contents, so the id is stable and unique per saved session.

  # Directory where saved sessions are stored (inside the working directory).
  def sessions_dir
    File.join(@file_list.workdir, SESSIONS_DIR)
  end

  # Save the current session (conversation + file list) to disk.
  # Returns the session id (short SHA-256 prefix).
  def save_session
    FileUtils.mkdir_p(sessions_dir)

    data = @session.to_h(@file_list)
    json = JSON.generate(data)

    id = Digest::SHA256.hexdigest(json)[0, SESSION_ID_LENGTH]
    path = File.join(sessions_dir, "#{id}.json")

    File.write(path, json)
    logger.info("session saved: #{id} (#{path})")
    id
  end

  # Resume a saved session by id (full or abbreviated SHA-256 prefix).
  # Restores the conversation chain and the file list.
  def resume_session(id)
    id = id.to_s.strip
    raise HarnessError, 'usage: /resume <session-id>' if id.empty?

    path = find_session_file(id)
    raise HarnessError, "no saved session matching '#{id}' (see /sessions)" unless path

    data = JSON.parse(File.read(path), symbolize_names: true)
    @session.restore(data, @file_list)
    logger.info("session resumed: #{File.basename(path, '.json')} (#{path})")
    path
  end

  # List saved sessions, newest first. Returns an array of hashes:
  #   { id:, path:, saved_at:, messages:, files:, workdir: }
  # Corrupt/unreadable entries are skipped rather than aborting the listing.
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

  # -- Public prompt API (called by the CLI with an explicit receiver) ----

  # Appends a new user prompt to the session and sends the chain to the LLM.
  # If the request fails, the prompt stays in the session (pending) so it can
  # be re-sent with #retry.
  def run_prompt(instruction)
    user_prompt = build_user_prompt(@file_list, instruction)

    if options[:verbose]
      logger.info("--- system ---\n#{options[:system]}")
      logger.info("--- user ---\n#{user_prompt}")
      logger.info("--- #{options[:model]} @ #{options[:base_url]} ---")
    end

    @session.add_user(user_prompt)
    send_session
  end

  # Re-sends the current session chain (e.g. after a failed request).
  # Requires a pending user prompt at the end of the chain.
  def retry
    unless @session.pending?
      raise HarnessError, 'nothing to retry — no pending prompt in the session (send a prompt first)'
    end

    logger.info("--- retry: re-sending session chain (#{@session.messages.size} messages) ---")
    send_session
  end

  # Sends the session chain to the LLM and prints the response.
  def send_session
    spinner = Spinner.new("Sending to #{options[:model]}")
    @spinner = spinner
    spinner.start

    response = nil
    begin
      response = call_llm
    ensure
      spinner.stop
      @spinner = nil
    end

    if options[:verbose]
      logger.info("--- reasoning ---\n#{response[:reasoning]}")
      logger.info("--- response ---\n#{response[:content]}")
    end

    puts response[:content]
    print_stats(response[:stats])
  end

  private

  # Find a saved session file by (abbreviated) id: the id must be a prefix
  # of the file name (without extension). Raises HarnessError on ambiguity.
  def find_session_file(id)
    raise HarnessError, "invalid session id: #{id}" unless id =~ /\A[0-9a-fA-F]+\Z/

    matches = Dir.glob(File.join(sessions_dir, '*.json')).select do |p|
      File.basename(p, '.json').downcase.start_with?(id.downcase)
    end

    case matches.size
    when 0 then nil
    when 1 then matches.first
    else
      raise HarnessError, "ambiguous session id '#{id}' — matches: #{matches.map { |p| File.basename(p, '.json') }.join(', ')}"
    end
  end

  def make_request(base_url, model, messages, auth_token: nil, timeout: DEFAULT_READ_TIMEOUT, tools: nil)
    uri  = URI("#{base_url}/chat/completions")
    http = KeepAliveHTTP.new(uri.host, uri.port)
    http.logger       = logger
    http.use_ssl      = (uri.scheme == 'https')
    http.open_timeout = DEFAULT_OPEN_TIMEOUT
    http.read_timeout = timeout
    # NOTE: keep-alive is the default in Net::HTTP (the keep_alive= setter
    # was removed in Ruby 3.4), so no explicit setting is needed here.
    # But the default keep_alive_timeout is only 2 seconds — too short for
    # the tool loop (tool execution between requests easily exceeds it),
    # so raise it to keep the connection reusable across iterations.
    http.keep_alive_timeout = KEEP_ALIVE_TIMEOUT

    body = {
      model: model,
      messages: messages,
      temperature: 0.1,
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

    resp = http.request(req)
    raise LLMError, "LLM error (HTTP #{resp.code}):\n#{resp.body}" unless resp.is_a?(Net::HTTPSuccess)

    logger.info("=" * 50)
    logger.info(resp.body)
    logger.info("=" * 50)

    JSON.parse(resp.body, symbolize_names: true)
  rescue Net::OpenTimeout => e
    raise LLMError, "LLM request timed out (open): #{e.message}"
  rescue Net::ReadTimeout => e
    raise LLMError, "LLM request timed out (read): #{e.message}"
  rescue SocketError => e
    raise LLMError, "LLM connection failed: #{e.message}"
  rescue JSON::ParserError => e
    raise LLMError, "LLM returned invalid JSON: #{e.message}"
  end

  def execute_tool_call(tool_call)
    func_name = tool_call[:function][:name]
    args_json = tool_call[:function][:arguments]
    args      = args_json ? JSON.parse(args_json) : {}

    tool = tool_registry.get(func_name)
    unless tool
      return "error: unknown tool '#{func_name}'"
    end

    # Pause (and clear) the spinner so tool output/input is not broken
    # by the animation. Resume it afterwards if it was running.
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

  # Sends the current session message chain to the LLM (with the tool loop).
  # On success the final assistant reply is appended to the session and the
  # stats are recorded. On failure the session is left untouched (the pending
  # user message stays in the chain) so it can be retried with #retry.
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
          logger.warn("tool-loop hard limit reached (#{consecutive_tool_calls} consecutive calls to '#{current_tool_name}') — forcing final response")
          loop_hard_break = true
        elsif consecutive_tool_calls >= TOOL_LOOP_WARN_THRESHOLD && !loop_warning_injected
          logger.warn("tool-loop warning: #{consecutive_tool_calls} consecutive calls to '#{current_tool_name}' — injecting stop message")
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

        # If we hit the hard limit, inject a strong "stop" message and force the model to respond
        if loop_hard_break
          messages << {
            role: 'user',
            content: 'STOP. You are stuck in a tool loop. Do NOT call any more tools. ' \
                     'Respond NOW with your final answer. If you were editing files, use the file_write tool to save them. ' \
                     'If this was a query, answer it directly in plain text.'
          }
          next
        end

        # If we hit the warning threshold, inject a gentle reminder
        if loop_warning_injected && consecutive_tool_calls == TOOL_LOOP_WARN_THRESHOLD
          messages << {
            role: 'user',
            content: 'Reminder: You have called the same tool multiple times in a row. ' \
                     'If you have enough information, stop calling tools and provide your final answer now.'
          }
        end

        next
      end

      # No tool calls — final response
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
end
