# frozen_string_literal: true

require_relative '../tool'
require_relative '../file_list'
require 'fileutils'

class FileRenameTool < Tool
  def initialize(file_list, options)
    @file_list = file_list
    @options   = options
    super(
      name: 'file_rename',
      description: 'Renames (moves) a file to a new path. BOTH the old and the new path ' \
                   'must be in the allowed file list — otherwise the rename is rejected. ' \
                   'Paths are relative to the harness working directory. ' \
                   'The file is moved on disk (contents unchanged) and the allowed file ' \
                   'list is updated: the old path is replaced by the new one. ' \
                   'The destination must not already exist on disk.',
      parameters: {
        type: 'object',
        properties: {
          old_path: { type: 'string', description: 'Current path of the file (relative to the working directory); must be in the allowed file list' },
          new_path: { type: 'string', description: 'New path for the file (relative to the working directory); must be in the allowed file list' }
        },
        required: ['old_path', 'new_path']
      }
    )
  end

  def execute(args)
    old_path = @file_list.resolve(args['old_path'])
    new_path = @file_list.resolve(args['new_path'])
    old_shown = @file_list.display_path(old_path)
    new_shown = @file_list.display_path(new_path)

    # Both paths must be in the allowed file list.
    unless @file_list.include?(old_path)
      puts "  [file_rename] ✗ #{old_shown} (old path not in allowed list)"
      $stdout.flush
      return "error: old path '#{old_shown}' is not in the allowed file list"
    end

    unless @file_list.include?(new_path)
      puts "  [file_rename] ✗ #{new_shown} (new path not in allowed list)"
      $stdout.flush
      return "error: new path '#{new_shown}' is not in the allowed file list"
    end

    # Security: the new path must not be sensitive.
    if @file_list.sensitive?(new_path)
      puts "  [file_rename] ✗ #{new_shown} (blocked: sensitive file)"
      $stdout.flush
      return "error: new path '#{new_shown}' is blocked and can never be added to the allowed file list"
    end

    unless File.file?(old_path)
      puts "  [file_rename] ✗ #{old_shown} (file does not exist)"
      $stdout.flush
      return "error: file '#{old_shown}' does not exist on disk"
    end

    if File.exist?(new_path)
      puts "  [file_rename] ✗ #{new_shown} (destination already exists)"
      $stdout.flush
      return "error: destination '#{new_shown}' already exists — choose a different new path"
    end

    if @options[:dry_run]
      puts "  [file_rename] ~ #{old_shown} → #{new_shown} (dry run)"
      $stdout.flush
      return "DRY RUN: would rename #{old_shown} to #{new_shown}"
    end

    dir = File.dirname(new_path)
    FileUtils.mkdir_p(dir) unless dir == '.'
    FileUtils.mv(old_path, new_path)

    # Update the allowed file list: old path replaced by the new one.
    @file_list.rename(old_path, new_path)

    puts "  [file_rename] ✓ #{old_shown} → #{new_shown}"
    $stdout.flush
    "ok: renamed #{old_shown} to #{new_shown} (allowed file list updated)"
  end
end
