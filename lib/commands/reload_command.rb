# frozen_string_literal: true

module Commands
  # /reload - reload harness.md (project rules) into the system prompt.
  class ReloadCommand
    def initialize(harness, _file_list, _options)
      @harness = harness
    end

    def handle(_args)
      @harness.session_manager.reload_rules
      puts "harness.md reloaded - project rules updated in the system prompt."
      puts
    end
  end
end
