# frozen_string_literal: true

require_relative 'harness_spec_support'

RSpec.describe Harness do
  include HarnessSpecSupport

  describe '#context_indicator' do
    it 'is nil when there is no conversation yet' do
      expect(build_harness.context_indicator).to be_nil
    end

    it 'shows exact usage from the last response' do
      harness = build_harness
      seed_usage(harness, 42_133)

      expect(harness.context_indicator).to eq('🧠 ctx 42133/65536 (64%)')
    end

    it 'marks estimates with ~' do
      harness = build_harness
      harness.session.add_user('a' * 160) # ~40 tokens at 4 chars/token (estimate)

      expect(harness.context_indicator).to include('~')
    end

    it 'respects a custom context window from options' do
      harness = build_harness(num_ctx: 10_000)
      seed_usage(harness, 5_000)

      expect(harness.context_indicator).to eq('🧠 ctx 5000/10000 (50%)')
    end
  end

  describe '#context_indicator_live (issue #126)' do
    it 'is nil when there is no conversation yet' do
      expect(build_harness.context_indicator_live).to be_nil
    end

    # Issue #271: this is the SPINNER's segment - the percentage and the
    # window it is a percentage of, not the token arithmetic (which
    # #context_indicator and the /ctx report keep).
    it 'shows the percentage and the rounded window when usage was reported' do
      harness = build_harness
      seed_usage(harness, 5_915)

      expect(harness.context_indicator_live).to eq('🧠 9% (66K)')
    end

    it 'marks estimates with ~ when no usage was reported yet' do
      harness = build_harness
      harness.session.add_user('a' * 160)

      expect(harness.context_indicator_live).to include('~')
    end

    it 'always estimates an explicit chain (mid-turn / in-loop compaction)' do
      harness = build_harness_with_responses
      seed_usage(harness, 5_915)
      # seed_usage records stats only (no anchor), and this explicit chain
      # is not an extension of the session chain, so this is a plain raw
      # estimate - always marked '~' regardless of last_stats.
      chain = [{ role: 'user', content: 'a' * 400 }]

      expect(harness.context_indicator_live(chain)).to include('~')
    end
    # issue #216: after a turn, the server-reported prompt_tokens anchor the
    # live estimate, so a mid-turn chain that EXTENDS the session chain
    # shows the true number + new messages - not a from-scratch chars/4
    # re-estimate of the whole chain (which was wildly different).
    it 'anchors the live estimate to the server-reported count after a turn' do
      harness = build_harness_with_responses
      harness.session.add_user('hello')
      harness.call_llm # scripted client reports prompt_tokens: 10 -> anchor

      # The session chain (system + user + assistant 'done') is anchored at
      # 10. Extend it with a mid-turn tool result and re-estimate.
      extended = harness.session.messages.dup
      extended << { role: 'tool', tool_call_id: 't1', content: 'x' * 2000 }

      line = harness.context_indicator_live(extended)
      expect(line).to include('~')
      # The segment must carry the ANCHORED count (511 tokens = 1% of
      # 65536), not the from-scratch chars/4 estimate of the whole chain,
      # which also measures the system prompt and reads several percent
      # higher.
      expect(harness.session.anchored_estimate(extended)).to eq(511)
      expect(line).to eq('🧠 ~1% (66K)')
    end

    # The window is only ever read as an order of magnitude, so a five-digit
    # one is rounded to whole thousands; sub-thousand windows stay exact.
    it 'rounds the window to K, keeping a small window exact' do
      wide = build_harness(num_ctx: 160_000)
      wide.session.record_stats(prompt_tokens: 19_514,
                               usage: { prompt_tokens: 19_514 })
      expect(wide.context_indicator_live).to eq('🧠 12% (160K)')

      tiny = build_harness(num_ctx: 10)
      tiny.session.record_stats(prompt_tokens: 10, usage: { prompt_tokens: 10 })
      expect(tiny.context_indicator_live).to eq('🧠 100% (10)')
    end
  end

  # issue #474 increment 21: the report is FIELDS, not a printed block. The
  # arithmetic that decides a compaction is what these pins hold; /ctx renders them.
  describe '#context_usage' do
    it 'answers nil for an empty session (nothing to measure)' do
      expect(build_harness.context_usage).to be_nil
    end

    it 'answers usage, pct, headroom and the trigger as fields' do
      harness = build_harness
      seed_usage(harness, 42_133)

      usage = harness.context_usage

      expect(usage).to eq({ window: 65_536, tokens: 42_133, estimated: false,
                            pct: 64, headroom: 23_403, trigger: 57_344,
                            trigger_pct: 88, due: false })
      # issue #151: trigger depends on context size - min(88% of 65536,
      # 65536 - 8192) = 57344.
    end

    it 'flags auto-compact as due when the threshold is exceeded' do
      harness = build_harness
      seed_usage(harness, 60_000)

      # 60000 >= 57344 (window - reserved headroom) -> due (issue #151).
      expect(harness.context_usage[:due]).to eq(true)
    end
  end


  describe '#context_usage' do
    it 'answers nil for an empty session (nothing to measure)' do
      expect(build_harness.context_usage).to be_nil
    end

    it 'answers usage, pct, headroom and the trigger as fields' do
      harness = build_harness
      seed_usage(harness, 42_133)

      usage = harness.context_usage

      expect(usage).to eq({ window: 65_536, tokens: 42_133, estimated: false,
                            pct: 64, headroom: 23_403, trigger: 57_344,
                            trigger_pct: 88, due: false })
      # issue #151: trigger depends on context size - min(88% of 65536,
      # 65536 - 8192) = 57344.
    end

    it 'flags auto-compact as due when the threshold is exceeded' do
      harness = build_harness
      seed_usage(harness, 60_000)

      # 60000 >= 57344 (window - reserved headroom) -> due (issue #151).
      expect(harness.context_usage[:due]).to eq(true)
    end
  end

end

