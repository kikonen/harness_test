# frozen_string_literal: true

require 'spec_helper'
require 'ui/editor'
require 'task'

class CtrlAFakeEditor
  def initialize(harness: nil)
    @harness  = harness
    @finished = false
  end

  attr_reader :finished

  def finish
    @finished = true
  end

  # Reline's base key handler, stood in so `super` (non-matching keys)
  # falls through cleanly.
  def input_key(_key); end

  # Reline hands a control key's char to #input_key as a one-character
  # String (issue #236), so these examples feed the real shape rather than
  # an Integer. Ctrl+A is "\u0001"; a plain 'a' is "a".
  def self.key(char) = Struct.new(:char).new(char)
end

RSpec.describe UI::RelinePatch::CtrlAToggle do
  after { UI::RelinePatch::CtrlAToggle.reset! }

  def ctrl_a_ed(harness: nil) = CtrlAFakeEditor.new(harness: harness)

  it 'is installed on Reline::LineEditor by install_reline_patches!' do
    UI::Editor.install_reline_patches!
    expect(Reline::LineEditor.ancestors)
      .to include(UI::RelinePatch::CtrlAToggle)
  end

  # run_mode_toggle reads the harness off the ACTIVE task (Thread current),
  # so these examples park a task with a fake harness for the keypress.
  def with_active_harness(harness)
    task = Task.new { nil }
    task.harness = harness
    old = Thread.current[:harness_task]
    Thread.current[:harness_task] = task
    begin
      yield
    ensure
      Thread.current[:harness_task] = old
    end
  end

  it 'fires CtrlAToggle with the new label and closes the read on Ctrl+A (String shape)' do
    harness = double('harness', toggle_command_mode: 'AUTO-APPROVE')
    e = ctrl_a_ed
    e.extend(UI::RelinePatch::CtrlAToggle)

    with_active_harness(harness) do
      e.input_key(CtrlAFakeEditor.key("\u0001"))
    end

    expect(UI::RelinePatch::CtrlAToggle.fired).to be(true)
    expect(UI::RelinePatch::CtrlAToggle.label).to eq('AUTO-APPROVE')
    expect(e.finished).to be(true)
  end

  it 'does NOT fire for a plain "a" (String "a")' do
    harness = double('harness', toggle_command_mode: 'AUTO-APPROVE')
    e = ctrl_a_ed
    e.extend(UI::RelinePatch::CtrlAToggle)

    with_active_harness(harness) do
      e.input_key(CtrlAFakeEditor.key("a"))
    end

    expect(UI::RelinePatch::CtrlAToggle.fired).to be_falsy
  end

  # A pasted block arrives as a String longer than one character whose first
  # byte may happen to be Ctrl+A's byte; it must not be mistaken for the key.
  it 'does NOT fire for a multi-character pasted String starting with the Ctrl+A byte' do
    harness = double('harness', toggle_command_mode: 'AUTO-APPROVE')
    e = ctrl_a_ed
    e.extend(UI::RelinePatch::CtrlAToggle)

    with_active_harness(harness) do
      e.input_key(CtrlAFakeEditor.key("\u0001abc"))
    end

    expect(UI::RelinePatch::CtrlAToggle.fired).to be_falsy
  end

  it 'fires with a nil label when no active harness exists' do
    e = ctrl_a_ed
    e.extend(UI::RelinePatch::CtrlAToggle)

    e.input_key(CtrlAFakeEditor.key("\u0001")) # no task/harness -> nil toggle

    expect(UI::RelinePatch::CtrlAToggle.fired).to be(true)
    expect(UI::RelinePatch::CtrlAToggle.label).to be_nil
    expect(e.finished).to be(true)
  end

  it 'CtrlAToggle.reset! clears the fired flag and label' do
    UI::RelinePatch::CtrlAToggle.fire!('MANUAL')
    UI::RelinePatch::CtrlAToggle.reset!
    expect(UI::RelinePatch::CtrlAToggle.fired).to be(false)
    expect(UI::RelinePatch::CtrlAToggle.label).to be_nil
  end

  # Regression guard for #236: a control key reaches #input_key through
  # Reline's OWN KeyStroke.expand as the one-character String "\u0001", not
  # an Integer. Driving the real path means an Integer-only comparison can no
  # longer pass a spec while breaking the terminal.
  def ctrl_a_feed(bytes)
    UI::Editor.install_reline_patches!
    cfg = Reline::Config.new
    ks  = Reline::KeyStroke.new(cfg, Encoding::UTF_8)
    le  = Reline::LineEditor.new(cfg)
    le.reset_variables('p> ')
    le.multiline_on
    le.confirm_multiline_termination_proc = ->(_buf) { false }
    bytes.each { |b| ks.expand([b]).first.each { |k| le.input_key(k) } }
    { fired: UI::RelinePatch::CtrlAToggle.fired,
      label: UI::RelinePatch::CtrlAToggle.label,
      finished: le.finished?, buffer: le.whole_buffer }
  ensure
    UI::RelinePatch::CtrlAToggle.reset!
  end

  it 'fires on the real Reline path (KeyStroke.expand -> input_key)' do
    harness = double('harness', toggle_command_mode: 'MANUAL')
    with_active_harness(harness) do
      r = ctrl_a_feed([1]) # Ctrl+A byte
      expect(r[:fired]).to be(true)
      expect(r[:label]).to eq('MANUAL')
      expect(r[:finished]).to be(true)
    end
  end

  it 'does NOT fire on the real Reline path for a plain "a" (byte 97)' do
    harness = double('harness', toggle_command_mode: 'MANUAL')
    with_active_harness(harness) do
      r = ctrl_a_feed([97])
      expect(r[:fired]).to be_falsy
      expect(r[:finished]).to be(false)
      expect(r[:buffer]).to eq('a')
    end
  end
end
