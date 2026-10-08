# frozen_string_literal: true

require 'spec_helper'
require 'task'
require 'ui/console'
require 'stringio'

# The Dialog suite (issue #74): the class lives in the `UI` namespace.
# Behavior is asserted for the current contract (issue #72 unified design):
# the choice line is option numbers only - single-select IS multi-select
# with one number; stray text re-prompts (never selects/notes/cancels,
# issue #155); cancel keeps a one-line reason ("<cancel> <reason>",
# issue #79); free text is the explicit "Additional details" option,
# selectable alongside ANY options and Cancel, entered as a multi-line
# block (blank line finishes, Ctrl-D cancels), riding along as
# [FREE_TEXT, text]; out-of-range numbers re-prompt (issue #73).
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
    # Rewrite the stream (not append): an earlier example may leave its
    # position mid-stream, where << would overlap or truncate content.
    newlined = lines.map do |l|
      l.to_s.end_with?("\n") ? l.to_s : "#{l}\n"
    end
    # join("\n") would eat the last line's newline (EOF, not an answer).
    io_in.string = newlined.join
    io_in.rewind # string= leaves the position at EOF; rewind so gets() reads it
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

    it 'inserts the "Additional details" option before cancel when free_text is on' do
      dialog = described_class.new(title: 't', options: options, free_text: true)
      expect(dialog.options.map(&:value))
        .to eq([:allow, :deny, UI::Dialog::FREE_TEXT, UI::Dialog::CANCEL_VALUE])
    end

    it 'uses the default label for the "Additional details" option without a hint' do
      dialog = described_class.new(title: 't', options: options, free_text: true)
      expect(dialog.options[2].title).to eq(UI::Dialog::FREE_TEXT_OPTION)
    end

    it 'uses the free_text_prompt as the label of the "Additional details" option' do
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

    describe 'choice line is option numbers only (issue #72)' do
      let(:dialog) { described_class.new(title: 't', options: options) }

      it 're-prompts on "<number> <text>" for a non-cancel choice (no inline notes)' do
        stub_stdin("1 seems fine\n", "1\n")
        expect(show(dialog)).to eq(:allow)
        expect(capture).to include('invalid choice 1 seems fine (valid: 1..3)')
      end

      it 'keeps the one-line reason on the cancel choice' do
        stub_stdin("3 no, and because X\n")
        expect(show(dialog))
          .to eq([UI::Dialog::CANCEL_VALUE, 'no, and because X'])
      end
    end

    describe 'with free text enabled (the "Additional details" option)' do
      # Options: Allow(1), Deny(2), Additional details(3), Cancel(4).
      let(:dialog) do
        described_class.new(
          title: 't', options: options,
          free_text: true, free_text_prompt: 'or type a short note'
        )
      end

      it 'renders the "Additional details" option with the hint as its label' do
        stub_stdin(nil)
        show(dialog)
        expect(capture).to include('3) type a short note')
        expect(capture).to include('4) Cancel')
      end

      it 'shows the generic label without a hint' do
        plain = described_class.new(
          title: 't', options: options, free_text: true
        )
        stub_stdin(nil)
        show(plain)
        expect(capture).to include("3) #{UI::Dialog::FREE_TEXT_OPTION}")
      end

      it 'enters the text block when "Additional details" is picked bare' do
        stub_stdin("3\n", "my own answer\n", "")
        expect(show(dialog)).to eq([UI::Dialog::FREE_TEXT, 'my own answer'])
      end

      it 'takes a multi-line (pasted) block: lines until the blank one' do
        stub_stdin("3\n", "line one", "line two with spaces  ", "line three", "")
        expect(show(dialog))
          .to eq([UI::Dialog::FREE_TEXT, "line one\nline two with spaces\nline three"])
      end

      it 'keeps the selection when "Additional details" is mixed in (issue #72)' do
        stub_stdin("2 3\n", "second and a note\n", "")
        expect(show(dialog)).to eq([:deny, [UI::Dialog::FREE_TEXT, 'second and a note']])
      end

      it 'option + details works even without multi_select ("option X but blaa blaa")' do
        stub_stdin("1 3\n", "but please also do Y\n", "")
        expect(show(dialog))
          .to eq([:allow, [UI::Dialog::FREE_TEXT, 'but please also do Y']])
      end

      it 'cancel + details returns cancelled with the reason block (issue #72)' do
        stub_stdin("4 3\n", "because the options miss Z\n", "")
        expect(show(dialog))
          .to eq([UI::Dialog::CANCEL_VALUE, [UI::Dialog::FREE_TEXT, 'because the options miss Z']])
      end

      it 're-prompts the choice on an empty text block' do
        stub_stdin("3\n", "", "1\n")
        expect(show(dialog)).to eq(:allow)
        expect(capture).to include('no text entered')
      end

      it 'cancels the whole dialog on EOF inside the text block' do
        stub_stdin("3\n", nil)
        expect(show(dialog)).to eq(UI::Dialog::CANCEL_VALUE)
      end

      it 're-prompts on stray text instead of taking it as the answer' do
        stub_stdin("looks good to me\n", "1\n")
        expect(show(dialog)).to eq(:allow)
        expect(capture).to include('invalid choice looks good to me (valid: 1..4)')
      end

      it 'keeps the one-line reason form on cancel' do
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

      it 're-prompts when the line mixes a valid and an out-of-range number' do
        stub_stdin("1 9\n", "2\n")
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

      it 'still reaches the details flow after an invalid number' do
        dialog = described_class.new(
          title: 't', options: options, free_text: true, free_text_prompt: 'or type a short note'
        )
        stub_stdin("9\n", "3\n", "something else entirely\n", "")
        expect(show(dialog)).to eq([UI::Dialog::FREE_TEXT, 'something else entirely'])
      end
    end

    describe 'stray non-numeric input (issue #155)' do
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

      it 're-prompts on stray text mixed into a multi selection (never cancels)' do
        stub_stdin("2 3 4 does_this_show\n", "1 2\n")
        expect(show(dialog)).to eq([:allow, :deny])
        expect(capture).to include('invalid choice')
      end

      it 'keeps the one-line reason on cancel' do
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

    describe 'multi_select + free text (issue #72)' do
      # Options: Allow(1), Deny(2), Additional details(3), Cancel(4).
      let(:dialog) do
        described_class.new(
          title: 't', options: options,
          multi_select: true, free_text: true,
          free_text_prompt: 'or type a short note'
        )
      end

      it 'keeps ALL selections plus the typed details (no mutual exclusion)' do
        stub_stdin("2 3 4\n", "you see second and third selected\n", "")
        expect(show(dialog))
          .to eq([:deny, [UI::Dialog::FREE_TEXT, 'you see second and third selected']])
      end

      it 'cancels on EOF inside the text block' do
        stub_stdin("3\n", nil)
        expect(show(dialog)).to eq(UI::Dialog::CANCEL_VALUE)
      end

      it 'still returns the selected values without "Additional details"' do
        stub_stdin("1 2\n")
        expect(show(dialog)).to eq([:allow, :deny])
      end

      it 'cancels when cancel is part of the selection' do
        stub_stdin("1 4\n")
        expect(show(dialog)).to eq(UI::Dialog::CANCEL_VALUE)
      end

      it 're-prompts on stray text before accepting a valid line' do
        stub_stdin("does_this_show 2\n", "1\n")
        expect(show(dialog)).to eq(:allow)
        expect(capture).to include('invalid choice does_this_show 2 (valid: 1..4)')
      end

      it 're-prompts when the line mixes numbers and stray text (regression)' do
        stub_stdin("2 3 4 does_this_show\n", "1 2\n")
        expect(show(dialog)).to eq([:allow, :deny])
        expect(capture).to include('invalid choice 2 3 4 does_this_show (valid: 1..4)')
      end
    end

    describe 'non-multi_select single-pick limit' do
      let(:dialog) { described_class.new(title: 't', options: options) }

      it 're-prompts when two regular options are picked at once' do
        stub_stdin("1 2\n", "1\n")
        expect(show(dialog)).to eq(:allow)
        expect(capture).to include('pick one option only')
      end

      it 're-prompts when cancel is picked alongside an option too' do
        # Cancel counts against the single-pick limit in a non-multi-select
        # dialog (only "Additional details" is reserved): "1 3" re-prompts
        # and must not silently cancel.
        stub_stdin("1 3\n", "1\n")
        expect(show(dialog)).to eq(:allow)
        expect(capture).to include('pick one option only')
      end
    end
  end
end
