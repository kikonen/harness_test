# frozen_string_literal: true

require_relative '../tool'
require_relative '../file_list'

class FileAddTool < Tool
  def initialize(file_list)
    @file_list = file_list
    super(
      name: 'file_add',
      description: 'Adds a file path to the allowed file list so it can be read or written. ' \
                   'Paths are relative to the harness working directory. ' \
                   'The file does not need to exist yet (useful for creating new files). ' \
                   'The user will be prompted for confirmation before the file is added.',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Path of the file to add to the allowed list (relative to the working directory)' }
        },
        required: ['path']
      }
    )
  end

  def execute(args)
    path  = @file_list.resolve(args['path'])
    shown = @file_list.display_path(path)

    # Security: sensitive files (e.g. .env*) are never allowed, no prompt.
    if @file_list.sensitive?(path)
      puts "  [file_add] ✗ #{shown} (blocked: sensitive file)"
      $stdout.flush
      return "error: file '#{shown}' is blocked and can never be added to the allowed file list"
    end

    if @file_list.include?(path)
      puts "  [file_add] = #{shown} (already in allowed list)"
      $stdout.flush
      return "ok: file '#{shown}' is already in the allowed file list"
    end

    # Determine whether the file already exists on disk.
    file_status = File.exist?(path) ? 'existing file' : 'new file (does not exist yet)'

    # Security: prompt the user for confirmation
    puts
    puts "  [file_add] ⚠  The model is requesting to add a file to the allowed list:"
    puts "              #{shown}  (#{file_status})"
    print  "              Allow? (y/n): "
    $stdout.flush

    answer = $stdin.gets
    answer = answer&.chomp&.downcase

    if answer == 'y' || answer == 'yes'
      @file_list.add(path)
      puts "  [file_add] ✓ #{shown} (#{file_status} — added to allowed list)"
      $stdout.flush
      "ok: file '#{shown}' (#{file_status}) has been added to the allowed file list"
    else
      puts "  [file_add] ✗ #{shown} (#{file_status} — denied by user)"
      $stdout.flush
      "error: user denied adding file '#{shown}' (#{file_status}) to the allowed file list"
    end
  end
end
