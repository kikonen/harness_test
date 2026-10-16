# frozen_string_literal: true

require_relative '../command'
require_relative '../session_locator'

module Commands
  # /sessions - list saved sessions.
  #
  # Listing is pure path + JSON reading, so it goes through SessionLocator
  # (issue #276) and needs NO harness: CLI's --list-sessions runs this command
  # with harness: nil, before any Harness exists. This class is the single
  # renderer of the session list (both entry points show the same columns).
  class SessionsCommand < Command
    def handle(_args)
      locator  = SessionLocator.new(@file_list.workdir)
      sessions = locator.list
      if sessions.empty?
        @ui.puts "No saved sessions (#{locator.sessions_dir})."
        return
      end

      @ui.puts "Saved sessions (#{sessions.size}):"
      sessions.each do |s|
        @ui.puts "  #{s[:id]}  saved #{s[:saved_at].strftime('%Y-%m-%d %H:%M:%S')}  " \
             "#{s[:messages]} messages, #{s[:files]} file(s)  [workdir: #{s[:workdir]}]"
      end
      @ui.puts "Resume one with: /resume <id>  (or: ruby harness.rb -m <model> --resume <id>)"
    end
  end
end
