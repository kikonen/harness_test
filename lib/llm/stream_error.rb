# frozen_string_literal: true

require_relative "../harness_error"

module LLM
  # A streamed response lost AFTER part of the answer had reached the caller:
  # re-sending would duplicate what the user already saw, so it is not retried.
  # The retry boundary: doc/streaming_design.md.
  class StreamError < LLMError; end

  # A non-2xx on the streamed path: it arrives before any answer, so it carries
  # the server's body for the log line and the retry decision.
  class StreamStatusError < StandardError
    attr_reader :code, :body

    def initialize(code, body)
      @code = code.to_i
      @body = body.to_s
      super("HTTP #{code}")
    end
  end
end
