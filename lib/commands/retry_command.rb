# frozen_string_literal: true

require_relative '../command'

module Commands
  # /retry - re-send the session message chain (after a failed request).
  class RetryCommand < Command
    def handle(_args)
      @harness.session_manager.retry
    end
  end
end
