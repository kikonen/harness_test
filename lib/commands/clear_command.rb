# frozen_string_literal: true

module Commands
  # /clear - remove all grants from the access list.
  class ClearCommand
    def initialize(harness, file_list, options)
      @file_list = file_list
    end

    def handle(_args)
      @file_list.clear
      puts "Access list cleared."
    end
  end
end
