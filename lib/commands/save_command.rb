# frozen_string_literal: true

require_relative '../command'

module Commands
  # /save - save the session (conversation + access list) to disk.
  class SaveCommand < Command
    def handle(_args)
      id = @harness.session_manager.save_session
      puts "Session saved as #{id} (#{@harness.session_manager.sessions_dir}/#{id}.json)"
      puts "Resume it later with: /resume #{id}"
      puts "  or from the command line: #{resume_cli_string(id)}"
    end

    # Build the CLI command to resume this session in a new harness run.
    def resume_cli_string(id)
      parts = ['ruby harness.rb', "-m #{@options[:model]}", "--resume #{id}"]
      parts << "-d #{@file_list.workdir}" unless @file_list.workdir == Dir.pwd
      parts.join(' ')
    end
  end
end
