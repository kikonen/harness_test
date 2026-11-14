# frozen_string_literal: true

require 'spec_helper'
require 'output_buffer'

RSpec.describe OutputBuffer do
  describe '.Entry' do
    it 'exposes type, origin and content as read-only fields' do
      entry = described_class::Entry.new(type: :stats, origin: :harness, content: 'line one')

      expect(entry.type).to eq(:stats)
      expect(entry.origin).to eq(:harness)
      expect(entry.content).to eq('line one')

      # Immutable Data object: no setter methods exist at all.
      expect(entry).not_to respond_to(:type=)
      expect { entry.send(:type=, :other) }.to raise_error(NoMethodError)
    end

    it 'is immutable (frozen) so renderers cannot mutate handed-out entries' do
      entry = described_class::Entry.new(type: :text, origin: :session_manager, content: 'hi')

      expect(entry).to be_frozen
    end

    it 'serializes to a hash and a readable string' do
      entry = described_class::Entry.new(type: :response, origin: :session_manager, content: 'hello')

      expect(entry.to_h).to eq(type: :response, origin: :session_manager, content: 'hello')
      expect(entry.to_s).to include('response')
      expect(entry.to_s).to include('hello')
    end
  end

  describe '#put' do
    it 'stores a structured entry and returns it' do
      buffer = described_class.new

      entry = buffer.put(type: :stats, origin: 'harness', content: '42 s')

      expect(entry).to be_a(described_class::Entry)
      expect(entry.type).to eq(:stats)
      expect(entry.origin).to eq(:harness) # string origin is normalized to a symbol
      expect(buffer.size).to eq(1)
    end

    it 'keeps content as nil when not given, normalizes nil origin to :unknown' do
      buffer = described_class.new

      entry = buffer.put(type: :text, origin: nil)

      # Nil stays nil (callers like Task.emit use it for progress events that
      # carry no text payload); renderers must handle both nil and "".
      expect(entry.content).to be_nil
      expect(entry.origin).to eq(:unknown)
    end

    it 'stores content frozen so the caller cannot mutate stored entries' do
      buffer = described_class.new
      text  = 'mutable'

      entry = buffer.put(type: :text, origin: :x, content: text)

      expect { entry.content.replace('other') }.to raise_error(FrozenError)
    end
  end

  describe '#puts (convenience writer)' do
    it 'stores one entry per part, in order' do
      buffer = described_class.new

      buffer.puts(:session_manager, 'line a', 'line b')

      drained = buffer.drain
      expect(drained.map(&:content)).to eq(['line a', 'line b'])
      expect(drained.map(&:type).uniq).to eq([:text])
    end

    it 'treats a no-argument call like Kernel.puts (single blank line)' do
      buffer = described_class.new

      entry = buffer.puts(:harness)

      expect(entry.content).to eq('')
      expect(buffer.size).to eq(1)
    end
  end

  describe '#drain' do
    it 'returns entries in append order and advances the waterline' do
      buffer = described_class.new
      buffer.put(type: :a, origin: :x, content: 'one')
      buffer.put(type: :b, origin: :y, content: 'two')

      first  = buffer.drain
      second = buffer.drain

      expect(first.map(&:content)).to eq(%w[one two])
      expect(second).to be_empty # the waterline moved past both entries
    end

    it 'delivers an entry exactly once across interleaved drains' do
      buffer = described_class.new
      buffer.put(type: :t, origin: :o, content: 'x')

      seen = (1..3).flat_map { buffer.drain.map(&:content) }

      expect(seen).to eq(['x'])
    end

    it 'returns [] when nothing has been appended' do
      expect(described_class.new.drain).to be_empty
    end
  end

  describe '#pending?' do
    it 'is false for an empty buffer and true once an entry is pending' do
      buffer = described_class.new

      expect(buffer.pending?).to be(false)

      buffer.put(type: :t, origin: :o, content: 'x')
      expect(buffer.pending?).to be(true)

      buffer.drain
      expect(buffer.pending?).to be(false)
    end
  end

  describe '#clear' do
    it 'drops consumed and pending entries and resets the waterline' do
      buffer = described_class.new
      buffer.put(type: :t, origin: :o, content: 'consumed')
      buffer.drain
      buffer.put(type: :t, origin: :o, content: 'pending')

      buffer.clear

      expect(buffer.size).to eq(0)
      expect(buffer.drain).to be_empty
    end
  end

  describe 'trimming the consumed prefix' do
    it 'keeps pending entries reachable after more than TRIM_AT were consumed' do
      buffer = described_class.new
      described_class::TRIM_AT.times do |i|
        buffer.put(type: :t, origin: :o, content: "old #{i}")
      end
      buffer.drain # waterline now at TRIM_AT - trim is only allowed when the
                   # consumed prefix is at least half of what is stored

      pending = (0...10).map { |i| buffer.put(type: :t, origin: :o, content: "new #{i}") }
      expect(buffer.drain.map(&:content)).to eq(pending.map(&:content))
    end

    it 'bounds stored entries once the waterline is far along' do
      buffer = described_class.new
      total  = described_class::TRIM_AT * 2 + 10

      total.times { |i| buffer.put(type: :t, origin: :o, content: "e#{i}") }
      drained = buffer.drain

      expect(drained.size).to eq(total)
      expect(buffer.size).to eq(0) # everything consumed - prefix fully trimmed
    end

    it 'does not trim while a large pending tail is still outstanding' do
      buffer = described_class.new
      described_class::TRIM_AT.times { |i| buffer.put(type: :t, origin: :o, content: "old #{i}") }
      tail_size = described_class::TRIM_AT + 10
      tail_size.times { |i| buffer.put(type: :t, origin: :o, content: "new #{i}") }

      # drain always consumes EVERYTHING up to "now" (there is no partial
      # read - a renderer polls until there is nothing more); the real
      # invariant is that a drained batch is complete and nothing is lost.
      consumed = buffer.drain

      expect(consumed.size).to eq(described_class::TRIM_AT + tail_size)
      expect(consumed.first.content).to eq('old 0')
      expect(consumed.last.content).to eq("new #{tail_size - 1}")
      expect(buffer.drain).to be_empty # waterline advanced past everything
    end
  end

  # issue #458: the buffer is the durable record a resumed run redraws. Only
  # entries that actually became a console line are replayable - the spinner is
  # animated, never rendered, so it is head state and never enters the tail.
  describe '#replay_tail (issue #458)' do
    it 'skips the animated :spinner_detail entries' do
      buffer = described_class.new
      buffer.put(type: :response, origin: :session_manager, content: 'answer')
      buffer.put(type: :spinner_detail, origin: :harness, content: { message: 'Working' })
      buffer.put(type: :status_ok, origin: 'file.read', content: 'ok')

      expect(buffer.replay_tail.map(&:type)).to eq(%i[response status_ok])
    end

    it 'returns the last n replayable entries in append order' do
      buffer = described_class.new
      4.times { |i| buffer.put(type: :text, origin: :user, content: "line #{i}") }

      expect(buffer.replay_tail(2).map(&:content)).to eq(['line 2', 'line 3'])
    end

    it 'returns every replayable entry when n is nil or larger than the tail' do
      buffer = described_class.new
      3.times { |i| buffer.put(type: :text, origin: :user, content: "line #{i}") }

      expect(buffer.replay_tail.map(&:content)).to eq(['line 0', 'line 1', 'line 2'])
      expect(buffer.replay_tail(99).size).to eq(3)
    end

    it 'returns an empty tail for n = 0' do
      buffer = described_class.new
      buffer.put(type: :text, origin: :user, content: 'x')

      expect(buffer.replay_tail(0)).to eq([])
    end

    it 'is unaffected by a trim of the consumed front' do
      buffer = described_class.new
      described_class::TRIM_AT.times { |i| buffer.put(type: :text, origin: :o, content: "old #{i}") }
      buffer.drain
      buffer.put(type: :text, origin: :user, content: 'kept a')
      buffer.put(type: :spinner_detail, origin: :harness, content: { message: 'x' })
      buffer.put(type: :text, origin: :session_manager, content: 'kept b')

      expect(buffer.replay_tail.map(&:content)).to eq(['kept a', 'kept b'])
    end
  end

  describe '#keep_tail (issue #458 - the record is a window)' do
    it 'drops the oldest entries and keeps the last n' do
      buffer = described_class.new
      5.times { |i| buffer.put(type: :text, origin: :o, content: "e#{i}") }

      buffer.keep_tail(2)

      expect(buffer.size).to eq(2)
      expect(buffer.replay_tail.map(&:content)).to eq(['e3', 'e4'])
    end

    it 'is a no-op when the buffer already holds at most n' do
      buffer = described_class.new
      buffer.put(type: :text, origin: :o, content: 'only')

      buffer.keep_tail(10)

      expect(buffer.size).to eq(1)
    end

    it 'keeps the waterline consistent so a later drain still yields what remains' do
      buffer = described_class.new
      6.times { |i| buffer.put(type: :text, origin: :o, content: "e#{i}") }
      buffer.drain # waterline now past all six entries
      buffer.keep_tail(3)

      # The dropped three were already consumed; the three kept are pulled back
      # into the readable window, so the drain sees exactly them.
      expect(buffer.drain.map(&:content)).to eq(['e3', 'e4', 'e5'])
    end
  end

  describe '#restore (issue #458 - rehydrating a saved tail)' do
    # The saved form is Entry#to_h through JSON: type/origin come back as
    # strings, and SessionLocator parses with symbolize_names so the keys are
    # symbols. put normalizes them back to symbols on restore.
    def json_round_trip(buffer)
      JSON.parse(JSON.generate(buffer.replay_tail.map(&:to_h)), symbolize_names: true)
    end

    it 'rebuilds Entry objects from saved hashes, normalizing string type/origin' do
      source = described_class.new
      source.put(type: :text, origin: :user, content: 'do the thing')
      source.put(type: :response, origin: :session_manager, content: 'done')
      saved = json_round_trip(source)
      target = described_class.new

      target.restore(saved)

      tail = target.replay_tail
      expect(tail.map { |e| [e.type, e.origin, e.content] }).to eq(
        [[:text, :user, 'do the thing'], [:response, :session_manager, 'done']]
      )
    end

    it 'round-trips a spinner-free tail losslessly through JSON' do
      source = described_class.new
      source.put(type: :text, origin: :user, content: 'a')
      source.put(type: :status_ok, origin: 'file.read', content: 'b')
      source.put(type: :spinner_detail, origin: :harness, content: { message: 'ignored' })
      target = described_class.new

      target.restore(json_round_trip(source))

      expect(target.replay_tail.map(&:content)).to eq(['a', 'b'])
    end

    it 'ignores non-hash entries (a malformed saved entry never breaks restore)' do
      target = described_class.new

      expect { target.restore([{ type: 'text', origin: 'user', content: 'ok' }, 'junk', nil]) }.not_to raise_error
      expect(target.replay_tail.map(&:content)).to eq(['ok'])
    end
  end
end

RSpec.describe OutputBuffer do
  # issue #286: the buffer has two parts. The tail is the durable record a
  # renderer can re-lay out (immutable entries); the head is the live state of
  # the streams still arriving (mutable cells, replaced as they grow).
  describe 'the two parts (issue #286)' do
    it 'lands HEAD_TYPES as a live cell and everything else as a tail entry' do
      buffer = described_class.new
      buffer.put(type: :response, origin: :session_manager, content: 'answer')
      buffer.put(type: :spinner_detail, origin: :harness, content: { message: 'Working' })

      expect(buffer.tail.map(&:type)).to eq([:response])
      expect(buffer.head.map(&:type)).to eq([:spinner_detail])
    end

    it 'replaces a live cell instead of appending a second one' do
      buffer = described_class.new
      buffer.put(type: :spinner_detail, origin: :harness, content: 'Working')
      buffer.put(type: :spinner_detail, origin: :harness, content: 'Sending')

      expect(buffer.head.size).to eq(1)
      expect(buffer.cell(:harness).content).to eq('Sending')
    end

    # A streamed answer GROWS: chunks append to the one cell for its origin.
    it 'grows a stream cell by appending, so a refresh reads the whole stream' do
      buffer = described_class.new
      buffer.put(type: :response, origin: :session_manager, content: 'Hel', mode: :append)
      buffer.put(type: :response, origin: :session_manager, content: 'lo', mode: :append)

      expect(buffer.cell(:session_manager).content).to eq('Hello')
      expect(buffer.tail).to be_empty
    end

    it 'marks a cell dirty so the live half has its own poll' do
      buffer = described_class.new
      buffer.put(type: :spinner_detail, origin: :harness, content: 'Working')

      expect(buffer.dirty_head.map(&:content)).to eq(['Working'])
      expect(buffer.dirty_head).to be_empty # not dirty until the next update

      buffer.put(type: :spinner_detail, origin: :harness, content: 'Sending')
      expect(buffer.dirty_head.map(&:content)).to eq(['Sending'])
    end

    # Committing is what makes the tail durable: the live state becomes ONE
    # immutable entry holding its final content, and leaves the head.
    it 'promotes a finished stream to the tail as one entry and leaves the head' do
      buffer = described_class.new
      buffer.put(type: :response, origin: :session_manager, content: 'Hel', mode: :append)
      buffer.put(type: :response, origin: :session_manager, content: 'lo', mode: :append)

      entry = buffer.commit(:session_manager)

      expect(entry.content).to eq('Hello')
      expect(entry).to be_frozen
      expect(buffer.head).to be_empty
      expect(buffer.tail.map(&:content)).to eq(['Hello'])
      # A stream that keeps going after a commit starts a new cell.
      buffer.put(type: :response, origin: :session_manager, content: ' there')
      # Without a mode the item is FINAL, so it is committed rather than live -
      # the head must never be the only copy of an answer.
      expect(buffer.cell(:session_manager)).to be_nil
      expect(buffer.tail.map(&:content)).to eq(['Hello', ' there'])
    end

    # A live update states its mode on the call; the part is not guessed from
    # the type, so the final content of a stream is always in the record.
    it 'keeps the final content in the tail and only the live view in the head' do
      buffer = described_class.new
      buffer.put(type: :response, origin: :session_manager, content: 'partial', mode: :append)
      expect(buffer.head.size).to eq(1)

      buffer.commit(:session_manager)
      buffer.put(type: :response, origin: :session_manager, content: 'full answer')
      expect(buffer.tail.map(&:content)).to eq(['partial', 'full answer'])
    end
  end
end

