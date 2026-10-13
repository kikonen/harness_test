# frozen_string_literal: true

require_relative '../command'

module Commands
  # /reload - reload the system prompt (base prompt file + harness.md
  # project rules) from disk (issue #223). Both are re-read on demand, so
  # edits to either take effect without a restart.
  class ReloadCommand < Command
    def handle(_args)
      @harness.session_manager.reload_rules
      @ui.puts "System prompt reloaded (base prompt file + harness.md project rules)."
      @ui.puts
    end
  end
end
