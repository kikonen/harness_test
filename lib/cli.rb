# frozen_string_literal: true

require 'optparse'
require 'fileutils'
require 'reline'

require_relative 'harness_error'
require_relative 'harness_config'
require_relative 'harness'
require_relative 'file_list'
require_relative 'history_manager'
require_relative 'command_handler'

# -- CLI ------------------------------------------------------------------

class CLI
  attr_reader :options, :harness, :file_list, :commands, :history

  # Default API base URL (used when neither the CLI nor the config provides one).
  DEFAULT_BASE_URL = 'http://localhost:11434/v1'

  def initialize
    @options   = parse_options
    @file_list = FileList.new([], workdir: @options[:workdir])
    @harness   = Harness.new(@options, @file_list)
    @commands  = CommandHandler.new(@harness, @file_list, @options)
    @history   = HistoryManager.new(@file_list.workdir)
    migrate_legacy_state
    list_sessions_and_exit if @options[:list_sessions]
    resume_from_cli if @options[:resume]
  end

  def parse_options
    opts = {}

    parser = OptionParser.new do |o|
      o.banner  = 'Usage: harness.rb [options]'
      o.separator ''
      o.on('-c FILE', '--config FILE',
           'Path to the YAML config file. Default: .harness/config.yml, ' \
           'which is created with a template on first run if missing.') do |v|
        opts[:config_path] = v
      end
      o.on('-m MODEL', '--model MODEL', 'Model name (required)') { |v| opts[:model] = v }
      o.on('--system-file FILE',
           'Use this file as the system prompt (overrides config / built-in)') do |v|
        opts[:system_file] = v
      end
      o.on('-d DIR', '--workdir DIR',
           'Working directory; all file paths are relative to it') do |v|
        opts[:workdir] = v
      end
      o.on('-r ID', '--resume ID',
           'Resume a saved session by id (see /sessions)') { |v| opts[:resume] = v }
      o.on('--list-sessions',
           'List saved sessions and exit (no model needed)') do
        opts[:list_sessions] = true
      end
      o.on('-v', '--verbose',
           'Show full prompt and raw response') { |v| opts[:verbose] = true }
      o.on('-h', '--help') { puts o; exit }
    end
    parser.parse!

    # Resolve the working directory first (config discovery depends on it).
    opts[:workdir] ||= Dir.pwd
    opts[:workdir] = File.expand_path(opts[:workdir])
    unless File.directory?(opts[:workdir])
      raise HarnessError, "working directory does not exist: #{opts[:workdir]}"
    end

    # Load the YAML config file (models, default_model, compact, system).
    # Precedence for every setting is: CLI flag > config file > built-in.
    config = HarnessConfig.load(opts[:config_path], opts[:workdir])

    # Resolve the active model profile from the config. When no models are
    # configured, -m is treated as a raw model id (backward compatible).
    profile = nil
    if config.models_configured? && !opts[:list_sessions]
      profile = config.resolve_model(opts[:model])
    end

    if profile
      opts[:base_url]         = profile[:url] || DEFAULT_BASE_URL
      opts[:model]           ||= profile[:model]
      opts[:token]            = profile[:token]
      opts[:num_ctx]          = profile[:num_ctx]
      opts[:reasoning_effort] = profile[:reasoning_effort]
      opts[:temperature]      = profile[:temperature]
      opts[:top_p]            = profile[:top_p]
    else
      opts[:base_url] ||= DEFAULT_BASE_URL
    end

    # Expose the configured model profiles so /models can list them and
    # /model can switch between them at runtime. The active model name is
    # tracked separately (options[:active_model]) for display and persistence.
    # It is stored as nil when the config default is active: a null value in
    # the session means "use whatever the config default is", so sessions
    # keep working even if the default model changes later.
    opts[:model_profiles] = config.models
    opts[:default_model]  = config.default_model
    explicit_model = !opts[:model].nil? && !opts[:model].to_s.strip.empty?
    default_key    = config.default_model
    using_default  = profile && !explicit_model && (default_key.nil? || (profile[:name] == default_key || profile[:model] == default_key))
    opts[:active_model]   = using_default ? nil : (profile ? (profile[:name] || profile[:model]) : opts[:model])

    # System prompt: --system-file > config 'system' > built-in default.
    if opts[:system_file]
      opts[:system] = File.read(opts[:system_file])
    else
      opts[:system] = config.system || Harness::SYSTEM_PROMPT
    end

    opts[:compact_recent]   ||= config.compact_recent_messages
    opts[:compact_max_size] = config.compact_max_size

    # Retry settings come from the config file (retry: count/delay).
    # Missing values fall back to the built-in defaults in harness.rb.
    opts[:retry_count] = config.retry_count
    opts[:retry_delay] = config.retry_delay

    unless opts[:model] || opts[:list_sessions]
      raise HarnessError, '-m / --model is required (or set default_model in the config)'
    end

    opts
  end

  # List saved sessions and exit (used by --list-sessions).
  def list_sessions_and_exit
    commands.list_sessions
    exit 0
  end

  def run
    @history.load

    puts "Harness ready. Type /help for commands, /exit to quit."
    puts "Model: #{harness.active_model_name} (@ #{@options[:base_url]})"
    puts "Working directory: #{@file_list.workdir}"
    puts "Tip: type a plain message (no /) to send it directly to the model."
    puts "Tip: paste multiline text directly, or end a line with a backslash (\\) " \
         "to continue."
    puts "Tip: a line starting with / is a command (executed immediately)."
    puts

    begin
      loop do
        show_file_list
        input = get_command
        break if input.nil?

        begin
          commands.handle(input)
        rescue Interrupt
          puts "\n  [interrupted]"
        rescue HarnessError => e
          puts "  [error] #{e.message}"
        rescue LLMError => e
          puts "  [LLM error] #{e.message}"
          puts "  (the prompt is kept in the session - type /retry to re-send it)"
        rescue ToolLoopError => e
          puts "  [tool loop] #{e.message}"
        rescue StandardError => e
          puts "  [unexpected error] #{e.class}: #{e.message}"
          puts e.backtrace.join("\n")
          puts "  (harness continues - type /exit to quit)"
        end

        break if commands.exiting?

        puts
        puts "-" * 40
        puts
      end
    rescue Interrupt
      # Ctrl+C at the prompt (or anywhere in the loop is waiting): treat as
      # a normal exit so that history and the session are still saved.
      puts "\n  [interrupted]"
    end

    @history.save
    id = auto_save_session
    puts "Goodbye."
    if id
      puts "Session saved as #{id} (#{harness.sessions_dir}/#{id}.json)."
      puts "Resume it later with: #{commands.resume_command(id)}"
    end
  end

  private

  # One-time migration of harness state that used to live scattered in the
  # working directory into the .harness directory:
  #   .sessions/          -> .harness/sessions/
  #   .harness_history    -> .harness/harness_history
  #   harness.log         -> .harness/harness.log
  # Existing files are moved (not copied) and only if the destination does
  # not exist yet. Best-effort: any failure is silently ignored.
  def migrate_legacy_state
    workdir = @file_list.workdir
    harness_dir = File.join(workdir, Harness::HARNESS_DIR)

    # .sessions/ -> .harness/sessions/
    old_sessions = File.join(workdir, '.sessions')
    new_sessions = File.join(harness_dir, 'sessions')
    if File.directory?(old_sessions) && !File.directory?(new_sessions)
      FileUtils.mkdir_p(harness_dir)
      FileUtils.mv(old_sessions, new_sessions)
    end

    # .harness_history -> .harness/harness_history
    old_history = File.join(workdir, '.harness_history')
    new_history = File.join(harness_dir, 'harness_history')
    if File.file?(old_history) && !File.exist?(new_history)
      FileUtils.mkdir_p(harness_dir)
      FileUtils.mv(old_history, new_history)
    end

    # harness.log -> .harness/harness.log
    old_log = File.join(workdir, 'harness.log')
    new_log = File.join(harness_dir, 'harness.log')
    if File.file?(old_log) && !File.exist?(new_log)
      FileUtils.mkdir_p(harness_dir)
      FileUtils.mv(old_log, new_log)
    end
  rescue StandardError
    # Migration is best-effort - never block the harness on it.
  end

  # Resume a saved session given via -r / --resume (best-effort: a missing
  # or ambiguous id raises HarnessError, which the entry point reports).
  def resume_from_cli
    id   = @options[:resume]
    path = @harness.resume_session(id)
    name = File.basename(path, '.json')
    puts "Resumed session #{name} (conversation and file list restored - see /session)."
  end

  # Auto-save the session on exit (best-effort). Returns the session id,
  # or nil if there was nothing to save or saving failed.
  def auto_save_session
    return nil if @harness.session.empty?

    @harness.save_session
  rescue StandardError => e
    puts "  [warning] could not auto-save session: #{e.message}"
    nil
  end

  def show_file_list
    if @file_list.empty?
      puts "(no access granted)"
      return
    end

    access = @file_list.accessible_paths
    labels = { both: 'Read + write', read: 'Read only', write: 'Write only' }

    %i[both read write].each do |mode|
      section = access[mode]
      files   = section[:files]
      dirs    = section[:dirs]
      flats   = section[:flat_dirs] || []
      next if files.empty? && dirs.empty? && flats.empty?

      puts "#{labels[mode]}:"
      unless files.empty?
        files.each_with_index do |f, i|
          puts "  #{i + 1}. #{@file_list.display_path(f)}"
        end
      end
      idx = files.size + 1
      unless dirs.empty?
        dirs.each_with_index do |d, i|
          puts "  #{idx + i}. #{@file_list.display_path(d)}/ (recursive)"
        end
      end
      idx += dirs.size
      unless flats.empty?
        flats.each_with_index do |d, i|
          puts "  #{idx + i}. #{@file_list.display_path(d)}/ (dir only)"
        end
      end
    end
  end

  # Reads a full command from stdin using Reline (the same library IRB uses).
  # Reline handles everything the old hand-rolled raw-mode code tried to do:
  #   * multiline input (a line ending in `\` continues; unbalanced quotes
  #     also continue),
  #   * pasted multiline text (bracketed paste - newlines inside a paste are
  #     inserted into the buffer instead of sending the input),
  #   * line editing (arrows, kill, word movement),
  #   * history (up/down arrows), persisted via HistoryManager.
  #
  # The block below is Reline's "keep reading" predicate. Two independent
  # termination logics coexist:
  #   * Quick slash-command detection: if the first line starts with "/"
  #     (first character, no stripping) and the last line does NOT end with
  #     "\", the input is presumed to be a command to be executed now
  #     (reading stops).
  #   * Paste detection: if the time between the last two linefeeds is
  #     shorter than PASTE_LF_INTERVAL, the input was pasted (not typed),
  #     so reading stops. Otherwise Reline keeps reading lines (backslash
  #     continuation, unbalanced quotes, etc.).
  #
  # Ctrl+C raises Interrupt (rescued in the run loop); Ctrl+D on an empty
  # line returns nil (EOF => quit).
  #
  # The input is kept as an array of lines in @last_lines so that future work
  # (cursor movement between lines, editing existing lines, inserting new
  # lines) can operate on the structured form rather than a flat string.
  PASTE_LF_INTERVAL = 0.05
  def get_command
    puts "[harness] > "
    $stdout.flush

    last_lf_time = nil

    text = Reline.readmultiline(
      "  ",
      add_history: true,
      rprompt: "  ") do |multiline_input|

      # Normalize Windows line endings: always work with a single \n.
      multiline_input = multiline_input.gsub("\r\n", "\n")

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      if multiline_input.start_with?("/")
        true
      elsif multiline_input.end_with?("\\\n")
        false
      else
        pasted = !last_lf_time || (now - last_lf_time) < PASTE_LF_INTERVAL
        last_lf_time = now
        !pasted
      end
    end

    return nil if text.nil?

    # Normalize Windows line endings: always work with a single \n.
    text = text.gsub("\r\n", "\n")

    @last_lines = text.split("\n", -1)
    text
  end
end