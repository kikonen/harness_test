# frozen_string_literal: true

require_relative "../command"
require_relative "../session_locator"

module Commands
  # /sessions - list saved sessions.
  #
  # Listing is pure path + JSON reading, so it goes through SessionLocator
  # (issue #276) and needs NO harness: CLI's --list-sessions runs this command
  # with harness: nil, before any Harness exists. This class is the single
  # renderer of the session list (both entry points show the same columns).
  class SessionsCommand < Command
    HELP = CommandHelp.new(
      usage: "sessions",
      summary: "List saved sessions in this working directory (id, saved-at, " \
               "message, grant and job counts)",
      group: :session,
      see_also: %w[save saving])

    def handle(_args)
      locator  = SessionLocator.new(@file_list.workdir)
      sessions = locator.list
      if sessions.empty?
        emit_role(:note, "No saved sessions (#{locator.sessions_dir}).")
        return
      end

      footer_text = "Resume one in a new run: `bin/harness --resume <id>`"
      emit_list(
        title: "Saved sessions (#{sessions.size}):",
        kind: :table,
        columns: %i[id saved messages files jobs workdir],
        items: sessions.map { |session| session_item(session) },
        footer: [footer_text],
        origin: "sessions")
    end

    def session_item(session)
      {
        id: session[:id],
        saved: session[:saved_at].strftime("%Y-%m-%d %H:%M:%S"),
        messages: session[:messages],
        files: session[:files],
        jobs: jobs_cell(session[:job_breakdown]),
        workdir: session[:workdir]
      }
    end

    # The jobs column is a per-job breakdown, not a count: messages only ever
    # belong to a job, so a bare number would ask "messages of what?". One row
    # per job (the renderer stacks a multi-line cell into table rows).
    def jobs_cell(breakdown)
      Array(breakdown).map { |j| "job #{j[:id]}: #{j[:messages]}" }.join("\n\n")
    end
  end
end
