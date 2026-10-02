# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

# The Dialog suite (issue #74): the class lives in the `UI` namespace.
# Behavior is asserted IDENTICALLY to the pre-migration top-level Dialog
# (option handling, notes, free text, multi-select, out-of-range re-prompt),
# plus a group for the backward-compatible `Dialog` alias.
RSpec.describe UI::Dialog do
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
      expect(result).to eq(UI::Dialog::CANCEL_VALUE)
    end

    it 'skips stale blank lines before a valid answer' do
      stub_stdin("\n", "\n", "1\n")
      expect(show(described_class.new(title: 't', options: options))).to eq(:allow)
    end

    it 'cancels on EOF without an answer' do
      stub_stdin(nil)
      expect(show(described_class.new(title: 't', options: options)))
        .to eq(UI::Dialog::CANCEL_VALUE)
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
          .to eq([UI::Dialog::CANCEL_VALUE, 'no, and because X'])
      end
    end

    describe 'with note_on_cancel_only (grant dialogs, issue #79)' do
      let(:dialog) do
        described_class.new(
          title: 't', options: options, note_on_cancel_only: true
        )
      end

      it 'ignores a note on a non-cancel choice' do
        stub_stdin("1 seems fine\n")
        expect(show(dialog)).to eq(:allow)
      end

      it 'keeps the note on the cancel choice' do
        stub_stdin("3 no, and because X\n")
        expect(show(dialog)).to eq([UI::Dialog::CANCEL_VALUE, 'no, and because X'])
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
        expect(show(dialog)).to eq([UI::Dialog::FREE_TEXT, 'looks good to me'])
      end

      it 'still returns [value, note] when a number leads' do
        stub_stdin("3 no, and because X\n")
        expect(show(dialog)).to eq([UI::Dialog::CANCEL_VALUE, 'no, and because X'])
      end

      it 'cancels on EOF' do
        stub_stdin(nil)
        expect(show(dialog)).to eq(UI::Dialog::CANCEL_VALUE)
      end
    end

    describe 'out-of-range option numbers (issue #73)' do
      let(:dialog) { described_class.new(title: 't', options: options) }

      it 're-prompts with an invalid message, then accepts a valid choice' do
        stub_stdin("9\n", "1\n")
        out = capture_stdout { expect(show(dialog)).to eq(:allow) }
        expect(out).to include('invalid choice 9 (valid: 1..3)')
      end

      it 're-prompts on "<number> <note>" with an out-of-range number' do
        stub_stdin("9 nope\n", "2\n")
        out = capture_stdout { expect(show(dialog)).to eq(:deny) }
        expect(out).to include('invalid choice 9 (valid: 1..3)')
      end

      it 'still cancels when the user dismisses with EOF' do
        stub_stdin("9\n", nil)
        expect(show(dialog)).to eq(UI::Dialog::CANCEL_VALUE)
      end

      it 're-prompts even in free-text mode (no silent free text)' do
        dialog = described_class.new(
          title: 't', options: options, free_text: true, free_text_prompt: 'or type a short note'
        )
        stub_stdin("9\n", "1\n")
        out = capture_stdout { expect(show(dialog)).to eq(:allow) }
        expect(out).to include('invalid choice 9 (valid: 1..3)')
      end

      it 'still accepts genuine free text after an invalid number' do
        dialog = described_class.new(
          title: 't', options: options, free_text: true, free_text_prompt: 'or type a short note'
        )
        stub_stdin("9\n", "something else entirely\n")
        expect(show(dialog)).to eq([UI::Dialog::FREE_TEXT, 'something else entirely'])
      end
    end

    describe 'with multi_select' do
      let(:dialog) { described_class.new(title: 't', options: options, multi_select: true) }
      # Options: Allow(1), Deny(2), Cancel(3).

      it 'returns an array of values in the order typed for "n m"' do
        stub_stdin("1 2\n")
        expect(show(dialog)).to eq([:allow, :deny])
      end

      it 'accepts comma-separated numbers' do
        stub_stdin("1,2\n")
        expect(show(dialog)).to eq([:allow, :deny])
      end

      it 'returns the bare value for a single number' do
        stub_stdin("1\n")
        expect(show(dialog)).to eq(:allow)
      end

      it 'returns CANCEL_VALUE when cancel is part of the selection' do
        stub_stdin("1 3\n")
        expect(show(dialog)).to eq(UI::Dialog::CANCEL_VALUE)
      end

      it 'cancels on "<number> <note>" for a non-cancel choice' do
        stub_stdin("1 seems fine\n")
        expect(show(dialog)).to eq(UI::Dialog::CANCEL_VALUE)
      end

      it 'keeps the note on the cancel choice' do
        stub_stdin("3 no, and because X\n")
        expect(show(dialog)).to eq([UI::Dialog::CANCEL_VALUE, 'no, and because X'])
      end

      it 're-prompts when any number is out of range, then accepts a valid line' do
        stub_stdin("1 9\n", "2\n")
        out = capture_stdout { expect(show(dialog)).to eq(:deny) }
        expect(out).to include('invalid choice 9 (valid: 1..3)')
      end

      it 'still cancels on EOF' do
        stub_stdin(nil)
        expect(show(dialog)).to eq(UI::Dialog::CANCEL_VALUE)
      end

      it 'shows a multi-select hint in the choice prompt' do
        stub_stdin(nil)
        out = capture_stdout { show(dialog) }
        expect(out).to include('several numbers like "1 3"')
      end
    end
  end

  describe 'backward-compatible top-level alias' do
    it 'exposes the namespaced Dialog as the legacy top-level Dialog' do
      expect(Dialog).to be(UI::Dialog)
    end

    it 'shares its constants with the namespaced class' do
      expect(Dialog::CANCEL_VALUE).to eq(UI::Dialog::CANCEL_VALUE)
      expect(Dialog::FREE_TEXT).to eq(UI::Dialog::FREE_TEXT)
    end

    it 'is constructible through the legacy alias with identical behavior' do
      stub_stdin("1 seems fine\n")
      dialog = Dialog.new(
        title: 't',
        options: [Dialog::Option.new(title: 'Allow', value: :allow)]
      )
      expect(dialog.show).to eq([:allow, 'seems fine'])
    end
  end
end
