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

  # Fake LLM client shared by the call_llm coverage below: records every
  # message chain it is called with and answers from a SCRIPTED queue.
  # Each item is either a tool round (a hash with :tool_calls), a final
  # answer ({ content: }), or :fail (raises LLMError - simulating a lost
  # connection mid-turn, issue #208). Anything left in the queue at the end
  # defaults to a final 'done' answer.
  class FakeScriptedClient
    attr_reader :calls

    def initialize(responses = [{ content: 'done', reasoning: nil }])
      @calls     = []
      @responses = responses
    end

    def chat(messages, tools: nil, timeout: nil)
      @calls << messages.map { |m| m.dup }
      response = @responses.shift || { content: 'done' }
      raise LLMError, 'connection lost mid-turn' if response == :fail

      message = response.is_a?(Hash) ? response : { content: 'done' }
      { choices: [{ message: message.merge(reasoning: nil) }],
        usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } }
    end
  end

  def build_harness(options = {})
    file_list = FileList.new([], workdir: workdir)
    # system_file points at the built-in default so the base prompt file is
    # resolved (issue #223); num_ctx fixed so context indicators are stable.
    opts      = { system_file: Harness::DEFAULT_SYSTEM_PROMPT_FILE,
                  num_ctx: 65_536 }.merge(options)
    # session_id / resume_data are constructor keywords (issue #276: the id is
    # settled before the Harness exists), not LLM options, so they are pulled
    # out of the options hash and passed where they belong.
    session_id  = opts.delete(:session_id)
    resume_data = opts.delete(:resume_data)
    described_class.new(opts, file_list, session_id: session_id, resume_data: resume_data)
  end

  # The on-disk path of a session id in this spec's workdir (#207 layout).
  def session_path(id, name = SessionLocator::SESSION_LOG_FILE)
    File.join(workdir, SessionLocator::SESSIONS_DIR, id, name)
  end

  def saved_session_ids
    Dir.children(File.join(workdir, SessionLocator::SESSIONS_DIR))
  end

  # A harness whose client plays a scripted response sequence (see
  # FakeScriptedClient) - the call_llm specs below use it to drive multi-
  # round tool loops and mid-loop failures.
  def build_harness_with_responses(responses = [{ content: 'done', reasoning: nil }])
    h = build_harness
    h.instance_variable_set(:@client, FakeScriptedClient.new(responses))
    h
  end

  def seed_usage(harness, prompt_tokens)
    harness.session.add_user('hello')
    harness.session.add_assistant('hi')
    harness.session.record_stats(usage: { prompt_tokens: prompt_tokens, total_tokens: prompt_tokens + 867 })
  end

  def drained_lines(task)
    lines = []
    loop do
      m = task.poll(0); break unless m
      lines << m[:content]
    end
    lines
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

    # Issue #271: this is the SPINNER's segment - the percentage and the
    # window it is a percentage of, not the token arithmetic (which
    # #context_indicator and the /ctx report keep).
    it 'shows the percentage and the rounded window when usage was reported' do
      harness = build_harness
      seed_usage(harness, 5_915)

      expect(harness.context_indicator_live).to eq('🧠 9% (66K)')
    end

    it 'marks estimates with ~ when no usage was reported yet' do
      harness = build_harness
      harness.session.add_user('a' * 160)

      expect(harness.context_indicator_live).to include('~')
    end

    it 'always estimates an explicit chain (mid-turn / in-loop compaction)' do
      harness = build_harness_with_responses
      seed_usage(harness, 5_915)
      # seed_usage records stats only (no anchor), and this explicit chain
      # is not an extension of the session chain, so this is a plain raw
      # estimate - always marked '~' regardless of last_stats.
      chain = [{ role: 'user', content: 'a' * 400 }]

      expect(harness.context_indicator_live(chain)).to include('~')
    end
    # issue #216: after a turn, the server-reported prompt_tokens anchor the
    # live estimate, so a mid-turn chain that EXTENDS the session chain
    # shows the true number + new messages - not a from-scratch chars/4
    # re-estimate of the whole chain (which was wildly different).
    it 'anchors the live estimate to the server-reported count after a turn' do
      harness = build_harness_with_responses
      harness.session.add_user('hello')
      harness.call_llm # scripted client reports prompt_tokens: 10 -> anchor

      # The session chain (system + user + assistant 'done') is anchored at
      # 10. Extend it with a mid-turn tool result and re-estimate.
      extended = harness.session.messages.dup
      extended << { role: 'tool', tool_call_id: 't1', content: 'x' * 2000 }

      line = harness.context_indicator_live(extended)
      expect(line).to include('~')
      # The segment must carry the ANCHORED count (511 tokens = 1% of
      # 65536), not the from-scratch chars/4 estimate of the whole chain,
      # which also measures the system prompt and reads several percent
      # higher.
      expect(harness.session.anchored_estimate(extended)).to eq(511)
      expect(line).to eq('🧠 ~1% (66K)')
    end

    # The window is only ever read as an order of magnitude, so a five-digit
    # one is rounded to whole thousands; sub-thousand windows stay exact.
    it 'rounds the window to K, keeping a small window exact' do
      wide = build_harness(num_ctx: 160_000)
      wide.session.record_stats(prompt_tokens: 19_514,
                               usage: { prompt_tokens: 19_514 })
      expect(wide.context_indicator_live).to eq('🧠 12% (160K)')

      tiny = build_harness(num_ctx: 10)
      tiny.session.record_stats(prompt_tokens: 10, usage: { prompt_tokens: 10 })
      expect(tiny.context_indicator_live).to eq('🧠 100% (10)')
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

    it 'creates the log file at the per-session path during #initialize' do
      harness = build_harness

      # issue #276: the id is settled BEFORE this object is built, so the
      # logger is built in #initialize - the file exists from construction
      # on, without anything having to ask for the logger first.
      expect(harness.logger).to be_a(Logger)
      expect(File.file?(harness.session_log_path)).to be true
    end

    it 'does not write to the legacy shared .harness/harness.log' do
      harness = build_harness
      harness.logger.info('per-session only')

      expect(File.exist?(File.join(workdir, Harness::HARNESS_DIR, 'harness.log'))).to be false
    end
  end

  # issue #276 replaced the #123 / #270 deferral machinery: the session id is
  # resolved before construction, so the logger and the client are built once,
  # under the id this run owns. There is no lazy accessor and no placeholder
  # a consumer could hold.
  describe '#initialize logger (issue #276)' do
    it 'has a real logger from #initialize on every path' do
      fresh  = build_harness
      resume = build_harness(session_id: 'f7931611-30b4-4b4b-aec6-f7083ef2942a')

      [fresh, resume].each do |harness|
        expect(harness.logger).to be_a(Logger)
        expect(harness.instance_variable_get(:@logger)).to be_a(Logger)
      end
    end

    it 'logs under the id it was given, not under a fresh random one' do
      id      = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      harness = build_harness(session_id: id)
      harness.logger.info('startup line')

      expect(harness.session.session_id).to eq(id)
      expect(File.read(harness.session_log_path)).to include('startup line')
      # Issue #123's throwaway-directory symptom is now structurally
      # impossible: there is no wrong id to log under.
      expect(saved_session_ids).to eq([id])
    end

    it 'gives the LLM client the real logger, never a placeholder' do
      harness = build_harness(auto_save: false, verbose: false)

      expect(harness.client.backend.logger).to equal(harness.logger)
    end

    it 'logs the first request without any lazy path running' do
      # The #270 failure shape, asserted against the real fix: the backend
      # logs on the first attempt of every request, and the logger it holds
      # is the one built at construction.
      harness = build_harness(auto_save: false, verbose: false,
                              base_url: 'http://127.0.0.1:1/v1', api: :openai,
                              retry_count: 1, retry_delay: 0)

      # Port 1: nothing listens. The request fails on connect, but only AFTER
      # the backend has logged its attempt - that log line is the point.
      expect {
        harness.client.chat([{ role: 'user', content: 'hi' }])
      }.to raise_error(LLMError)

      log = File.read(harness.session_log_path)
      expect(log).to include('REQ: POST').and include('attempt 1/')
    end
  end

  # issue #276 / #280: a resumed run - startup OR mid-run /resume - is one
  # Harness built under the settled id, so log, history and session dir all
  # carry that single identity and no rebind exists anywhere.
  describe 'startup resume via resume_data (issue #276)' do
    def seed_saved_session(id, yolo: true)
      FileUtils.mkdir_p(File.dirname(session_path(id, SessionLocator::SESSION_FILE)))
      data = {
        session_id:    id,
        created_at:    Time.now.iso8601,
        system_prompt: 'saved prompt',
        user_prompts:  2,
        messages:      [{ role: 'system', content: 'saved prompt' },
                        { role: 'user', content: 'earlier' },
                        { role: 'assistant', content: 'reply' }],
        yolo:          yolo,
        workdir:       workdir
      }
      File.write(session_path(id, SessionLocator::SESSION_FILE), JSON.generate(data))
    end

    def saved_data(id)
      JSON.parse(File.read(session_path(id, SessionLocator::SESSION_FILE)),
                 symbolize_names: true)
    end

    it 'restores the conversation and the YOLO posture under the settled id' do
      id = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session(id, yolo: true)

      harness = build_harness(session_id: id, resume_data: saved_data(id))

      expect(harness.session.session_id).to eq(id)
      expect(harness.session.messages.map { |m| m[:content] }).to include('earlier')
      # The posture the session was saved with wins over the config initial
      # posture (#221 rule), and it is applied DURING construction - not by a
      # later resume call that would then need a logger rebind.
      expect(harness.yolo?).to be(true)
      expect(harness.logger).to be_a(Logger)
      expect(harness.session_log_path).to include(id)
      # Only the resumed session's directory exists (issues #123 / #135).
      expect(saved_session_ids).to eq([id])
    end

    it 'refuses a session file whose stored id is not the one it lives under' do
      id = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session(id)
      data = saved_data(id)
      data[:session_id] = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'

      # The logger and the history file were already built under the settled
      # id, so silently adopting the file's id would split this run's state
      # across two session directories.
      expect { build_harness(session_id: id, resume_data: data) }
        .to raise_error(HarnessError, /says id a{8}-bbbb-cccc-dddd-eeeeeeeeeeee/)
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

      expect(lines).to include('||| checking the test suite |||')
      expect(lines).to include('    -> run.command')
    end

    it 'prints only the tool line when there is no reasoning text at all' do
      msg = { reasoning: nil, content: nil, tool_calls: [{ id: 'c1', function: { name: 'file.search' } }] }

      harness.send(:print_step_display, 4, msg)
      lines = drained_lines

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

    # issue #257: the tool result goes straight back into the message chain,
    # so an undecodable byte in it made the next JSON.generate (the request
    # body AND the session save) raise JSON::GeneratorError - and the failure
    # was invisible because the save that should record it died on the same
    # byte. execute_tool_call normalizes what enters the chain.
    it 'normalizes a tool result that carries an invalid byte' do
      harness = build_harness
      bad = [0xE2, 0x90].pack('C*').force_encoding(Encoding::UTF_8)

      raw_tool = Class.new(Tool) do
        define_method(:execute) { |_args| bad }
      end.new(name: 'ui.notify', description: 'fake', parameters: {})
      harness.tool_registry.register(raw_tool)

      result = harness.send(:execute_tool_call,
                            { id: 'c1', function: { name: 'ui.notify', arguments: '{}' } })
      expect(result.valid_encoding?).to be true
      expect(result).to eq('?')
      # What the session save (JSON.generate) choked on before the fix.
      expect { JSON.generate({ 'content' => bad }) }.to raise_error(JSON::GeneratorError)
      expect { JSON.generate({ 'content' => result }) }.not_to raise_error
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
    let(:harness) { build_harness_with_responses }

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
      # issue #208: the note committed into the SESSION directly (it is in
      # the chain now), and a second turn sends that chain - nothing is
      # replayed or double-appended.
      expect(harness.session.messages.map { |m| m[:content].to_s })
        .to include('User note (mid-turn): steer left')
      expect(harness.session.pending?).to be(false)
      harness.session.add_user('next prompt')
      harness.call_llm

      second = harness.client.calls.last
      notes = second.select { |m| m[:content].to_s == 'User note (mid-turn): steer left' }
      expect(notes.size).to eq(1)
    end

    it 'ignores blank notes (the setter clears the slot)' do
      harness.user_note_text = '   '

      harness.session.add_user('original prompt')
      harness.call_llm

      sent = harness.client.calls.first
      expect(sent.map { |m| m[:content].to_s }).not_to include('User note (mid-turn):')
      expect(harness.user_notes).to be_empty
    end

    it 'keeps only the LATEST pending note (single slot in flight)' do
      # The user corrects their course mid-turn: the second line replaces
      # the first, so the model sees only the latest steering.
      harness.session.add_user('original prompt')
      harness.user_note_text = 'use ruby'
      harness.user_note_text = 'no - use python'

      harness.call_llm

      sent = harness.client.calls.first
      # Restrict to user messages: the built-in system prompt itself
      # documents the "User note (mid-turn):" prefix, so a substring match
      # over the whole chain would also catch the system message.
      notes = sent.select { |m| m[:role] == 'user' && m[:content].to_s.include?('User note (mid-turn):') }
      expect(notes).to eq([{ role: 'user', content: 'User note (mid-turn): no - use python' }])
      expect(harness.user_notes).to eq(['no - use python'])
      expect(harness.session.pending?).to be(false) # final reply committed
    end

    it 'shows a console ack that the note was sent to the model (issue #198)' do
      task = Task.new { }
      old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task
      begin
        harness.session.add_user('original prompt')
        harness.user_note_text = 'steer left'
        harness.call_llm
      ensure
        Thread.current[:harness_task] = old_current
      end

      expect(drained_lines(task)).to include('  [note] sent to model')
    end

    it 'shows no "sent to model" ack when there is no note' do
      task = Task.new { }
      old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task
      begin
        harness.session.add_user('original prompt')
        harness.call_llm
      ensure
        Thread.current[:harness_task] = old_current
      end

      expect(drained_lines(task)).not_to include('  [note] sent to model')
    end
  end

  describe '#read_system_prompt (issue #223)' do
    it 'reads the built-in default file when no system_file option is set' do
      harness = build_harness(system_file: nil)

      expect(harness.send(:read_system_prompt))
        .to eq(File.read(Harness::DEFAULT_SYSTEM_PROMPT_FILE))
    end

    it 'reads the configured system_file when it exists' do
      path = File.join(workdir, 'my_prompt.txt')
      File.write(path, "custom prompt #{path}")
      harness = build_harness(system_file: path)

      expect(harness.send(:read_system_prompt)).to eq("custom prompt #{path}")
    end

    it 'falls back to the built-in default when the configured file is missing' do
      harness = build_harness(system_file: File.join(workdir, 'does_not_exist.txt'))

      expect(harness.send(:read_system_prompt))
        .to eq(File.read(Harness::DEFAULT_SYSTEM_PROMPT_FILE))
    end
  end

  describe '#format_elapsed (issue #226)' do
    it 'returns seconds with 2dp when under 60s' do
      expect(build_harness.format_elapsed(42.37)).to eq('42.37s')
    end

    it 'returns a bare integer seconds value' do
      expect(build_harness.format_elapsed(5)).to eq('5.0s')
    end

    it 'returns minutes + seconds (comma decimal) at 60s and above' do
      expect(build_harness.format_elapsed(60.0)).to eq('1m 00,00s')
    end

    it 'handles the canonical 5099.17s from issue #226' do
      expect(build_harness.format_elapsed(5099.17)).to eq('84m 59,17s')
    end

    it 'rounds the sub-minute remainder to 2dp' do
      expect(build_harness.format_elapsed(61.004)).to eq('1m 01,00s')
    end
  end

  describe '#max_tool_iterations (issue #226)' do
    it 'defaults to 200 when the option is not set' do
      expect(build_harness.max_tool_iterations).to eq(200)
    end

    it 'reads from options when set' do
      expect(build_harness(max_tool_iterations: 50).max_tool_iterations).to eq(50)
    end

    it 'raises ToolLoopError once the configurable limit is exceeded' do
      # The scripted client plays endless tool rounds; with a limit of 2 the
      # loop is aborted before the third iteration.
      rounds = [
        { content: nil, tool_calls: [{ id: 'c1', function: { name: 'test.echo', arguments: '{"text":"a"}' } }] },
        { content: nil, tool_calls: [{ id: 'c2', function: { name: 'test.echo', arguments: '{"text":"b"}' } }] },
        { content: nil, tool_calls: [{ id: 'c3', function: { name: 'test.echo', arguments: '{"text":"c"}' } }] }
      ]
      harness = build_harness_with_responses(rounds)
      harness.options[:max_tool_iterations] = 2

      expect { harness.call_llm }.to raise_error(ToolLoopError, /exceeded max tool iterations \(2\)/)
    end
  end

  # issue #224 follow-up: the session-level command consent posture
  # (MANUAL / AUTO-APPROVE), toggled live with Ctrl+A and always visible
  # in the spinner via the mode badge.
  describe '#command_safety_auto_approve / mode label / toggle (issue #224 follow-up)' do
    it 'defaults to MANUAL when the option is absent' do
      harness = build_harness(command_safety_check: true)

      expect(harness.command_safety_auto_approve).to be(false)
      expect(harness.command_mode_label).to eq('MANUAL')
      expect(harness.command_safety_auto_approve_effective?).to be(false)
    end

    it 'starts in AUTO-APPROVE when the option is set (config default)' do
      harness = build_harness(command_safety_check: true,
                              command_safety_auto_approve: true)

      expect(harness.command_mode_label).to eq('AUTO-APPROVE')
      expect(harness.command_safety_auto_approve_effective?).to be(true)
    end

    it 'labels the posture MANUAL with the check off (issue #221 review)' do
      # The label is always present: with the check off nothing is
      # auto-approved, so the honest label is MANUAL - an empty spinner
      # badge read as "no posture", which is bug 2/3.
      harness = build_harness(command_safety_check: false,
                              command_safety_auto_approve: true)

      expect(harness.command_mode_label).to eq('MANUAL')
      expect(harness.command_safety_auto_approve_effective?).to be(false)
    end

    it 'toggle_command_mode flips the posture and returns the new label' do
      harness = build_harness(command_safety_check: true)

      expect(harness.toggle_command_mode).to eq('AUTO-APPROVE')
      expect(harness.command_mode_label).to eq('AUTO-APPROVE')

      expect(harness.toggle_command_mode).to eq('MANUAL')
      expect(harness.command_mode_label).to eq('MANUAL')
    end

    it 'AUTO-APPROVE is only labeled when the check is on' do
      # command_safety_auto_approve without command_safety_check auto-approves
      # nothing, so the posture label must say MANUAL, not AUTO-APPROVE.
      harness = build_harness(command_safety_check: false,
                              command_safety_auto_approve: true)

      expect(harness.command_mode_label).to eq('MANUAL')
    end

    it 'toggle_command_mode is a no-op (nil) when the check is off' do
      harness = build_harness(command_safety_check: false)

      expect(harness.toggle_command_mode).to be_nil
      expect(harness.command_safety_auto_approve).to be(false)
    end

    it 'coerces the setter to a boolean' do
      harness = build_harness(command_safety_check: true)
      harness.command_safety_auto_approve = 'yes'
      expect(harness.command_safety_auto_approve).to be(false)
      harness.command_safety_auto_approve = true
      expect(harness.command_safety_auto_approve).to be(true)
    end
  end

  # issue #221: the YOLO posture (the consent-fatigue fix). Like #224's
  # mode it is a USER-side consent switch (the model cannot turn it on) -
  # but unlike it, YOLO is persisted with the session (SessionManager
  # specs cover the round trip) and it wins over the AUTO-APPROVE/MANUAL
  # pair in the mode label (YOLO means no consent check at all).
  describe '#yolo? / toggle_yolo / mode label (issue #221)' do
    it 'defaults to off' do
      harness = build_harness

      expect(harness.yolo?).to be(false)
    end

    it 'starts ON when the yolo option is set (config initial posture)' do
      harness = build_harness(yolo: true)

      expect(harness.yolo?).to be(true)
      expect(harness.command_mode_label).to eq('YOLO')
    end

    it 'YOLO wins over AUTO-APPROVE / MANUAL in the mode label' do
      harness = build_harness(command_safety_check: true,
                              command_safety_auto_approve: true, yolo: true)

      expect(harness.command_mode_label).to eq('YOLO')
    end

    it 'YOLO keeps its label even with the safety check off' do
      harness = build_harness(command_safety_check: false, yolo: true)

      expect(harness.command_mode_label).to eq('YOLO')
    end

    it 'toggle_yolo flips the posture and returns the new label' do
      harness = build_harness

      expect(harness.toggle_yolo).to eq('YOLO ON')
      expect(harness.yolo?).to be(true)
      expect(harness.toggle_yolo).to eq('YOLO OFF')
      expect(harness.yolo?).to be(false)
    end

    it 'coerces the setter to a boolean (truthy junk stays OFF)' do
      harness = build_harness

      harness.yolo = 'yes'
      expect(harness.yolo?).to be(false)
      harness.yolo = true
      expect(harness.yolo?).to be(true)
    end
  end

  # issue #208: the session is the working chain. When a turn dies mid-loop
  # (connection loss after the LLM answer of round N), every round already
  # made - assistant tool_calls AND tool results - must remain in the
  # SESSION, so /retry resumes from that exact point instead of replaying
  # the prompt from zero. Before this fix the trail lived only in a local
  # dup and was garbage-collected with the failed call.
  describe '#call_llm mid-loop failure keeps the tool trail (issue #208)' do
    def echo_tool_round
      { content: nil,
        tool_calls: [{ id: 'call_1', function: { name: 'test.echo', arguments: '{"text":"hi"}' } }] }
    end

    it 'keeps the assistant tool_calls and the tool result in the session' do
      harness = build_harness_with_responses([echo_tool_round, :fail])
      harness.session.add_user('implement feature X')

      expect { harness.call_llm }.to raise_error(LLMError, /connection lost/)

      messages = harness.session.messages
      expect(messages.map { |m| m[:role] }).to eq(%w[system user assistant tool])
      # The assistant message carries the exact tool_calls the model made.
      expect(messages[-2][:tool_calls].map { |tc| tc[:function][:name] }).to eq(['test.echo'])
      # The tool actually ran and its result committed too.
      expect(messages.last).to eq(role: 'tool', tool_call_id: 'call_1', content: 'hi')

      # The chain is now RESENDABLE from this point.
      expect(harness.session.pending?).to be(true)
    end

    it 'keeps only the pending prompt when the failure hits before any tool round' do
      harness = build_harness_with_responses([:fail])
      harness.session.add_user('implement feature X')

      expect { harness.call_llm }.to raise_error(LLMError)

      # Only the pending prompt remains - /retry re-sends it (old behavior).
      expect(harness.session.messages.map { |m| m[:role] }).to eq(%w[system user])
      expect(harness.session.pending?).to be(true)
    end

    it 'keeps a mid-turn steering note in the trail across the failure' do
      harness = build_harness_with_responses([echo_tool_round, :fail])
      harness.session.add_user('implement feature X')
      harness.user_note_text = 'fix the naming first'

      expect { harness.call_llm }.to raise_error(LLMError)

      contents = harness.session.messages.map { |m| m[:content].to_s }
      expect(contents).to include('User note (mid-turn): fix the naming first')
      expect(harness.session.pending?).to be(true)
    end
  end

  # Issue #283: call_llm emits the request line before every request, so a
  # re-point made by an earlier wait (an in-loop compaction) cannot stick for
  # the rest of the turn.
  describe '#call_llm spinner announcements (issue #283)' do
    let(:task) { Task.new { } }
    around do |example|
      @old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task
      example.run
    ensure
      Thread.current[:harness_task] = @old_current
    end

    def spinner_details
      events = []
      loop do
        m = task.poll(0)
        break unless m
        events << m[:content][:message] if m[:type] == :spinner_detail
      end
      events
    end

    # num_ctx 10: the scripted client's prompt_tokens (10) are over the
    # trigger and no headroom is reserved in such a small window.
    def loop_options
      { model: 'test-model', num_ctx: 10, compact_reserved: 0 }
    end

    def echo_round(id)
      { content: nil,
        tool_calls: [{ id: id,
                       function: { name: 'test.echo', arguments: '{"text":"x"}' } }] }
    end

    it 'announces the send line before each request of a tool loop' do
      h = build_harness(loop_options)
      h.instance_variable_set(:@client, FakeScriptedClient.new(
        [echo_round('c1'), { content: 'final' }]
      ))
      h.session.add_user('do the thing')

      h.call_llm

      expect(spinner_details).to eq(['Sending (test-model)'] * 2)
    end

    it 're-announces the send line after an in-loop compaction' do
      # Two tool rounds build a chain big enough to summarize, then the
      # threshold trips: iteration 3 first compacts (its own spinner line)
      # and then announces its own request.
      h = build_harness(loop_options)
      h.instance_variable_set(:@client, FakeScriptedClient.new(
        [echo_round('c1'), echo_round('c2'),
         { content: 'HANDOFF SUMMARY' }, { content: 'final' }]
      ))
      h.session.add_user('do the thing')

      h.call_llm

      details = spinner_details
      compact = details.index { |d| d.include?('Compacting session mid-task') }
      expect(compact).not_to be_nil
      # The turn's LAST spinner line is the new request, not the finished
      # compaction.
      expect(details.last).to eq('Sending (test-model)')
      expect(details[0, compact]).to all(eq('Sending (test-model)'))
    end
  end

  # issue #224: a tool batch with SEVERAL run.command calls is checked with
  # ONE forked LLM call (one verdict line per command) BEFORE the first
  # consent dialog. Advisory only; errors degrade to a verdict-less flow.
  describe '#precheck_batch_safety (issue #224)' do
    def run_command_calls(*commands)
      commands.each_with_index.map do |c, i|
        { id: "c#{i + 1}",
          function: { name: 'run.command',
                      arguments: JSON.dump(command: c) } }
      end
    end

    let(:harness) { build_harness(command_safety_check: true) }

    it 'is a no-op when the option is disabled' do
      off = build_harness(command_safety_check: false)
      expect(off.precheck_batch_safety(run_command_calls('a', 'b')))
        .to be_nil
    end

    it 'is a no-op for a batch with fewer than two run.command calls' do
      expect(harness.precheck_batch_safety(run_command_calls('echo hi')))
        .to be_nil
      expect(harness.options[:safety_verdicts]).to be_nil
    end

    it 'caches {command => verdict} in options when the batch has two or more' do
      client = instance_double('client')
      allow(client).to receive(:chat)
        .and_return({ choices: [{ message: { content:
          "safe: syntax check\nsafe: writes to tmp only" } }], usage: {} })
      harness.instance_variable_set(:@client, client)
      harness.session.add_user('go')

      verdicts = harness.precheck_batch_safety(
        run_command_calls('ruby -c lib/a.rb', 'bundle exec rspec'))

      expect(verdicts).to eq('ruby -c lib/a.rb' => 'safe: syntax check',
                             'bundle exec rspec' => 'safe: writes to tmp only')
      expect(harness.options[:safety_verdicts]).to eq(verdicts)
    end

    it 'sends one check request without tools, forked from the live chain' do
      client = instance_double('client')
      captured = []
      allow(client).to receive(:chat) do |chain, tools: nil, timeout: nil|
        captured << { chain: chain, tools: tools, timeout: timeout }
        { choices: [{ message: { content: "safe\nsafe" } }], usage: {} }
      end
      harness.instance_variable_set(:@client, client)
      harness.session.add_user('go')

      harness.precheck_batch_safety(
        run_command_calls('ruby -c lib/a.rb', 'bundle exec rspec'))

      expect(captured.size).to eq(1)
      expect(captured[0][:tools]).to be_nil
      expect(captured[0][:timeout]).to eq(SafetyCheck::DEFAULT_TIMEOUT)
      forked = captured[0][:chain]
      expect(forked.map { |m| m[:role] }).to eq(%w[system user user])
      expect(forked.last[:content]).to include('1. ruby -c lib/a.rb')
      expect(forked.last[:content]).to include('2. bundle exec rspec')
    end

    it 'returns nil (no verdicts) when the check call fails' do
      client = instance_double('client')
      allow(client).to receive(:chat).and_raise(LLMError, 'offline')
      harness.instance_variable_set(:@client, client)
      harness.session.add_user('go')

      expect(harness.precheck_batch_safety(
               run_command_calls('a', 'b'))).to be_nil
      expect(harness.options[:safety_verdicts]).to be_nil
    end

    # issue #241: allowlisted commands never reach a consent dialog (the
    # runner auto-approves them), so the model must not be asked about
    # them - only the unapproved commands are checked.
    def allowlist(*prefixes)
      FileUtils.mkdir_p(File.join(workdir, '.harness'))
      File.write(File.join(workdir, '.harness', 'allowed_commands.yml'),
                 YAML.dump(prefixes))
    end

    it 'skips allowlisted commands - only the unapproved ones are checked' do
      allowlist('ruby')
      client = instance_double('client')
      captured = []
      allow(client).to receive(:chat) do |chain, **|
        captured << chain
        { choices: [{ message: { content: "safe: tests\nsafe: git only" } }], usage: {} }
      end
      harness.instance_variable_set(:@client, client)
      harness.session.add_user('go')

      verdicts = harness.precheck_batch_safety(
        run_command_calls('ruby -c lib/a.rb', 'bundle exec rspec', 'git status'))

      expect(verdicts).to eq('bundle exec rspec' => 'safe: tests',
                             'git status' => 'safe: git only')
      expect(captured.size).to eq(1)
      expect(captured.first.last[:content]).to include('1. bundle exec rspec')
      expect(captured.first.last[:content]).to include('2. git status')
      expect(captured.first.last[:content]).not_to include('ruby -c lib/a.rb')
    end

    it 'makes no model call when every command in the batch is allowlisted' do
      allowlist('ruby', 'bundle exec rspec')
      client = instance_double('client')
      allow(client).to receive(:chat)
      harness.instance_variable_set(:@client, client)
      harness.session.add_user('go')

      expect(harness.precheck_batch_safety(
               run_command_calls('ruby -c lib/a.rb', 'bundle exec rspec'))).to be_nil
      expect(client).not_to have_received(:chat)
    end

    it 'makes no batch call when only one command is left after filtering' do
      allowlist('ruby')
      client = instance_double('client')
      allow(client).to receive(:chat)
      harness.instance_variable_set(:@client, client)
      harness.session.add_user('go')

      expect(harness.precheck_batch_safety(
               run_command_calls('ruby -c lib/a.rb', 'ruby -c lib/b.rb',
                                 'bundle exec rspec'))).to be_nil
      expect(client).not_to have_received(:chat)
    end
  end
end
