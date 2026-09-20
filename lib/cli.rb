# frozen_string_literal: true

require 'optparse'
require 'fileutils'
require 'io/console'

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
  #
  # NOTE: this heuristic only works if characters are delivered one at a
  # time, which requires raw terminal mode (see get_command_raw). In the
  # default buffered mode the kernel hands us the whole paste in a single
  # read, so every character "arrives" at the same instant and everything
  # looks like a paste.
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
      o.on('--reasoning-effort LEVEL', 'Reasoning effort [or $HARNESS_REASONING_EFFORT]') { |v| opts[:reasoning_effort] = v }
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
  # Paste detection relies on the wall-clock gap between consecutive
  # characters: a pasted block arrives as a burst (typically < 5 ms between
  # chars) while human typing is always slower (>= ~50 ms). This only works
  # if characters are delivered one at a time, which requires raw terminal
  # mode (IO/console): in the default buffered mode the kernel hands us the
  # whole paste in one read, so every character "arrives" at the same
  # instant and everything looks like a paste.
  #
  # Raw mode disables the terminal's line discipline, so we must handle
  # things the kernel used to do for us:
  #   * ^C no longer raises SIGINT — we see it as \x03 and handle it
  #     explicitly (clear the current input; quit if the input is empty),
  #   * ^D no longer signals EOF — we see it as \x04 and treat it as EOF,
  #   * echo is off — we echo each character ourselves,
  #   * backspace is not processed — we handle \x7f / \x08 ourselves.
  #
  # When stdin is not a tty (piped input) we fall back to plain getc; the
  # timing heuristic is meaningless there, so a newline simply ends the
  # input.
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

    if $stdin.tty? && $stdin.respond_to?(:raw)
      get_command_raw
    else
      get_command_fallback
    end
  end

  # Interactive input in raw terminal mode: characters arrive one at a time
  # (no kernel buffering), so the inter-character timing heuristic for paste
  # detection works. We must emulate the line discipline ourselves (see
  # get_command for the full list).
  def get_command_raw
    lines  = []
    pasted = false
    buf    = +""
    last_char_time = nil

    $stdin.raw do
      loop do
        c = $stdin.getc
        break if c.nil?

        case c
        when "\x03" # ^C: raw mode suppresses SIGINT, so handle it here.
          if buf.empty? && lines.empty?
            puts
            raise Interrupt  # empty input + ^C => quit
          end
          buf    = +""
          lines  = []
          pasted = false
          last_char_time = nil
          print "^C\nharness> "
          $stdout.flush
          next
        when "\x04" # ^D: raw mode suppresses EOF, treat it as end of input.
          break
        when "\n", "\r"
          line = buf
          buf  = +""
          print "\n"
          $stdout.flush

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
          # are arriving in a burst). This is the key fix: a trailing
          # linefeed no longer causes an immediate send, because we only
          # stop when the inter-character gap indicates human typing.
          break unless pasted
        when "\x7f", "\x08" # backspace: raw mode does not erase for us.
          next if buf.empty?
          buf.chop
          print "\b \b"
          $stdout.flush
          next
        else
          buf << (c == "\t" ? "  " : c)
          print c
          $stdout.flush
        end

        # If this character arrived quickly after the previous one, the input
        # is almost certainly a paste burst (human typing is always slower).
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if last_char_time && (now - last_char_time) < PASTE_CHAR_INTERVAL
          pasted = true
        end
        last_char_time = now
      end
    end

    finish_command(lines, buf, pasted)
  end

  # Non-interactive fallback (piped stdin, no tty): plain getc, a newline
  # ends the input, no paste detection (meaningless without a tty).
  def get_command_fallback
    lines = []
    buf   = +""

    loop do
      c = $stdin.getc
      break if c.nil?

      if c == "\n" || c == "\r"
        line = buf
        buf  = +""

        if line.end_with?('\\')
          lines << line[0..-2]
          next
        end

        lines << line
        break
      elsif c == "\t"
        buf << "  "
      else
        buf << c
      end
    end

    finish_command(lines, buf, false)
  end

  # Shared tail for both input modes: append a trailing line without a final
  # newline, summarize pastes, and return the joined command (or nil on EOF).
  def finish_command(lines, buf, pasted)
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

      Keys:
        Ctrl+C   Clear the current input (quits if the input is empty)
        Ctrl+D   Finish the input (sends it if non-empty, quits if empty)
    HELP
  end

  def run_direct_prompt(text)
    puts
    harness.run_prompt(text)
    puts
  end
end
