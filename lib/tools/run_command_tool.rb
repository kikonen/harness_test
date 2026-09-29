# frozen_string_literal: true

require 'open3'
require 'bundler'
require 'timeout'

require_relative '../tool'
require_relative '../dialog'
require_relative '../command_allowlist'

# Executes a shell command in the harness working directory.
#
# SAFETY MODEL:
#   - The FULL command string is displayed to the user before anything runs.
#   - The user must explicitly select "Allow" at an interactive dialog;
#     any other choice denies execution.
#   - "Always allow <prefix>" saves the command prefix to the user's
#     allowlist (.harness/allowed_commands.yml) so future commands with
#     the same prefix skip the dialog (issue #69).
#   - Commands run under a timeout (default 60 s, hard cap 300 s) so a
#     hung process can never block the session indefinitely.
#   - Output is truncated to a line limit (default 200, max 5000) because
#     it goes into the LLM context window.
module Tools

  class RunCommandTool < Tool
    DEFAULT_TIMEOUT = 60    # seconds
    MAX_TIMEOUT     = 300   # hard cap for the `timeout` parameter
    DEFAULT_LIMIT   = 200   # output lines
    MAX_LIMIT       = 5000  # hard cap for the `limit` parameter

    def initialize(file_list, options)
      @file_list    = file_list
      @options      = options
      @allowlist    = CommandAllowlist.new(file_list.workdir)
      super(
        name: 'run.command',
        description: 'Executes a shell command in the harness working directory. ' \
                     'Most commands require explicit user confirmation ("Allow") ' \
                     'before they run; previously approved command prefixes are ' \
                     'auto-approved. Use this for tasks no dedicated tool covers ' \
                     '(running tests, build steps, one-off scripts). Output is ' \
                     'captured and returned with the exit code.',
        parameters: {
          type: 'object',
          properties: {
            command: {
              type: 'string',
              description: 'The full shell command to execute (e.g. "bundle exec rspec spec/foo_spec.rb"). ' \
                           'Shown verbatim to the user for confirmation unless its prefix is already approved.'
            },
            cwd: {
              type: 'string',
              description: 'Optional working directory for the command (relative to the harness ' \
                           'working directory). Defaults to the working directory itself.'
            },
            timeout: {
              type: 'integer',
              description: "Optional timeout in seconds (default #{DEFAULT_TIMEOUT}, max #{MAX_TIMEOUT})."
            },
            limit: {
              type: 'integer',
              description: "Optional maximum number of output lines returned (default #{DEFAULT_LIMIT}, max #{MAX_LIMIT})."
            }
          },
          required: ['command']
        }
      )
    end

    def execute(args)
      command = args['command'].to_s.strip
      if command.empty?
        return "error: 'command' must be a non-empty shell command"
      end

      dir   = args['cwd'] ? @file_list.resolve(args['cwd']) : @file_list.workdir
      shown = @file_list.display_path(dir)
      unless File.directory?(dir)
        return "error: directory '#{shown}' does not exist"
      end

      timeout = [args['timeout'].to_i, DEFAULT_TIMEOUT].max
      timeout = [timeout, MAX_TIMEOUT].min
      limit   = args['limit'].to_i
      limit   = DEFAULT_LIMIT if limit <= 0
      limit   = [limit, MAX_LIMIT].min

      # Auto-approve when the command prefix is in the user's allowlist.
      if @allowlist.allowed?(command)
        puts "  [run.command] ✓ auto-approved (allowlist): #{command}"
        $stdout.flush
        return run_command(command, dir, shown, timeout, limit)
      end

      # Not in allowlist - ask the user.
      prefix = CommandAllowlist.extract_prefix(command)
      choice = Dialog.new(
        title: "The model is requesting to run a shell command:\n" \
               "$ #{command}\ncwd: #{shown} (timeout: #{timeout}s)",
        options: [
          Dialog::Option.new(title: 'Allow', value: :allow),
          Dialog::Option.new(
            title: "Always allow '#{prefix}'",
            description: 'Future commands starting with this prefix will run without asking.',
            value: :always_allow
          )
        ],
        note_on_cancel_only: true
      ).show

      # Dialog returns: bare value, or [value, note] when a note is attached.
      # With note_on_cancel_only, notes only appear on the cancel choice.
      value = choice.is_a?(Array) ? choice[0] : choice
      note  = choice.is_a?(Array) ? choice[1] : nil

      if value == Dialog::CANCEL_VALUE
        # Cancel - may carry a note (issue #79/#78).
        if note
          puts "  [run.command] ✗ denied by user (note: \"#{note}\")"
        else
          puts "  [run.command] ✗ denied by user"
        end
        $stdout.flush
        return Tool.denial_error('error: user denied executing the command',
                                { status: :denied, note: note })
      end

      if value == :always_allow
        @allowlist.add(prefix)
        puts "  [run.command] ✓ always-allowed: '#{prefix}' (saved to allowlist)"
        $stdout.flush
      end

      run_command(command, dir, shown, timeout, limit)
    end

    private

    # Runs the command (after any required confirmation) and formats the
    # result. Raises Timeout::Error when the command exceeds its timeout.
    def run_command(command, dir, shown, timeout, limit)
      if @options[:dry_run]
        puts "  [run.command] ~ #{command} (dry run)"
        $stdout.flush
        return "DRY RUN: would execute '#{command}' in #{shown}"
      end

      started = Time.now
      stdout, stderr, status = run_in_shell(command, dir, timeout)
      elapsed = (Time.now - started).round(2)
      code    = status.exitstatus

      out, truncated = truncate(stdout, limit)
      err            = truncate(stderr, limit)[0] unless stderr.strip.empty?

      if code.zero?
        puts "  [run.command] ✓ #{command} (exit 0, #{elapsed}s)"
      else
        puts "  [run.command] ✗ #{command} (exit #{code}, #{elapsed}s)"
      end
      $stdout.flush

      msg = "exit code: #{code} (#{elapsed}s)\n"
      msg += "--- stdout ---\n#{out}\n" if out.strip != ''
      msg += "--- stderr ---\n#{err}\n" if err&.strip&.!= ''
      msg += "\n(output truncated to #{limit} lines)" if truncated
      msg
    rescue Timeout::Error
      puts "  [run.command] ✗ #{command} (timed out after #{timeout}s)"
      $stdout.flush
      "error: command timed out after #{timeout}s"
    end

    # Runs the command in a shell with the inherited bundler env stripped
    # (Bundler.with_unbundled_env). The harness may have been started from a
    # shell polluted by ANOTHER project's bundler setup (BUNDLE_GEMFILE,
    # RUBYOPT=-rbundler/setup, GEM_HOME, ...); without this, any `bundle exec`
    # in the command would resolve against the wrong Gemfile and fail with
    # cryptic "can't find executable" errors. Stripped, `bundle exec` falls
    # back to the CWD's Gemfile - which is what callers expect.
    def run_in_shell(command, dir, timeout)
      Bundler.with_unbundled_env do
        Timeout.timeout(timeout) do
          Open3.capture3('sh', '-c', command, chdir: dir)
        end
      end
    end

    # Truncate text to `limit` lines (from the top), appending a notice with
    # the number of dropped lines. Returns [text, truncated?].
    def truncate(text, limit)
      lines = text.split("\n", -1)
      return [text, false] if lines.size <= limit

      dropped = lines.size - limit
      notice  = "... (output truncated: #{dropped} more line(s) omitted - " \
                "raise 'limit' or narrow the command to see them)"
      [lines.first(limit).join("\n") + "\n" + notice, true]
    end
  end
end
