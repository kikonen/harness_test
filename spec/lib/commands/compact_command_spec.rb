# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'job_registry'
require 'commands/compact_command'

# issue #70: /compact must report the resulting context size so the user can
# verify that compaction freed space without burning tokens on a follow-up.
#
# issue #253: the summary is an LLM round, so it must run on a Task thread
# (the single-thread I/O rule, issue #40). Output lines are emitted through
# the task event queue (TaskRunner#emit_line), not written to a stream from
# the task thread. The command reaches the Harness through the foreground
# job's harness (#286), so the spec carries the harness on a real registry's
# main job; the round itself is run by a stubbed registry.run (the executor)
# that executes the block synchronously.
RSpec.describe Commands::CompactCommand do
  let(:session) { Session.new('system prompt', file_cache: SessionFileCache.new) }
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

  # A real registry whose main job carries the harness (#286): the command reads
  # the harness through registry.foreground_job.harness.
  def registry_with_harness
    JobRegistry.new.tap { |r| r.add_job(kind: :main, harness:) }
  end

  def command
    described_class.new(registry: registry_with_harness, file_list: nil, ui:)
  end

  # Stub the registry executor to capture the block it is handed and execute it
  # synchronously. The spec does not need a real task thread - only the protocol
  # contract: the block must perform the compaction.
  def stub_run(cmd, error: nil, result_value: nil)
    allow(cmd.registry).to receive(:run) do |job:, ui:, &blk|
      blk.call(nil)
      [error, nil, result_value]
    end
  end

  def run_with_captured_block
    cmd = command
    block = nil
    allow(cmd.registry).to receive(:run) do |job:, ui:, &blk|
      block = blk
      blk.call(nil)
      [nil, nil, nil]
    end
    cmd.handle('')
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

    result[:context_before] = '🧠 ctx ~62100/65536 (95%)'
    result[:context_line]   = '🧠 ctx ~523/65536 (1%)'
  end

  it 'reports a task error as a [task error] line' do
    cmd = command
    stub_run(cmd, error: 'boom')

    cmd.handle('')

    expect(io.string).to include('[task error] boom')
  end

  it 'emits lines as task events instead of writing to the stream' do
    events = []
    fake_task = Class.new do
      define_method(:push_event) do |type:, origin: nil, content: nil|
        events << { type: type, origin: origin, content: content }
      end
    end.new

    allow(Task).to receive(:current).and_return(fake_task)
    cmd = command
    stub_run(cmd)

    cmd.handle('')

    # Nothing reached the console directly: every line is an event.
    expect(io.string).to eq("")
    expect(events).to eq([
      { type: :gap, origin: nil, content: '' },
      { type: :text, origin: 'command',
        content: 'Session compacted: 10 messages -> 4 messages (2 recent retained).' },
      { type: :text, origin: 'command',
        content: '  🧠 ctx ~62100/65536 (95%) -> 🧠 ctx ~523/65536 (1%)' },
      { type: :text, origin: 'command', content: '' },
      { type: :text, origin: 'command', content: 'Summary:' },
      { type: :text, origin: 'command', content: 'summary text' },
      { type: :text, origin: 'command', content: '' },
      { type: :gap, origin: nil, content: '' }
    ])
  end
end
