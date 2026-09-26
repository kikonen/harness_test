# frozen_string_literal: true

require_relative 'harness'
require_relative 'file_list'

# Handles slash-command dispatch and direct prompts.
# Extracted from CLI to keep the main class focused on the REPL loop,
# input handling, and lifecycle (init/exit).
class CommandHandler
  attr_reader :harness, :file_list, :options

  def initialize(harness, file_list, options)
    @harness   = harness
    @file_list = file_list
    @options   = options
    @exiting   = false
  end

  def exiting?
    @exiting
  end

  # Dispatch a single line of input. Slash-commands are matched by regex;
  # anything else is sent as a direct prompt to the model.
  def handle(input)
    input = input.strip
    return if input.empty?

    # Multiline slash commands are flattened: every linefeed (with
    # surrounding whitespace) becomes a single space, so the command
    # dispatch sees one line of text. Direct prompts keep their original
    # formatting (linefeeds preserved).
    input = input.gsub(/\s*\n\s*/, ' ') if input.start_with?('/')

    case input
    when /\A\/file\s+(.+?)(\s+(?:r|w|rw))?\Z/
      handle_file_command($1.strip, parse_grant_mode($2))
    when /\A\/dir\s+(.+?)(\s+(?:r|w|rw))?\Z/
      handle_dir_command($1.strip, parse_grant_mode($2))
    when /\A\/clear\Z/
      file_list.clear
      puts "Access list cleared."
    when /\A\/retry\Z/
      harness.retry
    when /\A\/session\Z/
      puts harness.session.summary
    when /\A\/session-clear\Z/
      harness.session.clear
      puts "Session cleared (conversation history reset)."
    when /\A\/compact\Z/
      result = harness.compact_session
      retained = result[:retained]
      puts "Session compacted: #{result[:before]} messages -> " \
           "#{result[:after]} messages (#{retained} recent retained)."
      puts
      puts "Summary:"
      puts result[:summary]
      puts
    when /\A\/reload\Z/
      harness.reload_rules
      puts "harness.md reloaded - project rules updated in the system prompt."
      puts
    when /\A\/save\Z/
      id = harness.save_session
      puts "Session saved as #{id} (#{harness.sessions_dir}/#{id}.json)"
      puts "Resume it later with: /resume #{id}"
      puts "  or from the command line: #{resume_command(id)}"
    when /\A\/resume\s+(.+)\Z/
      id = $1.strip
      path = harness.resume_session(id)
      puts "Session #{File.basename(path, '.json')} resumed."
      puts "  (conversation and file list restored - see /session)"
    when /\A\/sessions\Z/
      list_sessions
    when /\A\/help\Z/
      show_help
    when /\A\/exit\Z/
      @exiting = true
    when /\A\/tools\Z/
      show_tools
    when /\A\/models\Z/
      show_models
    when /\A\/model\Z/
      puts "Current model: #{harness.active_model_name} (@ #{options[:base_url]})"
      puts "List models with /models, switch with /model <name>."
    when /\A\/model\s+(.+)\Z/
      profile = harness.switch_model($1)
      name = profile[:name] || profile[:model]
      url  = profile[:url] || options[:base_url]
      puts "Switched to model: #{name} (#{profile[:model]} @ #{url})"
    when /\A\/.*\Z/
      puts "Unknown command: #{input}.\n----\nType /help for available commands."
    else
      run_direct_prompt(input)
    end
  end

  # Build the command line to resume a saved session in a new harness run.
  def resume_command(id)
    parts = ['ruby harness.rb', "-m #{options[:model]}", "--resume #{id}"]
    parts << "-d #{file_list.workdir}" unless file_list.workdir == Dir.pwd
    parts.join(' ')
  end

  # List saved sessions (newest first).
  def list_sessions
    sessions = harness.list_sessions
    if sessions.empty?
      puts "No saved sessions (#{harness.sessions_dir})."
      return
    end

    puts "Saved sessions (#{sessions.size}):"
    sessions.each do |s|
      puts "  #{s[:id]}  saved #{s[:saved_at].strftime('%Y-%m-%d %H:%M:%S')}  " \
           "#{s[:messages]} messages, #{s[:files]} file(s)  [workdir: #{s[:workdir]}]"
    end
    puts "Resume one with: /resume <id>  (or: ruby harness.rb -m <model> --resume <id>)"
  end

  private

  # -- /file command -------------------------------------------------------

  def handle_file_command(pattern, mode)
    if pattern =~ /[\\\*\?\[\]]/
      matches = Dir.glob(File.join(file_list.workdir, pattern)).sort
      if matches.empty?
        puts "No files match: #{pattern}"
      else
        added = 0
        matches.each do |path|
          shown = file_list.display_path(path)
          case file_list.add_file(path, mode)
          when :blocked
            puts "  [security] ✗ #{shown} (blocked: sensitive file)"
          when :duplicate
            puts "Already in list: #{shown}"
          when :added
            added += 1
            puts "Added: #{shown} (#{mode_label(mode)})"
          end
        end
        puts "Added #{added} file#{'s' if added != 1} matching #{pattern} (#{mode_label(mode)})."
      end
    else
      shown = file_list.display_path(pattern)
      case file_list.add_file(pattern, mode)
      when :blocked
        puts "  [security] ✗ #{shown} (blocked: sensitive file)"
      when :duplicate
        puts "Already in list: #{shown}"
      when :added
        puts "Added: #{shown} (#{mode_label(mode)})"
      end
    end
  end

  # -- /dir command --------------------------------------------------------

  def handle_dir_command(pattern, mode)
    if pattern =~ /[\\\*\?\[\]]/
      matches = Dir.glob(File.join(file_list.workdir, pattern)).sort
      dirs = matches.select { |p| File.directory?(p) }
      if dirs.empty?
        puts "No directories match: #{pattern}"
      else
        added = 0
        dirs.each do |path|
          shown = file_list.display_path(path)
          case file_list.add_tree(path, mode)
          when :blocked
            puts "  [security] ✗ #{shown} (blocked: sensitive directory)"
          when :duplicate
            puts "Already allowed: #{shown}/"
          when :added
            added += 1
            puts "Allowed: #{shown}/ (recursive, #{mode_label(mode)})"
          end
        end
        puts "Allowed #{added} director#{added == 1 ? 'y' : 'ies'} matching #{pattern} (#{mode_label(mode)})."
      end
    else
      shown = file_list.display_path(pattern)
      case file_list.add_tree(pattern, mode)
      when :blocked
        puts "  [security] ✗ #{shown} (blocked: sensitive directory)"
      when :duplicate
        puts "Already allowed: #{shown}/"
      when :added
        puts "Allowed: #{shown}/ (recursive, #{mode_label(mode)})"
      end
    end
  end

  # -- shared helpers ------------------------------------------------------

  # Parse the optional mode suffix of /file and /dir commands.
  # Accepts "r" (read), "w" (write), "rw" (both); defaults to :rw.
  def parse_grant_mode(suffix)
    case suffix&.strip
    when 'r' then :r
    when 'w' then :w
    when 'rw' then :rw
    else :rw
    end
  end

  # Human-readable label for a grant mode (used in command output).
  def mode_label(mode)
    case mode
    when :r then 'read'
    when :w then 'write'
    else 'read+write'
    end
  end

  # -- listing / display ---------------------------------------------------

  # List all available tools, grouped by namespace.
  def show_tools
    registry = harness.tool_registry
    puts "Available tools (#{registry.tools.size}):"
    registry.grouped.each do |ns, tools|
      puts "  #{ns}:"
      tools.each do |t|
        puts "    #{t.name} - #{t.description}"
      end
    end
  end

  # List the configured model profiles, marking the default and the active one.
  def show_models
    profiles = harness.model_profiles
    current  = harness.active_model_name

    if profiles.empty?
      puts "No model profiles configured."
      puts "Current model: #{current} (@ #{options[:base_url]})"
      return
    end

    default_name = harness.default_model_name

    puts "Configured models (#{profiles.size}):"
    profiles.each do |p|
      name   = p[:name] || p[:model]
      marks  = []
      marks << 'default' if default_name && (name == default_name || p[:model] == default_name)
      marks << 'active'  if name == current
      suffix = marks.empty? ? '' : "   [#{marks.join(', ')}]"
      puts "  #{name}  ->  #{p[:model]} @ #{p[:url] || CLI::DEFAULT_BASE_URL}#{suffix}"
    end
    puts
    puts "Switch with: /model <name>   (current: #{current})"
  end

  def show_help
    puts <<~HELP
      Available commands:
        /file <path> [r|w|rw]  Add a file to the allowed list (globs like src/*.rb work).
                               Mode: r = read only, w = write only, rw = both (default).
        /dir <path> [r|w|rw]   Allow a directory tree (all files under it, recursively).
                               Mode: r = read only, w = write only, rw = both (default).
        /clear         Remove all grants from the list

        /retry         Re-send the session message chain (after a failed request)
        /session       Show a summary of the current session
        /session-clear Reset the session (drop all conversation messages)
        /compact       Compact the session (summarize conversation to free context)
        /reload        Reload harness.md (project rules) into the system prompt
        /save          Save the session (conversation + access list) to .harness/sessions/
        /resume <id>   Resume a saved session by its id (see /sessions)
        /sessions      List saved sessions
        /tools         List available tools
        /models        List configured models (marks the default and active one)
        /model <name>  Switch the active model for this run (remembered in the session)
        /model         Show the currently active model
        /help          Show this help
        /exit          Exit the harness

      Read and write access are tracked separately. A read grant never implies
      write access, but a write grant implies read access to the same path.

      Direct prompt:
        Type any text (not starting with /) to send it directly to the model.
        The model can use file.read / file.write / file.patch etc. to access
        files. When it attempts to access a file that is not yet allowed,
        you will be prompted to grant the required access (read or write) at
        the granularity you prefer: the single file, the directory only
        (direct children), or the directory recursively (all subdirs).

      Session:
        Prompts are accumulated in a session, so the model sees the whole
        conversation. If a request to the LLM fails, the prompt stays in the
        session - use /retry to re-send the chain. /session shows a summary,
        /session-clear starts a fresh conversation. /compact summarizes the
        conversation to free up context window space.

      Project rules (harness.md):
        If a harness.md file exists in the working directory, its content
        is appended to the system prompt as "Project-Specific Rules".
        The file is auto-detected when its modification time changes
        (checked before each prompt). Use /reload to force a re-read.

      Saving / resuming sessions:
        The session (conversation history AND the access list) is
        auto-saved to .harness/sessions/ inside the working directory when
        the harness exits. /save stores it manually at any time.
        /sessions lists all saved sessions; /resume <id> restores the
        conversation and access list.

      Multiline input:
        * Paste: paste a multiline block directly at the prompt.
        * Type: end a line with a trailing backslash (\\) to continue.

      Keys:
        Ctrl+C   Cancel the current input (or interrupt a running request)
        Ctrl+D   Quit (on an empty prompt)
        Up/Down  Browse command history
    HELP
  end

  # -- direct prompt -------------------------------------------------------

  def run_direct_prompt(text)
    puts
    harness.run_prompt(text)
    puts
  end
end