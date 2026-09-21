# frozen_string_literal: true

require 'optparse'
require 'fileutils'
require 'reline'

require_relative 'harness_error'
require_relative 'harness'
require_relative 'file_list'

# -- CLI ------------------------------------------------------------------

class CLI
  attr_reader :options, :harness, :file_list

  # Where command history is persisted (best-effort).
  # Kept in the harness working directory so that different harness
  # instances (i.e. different working directories) do not mix their history.
  # NOTE: if you change the default or add new env vars read here, remember
  # to update the corresponding exports in the _env file.
  HISTORY_FILE = ENV['HARNESS_HISTORY_FILE'] || '.harness_history'

  def initialize
    @options   = parse_options
    @file_list = FileList.new(@options[:files] || [], workdir: @options[:workdir])
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
      o.on('--num-ctx N',    'Context window size in tokens [or $HARNESS_NUM_CTX]') { |v| opts[:num_ctx] = v.to_i }
      o.on('--reasoning-effort LEVEL', 'Reasoning effort [or $HARNESS_REASONING_EFFORT]') { |v| opts[:reasoning_effort] = v }
      o.on('-d DIR', '--workdir DIR', 'Working directory; all file paths are relative to it [or $HARNESS_WORKDIR]') { |v| opts[:workdir] = v }
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
    opts[:num_ctx]  ||= ENV['HARNESS_NUM_CTX']&.to_i
    opts[:reasoning_effort] ||= ENV['HARNESS_REASONING_EFFORT']
    opts[:workdir]  ||= ENV['HARNESS_WORKDIR'] || Dir.pwd

    raise HarnessError, '-m / --model is required' unless opts[:model]

    # Resolve the working directory and make sure it exists.
    opts[:workdir] = File.expand_path(opts[:workdir])
    unless File.directory?(opts[:workdir])
      raise HarnessError, "working directory does not exist: #{opts[:workdir]}"
    end

    # Security: never allow sensitive files (e.g. .env*) into the list.
    (opts[:files] || []).each do |f|
      if FileList.sensitive?(f)
        puts "  [security] ✗ #{f} (blocked: sensitive file)"
        $stdout.flush
      end
    end
    opts[:files] = (opts[:files] || []).reject { |f| FileList.sensitive?(f) }

    opts
  end

  def run
    setup_history

    puts "Harness ready. Type /help for commands, /exit to quit."
    puts "Working directory: #{@file_list.workdir}"
    puts "Tip: type a plain message (no /) to send it directly to the model."
    puts "Tip: paste multiline text directly, or end a line with a backslash (\\) to continue."
    puts

    loop do
      show_file_list
      input = get_command
      break if input.nil?

      begin
        handle_command(input)
      rescue Interrupt
        puts "\n  [interrupted]"
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

    save_history
    puts "Goodbye."
  end

  private

  # History file lives in the working directory so different harness
  # instances (different working directories) do not mix their history.
  def history_file
    File.join(@file_list.workdir, HISTORY_FILE)
  end

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

  # Reads a full command from stdin using Reline (the same library IRB uses).
  # Reline handles everything the old hand-rolled raw-mode code tried to do:
  #   * multiline input (a line ending in `\` continues; unbalanced quotes
  #     also continue),
  #   * pasted multiline text (bracketed paste — newlines inside a paste are
  #     inserted into the buffer instead of sending the input),
  #   * line editing (arrows, kill, word movement),
  #   * history (up/down arrows), persisted to HISTORY_FILE.
  #
  # Ctrl+C raises Interrupt (rescued in the run loop); Ctrl+D on an empty
  # line returns nil (EOF => quit).
  #
  # The input is kept as an array of lines in @last_lines so that future work
  # (cursor movement between lines, editing existing lines, inserting new
  # lines) can operate on the structured form rather than a flat string.
  def get_command
    puts "[... to EOF input]> "
    $stdout.flush

    text = Reline.readmultiline(
      "",
      add_history: true,
      rprompt: "") do |multiline_input|
      # HACK KI this is BAD, but qwen wrote itself into corner
      multiline_input.split.last == "..."
    end

    return nil if text.nil?

    @last_lines = text.split("\n", -1)
    text
  end

  # Load persisted history into Reline (best-effort).
  #
  # Reline has no built-in history persistence, so we implement it ourselves.
  # The history file is line-based: one entry per line, with backslashes and
  # newlines escaped (see escape_history_entry / unescape_history_entry), so
  # multiline entries survive the round trip.
  def setup_history
    return unless File.exist?(history_file)

    Reline::HISTORY.clear
    File.foreach(history_file) do |line|
      entry = line.chomp
      next if entry.empty?

      Reline::HISTORY << unescape_history_entry(entry)
    end
  rescue StandardError => e
    puts e.message
    # Corrupt or unreadable history — start fresh.
  end

  # Persist history on exit (best-effort).
  def save_history
    File.open(history_file, 'w') do |f|
      Reline::HISTORY.each do |entry|
        f.puts escape_history_entry(entry)
      end
    end
  rescue StandardError => e
    puts e.message
    # Ignore — history persistence is best-effort.
  end

  # Encode a (possibly multiline) history entry as a single line:
  # backslashes first, then newlines.
  def escape_history_entry(text)
    text.gsub('\\', '\\\\').gsub("\n", '\\n')
  end

  # Decode a single history line back into the original entry.
  # Single-pass scan so that e.g. a literal `\n` in the original text
  # (escaped as `\\n`) is not mistaken for a newline.
  def unescape_history_entry(line)
    line.gsub(/\\(.)/) { |m| m[1] == 'n' ? "\n" : m[1] }
  end

  def handle_command(input)
    input = input.strip
    return if input.empty?

    case input
    when /\A\/file\s+(.+)\z/
      pattern = $1.strip
      # Support globs: expand the pattern against the filesystem,
      # relative to the working directory.
      if pattern =~ /[\\\*\?\[\]]/
        matches = Dir.glob(File.join(@file_list.workdir, pattern)).sort
        if matches.empty?
          puts "No files match: #{pattern}"
        else
          added = 0
          matches.each do |path|
            case @file_list.add(path)
            when :blocked
              puts "  [security] ✗ #{path} (blocked: sensitive file)"
            when :duplicate
              puts "Already in list: #{path}"
            when :added
              added += 1
              puts "Added: #{path}"
            end
          end
          puts "Added #{added} file#{'s' if added != 1} matching #{pattern}."
        end
      else
        case @file_list.add(pattern)
        when :blocked
          puts "  [security] ✗ #{pattern} (blocked: sensitive file)"
        when :duplicate
          puts "Already in list: #{pattern}"
        when :added
          puts "Added: #{pattern}"
        end
      end

    when /\A\/clear\z/
      @file_list.clear
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
        /clear         Remove all files from the list
        /tools         List available tools
        /help          Show this help
        /exit          Exit the harness

      Direct prompt:
        Type any text (not starting with /) to send it directly to the model.
        The model will see the list of allowed files and can use file_read /
        file_write tools to access them. Use file_add to request adding a
        new file (user confirmation required).

      Multiline input:
        * Paste: paste a multiline block directly at the prompt — it is
          captured as a single prompt (Reline's bracketed paste).
        * Type: end a line with a trailing backslash (\\) to continue the
          prompt on the next line (unbalanced quotes also continue).

      Keys:
        Ctrl+C   Cancel the current input (or interrupt a running request)
        Ctrl+D   Quit (on an empty prompt)
        Up/Down  Browse command history
    HELP
  end

  def run_direct_prompt(text)
    puts
    #puts "[LLM]"
    harness.run_prompt(text)
    puts
  end
end
