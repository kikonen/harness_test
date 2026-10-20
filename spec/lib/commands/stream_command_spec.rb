# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'commands/stream_command'

# issue #28: /stream flips the streaming posture. Like /yolo it changes
# USER-side harness state only (the model cannot turn it on), acks with the
# new label, and states the cost it carries - a streamed request loses the
# full retry policy once part of the answer has been shown.
RSpec.describe Commands::StreamCommand do
  # Stand-in for Harness exposing the posture surface the command uses.
  def build_harness(stream: false)
    Class.new do
      attr_accessor :stream

      def initialize(stream)
        @stream = stream
      end

      def stream?
        @stream
      end

      def toggle_stream
        @stream = !@stream
        stream_mode_label
      end

      def stream_mode_label
        @stream ? 'STREAM' : nil
      end
    end.new(stream)
  end

  let(:io) { StringIO.new }
  let(:ui) { UI::Console.new(stdout: io) }

  def command(harness = build_harness)
    described_class.new(harness: harness, file_list: nil, options: nil, ui: ui)
  end

  it 'toggles the posture on a bare /stream and acks the new label' do
    harness = build_harness
    command(harness).handle('')

    expect(harness.stream?).to be(true)
    expect(io.string).to include('[STREAM]')
    expect(io.string).to include('spinner shows the answer as it arrives')
  end

  it 'toggles back off with a second /stream' do
    harness = build_harness(stream: true)
    command(harness).handle('')

    expect(harness.stream?).to be(false)
    # Off is the default, so the ack names the buffered state, not a badge.
    expect(io.string).to include('[BUFFERED]')
    expect(io.string).to include('whole answer arrives before it is printed')
  end

  it 'turns it on explicitly with /stream on' do
    harness = build_harness
    command(harness).handle('on')

    expect(harness.stream?).to be(true)
    expect(io.string).to include('[STREAM]')
  end

  it 'turns it off explicitly with /stream off' do
    harness = build_harness(stream: true)
    command(harness).handle('off')

    expect(harness.stream?).to be(false)
  end

  it 'reports the current posture with /stream status without changing it' do
    harness = build_harness(stream: true)
    command(harness).handle('status')

    expect(harness.stream?).to be(true)
    expect(io.string).to include('[STREAM]')
  end

  # The trade-off is the point of the command's text: streaming is not free.
  it 'states the retry boundary the posture costs' do
    command(build_harness).handle('on')

    expect(io.string).to include('retried only until the first part arrives')
  end

  it 'says the posture is saved with the session' do
    command(build_harness).handle('on')

    expect(io.string).to include('Saved with the session')
  end

  it 'shows usage for an unknown argument and changes nothing' do
    harness = build_harness
    command(harness).handle('sideways')

    expect(harness.stream?).to be(false)
    expect(io.string).to include('usage: /stream')
  end
end
