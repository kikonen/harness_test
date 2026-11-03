# frozen_string_literal: true

require 'spec_helper'
require 'ui/editor'

RSpec.describe UI::RelinePatch::EscCancel do
  after { UI::RelinePatch::EscState.esc_pending = false }

  it 'is installed on Reline::LineEditor by install_reline_patches!' do
    UI::Editor.install_reline_patches!
    expect(Reline::LineEditor.ancestors)
      .to include(UI::RelinePatch::EscCancel)
  end

  # Feeds bytes through Reline's own expansion, like the Ctrl+A/Ctrl+G specs do,
  # and reports what the patch left behind.
  def esc_feed(bytes, pending: false)
    UI::Editor.install_reline_patches!
    cfg = Reline::Config.new
    ks  = Reline::KeyStroke.new(cfg, Encoding::UTF_8)
    le  = Reline::LineEditor.new(cfg)
    le.reset_variables('p> ')
    le.multiline_on
    le.confirm_multiline_termination_proc = ->(_buf) { false }
    UI::RelinePatch::EscState.esc_pending = pending
    bytes.each { |b| ks.expand([b]).first.each { |k| le.input_key(k) } }
    { cancelled: le.cancelled?, finished: le.finished?, buffer: le.whole_buffer,
      pending: UI::RelinePatch::EscState.esc_pending }
  end

  # The marker byte stands in for what the Windows hook injects on a bare Esc.
  it 'marks the read cancelled on the marker byte, buffer kept for prefill' do
    # 'keep me' typed first, then the marker (29 = EscState::ESC_MARKER.ord).
    r = esc_feed([107, 101, 101, 112, 32, 109, 101, 29], pending: true)
    expect(r[:cancelled]).to be(true)
    expect(r[:finished]).to be(true)
    # The whole point: an Esc'd buffer is NOT discarded, it survives as a draft.
    expect(r[:buffer]).to eq('keep me')
    # The pending flag is consumed by the one read that used it.
    expect(r[:pending]).to be(false)
  end

  it 'leaves an ordinary key to Reline (no cancel, buffer keeps the char)' do
    r = esc_feed([97])
    expect(r[:cancelled]).to be(false)
    expect(r[:finished]).to be(false)
    expect(r[:buffer]).to eq('a')
  end
end
