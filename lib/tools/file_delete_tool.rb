# frozen_string_literal: true

require_relative '../tool'
require_relative '../file_list'

# Deletes a file from disk and removes it from the allowed file list.
# The file must be in the allowed file list (added via file.add or the
# CLI). The user is prompted for confirmation before the file is deleted.
class FileDeleteTool < Tool
  def initialize(file_list, options)
    @file_list = file_list
    @options   = options
    super(
      name: 'file.delete',
      description: 'Deletes a file from disk and removes it from the allowed file list. ' \
                   'The file must be in the allowed file list — otherwise the deletion is rejected. ' \
                   'Paths are relative to the harness working directory. ' \
                   'The user will be prompted for confirmation before the file is deleted.',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Path of the file to delete (relative to the working directory); must be in the allowed file list' }
        },
        required: ['path']
      }
    )
  end

  def execute(args)
    path  = @file_list.resolve(args['path'])
    shown = @file_list.display_path(path)

    # The file must be in the allowed file list.
    unless @file_list.include?(path)
      puts "  [file.delete] ✗ #{shown} (not in allowed list)"
      $stdout.flush
      return "error: file '#{shown}' is not in the allowed file list"
    end

    # Security: sensitive files can never be deleted.
    if @file_list.sensitive?(path)
      puts "  [file.delete] ✗ #{shown} (blocked: sensitive file)"
      $stdout.flush
      return "error: file '#{shown}' is blocked and can never be deleted"
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

    # Security: prompt the user for confirmation.
    puts
    puts "  [file.delete] ⚠  The model is requesting to DELETE a file:"
    puts "                  #{shown}"
    print  "                  Delete? (y/n): "
    $stdout.flush

    answer = $stdin.gets
    answer = answer&.chomp&.downcase

    if answer == 'y' || answer == 'yes'
      File.delete(path)
      @file_list.remove(path)
      puts "  [file.delete] ✓ #{shown} (deleted, removed from allowed list)"
      $stdout.flush
      "ok: file '#{shown}' has been deleted and removed from the allowed file list"
    else
      puts "  [file.delete] ✗ #{shown} (denied by user)"
      $stdout.flush
      "error: user denied deleting file '#{shown}'"
    end
  end
end
