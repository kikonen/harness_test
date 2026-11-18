# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'commands/yolo_command'
require 'system_settings'

# issue #221: /yolo flips the shell consent posture (the consent-fatigue
# fix). The command only ever changes USER-side consent state - it never
# touches the allowlist files - and always acks with the new label plus
# the denylist-floor reminder (YOLO is safe to switch casually only
# because the disaster denylist stays).
RSpec.describe Commands::YoloCommand do
  # The command talks to SystemSettings directly (#286): use the real one.
  def build_settings(yolo: false)
    SystemSettings.new(yolo: yolo)
  end

  let(:io) { StringIO.new }
  let(:ui) { UI::Console.new(stdout: io) }

  def command(settings = build_settings)
    described_class.new(settings: settings, file_list: nil, ui: ui)
  end

  it 'toggles the posture on a bare /yolo and acks the new label' do
    settings = build_settings(yolo: false)
    command(settings).handle('')

    expect(settings.yolo?).to be(true)
    expect(io.string).to include('[YOLO ON]')
    expect(io.string).to include('Shell consent for run.command is OFF')
  end

  it 'toggles back off with a second /yolo' do
    settings = build_settings(yolo: true)
    command(settings).handle('')

    expect(settings.yolo?).to be(false)
    expect(io.string).to include('[YOLO OFF]')
    expect(io.string).to include('unapproved commands ask as before')
  end

  it 'sets the posture explicitly with /yolo on and /yolo off' do
    settings = build_settings(yolo: false)
    command(settings).handle('on')
    expect(settings.yolo?).to be(true)

    # 'on' when already ON is idempotent (sets, not flips).
    command(settings).handle('ON')
    expect(settings.yolo?).to be(true)

    command(settings).handle('off')
    expect(settings.yolo?).to be(false)
  end

  it '/yolo status reports the current posture without changing it' do
    settings = build_settings(yolo: true)
    command(settings).handle('status')

    expect(settings.yolo?).to be(true)
    expect(io.string).to include('[YOLO ON]')
  end

  it 'prints the denylist floor reminder with examples' do
    command(build_settings).handle('on')

    # The block is a :bullet structure: the title at level 0, the examples at
    # level 1, the dash the renderer's layout rather than the emitter's string.
    expect(io.string).to include(
      "Disaster commands keep the dialog in EVERY posture:\n" \
      "  - rm -rf <path>\n  - sudo <cmd>\n  - git push -f\n  - curl <url> | sh\n" \
      "  - format C:\n  - del /s /q <path>\n  - dd of=/dev/...\n" \
      "  - Remove-Item -Recurse -Force <path>"
    )
  end

  it 'mentions that the posture is saved with the session' do
    command(build_settings).handle('on')

    expect(io.string).to include('saved with the session')
  end

  it 'shows usage for an unknown argument' do
    settings = build_settings(yolo: false)
    command(settings).handle('whatever')

    expect(settings.yolo?).to be(false) # unknown args change nothing
    expect(io.string).to include('usage: /yolo')
  end
end
