# frozen_string_literal: true

require_relative '../tool'
require_relative '../file_list'

# Provides basic metadata about a file: size, modification time, permissions,
# and line count. Does not read the file contents.
class FileInfoTool < Tool
  def initialize(file_list)
    @file_list = file_list
    super(
      name: 'file.info',
      description: 'Returns basic metadata about a file (size, modified time, permissions, line count) ' \
                   'without reading its contents. ' \
                   'Paths are relative to the harness working directory.',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Path to the file (relative to the working directory)' }
        },
        required: ['path']
      }
    )
  end

  def execute(args)
    path  = @file_list.resolve(args['path'])
    shown = @file_list.display_path(path)

    unless @file_list.readable?(path)
      result = @file_list.grant_access(path, :r)
      return "error: access denied for '#{shown}'" unless result == :granted
    end

    unless File.file?(path)
      puts "  [file.info] ✗ #{shown} (not found)"
      $stdout.flush
      return "error: file not found: #{shown}"
    end

    stat = File.stat(path)
    size = stat.size
    mtime = Time.at(stat.mtime).strftime('%Y-%m-%d %H:%M:%S')
    perms = format_permissions(stat.mode)
    lines = count_lines(path)

    info = "path: #{shown}\n" \
           "size: #{human_size(size)} (#{size} bytes)\n" \
           "modified: #{mtime}\n" \
           "permissions: #{perms}\n" \
           "lines: #{lines}"

    puts "  [file.info] ✓ #{shown} (#{human_size(size)}, #{lines} lines)"
    $stdout.flush
    info
  end

  private

  def format_permissions(mode)
    bits = (mode & 0o777).to_s(8).rjust(3, '0')
    format_rwx(bits)
  end

  def format_rwx(octal)
    result = ''
    octal.each_char do |d|
      n = d.to_i(8)
      result += (n & 4) != 0 ? 'r' : '-'
      result += (n & 2) != 0 ? 'w' : '-'
      result += (n & 1) != 0 ? 'x' : '-'
    end
    result
  end

  def human_size(bytes)
    units = %w[B KB MB GB]
    value = bytes.to_f
    idx   = 0
    while value >= 1024 && idx < units.size - 1
      value /= 1024.0
      idx += 1
    end
    return "#{bytes} B" if idx == 0
    "#{format('%.1f', value)} #{units[idx]}"
  end

  def count_lines(path)
    count = 0
    File.open(path, 'rb') do |f|
      f.each_line { |_| count += 1 }
    end
    count
  rescue StandardError
    -1
  end
end