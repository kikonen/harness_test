# frozen_string_literal: true

require 'spec_helper'
require 'logger'
require 'stringio'
require 'json'
require 'llm/base_backend'

# Request/response logging in the shared backend machinery: one REQ line per
# attempt (target URI, body size, attempt number) and one RESP line for the
# response that actually arrived (status, byte size, per-attempt duration and
# the token counts). The point is a readable trail in harness.log: for a stuck
# or slow call the log shows which endpoint was hit and how long each attempt
# took (issue #242), and the time + tokens together give prompt-processing
# speed (issue #231).
RSpec.describe LLM::BaseBackend do
  # BaseBackend is abstract, so the specs run against a minimal concrete
  # backend whose contract methods are trivial - only #chat's logging is
  # under test.
  class MinimalBackend < LLM::BaseBackend
    def api_type = LLM::OPENAI
    def endpoint_path = '/chat/completions'

    private

    def build_body(messages, _tools)
      { model: @options[:model], messages: messages }
    end

    # Returns the raw JSON so the usage of either wire shape is visible.
    def parse_response(json) = json
  end

  # A response object that satisfies Net::HTTPSuccess without a live socket
  # (Net::HTTPResponse#body reads through the socket and raises without one).
  class StubResponse < Net::HTTPSuccess
    def initialize(code, body)
      @stub_code = code.to_s
      @stub_body = body
    end

    def code = @stub_code
    def body = @stub_body
  end

  # Stubbed transport: plays a scripted sequence per request call. An
  # exception item simulates a network error on that attempt.
  class StubHTTP
    attr_accessor :logger, :use_ssl, :open_timeout, :read_timeout,
                  :keep_alive_timeout

    def initialize(responses)
      @responses = responses
    end

    def request(_req)
      item = @responses.shift
      raise item if item.is_a?(StandardError)

      item
    end
  end

  let(:log)    { StringIO.new }
  let(:logger) { Logger.new(log) }
  let(:options) do
    # retry_delay 0 keeps the retry spec fast; the attempt counter in the log
    # line is what is being checked, not the backoff.
    { base_url: 'http://127.0.0.1:11434/v1', model: 'test-model', api: 'openai',
      retry_count: 2, retry_delay: 0 }
  end
  let(:backend) { MinimalBackend.new(options, logger) }
  let(:http_stub) { StubHTTP.new([StubResponse.new(200, '{"usage":{}}')]) }

  before { allow(KeepAliveHTTP).to receive(:new).and_return(http_stub) }

  def logged_lines
    log.string.lines.map(&:chomp).reject(&:empty?)
  end

  describe 'request logging' do
    it 'logs the target URI, the request body size and the attempt number' do
      backend.chat([{ role: 'user', content: 'hi' }])

      line = logged_lines.first
      expect(line).to include('REQ: POST http://127.0.0.1:11434/v1/chat/completions')
      expect(line).to match(/\(\d+ bytes, attempt 1\/2\)/)
    end

    it 'logs a REQ line again for every retry attempt' do
      http_stub.instance_variable_set(:@responses, [
        Errno::ECONNREFUSED.new,
        StubResponse.new(200, '{"usage":{}}')
      ])

      backend.chat([{ role: 'user', content: 'hi' }])
      lines = logged_lines

      req_lines = lines.grep(/REQ: POST/)
      expect(req_lines.size).to eq(2)
      expect(req_lines[0]).to include('attempt 1/2')
      expect(req_lines[1]).to include('attempt 2/2')
      # A failed attempt gets the existing network-error warning, not a RESP
      # line: nothing arrived to measure.
      expect(lines[1]).to include('network error (attempt 1/2)')
      expect(lines.grep(/RESP:/).size).to eq(1)
    end
  end

  describe 'response logging' do
    it 'logs status, response byte size and the per-attempt duration' do
      response = StubResponse.new(200, '{"usage":{"prompt_tokens":10,"total_tokens":10}}')
      http_stub.instance_variable_set(:@responses, [response])

      backend.chat([{ role: 'user', content: 'hi' }])
      line = logged_lines.last

      # The Logger adds its own "INFO -- :" prefix, so match the message part.
      expect(line).to include('RESP: HTTP 200')
      expect(line).to include("(#{response.body.bytesize} bytes)")
      expect(line).to match(/ in \d+\.\d\ds/)
    end

    it 'includes the token counts when the response reports them' do
      usage_json = '{"usage":{"prompt_tokens":10,"completion_tokens":5,' \
                   '"total_tokens":15}}'
      response   = StubResponse.new(200, usage_json)
      http_stub.instance_variable_set(:@responses, [response])

      backend.chat([{ role: 'user', content: 'hi' }])

      expect(logged_lines.last).to include('- 10 -> 5 tokens')
    end

    # The two wire shapes report usage differently, so the log line reads the
    # RAW parsed JSON: the OpenAI `usage` object, or the native Ollama
    # top-level eval counts.
    it 'reads the native (top-level eval count) usage shape too' do
      native_json = '{"message":{"content":"hi"},"prompt_eval_count":7,"eval_count":3}'
      response    = StubResponse.new(200, native_json)
      http_stub.instance_variable_set(:@responses, [response])

      backend.chat([{ role: 'user', content: 'hi' }])

      expect(logged_lines.last).to include('- 7 -> 3 tokens')
    end

    it 'logs no usage part when the backend reports none' do
      response = StubResponse.new(200, '{"message":{"content":"hi"}}')
      http_stub.instance_variable_set(:@responses, [response])

      backend.chat([{ role: 'user', content: 'hi' }])
      line = logged_lines.last

      expect(line).to match(/ in \d+\.\d\ds\z/)
      expect(line).not_to include('tokens')
    end
  end

  # issue #257: the response body is text that arrived from outside this
  # process, so a string value in it can be byte-invalid in UTF-8. Parsing
  # succeeds, but the NEXT JSON.generate - the request body built from this
  # chain, and the session save - raises JSON::GeneratorError, and the save
  # that should record the failure dies on the same byte, so nothing reaches
  # the console. BaseBackend normalizes the parsed structure at that boundary.
  describe 'response normalization (issue #257)' do
    it 'returns a response whose string values are valid UTF-8' do
      bad = [0xE2, 0x90].pack('C*').force_encoding(Encoding::UTF_8)
      body = '{"message":{"content":"x' + bad + '"}}'
      http_stub.instance_variable_set(:@responses, [StubResponse.new(200, body)])

      # Control: the parsed value as it arrived is what JSON.generate rejected.
      raw = JSON.parse(body, symbolize_names: true)
      expect { JSON.generate(raw) }.to raise_error(JSON::GeneratorError)

      result = backend.chat([{ role: 'user', content: 'hi' }])
      # MinimalBackend#parse_response hands back the RAW parsed hash, so the
      # normalized structure is read in its wire shape here.
      content = result[:message][:content]
      expect(content.valid_encoding?).to be true
      expect(content).to eq('x?')
      expect { JSON.generate(result) }.not_to raise_error
    end
  end

  describe 'elapsed formatting' do
    it 'uses plain seconds with 2dp (no minute factoring)' do
      expect(backend.send(:format_seconds, 4.2)).to eq('4.20')
      expect(backend.send(:format_seconds, 125.7)).to eq('125.70')
    end
  end
end
