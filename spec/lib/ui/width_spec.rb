# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'ui/console'
require 'ui/width'

# A sink that REPORTS a terminal size the way a real terminal File does
# (#winsize answers [rows, columns], so the columns are index 1). A plain
# StringIO has no #winsize, so it answers nil and the caller's fallback applies.
# Named apart from spinner_spec's top-level SizedSink: two spec files defining the
# same top-level name collide.
class WidthSink < StringIO
  def initialize(columns)
    super(+'')
    @columns = columns
  end

  attr_accessor :columns

  def winsize
    [24, @columns]
  end

  def tty?
    false
  end
end

RSpec.describe UI::Width do
  describe 'the two forms of a width' do
    it 'a char count is used as asked and clamped to the terminal' do
      expect(described_class.resolve(value: 120, terminal: 176)).to eq(120)
      expect(described_class.resolve(value: 120, terminal: 100)).to eq(100)
    end

    # An explicit count is NOT capped below what was requested - that is exactly
    # what the caller asked for. Only a resolved PERCENTAGE is capped, so a wide
    # terminal does not produce a paragraph nobody can read.
    it 'honors a count past the reading maximum' do
      expect(described_class.resolve(value: 140, terminal: 176)).to eq(140)
    end

    it 'takes a percentage of the terminal and caps it for prose' do
      expect(described_class.resolve(value: '85%', terminal: 176)).to eq(120)
      expect(described_class.resolve(value: '50%', terminal: 176)).to eq(88)
    end

    it 'falls back when a percentage has no terminal to apply to' do
      expect(described_class.resolve(value: '85%', terminal: nil, fallback: 78)).to eq(78)
    end

    it 'resolves nothing when nothing is given, using the default percentage' do
      expect(described_class.resolve(value: nil, terminal: 176)).to eq(120) # 80% capped
      expect(described_class.resolve(value: nil, terminal: 80)).to eq(64)   # 80% of 80
      expect(described_class.resolve(value: nil, terminal: 100)).to eq(80)  # 80% of 100
    end

    it 'can be told not to cap (a table basis the caller sized itself)' do
      expect(described_class.resolve(value: '85%', terminal: 176, cap: nil)).to eq(149)
    end
  end

  describe 'the reading maximum' do
    it 'is around 120 columns for a text paragraph' do
      expect(described_class::MAX_PARAGRAPH_WIDTH).to eq(120)
    end

    it 'the default percentage is 80% of the terminal' do
      expect(described_class::DEFAULT_PERCENT).to eq(80)
    end
  end

  describe 'detecting the terminal' do
    it 'reads the columns of the sink the text is written to' do
      expect(described_class.detect_columns(WidthSink.new(160))).to eq(160)
    end

    it 'a sink with no winsize (a spec StringIO, a pipe) answers nil' do
      expect(described_class.detect_columns(StringIO.new)).to be_nil
      expect(described_class.detect_columns(nil)).to be_nil
    end

    it 'a zero or negative reported width is not a width' do
      expect(described_class.detect_columns(WidthSink.new(0))).to be_nil
    end

    # A UI::Console is NOT a stream, so a caller holding the SINK reads its stdout:
    # the Console itself has no #winsize, and its stream does.
    it 'reads the SINK through its stream, not the sink object itself' do
      console = UI::Console.new(stdout: WidthSink.new(150))

      expect(console.respond_to?(:winsize)).to be false
      expect(described_class.columns_for(console)).to eq(150)
    end
  end

  describe 'reserving columns' do
    # Only a DETECTED width is reserved: a line written into every column makes the
    # terminal wrap it, which lands the next control sequence on the wrong row.
    it 'reserves a column from a detected width' do
      expect(described_class.reserve_amount(160, described_class::RESERVED_COLUMNS)).to eq(159)
    end

    it 'never reserves from nothing' do
      expect(described_class.reserve_amount(nil, 1)).to be_nil
      expect(described_class.reserve_amount(1, 5)).to eq(1)
    end
  end
end
