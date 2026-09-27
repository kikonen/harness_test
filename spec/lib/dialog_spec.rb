# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe Dialog do
  let(:options) do
    [
      described_class::Option.new(title: 'Allow', value: :allow),
      described_class::Option.new(title: 'Deny', value: :deny, description: 'no access')
    ]
  end

  # Feed a sequence of lines to $stdin (last element nil = EOF).
  def stub_stdin(*lines)
    allow($stdin).to receive(:gets).and_return(*lines)
  end

  def show(dialog)
    dialog.show
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
    it 'appends the standard Cancel option automatically' do
      dialog = described_class.new(title: 't', options: options)
      expect(dialog.options.map(&:value)).to eq(%i[allow deny cancelled])
    end

    it 'rejects an empty title' do
      expect { described_class.new(title: '  ', options: options) }
        .to raise_error(ArgumentError, /title/)
    end

    it 'rejects an empty options array' do
      expect { described_class.new(title: 't', options: []) }
        .to raise_error(ArgumentError, /non-empty/)
    end

    it 'rejects non-Option entries' do
      expect { described_class.new(title: 't', options: ['nope']) }
        .to raise_error(ArgumentError, /Dialog::Option/)
    end
  end

  describe '#show' do
    it 'returns the option value for a plain number' do
      stub_stdin("1\n")
      expect(show(described_class.new(title: 't', options: options))).to eq(:allow)
    end

    it 'returns CANCEL_VALUE when the cancel option is picked' do
      stub_stdin("3\n")
      result = show(described_class.new(title: 't', options: options))
      expect(result).to eq(Dialog::CANCEL_VALUE)
    end

    it 'skips stale blank lines before a valid answer' do
      stub_stdin("\n", "\n", "1\n")
      expect(show(described_class.new(title: 't', options: options))).to eq(:allow)
    end

    it 'cancels on EOF without an answer' do
      stub_stdin(nil)
      expect(show(described_class.new(title: 't', options: options)))
        .to eq(Dialog::CANCEL_VALUE)
    end

    describe 'with a note attached to the choice' do
      it 'returns [value, note] for "<number> <note>"' do
        stub_stdin("1 seems fine\n")
        expect(show(described_class.new(title: 't', options: options)))
          .to eq([:allow, 'seems fine'])
      end

      it 'allows a note on the cancel option too' do
        stub_stdin("3 no, and because X\n")
        expect(show(described_class.new(title: 't', options: options)))
          .to eq([Dialog::CANCEL_VALUE, 'no, and because X'])
      end

      it 'falls back to cancel for an out-of-range number without free text' do
        stub_stdin("9 nope\n")
        expect(show(described_class.new(title: 't', options: options)))
          .to eq(Dialog::CANCEL_VALUE)
      end
    end

    describe 'with free text enabled' do
      let(:dialog) do
        described_class.new(
          title: 't', options: options,
          free_text: true, free_text_prompt: 'or type a short note'
        )
      end

      it 'renders the choice prompt without a doubled "or"' do
        stub_stdin(nil)
        out = capture_stdout { show(dialog) }
        expect(out).not_to include('or or')
        expect(out).to include('or type a short note')
      end

      it 'returns [FREE_TEXT, text] for a non-numeric answer' do
        stub_stdin("looks good to me\n")
        expect(show(dialog)).to eq([Dialog::FREE_TEXT, 'looks good to me'])
      end

      it 'still returns [value, note] when a number leads' do
        stub_stdin("2 with caveat\n")
        expect(show(dialog)).to eq([:deny, 'with caveat'])
      end

      it 'cancels on EOF' do
        stub_stdin(nil)
        expect(show(dialog)).to eq(Dialog::CANCEL_VALUE)
      end
    end
  end
end