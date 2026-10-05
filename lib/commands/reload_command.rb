# frozen_string_literal: true

require_relative '../command'

module Commands
  # /reload - reload harness.md (project rules) into the system prompt.
  class ReloadCommand < Command
    def handle(_args)
      @harness.session_manager.reload_rules
      puts "harness.md reloaded - project rules updated in the system prompt."
      puts
    end
  end
end
