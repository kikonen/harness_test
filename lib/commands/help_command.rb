# frozen_string_literal: true

require_relative '../command'

module Commands
  # /help - show available commands.
  class HelpCommand < Command
    def handle(_args)
      @ui.puts <<~HELP
        Available commands:
          /grant         Show all current grants: file/dir access (read, write,
                         delete) and the auto-approved command lists
                         (run.command tool and shell (!), kept separate)
          /clear         Remove all grants from the list

          /retry         Re-send the chain after a failed request; tool work
                         already done is kept, so the turn resumes from there
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

        Shell mode:
          Type any line starting with ! to run a shell command locally,
          bypassing the model. The command follows the same approval rules
          as run.command (Allow / always-allow; unsafe constructs can never
          be auto-approved) but uses a SEPARATE allowlist
          (.harness/shell_commands.yml) from the run.command tool - grants
          saved one way never auto-approve commands on the other. The command
          and its output are NOT sent to or stored in the model's session.

        Session:
          Prompts are accumulated in a session, so the model sees the whole
          conversation. If a request to the LLM fails mid-turn, the tool work
          already done stays in the session - use /retry to resume the turn
          from there instead of starting over. /session shows a summary,
          /session-clear starts a fresh conversation. /compact summarizes the
          conversation to free up context window space.

        Project rules (harness.md):
          If a harness.md file exists in the working directory, its content
          is appended to the system prompt as "Project-Specific Rules".
          The file is auto-detected when its modification time changes
          (checked before each prompt). Use /reload to force a re-read.

        Saving / resuming sessions:
          The session (conversation history AND the access list) is
          auto-saved to its own directory inside the working directory
          (.harness/sessions/<session-id>/session.json) at every prompt
          boundary (before each send and after each reply) and
          again on exit, so a crash loses at most one in-flight request.
          /save stores it manually at any time. Disable auto-save with the
          --no-auto-save flag or 'auto_save: false' in the config.
          /sessions lists all saved sessions; /resume <id> restores the
          conversation and access list. To pick up the newest saved session
          in a new run, start the harness with --continue.

        Multiline input (issue #198 phase 3 / #91):
          * Enter adds a NEWLINE inside the prompt - it never submits, so a
            multiline block can be typed or pasted without any tricks.
          * Submit key sends the whole buffer - by platform:
              - Windows console / Terminal on the host: Ctrl+Enter or
                Shift+Enter
              - a normal Unix terminal: Alt+Enter (Ctrl/Shift+Enter are
                indistinguishable from Enter there)
              - a remote host reached THROUGH Windows Terminal (ssh, WSL2):
                Alt+Enter is consumed by Windows Terminal and Ctrl+Enter has
                no encoding there by default. Use a terminal that forwards
                it as CSI 13 (kitty / kcm keyboard protocol) - that is
                bound too - or quickly tap ESC then Enter (the same bytes,
                within ~100 ms). See the startup banner.

        Mid-turn steering notes (issue #36):
          While the model is working, any keypress opens a note editor on
          the spot WITHOUT interrupting the turn. Finish the note and press
          the submit key (same keys as above - see Multiline input for
          remote setups): it is delivered to the model as a "User note
          (mid-turn)" message before its next step, so it can course-correct
          on the fly - no Ctrl+C needed. Enter inserts a NEWLINE inside the
          note, so multiline text can be typed or pasted as one note (issue
          #198 phase 4). The harness prints "[note] got it - ..." when it
          receives one. A submit on an empty note commits nothing and just
          returns to the spinner. Note: text typed mid-turn is ALWAYS a note,
          not a command or shell input (a "/" or "!" prefix has no special
          meaning then). While a dialog (grant prompt / ui.dialog) is open,
          the keyboard belongs to the dialog - answer it normally; its answer
          is never mistaken for a note.

        Keys:
          Esc      Idle prompt: cancel the read; the text is KEPT as a draft
                   and prefilled at the next prompt (submit key sends it).
                   Note editor: keep the text as a draft for the next time
                   the editor opens.
          Ctrl+C   Cancel the current input (or interrupt a running request)
          Ctrl+D   Quit (on an empty prompt); inside a note editor: abort the
                   RUNNING turn like Ctrl+C (a note committed before it is
                   still delivered)
          Up/Down  Browse command history
      HELP
    end
  end
end
