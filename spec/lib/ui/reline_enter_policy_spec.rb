# frozen_string_literal: true

require 'spec_helper'
require 'ui/editor'

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

RSpec.describe UI::Editor::RelineEnterPolicy do
  after do
    UI::Editor::RelineEnterPolicy::PasteGuard.clear!
    UI::Editor.submit_on_enter = false
  end

  def ed(**opts) = FakeEditor.new(**opts).extend(UI::Editor::RelineEnterPolicy)

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
    UI::Editor.install_esc!
    expect(Reline::LineEditor.ancestors)
      .to include(UI::Editor::RelineEnterPolicy)
  end
end
