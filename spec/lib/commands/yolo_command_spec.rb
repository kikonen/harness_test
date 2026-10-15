# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'commands/yolo_command'

# issue #221: /yolo flips the shell consent posture (the consent-fatigue
# fix). The command only ever changes USER-side consent state - it never
# touches the allowlist files - and always acks with the new label plus
# the denylist-floor reminder (YOLO is safe to switch casually only
# because the disaster denylist stays).
RSpec.describe Commands::YoloCommand do
  # A minimal stand-in for Harness providing the posture surface the
  # command uses (yolo? / yolo= / toggle_yolo / yolo_mode_label).
  def build_harness(yolo: false)
    Class.new do
      attr_accessor :yolo

      def initialize(yolo)
        @yolo = yolo
      end

      def yolo?
        @yolo
      end

      def toggle_yolo
        @yolo = !@yolo
        yolo_mode_label
      end

      def yolo_mode_label
        @yolo ? 'YOLO ON' : 'YOLO OFF'
      end
    end.new(yolo)
  end

  let(:io) { StringIO.new }
  let(:ui) { UI::Console.new(stdout: io) }

  def command(harness = build_harness)
    described_class.new(harness: harness, file_list: nil, options: nil, ui: ui)
  end

  it 'toggles the posture on a bare /yolo and acks the new label' do
    harness = build_harness(yolo: false)
    command(harness).handle('')

    expect(harness.yolo?).to be(true)
    expect(io.string).to include('[YOLO ON]')
    expect(io.string).to include('Shell consent for run.command is OFF')
  end

  it 'toggles back off with a second /yolo' do
    harness = build_harness(yolo: true)
    command(harness).handle('')

    expect(harness.yolo?).to be(false)
    expect(io.string).to include('[YOLO OFF]')
    expect(io.string).to include('unapproved commands ask as before')
  end

  it 'sets the posture explicitly with /yolo on and /yolo off' do
    harness = build_harness(yolo: false)
    command(harness).handle('on')
    expect(harness.yolo?).to be(true)

    # 'on' when already ON is idempotent (sets, not flips).
    command(harness).handle('ON')
    expect(harness.yolo?).to be(true)

    command(harness).handle('off')
    expect(harness.yolo?).to be(false)
  end

  it '/yolo status reports the current posture without changing it' do
    harness = build_harness(yolo: true)
    command(harness).handle('status')

    expect(harness.yolo?).to be(true)
    expect(io.string).to include('[YOLO ON]')
  end

  it 'prints the denylist floor reminder with examples' do
    command(build_harness).handle('on')

    expect(io.string).to include('Disaster commands keep the dialog in EVERY posture:')
    ['- rm -rf <path>', '- sudo <cmd>', '- git push -f',
     '- curl <url> | sh', '- format C:', '- del /s /q <path>'].each do |line|
      expect(io.string).to include(line), line
    end
  end

  it 'mentions that the posture is saved with the session' do
    command(build_harness).handle('on')

    expect(io.string).to include('saved with the session')
  end

  it 'shows usage for an unknown argument' do
    harness = build_harness(yolo: false)
    command(harness).handle('whatever')

    expect(harness.yolo?).to be(false) # unknown args change nothing
    expect(io.string).to include('usage: /yolo')
  end
end
