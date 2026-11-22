# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'task_runner'
require 'job_registry'
require 'input_path'

# issue #235: the shared wrapper for running an LLM round on a Task thread.
# Without it, Task.emit events are dropped and dialogs block the console.
RSpec.describe TaskRunner do
  # Minimal test double that includes TaskRunner and exposes harness/ui.
  let(:io) { StringIO.new }
  let(:ui) { UI::Console.new(stdout: io) }
  # run_on_task asks it for an aborted turn's summary line (#567): nil = nothing.
  let(:harness) { instance_double(Harness, aborted_turn_stats_line: nil) }

  # #286: every TaskRunner host is built by the run with its registry, and
  # #run_on_task AWAITs a job there (the harness reaches the Task via the job).
  # The smallest real one (a single main job) stands in for the run's registry.
  let(:registry) { JobRegistry.new }
  let(:main_job) { registry.add_job(kind: :main, harness: harness) }

  let(:host) do
    Class.new do
      include TaskRunner
      attr_accessor :foreground_harness, :ui, :settings, :registry

      def do_thing
        run_on_task { |_t| :work_done }
      end
    end.new
  end

  def setup_host
    host.foreground_harness = harness
    host.ui = ui
    host.registry = registry
    main_job # force the foreground job into the registry
    host
  end

  it 'runs the block on the host registry job, the harness off the job' do
    setup_host
    captured = {}
    # #286: registry.run reads the Harness off the job, not from this host.
    allow(registry).to receive(:run) do |job:, ui:, &blk|
      captured[:harness] = job.harness
      captured[:ui]      = ui
      [nil, nil, blk.call(nil)]
    end

    host.do_thing

    expect(captured[:harness]).to equal(harness)
    expect(captured[:ui]).to equal(ui)
    expect(registry).to have_received(:run).with(job: main_job, ui: ui)
  end

  # issue #286 increment 2: the registry is the executor, so a host whose harness
  # has one AWAITs a job there rather than running the turn in place, and the
  # block's value comes back as the job's result.
  describe 'run_on_task awaits the registry job' do
    def registry_host
      registry = JobRegistry.new
      host.registry = registry
      host.ui = ui
      job_harness = double('harness', aborted_turn_stats_line: nil)
      [host, registry, registry.add_job(kind: :main, harness: job_harness)]
    end

    it 'runs the foreground job through the registry and returns its result' do
      host, registry, job = registry_host
      # #286: registry.run no longer takes a harness - it reads it off the job.
      allow(registry).to receive(:run) do |job:, ui:, &blk|
        [nil, nil, blk.call(nil)]
      end

      expect(host.do_thing).to eq(:work_done)
      expect(registry).to have_received(:run).with(job:, ui:)
    end

    # The ONE input path is handed to the executor when the host owns one, so
    # the edit state is one state of the run's single poll loop.
    it 'passes the host input path to the registry run' do
      host, registry = registry_host
      host.input_path = InputPath.new(ui:)
      allow(registry).to receive(:run) { |**kwargs| [nil, nil, nil] }
      host.do_thing

      expect(registry).to have_received(:run).with(include(input_path: host.input_path))
    end
  end

  # issue #474 increment 22: the bracket shape belongs to UI::Renderer, so the
  # emitter states the :kind role and the origin names the kind. The console bytes
  # are unchanged, and the content is pattern-free - so a replay redraws the line
  # through the renderer instead of inheriting this emitter's prefix.
  it 'states the task error as the :kind role, the bracket being the renderer shape' do
    setup_host
    allow(Task).to receive(:current).and_return(nil)
    allow(registry).to receive(:run) { [ 'boom', nil, nil ] }

    host.do_thing

    # run_on_task's own leading and trailing blank lines are unchanged; only the
    # middle line now comes from the renderer.
    expect(io.string).to eq("\n  [task error] boom\n\n")
  end

  # issue #567: the harness decides whether an aborted turn owes a summary line;
  # this emitter prints it after the error line.
  describe 'the aborted turn summary line (issue #567)' do
    it 'prints the line the harness reports for the job that ran the turn' do
      setup_host
      line = '  [⏱ 1.2s | 🔄 1 of 2 iterations answered]'
      allow(Task).to receive(:current).and_return(nil)
      allow(harness).to receive(:aborted_turn_stats_line)
        .with(main_job.id).and_return(line)
      allow(registry).to receive(:run) { ['boom', nil, nil] }

      host.do_thing

      expect(io.string).to eq(
        "\n  [task error] boom\n#{line}\n\n"
      )
    end

    it 'prints nothing when the harness reports no line' do
      setup_host
      allow(Task).to receive(:current).and_return(nil)
      allow(registry).to receive(:run) { ['boom', nil, nil] }

      host.do_thing

      expect(io.string).to eq("\n  [task error] boom\n\n")
    end
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
    allow(registry).to receive(:run) { ['boom', nil, nil] }

    host.do_thing

    # Measured: the framing blanks are the :gap role too, so the whole turn is
    # events on the outbox - nothing is written to a stream from the emitter.
    expect(events).to eq([
      { type: :gap, origin: nil, content: '' },
      { type: :kind, origin: 'task error', content: 'boom' },
      { type: :gap, origin: nil, content: '' }
    ])
  end

  it 'prints blank lines before and after the task output' do
    setup_host
    allow(registry).to receive(:run) { [nil, nil, nil] }

    host.do_thing

    # No task output: a leading blank and a trailing blank (each + newline).
    expect(io.string).to eq("\n\n")
  end

  # issue #253: lines emitted from inside a task block must go through the
  # event queue, never straight to a stream (single-thread I/O rule, #40).
  it 'writes emit_line to the console when no task is active' do
    setup_host
    allow(registry).to receive(:run) { |job:, ui:, &blk| blk.call(nil); [nil, nil, nil] }
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

    allow(Task).to receive(:current).and_return(fake_task)
    allow(registry).to receive(:run) do |job:, ui:, &blk|
      blk.call(nil)
      [nil, nil, nil]
    end
    host.instance_eval { run_on_task { emit_line 'hello' } }

    # Measured: a task thread writes nothing to a stream, so the blanks reach the
    # console only after the drain loop renders them - here the outbox alone.
    expect(io.string).to eq("")
    expect(events).to eq([
      { type: :gap, origin: nil, content: '' },
      { type: :text, origin: 'command', content: 'hello' },
      { type: :gap, origin: nil, content: '' }
    ])
    # The origin is the bracket label and the record keeps it as a STRING (the
    # single router normalizes it, so every role's origin reads the same after the
    # session JSON round trip).
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
  # renderer draws the row layout; the run registry's record_report_output takes
  # STRUCTURED payload (title/columns/items), not a pre-rendered string. A
  # host without a registry (a plain command spec) still prints fine.
  describe 'emit_list (issue #474: structured command report)' do
    it 'renders the bullet list AND records the payload as structure' do
      recorded = []
      host.foreground_harness = Object.new
      host.ui = ui
      reg = Object.new
      reg.define_singleton_method(:record_report_output) do |type:, origin:, content:|
        recorded << { type:, origin:, content: }
      end
      host.registry = reg
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

    it 'renders without a record path when the host has no registry' do
      host.foreground_harness = Object.new
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
    def recording_registry
      recorded = []
      reg = Object.new
      reg.define_singleton_method(:record_report_output) do |type:, origin:, content:|
        recorded << { type:, origin:, content: }
      end
      [reg, recorded]
    end

    it 'records the stored markdown while printing the rendered line' do
      registry, recorded = recording_registry
      host.foreground_harness = Object.new
      host.registry = registry
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
      host.foreground_harness = Object.new
      host.registry = nil
      host.ui = ui
      allow(Task).to receive(:current).and_return(nil)
      host.emit_role(:body, '# Title', origin: 'plans')

      expect(io.string).to eq("# Title\n")
    end
  end

end
