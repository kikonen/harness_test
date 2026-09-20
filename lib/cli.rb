# frozen_string_literal: true

require 'optparse'
require 'fileutils'

require_relative 'harness_error'
require_relative 'harness'
require_relative 'file_list'

# -- CLI ------------------------------------------------------------------

class CLI
  attr_reader :options, :harness, :file_list

  # Threshold (seconds) for the gap between consecutive input characters.
  # If a character arrives within this window of the previous one, we assume
  # the input is a paste (the terminal delivers a pasted block as a burst of
  # already-buffered chars). Human typing is always slower than this.
  #
  # 50 ms is well below the fastest sustainable typing speed (~200 ms/char
  # for very fast typists) yet comfortably above the inter-character latency
  # of a paste burst (typically < 5 ms).
  PASTE_CHAR_INTERVAL = 0.05

  def initialize
    @options   = parse_options
    @file_list = FileList.new(@options[:files] || [])
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

    raise HarnessError, '-m / --model is required' unless opts[:model]

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
    trap('INT') do
      puts "\nGoodbye."
      exit 0
    end

    puts "Harness ready. Type /help for commands, /exit to quit."
    puts "Tip: type a plain message (no /) to send it directly to the model."
    puts "Tip: paste multiline text directly, or end a line with a backslash (\\) to continue."
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

  # Reads a full command from stdin, supporting both:
  #   * manually typed multiline input (a line ending in `\` continues), and
  #   * pasted multiline input (a burst of chars already buffered in stdin).
  #
  # We read character-by-character with getc rather than line-by-line with
  # gets. This matters because:
  #   * gets blocks until it sees a newline, so a paste that does NOT end in a
  #     linefeed would hang the prompt; getc lets us finish on EOF / a final
  #     char without a trailing newline.
  #   * A pasted block whose last char IS a linefeed used to be misread: the
  #     line-based loop would treat the trailing newline as "input complete"
  #     and send the prompt immediately. With getc we only treat a newline as
  #     "done" when the inter-character gap indicates human typing (see
  #     PASTE_CHAR_INTERVAL), so a trailing linefeed no longer triggers an
  #     early send.
  #
  # Bracketed paste (the terminal's 200~ / 201~ markers) is NOT relied upon:
  # it is delivered inconsistently across terminals, docker and ssh, so we
  # fall back to the inter-character timing heuristic instead.
  #
  # Paste detection (cross-platform, no IO.select):
  #   We measure the wall-clock gap between consecutive getc calls. A pasted
  #   block arrives as a burst — the gap between characters is typically
  #   < 5 ms. Human typing is always slower (≥ ~50 ms even for very fast
  #   typists). If the gap is below PASTE_CHAR_INTERVAL we flag the input as
  #   "pasted" and keep reading after a newline; otherwise we stop.
  #
  # Pasted text is not echoed back (the terminal already shows it); instead a
  # short summary like "[pasted N lines, Y chars]" is printed.
  #
  # Returns the joined command string, or nil on EOF.
  #
  # NOTE: the input is kept as an array of lines in @last_lines so that future
  # work (cursor movement between lines, editing existing lines, inserting new
  # lines) can operate on the structured form rather than a flat string.
  def get_command
    print "harness> "
    $stdout.flush

    lines  = []
    pasted = false
    buf    = +""
    last_char_time = nil

    loop do
      c = $stdin.getc
      break if c.nil?  # EOF

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # If this character arrived quickly after the previous one, the input
      # is almost certainly a paste burst (human typing is always slower).
      if last_char_time && (now - last_char_time) < PASTE_CHAR_INTERVAL
        pasted = true
      end
      last_char_time = now

      if c == "\n" || c == "\r"
        line = buf
        buf  = +""

        # Explicit continuation: a trailing backslash means "keep going",
        # regardless of whether more data is buffered.
        if line.end_with?('\\')
          lines << line[0..-2]
          print "... "
          $stdout.flush
          next
        end

        lines << line

        # A newline ends the input UNLESS we are in paste mode (characters
        # are arriving in a burst). This is the key fix: a trailing linefeed
        # no longer causes an immediate send, because we only stop when the
        # inter-character gap indicates human typing.
        break unless pasted
      elsif c == "\t"
        buf << "  "
      else
        buf << c
      end
    end

    # Include a trailing line that had no final newline (a paste without a
    # trailing linefeed, or EOF mid-line).
    lines << buf unless buf.empty?

    return nil if lines.empty?

    if pasted
      n     = lines.size
      chars = lines.sum { |l| l.length }
      puts "[pasted #{n} line#{'s' if n != 1}, #{chars} char#{'s' if chars != 1}]"
    end

    @last_lines = lines
    lines.join("\n")
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
        * Paste: paste a multiline block directly at the prompt. It is captured
          as a single prompt and summarized as "[pasted N lines, Y chars]"
          (the pasted text itself is not re-printed). A trailing linefeed in
          the pasted text will NOT cause an early send.
        * Type: end a line with a trailing backslash (\\) to continue the
          prompt on the next line. A continuation prompt ("... ") is shown
          until the line no longer ends with a backslash.
    HELP
  end

  def run_direct_prompt(text)
    puts
    harness.run_prompt(text)
    puts
  end
end
