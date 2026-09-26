# frozen_string_literal: true

require_relative '../git_runner'

# Shows the commit history (git log).
# Output is a compact one-line-per-commit format (hash, author, date,
# subject) by default. Options let the caller narrow the range (max
# commits), filter by file path, or include the full diff per commit.
class GitLogTool < GitRunner
  def initialize(file_list)
    @file_list = file_list
    super(
      name: 'git.log',
      description: 'Shows the commit history (like `git log`). ' \
                   'Compact one-line-per-commit output by default ' \
                   '(short hash, author, date, subject). ' \
                   'Use max_count to limit the number of commits, ' \
                   'path to filter to one file, or show_diff for full diffs. ' \
                   'Output is truncated to a line limit.',
      parameters: {
        type: 'object',
        properties: {
          max_count: { type: 'integer', description: 'Maximum number of commits to show (default 30)' },
          path:      { type: 'string',  description: 'Optional file path (relative to the working directory) to filter the log to commits touching that file' },
          show_diff: { type: 'boolean', description: 'Include the full diff for each commit (much longer output)' },
          limit:     { type: 'integer', description: "Optional maximum number of output lines (default #{DEFAULT_LIMITS[:log]}, max #{MAX_LIMIT})" }
        }
      }
    )
  end

  def execute(args)
    limit = clamp_limit(args['limit'], DEFAULT_LIMITS[:log])

    max_count = args['max_count'].to_i
    max_count = 30 if max_count <= 0

    cmd = %w[git log]
    cmd += ["--max-count=#{max_count}"]

    if args['show_diff']
      # Full diff per commit (much longer output, but that is what was asked).
      cmd << '--patch'
    else
      # Compact one-line format: short hash | author | date | subject.
      cmd << '--pretty=format:%h | %an | %ad | %s'
      cmd << '--date=short'
    end

    if args['path'] && !args['path'].to_s.strip.empty?
      shown = @file_list.display_path(args['path'])
      rel   = relative_to_workdir(args['path'])
      cmd   += %w[--] + [rel]  # "--" protects paths starting with "-"
      result = run_git(*cmd)
      if result[:status] != 0
        return git_error("log #{shown}", result, 'check the path and that it exists in the repository history')
      end

      text, _truncated = truncate_output(result[:stdout], limit)
      puts "  [git.log] ✓ #{shown} (#{text.lines.size} line(s))"
      $stdout.flush
      return text.empty? ? "no commits touching #{shown}" : text
    end

    result = run_git(*cmd)
    if result[:status] != 0
      return git_error('log', result, 'check that you are inside a git repository with at least one commit')
    end

    text, _truncated = truncate_output(result[:stdout], limit)
    puts "  [git.log] ✓ (#{text.lines.size} line(s))"
    $stdout.flush
    text.empty? ? 'no commits found' : text
  end
end