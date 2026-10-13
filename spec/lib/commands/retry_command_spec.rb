# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'commands/retry_command'

# issue #235: /retry must re-send the session chain on a Task thread (the
# single-thread I/O rule, issue #40). The bug: it ran synchronously on the
# main thread, so the LLM round had no spinner and any dialog blocked the
# console - the log moved but the console looked totally stuck.
RSpec.describe Commands::RetryCommand do
  let(:session_manager) { double('session_manager', retry: nil) }
  let(:harness) { double('harness', session_manager: session_manager) }
  let(:io) { StringIO.new }
  let(:ui) { UI::Console.new(stdout: io) }

  def command
    described_class.new(harness:, file_list: nil, options: nil, ui:)
  end

  # Stub Task.run to capture the block it is handed and execute it
  # synchronously. The spec does not need a real task thread - only the
  # protocol contract: the block must perform the re-send.
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

  it 'runs the re-send inside a Task (I/O routed through the drain loop)' do
    block = run_with_captured_block

    expect(block).to be_a(Proc)
    expect(session_manager).to have_received(:retry)
  end

  it 'reports a task error as a [task error] line' do
    allow(Task).to receive(:run) { |harness:, ui:, &blk| ['boom', nil] }

    command.handle('')

    expect(io.string).to include('[task error] boom')
  end
end
