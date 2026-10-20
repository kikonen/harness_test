# frozen_string_literal: true

require 'spec_helper'
require 'llm/stream_reader'

# The line boundary of a streamed body. Chunk boundaries are wherever the
# transport puts them, so a line can arrive in pieces and a chunk can hold
# several lines; splitting on BYTES is what makes a multi-byte character
# survive a split (0x0A is never inside one).
RSpec.describe LLM::StreamReader do
  subject(:reader) { described_class.new }

  def bytes(str) = str.dup.force_encoding(Encoding::BINARY)

  describe '#push' do
    it 'returns nothing for a chunk that completes no line' do
      expect(reader.push('data: {"a"')).to eq([])
      expect(reader.pending_bytes).to eq(10)
    end

    it 'returns the line when its newline arrives' do
      reader.push('data: {"a"')

      expect(reader.push('}')).to eq([])
      expect(reader.push("\n")).to eq(['data: {"a"}'])
      expect(reader.pending_bytes).to eq(0)
    end

    it 'returns every line a single chunk completes' do
      expect(reader.push("one\ntwo\nthree\n")).to eq(%w[one two three])
    end

    it 'keeps the unterminated tail after a multi-line chunk' do
      expect(reader.push("one\ntw")).to eq(['one'])
      expect(reader.pending_bytes).to eq(2)
      expect(reader.push("o\n")).to eq(['two'])
    end

    it 'emits an empty line as an empty string (a blank line is a line)' do
      expect(reader.push("\n\n")).to eq(['', ''])
    end

    it 'strips a CRLF transport newline' do
      expect(reader.push("data: x\r\n")).to eq(['data: x'])
    end

    it 'treats a lone CR as content, not as a line ending' do
      expect(reader.push("a\rb\n")).to eq(["a\rb"])
    end

    # The transport hands chunks as BINARY (measured against a real chunked
    # response): the tag is a byte container, not an encoding.
    it 'accepts BINARY-tagged chunks and returns UTF-8 lines' do
      lines = reader.push(bytes("data: caf\xc3\xa9\n"))

      expect(lines).to eq(['data: café'])
      expect(lines.first.encoding).to eq(Encoding::UTF_8)
    end

    # The point of splitting on bytes: a character split across two chunks is
    # whole again by the time the line is normalized.
    it 'reassembles a multi-byte character split across chunks' do
      whole = bytes("data: caf\xc3\xa9\n")
      reader.push(whole[0, 9])

      expect(reader.pending_bytes).to eq(9)
      expect(reader.push(whole[9..])).to eq(['data: café'])
    end

    # scrub replaces an INVALID SEQUENCE with one replacement char, not one
    # per byte: 0xE2 opens a three-byte sequence, 0x90 continues it, and the
    # newline that follows is not a continuation - so the incomplete sequence
    # collapses to a single '?'.
    it 'replaces an incomplete multi-byte sequence with one replacement char' do
      lines = reader.push(bytes("data: \xe2\x90\n"))

      expect(lines.first).to eq('data: ?')
      expect(lines.first.valid_encoding?).to be true
    end

    it 'keeps a valid multi-byte character intact' do
      expect(reader.push(bytes("data: \xe2\x9c\x93 ok\n"))).to eq(['data: ✓ ok'])
    end
  end

  describe '#finish' do
    it 'returns nothing when the buffer is empty' do
      reader.push("done\n")

      expect(reader.finish).to eq([])
    end

    it 'returns the final line when the stream ended without a newline' do
      reader.push('data: last')

      expect(reader.finish).to eq(['data: last'])
      expect(reader.pending_bytes).to eq(0)
    end

    it 'does not return the same line twice' do
      reader.push('tail')

      expect(reader.finish).to eq(['tail'])
      expect(reader.finish).to eq([])
    end
  end
end
