# frozen_string_literal: true

require_relative '../tool'
require_relative '../file_list'

# Deletes an EMPTY directory from disk. Non-empty directories are rejected
# (use file.delete to remove their contents first) - there is deliberately
# no recursive deletion. The path must reside under the working directory
# and must not be sensitive. Requires a DELETE access grant (its own mode,
# independent from read/write - issue #92).
module Tools

  class DirDeleteTool < Tool
    def initialize(file_list, options)
      @file_list = file_list
      @options   = options
      super(
        name: 'dir.delete',
        description: 'Deletes an EMPTY directory from disk. Non-empty directories are rejected - ' \
                     'remove their contents first (there is no recursive deletion). ' \
                     'Paths outside the working directory require explicit user approval. ' \
                     'Paths are relative to the harness working directory. ' \
                     'Deleting requires a DELETE access grant (its own mode, independent from read/write).',
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

      # Security: sensitive paths (e.g. inside .git or .harness) are blocked.
      if @file_list.sensitive?(path)
        Tool.puts "  [dir.delete] ✗ #{shown} (blocked: sensitive path)"
        return "error: path '#{shown}' is blocked and can never be deleted"
      end

      unless File.directory?(path)
        Tool.puts "  [dir.delete] ✗ #{shown} (not a directory)"
        return "error: '#{shown}' does not exist or is not a directory"
      end

      # Safety: only empty directories may be deleted.
      entries = Dir.children(path)
      unless entries.empty?
        Tool.puts "  [dir.delete] ✗ #{shown} (not empty: #{entries.size} entr#{entries.size == 1 ? 'y' : 'ies'})"
        return "error: directory '#{shown}' is not empty (#{entries.size} entries) - remove its contents first; recursive deletion is not supported"
      end

      # Deleting a directory requires a DELETE grant (its own mode, separate
      # from read/write - issue #92). A grant on the target directory itself
      # or on its parent (the entry is removed FROM the parent) both suffice;
      # prefer the more granular target-first.
      parent = File.dirname(path)
      unless @file_list.deletable?(path) || @file_list.deletable?(parent)
        purpose = "to delete directory '#{shown}'"
        result  = @file_list.grant_access(path, :d, purpose: purpose)
        return Tool.denial_error(
          "error: delete access denied for '#{@file_list.display_path(path)}'", result
        ) unless Tool.granted?(result)
      end

      if @options[:dry_run]
        Tool.puts "  [dir.delete] ~ #{shown} (dry run)"
        return "DRY RUN: would delete empty directory #{shown}"
      end

      Dir.rmdir(path)
      Tool.puts "  [dir.delete] ✓ #{shown} (deleted)"
      "ok: empty directory '#{shown}' has been deleted"
    end
  end
end
