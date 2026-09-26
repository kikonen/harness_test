# frozen_string_literal: true

require_relative '../git_runner'

# Shows the working tree status (git status --short).
# Output is short/porcelain style: one line per changed file with its
# status code (e.g. " M lib/foo.rb", "?? new_file.txt").
class GitStatusTool < GitRunner
  def initialize(file_list)
    @file_list = file_list
    super(
      name: 'git.status',
      description: 'Shows the working tree status (like `git status --short`). ' \
                   'One line per changed file with its status code ' \
                   '(e.g. " M lib/foo.rb" = modified, "?? new.txt" = untracked). ' \
                   'Output is truncated to a line limit.',
      parameters: {
        type: 'object',
        properties: {
          limit: { type: 'integer', description: "Optional maximum number of output lines (default #{DEFAULT_LIMITS[:status]}, max #{MAX_LIMIT})" }
        }
      }
    )
  end

  def execute(args)
    limit = clamp_limit(args['limit'], DEFAULT_LIMITS[:status])

    result = run_git('git', 'status', '--short', '--branch')
    if result[:status] != 0
      return git_error('status', result, 'check that you are inside a git repository')
    end

    text, _truncated = truncate_output(result[:stdout], limit)
    puts "  [git.status] ✓ (#{text.lines.size} line(s))"
    $stdout.flush
    text.strip.empty? ? 'working tree is clean' : text
  end
end
