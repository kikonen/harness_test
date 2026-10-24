# frozen_string_literal: true

require 'spec_helper'
require 'llm/usage_stats'

# The optional performance fields a response reports beside the token counts
# (issue #251). The wire names these reads come from the servers' own
# contracts (llama.cpp timings / prompt_tokens_details, Ollama Metrics) -
# doc/llm_stats.md lists them, so the fixtures below are synthesized from
# those published shapes rather than from a live capture.
RSpec.describe LLM::UsageStats do

  describe '.extended_usage (OpenAI-compatible shape)' do
    # llama.cpp /chat/completions: usage.prompt_tokens_details.cached_tokens
    # plus a top-level timings object.
    let(:llama_cpp) do
      { usage:   { prompt_tokens: 1000, completion_tokens: 50, total_tokens: 1050,
                   prompt_tokens_details: { cached_tokens: 768 } },
        timings: { cache_n: 768, prompt_n: 232, prompt_ms: 410.5,
                   prompt_per_second: 565.2, predicted_n: 50, predicted_ms: 1310.2,
                   predicted_per_second: 38.2, draft_n: 12, draft_n_accepted: 9 } }
    end

    it 'reads the cache depth and the llama.cpp timings' do
      expect(described_class.extended_usage(llama_cpp)).to eq(
        cached_tokens: 768, prompt_eval_ms: 410.5, eval_ms: 1310.2,
        prompt_tokens_per_second: 565.2, completion_tokens_per_second: 38.2,
        draft_n: 12, draft_n_accepted: 9
      )
    end

    it 'reports nothing for a plain usage block' do
      json = { usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } }

      expect(described_class.extended_usage(json)).to eq({})
    end

    it 'drops a zero-valued field (no cache hit is not a measurement)' do
      json = { timings: { prompt_ms: 0, cache_n: 0 },
               usage: { prompt_tokens_details: { cached_tokens: 0 } } }

      expect(described_class.extended_usage(json)).to eq({})
    end

    it 'ignores a malformed or absent timings object' do
      expect(described_class.extended_usage({ timings: 'n/a' })).to eq({})
      # prompt_ms exists ONLY inside llama.cpp's timings object; a bare
      # top-level one is not a field either server sends, so it is not read.
      expect(described_class.extended_usage({ prompt_ms: 12.5 })).to eq({})
    end

    it 'reads only the draft pair when it is present' do
      json = { timings: { prompt_ms: 5.0, predicted_ms: 20.0, draft_n: 8 } }

      expect(described_class.extended_usage(json)).to eq(
        prompt_eval_ms: 5.0, eval_ms: 20.0, draft_n: 8
      )
    end
  end

  describe '.extended_usage (native /api/chat shape)' do
    it 'converts the documented nanosecond durations to milliseconds' do
      # The values are Ollama's own docs example (docs/api.md).
      json = { prompt_eval_count: 26, prompt_eval_cached_count: 10,
               prompt_eval_duration: 130_079_000, eval_count: 259,
               eval_duration: 4_232_710_000 }

      expect(described_class.extended_usage(json)).to eq(
        cached_tokens: 10, prompt_eval_ms: 130.08, eval_ms: 4232.71
      )
    end

    it 'reads a duration that was marshaled as a Go duration string' do
      json = { prompt_eval_duration: '1m2.5s', eval_duration: '234ms' }

      expect(described_class.extended_usage(json)).to eq(
        prompt_eval_ms: 62_500.0, eval_ms: 234.0
      )
    end

    it 'ignores a duration that cannot be parsed' do
      expect(described_class.extended_usage({ eval_duration: 'soon' })).to eq({})
      expect(described_class.extended_usage({ eval_duration: nil })).to eq({})
    end

    it 'prefers a top-level duration over the timings entry' do
      json = { prompt_eval_duration: 100_000_000, timings: { prompt_ms: 500.0 } }

      expect(described_class.extended_usage(json)).to eq(prompt_eval_ms: 100.0)
    end
  end

  describe '.performance_snapshot' do
    it 'is nil for a usage that reported no performance' do
      expect(described_class.performance_snapshot(
        { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
      )).to be_nil
      expect(described_class.performance_snapshot(nil)).to be_nil
    end

    it 'keeps the token counts the measurements were made for' do
      usage = { prompt_tokens: 1000, completion_tokens: 50, cached_tokens: 768, eval_ms: 1310.2 }

      expect(described_class.performance_snapshot(usage)).to eq(
        cached_tokens: 768, eval_ms: 1310.2, prompt_tokens: 1000, completion_tokens: 50
      )
    end
  end

  describe '.performance_parts' do
    it 'is empty for nothing or for a core-only usage' do
      expect(described_class.performance_parts(nil)).to eq([])
      expect(described_class.performance_parts({ prompt_tokens: 10 })).to eq([])
    end

    it 'names each number with its unit' do
      usage = { cached_tokens: 200, prompt_eval_ms: 800.0, eval_ms: 1310.2,
                prompt_tokens: 1000, completion_tokens: 50 }

      expect(described_class.performance_parts(usage)).to eq(
        ['200 cached', 'prompt 1000 tok/s', 'gen 38.2 tok/s']
      )
    end

    it 'divides the prompt rate by the UNCACHED prompt tokens only' do
      # 1000 prompt tokens, 768 of them cached: only 232 were processed over
      # the measured 1160 ms. Dividing the whole prompt instead would read
      # 862.1 tok/s.
      usage = { cached_tokens: 768, prompt_eval_ms: 1160.0, prompt_tokens: 1000 }

      expect(described_class.performance_parts(usage)).to eq(
        ['768 cached', 'prompt 200 tok/s']
      )
    end

    it 'uses a server-reported rate instead of deriving one' do
      usage = { prompt_tokens_per_second: 565.2, completion_tokens_per_second: 38.2 }

      expect(described_class.performance_parts(usage)).to eq(
        ['prompt 565.2 tok/s', 'gen 38.2 tok/s']
      )
    end

    it 'reports the draft pair only when both counts are there' do
      usage = { draft_n: 12, draft_n_accepted: 9 }

      expect(described_class.performance_parts(usage)).to eq(['draft 12/9'])
      expect(described_class.performance_parts({ draft_n: 12 })).to eq([])
    end

    it 'shows the cache depth alone' do
      expect(described_class.performance_parts({ cached_tokens: 10 })).to eq(['10 cached'])
    end
  end

  describe '.uncached_prompt_tokens' do
    it 'never goes negative when the cache claims more than the prompt' do
      expect(described_class.uncached_prompt_tokens({ prompt_tokens: 10, cached_tokens: 40 })).to eq(0)
    end

    it 'treats a missing side as zero' do
      expect(described_class.uncached_prompt_tokens({ prompt_tokens: 10 })).to eq(10)
      expect(described_class.uncached_prompt_tokens({ cached_tokens: 10 })).to eq(0)
    end
  end

  describe '.tokens_per_second' do
    it 'is nil when either side cannot produce a rate' do
      expect(described_class.tokens_per_second(0, 10.0)).to be_nil
      expect(described_class.tokens_per_second(10, 0)).to be_nil
      expect(described_class.tokens_per_second(10, nil)).to be_nil
    end
  end

  describe '.format_rate' do
    it 'drops a trailing .0 and keeps one decimal otherwise' do
      expect(described_class.format_rate(38.04)).to eq('38')
      expect(described_class.format_rate(38.234)).to eq('38.2')
    end
  end
  # issue #285: the rate the spinner shows for the request that just finished.
  describe '.recent_generation_rate' do
    it 'prefers the server-reported rate over the harness clock' do
      usage = { completion_tokens: 50, completion_tokens_per_second: 31.4, eval_ms: 1600.0 }

      expect(described_class.recent_generation_rate(usage, 30.0)).to eq(
        rate: 31.4, server: true
      )
    end

    it 'derives one from the server-reported count and duration' do
      usage = { completion_tokens: 100, eval_ms: 2000.0 }

      expect(described_class.recent_generation_rate(usage, 30.0)).to eq(
        rate: 50.0, server: true
      )
    end

    # The harness's own clock is the LAST resort, and it is labeled as such by
    # the caller (server: false).
    it 'falls back to the harness clock when the server measured nothing' do
      usage = { completion_tokens: 100 }

      expect(described_class.recent_generation_rate(usage, 4.0)).to eq(
        rate: 25.0, server: false
      )
    end

    it 'is nil below the noise floor, without a duration, or without counts' do
      expect(described_class.recent_generation_rate({ completion_tokens: 100 }, 0.1)).to be_nil
      expect(described_class.recent_generation_rate({ completion_tokens: 2 }, 4.0)).to be_nil
      expect(described_class.recent_generation_rate({ prompt_tokens: 10 }, 4.0)).to be_nil
      expect(described_class.recent_generation_rate(nil, 4.0)).to be_nil
      expect(described_class.recent_generation_rate({}, 4.0)).to be_nil
    end

    it 'is nil when there are no seconds either (a resumed session)' do
      # No server number AND no measurement window: nothing to show.
      expect(described_class.recent_generation_rate({ completion_tokens: 100 }, nil)).to be_nil
    end
  end

  describe '.rate_segment' do
    it 'names the unit and tags the request it describes' do
      expect(described_class.rate_segment(31.4, measured_by_server: true, tag: 'last'))
        .to eq('31.4 tok/s (last)')
    end

    it "marks a rate the server did NOT measure with '~'" do
      expect(described_class.rate_segment(28.7, measured_by_server: false, tag: 'last'))
        .to eq('~28.7 tok/s (last)')
      expect(described_class.rate_segment(38.0, measured_by_server: false)).to eq('~38 tok/s')
    end

    it 'is nil when there is no rate' do
      expect(described_class.rate_segment(nil, measured_by_server: true, tag: 'last')).to be_nil
    end
  end

  describe '.measured_rate' do
    it 'is nil below its own noise floor' do
      expect(described_class.measured_rate(3, 3.0)).to be_nil
      expect(described_class.measured_rate(40, 0.1)).to be_nil
    end

    it 'divides tokens by seconds' do
      expect(described_class.measured_rate(40, 2.0)).to eq(20.0)
    end
  end
end
