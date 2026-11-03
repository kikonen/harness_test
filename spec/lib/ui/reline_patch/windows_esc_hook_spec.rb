# frozen_string_literal: true

require 'spec_helper'
require 'ui/editor'

# The Windows IOGate itself is a Windows-only code path; the hook only runs
# when Reline::IOGate.is_a?(Reline::Windows), which no test can stage on a
# Unix host. What this fake pins is the hook's own logic: translate the
# FIRST bare-Esc press to the marker byte, guard the auto-repeat window, and
# leave every other key to super.
class FakeIOGate
  def initialize
    @output_buf   = []
    @last_esc_at  = nil
    @super_called = false
  end

  attr_reader :output_buf, :super_called

  def process_key_event(*_args)
    @super_called = true
  end
end

RSpec.describe UI::RelinePatch::WindowsEscHook do
  def hook
    FakeIOGate.new.extend(described_class)
  end

  it 'is installed on Reline::Windows only on the Windows IOGate (skipped elsewhere)' do
    UI::Editor.install_reline_patches!
    on_windows = defined?(Reline::Windows) && Reline::IOGate.is_a?(Reline::Windows)
    if on_windows
      expect(Reline::Windows.ancestors).to include(described_class)
    elsif defined?(Reline::Windows)
      expect(Reline::Windows.ancestors).not_to include(described_class)
    end
  end

  it 'pushes the marker byte on a bare Esc with no modifiers' do
    UI::RelinePatch::EscState.esc_pending = false
    e = hook
    e.process_key_event(false, described_class::VK_ESCAPE, 0, 0, 0)
    expect(UI::RelinePatch::EscState.esc_pending).to be(true)
    expect(e.output_buf).to eq([UI::RelinePatch::EscState::ESC_MARKER.ord])
    expect(e.super_called).to be(false)
  end

  it 'ignores a modifier-prefixed Esc (Ctrl/Alt/Shift+Esc stays Reline\'s)' do
    UI::RelinePatch::EscState.esc_pending = false
    e = hook
    e.process_key_event(false, described_class::VK_ESCAPE, 0, 0, described_class::MODIFIERS)
    expect(UI::RelinePatch::EscState.esc_pending).to be(false)
    expect(e.output_buf).to be_empty
    expect(e.super_called).to be(true)
  end

  # Held keys auto-repeat faster than the REPEAT_WINDOW; only the first press
  # in a window is a "cancel". Otherwise every tick would inject the marker.
  it 'drops a rapid repeat inside REPEAT_WINDOW' do
    UI::RelinePatch::EscState.esc_pending = false
    e = hook
    vk = described_class::VK_ESCAPE
    e.process_key_event(false, vk, 0, 0, 0) # first press
    expect(e.output_buf).to eq([UI::RelinePatch::EscState::ESC_MARKER.ord])

    # Second press within the window must NOT push a second marker.
    e.process_key_event(true, vk, 0, 0, 0)
    expect(e.output_buf.size).to eq(1)
  end
end
