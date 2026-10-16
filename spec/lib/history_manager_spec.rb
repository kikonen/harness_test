# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'reline'
require 'harness' # for Harness::HARNESS_DIR (previously relied on load order)
require 'history_manager'

# issue #119: command history is per session - each session id gets its own
# history file (.harness/sessions/<session-id>/harness_history) so entries
# from different sessions are never mixed, and concurrent runs in the same
# workdir can no longer overwrite each other's shared history file.
RSpec.describe HistoryManager do
  let(:workdir) { Dir.mktmpdir('history-spec') }
  after { FileUtils.remove_entry(workdir) if File.directory?(workdir) }

  let(:sid_a) { 'aaaaaaaa-bbbb-cccc-dddd-111111111111' }
  let(:sid_b) { 'ffffffff-0000-1111-2222-333333333333' }

  # Reline::HISTORY is GLOBAL to the process - clear it in each test so no
  # example depends on (or leaks) the previous example's entries.
  before { Reline::HISTORY.clear }

  def manager
    described_class.new(workdir)
  end

  def history_entries
    Reline::HISTORY.map(&:to_s)
  end

  def session_file(sid)
    File.join(workdir, '.harness', 'sessions', sid, 'harness_history')
  end

  describe '#bind_session (issue #119)' do
    it 'stores the per-session history file under the session id' do
      m = manager
      m.bind_session(sid_a)
      expect(m.history_file).to eq(
        File.join(workdir, '.harness', 'sessions', sid_a, 'harness_history')
      )
    end

    it 'uses the legacy shared file when no session is bound' do
      expect(manager.history_file).to eq(
        File.join(workdir, '.harness', 'harness_history')
      )
    end

    it 're-resolves the file when the bound session changes' do
      m = manager
      m.bind_session(sid_a)
      m.bind_session(sid_b)
      expect(m.history_file).to eq(
        File.join(workdir, '.harness', 'sessions', sid_b, 'harness_history')
      )
    end
  end

  describe '#load / #save round trip' do
    it 'saves to and loads from the bound session file only' do
      m = manager
      m.bind_session(sid_a)

      Reline::HISTORY << 'prompt one'
      Reline::HISTORY << 'line1\nline2' # multiline survives the round trip
      m.save

      per_session = File.join(workdir, '.harness', 'sessions', sid_a, 'harness_history')
      expect(File.file?(per_session)).to be true

      # A different session must NOT see sid_a's entries.
      other = manager
      other.bind_session(sid_b)
      Reline::HISTORY.clear
      other.load
      expect(history_entries).to be_empty

      # ...but sid_a loads its own entries back, including the multiline one.
      m.load
      expect(history_entries).to eq(['prompt one', "line1\nline2"])
    end

    it 'does not write to the legacy shared file when a session is bound' do
      m = manager
      m.bind_session(sid_a)

      Reline::HISTORY << 'prompt'
      m.save

      legacy = File.join(workdir, '.harness', 'harness_history')
      expect(File.exist?(legacy)).to be false
    end

    it 'falls back to the legacy shared file for a session without its own' do
      legacy = File.join(workdir, '.harness', 'harness_history')
      FileUtils.mkdir_p(File.dirname(legacy))
      File.write(legacy, "old prompt\n")

      m = manager
      m.bind_session(sid_a) # sid_a has no file of its own yet
      m.load
      expect(history_entries).to eq(['old prompt'])
    end
  end

  # issue #135's symptom was a dummy dir for a throwaway id. Issue #276 made
  # it structurally impossible: the CLI resolves the resumed id BEFORE
  # constructing anything, so the manager is bound to sid_a once and sid_b -
  # the id the run never used - is never bound at all.
  describe 'resume keeps history in the RESUMED session (issues #135 / #276)' do
    before do
      # Session A persisted a few entries. A fresh process RESUMES A: the id is
      # resolved first (SessionLocator) and the manager is bound to it once.
      seed = manager
      seed.bind_session(sid_a)
      Reline::HISTORY.clear
      Reline::HISTORY << 'first prompt'
      Reline::HISTORY << 'second prompt'
      seed.save
      expect(File.file?(session_file(sid_a))).to be true

      @m = manager
      @m.bind_session(sid_a) # the id this run owns - no fresh id in between
      Reline::HISTORY.clear
      @m.load # <- A's entries are now in the buffer for the resumed run
      expect(history_entries).to eq(['first prompt', 'second prompt'])
    end

    it 'saves new typed entries into the RESUMED session dir (sid_a)' do
      Reline::HISTORY << 'a fresh prompt in the resumed run'

      @m.save

      # No dummy file under an id this run never used (issue #135).
      expect(File.exist?(session_file(sid_b))).to be false
      expect(File.read(session_file(sid_a)))
        .to include('first prompt', 'second prompt', 'a fresh prompt in the resumed run')
    end

    it 'does not touch sid_a file when only loaded entries are present' do
      before_content = File.read(session_file(sid_a))

      expect { @m.save }.not_to raise_error
      expect(File.exist?(session_file(sid_b))).to be false # no dummy dir either
      expect(File.read(session_file(sid_a))).to eq(before_content)
    end
  end

  describe '#load robustness' do
    it 'starts fresh when the history file is missing' do
      m = manager
      m.bind_session(sid_a)
      expect { m.load }.not_to raise_error
      expect(history_entries).to be_empty
    end

    it 'skips blank lines' do
      per_session = File.join(workdir, '.harness', 'sessions', sid_a, 'harness_history')
      FileUtils.mkdir_p(File.dirname(per_session))
      File.write(per_session, "a\n\nb\n")

      m = manager
      m.bind_session(sid_a)
      m.load
      expect(history_entries).to eq(%w[a b])
    end
  end
end
