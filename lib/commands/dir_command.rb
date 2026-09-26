# frozen_string_literal: true

module Commands
  # /dir <path> [r|w|rw] - allow a directory tree (recursively).
  class DirCommand
    def initialize(harness, file_list, options)
      @file_list = file_list
    end

    def handle(args)
      pattern, mode = parse_args(args)
      if pattern =~ /[\\\*\?\[\]]/
        handle_glob(pattern, mode)
      else
        handle_single(pattern, mode)
      end
    end

    private

    def parse_args(args)
      parts = args.strip.split(/\s+/, 2)
      pattern = parts[0]
      return [pattern, :rw] if parts.length < 2

      [pattern, FileCommand.mode_from(parts[1])]
    end

    def handle_glob(pattern, mode)
      matches = Dir.glob(File.join(@file_list.workdir, pattern)).sort
      dirs = matches.select { |p| File.directory?(p) }
      if dirs.empty?
        puts "No directories match: #{pattern}"
        return
      end

      added = 0
      dirs.each do |path|
        shown = @file_list.display_path(path)
        case @file_list.add_tree(path, mode)
        when :blocked
          puts "  [security] ✗ #{shown} (blocked: sensitive directory)"
        when :duplicate
          puts "Already allowed: #{shown}/"
        when :added
          added += 1
          puts "Allowed: #{shown}/ (recursive, #{mode_label(mode)})"
        end
      end
      puts "Allowed #{added} director#{added == 1 ? 'y' : 'ies'} matching #{pattern} (#{mode_label(mode)})."
    end

    def handle_single(pattern, mode)
      shown = @file_list.display_path(pattern)
      case @file_list.add_tree(pattern, mode)
      when :blocked
        puts "  [security] ✗ #{shown} (blocked: sensitive directory)"
      when :duplicate
        puts "Already allowed: #{shown}/"
      when :added
        puts "Allowed: #{shown}/ (recursive, #{mode_label(mode)})"
      end
    end

    def mode_label(mode)
      case mode
      when :r then 'read'
      when :w then 'write'
      else 'read+write'
      end
    end
  end
end
