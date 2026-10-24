# frozen_string_literal: true

require 'ui'
require 'stringio'

# The Spinner suite (issue #74 / #40): the class lives in the `UI` namespace.
# Single-thread I/O model (issue #40): start/stop are pure state changes
# (no background thread). update_detail re-points message/suffix without
# restarting the animation. The output console is injected ONCE at
# construction (ui:); render!/clear_line write to that console with no
# per-call stream argument and no global fallback. The main thread calls
# render! on each drain tick. Tests assert the frame text by constructing
# the spinner against a captured StringIO-backed UI::Console, not via
# sleep-based thread observation - no $stdout/$stdin globals anywhere.
RSpec.describe UI::Spinner do
  # A non-capturing console for examples that only need a valid constructor
  # argument (state queries).
  def quiet_console
    UI::Console.new(stdout: StringIO.new)
  end

  # Build the spinner bound to a fresh captured console; run the block with
  # it (typically start / render! / stop), then return the captured output
  # string.
  def capture(*args, &block)
    io      = StringIO.new
    spinner = described_class.new(*args, ui: UI::Console.new(stdout: io))
    yield(spinner)
    io.string
  end

  describe 'construction' do
    it 'defaults to the "Working" message with no suffix' do
      spinner = described_class.new(ui: quiet_console)
      expect(spinner.instance_variable_get(:@message)).to eq('Working')
      expect(spinner.instance_variable_get(:@suffix)).to be_nil
    end

    it 'accepts a custom message and a plain-string suffix (issue #115)' do
      suffix = '🧠 ctx 42133/65536 (64%)'
      spinner = described_class.new('Sending to gpt-x', suffix, ui: quiet_console)
      expect(spinner.instance_variable_get(:@message)).to eq('Sending to gpt-x')
      expect(spinner.instance_variable_get(:@suffix)).to eq(suffix)
    end

    it 'accepts a callable suffix that is stored for per-frame evaluation (issue #126)' do
      live = -> { 'ctx 9/10 (90%)' }
      spinner = described_class.new('Sending to gpt-x', live, ui: quiet_console)
      expect(spinner.instance_variable_get(:@suffix)).to be(live)
    end

    it 'requires a ui: console (no global stream fallback)' do
      expect { described_class.new }.to raise_error(ArgumentError, /ui/)
      expect { described_class.new(ui: nil) }
        .to raise_error(ArgumentError, /requires a ui: console/)
    end
  end

  describe '#render! and frame advancement' do
    it 'renders the frame, message and a string suffix on one line' do
      out = capture('Sending to gpt-x', '🧠 ctx 42133/65536 (64%)') do |spinner|
        spinner.start
        spinner.render!
        spinner.stop
      end
      expect(out).to include('Sending to gpt-x... 🧠 ctx 42133/65536 (64%)')
    end

    it 'renders only the message when no suffix is given' do
      out = capture('Working') do |spinner|
        spinner.start
        spinner.render!
        spinner.stop
      end
      expect(out).to include('Working...')
      # No stray trailing space before the line ends (suffix must be absent).
      expect(out).not_to include('Working... ')
    end

    # The suffix is drawn VERBATIM: a leading blank reserves the rate number's
    # tens column and a trailing blank pads the tail segment to its fixed width
    # (issue #364). Only a blank-only suffix resolves to no suffix at all.
    it 'renders the suffix verbatim, both leading and trailing blanks' do
      out = capture('Working', '  ctx 1/2 (50%)  ') do |spinner|
        spinner.start
        spinner.render!
        spinner.stop
      end
      expect(out).to include('Working...   ctx 1/2 (50%)  ')
    end

    it 'resolves a blank-only suffix to no suffix' do
      out = capture('Working', '   ') do |spinner|
        spinner.start
        spinner.render!
        spinner.stop
      end
      expect(out).to eq("\r\e[2K#{UI::Spinner::FRAMES[0]} Working...")
    end

    it 're-evaluates a callable suffix every frame so it tracks live state (issue #126)' do
      value = 'ctx 1/10 (10%)'
      out = capture('Sending to gpt-x', -> { value }) do |spinner|
        spinner.start
        spinner.render!
        # The "current" value changes; the next frame must show the new value.
        value = 'ctx 9/10 (90%)'
        spinner.render!
        spinner.stop
      end
      expect(out).to include('Sending to gpt-x... ctx 1/10 (10%)')
      expect(out).to include('Sending to gpt-x... ctx 9/10 (90%)')
    end

    it 'falls back to no suffix when the callable raises' do
      out = capture('Working', -> { raise 'boom' }) do |spinner|
        spinner.start
        spinner.render!
        spinner.stop
      end
      expect(out).to include('Working...')
      expect(out).not_to include('Working... ')
    end

    it 'advances through frames sequentially' do
      out = capture('Working') do |spinner|
        spinner.start
        3.times { spinner.render! }
        spinner.stop
      end
      # Each frame uses the next glyph from FRAMES
      expect(out).to include(UI::Spinner::FRAMES[0])
      expect(out).to include(UI::Spinner::FRAMES[1])
      expect(out).to include(UI::Spinner::FRAMES[2])
    end

    it 'is a no-op when stopped' do
      out = capture('Working') do |spinner|
        spinner.render! # never started
      end
      expect(out).to eq('')
    end
  end

  describe '#running?' do
    it 'is true only between start and stop' do
      spinner = described_class.new(ui: quiet_console)
      expect(spinner.running?).to be(false)
      spinner.start
      expect(spinner.running?).to be(true)
      spinner.stop
      expect(spinner.running?).to be(false)
    end

    it 'does not raise when stop is called without start' do
      spinner = described_class.new(ui: quiet_console)
      expect { spinner.stop }.not_to raise_error
    end
  end

  describe '#update_detail (re-point without restarting, issue #40 follow-up)' do
    it 'updates only the message, keeps the existing suffix' do
      out = capture('Working', 'ctx 1/2 (50%)') do |spinner|
        spinner.start
        spinner.render!
        spinner.update_detail(message: 'Sending to gpt-x')
        spinner.render!
        spinner.stop
      end
      expect(out).to include('Working... ctx 1/2 (50%)')
      expect(out).to include('Sending to gpt-x... ctx 1/2 (50%)')
    end

    it 'updates only the suffix, keeps the existing message' do
      out = capture('Working', 'ctx 1/2 (50%)') do |spinner|
        spinner.start
        spinner.render!
        spinner.update_detail(suffix: 'file.read')
        spinner.render!
        spinner.stop
      end
      expect(out).to include('Working... ctx 1/2 (50%)')
      expect(out).to include('Working... file.read')
    end

    it 'accepts a callable suffix and keeps animating' do
      value = 'ctx 1/10 (10%)'
      out = capture('Working') do |spinner|
        spinner.start
        spinner.update_detail(suffix: -> { value })
        spinner.render!
        value = 'ctx 9/10 (90%)'
        spinner.render!
        spinner.stop
      end
      expect(out).to include('Working... ctx 1/10 (10%)')
      expect(out).to include('Working... ctx 9/10 (90%)')
    end

    it 'is a no-op when nothing is passed' do
      spinner = described_class.new('Working', 'ctx 1/2 (50%)', ui: quiet_console)
      spinner.update_detail

      expect(spinner.instance_variable_get(:@message)).to eq('Working')
      expect(spinner.instance_variable_get(:@suffix)).to eq('ctx 1/2 (50%)')
    end
  end

  describe '#clear_line (issue #125)' do
    it 'clears the line with an ANSI erase escape, independent of glyph width' do
      # A double-width emoji in the suffix used to make the blank-space clear
      # one column short, leaving a stray ")" on the next line. The ANSI
      # erase-to-end escape clears the whole line regardless of width.
      suffix = '🧠 ctx 42133/65536 (64%)'
      out = capture('Sending to gpt-x', suffix) do |spinner|
        spinner.start
        spinner.render!
        spinner.clear_line
        spinner.stop
      end
      expect(out).to include("\e[2K")
    end
  end

  describe '#line (deterministic frame text)' do
    it 'returns the correct frame string for a given index' do
      spinner = described_class.new('Working', 'ctx 1/2 (50%)', ui: quiet_console)
      expect(spinner.line(0)).to eq("#{UI::Spinner::FRAMES[0]} Working... ctx 1/2 (50%)")
    end

    it 'wraps around the FRAMES array' do
      spinner = described_class.new('Working', ui: quiet_console)
      expect(spinner.line(UI::Spinner::FRAMES.size)).to eq("#{UI::Spinner::FRAMES[0]} Working...")
    end
  end

  describe '#badge (issue #224 follow-up: live consent-mode badge at the END)' do
    it 'is nil by default (renders nothing, frame format unchanged)' do
      spinner = described_class.new('Working', ui: quiet_console)
      expect(spinner.badge).to be_nil
      expect(spinner.line(0)).to eq("#{UI::Spinner::FRAMES[0]} Working...")
    end

    it 'renders a plain-string badge at the end of the line' do
      out = capture('Working') do |spinner|
        spinner.badge = '[MANUAL]'
        spinner.start
        spinner.render!
        spinner.stop
      end
      expect(out).to include("#{UI::Spinner::FRAMES[0]} Working... [MANUAL]")
    end

    it 're-evaluates a callable badge every frame so it tracks live state' do
      mode = 'MANUAL'
      out = capture('Working') do |spinner|
        spinner.badge = -> { "[#{mode}]" }
        spinner.start
        spinner.render!
        mode = 'AUTO-APPROVE'
        spinner.render!
        spinner.stop
      end
      expect(out).to include("#{UI::Spinner::FRAMES[0]} Working... [MANUAL]")
      expect(out).to include("#{UI::Spinner::FRAMES[1]} Working... [AUTO-APPROVE]")
    end

    it 'renders a nil badge value as nothing on the very next frame' do
      out = capture('Working') do |spinner|
        spinner.badge = -> { '[MANUAL]' }
        spinner.start
        spinner.render!
        spinner.badge = -> { nil } # safety check switched off -> no badge
        spinner.render!
        spinner.stop
      end
      expect(out).to include('Working... [MANUAL]')
      expect(out).to include("#{UI::Spinner::FRAMES[1]} Working...")
      # The SECOND frame must carry no badge at all (frame 0 legitimately
      # does, so the assertion is anchored on the second frame's glyph).
      expect(out).not_to include("#{UI::Spinner::FRAMES[1]} Working... [")
    end

    it 'combines a badge with a suffix' do
      out = capture('Working', 'ctx 1/2 (50%)') do |spinner|
        spinner.badge = '[AUTO-APPROVE]'
        spinner.start
        spinner.render!
        spinner.stop
      end
      expect(out).to include('Working... ctx 1/2 (50%) [AUTO-APPROVE]')
    end

    it 'falls back to no badge when the callable raises' do
      out = capture('Working') do |spinner|
        spinner.badge = -> { raise 'boom' }
        spinner.start
        spinner.render!
        spinner.stop
      end
      expect(out).to include("#{UI::Spinner::FRAMES[0]} Working...")
    end
  end

  # Issue #277: the turn's elapsed time, drawn right after the frame glyph so
  # the counter sits at a fixed column no matter what the message says.
  describe '#elapsed (issue #277: turn clock right after the glyph)' do
    it 'is nil by default (renders nothing, frame format unchanged)' do
      spinner = described_class.new('Working', ui: quiet_console)
      expect(spinner.elapsed).to be_nil
      expect(spinner.line(0)).to eq("#{UI::Spinner::FRAMES[0]} Working...")
    end

    it 'renders a plain-string elapsed segment between the glyph and the message' do
      out = capture('Sending to gpt-x') do |spinner|
        spinner.elapsed = '12s'
        spinner.start
        spinner.render!
        spinner.stop
      end
      expect(out).to include("#{UI::Spinner::FRAMES[0]} 12s Sending to gpt-x...")
    end

    it 're-evaluates a callable elapsed clock every frame' do
      secs = 0
      out = capture('Working', 'ctx 1/2 (50%)') do |spinner|
        spinner.elapsed = -> { "#{secs}s" }
        spinner.start
        spinner.render!
        secs = 3
        spinner.render!
        spinner.stop
      end
      expect(out).to include("#{UI::Spinner::FRAMES[0]} 0s Working... ctx 1/2 (50%)")
      expect(out).to include("#{UI::Spinner::FRAMES[1]} 3s Working... ctx 1/2 (50%)")
    end

    it 'renders nothing when the clock resolves to nil (task not started)' do
      out = capture('Working') do |spinner|
        spinner.elapsed = -> { nil }
        spinner.start
        spinner.render!
        spinner.stop
      end
      expect(out).to include("#{UI::Spinner::FRAMES[0]} Working...")
      expect(out).not_to include("#{UI::Spinner::FRAMES[0]}  Working")
    end

    it 'falls back to no segment when the clock raises' do
      out = capture('Working') do |spinner|
        spinner.elapsed = -> { raise 'boom' }
        spinner.start
        spinner.render!
        spinner.stop
      end
      expect(out).to include("#{UI::Spinner::FRAMES[0]} Working...")
    end
  end

  # Issue #364: the tok/s slot is redrawn every frame. Two defects, two fixes:
  # a frame was written with "\r" alone (cursor to column 0, NO erase) so any
  # frame SHORTER than the previous one left its tail on the line, and the
  # suffix resolution stripped the LEADING blank a padded rate number carries,
  # putting the number back in the position that shifts between frames.
  describe 'frame stability (issue #364)' do
    it 'erases the line before drawing every frame' do
      out = capture('Working') do |spinner|
        spinner.start
        2.times { spinner.render! }
        spinner.stop
      end
      expect(out.scan("\r\e[2K").size).to eq(2)
      expect(out).not_to match(/\r(?!\e\[2K)/)
    end

    it 'erases before a SHORTER frame, so its predecessor leaves no tail' do
      # The reported residue: the [STREAM] badge disappeared while a longer
      # frame was still on the line, and the leftover "]" read as "[MANUAL]REAM]".
      badge = '[STREAM] [MANUAL]'
      out = capture('Sending to model') do |spinner|
        spinner.badge = -> { badge }
        spinner.start
        spinner.render!
        badge = nil
        spinner.render!
        spinner.stop
      end
      last_frame = out.split("\e[2K").last
      expect(last_frame).to eq("#{UI::Spinner::FRAMES[1]} Sending to model...")
      expect(last_frame).not_to include('[')
    end

    it 'keeps a padded rate suffix in the same column across frames' do
      rates = [9.0, 99.9, 9.0]
      tick  = -1
      rate    = -> do
        LLM::UsageStats.rate_segment(rates[tick += 1], measured_by_server: false, pad: true)
      end
      spinner = described_class.new('Sending to model', rate, ui: quiet_console)
      spinner.badge = '[STREAM]'
      lines  = 3.times.map { |i| spinner.line(i) }
      # Nothing after the number moves: every frame is the same length even
      # though the rate itself changes width (9.0 vs 99.9).
      expect(lines.map(&:length).uniq).to eq([lines[0].length])
      expect(lines[0]).to include('~ 9.0 tok/s [STREAM]')
      expect(lines[1]).to include('~99.9 tok/s [STREAM]')
    end

    it 'renders a padded segment without shifting the badge after it' do
      out = capture('Working', -> { ' 9.0 tok/s' }) do |spinner|
        spinner.badge = '[STREAM]'
        spinner.start
        spinner.render!
        spinner.stop
      end
      expect(out).to include("#{UI::Spinner::FRAMES[0]} Working...  9.0 tok/s [STREAM]")
    end
  end
end
