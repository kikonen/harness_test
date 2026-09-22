# frozen_string_literal: true

require_relative '../tool'
require_relative '../file_list'

class FileReadTool < Tool
  def initialize(file_list)
    @file_list = file_list
    super(
      name: 'file_read',
      description: 'Reads the contents of a file. Only files in the allowed list can be read. ' \
                   'Paths are relative to the harness working directory. ' \
                   'Returns the SHA-256 digest of the file along with its full contents. ' \
                   'Pass the returned sha back to file_write to prove the file has not changed since you read it.',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Path to the file to read (relative to the working directory)' }
        },
        required: ['path']
      }
    )
  end

  def execute(args)
    path = @file_list.resolve(args['path'])
    shown = @file_list.display_path(path)
    unless @file_list.include?(path)
      puts "  [file_read] ✗ #{shown} (not in allowed list)"
      $stdout.flush
      return "error: file '#{shown}' is not in the allowed file list"
    end
    unless File.file?(path)
      puts "  [file_read] ✗ #{shown} (not found)"
      $stdout.flush
      return "error: file not found: #{shown}"
    end

    content = File.read(path)
    sha     = FileList.sha256(path)

    puts "  [file_read] ✓ #{shown} (sha256: #{sha})"
    $stdout.flush

    "sha256: #{sha}\n---\n#{content}"
  end
end
