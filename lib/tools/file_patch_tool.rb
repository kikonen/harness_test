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
#   2. The SHA-256 matches (file unchanged since read)
#   3. Each hunk's old-side lines (context + deletions) are found in the file
#
# Robustness:
#   - Hunks are located by SEARCHING for their old-side lines, starting at the
#     declared line number and expanding outward, then falling back to a
#     full-file search. Small line-number errors in the diff therefore do not
#     cause a failure.
#   - Hunk line COUNTS in the @@ header are treated as hints, not facts: a
#     wrong count (a very common model error) must not fail the patch. The
#     hunk body is recounted and trusted over the header; excess trailing
#     context lines are trimmed from the body.
#   - If the full old-side does not match anywhere (e.g. the model included
#     extra or wrong context lines), matching degrades to progressively
#     shorter old-side patterns — context lines are dropped one by one from
#     the hunk ends, NEVER '-' / '+' edit lines — until a match is found.
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
      result = @file_list.grant_access(path)
      return "error: access denied for '#{shown}'" unless result == :granted
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

  # True for real unified-diff header lines: exactly '---' or '+++', or
  # followed by a space (e.g. '--- a/path'). A bare start_with?('---') would
  # also swallow hunk body deletion lines (which start with '-'), so the
  # stricter check is required.
  def header_line?(line)
    line == '---' || line == '+++' ||
      line.start_with?('--- ') || line.start_with?('+++ ')
  end

  # Parses a unified diff into an array of hunk hashes:
  #   { old_start:, old_count:, new_count:, lines: [...] }
  # where each line is [type, text] with type being ' ', '-', or '+'.
  # Returns nil if the diff is malformed.
  #
  # Lenient parsing rules:
  #   - Blank lines inside a hunk are treated as context lines (models often
  #     omit the leading space of a context line).
  #   - The line counts in the @@ header are treated as hints, not facts:
  #     they are RECOUNTED from the actual hunk body (a wrong count is one of
  #     the most common model errors) and the recounted values are used.
  #     Excess trailing context lines are trimmed only when the body exceeds
  #     the header count; a body shorter than the header is still accepted,
  #     since the body is the more trustworthy source.
  def parse_unified_diff(diff)
    # Normalize the diff itself to LF so parsing is consistent.
    diff = diff.gsub("\r\n", "\n")
    lines = diff.split("\n")
    hunks = []
    i     = 0

    # Skip the --- / +++ header lines (and any leading blank lines).
    while i < lines.size
      line = lines[i]
      if header_line?(line) || line.strip.empty?
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

        # Reconcile with the header counts (see #reconcile_counts): trim
        # excess trailing context lines, never required '-' / '+' lines.
        hunk_lines = reconcile_counts(hunk_lines, old_count, new_count)
        return nil if hunk_lines.nil?

        # Use the RECOUNTED counts as the source of truth — they describe
        # what the hunk body actually contains.
        recounted_old = hunk_lines.count { |t, _| t == ' ' || t == '-' }
        recounted_new = hunk_lines.count { |t, _| t == ' ' || t == '+' }

        hunks << {
          old_start: old_start,
          old_count: recounted_old,
          new_count: recounted_new,
          lines:     hunk_lines
        }
      else
        i += 1
      end
    end

    hunks
  end

  # Reconciles a parsed hunk body with the counts declared in its header.
  # The counts are treated as hints (a wrong count is a common model error),
  # so mismatches are resolved in favor of the BODY:
  #   - Body LONGER than the header: trim excess trailing context lines
  #     (blank-line artifacts are the most common cause of count drift).
  #   - Body SHORTER than the header: accept it as-is — the header is likely
  #     just wrong, and the body still carries the real edit.
  # Returns nil only when the body is empty (nothing to apply at all).
  def reconcile_counts(hunk_lines, old_count, new_count)
    old_seen = hunk_lines.count { |t, _| t == ' ' || t == '-' }
    new_seen = hunk_lines.count { |t, _| t == ' ' || t == '+' }

    lines = hunk_lines.dup

    # Only trim when the body exceeds the header count, and only trailing
    # context lines — never '-' / '+' lines, which carry the actual edit.
    while (old_seen > old_count || new_seen > new_count) && lines.last[0] == ' '
      old_seen -= 1
      new_seen -= 1
      lines.pop
    end

    lines.empty? ? nil : lines
  end

  # Applies a single hunk to the lines array. Returns the new lines array,
  # or nil if the hunk does not apply cleanly.
  #
  # Strategy: locate the hunk by matching its old-side lines (context +
  # deletions) against the file, preferring the declared position. If the
  # full old-side does not match anywhere, progressively SHORTER old-side
  # patterns are tried — context lines are dropped one at a time from the
  # hunk ends (trailing first), while all '-' / '+' edit lines are always
  # kept. The corresponding new-side context lines are dropped in the same
  # way, so the actual edit is never altered.
  def apply_hunk(lines, hunk)
    old_side = hunk[:lines].select { |t, _| t == ' ' || t == '-' }.map { |_, text| text }
    new_side = hunk[:lines].select { |t, _| t == ' ' || t == '+' }.map { |_, text| text }
    return nil if old_side.empty? && new_side.empty?

    expected = hunk[:old_start] - 1  # 0-based

    # Pure insertion hunk (no old-side lines at all): insert at the
    # declared position, anchoring on a new-side context line if one exists
    # so the insertion lands in the right place.
    if old_side.empty?
      anchor = new_side.find { |t| t != '' }
      pos    = anchor ? find_position(lines, [anchor], expected) : nil
      pos    = [[expected, 0].max, lines.size].min if pos.nil?
      return lines[0...pos] + new_side + lines[pos..]
    end

    # How many context lines may be dropped without touching edit lines.
    ctx_count = hunk[:lines].count { |t, _| t == ' ' }
    (0..ctx_count).each do |drop|
      # Trailing context is dropped first; once all trailing context is
      # gone, leading context is dropped as well.
      back_drop  = [drop, ctx_count].min
      front_drop = drop - back_drop

      kept    = drop_hunk_context(hunk[:lines], front_drop, back_drop)
      pattern = kept.select { |t, _| t == ' ' || t == '-' }.map { |_, text| text }
      next if pattern.empty?

      pos = find_position(lines, pattern, expected)
      next if pos.nil?

      new_used = kept.select { |t, _| t == ' ' || t == '+' }.map { |_, text| text }
      return lines[0...pos] + new_used + lines[pos + pattern.size..]
    end

    nil
  end

  # Returns the hunk lines with `front_drop` leading and `back_drop` trailing
  # CONTEXT lines removed. '-' / '+' edit lines are always preserved.
  def drop_hunk_context(hunk_lines, front_drop, back_drop)
    return hunk_lines if front_drop.zero? && back_drop.zero?

    ctx_total = hunk_lines.count { |t, _| t == ' ' }
    ctx_index = 0
    kept      = []
    hunk_lines.each do |type, text|
      if type == ' '
        ctx_index += 1
        next if ctx_index <= front_drop
        next if ctx_index > (ctx_total - back_drop)
      end

      kept << [type, text]
    end
    kept
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
