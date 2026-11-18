# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'commands/stream_command'
require 'system_settings'

# issue #28: /stream flips the streaming posture. Like /yolo it changes
# USER-side harness state only (the model cannot turn it on), acks with the
# new label, and states the cost it carries - a streamed request loses the
# full retry policy once part of the answer has been shown.
RSpec.describe Commands::StreamCommand do
  # The command talks to SystemSettings directly (#286): use the real one.
  def build_settings(stream: false)
    SystemSettings.new(stream: stream)
  end

  let(:io) { StringIO.new }
  let(:ui) { UI::Console.new(stdout: io) }

  def command(settings = build_settings)
    described_class.new(settings: settings, file_list: nil, ui: ui)
  end

  it 'toggles the posture on a bare /stream and acks the new label' do
    settings = build_settings
    command(settings).handle('')

    expect(settings.stream?).to be(true)
    expect(io.string).to include('[STREAM]')
    expect(io.string).to include('spinner shows the answer as it arrives')
  end

  it 'toggles back off with a second /stream' do
    settings = build_settings(stream: true)
    command(settings).handle('')

    expect(settings.stream?).to be(false)
    # Off is the default, so the ack names the buffered state, not a badge.
    expect(io.string).to include('[BUFFERED]')
    expect(io.string).to include('whole answer arrives before it is printed')
  end

  it 'turns it on explicitly with /stream on' do
    settings = build_settings
    command(settings).handle('on')

    expect(settings.stream?).to be(true)
    expect(io.string).to include('[STREAM]')
  end

  it 'turns it off explicitly with /stream off' do
    settings = build_settings(stream: true)
    command(settings).handle('off')

    expect(settings.stream?).to be(false)
  end

  it 'reports the current posture with /stream status without changing it' do
    settings = build_settings(stream: true)
    command(settings).handle('status')

    expect(settings.stream?).to be(true)
    expect(io.string).to include('[STREAM]')
  end

  # The trade-off is the point of the command's text: streaming is not free.
  it 'states the retry boundary the posture costs' do
    command(build_settings).handle('on')

    expect(io.string).to include('retried only until the first part arrives')
  end

  it 'says the posture is saved with the session' do
    command(build_settings).handle('on')

    expect(io.string).to include('Saved with the session')
  end

  it 'shows usage for an unknown argument and changes nothing' do
    settings = build_settings
    command(settings).handle('sideways')

    expect(settings.stream?).to be(false)
    expect(io.string).to include('usage: /stream')
  end
end
