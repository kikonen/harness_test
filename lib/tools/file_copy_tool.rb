# frozen_string_literal: true

require_relative '../tool'
require_relative '../file_list'
require 'fileutils'

# Copies a file to a new path. The source must be in the allowed file list;
# the destination must not already exist on disk. After a successful copy,
# the destination is added to the allowed file list (no user prompt — the
# user already approved the source file, and the copy is a read-only
# operation on the source).
class FileCopyTool < Tool
  def initialize(file_list, options)
    @file_list = file_list
    @options   = options
    super(
      name: 'file_copy',
      description: 'Copies a file to a new path. The source must be in the allowed file list. ' \
                   'The destination must not already exist on disk. ' \
                   'Paths are relative to the harness working directory. ' \
                   'The destination is added to the allowed file list automatically.',
      parameters: {
        type: 'object',
        properties: {
          src: { type: 'string', description: 'Source path of the file (relative to the working directory); must be in the allowed file list' },
          dst: { type: 'string', description: 'Destination path for the copy (relative to the working directory); must not already exist' }
        },
        required: ['src', 'dst']
      }
    )
  end

  def execute(args)
    src = @file_list.resolve(args['src'])
    dst = @file_list.resolve(args['dst'])
    src_shown = @file_list.display_path(src)
    dst_shown = @file_list.display_path(dst)

    # The source must be in the allowed file list.
    unless @file_list.include?(src)
      puts "  [file_copy] ✗ #{src_shown} (source not in allowed list)"
      $stdout.flush
      return "error: source '#{src_shown}' is not in the allowed file list"
    end

    # Security: the destination must not be sensitive.
    if @file_list.sensitive?(dst)
      puts "  [file_copy] ✗ #{dst_shown} (blocked: sensitive file)"
      $stdout.flush
      return "error: destination '#{dst_shown}' is blocked and can never be written"
    end

    unless File.file?(src)
      puts "  [file_copy] ✗ #{src_shown} (file does not exist)"
      $stdout.flush
      return "error: source file '#{src_shown}' does not exist on disk"
    end

    if File.exist?(dst)
      puts "  [file_copy] ✗ #{dst_shown} (destination already exists)"
      $stdout.flush
      return "error: destination '#{dst_shown}' already exists — choose a different path"
    end

    if @options[:dry_run]
      puts "  [file_copy] ~ #{src_shown} → #{dst_shown} (dry run)"
      $stdout.flush
      return "DRY RUN: would copy #{src_shown} to #{dst_shown}"
    end

    dir = File.dirname(dst)
    FileUtils.mkdir_p(dir) unless dir == '.'
    FileUtils.cp(src, dst)

    # Add the destination to the allowed file list.
    @file_list.add(dst)

    puts "  [file_copy] ✓ #{src_shown} → #{dst_shown}"
    $stdout.flush
    "ok: copied #{src_shown} to #{dst_shown} (destination added to allowed file list)"
  end
end
