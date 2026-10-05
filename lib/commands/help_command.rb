# frozen_string_literal: true

require_relative '../command'

module Commands
  # /help - show available commands.
  class HelpCommand < Command
    def handle(_args)
      @ui.puts <<~HELP
        Available commands:
          /grant         Show all current grants: file/dir access (read, write,
                         delete) and command allowlist prefixes
          /clear         Remove all grants from the list

          /retry         Re-send the session message chain (after a failed request)
          /session       Show a summary of the current session
          /session-clear Reset the session (drop all conversation messages)
          /compact       Compact the session (summarize conversation to free context)
          /ctx           Show current context usage (tokens, %, headroom, auto-compact status)
          /reasoning     Show the reasoning text of the last response (the model's
                         extended thinking; normally only visible in
                         .harness/sessions/<session-id>/harness.log)
          /reload        Reload harness.md (project rules) into the system prompt
          /save          Save the session (conversation + access list) to .harness/sessions/
          /resume <id>   Resume a saved session by its id (see /sessions)
          /sessions      List saved sessions
          /tools         List available tools
          /models        List configured models (marks the default and active one)
          /model <name>  Switch the active model for this run (remembered in the session)
          /model         Show the currently active model
          /help          Show this help
          /exit          Exit the harness

        Read, write, and delete access are tracked separately. A read grant
        never implies write, and a write grant implies read access to the same
        path. Delete is its own mode - neither read nor write implies it.

        Direct prompt:
          Type any text (not starting with /) to send it directly to the model.
          The model can use file.read / file.write / file.patch etc. to access
          files. When it attempts to access a file that is not yet allowed,
          you will be prompted to grant the required access (read or write) at
          the granularity you prefer: the single file, the directory only
          (direct children), or the directory recursively (all subdirs).

        Session:
          Prompts are accumulated in a session, so the model sees the whole
          conversation. If a request to the LLM fails, the prompt stays in the
          session - use /retry to re-send the chain. /session shows a summary,
          /session-clear starts a fresh conversation. /compact summarizes the
          conversation to free up context window space.

        Project rules (harness.md):
          If a harness.md file exists in the working directory, its content
          is appended to the system prompt as "Project-Specific Rules".
          The file is auto-detected when its modification time changes
          (checked before each prompt). Use /reload to force a re-read.

        Saving / resuming sessions:
          The session (conversation history AND the access list) is
          auto-saved to .harness/sessions/ inside the working directory at
          every prompt boundary (before each send and after each reply) and
          again on exit, so a crash loses at most one in-flight request.
          /save stores it manually at any time. Disable auto-save with the
          --no-auto-save flag or 'auto_save: false' in the config.
          /sessions lists all saved sessions; /resume <id> restores the
          conversation and access list. To pick up the newest saved session
          in a new run, start the harness with --continue.

        Multiline input:
          * Paste: paste a multiline block directly at the prompt.
          * Type: end a line with a trailing backslash (\\) to continue.

        Keys:
          Ctrl+C   Cancel the current input (or interrupt a running request)
          Ctrl+D   Quit (on an empty prompt)
          Up/Down  Browse command history
      HELP
    end
  end
end
