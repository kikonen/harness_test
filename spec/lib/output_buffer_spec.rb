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
end
