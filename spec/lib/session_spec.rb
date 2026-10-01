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

    it 'prefers the last-call prompt_tokens over the accumulated usage' do
      # Multi-iteration turn: usage.prompt_tokens is the sum across calls
      # (overcounts), stats[:prompt_tokens] is the last call only (issue #81).
      session.add_user('hello')
      session.add_assistant('hi')
      session.record_stats(
        prompt_tokens: 35_000,
        usage: { prompt_tokens: 65_000, total_tokens: 70_000 }
      )

      expect(session.context_used).to eq(tokens: 35_000, estimated: false)
    end

    it 'falls back to a rough estimate when usage is missing' do
      session.add_user('a' * 160) # 160 chars -> ~40 tokens at 4 chars/token
      result = session.context_used

      expect(result[:estimated]).to be(true)
      expect(result[:tokens]).to be > 0
    end
  end

  describe '#context_estimate (issue #126)' do
    it 'returns nil when there is no conversation yet' do
      expect(session.context_estimate).to be_nil
    end

    it 'estimates the CURRENT chain even when last_stats reports a smaller number' do
      session.add_user('a' * 160)
      session.add_assistant('b' * 160)
      # A stale, small reported usage must NOT mask the larger live chain.
      session.record_stats(usage: { prompt_tokens: 5, total_tokens: 9 })

      expect(session.context_estimate[:tokens]).to be > 5
    end

    it 'grows as the chain grows (live, not a frozen snapshot)' do
      session.add_user('a' * 40)
      small = session.context_estimate[:tokens]
      session.add_assistant('b' * 400)
      expect(session.context_estimate[:tokens]).to be > small
    end
  end

  describe '#reset_stats (issue #108)' do
    it 'clears the last stats and reasoning' do
      session.add_user('hello')
      session.add_assistant('hi')
      session.record_stats(prompt_tokens: 9000, usage: {})
      session.record_reasoning('some thinking')

      session.reset_stats

      expect(session.instance_variable_get(:@last_stats)).to be_nil
      expect(session.last_reasoning).to be_nil
    end
  end

  describe '#context_pct' do
    before do
      session.add_user('hello')
      session.add_assistant('hi')
      session.record_stats(usage: { prompt_tokens: 60_000, total_tokens: 61_000 })
    end

    it 'returns the usage as a rounded percentage of the window' do
      expect(session.context_pct(65_536)).to eq(92)
    end

    it 'is nil when there is no conversation yet' do
      expect(described_class.new('sys').context_pct(65_536)).to be_nil
    end

    it 'is nil for an invalid window size' do
      expect(session.context_pct(0)).to be_nil
    end

    it 'reports above 100% when usage exceeds the window (no clamping)' do
      session.record_stats(usage: { prompt_tokens: 200_000, total_tokens: 200_000 })
      expect(session.context_pct(65_536)).to eq(305)
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
