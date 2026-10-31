# frozen_string_literal: true

# Issue #401: a spinner frame wider than the terminal soft-wraps onto extra
# physical rows that the next frame's "\r\e[2K" cannot reach (it erases only
# the row the cursor sits on), so the overflow row survives as residue.
# Run from the repo root: ruby analysis/401/repro.rb
#
# Part 1: the frame itself. Before the fix a frame was written whole, so the
#   worst-case live frame (glyph + elapsed + message + the 60-char streamed
#   tail + context + rate + posture badges) measured over 100 columns and
#   overflowed. After it, #fit_line(i, width) keeps one frame on one row by
#   sacrificing segments in SURVIVAL_PRIORITY order - glyph and message are
#   anchors, the long suffix (streamed text + context + rate) goes first.
#
# Part 2: WHICH width the frame is fitted to. The spinner probes the sink it
#   writes to; IO#winsize answers [rows, columns], so reading index 0 fits the
#   frame to the terminal's HEIGHT. That is the reported symptom: a 160-column
#   terminal with ~50 rows had its frame cut to ~50 columns, discarding the
#   context estimate, the rate and the posture badges. On a terminal with MORE
#   rows than columns the rows probe fits a frame WIDER than the terminal, so
#   the residue bug survives the fitting.
#
# Deterministic: explicit widths and a fake sink that reports a winsize, so it
# runs identically on any machine with no real terminal.
require_relative "../../lib/ui/spinner"
require_relative "../../lib/ui/console"
require "stringio"

width_of = ->(t) { Kramdown::ANSI::Width.display_width(t) }

# A sink that REPORTS a terminal size the way a real terminal File does
# (#winsize -> [rows, columns]); StringIO alone has no #winsize, so the
# detection path would never be exercised without it.
class SizedSink < StringIO
  def initialize(rows, columns)
    super(+"")
    @winsize = [rows, columns]
  end

  attr_reader :winsize

  def tty?
    false
  end
end

def live_spinner(suffix, console)
  spinner = UI::Spinner.new("Sending to local / ollama", suffix, ui: console)
  spinner.elapsed = "2m 03s"
  spinner.badge   = "[STREAM] [YOLO]"
  spinner
end

def drawn_frame(spinner, sink)
  spinner.start
  spinner.render!
  spinner.stop
  sink.string.split("\e[2K").last
end

# The worst-case suffix a live turn can produce: a full 60-char streamed tail,
# the context estimate and the rate (Harness#streaming_wait_line /
# #request_wait_suffix compose all of these at once).
tail = "\u2026" + ("x" * 59)
suffix = "#{tail} \u{1F9E0} ~12% (160K) ~38.0 tok/s"

plain = live_spinner(suffix, UI::Console.new(stdout: StringIO.new))

raw = plain.line(0)
puts "raw frame width  = #{width_of.call(raw)} columns"
puts "overflows an 80-column terminal without fitting? #{width_of.call(raw) > 80}"

[80, 55, 44, 30, 10, 1].each do |w|
  fit = plain.fit_line(0, w)
  width = width_of.call(fit)
  status = width <= w ? "ok" : "OVERFLOW"
  puts format("fit to %-3d -> %-3d columns  %s", w, width, status)
end

# The invariant that fixes the residue: a fitted frame is never wider than the
# requested width, so one frame is one physical row.
widths = [80, 55, 44, 30, 10, 1]
all_ok = widths.all? { |w| width_of.call(plain.fit_line(0, w)) <= w }
puts "\nall fits within their width (one row, no residue): #{all_ok}"

# Part 2. Shapes are [rows, columns] in IO#winsize order; the label spells them
# out so a row cannot be read as a width. The last column is what a winsize[0]
# (ROWS) probe would have done to the same terminal - the reported bug. A
# detected width keeps Spinner::RESERVED_COLUMNS free so the terminal itself
# never has to wrap the line.
puts "\ndetected width per sink:"
[
  { rows: 50, columns: 160, note: "as reported" },
  { rows: 40, columns: 120, note: "wide + short" },
  { rows: 90, columns: 40,  note: "tall + narrow" },
  { rows: 80, columns: 80,  note: "square" }
].each do |shape|
  rows    = shape[:rows]
  columns = shape[:columns]
  sink    = SizedSink.new(rows, columns)
  drawn   = drawn_frame(live_spinner(suffix, UI::Console.new(stdout: sink)), sink)

  drawn_w = width_of.call(drawn)
  limit   = columns - UI::Spinner::RESERVED_COLUMNS
  now     = drawn_w <= limit ? "fits #{drawn_w} (limit #{limit})" : "WRAPS #{drawn_w}"
  probe_w = width_of.call(plain.fit_line(0, rows))
  probe   = probe_w > columns ? "WRAPS #{probe_w} > #{columns}" \
                              : "chops #{probe_w} of #{columns}"

  label  = format("%-13s", shape[:note])
  fitted = format("%-27s", "now: #{now}")
  puts "  #{rows}r x #{columns}c #{label}#{fitted}winsize[0]: #{probe}"
end

# The reported shape drawn both ways so the loss is visible, not only measured:
# 50 rows x 160 columns, where the OLD probe cut the frame to 50 columns - the
# "cut-off into approx 50 chars discarding relevant information" reported.
puts "\n50 rows x 160 columns - what the user saw:"
old_frame = plain.fit_line(0, 50)
new_sink  = SizedSink.new(50, 160)
new_frame = drawn_frame(live_spinner(suffix, UI::Console.new(stdout: new_sink)), new_sink)

puts "  OLD (rows probe, fit 50):  #{old_frame}"
puts "  NEW (cols probe, fit 159): #{new_frame}"
lost = ["[STREAM]", "[YOLO]", "160K", "tok/s"].reject { |part| new_frame.include?(part) }
puts "  information the NEW frame discards: #{lost.empty? ? 'none' : lost.join(', ')}"
