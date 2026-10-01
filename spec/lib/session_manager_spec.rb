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
      attr_accessor :session, :client, :spinner

      def initialize(session, client)
        @session = session
        @client  = client
        @options = { num_ctx: 65_536, auto_save: false }
        @spinner = nil
        @logger  = Logger.new(File::NULL)
      end

      attr_reader :options, :logger

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
end
