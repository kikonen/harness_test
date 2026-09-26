# frozen_string_literal: true

require_relative '../tool'
require_relative '../file_list'
require 'fileutils'

# Creates a directory (with mkdir -p semantics: parent directories are
# created as needed). The path must reside under the working directory and
# must not be sensitive. If the directory already exists, the call is a
# no-op (success).
class DirCreateTool < Tool
  def initialize(file_list)
    @file_list = file_list
    super(
      name: 'dir.create',
      description: 'Creates a directory (mkdir -p semantics: parent directories are created as needed). ' \
                   'Paths outside the working directory require explicit user approval. ' \
                   'If the directory already exists, the call is a no-op (success). ' \
                   'Paths are relative to the harness working directory.',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Path of the directory to create (relative to the working directory)' }
        },
        required: ['path']
      }
    )
  end

  def execute(args)
    path  = @file_list.resolve(args['path'])
    shown = @file_list.display_path(path)

    # Security: sensitive paths (e.g. inside .git or .harness) are blocked.
    if @file_list.sensitive?(path)
      puts "  [dir.create] ✗ #{shown} (blocked: sensitive path)"
      $stdout.flush
      return "error: path '#{shown}' is blocked and can never be created"
    end

    if File.directory?(path)
      puts "  [dir.create] = #{shown} (already exists)"
      $stdout.flush
      return "ok: directory '#{shown}' already exists"
    end

    if File.file?(path)
      puts "  [dir.create] ✗ #{shown} (a file with this name exists)"
      $stdout.flush
      return "error: '#{shown}' already exists and is a file, not a directory"
    end

    # Creating a directory requires WRITE access to the PARENT directory.
    parent = File.dirname(path)
    unless @file_list.writable?(parent)
      result = @file_list.grant_access(parent, :w)
      return "error: write access denied for '#{@file_list.display_path(parent)}'" \
             unless result == :granted
    end

    FileUtils.mkdir_p(path)

    puts "  [dir.create] ✓ #{shown}"
    $stdout.flush
    "ok: created directory '#{shown}'"
  end
end