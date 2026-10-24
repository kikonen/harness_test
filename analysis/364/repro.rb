# frozen_string_literal: true

# Issue #364: the tok/s slot jumped (9 -> 11 -> 8 -> 10 visible characters for
# ONE smooth rate) and a leftover bracket stayed on the line ("...STREAM]M]").
# Run from the repo root: ruby analysis/364/repro.rb
# A tiny terminal emulator applies the writes the spinner ACTUALLY made, so what
# the user would have SEEN is printed. The pre-fix behaviour is replayed by
# dropping a padded number (scenario A) or the erase escape (scenario B).
require "stringio"
require_relative "../../lib/ui"
require_relative "../../lib/llm/usage_stats"

# Emulates the visible line. The spinner writes "\r\e[2K" then the frame: "\r"
# returns the cursor to column 0 WITHOUT erasing, "\e[2K" erases the line.
class Screen
  WIDTH = 64
  ERASE = "\e[2K"

  def initialize
    @cells = Array.new(WIDTH, " ")
  end

  def feed(text)
    text = text[1..] if text.start_with?("\r")
    if text.start_with?(ERASE)
      @cells = Array.new(WIDTH, " ")
      text   = text[ERASE.length..]
    end
    col = 0
    text.each_char do |ch|
      @cells[col] = ch
      col += 1
    end
    @cells.join("").rstrip
  end
end

# Draws the given rates and badges through the real spinner against a captured
# console, and returns the VISIBLE line of every frame. pad: the width-stable
# number; erase: the per-frame line erase. Both were missing before the fix.
def frames(rates:, badges:, pad:, erase:)
  io     = StringIO.new
  screen = Screen.new
  rate   = -1
  badge  = -1
  spin = UI::Spinner.new(
    "Sending to model",
    -> do
      LLM::UsageStats.rate_segment(
        rates[rate += 1], measured_by_server: false, pad:)
    end,
    ui: UI::Console.new(stdout: io))
  spin.badge = -> { badges[badge += 1] }
  spin.start
  rates.each_index { spin.render! }
  spin.stop
  writes = erase ? io.string : io.string.gsub(Screen::ERASE, "")
  writes.split(/(?=\r)/).filter_map { |w| screen.feed(w) unless w.empty? }
end

def report(label, lines)
  puts "#{label}:"
  lines.each { |line| puts "  |#{line}|" }
  puts "  widths: #{lines.map(&:length).inspect}"
end

puts "== scenario A: a smooth rate, constant posture badge =="
A_RATES  = [9.0, 38.04, 9.0, 28.7, 9.0]
A_BADGES = ["[STREAM]"] * A_RATES.size
a_before = frames(
  rates: A_RATES,
  badges: A_BADGES,
  pad: false,
  erase: true)
a_after = frames(
  rates: A_RATES,
  badges: A_BADGES,
  pad: true,
  erase: true)
report("BEFORE (unpadded number)", a_before)
report("AFTER  (padded number)", a_after)
jumped_before = a_before.map(&:length).uniq.size > 1
stable_after  = a_after.map(&:length).uniq.size == 1
puts "  BEFORE widths jumped: #{jumped_before}"
puts "  AFTER widths stable:  #{stable_after}"

puts
puts "== scenario B: the posture badge toggles OFF mid-turn =="
# The badge list ends early on purpose: from frame 3 on there is no badge, and
# a frame without it is SHORTER than the one before it.
B_RATES  = [38.04, 9.0, 9.0]
B_BADGES = ["[STREAM] [MANUAL]"] * (B_RATES.size - 1)
b_before = frames(rates: B_RATES, badges: B_BADGES, pad: false, erase: false)
b_after  = frames(rates: B_RATES, badges: B_BADGES, pad: true, erase: true)
report("BEFORE (no erase)", b_before)
report("AFTER  (erase per frame)", b_after)
ghost_before = b_before.last.include?("[")
ghost_after  = b_after.last.include?("[")
puts "  BEFORE last frame shows a GONE badge: #{ghost_before}"
puts "  AFTER  last frame shows a gone badge: #{ghost_after}"

fixed_ok  = stable_after && !ghost_after
replayed  = jumped_before && ghost_before
verdict   = if !fixed_ok  then "BUG PRESENT"
            elsif replayed then "FIXED"
            else "FIXED (pre-fix replay did not reproduce)"
            end
puts
puts verdict
