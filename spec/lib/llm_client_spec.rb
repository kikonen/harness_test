# frozen_string_literal: true

require 'spec_helper'
require 'logger'
require 'llm_client'

# issue #131: the RAW API response body is troubleshooting-only - it goes to
# harness.log only with --verbose, while the parsed reasoning/content
# sections (SessionManager#log_response) are always logged. These specs lock
# in that split so the log stays followable without the flag.
RSpec.describe LLMClient do
  let(:logger)    { Logger.new(File::NULL) }
  let(:options)   { { base_url: 'http://127.0.0.1:11434', model: 'test-model' } }
  let(:client)    { described_class.new(options, logger) }
  let(:resp_body) do
    JSON.generate(choices: [{ message: { role: 'assistant', content: 'hi' } }])
  end

  # Swap in a stub HTTP that returns a canned success response and records
  # every logger call, so the specs never touch the network.
  def stub_success!
    resp = double('resp', is_a?: true, body: resp_body)
    http = double('http', request: resp)

    expect(KeepAliveHTTP).to receive(:new).and_return(http)
    allow(http).to receive(:logger=)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:keep_alive_timeout=)

    calls = []
    logger.define_singleton_method(:info) { |*args| calls << args }
    allow(logger).to receive(:warn)
    allow(logger).to receive(:error)
    calls
  end

  it 'does NOT log the raw response body by default' do
    calls = stub_success!

    result = client.chat([{ role: 'user', content: 'hello' }])

    expect(result[:choices].first[:message][:content]).to eq('hi')
    expect(calls.join("\n")).not_to include(resp_body)
  end

  it 'logs the raw response body (between separators) with --verbose' do
    options[:verbose] = true
    calls = stub_success!

    client.chat([{ role: 'user', content: 'hello' }])

    joined = calls.join("\n")
    expect(joined).to include('=' * 50)
    expect(joined).to include(resp_body)
  end
end
