# frozen_string_literal: true

require 'spec_helper'
require 'job_registry'
require 'system_record'
require 'session_locator'
require 'session'
require 'system_settings'

# #548 increment 1: SystemRecord is the system-owned persistence half the CLI injects
# into SessionManager in place of the raw JobRegistry, so a per-Harness save
# reads only the two system keys (foreground job, replay tail) and never the
# scheduling registry itself.
RSpec.describe SystemRecord do
  def registry_with_tail(tail)
    registry = JobRegistry.new
    registry.add_job(kind: :main)
    registry.foreground_buffer.restore(tail)
    registry
  end

  it 'reports the foreground job id the registry holds at read time' do
    registry = JobRegistry.new
    registry.add_job(kind: :main)
    node = registry.add_job(kind: :command, requested_by: registry.jobs.first)
    registry.foreground = node.id

    expect(described_class.new(registry).foreground_job).to eq(node.id)
  end

  # The keys are read live, not snapshotted when SystemRecord is built: a system adds
  # jobs and switches the foreground after CLI#setup, and the save must record
  # the registry as it is at save time.
  it 'reads the registry live, not a snapshot taken at construction' do
    registry = JobRegistry.new
    registry.add_job(kind: :main)
    record = described_class.new(registry)

    expect(record.foreground_job).to eq(0)

    node = registry.add_job(kind: :command, requested_by: registry.jobs.first)
    registry.foreground = node.id

    expect(record.foreground_job).to eq(node.id)
  end

  it 'supplies the foreground buffer replay tail (the JobRegistry save shape)' do
    tail = [{ type: 'user', origin: 'user', content: 'do the thing' }]
    registry = registry_with_tail(tail)

    expect(described_class.new(registry).replay_tail).to eq(
      registry.replay_tail_for_save
    )
  end

  it 'returns an empty tail when the disabled window records nothing' do
    registry = JobRegistry.new(max_saved: 0)
    registry.add_job(kind: :main)

    expect(described_class.new(registry).replay_tail).to eq([])
  end
  # issue #548 increment 2: the writer persists the system -> job map and the next
  # job id. next_id is read live so a resumed system continues numbering.
  it 'reports next_id so a resumed system never reuses a job id' do
    registry = JobRegistry.new
    registry.add_job(kind: :main)
    registry.add_job(kind: :command)

    expect(described_class.new(registry).next_id).to eq(2)
  end

  it 'serializes each retained job with edges as IDS, not live Job refs' do
    registry = JobRegistry.new
    main = registry.add_job(kind: :main)
    registry.add_job(kind: :command, requested_by: main, dependencies: [main])

    jobs = described_class.new(registry).jobs_for_save

    expect(jobs.map { |j| j[:id] }).to eq([0, 1])
    expect(jobs[0][:kind]).to eq(:main)
    expect(jobs[1][:requested_by]).to eq(main.id)        # id, not a Job object
    expect(jobs[1][:dependencies]).to eq([main.id])      # ids, not Job objects
    expect(jobs[1][:dir]).to eq('jobs/1')
  end

  # A dependency that is a callable predicate (not a Job) has no id to record;
  # it is omitted (its re-resolution belongs to increment 4).
  it 'omits a non-Job dependency that has no id' do
    registry = JobRegistry.new
    registry.add_job(kind: :timed, dependencies: [-> { true }])

    expect(described_class.new(registry).jobs_for_save.first[:dependencies]).to eq([])
  end

  def session_h(id, workdir)
    {
      version: 1,
      session_id: id,
      created_at: '2026-01-01T00:00:00+00:00',
      workdir:,
      Session::FILE_CACHE_KEY => {},
      access: { both: [], read: [], write: [], delete: [] }
    }
  end

  it 'writes system.json + an empty replay.json for a registry-less (one-job) record' do
    Dir.mktmpdir do |dir|
      id      = 'aaaaaaaa-0000-0000-0000-000000000000'
      locator = SessionLocator.new(dir)

      described_class.new(nil).write_system_files(
        locator, id, session_h(id, dir))

      run = JSON.parse(File.read(locator.system_file_path(id)), symbolize_names: true)
      expect(run[:foreground_job]).to eq(0)
      expect(run[:next_id]).to eq(1)
      expect(run[:jobs].map { |j| j[:id] }).to eq([0])
      expect(run[:jobs].first[:dir]).to eq('jobs/0')
      expect(JSON.parse(File.read(locator.job_replay_file_path(id, 0)))).to eq([])
    end
  end

  it 'records NO conversation in the system half - the seam SystemRecord enforces' do
    Dir.mktmpdir do |dir|
      id      = 'bbbbbbbb-0000-0000-0000-000000000000'
      locator = SessionLocator.new(dir)
      sh      = session_h(id, dir)
      sh[:messages] = [{ role: 'user', content: 'secret chain' }]

      described_class.new(nil).write_system_files(
        locator, id, sh)

      run = JSON.parse(File.read(locator.system_file_path(id)), symbolize_names: true)
      expect(run).not_to have_key(:messages)
    end
  end

  # issue #548 increment 4b: write_system_files writes a replay.json for EVERY
  # retained job, not just the foreground one.
  it 'writes replay.json for every retained job (not only the foreground)' do
    Dir.mktmpdir do |dir|
      id       = 'dddddddd-0000-0000-0000-000000000000'
      locator  = SessionLocator.new(dir)
      registry = JobRegistry.new
      main = registry.add_job(kind: :main)
      child = registry.add_job(kind: :sub_agent, requested_by: main)
      child.buffer.put(type: :response, origin: :session_manager, content: 'child shown')
      child.buffer.keep_window
      registry.foreground = main.id

      described_class.new(registry).write_system_files(
        locator, id, session_h(id, dir))

      fg = JSON.parse(File.read(locator.job_replay_file_path(id, 0)), symbolize_names: true)
      job1 = JSON.parse(File.read(locator.job_replay_file_path(id, 1)), symbolize_names: true)
      expect(fg).to eq([])
      expect(job1.first[:content]).to eq('child shown')
    end
  end

  it 'writes the system -> job map from a real registry, postures read off the registry settings' do
    Dir.mktmpdir do |dir|
      id       = 'cccccccc-0000-0000-0000-000000000000'
      locator  = SessionLocator.new(dir)
      settings = SystemSettings.from_options({ yolo: true })
      registry = JobRegistry.new(settings: settings)
      main = registry.add_job(kind: :main)
      registry.add_job(kind: :command, requested_by: main, dependencies: [main])
      registry.foreground_buffer.restore([{ type: 'user', origin: 'user', content: 'shown' }])

      described_class.new(registry).write_system_files(
        locator, id, session_h(id, dir))

      run = JSON.parse(File.read(locator.system_file_path(id)), symbolize_names: true)
      expect(run[:next_id]).to eq(2)
      expect(run[:jobs].map { |j| j[:id] }).to eq([0, 1])
      expect(run[:jobs][1][:requested_by]).to eq(main.id)
      expect(run[:yolo]).to be(true)
      replay = JSON.parse(File.read(locator.job_replay_file_path(id, 0)), symbolize_names: true)
      expect(replay.first[:content]).to eq('shown')
    end
  end

  # issue #548 increment 1 (per-job record): every retained job gets its own
  # jobs/<id>/job.json - the detail system.json's jobs[] index points at.
  it 'writes a job.json for every retained job (the per-job record)' do
    Dir.mktmpdir do |dir|
      id      = 'eeeeeeee-0000-0000-0000-000000000000'
      locator = SessionLocator.new(dir)
      registry = JobRegistry.new
      main  = registry.add_job(kind: :main)
      child = registry.add_job(kind: :sub_agent, requested_by: main, dependencies: [main])
      child.finish('child answer')

      described_class.new(registry).write_system_files(
        locator, id, session_h(id, dir))

      job0 = locator.read_job_record(id, 0)
      job1 = locator.read_job_record(id, 1)
      # The round trip is JSON: a Symbol value reads back as a String.
      expect(job0).to eq(id: 0, kind: 'main', status: 'pending', result: nil,
                         requested_by: nil, dependencies: [])
      expect(job1[:kind]).to eq('sub_agent')
      expect(job1[:status]).to eq('finished')
      expect(job1[:result]).to eq('child answer')
      expect(job1[:requested_by]).to eq(main.id)
      expect(job1[:dependencies]).to eq([main.id])
      # A job record carries no run UUID: the directory name and system.json own it.
      expect(job1).not_to have_key(:session_id)
    end
  end

  it 'records a job result that is not JSON-representable as a labelled placeholder' do
    Dir.mktmpdir do |dir|
      id      = 'ffffffff-0000-0000-0000-000000000000'
      locator = SessionLocator.new(dir)
      registry = JobRegistry.new
      registry.add_job(kind: :main).finish(->(x) { x })

      described_class.new(registry).write_system_files(
        locator, id, session_h(id, dir))

      expect(locator.read_job_record(id, 0)[:result]).to eq('(unserializable Proc)')
    end
  end

  it 'writes the degenerate job.json when the record has no registry' do
    Dir.mktmpdir do |dir|
      id      = 'abababab-0000-0000-0000-000000000000'
      locator = SessionLocator.new(dir)

      described_class.new(nil).write_system_files(
        locator, id, session_h(id, dir))

      # A nil-registry save has no Job to take a result from, so it records an
      # unfinished job with the fields a live Job would supply.
      expect(locator.read_job_record(id, 0)).to eq(
        id: 0, kind: 'main', status: 'pending', result: nil, requested_by: nil, dependencies: []
      )
    end
  end
end
