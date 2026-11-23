# frozen_string_literal: true

require_relative "../command"

module Commands
  # /session - show a summary of the current session.
  class SessionCommand < Command
    HELP = CommandHelp.new(
      usage: "session",
      summary: "Show a summary of the current session (id, message counts, " \
        "prompts, whether a prompt is pending for /retry, last stats, process id)",
      group: :session,
      see_also: %w[conversation session-clear compact ctx save retry])

    def handle(_args)
      emit_list(
        title: nil,
        kind: :table,
        columns: %i[field value],
        # The pid is a run fact, not a conversation fact: the command supplies it
        # so Session never has to know the OS process (issue #527).
        # The kill hint is here rather than in the banner: the case this serves is a
        # run that has to be stopped from outside, and the command differs per OS.
        items: foreground_harness.session.summary(
          process_id: "#{Process.pid} (#{kill_hint})"),
        origin: "session")
    end

    private

    # Same platform split CommandRunner#kill_process_tree uses for its own children.
    def kill_hint
      Gem.win_platform? ? "taskkill /PID #{Process.pid} /T /F" : "kill #{Process.pid}"
    end
  end
end
