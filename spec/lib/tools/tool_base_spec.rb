# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Tool do
  describe '.denial_error' do
    it 'returns the plain message when there is no result' do
      expect(described_class.denial_error("error: access denied for 'x'"))
        .to eq("error: access denied for 'x'")
    end

    it 'returns the plain message for a denial without a note' do
      result = { status: :denied, note: nil }
      expect(described_class.denial_error("error: access denied for 'x'", result))
        .to eq("error: access denied for 'x'")
    end

    it 'appends the user\'s note when present' do
      result = { status: :denied, note: 'no, and because X' }
      expect(described_class.denial_error("error: access denied for 'x'", result))
        .to eq("error: access denied for 'x' (user's note: \"no, and because X\")")
    end

    it 'is safe for legacy :denied symbols' do
      expect(described_class.denial_error("error: access denied for 'x'", :denied))
        .to eq("error: access denied for 'x'")
    end

    it 'ignores non-denial results' do
      expect(described_class.denial_error('error: x', :granted))
        .to eq('error: x')
    end
  end

  describe '.granted?' do
    it 'is true only for :granted' do
      expect(described_class.granted?(:granted)).to be(true)
      expect(described_class.granted?({ status: :denied, note: nil })).to be(false)
      expect(described_class.granted?(:blocked)).to be(false)
    end
  end
end
