# frozen_string_literal: true

require_relative '../tool'
require_relative '../file_list'

# Applies a standard unified diff patch to a file.
# The model provides the file path, a unified diff, and the SHA-256 digest
# of the file as last read. The patch is applied to the file content and the
# result is written back.
#
# Unified diff format (standard):
#   --- a/path
#   +++ b/path
#   @@ -start,count +start,count @@
#    context line
#   -removed line
#   +added line
#
# The tool verifies:
#   1. The file is in the allowed list
#   2. The SHA-256 matches (file unchanged since read)
#   3. Each hunk's old-side lines (context + deletions) are found in the file
#
# Robustness:
#   - Hunks are located by SEARCHING for their old-side lines, starting at the
#     declared line number and expanding outward, then falling back to a
#     full-file search. Small line-number errors in the diff therefore do not
#     cause a failure.
#   - Blank lines inside a hunk are treated as context lines (a common model
#     output quirk: the leading space of a context line is omitted).
#   - Failure messages report the first mismatching line so the model can
#     self-correct.
#
# This is safer than a full file rewrite because:
#   - The model only specifies the changed regions
#   - Context lines are verified, preventing misapplied patches
#   - The SHA check protects against concurrent modifications
class FilePatchTool < Tool
  SEARCH_WINDOW = 50  # lines to search above/below the declared position

  def initialize(file_list, options)
    @file_list = file_list
    @options   = options
    super(
      name: 'file.patch',
      description: 'Applies a standard unified diff patch to a file. ' \
                   'The diff must be in unified diff format (--- / +++ / @@ hunks). ' \
                   'Only files in the allowed list can be patched. ' \
                   'You must provide the sha256 digest of the file as last read (from file.read or file.sha). ' \
                   'Hunk line numbers are used as a hint — the hunk is located by matching its context lines, ' \
                   'so small line-number errors are tolerated. ' \
                   'Use this for targeted edits instead of rewriting the entire file with file.write.',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Path to the file to patch (relative to the working directory)' },
          diff: { type: 'string', description: 'Unified diff to apply (standard format with --- / +++ / @@ hunks)' },
          sha:  { type: 'string', description: 'SHA-256 digest of the file as last read (from file.read or file.sha); must match the file on disk' }
        },
        required: ['path', 'diff', 'sha']
      }
    )
  end

  def execute(args)
    path = @file_list.resolve(args['path'])
    shown = @file_list.display_path(path)
    diff  = args['diff'].to_s
    sha   = args['sha'].to_s

    unless @file_list.include?(path)
      puts "  [file.patch] ✗ #{shown} (not in allowed list)"
      $stdout.flush
      return "error: file '#{shown}' is not in the allowed file list"
    end

    unless File.file?(path)
      puts "  [file.patch] ✗ #{shown} (file does not exist)"
      $stdout.flush
      return "error: file '#{shown}' does not exist on disk"
    end

    current_sha = FileList.sha256(path)

    if sha.empty?
      puts "  [file.patch] ✗ #{shown} (missing sha)"
      $stdout.flush
      return "error: 'sha' is required — pass the SHA-256 digest returned by file.read or file.sha"
    end

    unless current_sha == sha
      puts "  [file.patch] ✗ #{shown} (sha mismatch)"
      $stdout.flush
      return "error: sha mismatch for '#{shown}' — the file has changed since you read it. " \
             "Current sha256: #{current_sha}. Re-read the file with file.read and retry."
    end

    hunks = parse_unified_diff(diff)
    if hunks.nil?
      puts "  [file.patch] ✗ #{shown} (invalid diff format)"
      $stdout.flush
      return "error: could not parse the diff — expected unified diff format with @@ hunks"
    end
    if hunks.empty?
      puts "  [file.patch] ✗ #{shown} (no hunks in diff)"
      $stdout.flush
      return "error: the diff contains no hunks (no @@ ... @@ sections)"
    end

    content = File.read(path)

    # Detect and normalize line endings so context matching works
    # regardless of whether the file uses CRLF (Windows) or LF.
    crlf    = content.include?("\r\n")
    content = content.gsub("\r\n", "\n") if crlf
    lines   = content.split("\n")

    # Apply hunks in reverse order so line numbers from earlier hunks
    # are not invalidated by later ones.
    applied = 0
    hunks.reverse_each do |hunk|
      result = apply_hunk(lines, hunk)
      if result.nil?
        diag = diagnose(lines, hunk)
        puts "  [file.patch] ✗ #{shown} (hunk at line #{hunk[:old_start]} did not apply)"
        $stdout.flush
        return "error: hunk at old-line #{hunk[:old_start]} did not apply cleanly. #{diag} " \
               "Re-read the file with file.read and adjust the diff so its context lines match exactly."
      end
      lines   = result
      applied += 1
    end

    new_content = lines.join("\n")
    # Restore the original line-ending style.
    new_content = new_content.gsub("\n", "\r\n") if crlf

    if @options[:dry_run]
      puts "  [file.patch] ~ #{shown} (dry run, #{applied} hunk(s) applied)"
      $stdout.flush
      return "DRY RUN: would apply #{applied} hunk(s) to #{shown}"
    end

    File.write(path, new_content)
    puts "  [file.patch] ✓ #{shown} (#{applied} hunk(s) applied)"
    $stdout.flush
    "ok: applied #{applied} hunk(s) to #{shown}"
  end

  private

  # Parses a unified diff into an array of hunk hashes:
  #   { old_start:, old_count:, new_count:, lines: [...] }
  # where each line is [type, text] with type being ' ', '-', or '+'.
  # Returns nil if the diff is malformed.
  #
  # Lenient parsing rules:
  #   - Blank lines inside a hunk are treated as context lines (models often
  #     omit the leading space of a context line).
  #   - If the parsed line counts disagree with the hunk header, the excess
  #     context lines are trimmed from the end of the hunk (a common artifact
  #     of trailing blank lines) instead of failing.
  def parse_unified_diff(diff)
    # Normalize the diff itself to LF so parsing is consistent.
    diff = diff.gsub("\r\n", "\n")
    lines = diff.split("\n")
    hunks = []
    i     = 0

    # Skip the --- / +++ header lines (and any leading blank lines).
    while i < lines.size
      line = lines[i]
      if line.start_with?('---') || line.start_with?('+++') || line.strip.empty?
        i += 1
        next
      end
      break
    end

    while i < lines.size
      line = lines[i]

      if line.start_with?('@@')
        # Parse hunk header: @@ -old_start[,old_count] +new_start[,new_count] @@
        match = line.match(/\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/)
        return nil unless match

        old_start = match[1].to_i
        old_count = match[2] ? match[2].to_i : 1
        new_count = match[4] ? match[4].to_i : 1

        i += 1
        hunk_lines = []

        # Consume hunk body until the next hunk header or a line that is not
        # part of the hunk (e.g. a trailing "diff --git" line).
        while i < lines.size
          hline = lines[i]
          break if hline.start_with?('@@')

          if hline.start_with?('-')
            hunk_lines << ['-', hline[1..]]
          elsif hline.start_with?('+')
            hunk_lines << ['+', hline[1..]]
          elsif hline.start_with?(' ')
            hunk_lines << [' ', hline[1..]]
          elsif hline.start_with?('\\')
            # "\ No newline at end of file" — ignore
          elsif hline.strip.empty?
            # Blank line: treat as a context line with empty content.
            hunk_lines << [' ', '']
          else
            break  # not part of the hunk
          end
          i += 1
        end

        # Reconcile with the header counts: trim excess trailing context lines
        # (blank-line artifacts) if the body is longer than the header says.
        hunk_lines = reconcile_counts(hunk_lines, old_count, new_count)
        return nil if hunk_lines.nil?

        hunks << {
          old_start: old_start,
          old_count: old_count,
          new_count: new_count,
          lines:     hunk_lines
        }
      else
        i += 1
      end
    end

    hunks
  end

  # If the parsed body has more lines than the header counts allow, trim
  # trailing context lines until the counts match. Returns nil if the body
  # has FEWER lines than required (unfixable).
  def reconcile_counts(hunk_lines, old_count, new_count)
    old_seen = hunk_lines.count { |t, _| t == ' ' || t == '-' }
    new_seen = hunk_lines.count { |t, _| t == ' ' || t == '+' }

    return nil if old_seen < old_count || new_seen < new_count

    lines = hunk_lines.dup
    while (old_seen > old_count || new_seen > new_count) && lines.last[0] == ' '
      old_seen -= 1
      new_seen -= 1
      lines.pop
    end

    (old_seen == old_count && new_seen == new_count) ? lines : nil
  end

  # Applies a single hunk to the lines array. Returns the new lines array,
  # or nil if the hunk does not apply cleanly.
  #
  # The hunk is located by searching for its old-side lines (context +
  # deletions), starting at the declared 1-based old_start and expanding
  # outward, then falling back to a full-file search.
  def apply_hunk(lines, hunk)
    old_side = hunk[:lines].select { |t, _| t == ' ' || t == '-' }.map { |_, text| text }
    new_side = hunk[:lines].select { |t, _| t == ' ' || t == '+' }.map { |_, text| text }
    return nil if old_side.empty? && new_side.empty?

    expected = hunk[:old_start] - 1  # 0-based

    pos = find_position(lines, old_side, expected)
    return nil if pos.nil?

    lines[0...pos] + new_side + lines[pos + old_side.size..]
  end

  # Finds the 0-based index where old_side matches lines, preferring the
  # position closest to expected. Returns nil if not found.
  def find_position(lines, old_side, expected)
    return 0 if old_side.empty?

    # 1. Exact position first.
    return expected if matches_at?(lines, expected, old_side)

    # 2. Expand a window around the expected position.
    (1..SEARCH_WINDOW).each do |d|
      [expected - d, expected + d].each do |pos|
        next unless pos >= 0 && pos + old_side.size <= lines.size
        return pos if matches_at?(lines, pos, old_side)
      end
    end

    # 3. Full-file fallback (bounded by file size).
    (0...[lines.size - old_side.size + 1, 1].max).each do |pos|
      next if (pos - expected).abs <= SEARCH_WINDOW
      return pos if matches_at?(lines, pos, old_side)
    end

    nil
  end

  def matches_at?(lines, pos, old_side)
    old_side.each_with_index do |text, k|
      return false if lines[pos + k].nil? || lines[pos + k] != text
    end
    true
  end

  # Produces a short diagnostic for a failed hunk: the first old-side line
  # that does not match at the declared position.
  def diagnose(lines, hunk)
    old_side = hunk[:lines].select { |t, _| t == ' ' || t == '-' }.map { |_, text| text }
    pos      = hunk[:old_start] - 1

    old_side.each_with_index do |text, k|
      actual = lines[pos + k]
      if actual.nil?
        return "Expected line #{pos + k + 1} to be #{text.inspect}, but the file ends at line #{lines.size}."
      end
      if actual != text
        return "Expected line #{pos + k + 1} to be #{text.inspect}, but found #{actual.inspect}."
      end
    end

    'The hunk could not be located anywhere in the file — its context lines do not match.'
  end
end
