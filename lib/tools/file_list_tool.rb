# frozen_string_literal: true

require_relative '../tool'
require_relative '../file_list'

# Lists files matching a glob pattern under the harness working directory.
# The pattern must reside inside the workdir (no escaping via ".." or
# absolute paths). Listing requires READ access to the directory being
# listed; sensitive files and files without read grants are excluded.
class FileListTool < Tool
  # Safety cap so a too-broad pattern cannot flood the context.
  MAX_RESULTS = 500

  def initialize(file_list)
    @file_list = file_list
    super(
      name: 'file.list',
      description: 'Lists files matching a glob pattern under the harness working directory. ' \
                   'The pattern must reside inside the working directory (e.g. "lib/**/*.rb"). ' \
                   'Sensitive files are excluded from the results.',
      parameters: {
        type: 'object',
        properties: {
          pattern: { type: 'string', description: 'Glob pattern relative to the working directory (e.g. "lib/**/*.rb")' }
        },
        required: ['pattern']
      }
    )
  end

  def execute(args)
    pattern = args['pattern'].to_s.strip
    return 'error: usage: file.list(pattern)' if pattern.empty?

    expanded = File.expand_path(pattern, @file_list.workdir)

    # Listing a directory requires read access to that directory.
    base_dir = File.dirname(expanded.sub(/\/\*\*?\/.*\z/, '').sub(/\/\*\*?\z/, ''))
    unless @file_list.can_list_dir?(base_dir)
      result = @file_list.grant_access(base_dir, :r)
      return "error: read access denied for directory '#{@file_list.display_path(base_dir)}'" \
             unless result == :granted
    end

    matches = Dir.glob(expanded, File::FNM_DOTMATCH).select do |path|
      File.file?(path) && @file_list.readable?(path)
    end.sort

    if matches.empty?
      puts "  [file.list] (no files match '#{pattern}')"
      $stdout.flush
      return "no files match '#{pattern}' under #{@file_list.workdir}"
    end

    shown = matches.first(MAX_RESULTS).map { |p| @file_list.display_path(p) }
    puts "  [file.list] #{matches.size} file(s) match '#{pattern}'"
    $stdout.flush

    result = shown.map { |p| "- #{p}" }.join("\n")
    if matches.size > MAX_RESULTS
      result += "\n... (truncated: showing first #{MAX_RESULTS} of #{matches.size} files - narrow the pattern)"
    end
    result
  end
end