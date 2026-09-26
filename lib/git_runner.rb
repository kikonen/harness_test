# frozen_string_literal: true

require 'open3'

require_relative 'tool'

# Shared base class for the git.* tools.
#
# Handles the common concerns of running git commands:
#   - Commands run via Open3.capture3 in the harness working directory,
#     so they operate on the repository containing that directory.
#   - The pager is disabled (GIT_PAGER=cat + GIT_TERMINAL_PROMPT=0) so
#     output never hangs on a TTY prompt and is captured verbatim.
#   - Color is disabled (GIT_CONFIG_COUNT / color.ui=false) so the output
#     is plain text, suitable for LLM consumption.
#   - Output is truncated to a per-tool line limit with a clear notice,
#     because git log / diff can be very long.
#   - Path arguments are always passed after "--" by the individual tools,
#     so paths starting with "-" are never mistaken for options.
class GitRunner < Tool
  # Default output line limits per command (overridable via a tool's
  # `limit` parameter). Kept small on purpose: the output goes into the
  # LLM context window.
  DEFAULT_LIMITS = {
    diff:   500,
    show:   1000,
    status: 200,
    log:    200,
    apply:  100
  }.freeze

  MAX_LIMIT = 5000  # hard cap for the `limit` parameter

  def execute(args)
    raise NotImplementedError, "#{self.class}#execute not implemented"
  end

  protected

  # Run a git command in the working directory.
  # Returns { status:, stdout:, stderr: } (stdout/stderr as strings).
  def run_git(*cmd)
    env = {
      'GIT_PAGER'           => 'cat',
      'PAGER'               => 'cat',
      'GIT_TERMINAL_PROMPT' => '0',
      'GIT_CONFIG_COUNT'    => '1',
      'GIT_CONFIG_KEY_0'    => 'color.ui',
      'GIT_CONFIG_VALUE_0'  => 'never'
    }

    stdout, stderr, status = Open3.capture3(env, *cmd, chdir: workdir)
    { status: status.exitstatus, stdout: stdout, stderr: stderr }
  end

  # Working directory of the harness (the repository root is found by
  # git itself from here).
  def workdir
    @file_list.workdir
  end

  # Resolve a user-supplied path relative to the working directory.
  def resolve_path(path)
    @file_list.resolve(path)
  end

  # Path relative to the working directory (repo root) - the form git
  # expects after "--" in diff/show/log path filters.
  def relative_to_workdir(path)
    abs    = resolve_path(path)
    prefix = "#{workdir}/"
    abs.start_with?(prefix) ? abs.sub(prefix, '') : abs
  end

  # Clamp a user-supplied `limit` argument: non-positive values fall back
  # to the default, anything above MAX_LIMIT is capped.
  def clamp_limit(value, default)
    n = value.to_i
    return default if n <= 0
    [n, MAX_LIMIT].min
  end

  # Truncate long output to `limit` lines (from the top), appending a
  # notice with the number of dropped lines. Returns [text, truncated?].
  def truncate_output(text, limit)
    lines = text.split("\n", -1)
    return [text, false] if lines.size <= limit

    dropped = lines.size - limit
    notice  = "... (output truncated: #{dropped} more line(s) omitted - " \
              "narrow the query or raise 'limit' to see them)"
    [lines.first(limit).join("\n") + "\n" + notice, true]
  end

  # Build the standard "error:" result from a failed git command.
  def git_error(tag, result, hint = nil)
    detail = result[:stderr].strip.empty? ? result[:stdout].strip : result[:stderr].strip
    msg = "error: git #{tag} failed (exit #{result[:status]}): #{detail.lines.first&.strip || 'no error message'}"
    msg += ". #{hint}" if hint
    puts "  [#{tag}] ✗ #{msg}"
    $stdout.flush
    msg
  end
end