# frozen_string_literal: true

require 'ui/editor'
require 'stringio'

RSpec.describe UI::Editor do
  def result_text(r) = r.text
  def result_status(r) = r.status

  describe '#read on a non-tty stream (dumb path)' do
    it 'returns :submitted for a real line' do
      ed = described_class.new(StringIO.new("steer left\n"))
      r = ed.read
      expect(result_status(r)).to eq(:submitted)
      expect(result_text(r)).to eq('steer left')
    end

    it 'returns :empty for a blank line (bare Enter = no action, T3 design)' do
      ed = described_class.new(StringIO.new("\n"))
      expect(result_status(ed.read)).to eq(:empty)

      ed2 = described_class.new(StringIO.new("   \n"))
      expect(result_status(ed2.read)).to eq(:empty)
    end

    it 'returns :eof when the stream is exhausted' do
      ed = described_class.new(StringIO.new)
      expect(result_status(ed.read)).to eq(:eof)
    end

    it 'ignores the prefill on the dumb path (Reline-only feature)' do
      ed = described_class.new(StringIO.new("real line\n"))
      r = ed.read(prefill: 'old draft')
      expect(result_text(r)).to eq('real line')
    end

    it 'ignores a custom prompt on the dumb path (no prompt is printed)' do
      ed = described_class.new(StringIO.new("ok\n"))
      r = ed.read(prompt: '> ')
      expect(result_status(r)).to eq(:submitted)
      expect(result_text(r)).to eq('ok')
    end
  end

  # issue #198 phase 3: the idle prompt's read_multiline on a non-tty stream
  # is a plain one-line read (a pipe has no submit key): backslashes are
  # content, blank line is :empty, exhausted stream is :eof.
  describe '#read_multiline on a non-tty stream' do
    it 'reads one line and keeps backslashes as content' do
      ed = described_class.new(StringIO.new("line with \\\n"))
      r = ed.read_multiline
      expect(result_status(r)).to eq(:submitted)
      expect(result_text(r)).to eq('line with \\')
    end

    it 'returns :empty for a blank line' do
      expect(described_class.new(StringIO.new("\n"))
                    .read_multiline.status).to eq(:empty)
    end

    it 'returns :eof when the stream is exhausted' do
      expect(described_class.new(StringIO.new)
                    .read_multiline.status).to eq(:eof)
    end
  end

  describe 'streams without tty? (pipes)' do
    it 'takes the dumb path (pipes have no tty? method behavior we rely on)' do
      reader, writer = IO.pipe
      begin
        ed = described_class.new(reader)
        expect(ed.send(:tty?)).to be(false)

        writer.puts 'note from a pipe'
        r = ed.read
        expect(result_status(r)).to eq(:submitted)
        expect(result_text(r)).to eq('note from a pipe')
      ensure
        writer.close unless writer.closed?
        reader.close unless reader.closed?
      end
    end
  end

  describe 'install_esc! (idempotent global Reline patch)' do
    it 'installs the LineEditor module once and stays idempotent' do
      described_class.install_esc!
      expect(Reline::LineEditor.ancestors)
        .to include(UI::Editor::RelineEscCancel)

      before = Reline::LineEditor.ancestors.count
      described_class.install_esc!
      expect(Reline::LineEditor.ancestors.count).to eq(before)
    end

    # issue #91: the submit key sequence (Ctrl+Enter / Shift+Enter on
    # Windows, Alt+Enter on most Unix terminals) commits the multiline
    # buffer via Reline's built-in ed_force_submit.
    it 'binds the submit key sequence to :ed_force_submit in emacs mode' do
      described_class.install_esc!
      kb = Reline.core.config.editing_mode
      expect(kb.get(UI::Editor::SUBMIT_KEY_SEQ)).to eq(:ed_force_submit)
      # Plain Enter stays a newline - it never submits at the idle prompt.
      expect(kb.get([13])).to eq(:ed_newline)
    end

    it 'is idempotent for key bindings (no accumulation on re-call)' do
      described_class.install_esc!
      kb = Reline.core.config.editing_mode
      described_class.install_esc!
      expect(kb.get(UI::Editor::SUBMIT_KEY_SEQ)).to eq(:ed_force_submit)
    end

    # issue #198 (remote host via Windows Terminal, ssh / WSL2): CSI
    # Ctrl+Enter ("ESC [ 1 3 ~"), sent for Ctrl+Enter by terminals with an
    # extended keyboard protocol (kitty/kcm), is bound to the submit action.
    it 'binds CSI Ctrl+Enter to :ed_force_submit in emacs mode' do
      described_class.install_esc!
      kb = Reline.core.config.editing_mode
      expect(kb.get(UI::Editor::CSI_CTRL_ENTER_SEQ)).to eq(:ed_force_submit)
    end

    # issue #198 probe finding: on a remote host reached through Windows
    # Terminal (ssh / WSL2) Ctrl+Enter arrives as LF (byte 10) while Enter
    # sends CR - byte 10 is bound to the paste-guarded submit action.
    it 'binds LF (Ctrl+Enter via Windows Terminal) to the guarded submit' do
      described_class.install_esc!
      kb = Reline.core.config.editing_mode
      expect(kb.get([UI::Editor::CTRL_ENTER_LF_BYTE])).to eq(:lf_force_submit)
    end
  end

  # issue #198: the LF (Ctrl+Enter via Windows Terminal) submit action must
  # respect the paste guard - an LF inside pasted text inserts a newline,
  # not a submit.
  describe 'RelineLFSubmit (paste guard for LF byte 10)' do
    class LFFakeEditor
      def initialize(pasting: false)
        @in_pasting = pasting
        @submitted  = false
        @newlined   = false
      end

      attr_reader :submitted, :newlined

      def ed_force_submit(_key); @submitted = true; end
      def key_newline(_key); @newlined = true; end
    end

    after { UI::Editor::RelineEnterPolicy::PasteGuard.clear! }

    def lf_ed(**kw) = LFFakeEditor.new(**kw).extend(UI::Editor::RelineLFSubmit)

    it 'submits a plain LF when not pasting' do
      e = lf_ed
      e.send(:lf_force_submit, nil)
      expect(e.submitted).to be(true)
      expect(e.newlined).to be(false)
    end

    it 'inserts a newline when inside a paste or within the grace window' do
      e = lf_ed(pasting: true)
      e.send(:lf_force_submit, nil)
      expect(e.submitted).to be(false)
      expect(e.newlined).to be(true)

      UI::Editor::RelineEnterPolicy::PasteGuard.mark
      e2 = lf_ed
      e2.send(:lf_force_submit, nil)
      expect(e2.submitted).to be(false)
    end
  end

  # issue #198: the opt-in double-Enter policy (remote host via Windows
  # Terminal where no submit key reaches the pty). The predicate is tested
  # on a fake LineEditor with the module prepended; `ed_newline` falls
  # through to the base implementation when the policy does not match.
  describe 'RelineEnterPolicy (opt-in double-Enter submit)' do
    FakeConfig = Struct.new(:emacs) do
      def editing_mode_is?(mode) = mode == :emacs ? emacs : false
    end

    class FakeEditor
      def initialize(lines: ['hello'], line_index: 0, multiline: true,
                     emacs: true, pasting: false)
        @buffer_of_lines = lines
        @line_index      = line_index
        @is_multiline    = multiline
        @config          = FakeConfig.new(emacs)
        @in_pasting      = pasting
        @finished        = false
        @fell_through    = false
      end

      attr_reader :finished, :fell_through

      def process_insert(force: true); end

      # Reline's base behaviour, stood in for `super`.
      def ed_newline(_key)
        @fell_through = true
      end

      def finish
        @finished = true
      end
    end

    after do
      UI::Editor::RelineEnterPolicy::PasteGuard.clear!
      UI::Editor.submit_on_enter = false
    end

    def ed(**kw) = FakeEditor.new(**kw).extend(UI::Editor::RelineEnterPolicy)

    it 'is off by default: Enter always falls through to Reline' do
      e = ed
      e.send(:ed_newline, nil)
      expect(e.finished).to be(false)
      expect(e.fell_through).to be(true)
    end

    it 'submits when enabled and the cursor is on an EMPTY LAST line' do
      UI::Editor.submit_on_enter = true
      e = ed(lines: ['para one', ''], line_index: 1)
      e.send(:ed_newline, nil)
      expect(e.finished).to be(true)
      expect(e.fell_through).to be(false)
    end

    it 'falls through when the last line has content (Enter = newline)' do
      UI::Editor.submit_on_enter = true
      e = ed(lines: ['para one', 'more'], line_index: 1)
      e.send(:ed_newline, nil)
      expect(e.finished).to be(false)
      expect(e.fell_through).to be(true)
    end

    it 'falls through when the cursor is NOT on the last line' do
      UI::Editor.submit_on_enter = true
      e = ed(lines: ['', '', 'tail'], line_index: 0)
      e.send(:ed_newline, nil)
      expect(e.finished).to be(false)
    end

    it 'falls through for single-line reads and non-emacs modes' do
      UI::Editor.submit_on_enter = true
      a = ed(lines: [''], multiline: false)
      b = ed(lines: [''], emacs: false)
      [a, b].each { |x| x.send(:ed_newline, nil) }
      expect([a, b].map(&:finished)).to eq([false, false])
    end

    # Pasted blank lines must never submit mid-paste (@in_pasting or the
    # grace window right after a pasted key).
    it 'falls through while pasting or just after a paste' do
      UI::Editor.submit_on_enter = true
      e = ed(lines: ['a', ''], line_index: 1, pasting: true)
      e.send(:ed_newline, nil)
      expect(e.finished).to be(false)

      guard = UI::Editor::RelineEnterPolicy::PasteGuard
      guard.mark
      e2 = ed(lines: ['a', ''], line_index: 1)
      e2.send(:ed_newline, nil)
      expect(e2.finished).to be(false)
    end

    it 'is installed on Reline::LineEditor by install_esc!' do
      described_class.install_esc!
      expect(Reline::LineEditor.ancestors)
        .to include(UI::Editor::RelineEnterPolicy)
    end
  end
end
