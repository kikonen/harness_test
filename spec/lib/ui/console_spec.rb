# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'ui/console'

RSpec.describe UI::Console do
  def console(stdout: StringIO.new, stdin: nil)
    [described_class.new(stdout: stdout, stdin: stdin), stdout]
  end

  describe '#initialize' do
    it 'refuses a nil stdout (a write sink is the whole point)' do
      expect { described_class.new(stdout: nil) }
        .to raise_error(ArgumentError, /non-nil stdout/)
    end

    it 'accepts a stdout-only construction (the read side is optional)' do
      expect { described_class.new(stdout: StringIO.new) }.not_to raise_error
    end
  end

  describe 'writing' do
    it 'puts writes lines like IO#puts' do
      subject, stdout = console
      subject.puts('one', 'two')

      expect(stdout.string).to eq("one\ntwo\n")
    end

    it 'puts with no arguments writes just a newline' do
      subject, stdout = console
      subject.puts

      expect(stdout.string).to eq("\n")
    end

    it 'print writes without a trailing newline' do
      subject, stdout = console
      subject.print('no newline')

      expect(stdout.string).to eq('no newline')
    end

    it 'flush reaches the underlying stream' do
      stdout = StringIO.new
      subject = described_class.new(stdout: stdout)

      expect(stdout).to receive(:flush)
      subject.flush
    end

    # The reason the pair exists at all: a TUI sink can be injected without
    # touching a call site, so any object answering these messages works.
    it 'routes to whatever object it was given (any puts/print/flush sink)' do
      sink = Object.new
      sink.define_singleton_method(:print) { |text| @seen = text }
      sink.define_singleton_method(:seen) { @seen }

      described_class.new(stdout: sink).print('routed')

      expect(sink.seen).to eq('routed')
    end
  end

  describe '#gets' do
    it 'reads one line from stdin' do
      subject, _ = console(stdin: StringIO.new("typed\nmore\n"))

      expect(subject.gets).to eq("typed\n")
      expect(subject.gets).to eq("more\n")
    end

    it 'returns nil at end of input' do
      subject, _ = console(stdin: StringIO.new(''))

      expect(subject.gets).to be_nil
    end

    it 'returns nil when no stdin was given (instead of raising)' do
      subject, _ = console

      expect(subject.gets).to be_nil
    end
  end
end
