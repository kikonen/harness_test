# frozen_string_literal: true

require 'spec_helper'
require 'ui/editor'

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

RSpec.describe UI::RelinePatch::LFSubmit do
  after { UI::RelinePatch::PasteGuard.clear! }

  def lf_ed(**opts) = LFFakeEditor.new(**opts).extend(UI::RelinePatch::LFSubmit)

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

    UI::RelinePatch::PasteGuard.mark
    e2 = lf_ed
    e2.send(:lf_force_submit, nil)
    expect(e2.submitted).to be(false)
  end
end
