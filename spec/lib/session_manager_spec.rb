# frozen_string_literal: true

require 'spec_helper'
require 'logger'
require 'stringio'
require 'param_overrides'
require 'ui/spinner'
require 'output_buffer'
require 'session_manager'
require 'fileutils'
require 'tmpdir'

# Regression coverage for issue #64: auto-compact must run BEFORE the LLM
# call (at the start of the next prompt), never after the response, where it
# would race with a pending dialog (ui.dialog / grant prompt) for stdin and
# swallow the user's answer as a cancel.
RSpec.describe SessionManager do
  let(:session) { Session.new('system prompt') }
  let(:file_list) { FileList.new([], workdir: Dir.pwd) }
  let(:logger) { Logger.new(File::NULL) }

  # A minimal stand-in for Harness providing only what SessionManager uses.
  # NOTE: in the post-refactor design the harness no longer owns a spinner
  # or an output buffer - both are owned by the running Task (see
  # lib/task.rb). SessionManager emits typed events onto the Task's outbox
  # (the single event queue) via `Task.emit`. Specs that assert on emitted
  # entries set `Thread.current[:harness_task]` to a Task instance and drain
  # its outbox; specs that drive the real drain loop go through `Task.run`.
  let(:harness) do
    Class.new do
      attr_accessor :session, :client, :history

      # issue #221: save/resume persists the YOLO consent posture, so the
      # stub mirrors Harness#yolo? / yolo=.
      attr_writer :yolo
      def yolo?; @yolo == true; end
      # issue #28: save/resume persists the streaming posture too.
      attr_writer :stream
      def stream?; @stream == true; end
      # issue #303: stub mirrors Harness#output_palette (save_session).
      def output_palette = UI::Palette.fetch(nil)
      # issue #359: build_user_prompt states the planning expectation when the
      # mode is on, so the stub mirrors Harness#plan? / plan=.
      attr_writer :plan
      def plan?; @plan == true; end

      def initialize(session, client)
        @session = session
        @client  = client
        @options = { num_ctx: 65_536, auto_save: false }
        @history = nil
        @logger  = Logger.new(File::NULL)
      end

      attr_reader :options, :logger

      def compact_recent_messages
        Session::COMPACT_RECENT_MESSAGES
      end

      def compact_auto_threshold
        Session::AUTO_COMPACT_THRESHOLD
      end

      # issue #151: default reserved headroom (the stub mirrors Harness).
      def compact_reserved_tokens
        Session::COMPACT_RESERVED_TOKENS
      end

      def compact_trigger_tokens
        @session.compact_trigger(@options[:num_ctx], compact_auto_threshold,
                                 reserved_tokens: compact_reserved_tokens)
      end

      def compact_max_size
        nil
      end

      # Mirrors Harness#tools_payload: the summary call sends the SAME tool
      # definitions the live turn sends (#246; doc/compaction_cache_design.md).
      def tools_payload
        [{ type: 'function', function: { name: 'test.echo' } }]
      end

      # Delegates to the (stubbed) client so the spec can record call order.
      def call_llm
        data = @client.chat(@session.messages)
        { reasoning: nil, content: 'ok', stats: {} }
      end

      def print_stats(_stats)
        # no-op in specs
      end

      # Mirrors Harness#context_indicator (the real one formats the same).
      def context_indicator
        used = @session.context_used
        return nil if used.nil?

        "🧠 ctx #{used[:estimated] ? '~' : ''}#{used[:tokens]}/#{@options[:num_ctx]} (0%)"
      end

      # Mirrors Harness#context_indicator_live (issue #126, compact form per
      # issue #271): estimates the current chain. The spinner calls this every
      # frame, so it must exist.
      def context_indicator_live(_messages = nil)
        '🧠 ~0% (66K)'
      end

      # Mirrors Harness#request_wait_suffix (issue #28): the spinner's suffix
      # is a callable the harness owns, because a streaming turn swaps it for
      # the live tail of the answer.
      def request_wait_suffix
        -> { context_indicator_live }
      end
    end.new(session, client)
  end

  let(:backend) { double('backend', api_type: :openai, endpoint_path: '/chat/completions') }
  let(:client) { double('client', chat: nil, backend: backend) }
  let(:manager) { described_class.new(harness, file_list) }

  # issue #217: the UI (/model, /models, startup banner) shows WHERE a call
  # goes via target_display - api type + endpoint path. This harness's stub
  # client has a backend because the spinner line names its api type (see the
  # #request_spinner_detail specs).
  describe '#target_display' do
    it 'shows the openai target' do
      expect(backend).to receive(:api_type).and_return(:openai)
      expect(backend).to receive(:endpoint_path).and_return('/chat/completions')

      expect(manager.target_display).to eq('openai /chat/completions')
    end

    it 'shows the ollama target' do
      allow(backend).to receive(:api_type).and_return(:ollama)
      allow(backend).to receive(:endpoint_path).and_return('/api/chat')

      expect(manager.target_display).to eq('ollama /api/chat')
    end
  end

  # Issue #283: the spinner line of an LLM request is one method with ONE
  # caller (Harness#call_llm, once per request). send_session no longer emits
  # it, so nothing can hold a stale message for the rest of a turn.
  describe '#request_spinner_detail (issue #283)' do
    def emitted_details
      task = Task.new { }
      old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task
      begin
        manager.request_spinner_detail
        events = []
        loop do
          m = task.poll(0)
          break unless m
          events << m
        end
        events
      ensure
        Thread.current[:harness_task] = old_current
      end
    end

    # Issue #271 compacted the line: the who sits in parentheses after the
    # verb and only the API TYPE is named (the endpoint path stays in
    # target_display for /model, /models and the startup banner).
    it 'emits exactly one spinner_detail with the model and the api type' do
      harness.options[:model] = 'qwen2.5-coder:32b'

      events = emitted_details

      expect(events.map { |e| e[:type] }).to eq([:spinner_detail])
      expect(events.first[:origin]).to eq(:session_manager)
      expect(events.first[:content][:message])
        .to eq('Sending (qwen2.5-coder:32b / openai)')
      expect(events.first[:content][:suffix]).to respond_to(:call)
    end

    it 'names the api type only when the client reports a backend' do
      harness.options[:model] = 'raw-model'
      harness.client = Class.new { def chat(*) = nil; }.new

      expect(emitted_details.first[:content][:message]).to eq('Sending (raw-model)')
    end

    it 'still emits a bare Sending line when no model is configured' do
      harness.options.delete(:model)

      expect(emitted_details.first[:content][:message])
        .to eq('Sending (openai)')
    end
  end

  # Simulate a session whose last response already used past the threshold.
  def make_session_over_threshold
    session.add_user('hello')
    session.add_assistant('hi there')
    session.add_user('more work')
    session.add_assistant('done with more work')
    session.record_stats(usage: { prompt_tokens: 60_000, total_tokens: 61_000 })
  end

  describe 'auto-compact ordering (issue #64)' do
    it 'compacts BEFORE the LLM call when the threshold is exceeded' do
      make_session_over_threshold
      order = []

      allow(manager).to receive(:compact_session) { order << :compact; { before: 5, after: 3 } }
      allow(client).to receive(:chat) { order << :llm_call }

      manager.run_prompt('next instruction')

      expect(order).to eq(%i[compact llm_call])
    end

    it 'never compacts AFTER the response (no race with a pending dialog)' do
      make_session_over_threshold
      order = []

      allow(manager).to receive(:compact_session) { order << :compact; { before: 5, after: 3 } }
      allow(client).to receive(:chat) { order << :llm_call }

      manager.run_prompt('next instruction')

      compact_idx = order.index(:compact)
      llm_idx     = order.index(:llm_call)
      expect(compact_idx).not_to be_nil
      expect(llm_idx).not_to be_nil
      expect(compact_idx).to be < llm_idx, 'auto-compact must run before the LLM call, not after'
    end

    it 'does not compact when the threshold is not exceeded' do
      session.add_user('hello')
      session.add_assistant('hi there')
      session.record_stats(usage: { prompt_tokens: 1_000, total_tokens: 1_500 })

      expect(client).to receive(:chat)
      expect(manager).not_to receive(:compact_session)

      manager.run_prompt('next instruction')
    end

    it 'still sends the prompt when auto-compact fails (best-effort)' do
      make_session_over_threshold
      allow(manager).to receive(:compact_session) { raise HarnessError, 'boom' }
      allow(client).to receive(:chat)

      expect { manager.run_prompt('next instruction') }.not_to raise_error
      expect(client).to have_received(:chat)
    end
  end

  describe 'resulting context size after compaction (issue #70)' do
    it 'reports the estimated context size after compaction' do
      session.add_user('hello')
      session.add_assistant('hi there')

      line = harness.context_indicator

      expect(line).to match(/\A🧠 ctx ~\d+\/65536 \(\d+%\)\z/)
    end

    it 'is nil when there is nothing to measure' do
      expect(harness.context_indicator).to be_nil
    end

    it 'is included in the compact_session result hash' do
      4.times { |i| session.add_user("msg #{i}"); session.add_assistant("reply #{i}") }
      allow(client).to receive(:chat) do
        { choices: [{ message: { content: 'summary text' } }] }
      end

      result = manager.compact_session
      expect(result[:context_line]).to match(/🧠 ctx ~\d+\/65536 \(\d+%\)/)
    end

  end

  # Both compact paths ask for the summary through #generate_compact_summary. A
  # prefix cache matches the RENDERED prompt from token 0 and a chat template
  # renders the tool definitions into it, so the request must be the live chain
  # plus its instruction AND the live turn's own tool payload: dropping either
  # half makes it a different prompt, not a longer one (issue #246; both axes are
  # measured by analysis/246/repro.rb, the reasoning is
  # doc/compaction_cache_design.md).
  describe '#generate_compact_summary (the call both compact paths make)' do
    it 'sends the FULL chain to the summary call, system message included' do
      4.times { |i| session.add_user("msg #{i}"); session.add_assistant("reply #{i}") }
      live_chain = session.messages.map(&:dup)

      captured = nil
      allow(client).to receive(:chat) do |msgs|
        captured = msgs
        { choices: [{ message: { content: 'summary text' } }] }
      end

      manager.compact_session

      expect(captured.first(live_chain.size)).to eq(live_chain)
      expect(captured.first[:role]).to eq('system')
      expect(captured.size).to eq(live_chain.size + 1)
      expect(captured.last[:role]).to eq('user')
    end
    it 'sends the live tools payload on the summary call' do
      4.times { |i| session.add_user("msg #{i}"); session.add_assistant("reply #{i}") }
      captured_tools = nil
      allow(client).to receive(:chat) do |_msgs, tools: nil|
        captured_tools = tools
        { choices: [{ message: { content: 'summary text' } }] }
      end

      manager.compact_session

      expect(captured_tools).to eq(harness.tools_payload)
    end

    # The fork now sends the live tool payload, so the model CAN answer a
    # summary request with a tool call. Nothing in a fork is executed (there is
    # no tool loop here), so the shape must be reported, not swallowed as an
    # "empty summary" - and never mistaken for a summary.
    it 'raises naming the tool call when the summary call answers with one' do
      4.times { |i| session.add_user("msg #{i}"); session.add_assistant("reply #{i}") }
      allow(client).to receive(:chat).and_return({
        choices: [{ message: { content: '',
                              tool_calls: [{ id: 'x1',
                                            function: { name: 'file.write', arguments: '{}' } }] } }]
      })

      expect { manager.compact_session }
        .to raise_error(HarnessError, /tool call \(file.write\) instead of a summary/)
      expect(session.messages.size).to eq(9) # nothing was compacted
    end

    it 'keeps a text answer that also carries tool calls, and logs the calls' do
      log_io = StringIO.new
      harness.instance_variable_set(:@logger, Logger.new(log_io))
      4.times { |i| session.add_user("msg #{i}"); session.add_assistant("reply #{i}") }
      allow(client).to receive(:chat).and_return({
        choices: [{ message: { content: 'REAL SUMMARY',
                              tool_calls: [{ id: 'x1',
                                            function: { name: 'ui.note', arguments: '{}' } }] } }]
      })

      result = manager.compact_session

      expect(result[:summary]).to eq('REAL SUMMARY')
      expect(log_io.string).to include('summary call returned tool calls (ui.note) - ignored')
    end

    it 'still reports the plain empty-summary error when no tool call came back' do
      4.times { |i| session.add_user("msg #{i}"); session.add_assistant("reply #{i}") }
      allow(client).to receive(:chat).and_return({ choices: [{ message: { content: '   ' } }] })

      expect { manager.compact_session }.to raise_error(HarnessError, /empty summary/)
    end
  end

  describe 'auto-save at prompt boundaries (issue #107)' do
    # Each spec builds its own manager bound to a tmp workdir so the auto-
    # save writes land in an isolated .harness/sessions/ and never in the
    # real project state.
    def with_tmp_manager(auto_save: true)
      Dir.mktmpdir do |dir|
        file_list = FileList.new([], workdir: dir)
        manager   = described_class.new(harness, file_list)
        harness.options[:auto_save] = auto_save
        yield manager, file_list, dir
      end
    end

    it 'does not save when auto_save is disabled' do
      with_tmp_manager(auto_save: false) do |manager, _, _|
        session.add_user('hello')
        expect(manager).not_to receive(:save_session)
        manager.maybe_auto_save('test')
      end
    end

    it 'does not save when the session is still empty' do
      with_tmp_manager do |manager, _, _|
        expect(manager).not_to receive(:save_session)
        manager.maybe_auto_save('test')
      end
    end

    it 'persists the session when auto_save is on and there is content' do
      with_tmp_manager do |manager, _, dir|
        session.add_user('hello')
        # issue #207: the JSON lives INSIDE the session's own directory.
        path = manager.session_file_path(session.session_id)
        expect(manager).to receive(:save_session).and_call_original
        expect { manager.maybe_auto_save('test') }.to change { File.file?(path) }.from(false).to(true)
      end
    end

    it 'de-duplicates saves within AUTOSAVE_MIN_INTERVAL' do
      with_tmp_manager do |manager, _, _|
        session.add_user('hello')
        expect(manager).to receive(:save_session).once.and_call_original
        manager.maybe_auto_save('first')
        manager.maybe_auto_save('second')
      end
    end

    it 'warns and continues when the save fails' do
      with_tmp_manager do |manager, _, _|
        session.add_user('hello')
        allow(manager).to receive(:save_session)
          .and_raise(Errno::EACCES, 'read-only file system')
        expect { manager.maybe_auto_save('test') }.not_to raise_error
      end
    end

  end

  # issue #207: the session JSON lives INSIDE the session's own directory
  # (.harness/sessions/<id>/session.json), alongside its log and history -
  # not as <id>.json next to the per-session dirs.
  describe 'session JSON in the session dir (issue #207)' do
    let(:sid) { 'f7931611-30b4-4b4b-aec6-f7083ef2942a' }

    def seed_saved_session(dir)
      sessions = File.join(dir, '.harness/sessions', sid)
      FileUtils.mkdir_p(sessions)
      saved = session.to_h(file_list)
      saved[:session_id] = sid
      File.write(File.join(sessions, 'session.json'), JSON.generate(saved))
      sessions
    end

    it '#session_file_path points inside the session dir' do
      Dir.mktmpdir do |dir|
        file_list = FileList.new([], workdir: dir)
        manager   = described_class.new(harness, file_list)

        expect(manager.session_file_path(sid))
          .to eq(File.join(dir, '.harness/sessions', sid, 'session.json'))
      end
    end

    it '#save_session writes into the session dir (no stray <id>.json)' do
      Dir.mktmpdir do |dir|
        file_list = FileList.new([], workdir: dir)
        manager   = described_class.new(harness, file_list)
        session.add_user('hello')

        expect(manager.save_session).to eq(session.session_id)

        path = manager.session_file_path(session.session_id)
        expect(File.file?(path)).to be true
        # The old layout's file must NOT appear next to the session dirs.
        expect(File.exist?(File.join(dir, '.harness/sessions', "#{session.session_id}.json")))
          .to be false
      end
    end
  end
  # issue #221: the YOLO consent posture travels with the session save
  # (like active_model / param_overrides - it is harness state, not
  # conversation state) and is written as a plain boolean, so a session saved
  # before the feature has no key. The RESUME side of the round trip is
  # Harness#apply_resume_state, covered in spec/lib/harness_spec.rb.
  describe 'YOLO posture round trip (issue #221)' do
    def save_with_yolo(dir, on)
      file_list = FileList.new([], workdir: dir)
      manager   = described_class.new(harness, file_list)
      harness.yolo = on
      session.add_user('hello')
      manager.save_session
      JSON.parse(File.read(manager.session_file_path(session.session_id)))
    end

    it 'saves the posture as a plain boolean' do
      Dir.mktmpdir do |dir|
        data = save_with_yolo(dir, true)
        expect(data['yolo']).to be(true)

        data = save_with_yolo(dir, false)
        expect(data['yolo']).to be(false)
      end
    end
  end

  # issue #303: the palette the user picked for this session travels with the
  # save too (same treatment as the posture). Stored as its NAME, not as a
  # color table, so the resume side can validate it against the palettes this
  # build has. RESUME side: Harness#apply_resume_state, in harness_spec.rb.
  describe 'output palette round trip (issue #303)' do
    it 'saves the palette name' do
      Dir.mktmpdir do |dir|
        file_list = FileList.new([], workdir: dir)
        manager   = described_class.new(harness, file_list)
        session.add_user('hello')
        manager.save_session
        data = JSON.parse(File.read(manager.session_file_path(session.session_id)))

        expect(data['output_palette']).to eq('default')
      end
    end
  end

  # issue #28: the streaming posture travels with the session save too (same
  # treatment as yolo - harness posture, not conversation state), as a plain
  # boolean so a session saved before the feature simply has no key. The
  # RESUME side is Harness#apply_resume_state, covered in harness_spec.rb.
  describe 'streaming posture round trip (issue #28)' do
    def save_with_stream(dir, on)
      file_list = FileList.new([], workdir: dir)
      manager   = described_class.new(harness, file_list)
      harness.stream = on
      session.add_user('hello')
      manager.save_session
      JSON.parse(File.read(manager.session_file_path(session.session_id)))
    end

    it 'saves the posture as a plain boolean' do
      Dir.mktmpdir do |dir|
        expect(save_with_stream(dir, true)['stream']).to be(true)
        expect(save_with_stream(dir, false)['stream']).to be(false)
      end
    end
  end
  # issue #359: the planning mode's whole value is that the MODEL knows the mode
  # is on and holds back from editing. build_user_prompt states the expectation
  # every turn while the mode is on, and says nothing when it is off.
  describe 'planning mode advisory channel (issue #359)' do
    it 'states the planning expectation in the prompt when the mode is on' do
      harness.plan = true
      prompt = manager.build_user_prompt('fix the bug')

      expect(prompt).to include('## Planning mode (advisory)')
      expect(prompt).to include('Planning mode is ON')
      expect(prompt).to include('Do not rush to edit files')
      # The real instruction still follows the advisory section.
      expect(prompt).to include("## Instruction\n\nfix the bug")
    end

    it 'states nothing about planning when the mode is off' do
      harness.plan = false
      prompt = manager.build_user_prompt('fix the bug')

      expect(prompt).not_to include('Planning mode')
    end
  end
end

RSpec.describe SessionManager, 'session-level param overrides (issue #219)' do
  let(:session) { Session.new('system prompt') }
  let(:file_list) { FileList.new([], workdir: Dir.pwd) }
  let(:backend) { double('backend', api_type: :openai, endpoint_path: '/chat/completions') }
  let(:client) { double('client', chat: nil, backend: backend) }
  let(:options) do
    {
      num_ctx: 65_536,
      auto_save: false,
      reasoning_effort: 'medium',
      model_profiles: [
        { name: 'local', model: 'qwen', reasoning_effort: 'medium', num_ctx: 65_536 }
      ],
      active_model: 'local'
    }
  end
  let(:harness) do
    Class.new do
      attr_accessor :session, :client, :history
      def initialize(session, client, options)
        @session = session
        @client  = client
        @options = options
        @logger  = Logger.new(File::NULL)
        @history = nil
      end
      attr_reader :options, :logger
      # issue #221: stub mirrors Harness#yolo? / yolo= (save/resume).
      attr_writer :yolo
      def yolo?; @yolo == true; end
      # issue #28: stub mirrors Harness#stream? / stream= (save/resume).
      attr_writer :stream
      def stream?; @stream == true; end
      # issue #303: stub mirrors Harness#output_palette (save_session).
      def output_palette = UI::Palette.fetch(nil)
      def compact_recent_messages; 6; end
      def compact_auto_threshold; 88; end
      def compact_reserved_tokens; 8192; end
      def compact_trigger_tokens
        @session.compact_trigger(@options[:num_ctx], compact_auto_threshold,
                                 reserved_tokens: compact_reserved_tokens)
      end
      def compact_max_size; nil; end
      def context_indicator; nil; end
      def context_indicator_live(_m = nil); nil; end
    end.new(session, client, options)
  end
  let(:manager) { described_class.new(harness, file_list) }

  it '#param_overrides is memoized (same instance across calls)' do
    expect(manager.param_overrides).to equal(manager.param_overrides)
  end
  it 'setting an override updates options immediately' do
    manager.param_overrides.set('reasoning_effort', 'low')
    expect(options[:reasoning_effort]).to eq('low')
  end

  it 're-applies overrides after a profile change (apply_profile)' do
    manager.param_overrides.set('reasoning_effort', 'low')
    # Simulate: profile resets the option, then restore! is called.
    options[:reasoning_effort] = 'medium'
    manager.param_overrides.restore!
    expect(options[:reasoning_effort]).to eq('low')
  end

  it 'save_session includes param_overrides in the JSON' do
    Dir.mktmpdir do |dir|
      fl = FileList.new([], workdir: dir)
      mgr = described_class.new(harness, fl)
      mgr.param_overrides.set('reasoning_effort', 'low')
      session.add_user('hello')
      mgr.save_session

      path = mgr.session_file_path(session.session_id)
      data = JSON.parse(File.read(path))
      expect(data['param_overrides']).to include('reasoning_effort')
    end
  end
end
RSpec.describe SessionManager, 'in-loop compaction (issue #108)' do
  let(:session) { Session.new('system prompt') }
  let(:file_list) { FileList.new([], workdir: Dir.pwd) }
  let(:backend) { double('backend', api_type: :openai, endpoint_path: '/chat/completions') }
  let(:client) { double('client', chat: nil, backend: backend) }
  let(:harness) do
    Class.new do
      attr_accessor :session, :client

      def initialize(session, client)
        @session = session
        @client  = client
        @options = { num_ctx: 1000, auto_save: false }
        @logger  = Logger.new(File::NULL)
      end

      attr_reader :options, :logger

      def compact_max_size
        nil
      end

      def compact_auto_threshold
        88
      end

      # issue #151: reserve larger than this tiny window -> percentage
      # trigger wins (880 tokens of the 1000 window).
      def compact_reserved_tokens
        Session::COMPACT_RESERVED_TOKENS
      end

      def compact_trigger_tokens
        @session.compact_trigger(@options[:num_ctx], compact_auto_threshold,
                                 reserved_tokens: compact_reserved_tokens)
      end

      def context_indicator
        nil
      end

      def tools_payload
        [{ type: 'function', function: { name: 'test.echo' } }]
      end

      # issue #126: the spinner calls this every frame (with the local chain).
      def context_indicator_live(_messages = nil)
        '🧠 ~0% (1K)'
      end
    end.new(session, client)
  end
  let(:manager) { described_class.new(harness, file_list) }

  # issue #208: with the session as the working chain, this IS the session's
  # own message array (there is no separate local copy to sync back).
  def inloop_messages
    [
      { role: 'system', content: 'system prompt' },
      { role: 'user', content: '## Instruction\n\nimplement feature X' },
      { role: 'assistant', content: nil,
        tool_calls: [{ id: 'call_1', function: { name: 'file.read', arguments: '{}' } }] },
      { role: 'tool', tool_call_id: 'call_1', content: 'sha256: abc\n---\nline 1' },
      { role: 'assistant', content: nil,
        tool_calls: [{ id: 'call_2', function: { name: 'file.patch', arguments: '{}' } }] },
      { role: 'tool', tool_call_id: 'call_2', content: 'ok: applied 1 hunk(s)' }
    ]
  end

  def allow_summary_response(text = 'Goal: implement feature X. Steps done: read and patch foo.rb. Next: run specs.')
    allow(client).to receive(:chat) { { choices: [{ message: { content: text } }] } }
  end

  it 'does nothing when the last prompt_tokens are below the threshold' do
    messages = inloop_messages
    expect(manager.check_inloop_compaction(messages, 400)).to be(false)
    expect(client).not_to have_received(:chat)
    expect(session.messages.size).to eq(1)
    expect(messages.size).to eq(6)
  end

  it 'does nothing when there is no real work to summarize yet' do
    small = [
      { role: 'system', content: 'system prompt' },
      { role: 'user', content: 'hello' },
      { role: 'assistant', content: 'hi' }
    ]
    expect(manager.check_inloop_compaction(small, 1000)).to be(false)
    expect(client).not_to have_received(:chat)
  end

  it 'summarizes the FULL chain, drops the verbatim tail, and syncs the session' do
    allow_summary_response
    messages = inloop_messages

    captured = nil
    allow(client).to receive(:chat) do |msgs|
      captured = msgs
      { choices: [{ message: { content: 'HANDOFF' } }] }
    end

    result = manager.check_inloop_compaction(messages, 1000)
    expect(result).to be(true)

    # The summarization call sees the ENTIRE working chain AS IS - the system
    # message included - plus the instruction prompt. A prompt-prefix cache
    # matches from token 0, so dropping message 0 here would make the call a
    # different prompt instead of a longer version of the one the server just
    # read, and it would re-prefill the whole chain cold (issue #246). The
    # mid-turn tool trail is already committed into the chain as it happened.
    expect(captured.size).to eq(inloop_messages.size + 1)
    expect(captured.first).to eq(inloop_messages.first)
    expect(captured.last[:content]).to match(/Keep it under \d+ words/)
    # The working chain is replaced with a compacted form - the tail
    # (last N messages) is deliberately NOT retained, because retaining it
    # here would drop the rest of the work trail from both the live chain
    # and the persisted session (issue #107).
    expect(messages.map { |m| m[:role] }).to eq(%w[system user assistant user])
  end

  it 'replaces the local working chain with [system, summary, ack, continue]' do
    allow_summary_response('HANDOFF TEXT')
    messages = inloop_messages

    # Record the pre-compaction stats so we can verify reset_stats was called.
    session.record_stats(prompt_tokens: 1000, usage: {})

    expect(manager.check_inloop_compaction(messages, 1000)).to be(true)

    expect(messages.map { |m| m[:role] }).to eq(%w[system user assistant user])
    expect(messages[1][:content]).to include('HANDOFF TEXT')
    expect(messages.last[:content]).to match(/do not repeat/i)
    # The session IS the working chain - the replace lands in place.
    expect(session.messages).to eq(messages)
    # Stale pre-compaction stats must be cleared, otherwise auto_compact_due?
    # would immediately trip again on the very tokens that caused compaction.
    expect(session.instance_variable_get(:@last_stats)).to be_nil
  end
  # issue #36 / #208: a mid-turn steering note is already a message in the
  # working chain (= the session's, since the session IS that chain), so the
  # summarization call must see it - no separate carry-over step anymore.
  it 'summarizes a mid-turn steering note that sits in the chain' do
    messages = inloop_messages
    messages << { role: 'user', content: 'User note (mid-turn): fix the naming first' }

    captured = nil
    allow(client).to receive(:chat) do |msgs|
      captured = msgs
      { choices: [{ message: { content: 'HANDOFF TEXT' } }] }
    end

    expect(manager.check_inloop_compaction(messages, 1000)).to be(true)
    expect(captured.map { |m| m[:content].to_s })
      .to include('User note (mid-turn): fix the naming first')
  end
  # The tools half of the same prefix, mid-turn: the summary request must carry
  # the payload the turn itself carried (analysis/246/repro.rb measures it as
  # "tools == the live turn's payload?").
  it 'sends the live tools payload on the in-loop summary call' do
    captured_tools = nil
    allow(client).to receive(:chat) do |_msgs, tools: nil|
      captured_tools = tools
      { choices: [{ message: { content: 'HANDOFF' } }] }
    end

    expect(manager.check_inloop_compaction(inloop_messages, 1000)).to be(true)
    expect(captured_tools).to eq(harness.tools_payload)
  end

  # A summary request that answers with a tool call instead of text is a FAILED
  # compaction, and a failed in-loop compaction must leave a healthy turn alone
  # (the chain keeps its full work trail; the next request simply runs).
  it 'returns false and keeps the chain when the summary call answers with a tool call' do
    messages = inloop_messages
    allow(client).to receive(:chat).and_return({
      choices: [{ message: { content: nil,
                            tool_calls: [{ id: 'x1',
                                          function: { name: 'file.read', arguments: '{}' } }] } }]
    })

    expect(manager.check_inloop_compaction(messages, 1000)).to be(false)
    expect(messages.map { |m| m[:role] }).to eq(%w[system user assistant tool assistant tool])
    expect(messages.first).to eq(inloop_messages.first)
    expect(session.messages.size).to eq(1) # untouched: nothing was compacted
  end

  # issue #116: in-loop compaction runs from INSIDE Harness#call_llm, so the
  # send_session wait is still animating. The runner owns the spinner and
  # always keeps one visible while it waits; SessionManager's only protocol
  # entry for that is a single :spinner_detail event (message + live suffix)
  # emitted BEFORE the blocking summary call - it re-points what the
  # already-visible spinner displays, no start/stop pair.
  describe 'outer spinner handling (issue #116, spinner_detail)' do
    def drain_outbox(task)
      events = []
      loop do
        msg = task.poll(0)
        break unless msg
        events << msg
      end
      events
    end

    it 'emits a single spinner_detail (message + live suffix), no start/stop pair' do
      allow_summary_response
      messages = inloop_messages

      # A Task instance (not started) provides the outbox for event capture.
      task = Task.new { }
      old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task

      begin
        result = manager.check_inloop_compaction(messages, 1000)
        types = drain_outbox(task).map { |m| m[:type] }

        expect(result).to be(true)
        # One info line, then exactly ONE detail event - no start/stop pair:
        # the runner's spinner is always visible while waiting and the detail
        # only re-points what it displays.
        expect(types).to eq(%i[compact spinner_detail])
      ensure
        Thread.current[:harness_task] = old_current
      end
    end

    it 'emits the same spinner_detail event even without an active wait context' do
      allow_summary_response
      messages = inloop_messages

      task = Task.new { }
      old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task
      begin
        result = manager.check_inloop_compaction(messages, 1000)
        types = drain_outbox(task).map { |m| m[:type] }

        expect(result).to be(true)
        expect(types).to eq(%i[compact spinner_detail])
      ensure
        Thread.current[:harness_task] = old_current
      end
    end
  end
end

# issue #131: the full reasoning and content of EVERY LLM response go to
# harness.log unconditionally (not gated on --verbose) - the log is the
# authoritative record of what the model said. Empty sections are labeled
# "(none)" instead of leaving blank "--- reasoning ---" blocks.
RSpec.describe SessionManager, '#log_response (issue #131)' do
  let(:harness) { double('harness', logger: Logger.new(File::NULL)) }
  let(:manager) { described_class.new(harness, FileList.new([], workdir: Dir.pwd)) }

  it 'logs the reasoning and content sections to harness.log' do
    expect(harness.logger).to receive(:info).with("--- reasoning ---\nlet me think...")
    expect(harness.logger).to receive(:info).with("--- response ---\nall done")

    manager.log_response(reasoning: 'let me think...', content: 'all done')
  end

  it 'labels empty sections as (none)' do
    expect(harness.logger).to receive(:info).with("--- reasoning ---\n(none)")
    expect(harness.logger).to receive(:info).with("--- response ---\nfinal answer")

    manager.log_response(reasoning: nil, content: 'final answer')
  end
end

# issue #139: compaction must log exactly which messages SURVIVED so the
# retained window is inspectable from harness.log instead of a guess.
RSpec.describe SessionManager, 'retained-window logging (issue #139)' do
  let(:log_io) { StringIO.new }
  let(:logger) { Logger.new(log_io) }

  describe '#compact_session (end-of-turn)' do
    let(:session) { Session.new('system prompt') }
    # issue #178: summary longer than the old ~80-char preview cut, so a
    # regression to truncated logging would fail this expectation.
    let(:long_summary) { 'x' * 120 }
    let(:client) { double('client', chat: { choices: [{ message: { content: long_summary } }] }) }
    let(:harness) do
      double('harness', session: session, client: client, logger: logger,
             compact_recent_messages: 2, compact_max_size: nil,
             tools_payload: nil,
             context_indicator: 'ctx 1/65536 (0%)')
    end
    let(:manager) { described_class.new(harness, FileList.new([], workdir: Dir.pwd)) }

    it 'logs the retained tail to harness.log' do
      4.times { |i| session.add_user("msg #{i}"); session.add_assistant("reply #{i}") }

      manager.compact_session

      # issue #178: each surviving message is logged as "role:\n<full content>".
      # The full post-compaction chain is dumped (summary first), so the
      # retained tail comes after the summary + ack messages.
      expect(log_io.string).to include(
        "user:\nmsg 3\nassistant:\nreply 3"
      )
      # issue #178: the summary itself is logged in full, not truncated.
      expect(log_io.string).to include("This is a summary of our previous conversation:\n\n#{long_summary}")
    end
  end

  describe '#check_inloop_compaction (mid-turn)' do
    let(:session) { Session.new('system prompt') }
    let(:client) { double('client', chat: { choices: [{ message: { content: 'HANDOFF' } }] }) }
    let(:options) { { num_ctx: 1000 } }
    let(:harness) do
      double('harness', session: session, client: client, logger: logger,
             options: options, compact_trigger_tokens: 1, compact_max_size: nil,
             tools_payload: nil)
    end
    let(:manager) { described_class.new(harness, FileList.new([], workdir: Dir.pwd)) }

    it 'logs the fresh post-compaction chain to harness.log' do
      messages = [
        { role: 'system', content: 'system prompt' },
        { role: 'user', content: 'implement X' },
        { role: 'assistant', content: nil,
          tool_calls: [{ id: 't1', function: { name: 'x' } }] },
        { role: 'tool', tool_call_id: 't1', content: 'r1' },
        { role: 'assistant', content: 'done' }
      ]

      expect(manager.check_inloop_compaction(messages, 1000)).to be(true)

      # issue #178: the system prompt is identical every compaction - it
      # must NOT be part of the dump.
      expect(log_io.string).not_to include('system:')
      # issue #178: content is logged in full (no ~80-char preview cut),
      # so the summary is actually inspectable from the log.
      # The in-loop chain has no retained tail - the log shows the fresh
      # [summary, ack, continue] chain instead.
      expect(log_io.string).to include(
        "user:\nThis is a summary of our previous conversation:\n\nHANDOFF"
      )
    end
  end
end

# issue #208: /retry must be able to RESUME a turn that died mid-loop. The
# session is the working chain, so the trail (assistant tool_calls + tool
# results) is already in it when the LLM call fails - before this fix only a
# trailing user prompt counted as "pending" and /retry replayed the prompt
# from zero ("give continue and figure out what you were doing yourself").
RSpec.describe SessionManager, '#retry (issue #208)' do
  let(:session) { Session.new('system prompt') }
  let(:file_list) { FileList.new([], workdir: Dir.pwd) }
  let(:backend) { double('backend', api_type: :openai, endpoint_path: '/chat/completions') }
  let(:client) { double('client', chat: nil, backend: backend) }
  let(:sent_chains) { [] }
  let(:harness) do
    Class.new do
      attr_reader :session, :client, :logger

      def initialize(session, client, logger, sent_chains)
        @session = session
        @client  = client
        @options = { num_ctx: 65_536 }
        @logger  = logger
        @sent    = sent_chains
      end

      attr_reader :options

      def compact_auto_threshold
        Session::AUTO_COMPACT_THRESHOLD
      end

      def compact_reserved_tokens
        Session::COMPACT_RESERVED_TOKENS
      end

      def call_llm
        @sent << @session.messages.dup
        { reasoning: nil, content: 'ok', stats: {} }
      end

      def print_stats(_stats); end
    end.new(session, client, Logger.new(File::NULL), sent_chains)
  end
  let(:manager) { described_class.new(harness, file_list) }

  def seed_midloop_failure
    session.add_user('implement feature X')
    session.add_assistant_message(
      { role: 'assistant', content: nil,
        tool_calls: [{ id: 'call_1', function: { name: 'file.read', arguments: '{}' } }] }
    )
    session.messages << { role: 'tool', tool_call_id: 'call_1', content: 'line 1' }
  end

  it 'still retries an unanswered user prompt' do
    session.add_user('do the thing')

    expect { manager.retry }.not_to raise_error
    expect(sent_chains.size).to eq(1)
  end

  it 'refuses to retry a chain that ends on an answered reply' do
    session.add_user('do the thing')
    session.add_assistant('done')

    expect { manager.retry }.to raise_error(HarnessError, /answered reply/)
    expect(sent_chains).to be_empty
  end

  it 'resumes a turn that died on a tool result (the trail is re-sent)' do
    seed_midloop_failure
    allow(session).to receive(:auto_compact_due?).and_return(false)

    manager.retry

    expect(sent_chains.size).to eq(1)
    sent = sent_chains.first
    expect(sent.map { |m| m[:role] })
      .to eq(%w[system user assistant tool])
    expect(sent.last).to eq(role: 'tool', tool_call_id: 'call_1', content: 'line 1')
  end

  it 'resumes a turn that died right after an unanswered tool_calls answer' do
    session.add_user('implement feature X')
    session.add_assistant_message(
      { role: 'assistant', content: nil,
        tool_calls: [{ id: 'call_1', function: { name: 'file.read', arguments: '{}' } }] }
    )
    allow(session).to receive(:auto_compact_due?).and_return(false)

    manager.retry

    expect(sent_chains.first.map { |m| m[:role] })
      .to eq(%w[system user assistant])
  end
end
