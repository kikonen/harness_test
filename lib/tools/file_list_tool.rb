# frozen_string_literal: true

require_relative '../tool'
require_relative '../file_list'

# Lists files matching a glob pattern under the harness working directory.
# The pattern must reside inside the workdir (no escaping via ".." or
# absolute paths). Sensitive files are excluded from the results.
# Matched files are NOT added to the allowed file list — the model must
# still use dir.allow (with user confirmation) to work with a file.
class FileListTool < Tool
  # Safety cap so a too-broad pattern cannot flood the context.
  MAX_RESULTS = 500

  def initialize(file_list)
    @file_list = file_list
    super(
      name: 'file.list',
      description: 'Lists files matching a glob pattern under the harness working directory. ' \
                   'The pattern must reside inside the working directory (e.g. "lib/**/*.rb"). ' \
                   'Sensitive files are excluded from the results. ' \
                   'Matched files are NOT added to the allowed file list — use dir.allow to allow a directory you want to work with.',
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

    # The pattern must reside under the working directory.
    expanded = File.expand_path(pattern, @file_list.workdir)
    unless @file_list.within_workdir?(expanded)
      return "error: pattern '#{pattern}' must reside under the working directory (#{@file_list.workdir})"
    end

    matches = Dir.glob(expanded, File::FNM_DOTMATCH).select do |path|
      File.file?(path) && !@file_list.sensitive?(path)
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
      result += "\n... (truncated: showing first #{MAX_RESULTS} of #{matches.size} files — narrow the pattern)"
    end
    result
  end
end
