# frozen_string_literal: true

module LLM
  # Normalized vocabulary for the OPTIONAL performance fields a response
  # reports beside the token counts (issue #251): only what the server sent
  # is kept. Wire names per server and the rate semantics: doc/llm_stats.md.
  module UsageStats
    PERFORMANCE_KEYS = %i[
      cached_tokens
      prompt_eval_ms
      eval_ms
      prompt_tokens_per_second
      completion_tokens_per_second
      draft_n
      draft_n_accepted
    ].freeze

    # A native duration is an integer count of nanoseconds per Ollama's API
    # docs; the Go Duration type can also marshal one as a string ("1m2.5s").
    DURATION_UNITS = {
      "ns" => 0.000_001,
      "µs" => 0.001,
      "us" => 0.001,
      "ms" => 1.0,
      "s" => 1000.0,
      "m" => 60_000.0,
      "h" => 3_600_000.0
    }.freeze

    DURATION_PATTERN = /(\d+(?:\.\d+)?)(ns|µs|us|ms|s|m|h)/

    module_function

    # Extended fields one RAW parsed response or stream chunk reports ({} when
    # the server sent none); a native top-level duration wins over the
    # llama.cpp timings entry for the same measurement.
    def extended_usage(json)
      return {} unless json.is_a?(Hash)

      timings = json[:timings].is_a?(Hash) ? json[:timings] : {}
      ext = {}

      cached = positive_integer(
        json.dig(:usage, :prompt_tokens_details, :cached_tokens)) ||
        positive_integer(json[:prompt_eval_cached_count])
      ext[:cached_tokens] = cached if cached

      prompt_ms = duration_ms(json[:prompt_eval_duration]) ||
        positive_ms(timings[:prompt_ms])
      ext[:prompt_eval_ms] = prompt_ms if prompt_ms

      eval_ms = duration_ms(json[:eval_duration]) || positive_ms(timings[:predicted_ms])
      ext[:eval_ms] = eval_ms if eval_ms

      prompt_rate = rate_or_nil(timings[:prompt_per_second])
      ext[:prompt_tokens_per_second] = prompt_rate if prompt_rate

      gen_rate = rate_or_nil(timings[:predicted_per_second])
      ext[:completion_tokens_per_second] = gen_rate if gen_rate

      draft    = positive_integer(timings[:draft_n])
      accepted = positive_integer(timings[:draft_n_accepted])
      ext[:draft_n] = draft if draft
      ext[:draft_n_accepted] = accepted if accepted

      ext
    end

    # The performance of ONE response's usage, with its own token counts kept
    # alongside (nil when it reported none) - a turn's numbers must never be
    # built by summing measurements of different requests: doc/llm_stats.md.
    def performance_snapshot(usage)
      return nil unless usage.is_a?(Hash)

      snapshot = PERFORMANCE_KEYS.each_with_object({}) do |key, out|
        out[key] = usage[key] if positive_value?(usage[key])
      end
      return nil if snapshot.empty?

      %i[prompt_tokens completion_tokens].each do |key|
        snapshot[key] = usage[key] if usage[key]
      end
      snapshot
    end

    # Unit-explicit fragments ([] when nothing was reported). The prompt rate
    # covers the UNCACHED prompt tokens only: both servers time prompt
    # processing over the uncached part, and cached tokens cost no decode.
    def performance_parts(usage)
      return [] unless usage.is_a?(Hash)

      parts = []
      parts << "#{usage[:cached_tokens]} cached" if positive_value?(usage[:cached_tokens])

      prompt = usage[:prompt_tokens_per_second] ||
        tokens_per_second(uncached_prompt_tokens(usage), usage[:prompt_eval_ms])
      parts << "prompt #{format_rate(prompt)} tok/s" if prompt

      gen = usage[:completion_tokens_per_second] ||
        tokens_per_second(usage[:completion_tokens], usage[:eval_ms])
      parts << "gen #{format_rate(gen)} tok/s" if gen

      if positive_value?(usage[:draft_n]) && positive_value?(usage[:draft_n_accepted])
        parts << "draft #{usage[:draft_n]}/#{usage[:draft_n_accepted]}"
      end
      parts
    end

    def uncached_prompt_tokens(usage)
      [usage[:prompt_tokens].to_i - usage[:cached_tokens].to_i, 0].max
    end

    def tokens_per_second(tokens, millis)
      return nil if tokens.to_i <= 0 || millis.nil? || millis.to_f <= 0.0

      tokens.to_f / millis * 1000.0
    end

    def format_rate(rate)
      format("%.1f", rate).sub(/\.0\z/, "")
    end

    def duration_ms(value)
      ms = case value
           when Numeric then value.to_f / 1_000_000.0
           when String  then go_duration_ms(value)
           end
      return nil unless ms && ms.positive?

      ms.round(2)
    end

    def go_duration_ms(text)
      pieces = text.scan(DURATION_PATTERN)
      return nil if pieces.empty?

      total = 0.0
      pieces.each { |amount, unit| total += amount.to_f * DURATION_UNITS[unit] }
      total.round(2)
    end

    def positive_ms(value)
      value.to_f.round(2) if value.is_a?(Numeric) && value.positive?
    end

    def positive_integer(value)
      number = value.is_a?(String) && value.match?(/\A\d+\z/) ? value.to_i : value
      number if number.is_a?(Integer) && number.positive?
    end

    def rate_or_nil(value)
      value = value.to_f if value.is_a?(String) && value.match?(/\A\d+(?:\.\d+)?\z/)
      value.to_f if value.is_a?(Numeric) && value.positive?
    end

    def positive_value?(value)
      value.is_a?(Numeric) && value > 0
    end
  end
end
