# frozen_string_literal: true

require_relative '../tool'

class FileAddTool < Tool
  def initialize(allowed_files)
    @allowed_files = allowed_files
    super(
      name: 'file_add',
      description: 'Adds a file path to the allowed file list so it can be read or written. ' \
                   'The file does not need to exist yet (useful for creating new files). ' \
                   'The user will be prompted for confirmation before the file is added.',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Path of the file to add to the allowed list' }
        },
        required: ['path']
      }
    )
  end

  def execute(args)
    path = args['path']

    if @allowed_files.include?(path)
      puts "  [file_add] = #{path} (already in allowed list)"
      $stdout.flush
      return "ok: file '#{path}' is already in the allowed file list"
    end

    # Security: prompt the user for confirmation
    puts
    puts "  [file_add] ⚠  The model is requesting to add a file to the allowed list:"
    puts "              #{path}"
    print  "              Allow? (y/n): "
    $stdout.flush

    answer = $stdin.gets
    answer = answer&.chomp&.downcase

    if answer == 'y' || answer == 'yes'
      @allowed_files << path
      puts "  [file_add] ✓ #{path} (added to allowed list)"
      $stdout.flush
      "ok: file '#{path}' has been added to the allowed file list"
    else
      puts "  [file_add] ✗ #{path} (denied by user)"
      $stdout.flush
      "error: user denied adding file '#{path}' to the allowed file list"
    end
  end
end
