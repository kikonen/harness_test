# frozen_string_literal: true

require 'spec_helper'
require 'llm/stream_accumulator'

# Folds a stream of delta payloads into the SAME normalized response shape the
# buffered path returns (see LLM::BaseBackend), so Harness#call_llm cannot tell
# the two apart. Both wire shapes are covered: OpenAI's choices[0].delta with
# fragmented tool-call arguments, and the native message with complete ones.
RSpec.describe LLM::StreamAccumulator do
  subject(:acc) { described_class.new }

  describe 'content deltas' do
    it 'concatenates content fragments in arrival order' do
      acc.feed({ choices: [{ delta: { content: "Hel" } }] })
      acc.feed({ choices: [{ delta: { content: "lo" } }] })

      expect(acc.content).to eq("Hello")
    end

    it 'returns the delta it added so the caller can show it live' do
      expect(acc.feed({ choices: [{ delta: { content: "Hi" } }] })).to eq({ content: "Hi" })
    end

    it 'returns nothing for a chunk that carries no text' do
      expect(acc.feed({ choices: [{ delta: { role: "assistant" } }] })).to eq({})
    end

    # An empty-string delta is a real delta (servers send it as the first
    # chunk); it is not the same as "no content field".
    it 'treats an empty content delta as no text' do
      expect(acc.feed({ choices: [{ delta: { content: "" } }] })).to eq({ content: "" })
      expect(acc.content).to eq("")
    end

    it 'ignores a payload that is not a hash' do
      expect(acc.feed(nil)).to eq({})
      expect(acc.content).to eq("")
    end
  end

  describe 'reasoning deltas' do
    it 'accumulates OpenAI reasoning_content separately from content' do
      acc.feed({ choices: [{ delta: { reasoning_content: "thin" } }] })
      acc.feed({ choices: [{ delta: { content: "say" } }] })

      expect(acc.reasoning).to eq("thin")
      expect(acc.content).to eq("say")
    end

    it 'accumulates the native thinking field' do
      acc.feed({ message: { thinking: "deep" } })

      expect(acc.reasoning).to eq("deep")
    end

    it 'reports a reasoning delta to the caller' do
      expect(acc.feed({ message: { thinking: "hmm" } })).to eq({ reasoning: "hmm" })
    end
  end

  describe 'tool call deltas' do
    # OpenAI streams one call as fragments keyed by `index`: the name arrives
    # once, the arguments arrive piece by piece.
    it 'merges argument fragments of one indexed call' do
      acc.feed({ choices: [{ delta: { tool_calls: [
        { index: 0, id: "call_1", function: { name: "file.read", arguments: "" } }
      ] } }] })
      acc.feed({ choices: [{ delta: { tool_calls: [
        { index: 0, function: { arguments: '{"path":' } }
      ] } }] })
      acc.feed({ choices: [{ delta: { tool_calls: [
        { index: 0, function: { arguments: '"lib/a.rb"}' } }
      ] } }] })

      calls = acc.to_response[:choices][0][:message][:tool_calls]
      expect(calls.size).to eq(1)
      expect(calls[0][:id]).to eq("call_1")
      expect(calls[0][:function][:name]).to eq("file.read")
      expect(calls[0][:function][:arguments]).to eq('{"path":"lib/a.rb"}')
    end

    it 'keeps two indexed calls separate' do
      acc.feed({ choices: [{ delta: { tool_calls: [
        { index: 0, id: "a", function: { name: "one", arguments: "{}" } },
        { index: 1, id: "b", function: { name: "two", arguments: "{}" } }
      ] } }] })

      names = acc.to_response[:choices][0][:message][:tool_calls].map { |c| c[:function][:name] }
      expect(names).to eq(%w[one two])
    end

    # The native endpoint sends a complete call with arguments as an OBJECT;
    # execute_tool_call always expects a STRING.
    it 'stringifies native object arguments' do
      acc.feed({ message: { tool_calls: [
        { id: "c1", function: { name: "file.read", arguments: { "path" => "lib/a.rb" } } }
      ] } })

      args = acc.to_response[:choices][0][:message][:tool_calls][0][:function][:arguments]
      expect(args).to eq('{"path":"lib/a.rb"}')
    end

    it 'reports no tool calls when none arrived' do
      acc.feed({ choices: [{ delta: { content: "hi" } }] })

      expect(acc.to_response[:choices][0][:message][:tool_calls]).to be_nil
    end

    it 'defaults empty arguments to an empty JSON object' do
      acc.feed({ choices: [{ delta: { tool_calls: [
        { index: 0, id: "a", function: { name: "tools.list" } }
      ] } }] })

      expect(acc.to_response[:choices][0][:message][:tool_calls][0][:function][:arguments]).to eq("{}")
    end
  end

  describe 'usage' do
    it 'reads the OpenAI usage object' do
      acc.feed({ usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } })

      expect(acc.to_response[:usage]).to eq(
        { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
      )
    end

    it 'computes the total when the OpenAI usage omits it' do
      acc.feed({ usage: { prompt_tokens: 10, completion_tokens: 5 } })

      expect(acc.to_response[:usage][:total_tokens]).to eq(15)
    end

    it 'reads the native top-level eval counts' do
      acc.feed({ prompt_eval_count: 7, eval_count: 3 })

      expect(acc.to_response[:usage]).to eq(
        { prompt_tokens: 7, completion_tokens: 3, total_tokens: 10 }
      )
    end

    it 'reports no usage when the stream never sent any' do
      acc.feed({ choices: [{ delta: { content: "hi" } }] })

      expect(acc.to_response).not_to have_key(:usage)
    end

    # issue #251: on the streamed path the performance fields ride the FINAL
    # chunk (llama.cpp puts timings on the last delta, Ollama reports its
    # Metrics on the done line), so they must reach the assembled usage.
    it 'carries the timings of the final OpenAI-shape chunk' do
      acc.feed({ choices: [{ delta: { content: "hi" } }] })
      acc.feed({ usage: { prompt_tokens: 1000, completion_tokens: 50, total_tokens: 1050,
                          prompt_tokens_details: { cached_tokens: 768 } },
                 timings: { prompt_ms: 410.5, predicted_ms: 1310.2 } })

      expect(acc.to_response[:usage]).to include(
        prompt_tokens: 1000, completion_tokens: 50, total_tokens: 1050,
        cached_tokens: 768, prompt_eval_ms: 410.5, eval_ms: 1310.2
      )
    end

    it 'carries the native Metrics of the done line' do
      acc.feed({ message: { content: "hi" } })
      acc.feed({ done: true, prompt_eval_count: 1000, eval_count: 50,
                 prompt_eval_cached_count: 768, prompt_eval_duration: 410_500_000,
                 eval_duration: 1_310_200_000 })

      expect(acc.to_response[:usage]).to include(
        cached_tokens: 768, prompt_eval_ms: 410.5, eval_ms: 1310.2
      )
    end

    it 'keeps a core-only streamed usage at exactly the core keys' do
      acc.feed({ usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } })

      expect(acc.to_response[:usage]).to eq(
        prompt_tokens: 10, completion_tokens: 5, total_tokens: 15
      )
    end

    it 'drops performance fields that arrived with no token counts' do
      acc.feed({ choices: [{ delta: { content: "hi" } }] })
      acc.feed({ timings: { prompt_ms: 100.0 } })

      expect(acc.to_response).not_to have_key(:usage)
    end
  end

  describe '#started?' do
    it 'is false before any part of the answer arrives' do
      expect(acc.started?).to be false
    end

    it 'is true once content arrived' do
      acc.feed({ choices: [{ delta: { content: "x" } }] })

      expect(acc.started?).to be true
    end

    it 'is true once reasoning arrived (nothing visible, but generation began)' do
      acc.feed({ choices: [{ delta: { reasoning_content: "x" } }] })

      expect(acc.started?).to be true
    end

    it 'is true once a tool call arrived' do
      acc.feed({ choices: [{ delta: { tool_calls: [
        { index: 0, id: "a", function: { name: "tools.list", arguments: "{}" } }
      ] } }] })

      expect(acc.started?).to be true
    end
  end

  describe '#to_response (the normalized shape)' do
    it 'matches the buffered shape for a plain answer' do
      acc.feed({ message: { role: "assistant", content: "Hello" } })

      expect(acc.to_response).to eq(
        { choices: [{ message: { role: "assistant", content: "Hello",
                                 reasoning: nil, tool_calls: nil } }] }
      )
    end

    it 'reports nil content when nothing arrived (an empty stream)' do
      expect(acc.to_response[:choices][0][:message][:content]).to be_nil
    end

    it 'defaults the role to assistant when the stream never named one' do
      acc.feed({ choices: [{ delta: { content: "hi" } }] })

      expect(acc.to_response[:choices][0][:message][:role]).to eq("assistant")
    end

    it 'keeps a role the stream did name' do
      acc.feed({ choices: [{ delta: { role: "assistant", content: "hi" } }] })

      expect(acc.to_response[:choices][0][:message][:role]).to eq("assistant")
    end
  end
end
