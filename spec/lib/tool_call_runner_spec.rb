# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'logger'
require 'spec_helper'
require 'file_list'
require 'system_settings'
require 'tool_registry'
require 'session'
require 'session_file_cache'
require 'session_logger'
require 'tool_call_runner'
require 'tool_call_ports'
require 'model_config'
require 'job_registry'

# The tool-call half of a turn, tested at ITS OWN seam (issue #582): a fixture
# supplies the ports and no Harness is built, which is the point of the cut -
# this behavior no longer needs the harness to be exercised.
RSpec.describe ToolCallRunner do
  def build_fixture(options = {})
    workdir = Dir.mktmpdir('tool-call-spec')
    (@workdirs ||= []) << workdir
    log_dir = File.join(workdir, ".harness", "sessions", "spec")
    FileUtils.mkdir_p(File.dirname(log_dir))
    logger = SessionLogger.build(log_dir)
    settings = SystemSettings.from_options(options)
    registry = ToolRegistry.new
    session  = Session.new("system prompt", file_cache: SessionFileCache.new)
    locator  = SessionLocator.new(workdir)
    spill    = ResultSpill.new(locator, "spec", job_id: 0)
    fixture  = Struct.new(:workdir, :log_path, :logger, :settings, :tool_registry,
                          :session, :client, :model_config, :file_list, :result_spill,
                          :tools_payload).new(
      workdir, log_dir, logger, settings, registry, session, nil,
      ModelConfig.new(options), FileList.new([], workdir: workdir), spill,
      registry.to_openai
    )
    ports = ToolCallPorts.new(
      logger: logger,
      settings: settings,
      tool_registry: registry,
      session: session,
      model_config: ModelConfig.new(options),
      file_list: FileList.new([], workdir: workdir),
      spill_reader: nil,
      result_spill: -> { spill },
      text_tool_call_parser: nil,
      tool_wait_suffix: -> { nil },
      client: -> { nil }
    )
    [fixture, ports]
  end

  after do
    Array(@workdirs).each { |d| FileUtils.remove_entry(d) if File.directory?(d) }
  end

  # One fixture per example, with the runner and ports already wired.
  let(:pair)    { build_fixture }
  let(:fixture) { pair[0] }
  let(:ports)   { pair[1] }
  let(:runner)  { described_class.new }

  # A Task always runs on a registry + job (#286); an un-started one is enough
  # to capture Task.emit events.
  def emit_task
    registry = JobRegistry.new
    job = registry.add_job(kind: :main)
    Task.new(registry:, job:)
  end

  def drain_outbox(task)
    ms = []
    loop do
      m = task.poll(0)
      break unless m
      ms << m
    end
    ms
  end

  describe '#emit_step (issue #131)' do
    # The roles emit_step is allowed to emit (issue #146).
    let(:step_roles) { %i[step_label plan interstitial tool_plan] }
    let(:task) { emit_task }
    around do |example|
      @old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task
      example.run
    ensure
      Thread.current[:harness_task] = @old_current
    end
    let(:drained_lines) { drain_outbox(task).map { |m| m[:content] } }

    let(:message) do
      {
        reasoning: 'First I will inspect the spinner, then run the specs.',
        tool_calls: [
          { id: 'c1', function: { name: 'file.read', arguments: '{"path":"lib/ui/spinner.rb"}' } },
          { id: 'c2', function: { name: 'run.command', arguments: '{"command":"bundle exec rspec"}' } }
        ]
      }
    end

    it 'emits the step number, a digest of the reasoning and the tools called' do
      runner.emit_step(message, ports)
      events = drain_outbox(task)
      lines = events.map { |m| m[:content] }

      # Content is the ROLE the emitter stated; the pattern ('step ',
      # 'plan:  ') belongs to UI::Renderer, so it is asserted here on the
      # rendered line (spec/lib/ui/renderer_spec.rb covers the labels).
      step = events.find { |m| m[:type] == :step_label }[:content]
      expect(step[:number]).to eq(1)
      # The count is the number of tool calls in this step.
      expect(step[:calls]).to eq(2)
      expect(lines).to include('First I will inspect the spinner, then run the specs.')
      expect(lines).to include('file.read, run.command')
    end

    # issue #577: the step number is a job-wide monotonic counter, not the
    # per-call_llm loop counter - repeated emit_step calls never repeat a number
    # and never go backwards, so a turn that restarts cannot re-issue a step.
    it 'numbers steps monotonically across repeated calls (issue #577)' do
      numbers = 3.times.map do
        runner.emit_step(message, ports)
        drain_outbox(task).find { |m| m[:type] == :step_label }[:content][:number]
      end

      expect(numbers).to eq([1, 2, 3])
    end

    it 'falls back to message content when there is no reasoning' do
      msg = { reasoning: nil, content: 'checking the test suite',
              tool_calls: [{ id: 'c1', function: { name: 'run.command', id: 'run.command' } }] }

      runner.emit_step(msg, ports)
      lines = drained_lines

      expect(lines).to include('checking the test suite')
      expect(lines).to include('run.command')
    end

    it 'emits the reasoning digest and the interstitial as distinct roles' do
      runner.emit_step(message, ports)
      rendered = drain_outbox(task).map { |m| UI::Renderer.new.line(type: m[:type], content: m[:content]) }

      expect(rendered).to include('plan:  First I will inspect the spinner, then run the specs.')
      expect(rendered).not_to include(a_string_matching(/>>>/))
      expect(rendered).not_to include(a_string_matching(/\|\|\|/))
    end

    it 'emits only the tool line when there is no reasoning text at all' do
      msg = { reasoning: nil, content: nil,
              tool_calls: [{ id: 'c1', function: { name: 'file.search', id: 'file.search' } }] }

      runner.emit_step(msg, ports)
      lines = drained_lines

      expect(lines).to include('file.search')
    end

    it 'emits only the step roles - no spinner pause/resume (drain loop owns that)' do
      runner.emit_step(message, ports)

      types = drain_outbox(task).map { |m| m[:type] }
      expect(types - step_roles).to be_empty
      expect(types).not_to include(:progress_pause, :progress_resume, :spinner_detail)
    end

    it 'emits nothing when disabled via HARNESS_STEP_DISPLAY=off' do
      original = ENV['HARNESS_STEP_DISPLAY']
      ENV['HARNESS_STEP_DISPLAY'] = 'off'

      begin
        runner.emit_step(message, ports)

        expect(drain_outbox(task)).to be_empty
      ensure
        ENV['HARNESS_STEP_DISPLAY'] = original
      end
    end
  end

  describe '#execute spinner_detail (issue #40)' do
    let(:task) { emit_task }
    around do |example|
      @old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task
      example.run
    ensure
      Thread.current[:harness_task] = @old_current
    end

    let(:fake_tool) do
      Class.new(Tool) do
        def execute(_args)
          'ok'
        end
      end.new(name: 'ui.notify', description: 'fake', parameters: {})
    end

    # issue #362: a wait is announced by whoever starts it, and the tool round
    # IS a wait (a slow command, a consent dialog). Without this re-point the
    # drain loop replays the LLM request line that already finished, so a
    # 40-second run.command reads as if the model were still generating.
    it 're-points the spinner with the tool name before the tool runs' do
      ports.tool_registry.register(fake_tool)
      call = { id: 'c1', function: { name: 'ui.notify', arguments: '{}' } }

      expect(runner.execute(call, ports)).to eq('ok')

      details = drain_outbox(task).select { |m| m[:type] == :spinner_detail }
      expect(details.size).to eq(1)
      # The origin is the emitter's symbol (the buffer records who spoke).
      expect(details.first[:origin]).to eq(:harness)
      expect(details.first[:content][:message]).to eq('ui.notify')
      # A tool round has no request in flight, so it carries no rate segment -
      # the suffix is the live context estimate, not a tok/s number.
      expect(details.first[:content][:suffix]).to respond_to(:call)
    end

    # The spinner line is ONE line, and tool arguments are model-supplied text
    # that must never be echoed onto it.
    it 'names the tool only - never its arguments' do
      ports.tool_registry.register(fake_tool)
      long  = { id: 'c1', function: { name: 'ui.notify',
                                      arguments: JSON.dump(text: 'x' * 500) } }

      runner.execute(long, ports)

      detail = drain_outbox(task).find { |m| m[:type] == :spinner_detail }
      expect(detail[:content][:message]).to eq('ui.notify')
    end

    # issue #257: the tool result goes straight back into the message chain,
    # so an undecodable byte in it made the next JSON.generate (the request
    # body AND the session save) raise JSON::GeneratorError - and the failure
    # was invisible because the save that should record it died on the same
    # byte. #execute normalizes what enters the chain.
    it 'normalizes a tool result that carries an invalid byte' do
      bad = [0xE2, 0x90].pack('C*').force_encoding(Encoding::UTF_8)
      raw_tool = Class.new(Tool) do
        define_method(:execute) { |_args| bad }
      end.new(name: 'ui.notify', description: 'fake', parameters: {})
      ports.tool_registry.register(raw_tool)

      result = runner.execute({ id: 'c1', function: { name: 'ui.notify', arguments: '{}' } }, ports)
      expect(result.valid_encoding?).to be true
      expect(result).to eq('?')
      # What the session save (JSON.generate) choked on before the fix.
      expect { JSON.generate({ 'content' => bad }) }.to raise_error(JSON::GeneratorError)
      expect { JSON.generate({ 'content' => result }) }.not_to raise_error
    end

    it 'does not emit spinner_detail for an unknown tool' do
      call = { id: 'c1', function: { name: 'nope.missing', arguments: '{}' } }

      expect(runner.execute(call, ports)).to include('unknown tool')

      expect(drain_outbox(task).map { |m| m[:type] }).not_to include(:spinner_detail)
    end

    # issue #409: a tool that raises is an unexpected crash - the frames are
    # what explains it, so the log records them (ErrorText.detailed). The
    # string returned to the model stays the one-line label: a backtrace in a
    # tool result is noise it cannot act on, replayed on every request.
    it 'logs a raising tool WITH ITS FRAMES and returns the label to the model' do
      boom_tool = Class.new(Tool) do
        define_method(:execute) { |_args| nil.record }
      end.new(name: 'ui.notify', description: 'fake', parameters: {})
      ports.tool_registry.register(boom_tool)
      call = { id: 'c1', function: { name: 'ui.notify', arguments: '{}' } }

      result = runner.execute(call, ports)

      expect(result).to eq(
        "error: NoMethodError: undefined method 'record' for nil"
      )
      log = File.read(fixture.log_path)
      expect(log).to include("tool ui.notify failed: " \
                             "NoMethodError: undefined method 'record' for nil")
      expect(log).to include('tool_call_runner_spec.rb')
    end
  end

  # Some models wrap a call's arguments in an extra top-level "arguments" key,
  # so the tool reads its own parameters as missing (e.g. run.command gets
  # {"arguments": {"command": ...}} and 'command' is nil). #execute unwraps
  # that envelope through Tool#normalize_arguments before dispatch.
  describe '#execute wrapped arguments envelope' do
    it 'runs a call whose arguments arrived wrapped in an extra arguments key' do
      f, p = build_fixture
      echo = Class.new(Tool) do
        define_method(:execute) { |args| args["text"] }
      end.new(name: 'test.echo', description: 'echo', parameters: {})
      p.tool_registry.register(echo)
      wrapped = { 'arguments' => { 'text' => 'echoed' } }
      call = { id: 'c1', function: { name: 'test.echo',
                                     arguments: JSON.generate(wrapped) } }

      expect(runner.execute(call, p)).to eq('echoed')
      expect(File.read(f.log_path))
        .to include("tool test.echo arguments arrived wrapped in an extra 'arguments' key")
    end

    it 'leaves a normal call untouched (no unwrap log line)' do
      f, p = build_fixture
      echo = Class.new(Tool) do
        define_method(:execute) { |args| args["text"] }
      end.new(name: 'test.echo', description: 'echo', parameters: {})
      p.tool_registry.register(echo)
      call = { id: 'c1', function: { name: 'test.echo', arguments: '{"text":"plain"}' } }

      expect(runner.execute(call, p)).to eq('plain')
      expect(File.read(f.log_path))
        .not_to include("arrived wrapped in an extra 'arguments' key")
    end
  end

  describe '#capture_note (issue #138)' do
    def note_call(text)
      { id: 'c1', function: { name: 'session.note', arguments: JSON.dump(text: text) } }
    end

    it 'buffers the note when a session.note call succeeds' do
      _, p = build_fixture

      runner.capture_note(note_call('granted read on lib/'), 'ok: noted 19 chars', p)

      expect(p.session.instance_variable_get(:@notes))
        .to eq(['granted read on lib/'])
    end

    it 'does not buffer anything for a different tool' do
      _f, p = build_fixture

      call = { id: 'c1', function: { name: 'file.read', arguments: '{}' } }
      runner.capture_note(call, 'ok: noted 19 chars', p)

      expect(p.session.instance_variable_get(:@notes)).to be_nil
    end

    it 'does not buffer anything when the session.note call failed' do
      _f, p = build_fixture

      runner.capture_note(note_call('should not appear'), 'error: empty note', p)

      expect(p.session.instance_variable_get(:@notes)).to be_nil
    end

    it 'survives a malformed arguments payload without raising' do
      f, p = build_fixture

      call = { id: 'c1', function: { name: 'session.note', arguments: '{not json' } }

      expect { runner.capture_note(call, 'ok: noted 5 chars', p) }.not_to raise_error
      expect(p.session.instance_variable_get(:@notes)).to be_nil
      # issue #345: the drop is now visible. It used to rescue to nothing, so a
      # session.note whose arguments never arrived was silently not buffered.
      expect(File.read(f.log_path))
        .to include('session.note arguments did not parse')
    end

    it 'does not buffer anything when the result is not a string' do
      _f, p = build_fixture

      runner.capture_note(note_call('nope'), nil, p)

      expect(p.session.instance_variable_get(:@notes)).to be_nil
    end
  end
end
