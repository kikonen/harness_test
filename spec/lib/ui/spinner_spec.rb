# frozen_string_literal: true

require 'ui'
require 'stringio'

# The Spinner suite (issue #74): the class lives in the `UI` namespace.
# Behavior is asserted IDENTICALLY to the pre-migration top-level Spinner
# (frame/message/suffix rendering, callable suffix re-evaluation, pause/
# resume, running? gating, stop-without-start, and the width-independent ANSI
# line clear), plus a group pinning the renderer-selection gate (the TUI
# renderer must only be used on an interactive terminal / never in CI) and a
# group for the backward-compatible `Spinner` alias.
RSpec.describe UI::Spinner do
  OVERRIDE = UI::Spinner::ENV_OVERRIDE

  # Force the ANSI renderer for ALL examples: they must be deterministic and
  # must never touch a real terminal or load the ratatui native extension
  # (which would not render into captured $stdout). Restored after the suite.
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
        sleep 0.25
        spinner.stop
      end
      expect(out).to include('Working... ctx 1/2 (50%)')
    end
  end
end
