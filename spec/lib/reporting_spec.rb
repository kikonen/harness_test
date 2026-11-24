# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'reporting'
require 'job_registry'
require 'input_path'

# The console-reporting mixin (issue #235): without it, Task.emit events are
# dropped and dialogs block the console. The run wrapper (run_on_worker) moved
# to MainLoop/Command in increment 3, so these specs drive the roles directly.
RSpec.describe Reporting do
  let(:io) { StringIO.new }
  let(:ui) { UI::Console.new(stdout: io) }

  # Every Reporting host is built by the run with its registry, settings and ui.
  let(:registry) { JobRegistry.new }
  let(:main_job) { registry.add_job(kind: :main) }

  # Reporting#main_thread_renderer reads settings off the host.
  def spec_settings
    Class.new do
      def output_palette = UI::Palette.fetch('default')
      def markdown_max_width = nil
    end.new
  end

  let(:host) do
    Class.new do
      include Reporting
      attr_accessor :foreground_harness, :ui, :settings, :registry, :input_path
    end.new
  end

  def setup_host
    host.foreground_harness = Object.new
    host.settings = spec_settings
    host.ui = ui
    host.registry = registry
    main_job # force the foreground job into the registry
    host
  end

  # A stand-in active Task: a task thread must never write to a stream, so the
  # roles travel as events instead (single-thread I/O rule, issue #40).
  def fake_task(events)
    Class.new do
      define_method(:push_event) do |type:, origin: nil, content: nil|
        events << { type: type, origin: origin, content: content }
      end
    end.new
  end

  it 'writes emit_line to the console when no task is active' do
    setup_host
    allow(Task).to receive(:current).and_return(nil)
    host.emit_line 'hello'

    expect(io.string).to include("hello\n")
  end

  it 'emits emit_line as a :text event on the active task' do
    setup_host
    events = []
    allow(Task).to receive(:current).and_return(fake_task(events))
    host.emit_line 'hello'

    # A task thread writes nothing to a stream: the line reaches the console
    # only when the loop renders the event.
    expect(io.string).to eq("")
    expect(events).to eq([{ type: :text, origin: 'command', content: 'hello' }])
    # The origin is the bracket label kept as a STRING (the single router
    # normalizes it, so every role's origin reads the same after the session
    # JSON round trip).
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
    allow(Task).to receive(:current).and_return(fake_task(events))

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
