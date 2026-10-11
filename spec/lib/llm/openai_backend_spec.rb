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
  def body(messages, tools: nil) = backend.send(:build_body, messages, tools)
  def parsed(json)               = backend.send(:parse_response, json)

  describe '#api_type' do
    it 'returns :openai' do
      expect(backend.api_type).to eq(LLM::OPENAI)
    end
  end

  describe 'request body (issue #197)' do
    it 'targets /v1/chat/completions' do
      expect(backend.send(:endpoint_path)).to eq('/v1/chat/completions')
    end

    it 'includes model and messages' do
      b = body([{ role: 'user', content: 'hi' }])
      expect(b[:model]).to eq('test-model')
      expect(b[:messages]).to eq([{ role: 'user', content: 'hi' }])
    end

    it 'does NOT include a nested options block (OpenAI schema has no num_ctx)' do
      expect(body([{ role: 'user', content: 'hi' }])).not_to have_key(:options)
    end

    it 'includes standard OpenAI sampling fields with defaults' do
      b = body([{ role: 'user', content: 'hi' }])
      expect(b[:temperature]).to eq(LLM::TEMPERATURE)
      expect(b[:top_p]).to eq(LLM::TOP_P)
      expect(b[:max_tokens]).to eq(LLM::NUM_PREDICT)
    end

    it 'honours profile overrides for sampling parameters' do
      options[:temperature] = 0.9
      options[:top_p]       = 0.5
      b = body([{ role: 'user', content: 'hi' }])
      expect(b[:temperature]).to eq(0.9)
      expect(b[:top_p]).to eq(0.5)
    end

    it 'includes tools when provided' do
      tools = [{ type: 'function', function: { name: 't', parameters: {} } }]
      expect(body([{}], tools: tools)[:tools]).to eq(tools)
    end

    it 'omits tools when none provided' do
      expect(body([{}])).not_to have_key(:tools)
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
    it 'strips a legacy trailing /v1 (issue #197: base_url is the server root)' do
      options[:base_url] = 'http://localhost:11434/v1'
      expect(backend.send(:base_url)).to eq('http://localhost:11434')
    end

    it 'does not double-append /v1 for a root url' do
      options[:base_url] = 'http://localhost:11434'
      expect(backend.send(:base_url)).to eq('http://localhost:11434')
    end
  end
end
