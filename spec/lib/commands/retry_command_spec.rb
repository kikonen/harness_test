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

  # Stub the run loop to capture the block it is handed and execute it
  # synchronously (returning +error+ as the turn's error). The spec does not
  # need a real task thread - only the protocol contract: the block must
  # perform the re-send.
  def loop_double(error = nil)
    double('main_loop').tap do |d|
      allow(d).to receive(:run_turn) do |&blk|
        # The real loop runs the block on the worker, where service_turn
        # catches a raise into an :error_ctrl - the double absorbs it too.
        blk.call(nil)
      rescue StandardError
        # absorbed, as service_turn does
        error
      end
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

  def loop_double_with_capture(capture)
    double('main_loop').tap do |d|
      allow(d).to receive(:run_turn) do |&blk|
        capture.call(blk)
        blk.call(nil)
      end
    end
  end

  it 'runs the re-send inside a Task (I/O routed through the drain loop)' do
    block = run_with_captured_block

    expect(block).to be_a(Proc)
    expect(session_manager).to have_received(:retry)
  end

  # The [task error] line is the LOOP's report (MainLoop#run_turn hands the
  # error to CommandHandler#report_turn_error, pinned in main_loop_spec);
  # this spec only pins that a raising round reaches the loop as an error:
  # the real loop catches it in service_turn (an :error_ctrl event), so the
  # double must absorb it the same way.
  it 'hands a raising round to the loop as the turn error' do
    allow(session_manager).to receive(:retry).and_raise('boom')
    loop_ = loop_double('boom')

    expect { command(loop_).handle('') }.not_to raise_error
  end
end
