# frozen_string_literal: true

require_relative '../tool'
require_relative '../file_list'
require 'fileutils'

# Creates a directory (with mkdir -p semantics: parent directories are
# created as needed). The path must reside under the working directory and
# must not be sensitive. If the directory already exists, the call is a
# no-op (success).
module Tools

  class DirCreateTool < Tool
    def initialize(file_list, options = {})
      @file_list = file_list
      @options   = options
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
        Tool.puts "  [dir.create] ✗ #{shown} (blocked: sensitive path)"
        return "error: path '#{shown}' is blocked and can never be created"
      end

      if File.directory?(path)
        Tool.puts "  [dir.create] = #{shown} (already exists)"
        return "ok: directory '#{shown}' already exists"
      end

      if File.file?(path)
        Tool.puts "  [dir.create] ✗ #{shown} (a file with this name exists)"
        return "error: '#{shown}' already exists and is a file, not a directory"
      end

      # Creating a directory requires WRITE access to the PARENT directory,
      # or a write grant on the target directory itself (granted earlier for
      # this very dir) - see FileList#grant_access.
      # The grant request is made on the TARGET path so the dialog offers the
      # new directory itself as the first option (issue #54): granting it does
      # not make existing siblings of the parent writeable.
      if !@file_list.writable?(path) && !@file_list.writable?(File.dirname(path))
        purpose = "to create directory '#{shown}'"
        result  = @file_list.grant_access(path, :w, purpose: purpose)
        return Tool.denial_error(
          "error: write access denied for '#{shown}'", result
        ) unless Tool.granted?(result)
      end

      FileUtils.mkdir_p(path)

      Tool.puts "  [dir.create] ✓ #{shown}"
      "ok: created directory '#{shown}'"
    end
  end
end
