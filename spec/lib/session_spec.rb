# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Session do
  let(:session) { described_class.new('system prompt') }

  describe '#context_used' do
    it 'returns nil when there is no conversation yet' do
      expect(session.context_used).to be_nil
    end

    it 'reports the last response usage when available' do
      session.add_user('hello')
      session.add_assistant('hi')
      session.record_stats(usage: { prompt_tokens: 1234, total_tokens: 1500 })

      expect(session.context_used).to eq(tokens: 1234, estimated: false)
    end

    it 'falls back to a rough estimate when usage is missing' do
      session.add_user('a' * 160) # 160 chars -> ~40 tokens at 4 chars/token
      result = session.context_used

      expect(result[:estimated]).to be(true)
      expect(result[:tokens]).to be > 0
    end
  end

  describe '#auto_compact_due?' do
    before do
      session.add_user('hello')
      session.add_assistant('hi')
      session.record_stats(usage: { prompt_tokens: 60_000, total_tokens: 61_000 })
    end

    it 'is due when usage reached the threshold' do
      expect(session.auto_compact_due?(65_536, 88)).to be(true)
    end

    it 'is not due below the threshold' do
      expect(session.auto_compact_due?(65_536, 99)).to be(false)
    end

    it 'can be disabled with a threshold above 100' do
      expect(session.auto_compact_due?(65_536, 1000)).to be(false)
    end

    it 'is false when the window size is invalid' do
      expect(session.auto_compact_due?(0, 88)).to be(false)
    end
  end
end
