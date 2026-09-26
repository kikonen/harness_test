# frozen_string_literal: true

module Commands
  # /compact - compact the session (summarize conversation to free context).
  class CompactCommand
    def initialize(harness, _file_list, _options)
      @harness = harness
    end

    def handle(_args)
      result = @harness.session_manager.compact_session
      retained = result[:retained]
      puts "Session compacted: #{result[:before]} messages -> " \
           "#{result[:after]} messages (#{retained} recent retained)."
      puts
      puts "Summary:"
      puts result[:summary]
      puts
    end
  end
end
