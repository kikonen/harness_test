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
#   3. Each hunk applies cleanly (context lines match at the expected position)
#
# This is safer than a full file rewrite because:
#   - The model only specifies the changed regions
#   - Context lines are verified, preventing misapplied patches
#   - The SHA check protects against concurrent modifications
class FilePatchTool < Tool
  def initialize(file_list, options)
    @file_list = file_list
    @options   = options
    super(
      name: 'file.patch',
      description: 'Applies a standard unified diff patch to a file. ' \
                   'The diff must be in unified diff format (--- / +++ / @@ hunks). ' \
                   'Only files in the allowed list can be patched. ' \
                   'You must provide the sha256 digest of the file as last read (from file.read or file.sha). ' \
                   'Each hunk is verified against the file content — context lines must match. ' \
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
        puts "  [file.patch] ✗ #{shown} (hunk at line #{hunk[:old_start]} did not apply)"
        $stdout.flush
        return "error: hunk at old-line #{hunk[:old_start]} did not apply cleanly — " \
               "context lines do not match. Re-read the file with file.read and adjust the diff."
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
        old_seen   = 0
        new_seen   = 0

        while i < lines.size
          hline = lines[i]

          if hline.start_with?('@@')
            break  # next hunk
          end

          if hline.start_with?('-')
            hunk_lines << ['-', hline[1..]]
            old_seen += 1
          elsif hline.start_with?('+')
            hunk_lines << ['+', hline[1..]]
            new_seen += 1
          elsif hline.start_with?(' ')
            hunk_lines << [' ', hline[1..]]
            old_seen += 1
            new_seen += 1
          elsif hline.start_with?('\\')
            # "\ No newline at end of file" — ignore
          else
            # A blank line inside a hunk is a context line with empty content.
            # But it could also be the end of the hunk. We treat it as context
            # only if we still expect more lines.
            if old_seen < old_count || new_seen < new_count
              hunk_lines << [' ', '']
              old_seen += 1
              new_seen += 1
            else
              break
            end
          end

          i += 1
          break if old_seen >= old_count && new_seen >= new_count
        end

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

  # Applies a single hunk to the lines array. Returns the new lines array,
  # or nil if the hunk does not apply cleanly.
  #
  # The hunk's old_start is 1-based (standard unified diff).
  def apply_hunk(lines, hunk)
    old_start = hunk[:old_start]  # 1-based
    idx       = old_start - 1     # 0-based index into lines

    # Verify the hunk fits within the file.
    return nil if idx < 0 || idx >= lines.size + 1

    # Walk through the hunk lines, verifying context and '-' lines match.
    pos = idx
    new_lines = []

    # Copy lines before the hunk.
    new_lines.concat(lines[0...idx])

    hunk[:lines].each do |type, text|
      case type
      when ' '
        # Context line: must match the file.
        if pos >= lines.size || lines[pos] != text
          return nil
        end
        new_lines << text
        pos += 1
      when '-'
        # Deletion: must match the file.
        if pos >= lines.size || lines[pos] != text
          return nil
        end
        pos += 1
        # (line is not added to new_lines)
      when '+'
        # Addition: insert into new content.
        new_lines << text
      end
    end

    # Copy remaining lines after the hunk.
    new_lines.concat(lines[pos..] || [])

    new_lines
  end
end
