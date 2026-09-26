# frozen_string_literal: true

require_relative '../git_runner'

# Shows the changes made in a specific commit (git show).
# By default shows the commit message, file stats, and its full diff.
# With a path, only the diff for that file is shown (done via
# `git diff rev^..rev -- path`, because `git show` itself does not
# accept path filters; on the root commit it falls back to a diff
# against the empty tree).
# A revision may be a commit hash, tag, branch name, or "HEAD~N".
class GitShowTool < GitRunner
  # The well-known empty tree object - used as the "before" side when
  # showing the root commit (which has no parent).
  EMPTY_TREE = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'.freeze

  def initialize(file_list)
    @file_list = file_list
    super(
      name: 'git.show',
      description: 'Shows the changes made in a specific commit (like `git show`). ' \
                   'Displays the commit message, file stats, and its full diff. ' \
                   'With a path, only the diff for that file is shown. ' \
                   'Output is truncated to a line limit.',
      parameters: {
        type: 'object',
        properties: {
          revision: { type: 'string', description: 'Commit hash, tag, branch name, or relative ref (e.g. "HEAD", "HEAD~1"). Defaults to HEAD' },
          path:     { type: 'string', description: 'Optional file path (relative to the working directory) to restrict the diff to one file' },
          limit:    { type: 'integer', description: "Optional maximum number of output lines (default #{DEFAULT_LIMITS[:show]}, max #{MAX_LIMIT})" }
        }
      }
    )
  end

  def execute(args)
    limit = clamp_limit(args['limit'], DEFAULT_LIMITS[:show])

    revision = args['revision'].to_s.strip
    revision = 'HEAD' if revision.empty?

    # With a path: `git show` does not accept path filters, so use
    # `git diff rev^..rev -- path` instead (same result for the file).
    if args['path'] && !args['path'].to_s.strip.empty?
      shown = @file_list.display_path(args['path'])
      rel   = relative_to_workdir(args['path'])

      result = run_git('git', 'diff', "#{revision}^..#{revision}", '--', rel)
      # Root commit has no parent - retry against the empty tree.
      if result[:status] != 0
        result = run_git('git', 'diff', EMPTY_TREE, revision, '--', rel)
      end

      if result[:status] != 0
        return git_error("show #{shown}", result, "check that '#{revision}' is a valid revision and the path exists")
      end

      text, _truncated = truncate_output(result[:stdout], limit)
      puts "  [git.show] ✓ #{shown} @ #{revision} (#{text.lines.size} line(s))"
      $stdout.flush
      return text.empty? ? "no changes for #{shown} in #{revision}" : text
    end

    result = run_git('git', 'show', '--stat', revision)
    if result[:status] != 0
      return git_error('show', result, "check that '#{revision}' is a valid revision")
    end

    text, _truncated = truncate_output(result[:stdout], limit)
    puts "  [git.show] ✓ #{revision} (#{text.lines.size} line(s))"
    $stdout.flush
    text.empty? ? "no changes in #{revision}" : text
  end
end