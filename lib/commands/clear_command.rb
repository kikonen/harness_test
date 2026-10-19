# frozen_string_literal: true

require_relative "../command"

module Commands
  # /clear - remove all grants from the access list.
  class ClearCommand < Command
    HELP = CommandHelp.new(
      usage: "clear",
      summary: "Remove every file/dir grant from the access list (the command " \
        "allowlists are not touched - they are separate lists)",
      group: :access,
      see_also: %w[grant access])

    def handle(_args)
      @file_list.clear
      @ui.puts "Access list cleared."
    end
  end
end
