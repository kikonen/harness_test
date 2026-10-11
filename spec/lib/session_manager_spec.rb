# frozen_string_literal: true

require 'spec_helper'
require 'logger'
require 'stringio'
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

      def initialize(session, client)
        @session = session
        @client  = client
        @options = { num_ctx: 65_536, auto_save: false }
        @history = nil
        @logger  = Logger.new(File::NULL)
      end

      attr_reader :options, :logger

      # issue #113: resume re-points the logger; no-op in the stub.
      def rebind_logger
        @logger
      end

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

      # Mirrors Harness#context_indicator_live (issue #126): estimates the
      # current chain. The spinner calls this every frame, so it must exist.
      def context_indicator_live(_messages = nil)
        "🧠 ctx ~1/65536 (0%)"
      end
    end.new(session, client)
  end

  let(:client) { double('client', chat: nil) }
  let(:manager) { described_class.new(harness, file_list) }

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

    describe '#newest_session_path' do
      it 'is nil when the sessions dir does not exist' do
        with_tmp_manager do |manager, _, _|
          expect(manager.newest_session_path).to be_nil
        end
      end

      it 'returns the most recently modified session file' do
        with_tmp_manager do |manager, _, dir|
          sessions = File.join(dir, '.harness/sessions')
          # issue #207: files live inside per-session directories.
          older_dir = File.join(sessions, 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')
          newer_dir = File.join(sessions, 'ffffffff-0000-1111-2222-333333333333')
          FileUtils.mkdir_p([older_dir, newer_dir])
          older = File.join(older_dir, 'session.json')
          newer = File.join(newer_dir, 'session.json')
          File.write(older, '{}')
          File.write(newer, '{}')
          # Force distinct mtimes: put the "older" one clearly in the past.
          File.utime(Time.now - 120, Time.now - 120, older)
          expect(manager.newest_session_path).to eq(newer)
        end
      end
    end
  end

  describe '#resume_session (issue #113)' do
    it 're-points the logger at the resumed session id' do
      Dir.mktmpdir do |dir|
        # issue #207: the JSON lives inside the session's own directory.
        sid = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
        sessions = File.join(dir, '.harness/sessions', sid)
        FileUtils.mkdir_p(sessions)
        saved = session.to_h(file_list)
        saved[:session_id] = sid # the file on disk carries the resumed id
        File.write(File.join(sessions, 'session.json'), JSON.generate(saved))

        file_list = FileList.new([], workdir: dir)
        manager   = described_class.new(harness, file_list)
        expect(harness).to receive(:rebind_logger)

        manager.resume_session(sid)

        # The session id must have been swapped to the resumed one.
        expect(session.session_id).to eq(sid)
      end
    end
  end

  # issue #119: command history is per session - resume must re-point the
  # history manager at the new session id so up/down arrows (and the saved
  # file) follow the resumed session instead of mixing entries across ids.
  describe '#resume_session (issue #119)' do
    # issue #207: seed a saved session in the per-directory layout
    # (<sessions>/<id>/session.json).
    def seed_saved_session(dir)
      sid = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      sessions = File.join(dir, '.harness/sessions', sid)
      FileUtils.mkdir_p(sessions)
      saved = session.to_h(file_list)
      saved[:session_id] = sid
      File.write(File.join(sessions, 'session.json'), JSON.generate(saved))
      sid
    end

    it 're-binds the history manager to the resumed session id' do
      Dir.mktmpdir do |dir|
        sid = seed_saved_session(dir)

        file_list = FileList.new([], workdir: dir)
        manager   = described_class.new(harness, file_list)
        history   = double('history')
        harness.history = history

        expect(history).to receive(:bind_session).with(sid)

        manager.resume_session(sid)
      end
    end

    it 'does not break resume when no history manager is attached' do
      Dir.mktmpdir do |dir|
        sid = seed_saved_session(dir)

        file_list = FileList.new([], workdir: dir)
        manager   = described_class.new(harness, file_list)
        harness.history = nil

        expect { manager.resume_session(sid) }.not_to raise_error
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

    it '#list_sessions reads sessions from the new layout (id = dir name)' do
      Dir.mktmpdir do |dir|
        seed_saved_session(dir)

        file_list = FileList.new([], workdir: dir)
        manager   = described_class.new(harness, file_list)

        # eq() does not unwrap hash matchers - use match_array for that.
        expect(manager.list_sessions)
          .to match_array([hash_including(id: sid, messages: 1)])
      end
    end

    it '#newest_session_path finds sessions in the new layout' do
      Dir.mktmpdir do |dir|
        seed_saved_session(dir)

        file_list = FileList.new([], workdir: dir)
        manager   = described_class.new(harness, file_list)

        expect(manager.newest_session_path)
          .to eq(File.join(dir, '.harness/sessions', sid, 'session.json'))
      end
    end

    it '#resume_session resolves an abbreviated id by directory name' do
      Dir.mktmpdir do |dir|
        seed_saved_session(dir)

        file_list = FileList.new([], workdir: dir)
        manager   = described_class.new(harness, file_list)

        expect { manager.resume_session(sid[0, 8]) }.not_to raise_error
        expect(session.session_id).to eq(sid)
      end
    end
  end
end

RSpec.describe SessionManager, 'in-loop compaction (issue #108)' do
  let(:session) { Session.new('system prompt') }
  let(:file_list) { FileList.new([], workdir: Dir.pwd) }
  let(:client) { double('client', chat: nil) }
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

      # issue #126: the spinner calls this every frame (with the local chain).
      def context_indicator_live(_messages = nil)
        "🧠 ctx ~1/1000 (0%)"
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

    # The summarization call must see the ENTIRE working chain (minus
    # the system message, plus the instruction prompt) - including the
    # mid-turn tool trail already committed into it as it happened.
    expect(captured.size).to eq(inloop_messages.size - 1 + 1)
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
             options: options, compact_trigger_tokens: 1, compact_max_size: nil)
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
  let(:client) { double('client', chat: nil) }
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
