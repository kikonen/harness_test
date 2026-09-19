# frozen_string_literal: true

require 'optparse'
require 'fileutils'

require_relative 'harness_error'
require_relative 'harness'
require_relative 'sensitive_files'

# -- CLI ------------------------------------------------------------------

class CLI
  attr_reader :options, :harness

  def initialize
    @options   = parse_options
    @file_list = (@options[:files] || []).dup
    @harness   = Harness.new(@options, @file_list)
  end

  def parse_options
    opts = {}

    parser = OptionParser.new do |o|
      o.banner  = 'Usage: harness.rb [options] [FILE...]'
      o.separator ''
      o.on('-m MODEL', '--model MODEL', 'Model name (required)')                 { |v| opts[:model]    = v }
      o.on('--base-url URL', 'API base URL [default: http://localhost:11434/v1]') { |v| opts[:base_url] = v }
      o.on('--token TOKEN',  'Bearer auth token [or $HARNESS_TOKEN]')            { |v| opts[:token]    = v }
      o.on('--system TEXT',  'Override system prompt')                           { |v| opts[:system]   = v }
      o.on('-f FILE', '--file FILE', 'Add a file to the allowed file list (repeatable)') { |v| (opts[:files] ||= []) << v }
      o.on('--dry-run',      'Print edits, do not write files')                  { opts[:dry_run]  = true }
      o.on('-v', '--verbose', 'Show full prompt and raw response')               { opts[:verbose]  = true }
      o.on('-h', '--help')                                                        { puts o; exit }
    end
    parser.parse!

    # Shell glob expansion: `harness.rb -f src/*.rb` expands to
    # `-f src/a.rb src/b.rb ...` — OptionParser only consumes the first
    # argument as the option value; the rest become positional args.
    # Treat all remaining positional args as files so globs work.
    ARGV.each { |a| (opts[:files] ||= []) << a }

    opts[:base_url] ||= ENV['HARNESS_BASE_URL']
    opts[:model]    ||= ENV['HARNESS_MODEL']
    opts[:system]   ||= Harness::SYSTEM_PROMPT
    opts[:token]    ||= ENV['HARNESS_TOKEN']

    raise HarnessError, '-m / --model is required' unless opts[:model]

    # Security: never allow sensitive files (e.g. .env*) into the list.
    (opts[:files] || []).each do |f|
      if SensitiveFiles.sensitive?(f)
        puts "  [security] ✗ #{f} (blocked: sensitive file)"
        $stdout.flush
      end
    end
    opts[:files] = (opts[:files] || []).reject { |f| SensitiveFiles.sensitive?(f) }

    opts
  end

  def run
    trap('INT') do
      puts "\nGoodbye."
      exit 0
    end

    puts "Harness ready. Type /help for commands, /exit to quit."
    puts "Tip: type a plain message (no /) to send it directly to the model."
    puts "Tip: end a line with a trailing backslash (\\) to continue on the next line."
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
      puts "-" * 40
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

    buffer = line.chomp
    # Trailing backslash allows multiline input: strip the backslash,
    # keep the newline, and continue reading the next line.
    while buffer.end_with?('\\')
      buffer = buffer[0..-2] + "\n"
      print "... "
      $stdout.flush
      cont = $stdin.gets
      return nil if cont.nil?
      buffer += cont.chomp
    end
    buffer
  end

  def handle_command(input)
    input = input.strip
    return if input.empty?

    case input
    when /\A\/file\s+(.+)\z/
      pattern = $1.strip
      # Support globs: expand the pattern against the filesystem.
      if pattern =~ /[\\\*\?\[\]]/
        matches = Dir.glob(pattern).sort
        if matches.empty?
          puts "No files match: #{pattern}"
        else
          added = 0
          matches.each do |path|
            if SensitiveFiles.sensitive?(path)
              puts "  [security] ✗ #{path} (blocked: sensitive file)"
              next
            end
            if @file_list.include?(path)
              puts "Already in list: #{path}"
              next
            end
            @file_list << path
            added += 1
            puts "Added: #{path}"
          end
          puts "Added #{added} file#{'s' if added != 1} matching #{pattern}."
        end
      else
        if SensitiveFiles.sensitive?(pattern)
          puts "  [security] ✗ #{pattern} (blocked: sensitive file)"
        elsif @file_list.include?(pattern)
          puts "Already in list: #{pattern}"
        else
          @file_list << pattern
          puts "Added: #{pattern}"
        end
      end

    when /\A\/clear\z/
      @file_list = []
      puts "File list cleared."

    when /\A\/help\z/
      show_help

    when /\A\/exit\z/
      @exiting = true

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
        /file <path>   Add a file to the allowed file list (globs like src/*.rb work)
        /clear         Remove all files from the allowed list
        /tools         List available tools
        /help          Show this help
        /exit          Exit the harness

      Direct prompt:
        Type any text (not starting with /) to send it directly to the model.
        The model will see the list of allowed files and can use file_read /
        file_write tools to access them. Use file_add to request adding a
        new file (user confirmation required).

      Multiline input:
        End a line with a trailing backslash (\\) to continue the prompt
        on the next line. A continuation prompt ("... ") is shown until
        the line no longer ends with a backslash.
    HELP
  end

  def run_direct_prompt(text)
    puts
    harness.run_prompt(text)
    puts
  end
end
