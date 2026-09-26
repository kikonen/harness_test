# frozen_string_literal: true

require_relative '../tool'
require_relative '../file_list'
require 'fileutils'

# Copies a file to a new path. The source must be accessible;
# the destination must not already exist on disk.
class FileCopyTool < Tool
  def initialize(file_list, options)
    @file_list = file_list
    @options   = options
    super(
      name: 'file.copy',
      description: 'Copies a file to a new path. ' \
                   'The destination must not already exist on disk. ' \
                   'Paths are relative to the harness working directory.',
      parameters: {
        type: 'object',
        properties: {
          src: { type: 'string', description: 'Source path of the file (relative to the working directory)' },
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

    unless @file_list.include?(src)
      result = @file_list.grant_access(src)
      return "error: access denied for '#{src_shown}'" unless result == :granted
    end

    if @file_list.sensitive?(dst)
      puts "  [file.copy] ✗ #{dst_shown} (blocked: sensitive file)"
      $stdout.flush
      return "error: destination '#{dst_shown}' is blocked and can never be written"
    end

    unless File.file?(src)
      puts "  [file.copy] ✗ #{src_shown} (file does not exist)"
      $stdout.flush
      return "error: source file '#{src_shown}' does not exist on disk"
    end

    if File.exist?(dst)
      puts "  [file.copy] ✗ #{dst_shown} (destination already exists)"
      $stdout.flush
      return "error: destination '#{dst_shown}' already exists - choose a different path"
    end

    if @options[:dry_run]
      puts "  [file.copy] ~ #{src_shown} → #{dst_shown} (dry run)"
      $stdout.flush
      return "DRY RUN: would copy #{src_shown} to #{dst_shown}"
    end

    dir = File.dirname(dst)
    FileUtils.mkdir_p(dir) unless dir == '.'
    FileUtils.cp(src, dst)

    puts "  [file.copy] ✓ #{src_shown} → #{dst_shown}"
    $stdout.flush
    "ok: copied #{src_shown} to #{dst_shown}"
  end
end
