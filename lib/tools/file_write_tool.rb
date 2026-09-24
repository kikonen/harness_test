# frozen_string_literal: true

require_relative '../tool'
require_relative '../file_list'
require 'fileutils'

class FileWriteTool < Tool
  def initialize(file_list, options)
    @file_list = file_list
    @options   = options
    super(
      name: 'file.write',
      description: 'Writes content to a file. Only files in the allowed list can be written. ' \
                   'Paths are relative to the harness working directory. ' \
                   'The content must be the COMPLETE file content. ' \
                   'If the file already exists you must also provide the sha256 digest of the file ' \
                   'as it was when you last read it (from file.read or file.sha); it is verified to ' \
                   'match the file on disk before writing, so the file is guaranteed to be the version ' \
                   'you based your edit on. For a brand-new file that does not exist yet, leave sha empty.',
      parameters: {
        type: 'object',
        properties: {
          path:    { type: 'string', description: 'Path to the file to write (relative to the working directory)' },
          content: { type: 'string', description: 'Complete content to write to the file' },
          sha:     { type: 'string', description: 'SHA-256 digest of the file as last read (from file.read or file.sha); must match the file on disk. Leave empty only when creating a new file that does not exist yet.' }
        },
        required: ['path', 'content', 'sha']
      }
    )
  end

  def execute(args)
    path    = @file_list.resolve(args['path'])
    shown   = @file_list.display_path(path)
    content = args['content']
    sha     = args['sha']

    unless @file_list.include?(path)
      puts "  [file.write] ✗ #{shown} (not in allowed list)"
      $stdout.flush
      return "error: file '#{shown}' is not in the allowed file list"
    end

    current_sha = FileList.sha256(path)

    if current_sha
      # File exists: the provided sha must match the file on disk.
      if sha.nil? || sha.empty?
        puts "  [file.write] ✗ #{shown} (missing sha)"
        $stdout.flush
        return "error: 'sha' is required for an existing file — pass the SHA-256 digest returned by file.read or file.sha"
      end

      unless current_sha == sha
        puts "  [file.write] ✗ #{shown} (sha mismatch)"
        $stdout.flush
        return "error: sha mismatch for '#{shown}' — the file has changed since you read it. " \
               "Current sha256: #{current_sha}. Re-read the file with file.read and retry."
      end
    end
    # If current_sha is nil the file does not exist yet (new file) — allow the write.

    if @options[:dry_run]
      puts "  [file.write] ~ #{shown} (dry run, #{content.length} chars)"
      $stdout.flush
      return "DRY RUN: would write #{content.length} chars to #{shown}"
    end

    dir = File.dirname(path)
    FileUtils.mkdir_p(dir) unless dir == '.'
    File.write(path, content)
    puts "  [file.write] ✓ #{shown} (#{content.length} chars)"
    $stdout.flush
    "ok: wrote #{content.length} chars to #{shown}"
  end
end
