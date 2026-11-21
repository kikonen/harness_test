# frozen_string_literal: true

require 'spec_helper'
require 'output_budget'

# The gate exists for ONE shape (issue #551): output with few newlines and huge
# lines. A line count cannot bound it, so bytes are bounded too and a single
# oversized line is clipped within itself.
RSpec.describe OutputBudget do
  def blob(size)
    'A' * size
  end

  describe '.fit' do
    it 'leaves output within the byte budget untouched' do
      text = (1..50).map { |i| "line #{i}" }.join("\n")
      fit  = described_class.fit(text, limit: 10_000)

      expect(fit.text).to eq(text)
      expect(fit).not_to be_truncated
      expect(fit.bytes_dropped).to eq(0)
    end

    # The #551 case: 500 x 20KB passed the old 500-line gate whole (10 MB kept).
    it 'catches many huge lines that a line limit lets through whole' do
      text = Array.new(500) { blob(20_000) }.join("\n")
      fit  = described_class.fit(text, limit: 48_000)

      expect(fit).to be_truncated
      expect(fit.text.bytesize).to be <= 48_000 + 200
      expect(fit.bytes_dropped).to be > 9_900_000
    end

    it 'catches the single huge line no line-shaped rule can catch' do
      fit = described_class.fit(blob(4_000_000), limit: 48_000)

      expect(fit).to be_truncated
      expect(fit.text.bytesize).to be <= 48_000 + 200
      expect(fit.text).to start_with('AAAA')
      # The tail of the dump survives too (the #537 head+tail rule, per line).
      expect(fit.text).to end_with('AAAA')
      expect(fit.text).to include('bytes of this line omitted')
    end

    it 'keeps the head AND the tail of a many-line result (issue #537 shape)' do
      text = (1..1000).map { |i| "line #{i}" }.join("\n")
      fit  = described_class.fit(text, limit: 500, limit_lines: 10)

      expect(fit.text).to include('line 1')
      expect(fit.text).to include('line 1000')
      expect(fit.text).not_to include('line 500')
      expect(fit.lines_dropped).to eq(990)
    end

    it 'drops whole lines when line clipping alone cannot fit the budget' do
      text = Array.new(100) { blob(30_000) }.join("\n")
      fit  = described_class.fit(text, limit: 48_000)

      expect(fit.text.bytesize).to be <= 48_000 + 200
      expect(fit.text).to include("bytes omitted")
    end

    it 'names the spill path in the notice it appends' do
      text = blob(100_000)
      fit  = described_class.fit(text, limit: 10_000)
      full = fit.text + described_class.notice(fit.bytes_dropped,
                                               spill: '.harness/sessions/x/results/run-1.txt')

      expect(full).to include('read the full text saved to .harness/sessions/x/results/run-1.txt')
      expect(full.bytesize).to be < text.bytesize
    end

    it 'is a no-op on an empty result' do
      fit = described_class.fit('', limit: 100)

      expect(fit.text).to eq('')
      expect(fit).not_to be_truncated
    end
  end

  describe '.clip_line' do
    it 'leaves an ordinary line intact' do
      line = 'x' * 4_000

      expect(described_class.clip_line(line)).to eq(line)
    end

    it 'clips only a grossly oversized line, keeping both ends' do
      line = described_class.clip_line(blob(60_000))

      expect(line.bytesize).to be < 60_000
      expect(line).to start_with('AAAA')
      expect(line).to end_with('AAAA')
      expect(line).to include('...40000 bytes of this line omitted...')
    end
  end

  # A byte cut must never land mid-character: a broken character in a tool result
  # is what makes the next JSON.generate raise (the #257 family).
  describe 'character boundaries' do
    it 'clips without splitting a multi-byte character' do
      line = ("\u00e4" * 30_000)
      clipped = described_class.clip_line(line)

      expect(clipped.encoding).to eq(Encoding::UTF_8)
      expect(clipped.valid_encoding?).to be true
    end

    it 'keeps the result valid UTF-8 for a session save' do
      text = ("\u4e2d" * 50_000)
      fit  = described_class.fit(text, limit: 10_000)

      expect(fit.text.valid_encoding?).to be true
      expect { JSON.generate({ 'result' => fit.text }) }.not_to raise_error
    end
  end
end
