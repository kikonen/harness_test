# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'logger'
require 'time'
require 'thread'

require_relative 'harness_error'
require_relative 'spinner'
require_relative 'tool'
require_relative 'file_list'
require_relative 'tools/echo_tool'
require_relative 'tools/notify_tool'
require_relative 'tools/get_time_tool'
require_relative 'tools/file_read_tool'
require_relative 'tools/file_write_tool'
require_relative 'tools/file_add_tool'
require_relative 'tool_registry'

# -- Harness --------------------------------------------------------------

class Harness
  SYSTEM_PROMPT = <<~'TEXT'
    You are a precise code editor and assistant. You have access to tools for reading and writing files.

    When the task involves editing files:
    1. Use the "file_read" tool to read the current contents of files you need to modify.
    2. Make the requested changes.
    3. Use the "file_write" tool to write the complete modified file content back.
    4. Only modify files that are in the provided list of available files.
    5. Each file write must contain the COMPLETE file content (not a diff or snippet).
    6. Preserve original formatting, indentation, and style unless the instruction says otherwise.
    7. If you need to work with a file that is NOT in the allowed list, use the "file_add" tool to request adding it. The user will be asked for confirmation.

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
  DEFAULT_OPEN_TIMEOUT = 60
  DEFAULT_READ_TIMEOUT = 600

  # Ollama generation limits. -1 means "no limit" (generate until the model
  # stops on its own). num_ctx is the context window size (65K tokens).
  NUM_PREDICT = -1
  NUM_CTX     = 65536

  attr_reader :options, :logger, :tool_registry, :file_list

  def initialize(options, file_list)
    @options       = options
    @file_list     = file_list
    @logger        = build_logger
    @tool_registry = build_tool_registry
    @spinner       = nil
  end

  def build_logger
    logger = Logger.new(LOG_FILE)
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
    registry.register(FileAddTool.new(@file_list))
    registry
  end

  def build_user_prompt(file_list, instruction)
    files = file_list.to_a
    if files.empty?
      "## Instruction\n\n#{instruction}\n"
    else
      "## Available Files\n\n#{files.map { |f| "- #{f}" }.join("\n")}\n\n## Instruction\n\n#{instruction}\n"
    end
  end

  # Context window size: prefer the value from options (CLI flag or
  # $HARNESS_NUM_CTX), falling back to the built-in default.
  def num_ctx
    options[:num_ctx] || NUM_CTX
  end

  def make_request(base_url, model, messages, auth_token: nil, timeout: DEFAULT_READ_TIMEOUT, tools: nil)
    uri  = URI("#{base_url}/chat/completions")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = (uri.scheme == 'https')
    http.open_timeout = DEFAULT_OPEN_TIMEOUT
    http.read_timeout = timeout

    body = {
      model: model,
      messages: messages,
      temperature: 0.1,
      max_tokens: NUM_PREDICT,
      num_predict: NUM_PREDICT,
      num_ctx: num_ctx
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

  def call_llm(base_url, model, system, user, auth_token: nil, timeout: DEFAULT_READ_TIMEOUT)
    messages = [
      { role: 'system', content: system },
      { role: 'user',   content: user   }
    ]

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

      data    = make_request(base_url, model, messages, auth_token: auth_token, timeout: timeout, tools: tools)
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
      return {
        reasoning: message[:reasoning],
        content:   message[:content],
        stats: {
          elapsed_seconds: elapsed,
          iterations:      iteration,
          usage:           total_usage
        }
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

  def run_prompt(instruction)
    user_prompt = build_user_prompt(@file_list, instruction)

    if options[:verbose]
      logger.info("--- system ---\n#{options[:system]}")
      logger.info("--- user ---\n#{user_prompt}")
      logger.info("--- #{options[:model]} @ #{options[:base_url]} ---")
    end

    spinner = Spinner.new("Sending to #{options[:model]}")
    @spinner = spinner
    spinner.start

    response = nil
    begin
      response = call_llm(
        options[:base_url], options[:model], options[:system], user_prompt,
        auth_token: options[:token]
      )
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
end
