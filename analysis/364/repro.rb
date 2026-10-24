# frozen_string_literal: true

# Issue #364 (+ its follow-up report): three ways the spinner line rendered wrong.
#   A  the tok/s slot jumped (9 -> 11 -> 8 -> 10 visible characters for ONE rate)
#   B  a leftover bracket stayed on the line ("...STREAM]M]")
#   C  the 60-char tail marker glued onto ellipsis the ANSWER wrote ("... .... The")
# Run from the repo root: ruby analysis/364/repro.rb
# A tiny terminal emulator applies the writes the spinner ACTUALLY made, so what
# the user would have SEEN is printed. The pre-fix behaviour is replayed by
# dropping a padded number (A), the erase escape (B), or the seam replacement (C).
require "stringio"
require_relative "../../lib/ui"
require_relative "../../lib/llm/usage_stats"
require_relative "../../lib/llm/stream_preview"

# Emulates the visible line. The spinner writes "\r\e[2K" then the frame: "\r"
# returns the cursor to column 0 WITHOUT erasing, "\e[2K" erases the line.
class Screen
  WIDTH = 100
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

puts
puts "== scenario C: the 60-char cut lands inside ellipsis the ANSWER wrote =="
# The reported line was "⠇ 55s Sending (qwen / openai)... .... The bottom": the
# answer wrote its own "...." a couple characters past the cut, so the kept text
# BEGAN with ".. The bottom" and the old three-dot marker was prepended in front
# of it. The OLD rendering is rebuilt here by hand - keep the newest MAX_TAIL
# characters and prepend "..." ON TOP of them - because the class no longer
# behaves that way. The answer arrives word by word through the real spinner, with
# the tok/s rate drawn after the tail, as in a live turn.
C_CONTENT = "I checked the file above the region in question. The fix is small" \
  ".... The bottom line itself stays exactly as it is, unchanged."
MAX = LLM::StreamPreview::MAX_TAIL

# old: true replays the previous rendering; old: false asks the class. Returns the
# tail segment of every frame.
def c_segments(old)
  all = +""
  preview = LLM::StreamPreview.new(chars_per_token: 4)
  C_CONTENT.split.map do |word|
    if old
      all << "#{word} "
      all.length > MAX ? "...#{all[-MAX..]}" : all.dup
    else
      preview.record({ content: "#{word} " }).tail_line
    end
  end
end

def c_frame(segment)
  io   = StringIO.new
  spin = UI::Spinner.new(
    "Sending (qwen / openai)", "#{segment} ~ 9.0 tok/s", ui: UI::Console.new(stdout: io))
  spin.elapsed = "55s"
  spin.start
  spin.render!
  spin.stop
  Screen.new.feed(io.string)
end

# What the report is about: the marker GLUED onto dots (the line's own dots glued
# onto the marker), counted at the START of the segment only - dots FURTHER INSIDE
# the tail are the answer's own writing and stay, by design. And the width the rate
# label has to tolerate DURING the truncated phase, where the tail is redrawn every
# frame while the answer is still streaming.
def stats(segments)
  marker = LLM::StreamPreview::TAIL_MARKER
  trunc  = segments.select { |s| s.start_with?("...") || s.start_with?(marker) }
  {
    glued: trunc.count { |s| s.match?(/\A(?:…|\.\.\.)[.…]/) },
    widths: trunc.map(&:length).uniq.sort,
    jitter: trunc.map(&:length).each_cons(2).count { |a, b| a != b },
    over: trunc.count { |s| s.length > MAX }
  }
end

seg_before = c_segments(true)
seg_after  = c_segments(false)
s_before   = stats(seg_before)
s_after    = stats(seg_after)
report("BEFORE last frame (marker prepended on top of 60)", [c_frame(seg_before.last)])
report("AFTER  last frame (marker replaces the seam)", [c_frame(seg_after.last)])
def compare(label, before, after)
  puts "  #{label}: BEFORE #{before} / AFTER #{after}"
end
compare("marker glued onto dots (frames)", s_before[:glued], s_after[:glued])
compare("truncated-segment widths", s_before[:widths], s_after[:widths])
compare("frames wider than MAX_TAIL", s_before[:over], s_after[:over])
compare("width changes per frame", s_before[:jitter], s_after[:jitter])

fixed_ok = stable_after && !ghost_after && s_after[:glued].zero? &&
  s_after[:widths] == [MAX] && s_after[:over].zero? && s_after[:jitter].zero?
replayed = jumped_before && ghost_before && s_before[:glued].positive? &&
  s_before[:over].positive?
verdict = if !fixed_ok then "BUG PRESENT"
          elsif replayed then "FIXED"
          else "FIXED (pre-fix replay did not reproduce)"
          end
puts
puts verdict
