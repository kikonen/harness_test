# frozen_string_literal: true

require 'spec_helper'
require 'logger'
require 'spinner'
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
  let(:harness) do
    Class.new do
      attr_accessor :session, :client, :spinner, :history

      def initialize(session, client)
        @session = session
        @client  = client
        @options = { num_ctx: 65_536, auto_save: false }
        @spinner = nil
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
        sessions = File.join(dir, '.harness/sessions')
        FileUtils.mkdir_p(sessions)
        expect(manager).to receive(:save_session).and_call_original
        expect { manager.maybe_auto_save('test') }
          .to change { Dir.children(sessions).size }.from(0).to(1)
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
          FileUtils.mkdir_p(sessions)
          older = File.join(sessions, 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.json')
          newer = File.join(sessions, 'ffffffff-0000-1111-2222-333333333333.json')
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
        sessions = File.join(dir, '.harness/sessions')
        FileUtils.mkdir_p(sessions)
        sid = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
        saved = session.to_h(file_list)
        saved[:session_id] = sid # the file on disk carries the resumed id
        File.write(File.join(sessions, "#{sid}.json"), JSON.generate(saved))

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
    it 're-binds the history manager to the resumed session id' do
      Dir.mktmpdir do |dir|
        sessions = File.join(dir, '.harness/sessions')
        FileUtils.mkdir_p(sessions)
        sid = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
        saved = session.to_h(file_list)
        saved[:session_id] = sid
        File.write(File.join(sessions, "#{sid}.json"), JSON.generate(saved))

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
        sessions = File.join(dir, '.harness/sessions')
        FileUtils.mkdir_p(sessions)
        sid = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
        saved = session.to_h(file_list)
        saved[:session_id] = sid
        File.write(File.join(sessions, "#{sid}.json"), JSON.generate(saved))

        file_list = FileList.new([], workdir: dir)
        manager   = described_class.new(harness, file_list)
        harness.history = nil

        expect { manager.resume_session(sid) }.not_to raise_error
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
      attr_accessor :session, :client, :spinner, :history

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

  # A local working chain as it looks mid tool-loop: system + prompt + a
  # completed assistant/tool round (the part NOT yet in session.messages).
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

    # The summarization call must see the ENTIRE local working chain (minus
    # the system message, plus the instruction prompt) - including the
    # mid-turn tool trail that does not exist in session.messages yet.
    expect(captured.size).to eq(inloop_messages.size - 1 + 1)
    expect(captured.last[:content]).to match(/Keep it under \d+ words/)
    # The local working chain is replaced with a compacted form - the tail
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
    # The session must hold the exact same compacted chain (in place).
    expect(session.messages).to eq(messages)
    # Stale pre-compaction stats must be cleared, otherwise auto_compact_due?
    # would immediately trip again on the very tokens that caused compaction.
    expect(session.instance_variable_get(:@last_stats)).to be_nil
  end
  # issue #116: in-loop compaction runs from INSIDE Harness#call_llm, so the
  # send_session spinner is still animating. The old code created a second
  # spinner on top of it and then only stopped the inner one - orphaning the
  # outer animation thread, which kept printing its frame forever and
  # interleaved with every subsequent tool line.
  describe 'outer spinner handling (issue #116)' do
    it 'pauses the send spinner during compaction and resumes it afterwards' do
      allow_summary_response
      messages = inloop_messages

      outer = Spinner.new('Sending to gpt-x', nil)
      outer.start
      harness.spinner = outer

      expect(outer).to receive(:pause).ordered
      expect(outer).to receive(:resume).ordered

      result = manager.check_inloop_compaction(messages, 1000)

      expect(result).to be(true)
      # The outer spinner must be restored and still animating - the turn is
      # still in flight and must keep its spinner.
      expect(harness.spinner).to be(outer)
      expect(outer.running?).to be(true)
      outer.stop
    end

    it 'still compacts (and leaves no spinner) when there is no outer spinner' do
      allow_summary_response
      messages = inloop_messages

      expect(manager.check_inloop_compaction(messages, 1000)).to be(true)
      expect(harness.spinner).to be_nil
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
