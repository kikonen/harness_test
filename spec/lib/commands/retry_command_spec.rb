# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'job_registry'
require 'commands/retry_command'

# issue #235: /retry must re-send the session chain on a Task thread (the
# single-thread I/O rule, issue #40). The bug: it ran synchronously on the
# main thread, so the LLM round had no spinner and any dialog blocked the
# console - the log moved but the console looked totally stuck. The command
# reaches the Harness through the foreground job's harness (#286), so the
# harness double rides on a real registry's main job.
RSpec.describe Commands::RetryCommand do
  let(:session_manager) { double('session_manager', retry: nil) }
  let(:harness) { double('harness', session_manager: session_manager) }
  let(:io) { StringIO.new }
  let(:ui) { UI::Console.new(stdout: io) }

  def command
    registry = JobRegistry.new
    registry.add_job(kind: :main, harness:)
    described_class.new(registry:, file_list: nil, ui:)
  end

  # Stub the registry executor to capture the block it is handed and execute
  # it synchronously. The spec does not need a real task thread - only the
  # protocol contract: the block must perform the re-send.
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

  it 'runs the re-send inside a Task (I/O routed through the drain loop)' do
    block = run_with_captured_block

    expect(block).to be_a(Proc)
    expect(session_manager).to have_received(:retry)
  end

  it 'reports a task error as a [task error] line' do
    cmd = command
    allow(cmd.registry).to receive(:run) { |job:, ui:, &blk| ['boom', nil, nil] }

    cmd.handle('')

    expect(io.string).to include('[task error] boom')
  end
end
