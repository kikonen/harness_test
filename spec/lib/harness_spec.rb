# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'spec_helper'
require 'harness'

# Display-layer coverage for issue #63: the context indicator (shown above
# the prompt and in the per-response stats) and the /ctx report. Both are
# pure instance methods, so a real Harness instance is enough - no network.
RSpec.describe Harness do
  # Use a temp workdir so building the Harness (which creates .harness/)
  # does not pollute the project root.
  let(:workdir) { Dir.mktmpdir('harness-spec') }
  after { FileUtils.remove_entry(workdir) if File.directory?(workdir) }

  def build_harness(options = {})
    file_list = FileList.new([], workdir: workdir)
    opts      = { system: 'system prompt', num_ctx: 65_536 }.merge(options)
    described_class.new(opts, file_list)
  end

  def seed_usage(harness, prompt_tokens)
    harness.session.add_user('hello')
    harness.session.add_assistant('hi')
    harness.session.record_stats(usage: { prompt_tokens: prompt_tokens, total_tokens: prompt_tokens + 867 })
  end

  describe '#context_indicator' do
    it 'is nil when there is no conversation yet' do
      expect(build_harness.context_indicator).to be_nil
    end

    it 'shows exact usage from the last response' do
      harness = build_harness
      seed_usage(harness, 42_133)

      expect(harness.context_indicator).to eq('🧠 ctx 42133/65536 (64%)')
    end

    it 'marks estimates with ~' do
      harness = build_harness
      harness.session.add_user('a' * 160) # ~40 tokens at 4 chars/token (estimate)

      expect(harness.context_indicator).to include('~')
    end

    it 'respects a custom context window from options' do
      harness = build_harness(num_ctx: 10_000)
      seed_usage(harness, 5_000)

      expect(harness.context_indicator).to eq('🧠 ctx 5000/10000 (50%)')
    end
  end

  describe '#context_indicator_live (issue #126)' do
    it 'is nil when there is no conversation yet' do
      expect(build_harness.context_indicator_live).to be_nil
    end

    it 'shows EXACT usage (no ~) when the last response reported it' do
      harness = build_harness
      seed_usage(harness, 5_915)

      expect(harness.context_indicator_live).to eq('🧠 ctx 5915/65536 (9%)')
    end

    it 'marks estimates with ~ when no usage was reported yet' do
      harness = build_harness
      harness.session.add_user('a' * 160)

      expect(harness.context_indicator_live).to include('~')
    end

    it 'always estimates an explicit chain (mid-turn / in-loop compaction)' do
      harness = build_harness
      seed_usage(harness, 5_915)
      chain = [{ role: 'user', content: 'a' * 400 }]

      expect(harness.context_indicator_live(chain)).to include('~')
    end
  end

  describe '#context_report' do
    it 'reports "nothing to measure" for an empty session' do
      expect(build_harness.context_report)
        .to eq('No conversation yet - nothing to measure.')
    end

    it 'shows usage, headroom and auto-compact status' do
      harness = build_harness
      seed_usage(harness, 42_133)

      report = harness.context_report

      expect(report).to include('42133 tokens (64% of 65536)')
      expect(report).to include('Headroom:    23403 tokens')
      expect(report).to include('last LLM response')
      # issue #151: trigger depends on context size - min(88% of 65536,
      # 65536 - 8192) = 57344.
      expect(report).to include('not due (fires at 57344 tokens, 88% of the window)')
    end

    it 'flags auto-compact as due when the threshold is exceeded' do
      harness = build_harness
      seed_usage(harness, 60_000)

      # 60000 >= 57344 (window - reserved headroom) -> due (issue #151).
      expect(harness.context_report).to include('due (fires at 57344 tokens, 88% of the window)')
    end
  end

  describe '#session_log_path (issue #113)' do
    it 'resolves to .harness/sessions/<session-id>/harness.log' do
      harness = build_harness

      expected = File.join(workdir, Harness::HARNESS_DIR,
                           'sessions', harness.session.session_id,
                           Harness::SESSION_LOG_FILE)
      expect(harness.session_log_path).to eq(expected)
    end

    it 'creates the log file at the per-session path on first use' do
      harness = build_harness

      # The logger is deferred (issue #123): touching it creates the file.
      expect { harness.logger }.to change { File.file?(harness.session_log_path) }.from(false).to(true)
    end

    it 'does not write to the legacy shared .harness/harness.log' do
      harness = build_harness
      harness.logger # force creation via the lazy accessor

      expect(File.exist?(File.join(workdir, Harness::HARNESS_DIR, 'harness.log'))).to be false
    end
  end

  describe '#initialize logger deferral (issue #123)' do
    it 'does NOT create a log directory for the fresh random id' do
      harness = build_harness

      expect(harness.instance_variable_get(:@logger)).to be_nil
      expect(File.directory?(File.dirname(harness.session_log_path))).to be false
    end

    it 'creates no session dir at all when nothing logs before a resume' do
      build_harness

      sessions_dir = File.join(workdir, Harness::HARNESS_DIR, 'sessions')
      expect(Dir.exist?(sessions_dir) ? Dir.children(sessions_dir) : []).to be_empty
    end
  end

  describe '#rebind_logger (issue #113 / #123)' do
    it 'points the logger at the CURRENT session id after a resume swaps it in' do
      harness = build_harness
      resumed_id = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'

      # Simulate resume: the session id changes but the logger was still
      # bound to the fresh id created at startup (or not created at all).
      harness.session.instance_variable_set(:@session_id, resumed_id)

      expect(harness.session_log_path).to include(resumed_id)

      new_logger = harness.rebind_logger

      expect(new_logger).to be_a(Logger)
      expect(File.file?(File.join(workdir, Harness::HARNESS_DIR, 'sessions', resumed_id, 'harness.log'))).to be true
    end

    it 'closes the old logger when re-binding after a late id change' do
      harness = build_harness
      fresh_id = harness.session.session_id
      harness.logger # force creation for the fresh id

      old_logger = harness.instance_variable_get(:@logger)
      expect(old_logger).not_to be_nil

      harness.session.instance_variable_set(:@session_id, 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')
      harness.rebind_logger

      expect(harness.instance_variable_get(:@logger)).not_to equal(old_logger)
    end

    it 're-points the LLM client so HTTP logging follows the new session' do
      harness = build_harness

      harness.session.instance_variable_set(:@session_id, 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')
      harness.rebind_logger

      expect(harness.client.instance_variable_get(:@logger)).to equal(harness.logger)
    end
  end

  describe '#print_step_display (issue #131)' do
    let(:harness) { build_harness }
    # issue #40 follow-up: print_step_display emits typed events onto the
    # Task's outbox (single event queue) via Task.emit. Set the thread-local
    # task so Task.emit finds it, then drain the outbox to assert on the
    # lines - exactly what the real drain loop does.
    let(:task) { Task.new { } }
    around do |example|
      @old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task
      example.run
    ensure
      Thread.current[:harness_task] = @old_current
    end
    let(:drained_lines) { drain_outbox(task).map { |m| m[:content] } }
    def drain_outbox(t)
      ms = []
      loop do
        m = t.poll(0); break unless m
        ms << m
      end
      ms
    end

    let(:message) do
      {
        reasoning: 'First I will inspect the spinner, then run the specs.',
        tool_calls: [
          { id: 'c1', function: { name: 'file.read', arguments: '{"path":"lib/ui/spinner.rb"}' } },
          { id: 'c2', function: { name: 'run.command', arguments: '{"command":"bundle exec rspec"}' } }
        ]
      }
    end

    it 'prints the step number, a digest of the reasoning and the tools called' do
      harness.send(:print_step_display, 3, message)
      lines = drained_lines

      expect(lines).to include('[step 3]')
      expect(lines).to include('>>> First I will inspect the spinner, then run the specs. <<<')
      expect(lines).to include('    -> file.read, run.command')
    end

    it 'falls back to message content when there is no reasoning' do
      msg = { reasoning: nil, content: 'checking the test suite', tool_calls: [{ id: 'c1', function: { name: 'run.command' } }] }

      harness.send(:print_step_display, 2, msg)
      lines = drained_lines

      expect(lines).to include('[step 2]')
      expect(lines).to include('||| checking the test suite |||')
      expect(lines).to include('    -> run.command')
    end

    it 'prints only the tool line when there is no reasoning text at all' do
      msg = { reasoning: nil, content: nil, tool_calls: [{ id: 'c1', function: { name: 'file.search' } }] }

      harness.send(:print_step_display, 4, msg)
      lines = drained_lines

      expect(lines).to include('[step 4]')
      # The renderer owns the trailing newline now - the entry holds the raw line.
      expect(lines).to include('    -> file.search')
    end

    it 'emits only :step entries - no spinner pause/resume (drain loop owns that)' do
      harness.send(:print_step_display, 1, message)

      types = drain_outbox(task).map { |m| m[:type] }
      expect(types).to all(eq(:step))
      expect(types).not_to include(:progress_pause, :progress_resume, :spinner_detail)
    end

    it 'prints nothing when disabled via HARNESS_STEP_DISPLAY=off' do
      original = ENV['HARNESS_STEP_DISPLAY']
      ENV['HARNESS_STEP_DISPLAY'] = 'off'

      begin
        harness.send(:print_step_display, 1, message)

        expect(drain_outbox(task)).to be_empty
      ensure
        ENV['HARNESS_STEP_DISPLAY'] = original
      end
    end
  end

  describe '#execute_tool_call spinner_detail (issue #40)' do
    let(:harness) { build_harness }
    let(:task) { Task.new { } }
    def drain_outbox(t)
      ms = []
      loop do
        m = t.poll(0); break unless m
        ms << m
      end
      ms
    end
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

    it 'does NOT emit :spinner_detail for a tool being executed' do
      harness.tool_registry.register(fake_tool)
      call  = { id: 'c1', function: { name: 'ui.notify', arguments: '{}' } }

      expect(harness.send(:execute_tool_call, call)).to eq('ok')

      expect(drain_outbox(task).map { |m| m[:type] }).not_to include(:spinner_detail)
    end

    it 'does not emit spinner_detail for an unknown tool' do
      call = { id: 'c1', function: { name: 'nope.missing', arguments: '{}' } }

      expect(harness.send(:execute_tool_call, call)).to include('unknown tool')

      expect(drain_outbox(task).map { |m| m[:type] }).not_to include(:spinner_detail)
    end
  end

  describe '#record_note (issue #138)' do
    def note_call(text)
      { id: 'c1', function: { name: 'ui.note', arguments: JSON.dump(text: text) } }
    end

    it 'buffers the note when a ui.note call succeeds' do
      harness = build_harness

      harness.record_note(note_call('granted read on lib/'), 'ok: noted 19 chars')

      expect(harness.session.instance_variable_get(:@notes))
        .to eq(['granted read on lib/'])
    end

    it 'does not buffer anything for a different tool' do
      harness = build_harness

      call = { id: 'c1', function: { name: 'file.read', arguments: '{}' } }
      harness.record_note(call, 'ok: noted 19 chars')

      expect(harness.session.instance_variable_get(:@notes)).to be_nil
    end

    it 'does not buffer anything when the ui.note call failed' do
      harness = build_harness

      harness.record_note(note_call('should not appear'), 'error: empty note')

      expect(harness.session.instance_variable_get(:@notes)).to be_nil
    end

    it 'survives a malformed arguments payload without raising' do
      harness = build_harness

      call = { id: 'c1', function: { name: 'ui.note', arguments: '{not json' } }

      expect { harness.record_note(call, 'ok: noted 5 chars') }.not_to raise_error
      expect(harness.session.instance_variable_get(:@notes)).to be_nil
    end

    it 'does not buffer anything when the result is not a string' do
      harness = build_harness

      harness.record_note(note_call('nope'), nil)

      expect(harness.session.instance_variable_get(:@notes)).to be_nil
    end
  end

  describe '#user_note / call_llm mid-turn note injection (issue #36)' do
    # Fake LLM client: records every message chain it is called with and
    # answers each call with a final (no tool calls) response.
    class FakeLLMClient
      attr_reader :calls

      def initialize
        @calls = []
      end

      def chat(messages, tools: nil)
        @calls << messages.map { |m| m.dup }
        { choices: [{ message: { content: 'done', reasoning: nil } }],
          usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } }
      end
    end

    let(:harness) do
      h = build_harness
      h.instance_variable_set(:@client, FakeLLMClient.new)
      h
    end

    it 'injects a pending note into the chain before the next LLM call' do
      harness.session.add_user('original prompt')
      harness.user_note_text = 'steer left'

      harness.call_llm

      sent = harness.client.calls.first
      expect(sent.last).to eq({ role: 'user', content: 'User note (mid-turn): steer left' })
    end

    it 'tracks injected notes on #user_notes and clears the pending slot' do
      harness.session.add_user('original prompt')
      harness.user_note_text = 'steer left'

      harness.call_llm

      expect(harness.user_notes).to eq(['steer left'])
      # The slot is consumed: a second turn injects nothing new.
      harness.session.add_user('next prompt')
      harness.call_llm

      second = harness.client.calls.last
      expect(second.map { |m| m[:content].to_s }).not_to include('User note (mid-turn): steer left')
    end

    it 'ignores blank notes (the setter clears the slot)' do
      harness.user_note_text = '   '

      harness.session.add_user('original prompt')
      harness.call_llm

      sent = harness.client.calls.first
      expect(sent.map { |m| m[:content].to_s }).not_to include('User note (mid-turn):')
      expect(harness.user_notes).to be_empty
    end
  end
end
