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
      expect(spinner.instance_variable_get(:@suffix)).to eq('')
    end

    it 'accepts a custom message and optional suffix (issue #115)' do
      spinner = described_class.new('Sending to gpt-x', '🧠 ctx 42133/65536 (64%)')
      expect(spinner.instance_variable_get(:@message)).to eq('Sending to gpt-x')
      expect(spinner.instance_variable_get(:@suffix)).to eq('🧠 ctx 42133/65536 (64%)')
    end

    it 'treats a nil suffix as no suffix' do
      spinner = described_class.new('Working', nil)
      expect(spinner.instance_variable_get(:@suffix)).to eq('')
    end

    it 'strips surrounding whitespace from the suffix' do
      spinner = described_class.new('Working', '  ctx 1/2 (50%)  ')
      expect(spinner.instance_variable_get(:@suffix)).to eq('ctx 1/2 (50%)')
    end
  end

  describe '#start / #stop' do
    it 'renders the frame, message and suffix on one line' do
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

    it 'clears the full line including the suffix on stop' do
      spinner = described_class.new('Sending to gpt-x', 'ctx 100/200 (50%)')
      out = capture_stdout do
        spinner.start
        sleep 0.25
        spinner.stop
      end
      # "Sending to gpt-x..." is 17 chars; the suffix adds 1 + 15 = 16 more.
      expect(out).to include(' ' * (17 + 16))
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
end
