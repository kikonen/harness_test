# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'job_registry'
require 'session_locator'
require 'session_manager'
require 'file_list'
require 'system_settings'
require 'system_record'
require 'system_saver'

# SystemSaver is the system's owner-built half of persistence: the CLI hands it
# its own registry so a per-Harness SessionManager never assembles a file it does
# not own, and the SAME object is the read side a resume restores job state
# through. The layered WRITE shapes are covered in system_record_spec.rb, the
# whole-run save in cli_spec.rb.
RSpec.describe SystemSaver do
  def harness_double(settings)
    Object.new.tap do |h|
      h.define_singleton_method(:settings) { settings }
      h.define_singleton_method(:mcp_connected_summary) { [] }
    end
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

  describe 'the registry seam' do
    it 'holds the registry it was built from (the CLI reads it back)' do
      registry = JobRegistry.new
      registry.add_job(kind: :main)

      expect(described_class.new(SessionLocator.new('dir'), registry).registry).to be(registry)
    end

    # The saved foreground is the registry's fact, read live: #548 moved it off a
    # per-Harness object onto the object that owns the registry.
    it 'reports the foreground job the registry holds at read time' do
      registry = JobRegistry.new
      main = registry.add_job(kind: :main)
      other = registry.add_job(kind: :command, requested_by: main)
      saver = described_class.new(SessionLocator.new('dir'), registry)

      expect(saver.foreground_job).to eq(main.id)
      registry.foreground = other.id
      expect(saver.foreground_job).to eq(other.id)
    end
  end

  # issue #548 increment 3: the layered READ side. A save wrote one dir per job;
  # a resume reads each job's own status and shown tail back onto the job this
  # run has under that id, and names the ids it cannot.
  describe 'the layered read side (issue #548)' do
    def saved_system(dir, id, registry)
      described_class.new(SessionLocator.new(dir), registry).write_system_files(
        id, session_h(id, dir))
    end

    it 'restores a saved job status and replay tail onto the job this run has' do
      Dir.mktmpdir do |dir|
        id = 'c0c0c0c0-0000-0000-0000-000000000000'
        locator = SessionLocator.new(dir)
        saved_registry = JobRegistry.new
        main = saved_registry.add_job(kind: :main)
        child = saved_registry.add_job(kind: :sub_agent, requested_by: main)
        child.buffer.put(type: :response, origin: :session_manager, content: 'child shown')
        child.buffer.keep_window
        child.finish('child answer')
        saved_registry.foreground = main.id
        saved_system(dir, id, saved_registry)
        # The job's own conversation file (that job's SessionManager writes it).
        File.write(locator.job_session_file_path(id, 1),
                   JSON.generate({ messages: [{ role: 'assistant', content: 'child work' }] }))

        resumed = JobRegistry.new
        resumed.add_job(kind: :main)
        resumed.add_job(kind: :command)
        saver = described_class.new(locator, resumed)

        expect(saver.job_restores(id).map { |r| r[:id] }).to eq([1])
        expect(saver.job_restores(id).first[:messages].first[:content]).to eq('child work')

        restored = saver.restore_job_states(id)
        expect(restored.map(&:id)).to eq([1])
        # The status the save recorded was the Symbol :finished; the JSON round
        # trip gives the String "finished", and Job#restore_status maps it back.
        expect(resumed.job(1).status).to eq(:finished)
        expect(resumed.job(1).buffer.tail.map(&:content)).to eq(['child shown'])
        # A restored :finished job is a retention candidate again, as in the saved run.
        expect(resumed.job(1).finished?).to be true
      end
    end

    it 'names a saved id with no live Job under it as dropped' do
      Dir.mktmpdir do |dir|
        id = 'd1d1d1d1-0000-0000-0000-000000000000'
        locator = SessionLocator.new(dir)
        saved_registry = JobRegistry.new
        main = saved_registry.add_job(kind: :main)
        child = saved_registry.add_job(kind: :sub_agent, requested_by: main)
        child.finish('answer')
        saved_registry.foreground = main.id
        saved_system(dir, id, saved_registry)
        File.write(locator.job_session_file_path(id, 1), JSON.generate({ messages: [] }))

        resumed = JobRegistry.new
        resumed.add_job(kind: :main)
        saver = described_class.new(locator, resumed)

        expect(saver.restore_job_states(id)).to eq([])
        expect(saver.dropped_job_ids(id)).to eq([1])
      end
    end

    it 'restores nothing for a #207 flat session (no per-job tree exists)' do
      Dir.mktmpdir do |dir|
        id = 'e2e2e2e2-0000-0000-0000-000000000000'
        locator = SessionLocator.new(dir)
        FileUtils.mkdir_p(File.dirname(locator.session_file_path(id)))
        File.write(locator.session_file_path(id), JSON.generate({ session_id: id, messages: [] }))

        expect(described_class.new(locator, JobRegistry.new).job_restores(id)).to eq([])
      end
    end

    it 'restores nothing for an id with no saved session at all' do
      Dir.mktmpdir do |dir|
        saver = described_class.new(SessionLocator.new(dir), JobRegistry.new)

        expect(saver.job_restores('f3f3f3f3-0000-0000-0000-000000000000')).to eq([])
        expect(saver.dropped_job_ids('f3f3f3f3-0000-0000-0000-000000000000')).to eq([])
      end
    end
  end

  # The single-job save a SessionManager-less harness still produces: the job's
  # own session.json plus a degenerate one-job system.json, in the two steps
  # save_run uses. It is the only save that writes system.json WITHOUT a registry,
  # so the record it writes carries default postures - a real run's postures only
  # travel through save_run over a registry carrying the system settings (#548).
  describe 'save_standalone (issue #548)' do
    def standalone_harness(session, manager, workdir)
      Object.new.tap do |h|
        h.define_singleton_method(:session) { session }
        h.define_singleton_method(:file_list) { FileList.new([], workdir:) }
        h.define_singleton_method(:model_config) { ModelConfig.new({}) }
        h.define_singleton_method(:session_manager) { manager }
      end
    end

    it 'writes the job session.json and a one-job system.json under the run id' do
      Dir.mktmpdir do |dir|
        id      = 'a1a1a1a1-0000-0000-0000-000000000000'
        session = Session.new('sys', file_cache: SessionFileCache.new)
        session.add_user('standalone prompt')
        manager = SessionManager.new(standalone_harness(session, nil, dir), FileList.new([], workdir: dir))
        harness = standalone_harness(session, manager, dir)
        saver   = described_class.new(SessionLocator.new(dir), nil)

        expect(saver.save_standalone(id, harness)).to eq(id)

        locator = SessionLocator.new(dir)
        expect(File.file?(locator.job_session_file_path(id, 0))).to be true
        expect(File.file?(locator.system_file_path(id))).to be true
        job_data = JSON.parse(File.read(locator.job_session_file_path(id, 0)))
        expect(job_data['messages'].map { |m| m['content'] }).to include('standalone prompt')
        system_data = JSON.parse(File.read(locator.system_file_path(id)))
        expect(system_data['session_id']).to eq(id)
        expect(system_data['jobs'].map { |j| j['id'] }).to eq([0])
        # A registry-less record records the default posture, exactly as a session
        # saved before the key existed records nothing.
        expect(system_data['yolo']).to be(false)
      end
    end
  end
end
