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

    # issue #198 (remote host via Windows Terminal, ssh / WSL2): neither
    # Alt+Enter nor a default Ctrl+Enter encoding reaches the remote pty, so
    # CSI Ctrl+Enter ("ESC [ 1 3 ~", sent by terminals with the kitty/kcm
    # extended keyboard protocol) is bound to the same submit action.
    it 'binds CSI Ctrl+Enter to :ed_force_submit in emacs mode' do
      described_class.install_esc!
      kb = Reline.core.config.editing_mode
      expect(kb.get(UI::Editor::CSI_CTRL_ENTER_SEQ)).to eq(:ed_force_submit)
    end
  end
end
