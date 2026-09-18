#!/usr/bin/env ruby
# frozen_string_literal: true
#
# harness.rb — interactive AI edit harness. Any OpenAI-compatible server.
# Supports tool calling (iterative), file editing, and direct prompts.
#
# Usage:
#   ruby harness.rb -m qwen2.5-coder:32b
#   ruby harness.rb -m my-model --base-url http://192.168.1.10:8000/v1 --token sk-abc123
#   HARNESS_TOKEN=sk-abc123 ruby harness.rb -m gpt-4o

require 'net/http'
require 'uri'
require 'json'
require 'fileutils'
require 'optparse'
require 'logger'
require 'time'
require 'thread'

LOG_FILE = ENV['HARNESS_LOG_FILE'] || 'harness.log'

# ── Custom exceptions ────────────────────────────────────────────────────

class HarnessError < StandardError; end
class LLMError < HarnessError; end
class ToolLoopError < HarnessError; end

# ── Spinner ──────────────────────────────────────────────────────────────

class Spinner
  FRAMES = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']

  def initialize(message = 'Working')
    @message = message
    @running = false
    @thread  = nil
  end

  def start
    @running = true
    @thread = Thread.new do
      i = 0
      while @running
        frame = FRAMES[i % FRAMES.size]
        print "\r#{frame} #{@message}..."
        $stdout.flush
        i += 1
        sleep 0.1
      end
    end
  end

  def stop
    @running = false
    @thread&.join
    print "\r" + ' ' * (@message.length + 5) + "\r"
    $stdout.flush
  end
end

# ── Tool system ──────────────────────────────────────────────────────────

class Tool
  attr_reader :name, :description, :parameters

  def initialize(name:, description:, parameters:)
    @name        = name
    @description = description
    @parameters  = parameters
  end

  def execute(args_hash)
    raise NotImplementedError, "#{self.class}#execute not implemented"
  end

  def to_openai
    {
      type: 'function',
      function: {
        name: @name,
        description: @description,
        parameters: @parameters
      }
    }
  end
end

class EchoTool < Tool
  def initialize
    super(
      name: 'echo',
      description: 'TEST-ONLY tool: returns the input text as-is. Do NOT use this to communicate with the user or send progress messages. Use the "notify" tool instead for any user-facing output.',
      parameters: {
        type: 'object',
        properties: {
          text: { type: 'string', description: 'Text to echo back' }
        },
        required: ['text']
      }
    )
  end

  def execute(args)
    args['text'] || ''
  end
end

class NotifyTool < Tool
  def initialize
    super(
      name: 'notify',
      description: 'Sends a progress or status message directly to the user\'s console. Use this to inform the user about what you are doing (e.g., "Analyzing file...", "Applying changes..."). This is the ONLY tool for communicating with the user.',
      parameters: {
        type: 'object',
        properties: {
          message: { type: 'string', description: 'The message to display to the user' }
        },
        required: ['message']
      }
    )
  end

  def execute(args)
    msg = args['message'] || ''
    puts "  [notify] #{msg}"
    $stdout.flush
    'ok'
  end
end

class GetTimeTool < Tool
  def initialize
    super(
      name: 'get_current_time',
      description: 'Returns the current date and time in ISO 8601 format.',
      parameters: {
        type: 'object',
        properties: {},
        required: []
      }
    )
  end

  def execute(_args)
    Time.now.iso8601
  end
end

class ToolRegistry
  attr_reader :tools

  def initialize
    @tools = {}
  end

  def register(tool)
    @tools[tool.name] = tool
    self
  end

  def get(name)
    @tools[name]
  end

  def to_openai
    @tools.values.map(&:to_openai)
  end

  def empty?
    @tools.empty?
  end

  def list
    @tools.values.map { |t| "  #{t.name} — #{t.description}" }.join("\n")
  end
end

# ── Harness ──────────────────────────────────────────────────────────────

class Harness
  SYSTEM_PROMPT = <<~'TEXT'
    You are a precise code editor and assistant. You receive file contents (if any) and an instruction.

    When the task involves editing files, return ONLY the modified files in this exact format:

    === FILE[X]: <relative/path> ===
    <complete file content>
    === END[X] ===

    Rules for file edits:
    - Replace [X] in FILE[X] and END[X] with numeric index of file
    - Only return files that changed.
    - Each file must be complete (not a diff, not a snippet).
    - No commentary before or after the blocks.
    - Preserve original formatting, indentation, and style.

    When the instruction is a query, conversation, or does not involve file editing,
    respond with plain text.

    You have access to tools. Use them when they help you complete the task.
    Use the "notify" tool to send progress or status messages to the user.
    Do NOT use the "echo" tool for user communication — it is test-only.
  TEXT

  MAX_TOOL_ITERATIONS = 100
  # After this many consecutive tool-call iterations, inject a "stop looping" message
  TOOL_LOOP_WARN_THRESHOLD = 3
  # After this many consecutive tool-call iterations, force-break and return whatever we have
  TOOL_LOOP_HARD_LIMIT = 5

  attr_reader :options, :logger, :tool_registry

  def initialize(options)
    @options       = options
    @logger        = build_logger
    @tool_registry = build_tool_registry
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
    registry
  end

  def build_user_prompt(files, instruction)
    sections = files.map do |path, content|
      "--- FILE: #{path} ---\n#{content}--- END ---\n"
    end
    "## Files\n\n#{sections.join("\n")}\n## Instruction\n\n#{instruction}\n"
  end

  def parse_response(text)
    files = {}
    text.scan(/=== FILE\[\d+\]: (.+?) ===\n(.*?)\n?=== END\[\d+\] ===/m) do |path, content|
      files[path.strip] = content.rstrip
    end
    files
  end

  def make_request(base_url, model, messages, auth_token: nil, timeout: 300, tools: nil)
    uri  = URI("#{base_url}/chat/completions")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = (uri.scheme == 'https')
    http.open_timeout = 30
    http.read_timeout = timeout

    body = {
      model: model,
      messages: messages,
      temperature: 0.1,
      max_tokens: 8192
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

    begin
      result = tool.execute(args)
      logger.info("tool #{func_name} → #{result}")
      result.to_s
    rescue => e
      logger.error("tool #{func_name} failed: #{e.message}")
      "error: #{e.message}"
    end
  end

  def call_llm(base_url, model, system, user, auth_token: nil, timeout: 300)
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
        # ── Tool-loop detection ──
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

        logger.info("─── tool_calls (iteration #{iteration}, consecutive: #{consecutive_tool_calls}) ───")
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
                     'Respond NOW with your final answer. If you were editing files, output the complete file blocks. ' \
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

  def read_files(file_list)
    files = {}
    file_list.each do |f|
      raise HarnessError, "file not found: #{f}" unless File.file?(f)
      files[f] = File.read(f)
    end
    files
  end

  def write_results(parsed)
    parsed.each do |path, content|
      if options[:dry_run]
        logger.info("─── DRY RUN: #{path} (#{content.length} chars) ───")
        logger.info(content)
      else
        dir = File.dirname(path)
        FileUtils.mkdir_p(dir) unless dir == '.'
        File.write(path, content + "\n")
        logger.info("wrote #{path}")
      end
    end
  end

  def print_stats(stats)
    return unless stats

    elapsed = stats[:elapsed_seconds]
    iters   = stats[:iterations]
    usage   = stats[:usage]

    parts = ["⏱ #{elapsed}s"]
    parts << "🔄 #{iters} iteration#{'s' if iters > 1}"
    if usage && usage[:total_tokens] > 0
      parts << "📊 #{usage[:prompt_tokens]}→#{usage[:completion_tokens]} tokens (#{usage[:total_tokens]} total)"
    end
    puts "  [#{parts.join(' | ')}]"
  end

  def run_once(file_list, instruction)
    files = read_files(file_list)
    user_prompt = build_user_prompt(files, instruction)

    if options[:verbose]
      logger.info("─── system ───\n#{options[:system]}")
      logger.info("─── user ───\n#{user_prompt}")
      logger.info("─── #{options[:model]} @ #{options[:base_url]} ───")
    end

    spinner = Spinner.new("Sending to #{options[:model]}")
    spinner.start

    response = nil
    begin
      response = call_llm(
        options[:base_url], options[:model], options[:system], user_prompt,
        auth_token: options[:token]
      )
    ensure
      spinner.stop
    end

    if options[:verbose]
      logger.info("─── reasoning ───\n#{response[:reasoning]}")
      logger.info("─── response ───\n#{response[:content]}")
    end

    parsed = parse_response(response[:content])
    if parsed.empty?
      logger.warn 'no file blocks detected — raw response:'
      logger.warn response[:content]
      puts response[:content]
      print_stats(response[:stats])
      return
    end

    write_results(parsed)
    print_stats(response[:stats])
    logger.info("→ git diff") unless options[:dry_run]
  end

  def run_prompt(instruction)
    user_prompt = instruction

    if options[:verbose]
      logger.info("─── system ───\n#{options[:system]}")
      logger.info("─── user ───\n#{user_prompt}")
      logger.info("─── #{options[:model]} @ #{options[:base_url]} ───")
    end

    spinner = Spinner.new("Sending to #{options[:model]}")
    spinner.start

    response = nil
    begin
      response = call_llm(
        options[:base_url], options[:model], options[:system], user_prompt,
        auth_token: options[:token]
      )
    ensure
      spinner.stop
    end

    if options[:verbose]
      logger.info("─── reasoning ───\n#{response[:reasoning]}")
      logger.info("─── response ───\n#{response[:content]}")
    end

    puts response[:content]
    print_stats(response[:stats])
  end
end

# ── CLI ──────────────────────────────────────────────────────────────────

class CLI
  attr_reader :options, :harness

  def initialize
    @options   = parse_options
    @harness   = Harness.new(@options)
    @file_list = []
  end

  def parse_options
    opts = {}

    parser = OptionParser.new do |o|
      o.banner  = 'Usage: harness.rb [options]'
      o.separator ''
      o.on('-m MODEL', '--model MODEL', 'Model name (required)')                 { |v| opts[:model]    = v }
      o.on('--base-url URL', 'API base URL [default: http://localhost:11434/v1]') { |v| opts[:base_url] = v }
      o.on('--token TOKEN',  'Bearer auth token [or $HARNESS_TOKEN]')            { |v| opts[:token]    = v }
      o.on('--system TEXT',  'Override system prompt')                           { |v| opts[:system]   = v }
      o.on('--dry-run',      'Print edits, do not write files')                  { opts[:dry_run]  = true }
      o.on('-v', '--verbose', 'Show full prompt and raw response')               { opts[:verbose]  = true }
      o.on('-h', '--help')                                                        { puts o; exit }
    end
    parser.parse!

    opts[:base_url] ||= ENV['HARNESS_BASE_URL']
    opts[:model]    ||= ENV['HARNESS_MODEL']
    opts[:system]   ||= Harness::SYSTEM_PROMPT
    opts[:token]    ||= ENV['HARNESS_TOKEN']

    raise HarnessError, '-m / --model is required' unless opts[:model]

    opts
  end

  def run
    trap('INT') do
      puts "\nGoodbye."
      exit 0
    end

    puts "Harness ready. Type /help for commands, /exit to quit."
    puts "Tip: type a plain message (no /) to send it directly to the model."
    puts

    loop do
      show_file_list
      input = get_command
      break if input.nil?

      begin
        handle_command(input)
      rescue HarnessError => e
        puts "  [error] #{e.message}"
      rescue LLMError => e
        puts "  [LLM error] #{e.message}"
      rescue ToolLoopError => e
        puts "  [tool loop] #{e.message}"
      rescue StandardError => e
        puts "  [unexpected error] #{e.class}: #{e.message}"
        puts "  (harness continues — type /exit to quit)"
      end

      break if @exiting

      puts
      puts "─" * 40
      puts
    end

    puts "Goodbye."
  end

  private

  def show_file_list
    if @file_list.empty?
      puts "(no files loaded)"
    else
      puts "Files (#{@file_list.size}):"
      @file_list.each_with_index do |f, i|
        puts "  #{i + 1}. #{f}"
      end
    end
  end

  def get_command
    print "harness> "
    $stdout.flush
    line = $stdin.gets
    return nil if line.nil?
    line.chomp
  end

  def handle_command(input)
    input = input.strip
    return if input.empty?

    case input
    when /\A\/file\s+(.+)\z/
      path = $1.strip
      if @file_list.include?(path)
        puts "Already in list: #{path}"
      else
        @file_list << path
        puts "Added: #{path}"
      end

    when /\A\/clear\z/
      @file_list = []
      puts "File list cleared."

    when /\A\/help\z/
      show_help

    when /\A\/exit\z/
      @exiting = true

    when /\A\/run\z/
      run_edit

    when /\A\/tools\z/
      show_tools

    when /\A\/\S*\z/
      puts "Unknown command: #{input}. Type /help for available commands."

    else
      # Non-slash input: direct prompt to the model
      run_direct_prompt(input)
    end
  end

  def show_help
    puts <<~HELP
      Available commands:
        /file <path>   Add a file to the working set
        /clear         Remove all files from the working set
        /run           Enter instruction and execute the file edit
        /tools         List available tools
        /help          Show this help
        /exit          Exit the harness

      Direct prompt:
        Type any text (not starting with /) to send it directly to the model
        as a conversation/query (no file context).
    HELP
  end

  def show_tools
    puts "Available tools:"
    puts harness.tool_registry.list
  end

  def run_edit
    if @file_list.empty?
      puts "No files in list. Use /file <path> to add files first."
      return
    end

    instruction = collect_instruction_multiline
    return if instruction.nil?

    puts
    harness.run_once(@file_list, instruction)
    puts
  end

  def run_direct_prompt(text)
    puts
    harness.run_prompt(text)
    puts
  end

  def collect_instruction_multiline
    puts "Enter instruction (end line with \\ to continue):"
    lines = []
    loop do
      print "  "
      $stdout.flush
      line = $stdin.gets
      break if line.nil?
      line = line.chomp

      if line.end_with?('\\')
        lines << line[0..-2]
      else
        lines << line
        break
      end
    end

    instruction = lines.join("\n")
    if instruction.strip.empty?
      puts "No instruction entered."
      return nil
    end
    instruction
  end
end

# ── Entry point ──────────────────────────────────────────────────────────

begin
  CLI.new.run
rescue HarnessError => e
  puts "Error: #{e.message}"
  exit 1
rescue Interrupt
  puts "\nGoodbye."
  exit 0
end
