# frozen_string_literal: true

require_relative '../tool'
require 'fileutils'

class FileWriteTool < Tool
  def initialize(allowed_files, options)
    @allowed_files = allowed_files
    @options       = options
    super(
      name: 'file_write',
      description: 'Writes content to a file. Only files in the allowed list can be written. The content must be the COMPLETE file content.',
      parameters: {
        type: 'object',
        properties: {
          path:    { type: 'string', description: 'Path to the file to write' },
          content: { type: 'string', description: 'Complete content to write to the file' }
        },
        required: ['path', 'content']
      }
    )
  end

  def execute(args)
    path    = args['path']
    content = args['content']

    unless @allowed_files.include?(path)
      puts "  [file_write] ✗ #{path} (not in allowed list)"
      $stdout.flush
      return "error: file '#{path}' is not in the allowed file list"
    end

    if @options[:dry_run]
      puts "  [file_write] ~ #{path} (dry run, #{content.length} chars)"
      $stdout.flush
      return "DRY RUN: would write #{content.length} chars to #{path}"
    end

    dir = File.dirname(path)
    FileUtils.mkdir_p(dir) unless dir == '.'
    File.write(path, content)
    puts "  [file_write] ✓ #{path} (#{content.length} chars)"
    $stdout.flush
    "ok: wrote #{content.length} chars to #{path}"
  end
end
