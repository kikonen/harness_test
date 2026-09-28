# frozen_string_literal: true

require_relative '../git_runner'

# Searches the git commit history for commits whose diffs contain a given
# pattern (like `git log -G`). Useful for finding when a piece of code,
# a function name, or a configuration value was added or removed.
module Tools

  class GitGrepTool < GitRunner
    # Default number of commits to scan when searching history.
    DEFAULT_MAX_COUNT = 300

    def initialize(file_list)
      @file_list = file_list
      super(
        name: 'git.grep',
        description: 'Searches the commit history for commits whose diffs contain a pattern ' \
                     '(like `git log -G`). Use it to find when code, a symbol, or a value was ' \
                     'added or removed. Each matching commit is shown with its metadata and ' \
                     'the diff lines that matched the pattern. ' \
                     "Use max_count to bound how far back to look (default #{DEFAULT_MAX_COUNT}), " \
                     'path to restrict to one file, or ignore_case for a case-insensitive match. ' \
                     "Output is truncated to a line limit (default #{DEFAULT_LIMITS[:grep]}).",
        parameters: {
          type: 'object',
          properties: {
            pattern:     { type: 'string',  description: "Regular expression to search for in the diffs of commits (required, e.g. a function name or a config key)" },
            path:        { type: 'string',  description: 'Optional file path (relative to the working directory) to restrict the search to commits touching that file' },
            ignore_case: { type: 'boolean', description: 'Case-insensitive match (default false)' },
            max_count:   { type: 'integer', description: "Maximum number of commits to scan (default #{DEFAULT_MAX_COUNT})" },
            limit:       { type: 'integer', description: "Optional maximum number of output lines (default #{DEFAULT_LIMITS[:grep]}, max #{MAX_LIMIT})" }
          },
          required: ['pattern']
        }
      )
    end

    def execute(args)
      pattern = args['pattern'].to_s.strip
      if pattern.empty?
        return "error: 'pattern' is required and must not be empty"
      end

      limit     = clamp_limit(args['limit'], DEFAULT_LIMITS[:grep])
      max_count = args['max_count'].to_i
      max_count = DEFAULT_MAX_COUNT if max_count <= 0

      cmd = %w[git log]
      cmd += ["--max-count=#{max_count}"]
      cmd << '-G' + pattern
      cmd << '--regexp-ignore-case' if args['ignore_case']
      # One commit block: header line, then the matching diff lines only.
      cmd << '--pretty=format:%h | %an | %ad | %s'
      cmd << '--date=short'

      if args['path'] && !args['path'].to_s.strip.empty?
        shown = @file_list.display_path(args['path'])
        rel   = relative_to_workdir(args['path'])
        cmd   += %w[--] + [rel]  # "--" protects paths starting with "-"
      end

      result = run_git(*cmd)
      if result[:status] != 0
        return git_error("grep '#{pattern}'", result, 'check that you are inside a git repository with at least one commit')
      end

      text, _truncated = truncate_output(result[:stdout], limit)
      puts "  [git.grep] ✓ #{text.lines.size} line(s)"
      $stdout.flush
      text.empty? ? "no commits found matching '#{pattern}'" : text
    end
  end
end
