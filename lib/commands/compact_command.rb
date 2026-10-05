# frozen_string_literal: true

require_relative '../command'

module Commands
  # /compact - compact the session (summarize conversation to free context).
  class CompactCommand < Command
    def handle(_args)
      result = @harness.session_manager.compact_session
      retained = result[:retained]
      @ui.puts "Session compacted: #{result[:before]} messages -> " \
           "#{result[:after]} messages (#{retained} recent retained)."
      # issue #70 / #93: report the context size before and after so the
      # user can see how much space was freed (message count alone is
      # misleading - tool calls and long outputs inflate token usage).
      @ui.puts "  #{result[:context_before]} -> #{result[:context_line]}" if result[:context_before] && result[:context_line]
      @ui.puts
      @ui.puts "Summary:"
      @ui.puts result[:summary]
      @ui.puts
    end
  end
end
