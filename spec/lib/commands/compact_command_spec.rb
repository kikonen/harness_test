# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'commands/compact_command'

# issue #70: /compact must report the resulting context size so the user can
# verify that compaction freed space without burning tokens on a follow-up.
#
# issue #253: the summary is an LLM round, so it must run on a Task thread
# (the single-thread I/O rule, issue #40). Output lines are emitted through
# the task event queue (TaskRunner#emit_line), not written to a stream from
# the task thread. Specs stub Task.run and execute the block synchronously,
# so the block sees no active Task and emit_line writes to the console.
RSpec.describe Commands::CompactCommand do
  let(:session) { Session.new('system prompt') }
  let(:result) do
    {
      summary: 'summary text',
      before: 10,
      after: 4,
      retained: 2,
      context_before: '🧠 ctx ~62100/65536 (95%)',
      context_line: '🧠 ctx ~523/65536 (1%)'
    }
  end
  let(:manager) { double('session_manager', compact_session: result) }

  # A minimal stand-in for Harness providing only what the command uses.
  def build_harness
    Class.new do
      attr_accessor :session, :session_manager

      def initialize(session, manager)
        @session         = session
        @session_manager = manager
      end
    end.new(session, manager)
  end

  let(:harness) { build_harness }
  let(:io) { StringIO.new }
  let(:ui) { UI::Console.new(stdout: io) }

  def command
    described_class.new(harness:, file_list: nil, options: nil, ui:)
  end

  # Stub Task.run to capture the block it is handed and execute it
  # synchronously. The spec does not need a real task thread - only the
  # protocol contract: the block must perform the compaction.
  def run_with_captured_block
    block = nil
    allow(Task).to receive(:run) do |harness:, ui:, &blk|
      block = blk
      blk.call(nil)
      [nil, nil]
    end
    command.handle('')
    block
  end

  def run_command
    run_with_captured_block
    io.string
  end

  it 'runs the compaction inside a Task (I/O routed through the drain loop)' do
    block = run_with_captured_block

    expect(block).to be_a(Proc)
    expect(manager).to have_received(:compact_session)
  end

  it 'prints the resulting context size after compaction' do
    out = run_command

    expect(out).to match(
      /Session compacted: 10 messages -> 4 messages \(2 recent retained\)\.\n  🧠 ctx ~62100\/65536 \(95%\) -> 🧠 ctx ~523\/65536 \(1%\)\n\nSummary:\nsummary text\n/
    )
  end

  it 'omits the context line when before or after is missing' do
    result[:context_before] = nil

    expect(run_command).not_to match(/🧠 ctx/)

    result[:context_before] = '🧠 ctx ~62100/65536 (95%)'
    result[:context_line]   = nil

    expect(run_command).not_to match(/🧠 ctx/)
  end

  it 'reports a task error as a [task error] line' do
    allow(Task).to receive(:run) { |harness:, ui:, &blk| ['boom', nil] }

    command.handle('')

    expect(io.string).to include('[task error] boom')
  end

  it 'emits lines as task events instead of writing to the stream' do
    events = []
    fake_task = Class.new do
      define_method(:push_event) do |type:, origin: nil, content: nil|
        events << { type: type, origin: origin, content: content }
      end
    end.new

    allow(Task).to receive(:run) do |harness:, ui:, &blk|
      allow(Task).to receive(:current).and_return(fake_task)
      blk.call(nil)
      [nil, nil]
    end

    command.handle('')

    # Nothing reached the console directly: every line is an event.
    expect(io.string).to eq("\n\n")
    expect(events.map { |e| e[:content] }).to eq([
      'Session compacted: 10 messages -> 4 messages (2 recent retained).',
      '  🧠 ctx ~62100/65536 (95%) -> 🧠 ctx ~523/65536 (1%)',
      '',
      'Summary:',
      'summary text',
      ''
    ])
    expect(events).to all(include(type: :text))
  end
end
