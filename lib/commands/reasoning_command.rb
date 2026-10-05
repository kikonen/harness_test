# frozen_string_literal: true

require_relative '../command'

module Commands
  # /reasoning - show the reasoning text of the last LLM response on demand
  # (issue #98). Normally only visible in the log file; this makes it an
  # explicit console operation since reasoning can be lengthy.
  class ReasoningCommand < Command
    def handle(_args)
      reasoning = @harness.session.last_reasoning
      if reasoning.nil? || reasoning.strip.empty?
        puts 'No reasoning to show yet (no response with reasoning in this session).'
        return
      end

      puts "Reasoning for the last response (#{reasoning.length} chars):"
      puts '-' * 60
      puts reasoning
      puts '-' * 60
    end
  end
end
