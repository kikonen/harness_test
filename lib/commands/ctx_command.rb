# frozen_string_literal: true

module Commands
  # /ctx - report current context usage on demand (issue #63).
  class CtxCommand
    def initialize(harness, _file_list, _options)
      @harness = harness
    end

    def handle(_args)
      puts @harness.context_report
      puts
    end
  end
end
