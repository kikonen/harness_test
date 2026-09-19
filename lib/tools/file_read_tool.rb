# frozen_string_literal: true

require_relative '../tool'

class FileReadTool < Tool
  def initialize(allowed_files)
    @allowed_files = allowed_files
    super(
      name: 'file_read',
      description: 'Reads the contents of a file. Only files in the allowed list can be read.',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Path to the file to read' }
        },
        required: ['path']
      }
    )
  end

  def execute(args)
    path = args['path']
    unless @allowed_files.include?(path)
      puts "  [file_read] ✗ #{path} (not in allowed list)"
      $stdout.flush
      return "error: file '#{path}' is not in the allowed file list"
    end
    unless File.file?(path)
      puts "  [file_read] ✗ #{path} (not found)"
      $stdout.flush
      return "error: file not found: #{path}"
    end
    puts "  [file_read] ✓ #{path}"
    $stdout.flush
    File.read(path)
  end
end
