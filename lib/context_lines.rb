# frozen_string_literal: true

require_relative "llm_client"
require_relative "llm/usage_stats"

# The context and rate text a spinner frame shows (issue #582), extracted from
# Harness: it reads the session chain and the model window, and the live rate
# from the request in flight - not from the harness. Harness keeps only the
# thin delegators the UI and SessionManager already call.
class ContextLines
  def initialize(session:, window_source:)
    @session        = session
    @window_source  = window_source
  end

  def window
    @window_source.call
  end

  # A window is read as an order of magnitude; five digits is noise in a
  # per-frame line, so windows under 1000 stay exact.
  def window_label(window = self.window)
    w = window.to_i
    w < 1000 ? w.to_s : "#{(w / 1000.0).round}K"
  end

  def indicator
    used = @session.context_used
    return nil if used.nil?

    pct = @session.context_pct(window)
    label = used[:estimated] ? "~" : ""
    "🧠 ctx #{label}#{used[:tokens]}/#{window} (#{pct}%)"
  end

  # The SPINNER's context segment: the CURRENT chain (mid-turn results included)
  # as a glanceable percentage. Raw token arithmetic stays in #indicator.
  def live(messages = nil)
    if messages
      tokens  = @session.anchored_estimate(messages)
      label   = "~"
    else
      used = @session.context_used
      return nil if used.nil?

      tokens  = used[:tokens]
      label   = used[:estimated] ? "~" : ""
    end

    pct = (tokens.to_f / window * 100).round
    "🧠 #{label}#{pct}% (#{window_label})"
  end

  # Arithmetic stays here, the row shape is UI::Renderer's; nil with nothing to
  # measure.
  def usage(trigger)
    used = @session.context_used
    return nil if used.nil?

    pct      = @session.context_pct(window)
    headroom = [window - used[:tokens], 0].max

    {
      window:,
      tokens: used[:tokens],
      estimated: used[:estimated],
      pct:,
      headroom:,
      trigger:,
      trigger_pct: trigger ? (trigger.to_f / window * 100).round : nil,
      due: trigger ? used[:tokens] >= trigger : false
    }
  end

  # A tool call REPLACES the tail: while one is written no text arrives, so a
  # line built on a stopped tail reads as a frozen connection.
  def streaming_line(preview)
    phase = preview&.tool_call_line
    # No rate: a rate over an arriving-nothing window decays frame by frame
    # (9.0 -> 4.5 -> 2.2), the "connection is dying" reading this replaces.
    return [phase, live].compact.join(" ") if phase

    tail = preview&.tail_line
    return nil if tail.nil?

    rate = LLM::UsageStats.rate_segment(
      preview&.live_rate, measured_by_server: false, pad: true)
    rate ? "#{tail} #{rate}" : tail
  end
end
