# frozen_string_literal: true

require_relative "../command"

module Commands
  # /resume <id> - resume a saved session by its id.
  #
  # The resume is delegated to the run's own setup action (CLI#setup, issue
  # #280): the whole run - Harness, logger, LLM client, history file, command
  # handler - is BUILT AGAIN under the resumed id, and every holder is
  # repointed at it. What this command does NOT do is mutate the live Harness
  # of the session being replaced: swapping identity by patching the live
  # object's logger, history file and options one by one is what made the
  # derived resources chaseable (issues #113 / #119 / #276).
  class ResumeCommand < Command
    def handle(args)
      id = args.strip
      if id.empty?
        @ui.puts "Usage: /resume <id>   (see /sessions for available ids)"
        return
      end

      unless @on_resume
        @ui.puts "  [error] resume is not available in this run"
        return
      end

      # The action returns the FRESH run it built. Reporting through it (and
      # not through @harness) is the point: this command object was created by
      # the handler of the run being replaced, so its own @harness is exactly
      # that - a stale reference to the session being left behind.
      resumed = @on_resume.call(id)
      @ui.puts "  Session #{resumed.session.session_id} resumed."
      @ui.puts "  (conversation, file list and log rebuilt under it - see /session)"
    end

    # Build the CLI command to resume a session in a new harness run.
    def resume_cli_string(id)
      parts = ["ruby harness.rb", "-m #{@options[:model]}", "--resume #{id}"]
      parts << "-d #{@file_list.workdir}" unless @file_list.workdir == Dir.pwd
      parts.join(" ")
    end
  end
end
