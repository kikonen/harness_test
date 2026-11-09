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

  # issue #253: lines emitted from inside a task block must go through the
  # event queue, never straight to a stream (single-thread I/O rule, #40).
  it 'writes emit_line to the console when no task is active' do
    setup_host
    allow(Task).to receive(:run) { |harness:, ui:, &blk| blk.call(nil); [nil, nil] }
    allow(Task).to receive(:current).and_return(nil)
    host.instance_eval { run_on_task { emit_line 'hello' } }

    expect(io.string).to include("hello\n")
  end

  it 'emits emit_line as a :text event on the active task' do
    setup_host
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
    host.instance_eval { run_on_task { emit_line 'hello' } }

    expect(io.string).to eq("\n\n") # only run_on_task's blank lines
    expect(events).to eq([{ type: :text, origin: :command, content: 'hello' }])
  end

  # emit_role takes an ARRAY of paragraphs: a contiguous report-prose body is
  # ONE :note block, not several calls. Main thread: the renderer lays out every
  # paragraph of the joined content (each wrapped and indented), on one line.
  it 'renders a :note array as ONE wrapped note block on the main thread' do
    setup_host
    allow(Task).to receive(:current).and_return(nil)
    host.emit_role(:note, ['first paragraph here', 'second paragraph here'])

    lines = io.string.split("\n")
    expect(lines).to eq(['  first paragraph here', '  second paragraph here'])
  end

  it 'carries a :note array as ONE event whose content is the joined paragraphs' do
    setup_host
    events = []
    fake_task = Class.new do
      define_method(:push_event) do |type:, origin: nil, content: nil|
        events << { type: type, origin: origin, content: content }
      end
    end.new
    allow(Task).to receive(:current).and_return(fake_task)

    host.emit_role(:note, ['first paragraph', 'second paragraph'], origin: 'report')

    expect(events).to eq([{ type: :note, origin: 'report', content: "first paragraph\nsecond paragraph" }])
  end

  it 'leaves a single :note string as one paragraph (array support is additive)' do
    setup_host
    allow(Task).to receive(:current).and_return(nil)
    host.emit_role(:note, 'just one paragraph')

    expect(io.string).to eq("  just one paragraph\n")
  end
end
