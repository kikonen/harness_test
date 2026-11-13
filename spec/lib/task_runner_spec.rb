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

  # issue #474 increment 22: the bracket shape belongs to UI::Renderer, so the
  # emitter states the :kind role and the origin names the kind. The console bytes
  # are unchanged, and the content is pattern-free - so a replay redraws the line
  # through the renderer instead of inheriting this emitter's prefix.
  it 'states the task error as the :kind role, the bracket being the renderer shape' do
    setup_host
    allow(Task).to receive(:current).and_return(nil)
    allow(Task).to receive(:run) { |harness:, ui:, &blk| ['boom', nil] }

    host.do_thing

    # run_on_task's own leading and trailing blank lines are unchanged; only the
    # middle line now comes from the renderer.
    expect(io.string).to eq("\n  [task error] boom\n\n")
  end

  # The same role routed the normal way: with a task active the error travels as an
  # event, so it enters the record as type + origin + content, never as a fused
  # "[task error] boom" string.
  it 'carries the task error as a :kind event when a task is active' do
    setup_host
    events = []
    fake_task = Class.new do
      define_method(:push_event) do |type:, origin: nil, content: nil|
        events << { type: type, origin: origin, content: content }
      end
    end.new
    allow(Task).to receive(:current).and_return(fake_task)
    allow(Task).to receive(:run) { |harness:, ui:, &blk| ['boom', nil] }

    host.do_thing

    expect(events).to eq([{ type: :kind, origin: 'task error', content: 'boom' }])
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
    # The origin is the bracket label and the record keeps it as a STRING (the
    # single router normalizes it, so every role's origin reads the same after the
    # session JSON round trip).
    expect(events).to eq([{ type: :text, origin: 'command', content: 'hello' }])
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
  # issue #474: a command report's structure reaches the durable record. The
  # renderer draws the row layout; harness.record_report_output receives the
  # STRUCTURED payload (title/columns/items), not a pre-rendered string. A
  # harness double that lacks record_report_output (a plain command spec) must
  # still print fine, so the recording is guarded by respond_to?.
  describe 'emit_list (issue #474: structured command report)' do
    it 'renders the bullet list AND records the payload as structure' do
      recorded = []
      # Plain object (not a strict double): main_thread_renderer asks the harness
      # whether it answers #output_palette too, so respond_to? must answer both.
      h = Object.new
      h.define_singleton_method(:record_report_output) do |type:, origin:, content:|
        recorded << { type:, origin:, content: }
      end
      host.harness = h
      host.ui = ui
      allow(Task).to receive(:current).and_return(nil)
      host.emit_list(title: 'Hosts:', items: [{ value: 'a' }, { value: 'b' }],
                     columns: [:value], origin: 'grant')
      # Console: byte-identical to the old @ui.puts output.
      expect(io.string).to eq("Hosts:\n  - a\n  - b\n")
      # Record: the fields, not a fused row string.
      expect(recorded.size).to eq(1)
      entry = recorded.first
      expect(entry[:type]).to eq(:list)
      expect(entry[:origin]).to eq('grant')
      expect(entry[:content]).to include(:title, :items, :columns, :kind)
      expect(entry[:content][:items]).to eq([{ value: 'a' }, { value: 'b' }])
    end

    it 'renders without a record path when harness has no record_report_output' do
      # An object with NO record_report_output: a plain command spec's harness.
      host.harness = Object.new
      host.ui = ui
      allow(Task).to receive(:current).and_return(nil)
      host.emit_list(title: 'L:', items: [{ value: 'x' }], columns: [:value])
      # Console output unchanged.
      expect(io.string).to eq("L:\n  - x\n")
    end
  end

  # issue #474: a store body is the one main-thread role whose RECORD must hold the
  # RAW stored markdown rather than the printed line, so a replay redraws it through
  # the renderer (the same #146 rule :list follows). The console line is the render.
  describe 'emit_role(:body) - the record holds the raw text, not the render' do
    def recording_harness
      recorded = []
      h = Object.new
      h.define_singleton_method(:record_report_output) do |type:, origin:, content:|
        recorded << { type:, origin:, content: }
      end
      [h, recorded]
    end

    it 'records the stored markdown while printing the rendered line' do
      harness, recorded = recording_harness
      host.harness = harness
      host.ui = UI::Console.new(stdout: io, palette: UI::Palette.fetch('default'))
      allow(Task).to receive(:current).and_return(nil)
      host.emit_role(:body, '# Title' + "\n\nRun **bin/rspec** first.", origin: 'plans')

      expect(recorded.size).to eq(1)
      entry = recorded.first
      expect(entry[:type]).to eq(:body)
      expect(entry[:origin]).to eq('plans')
      # The record is the RAW file content: no escape bytes, no consumed markers.
      expect(entry[:content]).to eq("# Title\n\nRun **bin/rspec** first.")
      # The console got the render (markers consumed, title painted).
      expect(io.string).to include('Title')
      expect(io.string).to include("\e[")
      expect(io.string).not_to include('# Title')
    end

    it 'still prints when harness has no record path' do
      host.harness = Object.new
      host.ui = ui
      allow(Task).to receive(:current).and_return(nil)
      host.emit_role(:body, '# Title', origin: 'plans')

      expect(io.string).to eq("# Title\n")
    end
  end

end
