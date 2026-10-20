# frozen_string_literal: true

require 'spec_helper'
require 'llm/stream_preview'

# The live tail of a streamed answer for the spinner. The task thread WRITES it
# (the on_delta callback) and the MAIN thread READS it (the spinner evaluates
# its suffix callable every frame), so #record publishes a frozen snapshot
# rather than exposing a mutable String.
RSpec.describe LLM::StreamPreview do
  describe '#record / #tail_line' do
    it 'has no tail before anything arrives (the spinner shows the ctx instead)' do
      expect(described_class.new.tail_line).to be_nil
    end

    it 'shows the content received so far' do
      preview = described_class.new
      preview.record({ content: "Reading the" })

      expect(preview.tail_line).to eq("Reading the")
    end

    it 'appends later deltas' do
      preview = described_class.new
      preview.record({ content: "Hello" })
      preview.record({ content: " world" })

      expect(preview.tail_line).to eq("Hello world")
    end

    it 'shows reasoning when the model has produced only reasoning' do
      preview = described_class.new
      preview.record({ reasoning: "let me check" })

      expect(preview.tail_line).to eq("let me check")
    end

    it 'prefers content once the answer itself has started' do
      preview = described_class.new
      preview.record({ reasoning: "thinking hard" })
      preview.record({ content: "the answer" })

      expect(preview.tail_line).to eq("the answer")
    end

    it 'ignores a delta with no text part' do
      preview = described_class.new
      preview.record({ content: "a" })
      preview.record({})

      expect(preview.tail_line).to eq("a")
    end

    it 'ignores a nil delta' do
      preview = described_class.new
      preview.record(nil)

      expect(preview.tail_line).to be_nil
    end

    it 'keeps an empty-string delta from erasing the tail' do
      preview = described_class.new
      preview.record({ content: "abc" })
      preview.record({ content: "" })

      expect(preview.tail_line).to eq("abc")
    end
  end

  describe 'the tail length' do
    it 'keeps the newest part when the answer is longer than the tail' do
      preview = described_class.new(max_tail: 10)
      preview.record({ content: "0123456789abcdefghij" })

      # The LAST max_tail characters: the newest part is what the user wants.
      expect(preview.tail_line).to eq("...abcdefghij")
    end

    it 'marks a truncated tail with a leading ellipsis' do
      preview = described_class.new(max_tail: 5)
      preview.record({ content: "123456789" })

      expect(preview.tail_line).to start_with("...")
    end

    it 'does not mark a tail that is the whole answer' do
      preview = described_class.new(max_tail: 20)
      preview.record({ content: "short" })

      expect(preview.tail_line).to eq("short")
    end

    it 'marks the tail when only the reasoning overflowed' do
      preview = described_class.new(max_tail: 6)
      preview.record({ reasoning: "reasoning longer than six" })

      expect(preview.tail_line).to eq("...an six")
    end

    it 'defaults to a 60-char tail' do
      expect(described_class::MAX_TAIL).to eq(60)
    end

    it 'collapses newlines so the tail stays one spinner line' do
      preview = described_class.new(max_tail: 40)
      preview.record({ content: "line one\nline two\n" })

      expect(preview.tail_line).not_to include("\n")
    end
  end

  describe 'the snapshot (the cross-thread contract)' do
    it 'publishes an immutable snapshot the reader cannot mutate' do
      preview = described_class.new
      preview.record({ content: "abc" })

      expect(preview.snapshot).to be_frozen
    end

    it 'replaces the snapshot wholesale on the next delta (no partial append)' do
      preview = described_class.new
      preview.record({ content: "one" })
      first = preview.snapshot
      preview.record({ content: " two" })

      expect(first).to eq("one")
      expect(preview.snapshot).to eq("one two")
    end

    it 'reports the characters received (for the log, not the console)' do
      preview = described_class.new
      preview.record({ content: "abc" })
      preview.record({ reasoning: "de" })

      expect(preview.received_chars).to eq(5)
    end
  end

  # The failure mode the snapshot exists to prevent: a reader must never see a
  # half-applied delta, and a reader error must never be able to break the
  # writer.
  it 'survives concurrent writers and readers without raising' do
    preview = described_class.new(max_tail: 20)
    writer  = Thread.new { 200.times { preview.record({ content: "x" }) } }
    reads   = 0
    reader  = Thread.new do
      200.times { reads += 1 if preview.tail_line.nil? || preview.tail_line.is_a?(String) }
    end
    writer.join
    reader.join

    expect(preview.received_chars).to eq(200)
    expect(reads).to eq(200)
  end
end
