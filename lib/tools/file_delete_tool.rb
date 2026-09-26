# frozen_string_literal: true

require_relative '../tool'
require_relative '../file_list'

# Deletes a file from disk. The user is prompted for confirmation.
class FileDeleteTool < Tool
  def initialize(file_list, options)
    @file_list = file_list
    @options   = options
    super(
      name: 'file.delete',
      description: 'Deletes a file from disk. ' \
                   'Paths are relative to the harness working directory. ' \
                   'The user will be prompted for confirmation before the file is deleted.',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Path of the file to delete (relative to the working directory)' }
        },
        required: ['path']
      }
    )
  end

  def execute(args)
    path  = @file_list.resolve(args['path'])
    shown = @file_list.display_path(path)

    if @file_list.sensitive?(path)
      puts "  [file.delete] ✗ #{shown} (blocked: sensitive file)"
      $stdout.flush
      return "error: file '#{shown}' is blocked and can never be deleted"
    end

    # Deleting a file requires WRITE access (read alone is not enough).
    unless @file_list.writable?(path)
      result = @file_list.grant_access(path, :w)
      return "error: access denied for '#{shown}'" unless result == :granted
    end

    unless File.file?(path)
      puts "  [file.delete] ✗ #{shown} (file does not exist)"
      $stdout.flush
      return "error: file '#{shown}' does not exist on disk"
    end

    if @options[:dry_run]
      puts "  [file.delete] ~ #{shown} (dry run)"
      $stdout.flush
      return "DRY RUN: would delete #{shown}"
    end

    puts
    puts "  [file.delete] ⚠  The model is requesting to DELETE a file:"
    puts "                  #{shown}"
    puts "                  1) Confirm delete"
    puts "                  2) Deny"
    print  "                  Choice (1/2): "
    $stdout.flush

    answer = $stdin.gets
    answer = answer&.chomp&.strip

    if answer == '1'
      File.delete(path)
      puts "  [file.delete] ✓ #{shown} (deleted)"
      $stdout.flush
      "ok: file '#{shown}' has been deleted"
    else
      puts "  [file.delete] ✗ #{shown} (denied by user)"
      $stdout.flush
      "error: user denied deleting file '#{shown}'"
    end
  end
end