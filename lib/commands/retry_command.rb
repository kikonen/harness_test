# frozen_string_literal: true

module Commands
  # /retry - re-send the session message chain (after a failed request).
  class RetryCommand
    def initialize(harness, _file_list, _options)
      @harness = harness
    end

    def handle(_args)
      @harness.session_manager.retry
    end
  end
end
