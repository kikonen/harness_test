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
    # Mirrors LLMClient#chat: the caller decides per request whether the
    # response streams (issue #28), so the streaming kwargs are accepted.
    # @calls records the chain; @stream_flags / @on_deltas record what each
    # request was given, so a spec can assert WHICH posture was used.
    attr_reader :calls, :stream_flags, :on_deltas

    # Optional hook run after each call, so a spec can change harness state
    # BETWEEN the requests of one turn (e.g. a mid-turn /stream toggle).
    attr_accessor :after_call

    def initialize(responses = [{ content: 'done', reasoning: nil }])
      @calls        = []
      @stream_flags = []
      @on_deltas    = []
      @responses = responses
    end

    def chat(messages, tools: nil, timeout: nil, stream: false, on_delta: nil)
      @calls << messages.map { |m| m.dup }
      @stream_flags << stream
      @on_deltas   << on_delta
      response = @responses.shift || { content: 'done' }
      raise LLMError, 'connection lost mid-turn' if response == :fail

      message = response.is_a?(Hash) ? response : { content: 'done' }
      # finish_reason is a top-level part of the normalized shape (issue #345),
      # so a scripted response names it the way the backends return it.
      finish = message.is_a?(Hash) ? message.delete(:finish_reason) : nil
      result = { choices: [{ message: message.merge(reasoning: nil) }],
                 usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } }
      result[:finish_reason] = finish if finish
      # The hook runs AFTER the answer is built, so a spec can flip harness
      # state between this request and the next one of the same turn.
      @after_call&.call
      result
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
    def seed_saved_session(id, yolo: true, output_palette: 'basic16', stream: true)
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
        output_palette: output_palette,
        stream:        stream,
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

    # issue #28: the streaming posture the user chose for THIS session must
    # survive the round trip - a session they set to streamed must not come
    # back buffered (the same rule as the YOLO posture).
    it 'restores the streaming posture the session was saved with' do
      id = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session(id, stream: true)

      harness = build_harness(session_id: id, resume_data: saved_data(id))

      expect(harness.stream?).to be(true)
      expect(harness.stream_mode_label).to eq('STREAM')
    end

    # A session saved BEFORE streaming existed has no key at all: that is not
    # an error, it is the buffered default.
    it 'treats a session with no streaming key as buffered' do
      id = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session(id)
      data = saved_data(id)
      data.delete(:stream)

      harness = build_harness(session_id: id, resume_data: data)

      expect(harness.stream?).to be(false)
    end

    # issue #303: the palette the session was saved with is restored during
    # construction, like the YOLO posture - a session the user set to 'none'
    # must not come back colored.
    it 'restores the output palette the session was saved with' do
      id = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session(id, output_palette: 'none')

      harness = build_harness(session_id: id, resume_data: saved_data(id),
                              output_palette: 'default')

      expect(harness.output_palette.name).to eq('none')
    end

    it 'falls back to the default palette when the stored name no longer exists' do
      id = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session(id, output_palette: 'crayola')

      harness = build_harness(session_id: id, resume_data: saved_data(id))

      expect(harness.output_palette.name).to eq('default')
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
    # The roles print_step_display is allowed to emit (issue #146).
    let(:step_roles) { %i[step_label plan interstitial tool_plan] }
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

      # Content is the ROLE the emitter stated; the pattern ('step ',
      # 'plan:  ') belongs to UI::Renderer, so it is asserted here on the
      # rendered line (spec/lib/ui/renderer_spec.rb covers the labels).
      expect(lines).to include(3)
      expect(lines).to include('First I will inspect the spinner, then run the specs.')
      expect(lines).to include('file.read, run.command')
    end

    it 'falls back to message content when there is no reasoning' do
      msg = { reasoning: nil, content: 'checking the test suite', tool_calls: [{ id: 'c1', function: { name: 'run.command' } }] }

      harness.send(:print_step_display, 2, msg)
      lines = drained_lines

      expect(lines).to include('checking the test suite')
      expect(lines).to include('run.command')
    end

    it 'emits the reasoning digest and the interstitial as distinct roles' do
      harness.send(:print_step_display, 3, message)
      rendered = drain_outbox(task).map { |m| UI::Renderer.new.line(type: m[:type], content: m[:content]) }

      expect(rendered).to include('plan:  First I will inspect the spinner, then run the specs.')
      expect(rendered).not_to include(a_string_matching(/>>>/))
      expect(rendered).not_to include(a_string_matching(/\|\|\|/))
    end

    it 'prints only the tool line when there is no reasoning text at all' do
      msg = { reasoning: nil, content: nil, tool_calls: [{ id: 'c1', function: { name: 'file.search' } }] }

      harness.send(:print_step_display, 4, msg)
      lines = drained_lines

      expect(lines).to include('file.search')
    end

    it 'emits only the step roles - no spinner pause/resume (drain loop owns that)' do
      harness.send(:print_step_display, 1, message)

      types = drain_outbox(task).map { |m| m[:type] }
      expect(types - step_roles).to be_empty
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

    # issue #362: a wait is announced by whoever starts it, and the tool round
    # IS a wait (a slow command, a consent dialog). Without this re-point the
    # drain loop replays the LLM request line that already finished, so a
    # 40-second run.command reads as if the model were still generating.
    it 're-points the spinner with the tool name before the tool runs' do
      harness.tool_registry.register(fake_tool)
      call  = { id: 'c1', function: { name: 'ui.notify', arguments: '{}' } }

      expect(harness.send(:execute_tool_call, call)).to eq('ok')

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
      harness.tool_registry.register(fake_tool)
      long  = { id: 'c1', function: { name: 'ui.notify',
                                      arguments: JSON.dump(text: 'x' * 500) } }

      harness.send(:execute_tool_call, long)

      detail = drain_outbox(task).find { |m| m[:type] == :spinner_detail }
      expect(detail[:content][:message]).to eq('ui.notify')
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
      # issue #345: the drop is now visible. It used to rescue to nothing, so a
      # ui.note whose arguments never arrived was silently not buffered.
      expect(File.read(harness.session_log_path))
        .to include('ui.note arguments did not parse')
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

      # The ack is a STATUS event: content is the message, the bracket label
      # is the origin and UI::Renderer supplies the indent and the bracket.
      expect(drained_lines(task)).to include('sent to model')
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

      expect(drained_lines(task)).not_to include('sent to model')
    end
  end

  describe '#read_system_prompt (issue #223)' do
    it 'reads the built-in default file when no system_file option is set' do
      harness = build_harness(system_file: nil)

      expect(harness.send(:read_system_prompt))
        .to eq(File.read(Harness::DEFAULT_SYSTEM_PROMPT_FILE))
    end

    # issue #342: a prompt file is the first message of every chain, so it is a
    # read boundary. The assertion that catches the CLASS is the chain-level one
    # below it - a prompt-encoding assertion alone would still pass if the bad
    # string were rebuilt somewhere else.
    it 'normalizes a configured system_file whose bytes are not valid UTF-8' do
      path = File.join(workdir, 'sys.txt')
      File.binwrite(path, "You are a caf\xe9 helper\n")
      harness = build_harness(system_file: path)

      prompt = harness.send(:read_system_prompt)
      expect(prompt.valid_encoding?).to be(true)
      expect(harness.session.system_prompt.valid_encoding?).to be(true)
    end

    it 'keeps the session chain JSON-serializable after a damaged prompt file' do
      path = File.join(workdir, 'sys.txt')
      File.binwrite(path, "You are a caf\xe9 helper\n")
      harness = build_harness(system_file: path)
      harness.session.add_user('go')

      # JSON.generate is both the request body and the session save: this is
      # where the unnormalized read used to raise (JSON::GeneratorError).
      expect { JSON.generate(harness.session.messages) }.not_to raise_error
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

  # issue #341: harness.md is the file the harness is INVITED to edit, so a bad
  # byte is ordinary work, not an exotic input. Its content is the tail of the
  # FIRST message of every chain, so this read is a boundary too.
  describe '#build_system_prompt (issue #341)' do
    def damaged_rules(dir)
      File.binwrite(File.join(dir, 'harness.md'), "rule caf\xe9 keep 90 cols\n")
    end

    it 'builds a valid-UTF-8 prompt from a harness.md carrying an invalid byte' do
      damaged_rules(workdir)
      harness = build_harness
      prompt  = harness.session.system_prompt

      expect(prompt.valid_encoding?).to be(true)
      expect(prompt).to include('## Project-Specific Rules')
      # Asserted ON BYTES (the #318 rule): the undecodable one is the replacement.
      expect(prompt).to include('rule caf? keep 90 cols')
    end

    it 'names what it replaced, so the repair is not silent' do
      damaged_rules(workdir)
      harness = build_harness

      expect(harness.rules_repair_note)
        .to eq('1 invalid byte replaced - harness.md is not valid UTF-8')
    end

    it 'reports no repair for a clean harness.md' do
      File.write(File.join(workdir, 'harness.md'), "rule keep 90 cols\n")
      harness = build_harness

      expect(harness.rules_repair_note).to be_nil
      expect(harness.session.system_prompt).to include('rule keep 90 cols')
    end

    # The mid-session shape the issue calls WORSE: the file goes bad while the run
    # is live, so the failure surfaced on the NEXT prompt (run_prompt calls
    # check_rules_reload) or on /reload. utime keeps the mtime change deterministic.
    it 'survives a harness.md that turned invalid mid-session (reload path)' do
      File.write(File.join(workdir, 'harness.md'), "rule one\n")
      harness = build_harness
      damaged_rules(workdir)
      past = Time.now - 120
      File.utime(past, past, File.join(workdir, 'harness.md'))

      expect { harness.session_manager.check_rules_reload }.not_to raise_error
      expect(harness.session.system_prompt.valid_encoding?).to be(true)
      expect(harness.session.system_prompt).to include('rule caf? keep 90 cols')
      expect(harness.rules_repair_note).to include('1 invalid byte')
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

  # issue #303: the rendered-output palette is resolved once, at construction,
  # so the drain loop never re-resolves a name per line.
  describe '#output_palette (issue #303)' do
    it 'resolves to the default palette when the option is absent' do
      expect(build_harness.output_palette.name).to eq('default')
    end

    it 'resolves a configured name to that palette' do
      expect(build_harness(output_palette: 'basic16').output_palette.name).to eq('basic16')
      expect(build_harness(output_palette: 'none').output_palette.name).to eq('none')
    end

    it 'rejects an unknown name at construction, before any LLM call' do
      expect { build_harness(output_palette: 'crayola') }
        .to raise_error(HarnessError, /unknown output palette/)
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

      # Each request announces itself AND each tool round announces itself
      # (issue #362) - the two kinds alternate, and a request line always
      # follows the tool line of the round it produced.
      expect(spinner_details).to eq(['Sending (test-model)', 'test.echo',
                                     'Sending (test-model)'])
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
      # compaction, and every line BEFORE the compaction is a request line or
      # the tool line of the round that request produced (issue #362).
      expect(details.last).to eq('Sending (test-model)')
      expect(details[0, compact]).to eq(['Sending (test-model)', 'test.echo',
                                         'Sending (test-model)', 'test.echo'])
    end
  end

  # issue #251: the server-reported performance of a turn. Each request's
  # cache depth / durations describe only that request, so the turn keeps the
  # LAST request's measurement instead of summing measurements that were
  # never taken together.
  describe '#call_llm performance stats (issue #251)' do
    # A scripted client whose responses may carry their own usage.
    class PerformanceClient
      def initialize(responses)
        @responses = responses
      end

      def chat(_messages, tools: nil, timeout: nil, stream: false, on_delta: nil)
        @responses.shift
      end
    end

    def answer(usage)
      { choices: [{ message: { content: 'done', reasoning: nil } }], usage: }
    end

    def tool_round(id, usage)
      { choices: [{ message: { content: nil, reasoning: nil,
                              tool_calls: [{ id: id, function: { name: 'test.echo',
                                                                arguments: '{"text":"x"}' } }] } }],
        usage: }
    end

    def harness_with(usage)
      h = build_harness
      h.instance_variable_set(:@client, PerformanceClient.new([answer(usage)]))
      h.session.add_user('go')
      h.call_llm[:stats]
    end

    it 'reports no performance when the server sent none' do
      stats = harness_with({ prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 })

      expect(stats[:performance]).to be_nil
    end

    it 'keeps the LAST request\'s measurement, not a sum of them' do
      h = build_harness
      h.instance_variable_set(:@client, PerformanceClient.new([
        tool_round('c1', { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15,
                           cached_tokens: 100, eval_ms: 1000.0 }),
        answer({ prompt_tokens: 20, completion_tokens: 5, total_tokens: 25,
                 cached_tokens: 900, eval_ms: 200.0 })
      ]))
      h.session.add_user('go')

      stats = h.call_llm[:stats]

      # The core accounting still sums across the turn (it always did).
      expect(stats[:usage]).to eq(prompt_tokens: 30, completion_tokens: 10, total_tokens: 40)
      expect(stats[:performance]).to eq(
        cached_tokens: 900, eval_ms: 200.0, prompt_tokens: 20, completion_tokens: 5
      )
    end

    it 'shows the performance on the stats line' do
      stats = harness_with({ prompt_tokens: 1000, completion_tokens: 50, total_tokens: 1050,
                             cached_tokens: 768, prompt_eval_ms: 1160.0, eval_ms: 1310.2 })
      task = Task.new { }
      old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task
      begin
        build_harness.print_stats(stats)
      ensure
        Thread.current[:harness_task] = old_current
      end

      line = drained_lines(task).grep(/tokens \(/).first.to_s
      expect(line).to include('768 cached')
      expect(line).to include('prompt 200 tok/s')
      expect(line).to include('gen 38.2 tok/s')
    end
  end

  # issue #345: a response cut by the token budget is an EVENT, not a bad model
  # answer. The plumbing (finish_reason in the normalized shape) belongs to the
  # spec/lib/llm/ specs; this is what Harness#call_llm does with it.
  describe '#call_llm finish_reason (issue #345)' do
    let(:task) { Task.new { } }
    around do |example|
      @old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task
      example.run
    ensure
      Thread.current[:harness_task] = @old_current
    end

    def event_lines(t)
      drained_lines(t).grep(/token budget|finish reason/)
    end

    def truncated_round(id)
      { content: nil, finish_reason: 'length',
        tool_calls: [{ id: id,
                       function: { name: 'test.echo', arguments: '{"text":"x"}' } }] }
    end

    it 'says on the console and in harness.log that the budget cut the answer' do
      h = build_harness_with_responses([{ content: 'partial', finish_reason: 'length' }])
      h.session.add_user('go')

      h.call_llm

      line = event_lines(task).first.to_s
      expect(line).to include('cut off by the token budget (iteration 1')
      # The harness' own budget is named next to what the server reported.
      expect(line).to include('5 completion tokens')
      expect(line).to include('no token limit configured')
      expect(File.read(h.session_log_path)).to include('cut off by the token budget')
    end

    it 'names the configured limit when one is set' do
      h = build_harness_with_responses([{ content: 'partial', finish_reason: 'length' }])
      h.options[:max_tokens] = 4096
      h.session.add_user('go')

      h.call_llm

      expect(event_lines(task).first.to_s).to include('limit 4096')
    end

    %w[stop tool_calls].each do |reason|
      it "stays silent for the normal end '#{reason}'" do
        h = build_harness_with_responses([{ content: 'done', finish_reason: reason }])
        h.session.add_user('go')

        h.call_llm

        expect(event_lines(task)).to eq([])
      end
    end

    it 'warns about an unknown reason without calling it truncation' do
      h = build_harness_with_responses([{ content: 'done', finish_reason: 'content_filter' }])
      h.session.add_user('go')

      h.call_llm

      line = event_lines(task).first.to_s
      expect(line).to include("finish reason 'content_filter' (iteration 1)")
      expect(line).not_to include('token budget')
    end

    # A well-formed call from a cut round still runs: truncation is not a
    # reason to refuse a call that arrived complete. The model is told ONCE.
    it 'runs a truncated round whose calls arrived complete, and says so to the model' do
      h = build_harness_with_responses([truncated_round('c1'), { content: 'done' }])
      h.session.add_user('go')

      h.call_llm

      chain = h.session.messages
      expect(chain.find { |m| m[:role] == 'tool' }[:content]).to eq('x')
      told = chain.select do |m|
        m[:role] == 'user' && m[:content].to_s.include?('cut off by the token budget')
      end
      expect(told.size).to eq(1)
      expect(told.first[:content]).to include('Do NOT re-send the same call')
    end

    # THE point of the issue: a call whose arguments were cut mid-JSON must not
    # read as a malformed call (that is what #332's model kept retrying).
    it 'reports a cut-off call as truncation, not as a malformed call' do
      cut = truncated_round('c1')
      cut[:tool_calls][0][:function][:arguments] = '{"text":"x'
      h = build_harness_with_responses([cut, { content: 'done' }])
      h.session.add_user('go')

      h.call_llm

      result = h.session.messages.find { |m| m[:role] == 'tool' }[:content]
      expect(result).to include('cut off by the token budget')
      expect(result).to include('NOT executed')
      expect(result).not_to include('not valid JSON')
      expect(File.read(h.session_log_path)).to include('arguments did not parse')
    end

    # The same parse failure with NO truncation is still named as what it is.
    it 'names an un-truncated malformed call a malformed call' do
      bad = truncated_round('c1')
      bad.delete(:finish_reason)
      bad[:tool_calls][0][:function][:arguments] = '{"text":"x'
      h = build_harness_with_responses([bad, { content: 'done' }])
      h.session.add_user('go')

      h.call_llm

      expect(h.session.messages.find { |m| m[:role] == 'tool' }[:content])
        .to include('arguments are not valid JSON')
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

    # issue #344: the batch consumer binds by the number the model wrote, so an
    # out-of-order answer is still correct - and an answer that cannot be placed
    # caches NO verdicts (the runner then opens the dialog) instead of a shifted
    # set. The drop itself goes to harness.log.
    it 'binds batch verdicts by number, and caches none when the answer cannot be placed' do
      numbered = instance_double('client')
      allow(numbered).to receive(:chat).and_return({ choices: [{ message: { content:
        "2: dangerous: drops the table\n1: safe: syntax check" } }], usage: {} })
      harness.instance_variable_set(:@client, numbered)
      harness.session.add_user('go')

      expect(harness.precheck_batch_safety(run_command_calls('ruby -c a.rb', 'DROP TABLE x')))
        .to eq('ruby -c a.rb' => 'safe: syntax check', 'DROP TABLE x' => 'dangerous: drops the table')

      shifted = instance_double('client')
      allow(shifted).to receive(:chat).and_return({ choices: [{ message: { content:
        "Here are my verdicts:\nsafe: syntax check\ndangerous: drops the table" } }], usage: {} })
      harness.instance_variable_set(:@client, shifted)

      expect(harness.precheck_batch_safety(run_command_calls('ruby -c a.rb', 'DROP TABLE x')))
        .to eq('ruby -c a.rb' => nil, 'DROP TABLE x' => nil)
      expect(File.read(harness.session_log_path))
        .to include('safety check: line "Here are my verdicts:" carries no ' \
                    'safe:/dangerous: shape; 2 unnumbered verdict line(s) cannot be placed')
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

    # issue #332's candidate: a run.command whose arguments were cut mid-JSON
    # used to parse to {}, so the command vanished and a batch of two truncated
    # calls was safety pre-checked as ZERO commands. The skip must be visible.
    it 'logs a run.command whose arguments did not parse instead of dropping it' do
      calls = run_command_calls('ruby -c a.rb', 'rm -rf /tmp/x')
      calls[1][:function][:arguments] = '{"command":"rm -rf /tmp'

      expect(harness.run_command_batch_commands(calls)).to eq(['ruby -c a.rb'])
      expect(File.read(harness.session_log_path))
        .to include('run.command arguments did not parse')
    end

    # The whole point of the fix: a call whose arguments lost their shape must
    # not read as a malformed call when the request that made it was cut.
    it 'pre-checks a batch normally when every call parsed' do
      expect(harness.run_command_batch_commands(run_command_calls('a', 'b'))).to eq(%w[a b])
    end

    it 'an empty or missing arguments payload is not a parse error' do
      calls = [run_command_calls('a')[0], { id: 'c2', function: { name: 'run.command' } }]

      expect(harness.run_command_batch_commands(calls)).to eq(['a'])
      expect(File.read(harness.session_log_path)).not_to include('did not parse')
    end
  end

  # issue #28: the streaming posture. It decides whether a request's response
  # is consumed chunk by chunk, so it is harness state (like YOLO), not
  # conversation state - and it is read PER REQUEST, so /stream takes effect
  # on the next request of the same turn.
  describe '#stream? / mode label / toggle (issue #28)' do
    it 'defaults to buffered when the option is absent' do
      harness = build_harness

      expect(harness.stream?).to be(false)
      expect(harness.stream_mode_label).to be_nil
    end

    it 'starts streaming when the option is set (config key)' do
      harness = build_harness(stream: true)

      expect(harness.stream?).to be(true)
      expect(harness.stream_mode_label).to eq('STREAM')
    end

    it 'labels only the non-default posture (buffered gets no spinner tag)' do
      harness = build_harness
      harness.stream = true
      expect(harness.stream_mode_label).to eq('STREAM')

      harness.stream = false
      expect(harness.stream_mode_label).to be_nil
    end

    it 'toggle_stream flips the posture and returns the new label' do
      harness = build_harness

      expect(harness.toggle_stream).to eq('STREAM')
      expect(harness.stream?).to be(true)
      expect(harness.toggle_stream).to be_nil
      expect(harness.stream?).to be(false)
    end

    it 'coerces the setter to a boolean' do
      harness = build_harness
      harness.stream = 'yes'

      expect(harness.stream?).to be(false)
    end
  end

  describe '#call_llm streaming posture (issue #28)' do
    def scripted(harness, client)
      harness.instance_variable_set(:@client, client)
      harness.session.add_user('go')
      harness
    end

    def tool_round(id)
      { content: nil,
        tool_calls: [{ id: id,
                       function: { name: 'test.echo', arguments: '{"text":"x"}' } }] }
    end

    it 'asks for a buffered response when the posture is off' do
      client = FakeScriptedClient.new([{ content: 'final' }])
      h = scripted(build_harness, client)

      h.call_llm

      expect(client.stream_flags).to eq([false])
      expect(client.on_deltas).to eq([nil])
    end

    it 'asks for a streamed response and a delta callback when the posture is on' do
      client = FakeScriptedClient.new([{ content: 'final' }])
      h = scripted(build_harness(stream: true), client)

      h.call_llm

      expect(client.stream_flags).to eq([true])
      expect(client.on_deltas.first).to respond_to(:call)
    end

    # A mid-turn /stream toggle must apply to the NEXT request, not the one
    # already in flight: the posture is read inside the loop, once per
    # request. The client flips it after its FIRST call, so the second
    # request of the same turn must carry the new value.
    it 'reads the posture per request, so a toggle applies to the next one' do
      client = FakeScriptedClient.new([tool_round('c1'), { content: 'final' }])
      h = scripted(build_harness, client)
      client.after_call = -> { h.toggle_stream }

      h.call_llm

      expect(client.stream_flags).to eq([false, true])
    end

    # The live tail belongs to ONE request: an answer that already finished
    # must not leak into the next request's spinner line.
    it 'clears the live preview once a request ends' do
      client = FakeScriptedClient.new([{ content: 'final' }])
      h = scripted(build_harness(stream: true), client)

      h.call_llm

      expect(h.stream_preview_line).to be_nil
    end

    # The same clearing on the FAILURE path: a request that died mid-stream
    # would otherwise leave a partial answer's tail set, and the next request
    # (a /retry, or the next turn) would show text from an answer that never
    # completed.
    it 'clears the live preview when the request fails' do
      client = instance_double('client')
      # The block signature must accept every keyword the harness passes
      # (tools: too) - a narrow one raises ArgumentError inside the stub.
      allow(client).to receive(:chat) do |_messages, **kwargs|
        kwargs[:on_delta]&.call({ content: 'half an answer' })
        raise LLMError, "stream lost"
      end
      h = scripted(build_harness(stream: true), client)

      expect { h.call_llm }.to raise_error(LLMError, 'stream lost')
      expect(h.stream_preview_line).to be_nil
    end

    # The suffix callable the spinner evaluates every frame is the harness's,
    # so it is asserted DURING the request (the only moment a tail exists):
    # the client plays a delta, and the suffix the request announced reads it.
    it 'shows the newest streamed text in the spinner suffix while streaming' do
      h = build_harness(stream: true)
      seen = nil
      client = instance_double('client')
      allow(client).to receive(:chat) do |_messages, **kwargs|
        kwargs[:on_delta].call({ content: 'arriving text' })
        seen = h.request_wait_suffix.call
        { choices: [{ message: { content: 'arriving text' } }], usage: {} }
      end
      h.instance_variable_set(:@client, client)
      h.session.add_user('go')

      h.call_llm

      expect(seen).to eq('arriving text')
    end

    # issue #368: while a tool call streams, no text is arriving, so a line built
    # from the (frozen) tail reads as a dead connection. The phase names the tool.
    it 'names the tool call the model is writing instead of the frozen tail' do
      h = build_harness(stream: true)
      seen = nil
      client = instance_double('client')
      allow(client).to receive(:chat) do |_messages, **kwargs|
        kwargs[:on_delta].call({ content: 'I will write the file' })
        kwargs[:on_delta].call({ tool_call_names: ['file.write'] })
        # The argument fragment carries no name - the phase must still be known.
        kwargs[:on_delta].call({ tool_call_names: ['file.write'] })
        seen = h.request_wait_suffix.call
        { choices: [{ message: { content: 'I will write the file' } }], usage: {} }
      end
      h.instance_variable_set(:@client, client)
      h.session.add_user('go')

      h.call_llm

      expect(seen).to eq("writing tool call: file.write #{h.context_indicator_live}")
    end

    # The reason the phase line carries NO rate: no text is arriving to measure,
    # and a rate computed over that window decays frame by frame - the exact
    # "the connection is dying" reading the phase exists to replace.
    it 'shows no tok/s rate during the tool-call phase' do
      h = build_harness(stream: true)
      seen = nil
      client = instance_double('client')
      allow(client).to receive(:chat) do |_messages, **kwargs|
        kwargs[:on_delta].call({ content: 'x' * 80 })
        sleep 0.2
        kwargs[:on_delta].call({ content: 'y' * 80 })
        kwargs[:on_delta].call({ tool_call_names: ['file.write'] })
        sleep 0.5 # a real pause, so a rate WOULD have been measurable if shown
        seen = h.request_wait_suffix.call
        { choices: [{ message: { content: 'done' } }], usage: {} }
      end
      h.instance_variable_set(:@client, client)
      h.session.add_user('go')

      h.call_llm

      expect(seen).not_to include('tok/s')
      expect(seen).to start_with('writing tool call: file.write')
    end

    it 'falls back to the context estimate when nothing is streaming' do
      h = build_harness
      h.session.add_user('a' * 400)

      expect(h.request_wait_suffix.call).to eq(h.context_indicator_live)
    end
  end

  # issue #285: a tok/s rate on the spinner line. While a streamed answer is
  # arriving it is measured from the deltas themselves; for the waits where no
  # text has arrived yet (prefill, or a buffered request) it is the rate of the
  # request that last completed. Nothing is ever invented: with no measurement
  # the segment simply is not there.
  describe '#request_wait_suffix live rate (issue #285)' do
    # A client that answers instantly. The harness's own clock over an instant
    # call is under its noise floor, so a client-timed rate only appears when
    # the usage carries no server measurement AND the request took real time
    # (see the slow client below).
    def rate_client(usage)
      client = instance_double('client')
      allow(client).to receive(:chat)
        .and_return({ choices: [{ message: { content: 'done', reasoning: nil } }], usage: })
      client
    end

    def one_request(h)
      h.session.add_user('go')
      h.call_llm
      h
    end

    it 'shows no rate before any request has completed' do
      h = build_harness
      h.session.add_user('go')

      expect(h.last_rate_segment).to be_nil
      expect(h.request_wait_suffix.call).to eq(h.context_indicator_live)
    end

    # No conversation AND no completed request: the suffix resolves to NOTHING,
    # not an empty segment (the spinner's contract for "no suffix").
    it 'shows no suffix at all when there is nothing measured' do
      expect(build_harness.request_wait_suffix.call).to be_nil
    end

    it 'shows the server-reported rate of the request that just finished' do
      h = build_harness
      h.instance_variable_set(:@client, rate_client(
        { prompt_tokens: 1000, completion_tokens: 50, total_tokens: 1050,
          completion_tokens_per_second: 31.4 }
      ))
      one_request(h)

      # Server-measured, so NO '~'; tagged because it describes the PREVIOUS
      # request, not the one the spinner is currently waiting for.
      expect(h.last_rate_segment).to eq('31.4 tok/s (last)')
      expect(h.request_wait_suffix.call).to end_with('31.4 tok/s (last)')
    end

    it "marks a rate the harness timed itself with '~'" do
      h = build_harness
      # No server number at all: the harness's own seconds are the only source,
      # and they are measured over the whole request (prefill included), so the
      # number is labeled as not the server's.
      h.record_last_rate({ prompt_tokens: 500, completion_tokens: 100 }, 4.0)

      expect(h.last_rate_segment).to eq('~25 tok/s (last)')
    end

    it 'shows the newest text plus its live rate while an answer is streaming' do
      h = build_harness(stream: true)
      seen = nil
      client = instance_double('client')
      allow(client).to receive(:chat) do |_messages, **kwargs|
        # Two short deltas with a real gap between them: 25 characters is 7
        # estimated tokens over ~0.35s, just above the noise floor - and short
        # enough that the WHOLE answer fits the 60-char tail (no ellipsis).
        kwargs[:on_delta].call({ content: 'hello there ' })
        sleep 0.35
        kwargs[:on_delta].call({ content: 'arriving text' })
        seen = h.request_wait_suffix.call
        { choices: [{ message: { content: 'done' } }], usage: {} }
      end
      h.instance_variable_set(:@client, client)
      h.session.add_user('go')

      h.call_llm

      # The tail first, then the rate its own text arrived at ('~' because the
      # token count is estimated from characters), and no "(last)" tag: this
      # rate describes the request in flight.
      # The spinner number is the width-stable form (issue #364): one decimal
      # always, and a leading space under 100 - so the pattern allows the pad
      # column rather than assuming the measured rate happens to be wide.
      expect(seen).to match(/\Ahello there arriving text ~ ?\d+\.\d tok\/s\z/)
    end

    it 'shows only the tail while the text is too short to measure yet' do
      h = build_harness(stream: true)
      seen = nil
      client = instance_double('client')
      allow(client).to receive(:chat) do |_messages, **kwargs|
        kwargs[:on_delta].call({ content: 'hi' })
        seen = h.request_wait_suffix.call
        { choices: [{ message: { content: 'done' } }], usage: {} }
      end
      h.instance_variable_set(:@client, client)
      h.session.add_user('go')

      h.call_llm

      expect(seen).to eq('hi')
    end

    # A resumed session's saved per-request performance (#251) IS a server
    # measurement, so the recent rate is available on the FIRST request after
    # the resume - no request needed in this process first.
    it 'restores the recent rate from a saved session' do
      id = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      FileUtils.mkdir_p(File.dirname(session_path(id, SessionLocator::SESSION_FILE)))
      File.write(session_path(id, SessionLocator::SESSION_FILE), JSON.generate({
        session_id: id, created_at: Time.now.iso8601, system_prompt: 'saved prompt',
        messages: [{ role: 'system', content: 'saved prompt' },
                   { role: 'user', content: 'earlier' }],
        last_stats: { elapsed_seconds: 5.0, iterations: 1,
                      usage: { prompt_tokens: 1000, completion_tokens: 50 },
                      prompt_tokens: 1000,
                      performance: { completion_tokens_per_second: 27.8,
                                     completion_tokens: 50 } }
      }))
      data = JSON.parse(File.read(session_path(id, SessionLocator::SESSION_FILE)), symbolize_names: true)

      harness = build_harness(session_id: id, resume_data: data)

      expect(harness.last_rate_segment).to eq('27.8 tok/s (last)')
    end

    # A rate was measured against ONE server. /model points the run at another,
    # so keeping the number would show a speed that describes nothing this run
    # is about to do.
    it 'drops the recent rate when the model is switched' do
      h = build_harness(model_profiles: [
        { name: 'one', model: 'qwen', num_ctx: 65_536 },
        { name: 'two', model: 'llama', num_ctx: 32_768 }
      ])
      h.record_last_rate({ completion_tokens: 100, completion_tokens_per_second: 31.4 }, 4.0)
      expect(h.last_rate_segment).to eq('31.4 tok/s (last)')

      h.session_manager.switch_model('two')

      expect(h.last_rate_segment).to be_nil
      expect(h.request_wait_suffix.call).to eq(h.context_indicator_live)
    end

    # Issue #364: the number the SPINNER draws is width-stable (see
    # UsageStats.format_stable_rate), so a rate under 100 keeps its column and
    # a frame that changes the rate cannot shift the posture badge after it.
    # Only the spinner asks for it: a log line names the same rate unpadded.
    it 'pads the rate number on the spinner line, not in the log form' do
      h = build_harness
      h.record_last_rate({ completion_tokens: 20, completion_tokens_per_second: 9.0 }, 4.0)

      expect(h.last_rate_segment).to eq('9 tok/s (last)')
      expect(h.last_rate_segment(pad: true)).to eq(' 9.0 tok/s (last)')
      expect(h.request_wait_suffix.call).to end_with(' 9.0 tok/s (last)')
    end

    # A spinner suffix must never be an empty segment: the leading pad belongs
    # to the number, not to the separator the spinner adds before the suffix.
    it 'keeps the padded rate behind the context indicator on one line' do
      h = build_harness
      h.session.add_user('a' * 400)
      h.record_last_rate({ completion_tokens: 20, completion_tokens_per_second: 9.0 }, 4.0)

      expect(h.request_wait_suffix.call)
        .to eq("#{h.context_indicator_live}  9.0 tok/s (last)")
    end
  end

  describe '#skills (issue #12)' do
    # The loader is built from the workdir at construction, so the tools the
    # registry got and /skills read point at the SAME directory the harness owns.
    it 'points at .harness/skills under this run\'s workdir' do
      h = build_harness

      expect(h.skills.dir).to eq(File.join(workdir, '.harness', 'skills'))
      expect(h.skills.exist?).to be false
      expect(h.skills.all).to eq([])
    end

    it 'registers skills.list and skills.read over that same loader' do
      h = build_harness
      list = h.tool_registry.get('skills.list')
      read = h.tool_registry.get('skills.read')

      expect(list).not_to be_nil
      expect(read).not_to be_nil
      expect(list.instance_variable_get(:@skills)).to equal(h.skills)
      expect(read.instance_variable_get(:@skills)).to equal(h.skills)
      expect(h.skills.dir).to eq(File.join(workdir, '.harness', 'skills'))
    end
  end

  # Issue #10: the store is one reader (Memories) shared by memory.* and /memory,
  # and the harness hands that ONE object to every tool, so the two sides cannot
  # disagree about which notes exist.
  describe '#memories (issue #10)' do
    it 'points at .harness/memories under this run\'s workdir' do
      h = build_harness

      expect(h.memories.dir).to eq(File.join(workdir, '.harness', 'memories'))
      expect(h.memories.exist?).to be false
      expect(h.memories.all).to eq([])
    end

    it 'registers the four memory tools over that same store' do
      h = build_harness
      tools = %w[memory.list memory.read memory.add memory.delete].map { |n| h.tool_registry.get(n) }

      expect(tools.compact.size).to eq(4)
      tools.each do |tool|
        expect(tool.instance_variable_get(:@memories)).to equal(h.memories)
      end
    end

    # The store holds over SESSIONS, so it is NOT session state: it is never
    # serialized into session.json, and a note saved under one id is readable by
    # a harness built under a different id in the same workdir.
    it 'holds notes over a different session id in the same workdir' do
      first = build_harness
      first.tool_registry.get('memory.add').execute('name' => 'cross-session', 'text' => 'a fact')

      later = build_harness
      expect(later.session.session_id).not_to eq(first.session.session_id)
      expect(later.memories.body('cross-session')).to eq('a fact')
      expect(later.tool_registry.get('memory.read').execute('name' => 'cross-session')).to eq('a fact')
    end

    # A memory write is recorded in harness.log by the harness' own tool-call
    # line - the same record every other tool change gets, nothing extra to keep
    # in sync.
    it 'records a memory write in this session\'s harness.log' do
      h = build_harness
      h.send(:execute_tool_call, {
        id: 'c1',
        function: { name: 'memory.add', arguments: JSON.generate(name: 'logged-note', text: 'a fact') }
      })

      log = File.read(h.session_log_path)
      expect(log).to include("tool memory.add → ok: saved memory 'logged-note'")
      expect(h.memories.body('logged-note')).to eq('a fact')
    end
  end

  # Issue #33: web.fetch is the harness' only outbound network call outside the
  # LLM client, so its wiring is worth asserting: the tool must see THIS run's
  # options (the private-address key is a user posture) and THIS run's workdir
  # (that is where the host grants are saved).
  describe 'web.fetch (issue #33)' do
    it 'is registered in every run' do
      h = build_harness

      expect(h.tool_registry.get('web.fetch')).to be_a(Tools::WebFetchTool)
      expect(h.tool_registry.names).to include('web.fetch')
    end

    it 'reads this run\'s options and its FileList, not copies' do
      h = build_harness
      tool = h.tool_registry.get('web.fetch')

      expect(tool.instance_variable_get(:@options)).to equal(h.options)
      expect(tool.instance_variable_get(:@workdir)).to eq(workdir)
      expect(tool.instance_variable_get(:@harness)).to equal(h)
    end

    it 'refuses a private address with no config, whatever the model asks' do
      h = build_harness
      tool = h.tool_registry.get('web.fetch')

      # A literal IP: the guard decides it without DNS, so it is refused before
      # any consent (a dialog would raise here - no Task - and none is needed).
      out = tool.execute('url' => 'http://127.0.0.1:9/x')

      expect(out).to include('127.0.0.1 is a blocked address')
    end

    # The refusal is visible in this session's harness.log, like every other
    # tool verdict: a network call that never happened still leaves a trace.
    it 'records a refused fetch in this session\'s harness.log' do
      h = build_harness
      h.send(:execute_tool_call, {
        id: 'c1',
        function: { name: 'web.fetch', arguments: JSON.generate(url: 'http://127.0.0.1:9/x') }
      })

      log = File.read(h.session_log_path)
      expect(log).to include("tool web.fetch → error: 127.0.0.1 is a blocked address")
    end
  end
end
