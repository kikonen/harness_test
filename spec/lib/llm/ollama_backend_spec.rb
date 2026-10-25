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

  def body(messages, tools: nil, stream: false)
    backend.send(:build_body, messages, tools, stream: stream)
  end
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

    # issue #28: the native endpoint streams NDJSON (one JSON object per line)
    # when the CALLER asks. Unlike the OpenAI endpoint it reports the eval
    # counts on the final line either way, so no extra request field is needed
    # to keep the harness' token accounting.
    it 'sends stream: true when the request asks for a stream' do
      expect(body([{ role: 'user', content: 'hi' }], stream: true)[:stream]).to be(true)
    end

    it 'keeps the options block (num_ctx) alongside a stream request' do
      b = body([{}], stream: true)

      expect(b.dig(:options, :num_ctx)).to eq(LLM::NUM_CTX)
      expect(b[:stream]).to be(true)
    end

    it 'includes num_ctx in the native options block (built-in window when unset)' do
      b = body([{}])
      expect(b.dig(:options, :num_ctx)).to eq(LLM::NUM_CTX)
    end

    it 'honours a profile override for num_ctx (the whole point of this fix)' do
      options[:num_ctx] = 32_768
      expect(body([{}]).dig(:options, :num_ctx)).to eq(32_768)
    end

    # issue #215: the config owns every sampling/generation value. A key
    # that is not set is NOT sent, so the server's own default applies -
    # num_ctx alone keeps a built-in (it is this backend's raison d'etre).
    it 'sends only num_ctx when nothing else is configured' do
      opts = body([{}])[:options]
      expect(opts).to eq(num_ctx: LLM::NUM_CTX)
      # issue #215: no reasoning_effort in options - the native API has no
      # such option (Options.FromMap warns + drops it).
      expect(opts).not_to have_key(:reasoning_effort)
    end

    it 'sends sampling fields only when configured' do
      options[:num_predict]  = 512
      options[:temperature]  = 0.9
      options[:repeat_penalty] = 1.05
      opts = body([{}])[:options]
      expect(opts[:num_predict]).to eq(512)
      expect(opts[:temperature]).to eq(0.9)
      expect(opts[:repeat_penalty]).to eq(1.05)
      expect(opts).not_to have_key(:top_p)
      expect(opts).not_to have_key(:top_k)
    end

    it 'sends think (not reasoning_effort) at the top level when configured' do
      options[:reasoning_effort] = 'high'
      b = body([{}])
      expect(b[:think]).to eq('high')
      expect(b.dig(:options, :reasoning_effort)).to be_nil
    end

    it 'omits think when reasoning_effort is not configured' do
      expect(body([{}])).not_to have_key(:think)
    end
  describe 'message serialization (issue #215)' do
    def assistant_with_calls
      {
        role: 'assistant', content: nil,
        tool_calls: [
          { id: 'c1', function: { name: 'f', arguments: '{"a":1}' } },
          { id: 'c2', function: { name: 'g', arguments: '{}' } }
        ]
      }
    end

    it 'converts string tool-call arguments to JSON objects for /api/chat' do
      out = backend.send(:serialize_messages, [assistant_with_calls])
      args = out.first[:tool_calls].map { |tc| tc[:function][:arguments] }
      # The parsed JSON carries STRING keys, as JSON objects do on the wire.
      expect(args).to eq([{ 'a' => 1 }, {}])
    end

    it 'leaves messages without tool calls untouched' do
      m = [{ role: 'user', content: 'hi' }]
      expect(backend.send(:serialize_messages, m)).to eq(m)
    end

    it 'tolerates already-parsed (object) arguments from a native response' do
      m = [{ role: 'assistant', content: nil,
             tool_calls: [{ id: 'c1', function: { name: 'f', arguments: { 'a' => 1 } } }] }]
      out = backend.send(:serialize_messages, m)
      expect(out.first[:tool_calls].first[:function][:arguments]).to eq({ 'a' => 1 })
    end

    it 'falls back to an empty object for unparsable arguments' do
      m = [{ role: 'assistant', content: nil,
             tool_calls: [{ id: 'c1', function: { name: 'f', arguments: '{not json' } }] }]
      out = backend.send(:serialize_messages, m)
      expect(out.first[:tool_calls].first[:function][:arguments]).to eq({})
    end
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

    # issue #345: the native field is done_reason, and nothing on master read
    # it (grep -rn done_reason lib/ spec/ was empty) - so this path reported no
    # truncation signal at all.
    it 'carries the native done_reason at the top level' do
      result = parsed({ message: { role: 'assistant', content: 'c' }, done_reason: 'length' })

      expect(result[:finish_reason]).to eq('length')
    end

    it 'omits finish_reason when the done line reported none' do
      result = parsed({ message: { role: 'assistant', content: 'c' }, prompt_eval_count: 1 })

      expect(result).not_to have_key(:finish_reason)
    end

    it 'omits usage when no token counters are present' do
      result = parsed({ message: { role: 'assistant', content: 'c' } })
      expect(result).not_to have_key(:usage)
    end

    # issue #251: the native Metrics block also reports the cache depth and
    # the durations (integer nanoseconds per Ollama's API docs).
    it 'carries the cached count and the durations as milliseconds' do
      result = parsed({
        message: { role: 'assistant', content: 'c' },
        prompt_eval_count: 1000, prompt_eval_cached_count: 768,
        prompt_eval_duration: 410_500_000, eval_count: 50, eval_duration: 1_310_200_000
      })

      expect(result[:usage]).to include(
        prompt_tokens: 1000, completion_tokens: 50, total_tokens: 1050,
        cached_tokens: 768, prompt_eval_ms: 410.5, eval_ms: 1310.2
      )
    end

    it 'keeps the core usage alone when no Metrics extras are sent' do
      result = parsed({ message: { content: 'c' }, prompt_eval_count: 10, eval_count: 5 })

      expect(result[:usage]).to eq(prompt_tokens: 10, completion_tokens: 5, total_tokens: 15)
    end

    it 'carries a cached count even with no duration reported' do
      result = parsed({
        message: { content: 'c' }, prompt_eval_count: 1000, eval_count: 50,
        prompt_eval_cached_count: 768
      })

      expect(result[:usage]).to include(cached_tokens: 768)
    end
  end
end
