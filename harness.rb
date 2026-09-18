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
    @options = parse_options
    @harness = Harness.new(@options)
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

    puts "Harness ready. Type 'exit' to quit, Ctrl+C to interrupt."
    puts

    loop do
      file_list = collect_files
      break if file_list.nil?

      instruction = collect_instruction
      break if instruction.nil?

      puts
      harness.run_once(file_list, instruction)
      puts
      puts "─" * 40
      puts
    end

    puts "Goodbye."
  end

  private

  def collect_files
    puts "Enter file(s) (one per line, blank line to finish):"
    files = []
    loop do
      line = $stdin.gets&.chomp
      break if line.nil?
      break if line.strip.empty?
      if line.strip.downcase == 'exit'
        return nil
      end
      files << line.strip
    end

    if files.empty?
      puts "No files entered."
      return []
    end

    files
  end

  def collect_instruction
    puts "Enter instruction:"
    instruction = $stdin.gets&.chomp
    if instruction.nil? || instruction.strip.empty?
      puts "No instruction entered."
      return nil
    end
    if instruction.strip.downcase == 'exit'
      return nil
    end
    instruction.strip
  end
end

# ── Entry point ──────────────────────────────────────────────────────────

CLI.new.run
