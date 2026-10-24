# frozen_string_literal: true

require 'spec_helper'
require 'llm/stream_preview'

# The live tail and live rate of a streamed answer for the spinner. The task
# thread WRITES them (the on_delta callback) and the MAIN thread READS them (the
# spinner evaluates its suffix callable every frame), so #record publishes a
# frozen snapshot rather than exposing a mutable String.
# A fake clock the spec advances by hand: a rate spec must not depend on how
# long the machine took between two records.
class PreviewFakeClock
  def initialize
    @t = 100.0
  end

  def call = @t

  def advance(seconds)
    @t += seconds
  end
end

RSpec.describe LLM::StreamPreview do
  def preview(max_tail: LLM::StreamPreview::MAX_TAIL, clock: PreviewFakeClock.new, chars_per_token: 4)
    [described_class.new(max_tail: max_tail, chars_per_token: chars_per_token, clock: clock), clock]
  end

  describe '#record / #tail_line' do
    it 'has no tail before anything arrives (the spinner shows the ctx instead)' do
      subject, = preview

      expect(subject.tail_line).to be_nil
    end

    it 'shows the content received so far' do
      subject, = preview
      subject.record({ content: "Reading the" })

      expect(subject.tail_line).to eq("Reading the")
    end

    it 'appends later deltas' do
      subject, = preview
      subject.record({ content: "Hello" })
      subject.record({ content: " world" })

      expect(subject.tail_line).to eq("Hello world")
    end

    it 'shows reasoning when the model has produced only reasoning' do
      subject, = preview
      subject.record({ reasoning: "let me check" })

      expect(subject.tail_line).to eq("let me check")
    end

    it 'prefers content once the answer itself has started' do
      subject, = preview
      subject.record({ reasoning: "thinking hard" })
      subject.record({ content: "the answer" })

      expect(subject.tail_line).to eq("the answer")
    end

    it 'ignores a delta with no text part' do
      subject, = preview
      subject.record({ content: "a" })
      subject.record({})

      expect(subject.tail_line).to eq("a")
    end

    it 'ignores a nil delta' do
      subject, = preview
      subject.record(nil)

      expect(subject.tail_line).to be_nil
    end

    it 'keeps an empty-string delta from erasing the tail' do
      subject, = preview
      subject.record({ content: "abc" })
      subject.record({ content: "" })

      expect(subject.tail_line).to eq("abc")
    end
  end

  describe 'the tail length' do
    it 'keeps the newest part when the answer is longer than the tail' do
      subject, = preview(max_tail: 10)
      subject.record({ content: "0123456789abcdefghij" })

      # The LAST max_tail characters: the newest part is what the user wants.
      expect(subject.tail_line).to eq("...abcdefghij")
    end

    it 'marks a truncated tail with a leading ellipsis' do
      subject, = preview(max_tail: 5)
      subject.record({ content: "123456789" })

      expect(subject.tail_line).to start_with("...")
    end

    it 'does not mark a tail that is the whole answer' do
      subject, = preview(max_tail: 20)
      subject.record({ content: "short" })

      expect(subject.tail_line).to eq("short")
    end

    it 'marks the tail when only the reasoning overflowed' do
      subject, = preview(max_tail: 6)
      subject.record({ reasoning: "reasoning longer than six" })

      expect(subject.tail_line).to eq("...an six")
    end

    it 'defaults to a 60-char tail' do
      expect(described_class::MAX_TAIL).to eq(60)
    end

    it 'collapses newlines so the tail stays one spinner line' do
      subject, = preview(max_tail: 40)
      subject.record({ content: "line one\nline two\n" })

      expect(subject.tail_line).not_to include("\n")
    end
  end

  describe '#live_rate (issue #285)' do
    it 'is nil before anything arrives (no text, no measurement)' do
      subject, = preview

      expect(subject.live_rate).to be_nil
    end

    it 'is nil for the first delta (too short a window to be a speed)' do
      subject, = preview
      subject.record({ content: "hi" })

      expect(subject.live_rate).to be_nil
    end

    it 'measures tokens over the seconds the deltas took' do
      subject, clock = preview
      subject.record({ content: "#{'x' * 80}" }) # 20 tokens at 4 chars/token
      clock.advance(2.0)
      subject.record({ content: "#{'y' * 80}" }) # 20 more tokens

      expect(subject.live_rate).to eq(20.0) # 40 tokens / 2s
    end

    it 'counts reasoning too (it is text the model is producing)' do
      subject, clock = preview
      subject.record({ reasoning: "#{'r' * 80}" })
      clock.advance(1.0)
      subject.record({ reasoning: "#{'r' * 80}" })

      expect(subject.live_rate).to eq(40.0)
    end

    it 'starts the clock at the FIRST delta, not at construction (prefill is not generation)' do
      subject, clock = preview
      clock.advance(60.0) # the server spends a minute on the prompt
      subject.record({ content: "#{'x' * 80}" })
      clock.advance(1.0)
      subject.record({ content: "#{'x' * 80}" })

      # Only the 1 second AFTER text started counts: 40 tokens / 1s = 40, not
      # 40 / 61s a construction-based clock would report.
      expect(subject.live_rate).to eq(40.0)
    end

    it 'stays nil below the noise floor however many deltas arrive' do
      subject, clock = preview
      3.times { clock.advance(0.01); subject.record({ content: "x" }) }

      expect(subject.live_rate).to be_nil
    end

    it 'uses the injected chars-per-token ratio' do
      subject, clock = preview(chars_per_token: 2)
      subject.record({ content: "#{'x' * 40}" }) # 20 tokens at 2 chars/token
      clock.advance(2.0)
      subject.record({ content: "#{'x' * 40}" })

      expect(subject.live_rate).to eq(20.0)
    end
  end

  describe 'the snapshot (the cross-thread contract)' do
    it 'publishes an immutable snapshot the reader cannot mutate' do
      subject, = preview
      subject.record({ content: "abc" })

      expect(subject.snapshot).to be_frozen
    end

    it 'replaces the snapshot wholesale on the next delta (no partial append)' do
      subject, = preview
      subject.record({ content: "one" })
      first = subject.snapshot
      subject.record({ content: " two" })

      expect(first).to eq("one")
      expect(subject.snapshot).to eq("one two")
    end

    # The rate is published WITH the tail: the reader never recomputes from the
    # counters the writer is in the middle of mutating.
    it 'publishes the rate in the same snapshot update as the tail' do
      subject, clock = preview
      subject.record({ content: "#{'x' * 80}" })
      clock.advance(2.0)
      subject.record({ content: "#{'x' * 80}" })
      published = subject.live_rate

      clock.advance(2.0)
      subject.record({ content: "#{'x' * 80}" })

      expect(published).to eq(20.0)
      expect(subject.live_rate).to eq(15.0) # 60 tokens / 4s
    end

    it 'reports the characters received (for the log, not the console)' do
      subject, = preview
      subject.record({ content: "abc" })
      subject.record({ reasoning: "de" })

      expect(subject.received_chars).to eq(5)
    end

    it 'converts those characters to estimated tokens' do
      subject, = preview(chars_per_token: 4)
      subject.record({ content: "#{'x' * 10}" })

      expect(subject.received_tokens).to eq(3) # ceil(10 / 4)
    end
  end

  # The failure mode the snapshot exists to prevent: a reader must never see a
  # half-applied delta, and a reader error must never be able to break the
  # writer.
  it 'survives concurrent writers and readers without raising' do
    subject, = preview(max_tail: 20)
    writer = Thread.new { 200.times { subject.record({ content: "x" }) } }
    reads  = 0
    reader = Thread.new do
      200.times do
        reads += 1 if subject.tail_line.nil? || subject.tail_line.is_a?(String)
        reads += 1 if subject.live_rate.nil? || subject.live_rate.is_a?(Numeric)
      end
    end
    writer.join
    reader.join

    expect(subject.received_chars).to eq(200)
    expect(reads).to eq(400)
  end
end
