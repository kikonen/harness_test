#!/usr/bin/env ruby
# frozen_string_literal: true
#
# harness.rb — interactive AI edit harness. Any OpenAI-compatible server.
# No agent loop, no tool calling. Prompt in, edited files out.
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
require 'debug'

LOG_FILE = ENV['HARNESS_LOG_FILE'] || 'harness.log'

class Harness
  SYSTEM_PROMPT = <<~'TEXT'
    You are a precise code editor. You receive file contents and an instruction.
    Return ONLY the modified files in this exact format:

    === FILE[X]: <relative/path> ===
    <complete file content>
    === END[X] ===

    Rules:
    - Replae [X] in FILE[X] and END[X] with numeric index of file
    - Only return files that changed.
    - Each file must be complete (not a diff, not a snippet).
    - No commentary before or after the blocks.
    - Preserve original formatting, indentation, and style.

    Exceptions:
    - if instructions are clearly query and not editing of file then
      return raw response
  TEXT

  attr_reader :options, :logger

  def initialize(options)
    @options = options
    @logger  = build_logger
  end

  def build_logger
    logger = Logger.new(LOG_FILE)
    logger.formatter = proc { |severity, datetime, _progname, msg|
      "#{datetime.strftime('%Y-%m-%d %H:%M:%S')} [#{severity}] #{msg}\n"
    }
    logger
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

  def call_llm(base_url, model, system, user, auth_token: nil, timeout: 300)
    uri  = URI("#{base_url}/chat/completions")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = (uri.scheme == 'https')
    http.open_timeout = 30
    http.read_timeout = timeout

    req = Net::HTTP::Post.new(uri.request_uri)
    req['Content-Type'] = 'application/json'
    req['Authorization'] = "Bearer #{auth_token}" if auth_token
    req.body = JSON.generate(
      model: model,
      messages: [
        { role: 'system', content: system },
        { role: 'user',   content: user   }
      ],
      temperature: 0.1,
      max_tokens: 8192
    )

    resp = http.request(req)
    abort "LLM error (HTTP #{resp.code}):\n#{resp.body}" unless resp.is_a?(Net::HTTPSuccess)

    logger.info("=" * 50)
    logger.info(resp.body)
    logger.info("=" * 50)

    data    = JSON.parse(resp.body, symbolize_names: true)
    message = data[:choices][0][:message]
    {
      reasoning: message[:reasoning],
      content:   message[:content],
    }
  end

  def read_files(file_list)
    files = {}
    file_list.each do |f|
      abort "error: not found: #{f}" unless File.file?(f)
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

  def run_once(file_list, instruction)
    files = read_files(file_list)
    user_prompt = build_user_prompt(files, instruction)

    if options[:verbose]
      logger.info("─── system ───\n#{options[:system]}")
      logger.info("─── user ───\n#{user_prompt}")
      logger.info("─── #{options[:model]} @ #{options[:base_url]} ───")
    end

    response = call_llm(
      options[:base_url], options[:model], options[:system], user_prompt,
      auth_token: options[:token]
    )

    if options[:verbose]
      logger.info("─── reasoning ───\n#{response[:reasoning]}")
      logger.info("─── response ───\n#{response[:content]}")
    end

    parsed = parse_response(response[:content])
    if parsed.empty?
      logger.warn 'no file blocks detected — raw response:'
      logger.warn response[:content]
      puts response[:content]
      return
    end

    write_results(parsed)
    logger.info("→ git diff") unless options[:dry_run]
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

    abort 'error: -m / --model is required' unless opts[:model]

    opts
  end

  def run
    trap('INT') do
      puts "\nGoodbye."
      exit 0
    end

    puts "Harness ready. Type /help for commands, /exit to quit."
    puts

    loop do
      show_file_list
      input = get_command
      break if input.nil?

      handle_command(input)
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

    else
      puts "Unknown command: #{input}. Type /help for available commands."
    end
  end

  def show_help
    puts <<~HELP
      Available commands:
        /file <path>   Add a file to the working set
        /clear         Remove all files from the working set
        /run           Enter instruction and execute the edit
        /help          Show this help
        /exit          Exit the harness
    HELP
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

CLI.new.run
