# frozen_string_literal: true

require_relative '../git_runner'

# Shows a unified diff (git diff).
# Without a path: working tree + index vs HEAD (staged and unstaged).
# With a path:    the diff for that file only.
# A revision (e.g. "HEAD~1", a commit hash, or a tag) is optional; when
# given, the diff is against that revision instead of the working tree.
class GitDiffTool < GitRunner
  def initialize(file_list)
    @file_list = file_list
    super(
      name: 'git.diff',
      description: 'Shows a unified diff from git (like `git diff`). ' \
                   'Without a path: all working-tree changes vs HEAD. ' \
                   'With a path: only that file. Optional revision to diff against ' \
                   '(e.g. "HEAD~1" or a commit hash). Output is truncated to a line limit.',
      parameters: {
        type: 'object',
        properties: {
          path:    { type: 'string', description: 'Optional file path (relative to the working directory) to restrict the diff to one file' },
          revision: { type: 'string', description: 'Optional revision to diff against (e.g. "HEAD~1", a commit hash, or a tag). Defaults to the working tree vs HEAD' },
          limit:   { type: 'integer', description: "Optional maximum number of output lines (default #{DEFAULT_LIMITS[:diff]}, max #{MAX_LIMIT})" }
        }
      }
    )
  end

  def execute(args)
    limit = clamp_limit(args['limit'], DEFAULT_LIMITS[:diff])

    cmd = %w[git diff]
    cmd << args['revision'] if args['revision'] && !args['revision'].to_s.strip.empty?

    if args['path'] && !args['path'].to_s.strip.empty?
      shown = @file_list.display_path(args['path'])
      rel   = relative_to_workdir(args['path'])
      cmd  += %w[--] + [rel]  # "--" protects paths starting with "-"
      result = run_git(*cmd)
      if result[:status] != 0
        return git_error("diff #{shown}", result, 'check the path and that the file exists in the repository')
      end

      text, _truncated = truncate_output(result[:stdout], limit)
      puts "  [git.diff] ✓ #{shown} (#{text.lines.size} line(s))"
      $stdout.flush
      return text.empty? ? "no changes for #{shown}" : text
    end

    result = run_git(*cmd)
    if result[:status] != 0
      return git_error('diff', result, 'check that the revision exists')
    end

    text, _truncated = truncate_output(result[:stdout], limit)
    puts "  [git.diff] ✓ working tree (#{text.lines.size} line(s))"
    $stdout.flush
    text.empty? ? 'working tree is clean (no changes vs HEAD)' : text
  end
end
