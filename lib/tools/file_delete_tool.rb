# frozen_string_literal: true

require_relative '../tool'
require_relative '../file_list'

# Deletes a file from disk. Requires a DELETE access grant (its own mode,
# independent from read/write - issue #92).
module Tools

  class FileDeleteTool < Tool
    def initialize(file_list, options)
      @file_list = file_list
      @options   = options
      super(
        name: 'file.delete',
        description: 'Deletes a file from disk. ' \
                     'Paths are relative to the harness working directory. ' \
                     'Deleting requires a DELETE access grant (its own mode, independent from read/write).',
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

      # Deleting a file requires a DELETE grant - its own mode, independent
      # of read/write (issue #92). A read or write grant is not enough.
      unless @file_list.deletable?(path)
        result = @file_list.grant_access(path, :d)
        return Tool.denial_error("error: access denied for '#{shown}'", result) unless Tool.granted?(result)
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

      File.delete(path)
      puts "  [file.delete] ✓ #{shown} (deleted)"
      $stdout.flush
      "ok: file '#{shown}' has been deleted"
    end
  end
end
