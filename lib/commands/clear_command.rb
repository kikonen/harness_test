# frozen_string_literal: true

require_relative '../command'

module Commands
  # /clear - remove all grants from the access list.
  class ClearCommand < Command
    def handle(_args)
      @file_list.clear
      @ui.puts "Access list cleared."
    end
  end
end
