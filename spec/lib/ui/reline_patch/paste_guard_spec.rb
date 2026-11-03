# frozen_string_literal: true

require 'spec_helper'
require 'ui/reline_patch/paste_guard'

RSpec.describe UI::RelinePatch::PasteGuard do
  after { described_class.clear! }

  it 'is not recent before any paste has been marked' do
    expect(described_class.recent?).to be(false)
  end

  it 'is recent right after mark' do
    described_class.mark
    expect(described_class.recent?).to be(true)
  end

  it 'is no longer recent once the grace window has passed' do
    described_class.mark
    # Push the recorded timestamp back past the window instead of sleeping.
    described_class.instance_variable_set(
      :@last_seen,
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - (described_class::GRACE + 1)
    )
    expect(described_class.recent?).to be(false)
  end

  it 'clear! forgets the paste' do
    described_class.mark
    described_class.clear!
    expect(described_class.recent?).to be(false)
  end
end
