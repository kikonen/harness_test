# frozen_string_literal: true

require_relative '../command'
require_relative '../command_allowlist'

module Commands
  # /grant - show all current grants: file/dir access grants (read, write,
  # delete) and command allowlist prefixes. Replaces the constant grant
  # display that used to be printed above every prompt (issue #101).
  class GrantCommand < Command
    def handle(_args)
      access = @file_list.accessible_paths
      labels = { both: 'Read + write', read: 'Read only', write: 'Write only', delete: 'Delete' }

      %i[both read write delete].each do |mode|
        section = access[mode]
        files   = section[:files]
        dirs    = section[:dirs]
        flats   = section[:flat_dirs] || []
        next if files.empty? && dirs.empty? && flats.empty?

        @ui.puts "#{labels[mode]}:"
        unless files.empty?
          files.each_with_index do |f, i|
            @ui.puts "  #{i + 1}. #{@file_list.display_path(f)}"
          end
        end
        idx = files.size + 1
        unless dirs.empty?
          dirs.each_with_index do |d, i|
            @ui.puts "  #{idx + i}. #{@file_list.display_path(d)}/ (recursive)"
          end
        end
        idx += dirs.size
        unless flats.empty?
          flats.each_with_index do |d, i|
            @ui.puts "  #{idx + i}. #{@file_list.display_path(d)}/ (dir only)"
          end
        end
      end

      tool_list = CommandAllowlist.new(@file_list.workdir).prefixes
      shell_list = CommandAllowlist.new(@file_list.workdir,
                                        file: CommandAllowlist::SHELL_FILENAME)
                             .prefixes

      if tool_list.empty? && shell_list.empty?
        @ui.puts "Commands: (none allowed)"
        return
      end

      unless tool_list.empty?
        @ui.puts 'Commands for run.command:'
        tool_list.each { |p| @ui.puts "  - #{p}" }
      end
      unless shell_list.empty?
        @ui.puts 'Commands for shell (!):'
        shell_list.each { |p| @ui.puts "  - #{p}" }
      end
    end
  end
end
