# frozen_string_literal: true

require 'spinner'
require 'stringio'

RSpec.describe Spinner do
  # Capture everything written to $stdout while the block runs. The
  # animation thread writes via print, so it goes to $stdout too.
  def capture_stdout
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end

  describe 'construction' do
    it 'defaults to the "Working" message with no suffix' do
      spinner = described_class.new
      expect(spinner.instance_variable_get(:@message)).to eq('Working')
      expect(spinner.instance_variable_get(:@suffix)).to be_nil
    end

    it 'accepts a custom message and a plain-string suffix (issue #115)' do
      spinner = described_class.new('Sending to gpt-x', '🧠 ctx 42133/65536 (64%)')
      expect(spinner.instance_variable_get(:@message)).to eq('Sending to gpt-x')
      expect(spinner.instance_variable_get(:@suffix)).to eq('🧠 ctx 42133/65536 (64%)')
    end

    it 'accepts a callable suffix that is stored for per-frame evaluation (issue #126)' do
      live = -> { 'ctx 9/10 (90%)' }
      spinner = described_class.new('Sending to gpt-x', live)
      expect(spinner.instance_variable_get(:@suffix)).to be(live)
    end
  end

  describe '#start / #stop rendering' do
    it 'renders the frame, message and a string suffix on one line' do
      spinner = described_class.new('Sending to gpt-x', '🧠 ctx 42133/65536 (64%)')
      out = capture_stdout do
        spinner.start
        sleep 0.25 # let at least two frames render
        spinner.stop
      end
      expect(out).to include('Sending to gpt-x... 🧠 ctx 42133/65536 (64%)')
    end

    it 'renders only the message when no suffix is given' do
      spinner = described_class.new('Working')
      out = capture_stdout do
        spinner.start
        sleep 0.25
        spinner.stop
      end
      expect(out).to include('Working...')
      # No stray trailing space before the line ends (suffix must be absent).
      expect(out).not_to include('Working... ')
    end

    it 'strips surrounding whitespace from a string suffix' do
      spinner = described_class.new('Working', '  ctx 1/2 (50%)  ')
      out = capture_stdout do
        spinner.start
        sleep 0.25
        spinner.stop
      end
      expect(out).to include('Working... ctx 1/2 (50%)')
    end

    it 're-evaluates a callable suffix every frame so it tracks live state (issue #126)' do
      value = 'ctx 1/10 (10%)'
      spinner = described_class.new('Sending to gpt-x', -> { value })
      out = capture_stdout do
        spinner.start
        sleep 0.15
        # The "current" value changes mid-animation; the suffix must follow it.
        value = 'ctx 9/10 (90%)'
        sleep 0.25
        spinner.stop
      end
      expect(out).to include('Sending to gpt-x... ctx 1/10 (10%)')
      expect(out).to include('Sending to gpt-x... ctx 9/10 (90%)')
    end

    it 'falls back to no suffix when the callable raises' do
      spinner = described_class.new('Working', -> { raise 'boom' })
      out = capture_stdout do
        spinner.start
        sleep 0.25
        spinner.stop
      end
      expect(out).to include('Working...')
      expect(out).not_to include('Working... ')
    end

    it 'pause clears the line and resume restarts the animation' do
      spinner = described_class.new('Working', 'ctx 1/2 (50%)')
      out = capture_stdout do
        spinner.start
        sleep 0.25
        spinner.pause
        expect(spinner.instance_variable_get(:@thread)).to be_nil
        spinner.resume
        sleep 0.25
        spinner.stop
      end
      expect(out).to include('Working... ctx 1/2 (50%)')
    end

    it 'reports running? only while the animation thread is live' do
      spinner = described_class.new
      expect(spinner.running?).to be(false)
      capture_stdout do
        spinner.start
        expect(spinner.running?).to be(true)
        spinner.pause
        expect(spinner.running?).to be(false)
        spinner.resume
        expect(spinner.running?).to be(true)
        spinner.stop
        expect(spinner.running?).to be(false)
      end
    end

    it 'does not resume a stopped spinner (issue #116)' do
      spinner = described_class.new
      capture_stdout do
        spinner.start
        sleep 0.15
        spinner.stop
        spinner.resume
        expect(spinner.running?).to be(false)
      end
    end

    it 'does not raise when stop is called without start' do
      spinner = described_class.new
      capture_stdout { spinner.stop }
    end
  end

  describe 'line clearing (issue #125)' do
    it 'clears the line with an ANSI erase escape, independent of glyph width' do
      # A double-width emoji in the suffix used to make the blank-space clear
      # one column short, leaving a stray ")" on the next line. The ANSI
      # erase-to-end escape clears the whole line regardless of width.
      spinner = described_class.new('Sending to gpt-x', '🧠 ctx 42133/65536 (64%)')
      out = capture_stdout do
        spinner.start
        sleep 0.25
        spinner.stop
      end
      expect(out).to include("\e[2K")
    end
  end
end
