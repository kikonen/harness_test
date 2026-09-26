# frozen_string_literal: true

require_relative '../tool'
require_relative '../file_list'

# Grants access to a directory tree: once a directory is allowed, every
# file under it (recursively, including subdirectories) can be read and
# written without being individually added to the allowed file list.
# Sensitive files/directories (e.g. .env*, .git, .harness) are always
# blocked, even inside an allowed directory.
#
# The path must reside under the working directory. The user is prompted
# for confirmation before the directory is allowed.
class DirAllowTool < Tool
  def initialize(file_list)
    @file_list = file_list
    super(
      name: 'dir.allow',
      description: 'Grants access to a directory and everything under it (all files and ' \
                   'subdirectories, recursively). Once allowed, files in that tree can be ' \
                   'read and written without individually adding each one. ' \
                   'Sensitive files/directories (e.g. .env*, .git, .harness) are still ' \
                   'blocked. The path must reside under the working directory. ' \
                   'The user will be prompted for confirmation before the directory is allowed.',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Path of the directory to allow (relative to the working directory)' }
        },
        required: ['path']
      }
    )
  end

  def execute(args)
    path  = @file_list.resolve(args['path'])
    shown = @file_list.display_path(path)

    # The path must reside under the working directory.
    unless @file_list.within_workdir?(path)
      puts "  [dir.allow] ✗ #{shown} (outside working directory)"
      $stdout.flush
      return "error: path '#{shown}' must reside under the working directory (#{@file_list.workdir})"
    end

    # Security: sensitive paths (e.g. inside .git or .harness) are never allowed.
    if @file_list.sensitive?(path)
      puts "  [dir.allow] ✗ #{shown} (blocked: sensitive path)"
      $stdout.flush
      return "error: path '#{shown}' is blocked and can never be allowed"
    end

    if @file_list.include?(path)
      puts "  [dir.allow] = #{shown} (already allowed)"
      $stdout.flush
      return "ok: directory '#{shown}' is already allowed"
    end

    # Security: prompt the user for confirmation.
    puts
    puts "  [dir.allow] ⚠  The model is requesting to ALLOW a directory (and everything under it):"
    puts "              #{shown}"
    print  "              Allow? (y/n): "
    $stdout.flush

    answer = $stdin.gets
    answer = answer&.chomp&.downcase

    if answer == 'y' || answer == 'yes'
      @file_list.add_dir(path)
      puts "  [dir.allow] ✓ #{shown} (allowed — all files under it are now accessible)"
      $stdout.flush
      "ok: directory '#{shown}' has been allowed — all files under it (except sensitive ones) are now accessible"
    else
      puts "  [dir.allow] ✗ #{shown} (denied by user)"
      $stdout.flush
      "error: user denied allowing directory '#{shown}'"
    end
  end
end
