# frozen_string_literal: true

require_relative '../tool'
require_relative '../file_list'

class FileShaTool < Tool
  def initialize(file_list)
    @file_list = file_list
    super(
      name: 'file_sha',
      description: 'Returns the SHA-256 digest of a file without its contents. ' \
                   'Paths are relative to the harness working directory. ' \
                   'Use this to verify a file is up to date (i.e. unchanged since you last read it) ' \
                   'before writing, or to obtain the sha required by file_write. ' \
                   'Only files in the allowed list can be checked.',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Path to the file to hash (relative to the working directory)' }
        },
        required: ['path']
      }
    )
  end

  def execute(args)
    path  = @file_list.resolve(args['path'])
    shown = @file_list.display_path(path)
    unless @file_list.include?(path)
      puts "  [file_sha] ✗ #{shown} (not in allowed list)"
      $stdout.flush
      return "error: file '#{shown}' is not in the allowed file list"
    end
    unless File.file?(path)
      puts "  [file_sha] ✗ #{shown} (not found)"
      $stdout.flush
      return "error: file not found: #{shown}"
    end

    sha = FileList.sha256(path)
    puts "  [file_sha] ✓ #{shown} (sha256: #{sha})"
    $stdout.flush
    "sha256: #{sha}"
  end
end
