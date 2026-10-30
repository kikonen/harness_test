# frozen_string_literal: true

require_relative "harness_error"

# The three invariants of the pre-dialog command safety check (issue #224):
# the verdict is ADVISORY, a check that cannot be trusted yields NO verdict
# (never a guessed one), and SafetyCheck is a PURE function over a chain +
# client - an injected logger is the only sink it may write to. Rationale,
# the KV-cache reasoning and the verdict-binding rule: doc/safety_check_design.md.
module SafetyCheck
  # Short read timeout: the verdict is advisory; a slow check must not
  # stall the user's consent dialog (the caller degrades to a plain
  # dialog on error).
  DEFAULT_TIMEOUT = 30

  # The answer must name the command's number back: the ordinal is the only
  # identity a verdict line carries, so it survives a preamble line or an
  # out-of-order answer.
  CHECK_PROMPT = "I am about to run these shell command(s) in this project:\n" \
    "%s\n" \
    "Reply with EXACTLY one line per command. Each line must start with that " \
    "command's number and a colon, then safe: or dangerous: and a short reason " \
    "(example: 1: safe: only reads project files). Do NOT call any tools."

  # The kind is matched case-insensitively and rebuilt lowercase by the parser:
  # the AUTO-APPROVE consumer matches the exact "safe:" prefix, so a verdict
  # that reached it never starts with "Safe:".
  VERDICT_LINE = /
    \A (?:(?<ordinal>\d+)[.):]?\s*)? (?<kind>safe|dangerous): \s* (?<reason>.*\S) \s* \z
  /xi

  class << self
    # Fork of chain truncated at the last COMPLETE round: the trailing
    # assistant message with tool_calls (whose tool results have not been
    # appended yet - the dialog fires exactly at that point, mid tool
    # loop) is dropped, because backends reject tool_calls without their
    # results. Ends on a tool/user/plain-assistant message, or on the
    # unchanged chain when it is already valid. The original array is
    # never mutated.
    def truncate_for_check(chain)
      forked = chain.dup
      while (last = forked.last) && last[:role] == "assistant" && last[:tool_calls]
        forked.pop
      end
      forked
    end

    # One check call for ALL commands (one verdict line each). Returns
    # { command => one-line verdict or nil }. nil verdicts (blank answer,
    # an answer whose lines cannot be placed, degenerate chain) mean "no
    # verdict" for that command. Raises LLMError etc. - the CALLER must
    # rescue and degrade to a plain dialog. tools: is the live turn's own tool
    # payload - see doc/compaction_cache_design.md for why the fork must carry it.
    def run(client, chain, commands, tools: nil, timeout: DEFAULT_TIMEOUT, logger: nil)
      commands = Array(commands).map(&:to_s)
      results  = commands.to_h { |c| [c, nil] }
      return results if commands.size == 0

      base = truncate_for_check(chain)
      # Degenerate chain (empty, or nothing but the system prompt): there
      # is no conversation to reuse (no cached prefix, nothing to ground
      # the verdict in) - no verdict, no call.
      return results if base.reject { |m| m[:role] == "system" }.empty?

      listed = commands.each_with_index.map { |c, i| "#{i + 1}. #{c}" }.join("\n")
      question = format(CHECK_PROMPT, listed)
      fork     = base + [{ role: "user", content: question }]

      data = client.chat(fork, tools:, timeout:)
      message = data.dig(:choices, 0, :message) || {}
      text    = message[:content].to_s
      if text.strip.empty?
        # The fork sends the live tool payload (#246), so an answer CAN be a
        # tool call instead of verdict lines. Say so: a silent nil set is the
        # "AUTO-APPROVE stopped approving" symptom with nothing to explain it.
        names = Array(message[:tool_calls]).filter_map { |tc| tc.dig(:function, :name) }
        shape = names.empty? ? "blank" : "a tool call: #{names.join(', ')}"
        logger&.info "safety check: no verdict lines (answer was #{shape})"
      end
      verdicts, dropped = parse_verdicts(text, commands)
      if dropped.any?
        logger&.info "safety check: #{dropped.join('; ')}"
      end
      verdicts
    end

    # Answer -> commands, as [verdicts, dropped]. Position is consulted ONLY
    # when no line carries an ordinal and the counts match exactly; anything
    # ambiguous is dropped rather than guessed, because a wrong "safe:" label
    # is what skips the consent dialog. Rule and table: doc/safety_check_design.md.
    def parse_verdicts(text, commands)
      bound   = {}
      plain   = []
      dropped = []

      text.to_s.split("\n").map(&:strip).reject(&:empty?).each do |line|
        m = VERDICT_LINE.match(line)
        if m.nil?
          dropped << "line #{line[0, 40].inspect} carries no safe:/dangerous: shape"
          next
        end
        verdict = "#{m[:kind].downcase}: #{m[:reason]}"
        ordinal = m[:ordinal]&.to_i
        if ordinal.nil?
          plain << verdict
          next
        end
        unless (1..commands.size).include?(ordinal)
          dropped << "ordinal #{ordinal} names no command (1..#{commands.size})"
          next
        end
        if bound.key?(ordinal)
          dropped << "command #{ordinal} was answered twice - verdict dropped"
          bound[ordinal] = nil
          next
        end
        bound[ordinal] = verdict
      end

      if plain.any?
        if bound.empty? && dropped.empty? && plain.size == commands.size
          plain.each_with_index { |verdict, idx| bound[idx + 1] = verdict }
        else
          dropped << "#{plain.size} unnumbered verdict line(s) cannot be placed"
        end
      end

      [commands.each_with_index.to_h { |c, i| [c, bound[i + 1]] }, dropped]
    end
  end
end
