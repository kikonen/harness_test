# frozen_string_literal: true

# Issue #401: a spinner frame wider than the terminal soft-wraps onto extra
# physical rows that the next frame's "\r\e[2K" cannot reach (it erases only
# the row the cursor sits on), so the overflow row survives as residue.
# Run from the repo root: ruby analysis/401/repro.rb
#
# Before the fix: UI::Spinner had no #fit_line - a frame was written whole, so
#   a worst-case frame (glyph + elapsed + message + the 60-char streamed tail +
#   context + rate + posture badges) measured over 100 columns and overflowed.
# After the fix: #fit_line(i, width) fits one frame to one row by sacrificing
#   segments in SURVIVAL_PRIORITY order - glyph+message are anchors, the long
#   suffix (streamed text + context + rate) is truncated first then dropped.
#
# Deterministic: it calls #fit_line with an explicit width (no real terminal),
# so it runs identically on any machine.
require_relative "../../lib/ui/spinner"
require_relative "../../lib/ui/console"
require "stringio"

width_of = ->(t) { Kramdown::ANSI::Width.display_width(t) }

# The worst-case suffix a live turn can produce: a full 60-char streamed tail,
# the context estimate and the rate (Harness#streaming_wait_line /
# #request_wait_suffix compose all of these at once).
tail = "\u2026" + ("x" * 59)
suffix = "#{tail} \u{1F9E0} ~12% (160K) ~38.0 tok/s"

spinner = UI::Spinner.new(
  "Sending to local / ollama",
  suffix,
  ui: UI::Console.new(stdout: StringIO.new))
spinner.elapsed = "12s"
spinner.badge   = "[STREAM] [MANUAL]"

raw = spinner.line(0)
puts "raw frame width  = #{width_of.call(raw)} columns"
puts "overflows an 80-column terminal without fitting? #{width_of.call(raw) > 80}"

[80, 55, 44, 30, 10, 1].each do |w|
  fit = spinner.fit_line(0, w)
  width = width_of.call(fit)
  status = width <= w ? "ok" : "OVERFLOW"
  puts format("fit to %-3d -> %-3d columns  %s", w, width, status)
end

# The invariant that fixes the residue: a fitted frame is never wider than the
# requested width, so one frame is one physical row.
widths = [80, 55, 44, 30, 10, 1]
all_ok = widths.all? { |w| width_of.call(spinner.fit_line(0, w)) <= w }
puts "\nall fits within their width (one row, no residue): #{all_ok}"
