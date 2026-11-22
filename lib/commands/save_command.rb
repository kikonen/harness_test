# frozen_string_literal: true

require_relative "../command"

module Commands
  # /save - save the session (conversation + access list) to disk.
  class SaveCommand < Command
    HELP = CommandHelp.new(
      usage: "save",
      summary: "Save the session (conversation + access list) now and print " \
        "the id and the command line that resumes it",
      group: :session,
      see_also: %w[sessions saving])

    def handle(_args)
      # The run's own writer: every job's chain plus the system record, in one
      # write by the system's owner (a job SessionManager writes only its own).
      id = system_saver.save_run(foreground_harness.session.session_id)
      # issue #207: the session JSON lives inside the session's own dir.
      # Contiguous prose ack -> ONE note call, two paragraphs; the renderer
      # owns the indent and wrap (#470), not the emitter. Resume is startup-only
      # (--resume <id>); there is no in-run resume command.
      emit_role(
        :note,
        [
          "Session saved as #{id} (#{foreground_harness.session_manager.session_file_path(id)})",
          "Resume it in a new run: #{resume_cli_string(id)}"
        ])
    end

    # Build the CLI command to resume this session in a new harness run.
    def resume_cli_string(id)
      # Same rule as CLI#resume_cli_string: bin/harness is what the user runs,
      # and the resumed run restores its own model profile, so no -m.
      parts = ["bin/harness", "--resume #{id}"]
      parts << "-d #{@file_list.workdir}" unless @file_list.workdir == Dir.pwd
      parts.join(" ")
    end
  end
end
