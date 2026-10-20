# frozen_string_literal: true

require 'spec_helper'
require 'llm/stream_decoder'

# Framing of a streamed body. Both supported endpoints are covered: the
# OpenAI-compatible SSE framing ("data: ...") and the native NDJSON framing
# (one JSON object per line). A line that carries no payload yields nil - one
# odd line must not abort a stream.
RSpec.describe LLM::StreamDecoder do
  subject(:decoder) { described_class.new }

  describe 'SSE framing (OpenAI-compatible)' do
    it 'decodes a data line into a parsed payload' do
      payloads = decoder.push("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n")

      expect(payloads).to eq([{ choices: [{ delta: { content: "hi" } }] }])
    end

    it 'decodes several data lines from one chunk' do
      payloads = decoder.push("data: {\"a\":1}\ndata: {\"b\":2}\n")

      expect(payloads).to eq([{ a: 1 }, { b: 2 }])
    end

    it 'decodes a data line with no space after the colon' do
      expect(decoder.push("data:{\"a\":1}\n")).to eq([{ a: 1 }])
    end

    it 'recognizes the [DONE] marker and reports the stream done' do
      expect(decoder.push("data: [DONE]\n")).to eq([LLM::StreamDecoder::DONE])
      expect(decoder.done?).to be true
    end

    # After the marker the transport may still send a terminator chunk; it
    # must not be decoded as a payload.
    it 'ignores everything after [DONE]' do
      decoder.push("data: [DONE]\n")

      expect(decoder.push("data: {\"a\":1}\n")).to eq([])
    end

    it 'yields nothing for a blank line (an SSE event separator)' do
      expect(decoder.push("\n")).to eq([])
    end

    it 'yields nothing for the non-payload SSE fields' do
      expect(decoder.push("event: message\nid: 7\nretry: 1000\n")).to eq([])
    end

    it 'yields nothing for a comment line' do
      expect(decoder.push(": keep-alive\n")).to eq([])
      expect(decoder.push("data: \n")).to eq([])
    end

    it 'yields nothing for a data line that is not JSON' do
      expect(decoder.push("data: not json\n")).to eq([])
    end
  end

  describe 'NDJSON framing (native /api/chat)' do
    it 'decodes a bare JSON object line' do
      expect(decoder.push("{\"message\":{\"content\":\"hi\"}}\n"))
        .to eq([{ message: { content: "hi" } }])
    end

    it 'decodes the native final line carrying the eval counts' do
      expect(decoder.push("{\"done\":true,\"eval_count\":3}\n"))
        .to eq([{ done: true, eval_count: 3 }])
    end

    it 'yields nothing for a line that does not start with an object' do
      expect(decoder.push("garbage\n")).to eq([])
    end

    it 'yields nothing for a truncated JSON line' do
      expect(decoder.push("{\"message\":{\"content\":\n")).to eq([])
    end
  end

  describe 'stream boundaries' do
    it 'decodes a final line that arrived without a newline' do
      # A COMPLETE payload whose line terminator never arrived (the stream
      # ended at the last chunk).
      decoder.push("data: {\"a\":1}")

      expect(decoder.finish).to eq([{ a: 1 }])
    end

    it 'reports pending bytes of an incomplete line' do
      decoder.push("data: {\"a")

      expect(decoder.pending_bytes).to eq(9)
    end

    it 'is not done before the marker arrives' do
      decoder.push("data: {\"a\":1}\n")

      expect(decoder.done?).to be false
    end
  end
end
