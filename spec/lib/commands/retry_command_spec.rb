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
  let(:harness) do
    double('harness', session_manager: session_manager,
                     aborted_turn_stats_line: nil)
  end
  let(:io) { StringIO.new }
  let(:ui) { UI::Console.new(stdout: io) }

  # Stub the run loop's drain state: begin_turn takes the QueuedEvent and runs
  # its block synchronously. The spec does not need a real task thread - only
  # the protocol contract: the block must perform the re-send.
  def loop_double
    double('main_loop').tap do |d|
      allow(d).to receive(:begin_turn) do |event|
        # The real loop runs the block on the worker, where the mini-turn
        # absorbs a raise - the double absorbs it too.
        event.block.call
      rescue StandardError
        # absorbed, as the mini-turn does
      end
      allow(d).to receive(:shown_job) { nil }
    end
  end

  def loop_double_with_capture(capture)
    double('main_loop').tap do |d|
      allow(d).to receive(:begin_turn) do |event|
        capture.call(event.block)
        event.block.call
      rescue StandardError
        # absorbed, as the mini-turn does
      end
      allow(d).to receive(:shown_job) { nil }
    end
  end

  def command(main_loop = loop_double)
    registry = JobRegistry.new
    registry.add_job(kind: :main, harness:)
    described_class.new(registry:, file_list: nil, ui:, main_loop:)
  end

  def run_with_captured_block
    block = nil
    cmd = command(loop_double_with_capture(block = ->(blk) { block = blk }))
    cmd.handle('')
    block
  end

  it 'runs the re-send inside a Task (I/O routed through the drain loop)' do
    block = run_with_captured_block

    expect(block).to be_a(Proc)
    expect(session_manager).to have_received(:retry)
  end

  # The [task error] line is the LOOP's report (its drain state hands the error
  # to CommandHandler#report_turn_error, pinned in main_loop_spec); this spec
  # only pins that a raising round reaches the loop as an error: the real loop
  # runs the block in a mini-turn that absorbs it, so the double must too.
  it 'hands a raising round to the loop as the turn error' do
    allow(session_manager).to receive(:retry).and_raise('boom')

    expect { command.handle('') }.not_to raise_error
  end
end
