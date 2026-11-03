# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'stringio'
require 'ui/editor'

RSpec.describe UI::Editor::RelineCtrlGHandoff do
  after { UI::Editor.external_editor = nil }

  it 'is installed on Reline::LineEditor by install_esc!' do
    UI::Editor.install_esc!
    expect(Reline::LineEditor.ancestors)
      .to include(UI::Editor::RelineCtrlGHandoff)
  end

  it 'external_editor= normalizes a blank command to nil (the key stays Reline\'s)' do
    UI::Editor.external_editor = '  '
    expect(UI::Editor.external_editor).to be_nil
    UI::Editor.external_editor = 'nvim -R'
    expect(UI::Editor.external_editor).to eq('nvim -R')
  end

  # Feeds bytes through Reline's own expansion and reports what the patch left
  # behind: whether it fired, and what the buffer became.
  def ctrl_g_feed(bytes, multiline: true)
    UI::Editor.install_esc!
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
    UI::Editor.external_editor = nil
    r = ctrl_g_feed([97, 7]) # 'a' then Ctrl+G
    expect(r[:fired]).to be_falsy
    expect(r[:finished]).to be(false)
    expect(r[:buffer]).to eq("a\a") # byte 7 inserted, as Reline did before
  end

  it 'snapshots the buffer and closes the read when an editor is configured' do
    UI::Editor.external_editor = 'notepad'
    r = ctrl_g_feed([97, 10, 98, 7]) # 'a', Enter (a real newline), 'b', Ctrl+G
    expect(r[:fired]).to be(true)
    expect(r[:text]).to eq("a\nb")
    expect(r[:finished]).to be(true)
  end

  it 'does NOT fire on a single-line read (there is no buffer to edit)' do
    UI::Editor.external_editor = 'notepad'
    r = ctrl_g_feed([97, 7], multiline: false)
    expect(r[:fired]).to be_falsy
    expect(r[:buffer]).to eq("a\a")
  end

  # Editor#ctrl_g_result is the READER side of the hand-off: what a caller
  # actually sees after Ctrl+G. :edited always - never :submitted - so a caller
  # that cannot treat a draft (a dialog's choice loop) cannot mistake nothing
  # for an answer. Runs a real child editor.
  describe 'the :edited result Editor#ctrl_g_result hands back' do
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
        UI::Editor.external_editor = "ruby #{script}"
        ed = UI::Editor.new(StringIO.new)
        r  = ed.send(:ctrl_g_result, "draft text")

        expect(r.status).to eq(:edited)
        expect(r.text).to include('from-editor')
        expect(r.text).to include('draft text')
        expect(r.note).to eq("edited with ruby")
      end
    end

    it 'on a failed editor returns :edited with the buffer intact + an error note' do
      UI::Editor.external_editor = 'definitely-not-a-program-xyz'
      ed = UI::Editor.new(StringIO.new)
      r  = ed.send(:ctrl_g_result, 'my draft')

      expect(r.status).to eq(:edited)
      expect(r.text).to eq('my draft')
      expect(r.note).to include('could not run')
    end
  end
end
