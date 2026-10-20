# frozen_string_literal: true

require 'spec_helper'
require 'llm/stream_error'

RSpec.describe LLM::StreamError do
  it 'is an LLMError, so the client retry loop sees it' do
    expect(LLM::StreamError).to be < ::LLMError
  end

  # A stream lost mid-answer is never retried (re-sending would duplicate what
  # the user already saw), so the class carries no payload of its own.
  it 'carries no payload' do
    expect(LLM::StreamError.new('mid-answer').message).to eq('mid-answer')
  end
end

RSpec.describe LLM::StreamStatusError do
  subject(:error) { described_class.new(503, 'upstream unavailable') }

  it 'is a plain StandardError, NOT an LLMError' do
    # Deliberate: a non-2xx on the streamed path arrives BEFORE any answer, so
    # the caller decides on the code itself instead of the retry loop matching
    # on the exception class.
    expect(LLM::StreamStatusError).not_to be < ::LLMError
    expect(error).to be_a(StandardError)
  end

  it 'exposes the status code as an integer' do
    expect(error.code).to eq(503)
    expect(error.code).to be_a(Integer)
  end

  it 'coerces a code given as a string' do
    expect(described_class.new('404', '').code).to eq(404)
  end

  it 'keeps the server body for the log line' do
    expect(error.body).to eq('upstream unavailable')
  end

  it 'coerces a nil body to an empty string (no nil ever reaches the log)' do
    expect(described_class.new(500, nil).body).to eq('')
  end

  it 'names the code in the message' do
    expect(error.message).to eq('HTTP 503')
  end
end
