# frozen_string_literal: true

require_relative "../command"

module Commands
  # /ctx - report current context usage on demand (issue #63).
  #
  # The token arithmetic stays in Harness#context_usage (the same numbers that
  # decide a compaction), and the command states them as the fields of a two-column
  # table (field | value) so the padding UI::Renderer owns is not baked here
  # (issue #474, increment 21).
  class CtxCommand < Command
    HELP = CommandHelp.new(
      usage: "ctx",
      summary: "Show context usage now: tokens used, % of the window, " \
        "headroom and whether auto-compact is due",
      group: :session,
      see_also: %w[compact session conversation])

    def handle(_args)
      usage = @harness.context_usage
      return emit_role(:note, "No conversation yet - nothing to measure.") if usage.nil?

      emit_list(
        title: "\u{1F9E0} Context usage",
        kind: :table,
        columns: %i[field value],
        items: usage_rows(usage),
        origin: "ctx")
    end

    private

    def usage_rows(usage)
      rows = [
        {
          field: "Used",
          value: "#{usage[:tokens]} tokens (#{usage[:pct]}% of #{usage[:window]})"
        },
        {
          field: "Source",
          value: usage[:estimated] ? "estimate (~4 chars/token)" : "last LLM response"
        },
        { field: "Headroom", value: "#{usage[:headroom]} tokens" }
      ]
      # No trigger configured means nothing fires, so there is no row to state.
      rows << {
        field: "Auto-compact",
        value: auto_compact_value(usage)
      } if usage[:trigger]
      rows
    end

    def auto_compact_value(usage)
      status = usage[:due] ? "due" : "not due"
      "#{status} (fires at #{usage[:trigger]} tokens, " \
        "#{usage[:trigger_pct]}% of the window)"
    end
  end
end
