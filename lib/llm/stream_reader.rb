# frozen_string_literal: true

require_relative "../text_normalizer"

module LLM
  # Cuts a stream of raw transport chunks into complete lines. The split is
  # done on BYTES and normalization happens per complete line: 0x0A never
  # occurs inside a multi-byte sequence, so a chunk can split a character but
  # a line never can. Splitting and framing rules: doc/streaming_design.md.
  class StreamReader
    def initialize
      @buffer = String.new(encoding: Encoding::BINARY)
    end

    # Returns the complete lines this chunk completes (possibly none); an
    # unterminated tail stays in the buffer for the next chunk.
    def push(chunk)
      @buffer << chunk.to_s.dup.force_encoding(Encoding::BINARY)
      lines = []
      while (index = @buffer.index("\n"))
        lines << @buffer[0...index]
        @buffer = @buffer[(index + 1)..].to_s
      end
      lines.map { |line| normalize(line) }
    end

    # The final line when the stream ended without a trailing newline.
    def finish
      return [] if @buffer.empty?

      line = @buffer.dup
      @buffer = String.new(encoding: Encoding::BINARY)
      [normalize(line)]
    end

    # Bytes still held for an incomplete line (transport byte accounting).
    def pending_bytes
      @buffer.bytesize
    end

    private

    def normalize(line)
      # A CRLF transport leaves the \r on the line; strip it before the
      # payload is parsed, not after (a trailing \r is not content).
      line = line.sub(/\r\z/, "")
      TextNormalizer.normalize(line)
    end
  end
end
