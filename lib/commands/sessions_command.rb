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
               "message and grant counts)",
      group: :session,
      see_also: %w[resume save saving])

    def handle(_args)
      locator  = SessionLocator.new(@file_list.workdir)
      sessions = locator.list
      if sessions.empty?
        emit_role(:note, "No saved sessions (#{locator.sessions_dir}).")
        return
      end

      footer_text = "Resume one with: /resume <id>  " \
                    "(or: ruby harness.rb -m <model> --resume <id>)"
      emit_list(
        title: "Saved sessions (#{sessions.size}):",
        kind: :table,
        columns: %i[id saved messages files workdir],
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
        workdir: session[:workdir]
      }
    end
  end
end
