# frozen_string_literal: true

require 'spec_helper'
require 'logger'
require 'llm/ollama_backend'

RSpec.describe LLM::OllamaBackend do
  let(:logger) { Logger.new(File::NULL) }
  let(:options) do
    { base_url: 'http://127.0.0.1:11434', model: 'test-model', api: 'ollama' }
  end
  let(:backend) { described_class.new(options, logger) }

  def body(messages, tools: nil) = backend.send(:build_body, messages, tools)
  def parsed(json)               = backend.send(:parse_response, json)

  describe '#api_type' do
    it 'returns :ollama' do
      expect(backend.api_type).to eq(LLM::OLLAMA)
    end
  end

  describe 'request body (issue #197: num_ctx is honoured here)' do
    it 'targets /api/chat' do
      expect(backend.send(:endpoint_path)).to eq('/api/chat')
    end

    it 'sends stream: false and model + messages' do
      b = body([{ role: 'user', content: 'hi' }])
      expect(b[:model]).to eq('test-model')
      expect(b[:messages]).to eq([{ role: 'user', content: 'hi' }])
      expect(b[:stream]).to be(false)
    end

    it 'includes num_ctx in the native options block with the default window' do
      b = body([{}])
      expect(b.dig(:options, :num_ctx)).to eq(LLM::NUM_CTX)
    end

    it 'honours a profile override for num_ctx (the whole point of this fix)' do
      options[:num_ctx] = 32_768
      expect(body([{}]).dig(:options, :num_ctx)).to eq(32_768)
    end

    it 'includes the full native sampling set with defaults' do
      opts = body([{}])[:options]
      expect(opts[:num_predict]).to eq(LLM::NUM_PREDICT)
      expect(opts[:temperature]).to eq(LLM::TEMPERATURE)
      expect(opts[:top_p]).to eq(LLM::TOP_P)
      expect(opts[:top_k]).to eq(LLM::TOP_K)
      expect(opts[:min_p]).to eq(LLM::MIN_P)
      expect(opts[:presence_penalty]).to eq(LLM::PRESENCE_PENALTY)
      expect(opts[:repeat_penalty]).to eq(LLM::REPEAT_PENALTY)
      expect(opts[:reasoning_effort]).to eq(LLM::REASONING_EFFORT)
    end

    it 'honours profile overrides for sampling parameters' do
      options[:temperature] = 0.9
      options[:top_k]       = 40
      opts = body([{}])[:options]
      expect(opts[:temperature]).to eq(0.9)
      expect(opts[:top_k]).to eq(40)
    end

    it 'includes tools when provided' do
      tools = [{ type: 'function', function: { name: 't', parameters: {} } }]
      expect(body([{}], tools: tools)[:tools]).to eq(tools)
    end

    it 'omits tools when none provided' do
      expect(body([{}])).not_to have_key(:tools)
    end
  end

  describe 'response normalization (native /api/chat shape)' do
    it 'maps the top-level message into the normalized shape' do
      result = parsed({
        message: { role: 'assistant', content: 'hello' },
        prompt_eval_count: 10, eval_count: 5
      })
      msg = result[:choices].first[:message]
      expect(msg[:role]).to eq('assistant')
      expect(msg[:content]).to eq('hello')
      expect(msg[:reasoning]).to be_nil
      expect(msg[:tool_calls]).to be_nil
      # The native API has no usage object; it is synthesized from the
      # top-level token counters.
      usage = { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
      expect(result[:usage]).to eq(usage)
    end

    it 'maps thinking to reasoning' do
      result = parsed({ message: { role: 'assistant', content: 'c', thinking: 'r' } })
      expect(result[:choices].first[:message][:reasoning]).to eq('r')
    end

    it 'stringifies object tool-call arguments (the native API sends JSON objects)' do
      result = parsed({
        message: {
          role: 'assistant', content: nil,
          tool_calls: [{ id: 'x', function: { name: 'f', arguments: { 'a' => 1 } } }]
        }
      })
      tc = result[:choices].first[:message][:tool_calls].first
      expect(tc[:function][:arguments]).to eq('{"a":1}')
    end

    it 'omits usage when no token counters are present' do
      result = parsed({ message: { role: 'assistant', content: 'c' } })
      expect(result).not_to have_key(:usage)
    end
  end
end
