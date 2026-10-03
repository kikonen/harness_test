# frozen_string_literal: true

require 'ui'
require 'stringio'

# The Spinner suite (issue #74 / #40): the class lives in the `UI` namespace.
# Single-thread I/O model (issue #40): start/stop/pause/resume are pure state
# changes (no background thread). render! advances one animation frame and
# writes it to $stdout. The main thread calls render! on each drain tick.
# Tests assert the frame text via capture_stdout + render!, not via sleep-based
# thread observation.
RSpec.describe UI::Spinner do
  OVERRIDE = UI::Spinner::ENV_OVERRIDE

  # Force the ANSI renderer for ALL examples: they must be deterministic and
  # must never touch a real terminal or load the ratatui native extension.
  before(:context) do
    @original_override = ENV[OVERRIDE]
    ENV[OVERRIDE] = 'print'
  end

  after(:context) do
    if @original_override.nil?
      ENV.delete(OVERRIDE)
    else
      ENV[OVERRIDE] = @original_override
    end
  end

  # Capture everything written to $stdout while the block runs.
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

  describe '#render! and frame advancement' do
    it 'renders the frame, message and a string suffix on one line' do
      spinner = described_class.new('Sending to gpt-x', '🧠 ctx 42133/65536 (64%)')
      out = capture_stdout do
        spinner.start
        spinner.render!
        spinner.stop
      end
      expect(out).to include('Sending to gpt-x... 🧠 ctx 42133/65536 (64%)')
    end

    it 'renders only the message when no suffix is given' do
      spinner = described_class.new('Working')
      out = capture_stdout do
        spinner.start
        spinner.render!
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
        spinner.render!
        spinner.stop
      end
      expect(out).to include('Working... ctx 1/2 (50%)')
    end

    it 're-evaluates a callable suffix every frame so it tracks live state (issue #126)' do
      value = 'ctx 1/10 (10%)'
      spinner = described_class.new('Sending to gpt-x', -> { value })
      out = capture_stdout do
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
      spinner = described_class.new('Working', -> { raise 'boom' })
      out = capture_stdout do
        spinner.start
        spinner.render!
        spinner.stop
      end
      expect(out).to include('Working...')
      expect(out).not_to include('Working... ')
    end

    it 'advances through frames sequentially' do
      spinner = described_class.new('Working')
      out = capture_stdout do
        spinner.start
        3.times { spinner.render! }
        spinner.stop
      end
      # Each frame uses the next glyph from FRAMES
      expect(out).to include(UI::Spinner::FRAMES[0])
      expect(out).to include(UI::Spinner::FRAMES[1])
      expect(out).to include(UI::Spinner::FRAMES[2])
    end
  end

  describe '#pause / #resume state management' do
    it 'reports running? only when active and not paused' do
      spinner = described_class.new
      expect(spinner.running?).to be(false)
      spinner.start
      expect(spinner.running?).to be(true)
      spinner.pause
      expect(spinner.running?).to be(false)
      spinner.resume
      expect(spinner.running?).to be(true)
      spinner.stop
      expect(spinner.running?).to be(false)
    end

    it 'does not resume a stopped spinner (issue #116)' do
      spinner = described_class.new
      spinner.start
      spinner.stop
      spinner.resume
      expect(spinner.running?).to be(false)
    end

    it 'pause prevents render! from writing' do
      spinner = described_class.new('Working', 'ctx 1/2 (50%)')
      out = capture_stdout do
        spinner.start
        spinner.pause
        spinner.render! # should be no-op
        spinner.stop
      end
      expect(out).to eq('')
    end

    it 'resume restores rendering after pause' do
      spinner = described_class.new('Working', 'ctx 1/2 (50%)')
      out = capture_stdout do
        spinner.start
        spinner.pause
        spinner.resume
        spinner.render!
        spinner.stop
      end
      expect(out).to include('Working... ctx 1/2 (50%)')
    end

    it 'does not raise when stop is called without start' do
      spinner = described_class.new
      capture_stdout { spinner.stop }
    end
  end

  describe '#clear_line (issue #125)' do
    it 'clears the line with an ANSI erase escape, independent of glyph width' do
      # A double-width emoji in the suffix used to make the blank-space clear
      # one column short, leaving a stray ")" on the next line. The ANSI
      # erase-to-end escape clears the whole line regardless of width.
      spinner = described_class.new('Sending to gpt-x', '🧠 ctx 42133/65536 (64%)')
      out = capture_stdout do
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
      spinner = described_class.new('Working', 'ctx 1/2 (50%)')
      expect(spinner.line(0)).to eq("#{UI::Spinner::FRAMES[0]} Working... ctx 1/2 (50%)")
    end

    it 'wraps around the FRAMES array' do
      spinner = described_class.new('Working')
      expect(spinner.line(UI::Spinner::FRAMES.size)).to eq("#{UI::Spinner::FRAMES[0]} Working...")
    end
  end

  # Renderer-selection gate: exercise the ENV override directly, restoring the
  # suite's 'print' default after each case so it works regardless of the
  # actual terminal. The tty branch is stubbed (a fake IO would otherwise
  # make interactive_tty? report false on real runs).
  describe 'renderer selection (issue #74)' do
    def with_override(value)
      if value.nil?
        ENV.delete(OVERRIDE)
      else
        ENV[OVERRIDE] = value
      end
      yield
    ensure
      ENV[OVERRIDE] = 'print' # restore the suite default for the next example
    end

    it 'is forced to the ANSI spinner when HARNESS_SPINNER=print (case-insensitive)' do
      with_override('PRINT') { expect(described_class.new.forced_print?).to be(true) }
    end

    it 'is NOT forced by an unrelated override value' do
      with_override('tui') { expect(described_class.new.forced_print?).to be(false) }
    end

    it 'prefers the TUI renderer on an interactive terminal when not forced' do
      spinner = described_class.new
      with_override(nil) do
        allow(spinner).to receive(:interactive_tty?).and_return(true)
        expect(spinner.tui_preferred?).to be(true)
      end
    end

    it 'never uses the TUI renderer when output is not an interactive terminal (CI / pipes)' do
      spinner = described_class.new
      with_override(nil) do
        allow(spinner).to receive(:interactive_tty?).and_return(false)
        expect(spinner.tui_preferred?).to be(false)
      end
    end

    it 'stays on the ANSI path even when a TTY is present but the user pinned print' do
      spinner = described_class.new
      with_override('print') do
        allow(spinner).to receive(:interactive_tty?).and_return(true)
        expect(spinner.tui_preferred?).to be(false)
      end
    end
  end

  describe 'backward-compatible top-level alias' do
    it 'exposes the namespaced Spinner as the legacy top-level Spinner' do
      expect(Spinner).to be(UI::Spinner)
    end

    it 'is constructible through the legacy alias with identical behavior' do
      spinner = Spinner.new('Working', 'ctx 1/2 (50%)')
      out = capture_stdout do
        spinner.start
        spinner.render!
        spinner.stop
      end
      expect(out).to include('Working... ctx 1/2 (50%)')
    end
  end
end
