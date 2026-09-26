# frozen_string_literal: true

require_relative '../tool'
require_relative '../file_list'

# Deletes an EMPTY directory from disk. Non-empty directories are rejected
# (use file.delete to remove their contents first) — there is deliberately
# no recursive deletion. The path must reside under the working directory
# and must not be sensitive. The user is prompted for confirmation before
# the directory is deleted.
class DirDeleteTool < Tool
  def initialize(file_list, options)
    @file_list = file_list
    @options   = options
    super(
      name: 'dir.delete',
      description: 'Deletes an EMPTY directory from disk. Non-empty directories are rejected — ' \
                   'remove their contents first (there is no recursive deletion). ' \
                   'The path must reside under the working directory and must not be sensitive. ' \
                   'Paths are relative to the harness working directory. ' \
                   'The user will be prompted for confirmation before the directory is deleted.',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Path of the empty directory to delete (relative to the working directory)' }
        },
        required: ['path']
      }
    )
  end

  def execute(args)
    path  = @file_list.resolve(args['path'])
    shown = @file_list.display_path(path)

    # The path must reside under the working directory (and not be the
    # working directory itself).
    unless @file_list.within_workdir?(path)
      puts "  [dir.delete] ✗ #{shown} (outside working directory)"
      $stdout.flush
      return "error: path '#{shown}' must reside under the working directory (#{@file_list.workdir})"
    end

    # Security: sensitive paths (e.g. inside .git or .harness) are blocked.
    if @file_list.sensitive?(path)
      puts "  [dir.delete] ✗ #{shown} (blocked: sensitive path)"
      $stdout.flush
      return "error: path '#{shown}' is blocked and can never be deleted"
    end

    unless File.directory?(path)
      puts "  [dir.delete] ✗ #{shown} (not a directory)"
      $stdout.flush
      return "error: '#{shown}' does not exist or is not a directory"
    end

    # Safety: only empty directories may be deleted.
    entries = Dir.children(path)
    unless entries.empty?
      puts "  [dir.delete] ✗ #{shown} (not empty: #{entries.size} entr#{entries.size == 1 ? 'y' : 'ies'})"
      $stdout.flush
      return "error: directory '#{shown}' is not empty (#{entries.size} entries) — remove its contents first; recursive deletion is not supported"
    end

    if @options[:dry_run]
      puts "  [dir.delete] ~ #{shown} (dry run)"
      $stdout.flush
      return "DRY RUN: would delete empty directory #{shown}"
    end

    # Security: prompt the user for confirmation.
    puts
    puts "  [dir.delete] ⚠  The model is requesting to DELETE an empty directory:"
    puts "                  #{shown}"
    print  "                  Delete? (y/n): "
    $stdout.flush

    answer = $stdin.gets
    answer = answer&.chomp&.downcase

    if answer == 'y' || answer == 'yes'
      Dir.rmdir(path)
      puts "  [dir.delete] ✓ #{shown} (deleted)"
      $stdout.flush
      "ok: empty directory '#{shown}' has been deleted"
    else
      puts "  [dir.delete] ✗ #{shown} (denied by user)"
      $stdout.flush
      "error: user denied deleting directory '#{shown}'"
    end
  end
end
