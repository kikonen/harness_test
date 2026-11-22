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
  let(:sid_c) { 'cccccccc-0000-1111-2222-333333333333' }

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

  # Seed a layered system directory (issue #548, layout A):
  # <sessions>/<id>/system.json plus <sessions>/<id>/jobs/<job>/session.json.
  # statuses is what each job's own job.json records (the index names the job,
  # the record describes it).
  def seed_system(id, jobs: [0, 1], statuses: {})
    dir = File.join(workdir, '.harness', 'sessions', id)
    FileUtils.mkdir_p(dir)
    run_data = { session_id: id, workdir:, next_id: jobs.max + 1,
                 foreground_job: jobs.min,
                 jobs: jobs.map { |j| { id: j, dir: "jobs/#{j}", messages: 1 } } }
    run_path = File.join(dir, 'system.json')
    File.write(run_path, JSON.generate(run_data))
    jobs.each do |j|
      jdir = File.join(dir, 'jobs', j.to_s)
      FileUtils.mkdir_p(jdir)
      File.write(File.join(jdir, 'session.json'),
                 JSON.generate({ messages: [{ role: 'user', content: "job#{j}" }],
                                 active_model: 'm', param_overrides: {} }))
      status = statuses.fetch(j, 'pending')
      File.write(File.join(jdir, 'job.json'),
                 JSON.generate({ id: j, kind: 'main', status: status, result: nil,
                                 requested_by: nil, dependencies: [] }))
    end
    run_path
  end

  describe 'construction (issue #276)' do
    it 'creates nothing on disk' do
      locator

      expect(Dir.exist?(File.join(workdir, '.harness'))).to be false
    end
  end

  describe '#sessions_dir / #session_file_path' do
    it 'derives both from the workdir alone' do
      expect(locator.sessions_dir).to eq(File.join(workdir, '.harness', 'sessions'))
      expect(locator.session_file_path(sid_a))
        .to eq(File.join(workdir, '.harness', 'sessions', sid_a, 'session.json'))
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

  # issue #548: a layered system nests its session.json under jobs/<id>/, so the
  # old one-level glob would skip it. The directory-based reader lists a layered
  # run AND a #207 session together, each by the JSON that names its directory.
  describe '#session_dirs / layered + #207 listing (issue #548)' do
    it 'lists a layered system by its system.json, not its nested job session.json' do
      seed_system(sid_c)

      expect(locator.session_dirs).to eq([File.join(workdir, '.harness', 'sessions', sid_c)])
      expect(locator.session_files).to eq([File.join(workdir, '.harness', 'sessions', sid_c, 'system.json')])
    end

    it 'lists a layered system and a #207 session side by side' do
      seed_system(sid_c)
      seed_session(sid_a)

      dirs = locator.session_dirs.map { |d| File.basename(d) }.sort
      expect(dirs).to eq([sid_a, sid_c])
    end

    it 'finds a layered system dir by abbreviated id (resume/delete address it)' do
      seed_system(sid_c)

      expect(File.basename(File.dirname(locator.find_session_file(sid_c[0, 8])))).to eq(sid_c)
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

  # issue #548: a layered system is re-joined into the SAME flat resume_data hash
  # a #207 session provides, so the resume consumers read one shape. The run
  # keys come from system.json, the foreground conversation from its job dir, and
  # the replay tail from that job's replay.json.
  # #548: read_session returns the SYSTEM half only. No job conversation is
# folded in - the system owner reads each job's own files to rebuild them, so
# which job is foreground is the owner's decision, not the locator's.
  describe '#read_session returns the system half (issue #548)' do
    it 'returns system.json as-is, with no job conversation merged in' do
      seed_system(sid_c, jobs: [0])
      File.write(locator.job_replay_file_path(sid_c, 0),
                 JSON.generate([{ type: 'user', origin: 'user', content: 'do the thing' }]))

      data = locator.read_session(sid_c)

      expect(data[:session_id]).to eq(sid_c)
      expect(data[:next_id]).to eq(1)
      expect(data[:foreground_job]).to eq(0)
      # The conversation lives only in the job's own file, not in the resume hash.
      expect(data).not_to have_key(:messages)
      expect(data).not_to have_key(:replay_tail)
    end

    it 'is the system.json of a layered system unchanged' do
      seed_system(sid_c, jobs: [0, 1])

      data = locator.read_session(sid_c)

      expect(data[:jobs].map { |j| j[:id] }).to eq([0, 1])
      expect(data).not_to have_key(:messages)
    end
  end

  describe '#job_restores (issue #548 per-job restore)' do
    it 'returns EVERY job with a saved dir, with its own session half, status and tail' do
      seed_system(sid_c, jobs: [0, 1, 2], statuses: { 1 => "pending", 2 => "finished" })
      File.write(locator.job_replay_file_path(sid_c, 1),
                 JSON.generate([{ type: 'response', origin: 'session_manager', content: 'shown' }]))

      restores = locator.job_restores(sid_c)

      expect(restores.map { |r| r[:id] }).to eq([0, 1, 2])
      job1 = restores.find { |r| r[:id] == 1 }
      expect(job1[:session][:messages].first[:content]).to eq('job1')
      expect(job1[:replay_tail].first[:content]).to eq('shown')
      # The status comes from the job's OWN record file (job.json), not from
      # system.json's index, which names the job rather than describing it.
      expect(File.basename(locator.job_file_path(sid_c, 2))).to eq('job.json')
      expect(restores.last[:status]).to eq('finished')
      expect(restores.first[:kind]).to eq('main')
      expect(restores.first[:status]).to eq('pending')
    end

    it 'skips a job whose conversation file was dropped' do
      seed_system(sid_c, jobs: [0, 1])
      FileUtils.remove_entry(locator.job_dir_path(sid_c, 1))

      expect(locator.job_restores(sid_c).map { |r| r[:id] }).to eq([0])
    end

    it 'is empty for a #207 session (it has no jobs/ tree)' do
      seed_session(sid_a)

      expect(locator.job_restores(sid_a)).to eq([])
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

    # The /sessions "files" column is a GRANT count (SessionsCommand HELP), but a
    # modern save stores grants under the per-mode "access" hash and never writes
    # a literal "files" key, so a naive data[:files].size always read 0.
    it 'counts grants from the modern per-mode access hash' do
      dir  = File.join(workdir, '.harness', 'sessions', sid_a)
      path = File.join(dir, 'session.json')
      FileUtils.mkdir_p(dir)
      File.write(path, JSON.generate({
                                      session_id: sid_a, workdir:,
                                      messages: [{ role: 'user', content: 'm0' }],
                                      access: {
                                        both:  { files: ['lib/a.rb'], dirs: [], flat_dirs: [] },
                                        read:  { files: [], dirs: ['spec/lib'], flat_dirs: [] },
                                        write: { files: [], dirs: [], flat_dirs: [] },
                                        delete: { files: [], dirs: [], flat_dirs: [] }
                                      }
                                    }))

      expect(locator.list.find { |s| s[:id] == sid_a }[:files]).to eq(2)
    end

    it 'counts a grant that spans sections only once' do
      seed_session(sid_a)
      # seed_session writes files: ['lib/a.rb'] (legacy shape); a duplicate
      # across sections must not inflate the union.
      expect(locator.list.find { |s| s[:id] == sid_a }[:files]).to eq(1)
    end

    it 'skips an unreadable session file instead of failing the listing' do
      seed_session(sid_a)
      path = seed_session(sid_b)
      File.write(path, '{ not json')

      expect(locator.list.map { |s| s[:id] }).to eq([sid_a])
    end
  end

  # issue #548: messages are PER JOB - a layered system has no single "session
  # messages" number. /sessions reports the sum of the recorded per-job counts in
  # system.json, and #search reads every job's conversation, not just the foreground.
  describe '#list / #search of a layered system (issue #548)' do
    it 'sums the recorded per-job message counts, not an empty system.json' do
      seed_system(sid_c, jobs: [0, 1]) # seed records messages: 1 per job

      entry = locator.list.find { |s| s[:id] == sid_c }
      expect(entry[:messages]).to eq(2)
      expect(entry[:jobs]).to eq(2)
    end

    it 'searches a layered system across every job, not just the foreground' do
      seed_system(sid_c, jobs: [0, 1]) # job 1's content is "job1"

      expect(locator.search('job1').map { |m| m[:id] }).to eq([sid_c])
    end
  end

  # issue #279: find a saved session by what it was ABOUT (message text / id),
  # not just list them. The search shape SessionsSearchTool renders.
  describe '#search (issue #279)' do
    it 'is empty for a blank query' do
      expect(locator.search('')).to eq([])
      expect(locator.search('   ')).to eq([])
    end

    it 'is empty when no sessions are saved' do
      expect(locator.search('anything')).to eq([])
    end

    it 'matches a session by message content and reports a snippet and hit count' do
      seed_session(sid_a, messages: 1) # content is "m0" - no hit for 'refactor'
      dir  = File.join(workdir, '.harness', 'sessions', sid_b)
      path = File.join(dir, 'session.json')
      FileUtils.mkdir_p(dir)
      File.write(path, JSON.generate({
                                      session_id: sid_b, workdir:,
                                      messages: [{ role: 'user', content: 'we refactored the parser' },
                                                 { role: 'user', content: 'refactor done' }]
                                    }))

      matches = locator.search('refactor')

      expect(matches.map { |m| m[:id] }).to eq([sid_b])
      expect(matches.first[:hits]).to eq(2)
      expect(matches.first[:snippet]).to include('refactored the parser')
      expect(matches.first[:saved_at]).to be_a(Time)
      expect(matches.first[:workdir]).to eq(workdir)
    end

    it 'is case-insensitive and also matches the id' do
      dir  = File.join(workdir, '.harness', 'sessions', sid_a)
      path = File.join(dir, 'session.json')
      FileUtils.mkdir_p(dir)
      File.write(path, JSON.generate({
                                      session_id: sid_a, workdir:,
                                      messages: [{ role: 'user', content: 'kubernetes' }]
                                    }))

      expect(locator.search('KUBERNETES').map { |m| m[:id] }).to eq([sid_a])
      expect(locator.search(sid_a[0, 8]).map { |m| m[:id] }).to eq([sid_a])
    end

    it 'returns matches newest first' do
      older = Time.now - 60
      newer = Time.now
      a_path = seed_session(sid_a)
      b_path = seed_session(sid_b)
      File.write(a_path, JSON.generate({ session_id: sid_a, workdir:, messages: [{ content: 'topic' }] }))
      File.write(b_path, JSON.generate({ session_id: sid_b, workdir:, messages: [{ content: 'topic' }] }))
      File.utime(older, older, a_path)
      File.utime(newer, newer, b_path)

      ids = locator.search('topic').map { |m| m[:id] }
      expect(ids).to eq([sid_b, sid_a])
    end

    it 'skips an unreadable session file instead of failing the search' do
      seed_session(sid_a)
      path = seed_session(sid_b)
      File.write(path, '{ not json')

      expect(locator.search('m0').map { |m| m[:id] }).to eq([sid_a])
    end
  end

  # issue #548: the layered dir-per-job layout. These are the read-side path and
  # read primitives a writer/resolver build on. They are ADDITIVE - they do not
  # yet change the #207 #session_files glob, #list, or resume (that switch is the
  # same increment as the writer), so a #207 session and a layered system coexist.
  describe '#548 layered layout primitives' do
    it 'derives system.json, a job dir, and a job session path from the workdir' do
      expect(locator.system_file_path(sid_a))
        .to eq(File.join(workdir, '.harness', 'sessions', sid_a, 'system.json'))
      expect(locator.job_dir_path(sid_a, 0))
        .to eq(File.join(workdir, '.harness', 'sessions', sid_a, 'jobs', '0'))
      expect(locator.job_session_file_path(sid_a, 3))
        .to eq(File.join(workdir, '.harness', 'sessions', sid_a, 'jobs', '3', 'session.json'))
      expect(locator.job_file_path(sid_a, 3))
        .to eq(File.join(workdir, '.harness', 'sessions', sid_a, 'jobs', '3', 'job.json'))
      expect(locator.job_replay_file_path(sid_a, 3))
        .to eq(File.join(workdir, '.harness', 'sessions', sid_a, 'jobs', '3', 'replay.json'))
    end

    # issue #548 increment 1: a job's OWN record is a sibling of its session.json
    # and replay.json inside the job dir - the job's facts, not its conversation
    # and not its shown output.
    it 'reads a job.json symbolized beside the job session.json' do
      seed_system(sid_a, jobs: [0])
      File.write(locator.job_file_path(sid_a, 0),
                 JSON.generate({ id: 0, kind: 'sub_agent', status: 'finished',
                                 result: 'answer', requested_by: 1, dependencies: [2] }))

      record = locator.read_job_record(sid_a, 0)

      expect(record[:kind]).to eq('sub_agent')
      expect(record[:status]).to eq('finished')
      expect(record[:result]).to eq('answer')
      expect(record[:requested_by]).to eq(1)
      expect(record[:dependencies]).to eq([2])
      expect(record).not_to have_key(:session_id)
    end

    it 'raises reading a job record that is not there' do
      seed_system(sid_a, jobs: [0])

      expect { locator.read_job_record(sid_a, 5) }
        .to raise_error(HarnessError, /no job record for job 5 of session/)
    end

    it 'reports a layered system dir as a run, and a #207 dir as not' do
      seed_system(sid_a)
      seed_session(sid_b)

      expect(locator.system_dir?(sid_a)).to be true
      expect(locator.system_dir?(sid_b)).to be false
      expect(locator.system_dir?(sid_c)).to be false # no such dir at all
    end

    it 'reads system.json symbolized for a layered session' do
      seed_system(sid_a, jobs: [0, 1, 2])

      record = locator.read_system(sid_a)

      expect(record[:session_id]).to eq(sid_a)
      expect(record[:next_id]).to eq(3)
      expect(record[:jobs].map { |j| j[:id] }).to eq([0, 1, 2])
    end

    it 'reads a job session.json symbolized, carrying no session_id' do
      seed_system(sid_a, jobs: [0])

      job = locator.read_job_session(sid_a, 0)

      expect(job[:messages].first[:content]).to eq('job0')
      expect(job).not_to have_key(:session_id)
    end

    it 'raises reading a system record that is not there (a #207 session has none)' do
      seed_session(sid_b)

      expect { locator.read_system(sid_b) }
        .to raise_error(HarnessError, /no system record for session/)
      expect { locator.read_system(sid_c) }
        .to raise_error(HarnessError, /no system record for session/)
    end

    it 'raises reading a job session that is not there' do
      seed_system(sid_a, jobs: [0])

      expect { locator.read_job_session(sid_a, 5) }
        .to raise_error(HarnessError, /no session for job 5 of session/)
    end
  end
end
