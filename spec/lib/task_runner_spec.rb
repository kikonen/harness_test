# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'task_runner'

# issue #235: the shared wrapper for running an LLM round on a Task thread.
# Without it, Task.emit events are dropped and dialogs block the console.
RSpec.describe TaskRunner do
  # Minimal test double that includes TaskRunner and exposes harness/ui.
  let(:io) { StringIO.new }
  let(:ui) { UI::Console.new(stdout: io) }
  let(:harness) { double('harness') }

  let(:host) do
    Class.new do
      include TaskRunner
      attr_accessor :harness, :ui

      def do_thing
        run_on_task { |_t| :work_done }
      end
    end.new
  end

  def setup_host
    host.harness = harness
    host.ui = ui
    host
  end

  it 'runs the block inside Task.run with the host harness and ui' do
    setup_host
    captured = {}
    allow(Task).to receive(:run) do |harness:, ui:, &blk|
      captured[:harness] = harness
      captured[:ui]      = ui
      captured[:result]  = blk.call(nil)
      [nil, nil]
    end

    host.do_thing

    expect(captured[:harness]).to equal(harness)
    expect(captured[:ui]).to equal(ui)
    expect(captured[:result]).to eq(:work_done)
  end

  it 'reports a task error as a [task error] line on the console' do
    setup_host
    allow(Task).to receive(:run) { |harness:, ui:, &blk| ['boom', nil] }

    host.do_thing

    expect(io.string).to include('[task error] boom')
  end

  it 'prints blank lines before and after the task output' do
    setup_host
    allow(Task).to receive(:run) { |harness:, ui:, &blk| [nil, nil] }

    host.do_thing

    # No task output: a leading blank and a trailing blank (each + newline).
    expect(io.string).to eq("\n\n")
  end
end
