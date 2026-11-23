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
JOB_RUN_ID = 'a9a9a9a9-0000-0000-0000-000000000000'

RSpec.describe SystemSaver do
  def harness_double(settings)
    Object.new.tap do |h|
      h.define_singleton_method(:settings) { settings }
      h.define_singleton_method(:mcp_connected_summary) { [] }
    end
  end

  def session_h(id, workdir = Dir.pwd)
    {
      version: 1,
      session_id: id,
      created_at: '2026-01-01T00:00:00+00:00',
      workdir:,
      Session::FILE_CACHE_KEY => {},
      access: { both: [], read: [], write: [], delete: [] }
    }
  end

  # A locator that names the session these specs save and read under.
  def saver_for(dir, id, registry)
    described_class.new(SessionLocator.new(dir, session_id: id), registry)
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
      saver_for(dir, id, registry).write_system_files(session_h(id, dir))
    end

    it "reads each job's own half back, with the system half kept separate" do
      Dir.mktmpdir do |dir|
        id = 'c0c0c0c0-0000-0000-0000-000000000000'
        locator = SessionLocator.new(dir, session_id: id)
        saved_registry = JobRegistry.new
        main = saved_registry.add_job(kind: :main)
        main.buffer.put(type: :response, origin: 'session_manager', content: 'main shown')
        saved_registry.foreground = main.id
        saved_system(dir, id, saved_registry)
        File.write(locator.job_session_file_path(0),
                   JSON.generate({ messages: [{ role: 'user', content: 'main chain' }],
                                   active_profile_id: 'x' }))

        saver = described_class.new(locator, JobRegistry.new)
        # The job half comes back through job_restores; the system half stays in
        # read_system. Nothing folds one into the other (#548).
        restore = saver.job_restores.first
        expect(restore[:id]).to eq(0)
        expect(restore[:session][:messages].first[:content]).to eq('main chain')
        expect(restore[:session][:active_profile_id]).to eq('x')
        expect(locator.read_system[:session_id]).to eq(id)
        # The saved shown tail is read straight from the job's replay file.
        File.write(locator.job_replay_file_path(0),
                   JSON.generate([{ type: 'response', origin: 'session_manager', content: 'main shown' }]))
        expect(saver.replay_tail_of(0).first[:content]).to eq('main shown')
      end
    end

    it 'names a saved id with no live Job under it as dropped' do
      Dir.mktmpdir do |dir|
        id = 'd1d1d1d1-0000-0000-0000-000000000000'
        locator = SessionLocator.new(dir, session_id: id)
        saved_registry = JobRegistry.new
        main = saved_registry.add_job(kind: :main)
        child = saved_registry.add_job(kind: :sub_agent, requested_by: main)
        child.finish('answer')
        saved_registry.foreground = main.id
        saved_system(dir, id, saved_registry)
        File.write(locator.job_session_file_path(1), JSON.generate({ messages: [] }))

        resumed = JobRegistry.new
        resumed.add_job(kind: :main)
        saver = described_class.new(locator, resumed)

        expect(saver.dropped_job_ids).to eq([1])
      end
    end

    it 'restores nothing for a #207 flat session (no per-job tree exists)' do
      Dir.mktmpdir do |dir|
        id = 'e2e2e2e2-0000-0000-0000-000000000000'
        locator = SessionLocator.new(dir, session_id: id)
        FileUtils.mkdir_p(File.dirname(locator.session_file_path))
        File.write(locator.session_file_path, JSON.generate({ session_id: id, messages: [] }))

        expect(described_class.new(locator, JobRegistry.new).job_restores).to eq([])
      end
    end

    it 'restores nothing for an id with no saved session at all' do
      Dir.mktmpdir do |dir|
        saver = saver_for(dir, 'f3f3f3f3-0000-0000-0000-000000000000', JobRegistry.new)

        expect(saver.job_restores).to eq([])
        expect(saver.dropped_job_ids).to eq([])
      end
    end

    # Index first: a resume enumerates it, so a job gone from it is gone.
    it 'remove_job drops the index entry and the job dir' do
      Dir.mktmpdir do |dir|
        id = 'b4b4b4b4-0000-0000-0000-000000000000'
        locator = SessionLocator.new(dir, session_id: id)
        saved_registry = JobRegistry.new
        main = saved_registry.add_job(kind: :main)
        child = saved_registry.add_job(kind: :sub_agent, requested_by: main)
        child.finish('answer')
        saved_registry.foreground = main.id
        saved_system(dir, id, saved_registry)
        File.write(locator.job_session_file_path(1), JSON.generate({ messages: [] }))

        live = JobRegistry.new
        live.add_job(kind: :main)
        live.add_job(kind: :sub_agent, requested_by: live.job(0))
        live.foreground = live.job(0).id
        saver = described_class.new(locator, live)

        expect(saver.remove_job(1)).to eq(1)

        expect(File.directory?(locator.job_dir(1))).to be(false)
        expect(locator.read_system[:jobs].map { |j| j[:id] }).to eq([0])
        expect(live.job(1)).to be_nil
        expect(live.job(0)).not_to be_nil
      end
    end

    it 'remove_job of a never-saved job just drops it from the live registry' do
      registry = JobRegistry.new
      registry.add_job(kind: :main)
      child = registry.add_job(kind: :sub_agent, requested_by: registry.job(0))
      saver = described_class.new(SessionLocator.new('no-such-dir', session_id: 'no-such-id'), registry)

      expect(saver.remove_job(child.id)).to eq(child.id)
      expect(registry.job(child.id)).to be_nil
    end
  end

  # The chain half of a save: every job with an agent is written, whatever its
  # status. Gating on finished? left every background chain unwritten (a job that
  # ran a turn and was never :done is still :pending), and a resume then had no
  # chain to rebuild - only the foreground job came back.
  describe 'save_run writes every job chain (issue #548)' do
    # A job agent bare enough to save: the real Session + SessionManager pair,
    # which is all save_run reads off a job harness.
    def job_harness(dir, session, manager)
      Object.new.tap do |h|
        h.define_singleton_method(:session) { session }
        h.define_singleton_method(:locator) { SessionLocator.new(dir, session_id: JOB_RUN_ID) }
        h.define_singleton_method(:file_list) { FileList.new([], workdir: dir) }
        h.define_singleton_method(:session_manager) { manager }
        h.define_singleton_method(:model_config) { ModelConfig.new({}) }
        h.define_singleton_method(:settings) { SystemSettings.from_options({}) }
        h.define_singleton_method(:mcp_connected_summary) { [] }
        h.define_singleton_method(:output_palette) { UI::Palette.fetch(nil) }
        h.define_singleton_method(:yolo?) { false }
        h.define_singleton_method(:stream?) { false }
        h.define_singleton_method(:markdown?) { false }
      end
    end

    def job_agent(dir, content)
      session = Session.new('sys', file_cache: SessionFileCache.new)
      session.add_user(content)
      file_list = FileList.new([], workdir: dir)
      manager   = SessionManager.new(job_harness(dir, session, nil), file_list)
      job_harness(dir, session, manager)
    end

    it 'writes a pending background job chain (not only the foreground one)' do
      Dir.mktmpdir do |dir|
        locator  = SessionLocator.new(dir, session_id: JOB_RUN_ID)
        registry = JobRegistry.new
        main     = registry.add_job(kind: :main)
        sub      = registry.add_job(kind: :sub_agent, requested_by: main)
        sub.attach_harness(job_agent(dir, 'sub-agent chain'))
        expect(sub.finished?).to be(false)

        described_class.new(locator, registry).save_run

        path = locator.job_session_file_path(sub.id)
        expect(File.file?(path)).to be(true)
        chain = JSON.parse(File.read(path), symbolize_names: true)[:messages]
        expect(chain.map { |m| m[:content] }).to include('sub-agent chain')
      end
    end
  end

  # A resumed job the registry still holds is in the fresh index, so never pruned.
  describe 'prune_stale_job_dirs (issue #557)' do
    def jobs_on_disk(dir, id)
      Dir.glob(File.join(SessionLocator.new(dir, session_id: id).job_dir(''), '*'))
         .select { |d| File.directory?(d) }
         .map { |d| File.basename(d).to_i }
         .sort
    end

    it 'removes a dir whose job is no longer in the index, keeping index jobs' do
      Dir.mktmpdir do |dir|
        id = 'c5c5c5c5-0000-0000-0000-000000000000'
        registry = JobRegistry.new
        registry.add_job(kind: :main)
        # Index names only job 0 (job 1 never made it in). Both dirs exist on
        # disk: jobs/1/ is the stale one a drop left behind.
        saved = JobRegistry.new
        saved.add_job(kind: :main)
        saver_for(dir, id, saved).write_system_files(session_h(id, dir))
        FileUtils.mkdir_p(SessionLocator.new(dir, session_id: id).job_dir(0))
        FileUtils.mkdir_p(SessionLocator.new(dir, session_id: id).job_dir(1))
        saver_for(dir, id, registry).prune_stale_job_dirs
        expect(jobs_on_disk(dir, id)).to eq([0])
      end
    end

    it 'is a no-op for a #207 flat session (no jobs/ tree to prune)' do
      Dir.mktmpdir do |dir|
        id = 'd6d6d6d6-0000-0000-0000-000000000000'
        locator = SessionLocator.new(dir, session_id: id)
        FileUtils.mkdir_p(File.dirname(locator.session_file_path))
        File.write(locator.session_file_path, JSON.generate({ session_id: id, messages: [] }))
        expect { described_class.new(locator, JobRegistry.new).prune_stale_job_dirs }.not_to raise_error
      end
    end
  end
end
