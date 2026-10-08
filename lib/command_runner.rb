# frozen_string_literal: true

require 'open3'
require 'bundler'
require 'timeout'

require_relative 'tool'
require_relative 'command_allowlist'
require_relative 'ui/dialog'

# Shared consent + execution logic for shell commands (issue #129).
#
# Used by both callers of this harness's shell execution:
#   * Tools::RunCommandTool - LLM-driven, runs inside a Task thread. The
#     confirmation dialog is routed through the task to the MAIN THREAD
#     (ui: nil), status lines go over Tool.puts, and the formatted result
#     string is returned to the model.
#   * CommandHandler bang syntax (`! cmd`) - user-typed, runs on the main
#     thread directly. The dialog is served in place (perform_direct on
#     the console) and the output is printed verbatim by the caller.
#
# SAFETY MODEL:
#   - The FULL command string is displayed to the user before anything runs;
#     explicit "Allow" required unless the prefix is in the list.
#   - "Always allow <prefix>" saves a grant (issue #69, multi-select
#     per-prefix issue #102). The list is SEPARATE per caller (issue #129):
#     the tool writes .harness/allowed_commands.yml, bang syntax writes
#     .harness/shell_commands.yml - one never auto-approves for the other.
#   - Commands run under a timeout (default 60 s, cap 300 s) so a hung
#     process can never block the session indefinitely.
#   - Output is truncated to a line limit (default 200, max 5000); that
#     limit exists because the tool path returns output into the LLM
#     context window - the bang path prints it as-is.
class CommandRunner
  DEFAULT_TIMEOUT = 60    # seconds
  MAX_TIMEOUT     = 300   # hard cap
  DEFAULT_LIMIT   = 200   # output lines
  MAX_LIMIT       = 5000  # hard cap

  TOOL_TITLE = "The model is requesting to run a shell command:\n" \
               "$ %s\ncwd: %s (timeout: %ss)"
  BANG_TITLE = "Run shell command:\n$ %s\ncwd: %s (timeout: %ss)"

  # Which allowlist file this runner consults and writes.
  LISTS = { tool: CommandAllowlist::TOOL_FILENAME,
            shell: CommandAllowlist::SHELL_FILENAME }.freeze

  # Shown as a dialog note when no "Always allow" option is offered because
  # the command contains constructs that can never be auto-approved.
  # Normally replaced by a tailored note naming the specific unsafe
  # construct (issue #102).
  UNSAFETY_NOTE = 'UNSAFE: contains shell constructs that cannot be auto-approved.'

  # label:     bracket used in status lines ('run.command' or 'shell')
  # title_fmt: sprintf-style dialog title (TOOL_TITLE / BANG_TITLE)
  # ui:        UI::Console for direct main-thread dialogs (nil = Task thread)
  # list:      :tool (default) or :shell - selects the allowlist file
  def initialize(file_list, options, label: 'run.command', title_fmt: TOOL_TITLE,
                 ui: nil, list: :tool)
    @file_list = file_list
    @options   = options
    @label     = label
    @title_fmt = title_fmt
    @ui        = ui
    @allowlist = CommandAllowlist.new(file_list.workdir,
                                      file: LISTS.fetch(list.to_sym))
  end

  # Run a command after any required user consent. Returns the formatted
  # result string: "exit code: N (Xs)" + stdout/stderr sections, or an
  # "error: ..." string on denial / failure.
  def run(command, cwd: nil, timeout: DEFAULT_TIMEOUT, limit: DEFAULT_LIMIT)
    command = command.to_s.strip
    return "error: 'command' must be a non-empty shell command" if command.empty?

    dir   = cwd ? @file_list.resolve(cwd) : @file_list.workdir
    shown = @file_list.display_path(dir)
    unless File.directory?(dir)
      return "error: directory '#{shown}' does not exist"
    end

    timeout = [timeout.to_i, DEFAULT_TIMEOUT].max
    timeout = [timeout, MAX_TIMEOUT].min
    limit   = limit.to_i
    limit   = DEFAULT_LIMIT if limit <= 0
    limit   = [limit, MAX_LIMIT].min

    # Auto-approve when the command prefix is in the user's allowlist.
    if @allowlist.allowed?(command)
      status("✓ auto-approved (allowlist): #{command}")
      return execute(command, dir, shown, timeout, limit)
    end

    # Not in allowlist - ask the user. One "Always allow" option per
    # candidate prefix length of each segment (issue #102); candidates
    # already subsumed by a stored grant are filtered out up front so
    # the dialog only shows prefixes that would actually change
    # behaviour when saved (issue #94).
    all_candidates = CommandAllowlist.extract_prefix_options(command)
    prefixes       = @allowlist.filter_uncovered(all_candidates)
    options        = [UI::Dialog::Option.new(title: 'Allow', value: :allow)]

    prefixes.each do |p|
      options << UI::Dialog::Option.new(
        title: "Always allow '#{p}'",
        # Unique per prefix so a multi-select answer maps back to the
        # exact prefixes chosen (issue #102).
        value: { always_allow: p }
      )
    end

    # UNSAFETY_NOTE only when the command itself contains unsafe
    # constructs (all_candidates empty). If candidates existed but were
    # all filtered out because a stored grant already covers them, the
    # command is fine - no scary note. When unsafe, name the specific
    # construct instead of a generic list (issue #102).
    if all_candidates.empty?
      label = CommandAllowlist.classify_unsafe(command)
      note  = label ? "UNSAFE: #{label} cannot be auto-approved" : UNSAFETY_NOTE
    end

    dialog = UI::Dialog.new(
      title: format(@title_fmt, command, shown, timeout),
      options: options,
      note: note,
      # Multi-select lets the user save several prefixes in one line
      # (e.g. "2 4") - issue #102. Only meaningful when there is at
      # least one grantable prefix.
      multi_select: !prefixes.empty?
    )
    # Route the dialog: within a Task thread use show(ui: nil) so the
    # drain loop services it on the main thread (issue #40); on the
    # main thread (bang syntax) serve it in place on the console.
    choice = @ui ? dialog.perform_direct(ui: @ui) : dialog.show(ui: nil)

    result = handle_choice(choice)
    return result[:denial] if result[:denied]

    if result[:saved] && !result[:saved].empty?
      result[:saved].each { |p| @allowlist.add(p) }
      status("✓ always-allowed: #{result[:saved].join(', ')} (saved to allowlist)")
    end

    execute(command, dir, shown, timeout, limit)
  end

  private

  # Console status line. Within a Task thread goes over Tool.puts (event
  # queue, rendered by the drain loop); on the main thread writes to @ui.
  def status(msg)
    text = "  [#{@label}] #{msg}"
    if defined?(Task) && Task.current
      Tool.puts(text)
    elsif @ui
      @ui.puts(text)
    end
  end

  # Interpret the raw dialog answer. Returns a hash with :denied and
  # :denial (the error string to return) when the user cancelled, and
  # :saved (array of prefixes to persist) when one or more "Always
  # allow" options were picked. A bare :allow - including one mixed
  # into a multi-select line, which is contradictory - runs the command
  # without saving anything.
  def handle_choice(choice)
    # A [:cancelled, 'reason'] pair means the user cancelled with a one-line reason.
    if choice.is_a?(Array) && choice.size == 2 && choice[1].is_a?(String)
      return denial('user denied executing the command', note: choice[1]) \
             if choice[0] == UI::Dialog::CANCEL_VALUE
      return {}
    end

    # Multi-select returns an array of values (e.g. [hash1, hash2]).
    # Single selection returns the bare value.
    values = choice.is_a?(Array) ? choice : [choice]
    return denial('user denied executing the command') \
           if values.include?(UI::Dialog::CANCEL_VALUE)

    # A mix of plain "Allow" with one or more grants is ambiguous: the
    # user wants to run the command now, so we honor the Allow and save
    # nothing (a bare grant selection saves those prefixes). Only
    # hash-valued options carry a prefix to persist.
    if values.include?(:allow)
      return { saved: [] }
    end

    saved = values.select { |v| v.is_a?(Hash) && v[:always_allow] }
                .map { |v| v[:always_allow] }
    { saved: saved }
  end

  def denial(message, note: nil)
    if note
      status("✗ denied by user (note: \"#{note}\")")
    else
      status('✗ denied by user')
    end
    { denied: true,
      denial: Tool.denial_error("error: #{message}", note ? { note: note } : nil) }
  end

  # Runs the command (after any required confirmation) and formats the
  # result. Raises Timeout::Error when the command exceeds its timeout.
  def execute(command, dir, shown, timeout, limit)
    if @options&.dig(:dry_run)
      status("~ #{command} (dry run)")
      return "DRY RUN: would execute '#{command}' in #{shown}"
    end

    started = Time.now
    stdout, stderr, result = run_in_shell(command, dir, timeout)
    elapsed = (Time.now - started).round(2)
    code    = result.exitstatus

    out            = truncate(stdout, limit)[0]
    err            = truncate(stderr, limit)[0] unless stderr.strip.empty?

    if code.zero?
      status("✓ #{command} (exit 0, #{elapsed}s)")
    else
      status("✗ #{command} (exit #{code}, #{elapsed}s)")
    end

    msg = "exit code: #{code} (#{elapsed}s)\n"
    msg += "--- stdout ---\n#{out}\n" if out.strip != ''
    msg += "--- stderr ---\n#{err}\n" if err&.strip&.!= ''
    msg
  rescue Timeout::Error
    status("✗ #{command} (timed out after #{timeout}s)")
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
    # Plain split drops a trailing empty element from a final newline,
    # so line counts match what the user actually sees.
    lines = text.split("\n")
    return [text, false] if lines.size <= limit

    dropped = lines.size - limit
    notice  = "... (output truncated: #{dropped} more line(s) omitted - " \
              "raise 'limit' or narrow the command to see them)"
    [lines.first(limit).join("\n") + "\n" + notice, true]
  end
end
