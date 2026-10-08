# frozen_string_literal: true

require 'spec_helper'
require 'task'
require 'ui/console'
require 'stringio'

# The Dialog suite (issue #74): the class lives in the `UI` namespace.
# Behavior is asserted for the current contract (option handling, notes,
# explicit "Other" free-text option, multi-select incl. with free text,
# out-of-range re-prompt, cancel-is-always-explicit).
RSpec.describe UI::Dialog do
  let(:options) do
    [
      described_class::Option.new(title: 'Allow', value: :allow),
      described_class::Option.new(title: 'Deny', value: :deny, description: 'no access')
    ]
  end

  # Per-example streams behind the UI::Console (issue #40 / TUI prep): no
  # $stdout / $stdin globals are touched anywhere in this suite.
  let(:io_in)   { StringIO.new }
  let(:io_out)  { StringIO.new }
  let(:console) { UI::Console.new(stdout: io_out, stdin: io_in) }

  # Feed a sequence of lines into the console's stdin (empty = immediate EOF).
  def stub_stdin(*lines)
    lines.compact.each { |line| io_in << line }
    io_in.rewind # `<<` leaves the position at EOF; rewind so gets() reads it
  end

  def show(dialog)
    dialog.show(ui: console)
  end

  # Everything the dialog wrote, as a string.
  def capture
    io_out.string
  end

  describe 'stream contract (issue #40: no global stream access)' do
    let(:dialog) { described_class.new(title: 't', options: options) }

    it 'raises when no Task is active and the ui console is nil' do
      expect { dialog.show }.to raise_error(ArgumentError, /explicit ui: console/)
    end

    context 'on a task thread (Thread.current[:harness_task] set)' do
      around do |example|
        old = Thread.current[:harness_task]
        Thread.current[:harness_task] = Task.new { }
        example.run
      ensure
        Thread.current[:harness_task] = old
      end

      it 'routes through the task and rejects a named console' do
        expect { dialog.show(ui: console) }
          .to raise_error(ArgumentError, /pass ui: nil/)
      end

      it 'passes ui: nil straight to the task request protocol' do
        task = Task.current
        expect(task).to receive(:request).with(:dialog, dialog: dialog).and_return(:yes)
        expect(dialog.show(ui: nil)).to eq(:yes)
      end
    end
  end

  describe 'construction' do
    it 'appends the standard Cancel option automatically' do
      dialog = described_class.new(title: 't', options: options)
      expect(dialog.options.map(&:value)).to eq(%i[allow deny cancelled])
    end

    it 'inserts the explicit "Other" option before cancel when free_text is on' do
      dialog = described_class.new(title: 't', options: options, free_text: true)
      expect(dialog.options.map(&:value))
        .to eq([:allow, :deny, UI::Dialog::FREE_TEXT, UI::Dialog::CANCEL_VALUE])
    end

    it 'uses the default label for the "Other" option without a hint' do
      dialog = described_class.new(title: 't', options: options, free_text: true)
      expect(dialog.options[2].title).to eq(UI::Dialog::FREE_TEXT_OPTION)
    end

    it 'uses the free_text_prompt as the label of the "Other" option' do
      dialog = described_class.new(
        title: 't', options: options,
        free_text: true, free_text_prompt: 'or type a short note'
      )
      expect(dialog.options[2].title).to eq('type a short note')
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

    describe 'with free text enabled (explicit "Other" option)' do
      # Options: Allow(1), Deny(2), Other(3), Cancel(4).
      let(:dialog) do
        described_class.new(
          title: 't', options: options,
          free_text: true, free_text_prompt: 'or type a short note'
        )
      end

      it 'renders the "Other" option with the hint as its label' do
        stub_stdin(nil)
        show(dialog)
        expect(capture).to include('3) type a short note')
        expect(capture).to include('4) Cancel')
      end

      it 'shows a generic "Other" label without a hint' do
        plain = described_class.new(
          title: 't', options: options, free_text: true
        )
        stub_stdin(nil)
        show(plain)
        expect(capture).to include("3) #{UI::Dialog::FREE_TEXT_OPTION}")
      end

      it 'prompts for the typed answer when "Other" is picked' do
        stub_stdin("3\n", "my own answer\n")
        expect(show(dialog)).to eq([UI::Dialog::FREE_TEXT, 'my own answer'])
      end

      it 'takes "<Other number> <text>" as the answer on one line' do
        stub_stdin("3 my own answer\n")
        expect(show(dialog)).to eq([UI::Dialog::FREE_TEXT, 'my own answer'])
      end

      it 'cancels on EOF at the free-text prompt' do
        stub_stdin("3\n", nil)
        expect(show(dialog)).to eq(UI::Dialog::CANCEL_VALUE)
      end

      it 're-prompts on stray text instead of taking it as the answer' do
        stub_stdin("looks good to me\n", "1\n")
        expect(show(dialog)).to eq(:allow)
        expect(capture).to include('invalid choice looks good to me (valid: 1..4)')
      end

      it 'still returns [value, note] when a number leads' do
        stub_stdin("4 no, and because X\n")
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
        expect(show(dialog)).to eq(:allow)
        expect(capture).to include('invalid choice 9 (valid: 1..3)')
      end

      it 're-prompts on "<number> <note>" with an out-of-range number' do
        stub_stdin("9 nope\n", "2\n")
        expect(show(dialog)).to eq(:deny)
        expect(capture).to include('invalid choice 9 (valid: 1..3)')
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
        expect(show(dialog)).to eq(:allow)
        expect(capture).to include('invalid choice 9 (valid: 1..4)')
      end

      it 'still reaches the free-text flow after an invalid number' do
        dialog = described_class.new(
          title: 't', options: options, free_text: true, free_text_prompt: 'or type a short note'
        )
        stub_stdin("9\n", "3 something else entirely\n")
        expect(show(dialog)).to eq([UI::Dialog::FREE_TEXT, 'something else entirely'])
      end
    end

    describe 'stray non-numeric input in a plain dialog (issue #155)' do
      let(:dialog) { described_class.new(title: 't', options: options) }

      it 're-prompts on random text instead of cancelling' do
        stub_stdin("s1\n", "1\n")
        expect(show(dialog)).to eq(:allow)
        expect(capture).to include('invalid choice s1 (valid: 1..3)')
      end

      it 'still cancels when the user dismisses with EOF after stray text' do
        stub_stdin("s1\n", nil)
        expect(show(dialog)).to eq(UI::Dialog::CANCEL_VALUE)
      end

      it 're-prompts on a full word and accepts the next valid choice' do
        stub_stdin("nope\n", "3\n")
        expect(show(dialog)).to eq(UI::Dialog::CANCEL_VALUE)
        expect(capture).to include('invalid choice nope (valid: 1..3)')
      end
    end

    describe 'with multi_select' do
      # Options: Allow(1), Deny(2), Cancel(3).
      let(:dialog) { described_class.new(title: 't', options: options, multi_select: true) }

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
        expect(show(dialog)).to eq(:deny)
        expect(capture).to include('invalid choice 9 (valid: 1..3)')
      end

      it 'still cancels on EOF' do
        stub_stdin(nil)
        expect(show(dialog)).to eq(UI::Dialog::CANCEL_VALUE)
      end

      it 'shows a multi-select hint in the choice prompt' do
        stub_stdin(nil)
        show(dialog)
        expect(capture).to include('several numbers like "1 3"')
      end
    end

    describe 'with multi_select AND free_text (issue #72)' do
      # Options: Allow(1), Deny(2), Other(3), Cancel(4).
      let(:dialog) do
        described_class.new(
          title: 't', options: options,
          multi_select: true, free_text: true,
          free_text_prompt: 'or type a short note'
        )
      end

      it 'prompts for the answer when "Other" is picked bare' do
        stub_stdin("3\n", "typed answer\n")
        expect(show(dialog)).to eq([UI::Dialog::FREE_TEXT, 'typed answer'])
      end

      it 'prompts for the answer when "Other" is mixed into a selection' do
        stub_stdin("1 3\n", "typed answer\n")
        expect(show(dialog)).to eq([UI::Dialog::FREE_TEXT, 'typed answer'])
      end

      it 'cancels on EOF at the free-text prompt' do
        stub_stdin("3\n", nil)
        expect(show(dialog)).to eq(UI::Dialog::CANCEL_VALUE)
      end

      it 'still returns the selected values without "Other"' do
        stub_stdin("1 2\n")
        expect(show(dialog)).to eq([:allow, :deny])
      end

      it 'cancels when cancel is part of the selection' do
        stub_stdin("1 4\n")
        expect(show(dialog)).to eq(UI::Dialog::CANCEL_VALUE)
      end
    end
  end
end
