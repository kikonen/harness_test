# frozen_string_literal: true

require_relative '../command'

module Commands
  # /ctx - report current context usage on demand (issue #63).
  class CtxCommand < Command
    def handle(_args)
      @ui.puts @harness.context_report
      @ui.puts
    end
  end
end
