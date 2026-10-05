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

    it 'strips surrounding whitespace from a string suffix' do
      out = capture('Working', '  ctx 1/2 (50%)  ') do |spinner|
        spinner.start
        spinner.render!
        spinner.stop
      end
      expect(out).to include('Working... ctx 1/2 (50%)')
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
end
