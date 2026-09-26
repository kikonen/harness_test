# frozen_string_literal: true

module Commands
  # /resume <id> - resume a saved session by its id.
  class ResumeCommand
    def initialize(harness, file_list, options)
      @harness = harness
      @file_list = file_list
      @options = options
    end

    def handle(args)
      id = args.strip
      if id.empty?
        puts "Usage: /resume <id>   (see /sessions for available ids)"
        return
      end

      path = @harness.session_manager.resume_session(id)
      puts "Session #{File.basename(path, '.json')} resumed."
      puts "  (conversation and file list restored - see /session)"
    end

    # Build the CLI command to resume a session in a new harness run.
    def resume_cli_string(id)
      parts = ['ruby harness.rb', "-m #{@options[:model]}", "--resume #{id}"]
      parts << "-d #{@file_list.workdir}" unless @file_list.workdir == Dir.pwd
      parts.join(' ')
    end
  end
end
