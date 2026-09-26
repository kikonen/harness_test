# frozen_string_literal: true

require_relative '../tool'
require_relative '../file_list'

class FileReadTool < Tool
  def initialize(file_list)
    @file_list = file_list
    super(
      name: 'file.read',
      description: 'Reads the contents of a file. ' \
                   'Paths are relative to the harness working directory. ' \
                   'Returns the SHA-256 digest of the file along with its full contents. ' \
                   'Pass the returned sha back to file.write to prove the file has not changed since you read it.',
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

    unless @file_list.readable?(path)
      result = @file_list.grant_access(path, :r)
      return "error: access denied for '#{shown}'" unless result == :granted
    end

    unless File.file?(path)
      puts "  [file.read] ✗ #{shown} (not found)"
      $stdout.flush
      return "error: file not found: #{shown}"
    end

    content = File.read(path)
    sha     = FileList.sha256(path)

    # Normalize CRLF to LF so the LLM always sees clean line endings.
    content = content.gsub("\r\n", "\n")

    puts "  [file.read] ✓ #{shown} (sha256: #{sha})"
    $stdout.flush

    "sha256: #{sha}\n---\n#{content}"
  end
end