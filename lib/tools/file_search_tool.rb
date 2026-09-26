# frozen_string_literal: true

require_relative '../tool'
require_relative '../file_list'

# Searches for a regex pattern in files under the harness working directory.
# Returns matching lines with file path and line number (grep-like output).
# Sensitive files are excluded. The optional glob limits which files are
# searched.
class FileSearchTool < Tool
  MAX_RESULTS = 200
  MAX_FILES   = 5000

  def initialize(file_list)
    @file_list = file_list
    super(
      name: 'file.search',
      description: 'Searches for a regex pattern in files under the working directory (like grep). ' \
                   'Returns matching lines as "file:line: text". ' \
                   'Sensitive files are excluded. ' \
                   'Use the optional glob to limit which files are searched (e.g. "lib/**/*.rb").',
      parameters: {
        type: 'object',
        properties: {
          pattern: { type: 'string', description: 'Regular expression to search for (Ruby regex syntax)' },
          glob:    { type: 'string', description: 'Optional glob to limit which files to search (e.g. "lib/**/*.rb"). Defaults to all files.' },
          context: { type: 'integer', description: 'Optional number of context lines before/after each match (default 0)' }
        },
        required: ['pattern']
      }
    )
  end

  def execute(args)
    pattern_str = args['pattern'].to_s
    return 'error: usage: file.search(pattern)' if pattern_str.empty?

    regex = Regexp.new(pattern_str)
    glob  = (args['glob'] || '**/*').to_s.strip
    context = (args['context'] || 0).to_i

    expanded = File.expand_path(glob, @file_list.workdir)

    # Determine the base directory that needs read permission.
    # If stripping the glob changed the path, the result is already a dir.
    # Otherwise it's a file path and we need its parent.
    stripped = expanded.sub(/\/\*\*?\/.*\z/, '').sub(/\/\*\*?\z/, '')
    base_dir = (stripped != expanded) ? stripped : File.dirname(stripped)
    unless @file_list.can_list_dir?(base_dir)
      result = @file_list.grant_access(base_dir, :r)
      return "error: read access denied for directory '#{@file_list.display_path(base_dir)}'" \
             unless result == :granted
    end

    files = Dir.glob(expanded, File::FNM_DOTMATCH).select do |path|
      # Only readable files are searched (readable? also excludes sensitive
      # paths).
      File.file?(path) && @file_list.readable?(path)
    end.sort

    if files.size > MAX_FILES
      files = files.first(MAX_FILES)
    end

    matches = []
    files.each do |file|
      next unless File.readable?(file)

      content = nil
      begin
        content = File.read(file)
      rescue StandardError
        next
      end
      next if content.include?("\x00")  # skip binary files

      # Normalize CRLF to LF for consistent line splitting and output.
      content = content.gsub("\r\n", "\n")

      lines = content.split("\n")
      lines.each_with_index do |line, idx|
        if line.match?(regex)
          shown = @file_list.display_path(file)
          if context > 0
            start  = [idx - context, 0].max
            finish = [idx + context, lines.size - 1].min
            block  = lines[start..finish]
            matches << { file: shown, line: idx + 1, text: block.join("\n") }
          else
            matches << { file: shown, line: idx + 1, text: line }
          end
        end
      end
    end

    if matches.empty?
      puts "  [file.search] no matches for /#{pattern_str}/"
      $stdout.flush
      return "no matches for /#{pattern_str}/"
    end

    shown_matches = matches.first(MAX_RESULTS)
    puts "  [file.search] #{matches.size} match(es) for /#{pattern_str}/"
    $stdout.flush

    result = shown_matches.map do |m|
      if context > 0
        "#{m[:file]}:#{m[:line]}:\n#{m[:text]}"
      else
        "#{m[:file]}:#{m[:line]}: #{m[:text]}"
      end
    end.join("\n")

    if matches.size > MAX_RESULTS
      result += "\n... (truncated: showing first #{MAX_RESULTS} of #{matches.size} matches - narrow the pattern or glob)"
    end
    result
  end
end