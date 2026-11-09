# frozen_string_literal: true

require 'spec_helper'
require 'ui/text_wrap'

# Shared greedy word wrap used by the renderer's :note prose and the dialog's
# wrapped notes/descriptions (#470, #476). A fitting line is returned verbatim;
# a word wider than the width gets its own line (never split).
RSpec.describe UI::TextWrap do
  describe '.line' do
    it 'returns a fitting line verbatim (no whitespace re-flow)' do
      expect(described_class.line("  keeps   spacing  ", 80)).to eq(["  keeps   spacing  "])
    end

    it 'wraps a long line greedily to the width' do
      out = described_class.line('one two three four five six seven eight nine ten', 15)

      expect(out).to eq(['one two three', 'four five six', 'seven eight', 'nine ten'])
    end

    it 'never splits a word wider than the width' do
      expect(described_class.line('aaaaaaaaaaaaaaaaaaaaaa bb', 10))
        .to eq(['aaaaaaaaaaaaaaaaaaaaaa', 'bb'])
    end

    it 'returns [] for blank input' do
      expect(described_class.line('', 10)).to eq([])
    end
  end

  describe '.paragraphs' do
    it 'wraps each newline-separated paragraph and indents every line' do
      out = described_class.paragraphs("first para here\nsecond para here", 12, "  ")

      expect(out).to eq(["  first para", "  here", "  second para", "  here"])
    end
  end
end
