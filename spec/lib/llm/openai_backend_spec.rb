# frozen_string_literal: true

require 'spec_helper'
require 'logger'
require 'llm/openai_backend'

RSpec.describe LLM::OpenAIBackend do
  let(:logger) { Logger.new(File::NULL) }
  let(:options) do
    { base_url: 'http://127.0.0.1:11434', model: 'test-model', api: 'openai' }
  end
  let(:backend) { described_class.new(options, logger) }

  # build_body / parse_response are the backend's contract; test them
  # directly (no network layer). The subclass methods are private - that is
  # intentional - so send(:) is used here.
  def body(messages, tools: nil, stream: false)
    backend.send(:build_body, messages, tools, stream: stream)
  end
  def parsed(json)               = backend.send(:parse_response, json)

  describe '#api_type' do
    it 'returns :openai' do
      expect(backend.api_type).to eq(LLM::OPENAI)
    end
  end

  describe 'request body (issue #197)' do
    it 'targets /chat/completions (appended to the configured base url)' do
      # The base url carries the /v1 prefix (Ollama's /v1-compatible server);
      # the backend appends ONLY /chat/completions - no URL rewriting.
      expect(backend.send(:endpoint_path)).to eq('/chat/completions')
    end

    it 'includes model and messages' do
      b = body([{ role: 'user', content: 'hi' }])
      expect(b[:model]).to eq('test-model')
      expect(b[:messages]).to eq([{ role: 'user', content: 'hi' }])
    end

    it 'does NOT include a nested options block (OpenAI schema has no num_ctx)' do
      expect(body([{ role: 'user', content: 'hi' }])).not_to have_key(:options)
    end

    # issue #215: the config owns every sampling/generation value. A key
    # that is not set is NOT sent, so the server's own default applies -
    # there are no code-side defaults to leak into the request.
    it 'omits all sampling fields when none are configured' do
      b = body([{ role: 'user', content: 'hi' }])
      %i[temperature top_p top_k min_p presence_penalty repeat_penalty
         max_tokens reasoning_effort].each do |key|
        expect(b).not_to have_key(key), "expected #{key} to be omitted"
      end
    end

    it 'sends sampling fields only when configured' do
      options[:temperature] = 0.6
      options[:max_tokens]  = 4096
      b = body([{ role: 'user', content: 'hi' }])
      expect(b[:temperature]).to eq(0.6)
      expect(b[:max_tokens]).to eq(4096)
      expect(b).not_to have_key(:top_p)
    end

    it 'sends reasoning_effort at the top level when configured (issue #215: the OpenAI schema reads it there)' do
      options[:reasoning_effort] = 'high'
      b = body([{ role: 'user', content: 'hi' }])
      expect(b[:reasoning_effort]).to eq('high')
    end

    it 'omits reasoning_effort when not configured' do
      expect(body([{ role: 'user', content: 'hi' }])).not_to have_key(:reasoning_effort)
    end

    it 'honours profile overrides for sampling parameters' do
      options[:temperature] = 0.9
      options[:top_p]       = 0.5
      b = body([{ role: 'user', content: 'hi' }])
      expect(b[:temperature]).to eq(0.9)
      expect(b[:top_p]).to eq(0.5)
    end

  describe 'message serialization (issue #215)' do
    it 'keeps string tool-call arguments as-is (the OpenAI wire shape)' do
      m = [{ role: 'assistant', content: nil,
             tool_calls: [{ id: 'c1', function: { name: 'f', arguments: '{"a":1}' } }] }]
      expect(backend.send(:serialize_messages, m)).to eq(m)
    end
  end

    it 'includes tools when provided' do
      tools = [{ type: 'function', function: { name: 't', parameters: {} } }]
      expect(body([{}], tools: tools)[:tools]).to eq(tools)
    end

    it 'omits tools when none provided' do
      expect(body([{}])).not_to have_key(:tools)
    end

    # issue #28: the CALLER's per-request decision reaches this endpoint's
    # wire shape. The OpenAI schema reads the flag at top level, and usage is
    # only reported on a streamed response when asked for explicitly - without
    # stream_options the harness would lose its token accounting for every
    # streamed turn.
    it 'sends stream: true with include_usage when the request asks for a stream' do
      b = body([{ role: 'user', content: 'hi' }], stream: true)

      expect(b[:stream]).to be(true)
      expect(b[:stream_options]).to eq(include_usage: true)
    end

    # The default (no stream asked for) sends NOTHING stream-related: the
    # buffered request is byte-identical to what it was before streaming
    # existed.
    it 'sends no stream keys when the request does not ask for a stream' do
      b = body([{ role: 'user', content: 'hi' }])

      expect(b).not_to have_key(:stream)
      expect(b).not_to have_key(:stream_options)
    end

    it 'keeps sampling fields alongside a stream request' do
      options[:temperature] = 0.4
      b = body([{}], stream: true)

      expect(b[:temperature]).to eq(0.4)
      expect(b[:stream]).to be(true)
    end
  end

  describe 'response normalization' do
    it 'maps the OpenAI choices[0].message into the normalized shape' do
      result = parsed({
        choices: [{ message: { role: 'assistant', content: 'hello' } }],
        usage:   { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
      })
      msg = result[:choices].first[:message]
      expect(msg[:role]).to eq('assistant')
      expect(msg[:content]).to eq('hello')
      expect(msg[:reasoning]).to be_nil
      expect(msg[:tool_calls]).to be_nil
      usage = { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
      expect(result[:usage]).to eq(usage)
    end

    it 'maps reasoning_content to reasoning' do
      msg    = { role: 'assistant', content: 'c', reasoning_content: 'r' }
      result = parsed({ choices: [{ message: msg }] })
      expect(result[:choices].first[:message][:reasoning]).to eq('r')
    end

    it 'keeps string tool-call arguments as-is' do
      result = parsed({
        choices: [{
          message: {
            role: 'assistant', content: nil,
            tool_calls: [
              { id: 'x', function: { name: 'f', arguments: '{"a":1}' } }
            ]
          }
        }]
      })
      tc = result[:choices].first[:message][:tool_calls].first
      expect(tc[:id]).to eq('x')
      expect(tc[:function][:arguments]).to eq('{"a":1}')
    end

    it 'omits usage when the response has none' do
      result = parsed({ choices: [{ message: { role: 'assistant', content: 'c' } }] })
      expect(result).not_to have_key(:usage)
    end
  end

  describe 'base_url normalization' do
    it 'uses the configured url as-is (no rewriting; issue #215 follow-up)' do
      options[:base_url] = 'http://localhost:11434/v1'
      expect(backend.send(:base_url)).to eq('http://localhost:11434/v1')
    end

    it 'leaves a root url as-is too' do
      options[:base_url] = 'http://localhost:11434'
      expect(backend.send(:base_url)).to eq('http://localhost:11434')
    end

    it 'composes base url + endpoint path into the request url (no /v1 in between)' do
      options[:base_url] = 'http://localhost:11434/v1'
      expect(URI("#{backend.send(:base_url)}#{backend.send(:endpoint_path)}").to_s)
        .to eq('http://localhost:11434/v1/chat/completions')
    end
  end
end
