# frozen_string_literal: true

require 'ui/editor'
require 'task'
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

  # issue #224 follow-up: Ctrl+A toggles the command consent MODE. The
  # patch is prepended on the LineEditor like Esc-cancel; the fired
  # state is parked on CtrlAState for the reader to hand back.
  describe 'RelineCtrlAToggle (Ctrl+A consent-mode toggle)' do
    after { UI::Editor::CtrlAState.reset! }

    class CtrlAFakeEditor
      def initialize(harness: nil)
        @harness  = harness
        @finished = false
      end

      attr_reader :finished

      def finish
        @finished = true
      end

      # Reline's base key handler, stood in so `super` (non-matching
      # keys) falls through cleanly.
      def input_key(_key); end

      # The key the patch tests for (char == 1 = Ctrl+A, 97 = plain 'a').
      def self.key(char) = Struct.new(:char).new(char)
    end

    def ctrl_a_ed(harness: nil) = CtrlAFakeEditor.new(harness: harness)

    it 'is installed on Reline::LineEditor by install_esc!' do
      described_class.install_esc!
      expect(Reline::LineEditor.ancestors)
        .to include(UI::Editor::RelineCtrlAToggle)
    end

    # run_mode_toggle reads the harness off the ACTIVE task (Thread
    # current), so these examples park a task with a fake harness for the
    # duration of the keypress.
    def with_active_harness(harness, &block)
      task = Task.new { }
      task.harness = harness
      old = Thread.current[:harness_task]
      Thread.current[:harness_task] = task
      begin
        block.call
      ensure
        Thread.current[:harness_task] = old
      end
    end

    it 'fires CtrlAState with the new label and closes the read on Ctrl+A' do
      harness = double('harness', toggle_command_mode: 'AUTO-APPROVE')
      e = ctrl_a_ed
      e.extend(UI::Editor::RelineCtrlAToggle)

      with_active_harness(harness) do
        e.input_key(CtrlAFakeEditor.key(1))
      end

      expect(UI::Editor::CtrlAState.fired).to be(true)
      expect(UI::Editor::CtrlAState.label).to eq('AUTO-APPROVE')
      expect(e.finished).to be(true)
    end

    it 'does NOT fire for a plain "a" (char 97)' do
      harness = double('harness', toggle_command_mode: 'AUTO-APPROVE')
      e = ctrl_a_ed
      e.extend(UI::Editor::RelineCtrlAToggle)

      with_active_harness(harness) do
        e.input_key(CtrlAFakeEditor.key(97))
      end

      expect(UI::Editor::CtrlAState.fired).to be_falsy
    end

    it 'fires with a nil label when no active harness exists' do
      e = ctrl_a_ed
      e.extend(UI::Editor::RelineCtrlAToggle)

      e.input_key(CtrlAFakeEditor.key(1)) # no task/harness -> nil toggle

      expect(UI::Editor::CtrlAState.fired).to be(true)
      expect(UI::Editor::CtrlAState.label).to be_nil
      expect(e.finished).to be(true)
    end

    it 'CtrlAState.reset! clears the fired flag and label' do
      UI::Editor::CtrlAState.fire!('MANUAL')
      UI::Editor::CtrlAState.reset!
      expect(UI::Editor::CtrlAState.fired).to be(false)
      expect(UI::Editor::CtrlAState.label).to be_nil
    end
  end

  # issue #298: Ctrl+G hands the buffer being edited to an external editor.
  # These run the REAL Reline read path (KeyStroke.expand -> input_key), because
  # the fact being pinned is what Reline hands to #input_key: a control key's
  # char is the one-character String "\a", not the Integer 7. A fake Key struct
  # is exactly what hides that (see the Ctrl+A examples, which fake char as 1).
  describe 'RelineCtrlGHandoff (Ctrl+G -> external editor, issue #298)' do
    after { described_class.external_editor = nil }

    it 'is installed on Reline::LineEditor by install_esc!' do
      described_class.install_esc!
      expect(Reline::LineEditor.ancestors)
        .to include(UI::Editor::RelineCtrlGHandoff)
    end

    it 'external_editor= normalizes a blank command to nil (the key stays Reline\'s)' do
      described_class.external_editor = '  '
      expect(described_class.external_editor).to be_nil
      described_class.external_editor = 'nvim -R'
      expect(described_class.external_editor).to eq('nvim -R')
    end

    # Feeds bytes through Reline's own expansion and reports what the patch left
    # behind: whether it fired, and what the buffer became.
    def ctrl_g_feed(bytes, multiline: true)
      described_class.install_esc!
      cfg = Reline::Config.new
      ks  = Reline::KeyStroke.new(cfg, Encoding::UTF_8)
      le  = Reline::LineEditor.new(cfg)
      le.reset_variables('p> ')
      if multiline
        le.multiline_on
        le.confirm_multiline_termination_proc = ->(_buf) { false }
      end
      bytes.each { |b| ks.expand([b]).first.each { |k| le.input_key(k) } }
      { fired: UI::Editor::CtrlGState.fired, text: UI::Editor::CtrlGState.text,
        finished: le.finished?, buffer: le.whole_buffer }
    ensure
      UI::Editor::CtrlGState.reset!
    end

    it 'does NOT take the key when no editor is configured (Reline keeps it)' do
      described_class.external_editor = nil
      r = ctrl_g_feed([97, 7]) # 'a' then Ctrl+G
      expect(r[:fired]).to be_falsy
      expect(r[:finished]).to be(false)
      expect(r[:buffer]).to eq("a\a") # byte 7 inserted, as Reline did before
    end

    it 'snapshots the buffer and closes the read when an editor is configured' do
      described_class.external_editor = 'notepad'
      r = ctrl_g_feed([97, 10, 98, 7]) # 'a', Enter (a real newline), 'b', Ctrl+G
      expect(r[:fired]).to be(true)
      expect(r[:text]).to eq("a\nb")
      expect(r[:finished]).to be(true)
    end

    it 'does NOT fire on a single-line read (there is no buffer to edit)' do
      described_class.external_editor = 'notepad'
      r = ctrl_g_feed([97, 7], multiline: false)
      expect(r[:fired]).to be_falsy
      expect(r[:buffer]).to eq("a\a")
    end

    # The reader's ctrl_g_result (private) is what a caller actually sees after
    # Ctrl+G: an :edited result whose text is the editor's output and whose note
    # names the editor. This is the exact shape PromptReader#read, Task.poll_for_note
    # and UI::Dialog#collect_details each branch on. Runs a real child editor.
    describe 'the :edited result a Ctrl+G hand-off hands back' do
      def fake_editor_script(dir)
        script = File.join(dir, 'ed.rb')
        File.write(script, <<~RUBY)
          path = ARGV.last
          before = File.binread(path)
          File.binwrite(path, "from-editor:\\n\#{before}")
        RUBY
        script
      end

      it 'returns :edited with the editor text and a note naming the editor' do
        Dir.mktmpdir do |dir|
          script = fake_editor_script(dir)
          described_class.external_editor = "ruby #{script}"
          ed = described_class.new(StringIO.new)
          r  = ed.send(:ctrl_g_result, "draft text")

          expect(r.status).to eq(:edited)
          expect(r.text).to include('from-editor')
          expect(r.text).to include('draft text')
          expect(r.note).to eq("edited with ruby")
        end
      end

      it 'on a failed editor returns :edited with the buffer intact + an error note' do
        described_class.external_editor = 'definitely-not-a-program-xyz'
        ed = described_class.new(StringIO.new)
        r  = ed.send(:ctrl_g_result, 'my draft')

        expect(r.status).to eq(:edited)
        expect(r.text).to eq('my draft')
        expect(r.note).to include('could not run')
      end
    end
  end
end
