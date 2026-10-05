# frozen_string_literal: true

require_relative '../command'

module Commands
  # /sessions - list saved sessions.
  class SessionsCommand < Command
    def handle(_args)
      sessions = @harness.session_manager.list_sessions
      if sessions.empty?
        puts "No saved sessions (#{@harness.session_manager.sessions_dir})."
        return
      end

      puts "Saved sessions (#{sessions.size}):"
      sessions.each do |s|
        puts "  #{s[:id]}  saved #{s[:saved_at].strftime('%Y-%m-%d %H:%M:%S')}  " \
             "#{s[:messages]} messages, #{s[:files]} file(s)  [workdir: #{s[:workdir]}]"
      end
      puts "Resume one with: /resume <id>  (or: ruby harness.rb -m <model> --resume <id>)"
    end
  end
end
