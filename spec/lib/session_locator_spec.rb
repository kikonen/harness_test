# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'session_locator'

# issue #276: SessionLocator is the single place that knows WHERE a session
# lives and WHICH session this run is. It is pure path logic - constructing it
# must never create anything on disk (that is what lets CLI settle identity
# before any Harness, logger or history file exists).
RSpec.describe SessionLocator do
  let(:workdir) { Dir.mktmpdir('locator-spec') }
  let(:locator) { described_class.new(workdir) }
  let(:sid_a) { 'aaaaaaaa-bbbb-cccc-dddd-111111111111' }
  let(:sid_b) { 'ffffffff-0000-1111-2222-333333333333' }

  after { FileUtils.remove_entry(workdir) if File.directory?(workdir) }

  # Seed a saved session in the issue #207 layout: <sessions>/<id>/session.json.
  def seed_session(id, messages: 2, saved_at: Time.now, workdir_value: nil)
    dir  = File.join(workdir, '.harness', 'sessions', id)
    path = File.join(dir, 'session.json')
    FileUtils.mkdir_p(dir)
    data = {
      session_id: id,
      messages:   Array.new(messages) { |i| { role: 'user', content: "m#{i}" } },
      files:      ['lib/a.rb'],
      workdir:    workdir_value || workdir
    }
    File.write(path, JSON.generate(data))
    File.utime(saved_at, saved_at, path)
    path
  end

  describe '#sessions_dir / #session_file_path' do
    it 'derives both from the workdir alone' do
      expect(locator.sessions_dir).to eq(File.join(workdir, '.harness', 'sessions'))
      expect(locator.session_file_path(sid_a))
        .to eq(File.join(workdir, '.harness', 'sessions', sid_a, 'session.json'))
    end
  end

  describe 'construction (issue #276)' do
    it 'creates nothing on disk' do
      locator

      expect(Dir.exist?(File.join(workdir, '.harness'))).to be false
    end
  end

  describe '#session_files / #newest_session_path' do
    it 'is empty when there is no sessions dir yet' do
      expect(locator.session_files).to eq([])
      expect(locator.newest_session_path).to be_nil
    end

    it 'lists the session JSON files of the #207 layout only' do
      seed_session(sid_a)
      seed_session(sid_b)
      # A stray file outside the layout must not be picked up.
      File.write(File.join(workdir, '.harness', 'sessions', 'loose.json'), '{}')

      expect(locator.session_files.size).to eq(2)
      expect(locator.session_files).to all(end_with('session.json'))
    end

    it 'picks the file with the newest mtime' do
      older = seed_session(sid_a, saved_at: Time.now - 60)
      newer = seed_session(sid_b, saved_at: Time.now)

      expect(locator.newest_session_path).to eq(newer)
      expect(older).not_to eq(newer)
    end
  end

  describe '#find_session_file' do
    it 'matches an abbreviated id by directory-name prefix' do
      path = seed_session(sid_a)

      expect(locator.find_session_file(sid_a[0, 8])).to eq(path)
    end

    it 'returns nil for an unknown id' do
      seed_session(sid_a)

      expect(locator.find_session_file('deadbeef')).to be_nil
    end

    it 'raises when a prefix matches several sessions' do
      seed_session('abcdef01-1111-2222-3333-444444444444')
      seed_session('abcdef02-1111-2222-3333-444444444444')

      expect { locator.find_session_file('abcdef') }
        .to raise_error(HarnessError, /ambiguous session id 'abcdef'/)
    end

    it 'rejects an id that cannot be a directory name' do
      # A path-shaped id must not be globbed against the sessions dir.
      expect { locator.find_session_file('../escape') }
        .to raise_error(HarnessError, /invalid session id/)
      expect { locator.find_session_file('') }.to raise_error(HarnessError, /invalid/)
      expect { locator.find_session_file(nil) }.to raise_error(HarnessError, /invalid/)
    end
  end

  describe '#resolve_id (the point of this class)' do
    it 'mints a fresh UUID when no resume is asked for' do
      id = locator.resolve_id

      expect(id).to match(Session::UUID_RE)
      # ...and it did that WITHOUT creating the directory for it.
      expect(Dir.exist?(File.join(workdir, '.harness'))).to be false
    end

    it 'returns the full directory name of a resumed id' do
      seed_session(sid_a)

      expect(locator.resolve_id(resume: sid_a[0, 8])).to eq(sid_a)
    end

    it 'returns the newest saved id for --continue' do
      seed_session(sid_a, saved_at: Time.now - 60)
      seed_session(sid_b, saved_at: Time.now)

      expect(locator.resolve_id(newest: true)).to eq(sid_b)
    end

    it 'raises instead of falling back to a fresh id' do
      # A typo'd resume id must not silently start an unrelated empty session
      # the user believes is theirs.
      expect { locator.resolve_id(resume: 'deadbeef') }
        .to raise_error(HarnessError, /no saved session matching 'deadbeef'/)
      expect { locator.resolve_id(newest: true) }
        .to raise_error(HarnessError, /no saved sessions/)
    end
  end

  describe '#read_session' do
    it 'returns the saved data symbolized, for a caller whose id is settled' do
      seed_session(sid_a, messages: 3)

      data = locator.read_session(sid_a[0, 8])

      expect(data[:session_id]).to eq(sid_a)
      expect(data[:messages].size).to eq(3)
    end

    it 'raises for an unknown id' do
      expect { locator.read_session('deadbeef') }
        .to raise_error(HarnessError, /no saved session matching/)
    end
  end

  describe '#list' do
    it 'is empty when nothing is saved' do
      expect(locator.list).to eq([])
    end

    it 'reports each session newest first, with the id from the dir name' do
      seed_session(sid_a, saved_at: Time.now - 60)
      seed_session(sid_b, saved_at: Time.now)

      ids = locator.list.map { |s| s[:id] }
      expect(ids).to eq([sid_b, sid_a])

      entry = locator.list.first
      expect(entry[:messages]).to eq(2)
      expect(entry[:files]).to eq(1)
      expect(entry[:workdir]).to eq(workdir)
      expect(entry[:saved_at]).to be_a(Time)
    end

    it 'skips an unreadable session file instead of failing the listing' do
      seed_session(sid_a)
      path = seed_session(sid_b)
      File.write(path, '{ not json')

      expect(locator.list.map { |s| s[:id] }).to eq([sid_a])
    end
  end
end
