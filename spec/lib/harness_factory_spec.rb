# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'harness'
require 'harness_factory'
require 'job_registry'
require 'system_saver'
require 'file_list'
require 'session_locator'
require 'system_settings'

# HarnessFactory is the basis for MORE THAN ONE agent per run (issue #548): a Job
# is created empty and RECEIVES its Harness, and the per-agent wiring a job cannot
# invent for itself (which job dir its save writes under, which system writer it
# delegates to) is done in one place.
# The ONE uuid a run has is the system session id: a job is named by its own
# jobs/<id>/ directory under it, never by a uuid of its own.
SESSION_ID = 'aaaaaaaa-0000-0000-0000-000000000000'

RSpec.describe HarnessFactory do
  let(:workdir) { Dir.mktmpdir('factory-spec') }
  after { FileUtils.remove_entry(workdir) if File.directory?(workdir) }

  before { allow_any_instance_of(SandboxGemfile).to receive(:lock_seeded?).and_return(true) }

  def settings
    SystemSettings.from_options(
      system_file: Harness::DEFAULT_SYSTEM_PROMPT_FILE, num_ctx: 65_536)
  end

  def registry_with(*kinds)
    JobRegistry.new.tap do |registry|
      kinds.each { |kind| registry.add_job(kind:) }
    end
  end

  def factory(registry:, system_saver: nil)
    described_class.new(
      registry:,
      locator: SessionLocator.new(workdir),
      settings:,
      file_list: FileList.new([], workdir: workdir),
      logger: nil,
      system_saver:)
  end

  describe '#build_for (a job gets its own agent)' do
    it 'attaches a built harness to the job and wires the job id onto its save' do
      registry = registry_with(:main)
      job      = registry.jobs.first
      harness  = factory(registry: registry).build_for(job, session_id: SESSION_ID)

      expect(job.harness).to be(harness)
      expect(harness.session_manager.job_id).to eq(job.id)
      # The Harness reached the job, not a CLI-held reference (#286).
      expect(registry.foreground_job.harness).to be(harness)
    end

    it 'refuses to build a second harness for a job that already has one' do
      registry = registry_with(:main)
      job      = registry.jobs.first
      factory(registry: registry).build_for(job, session_id: SESSION_ID)

      expect do
        factory(registry: registry).build_for(job, session_id: SESSION_ID)
      end.to raise_error(HarnessError, /job 0 already has a harness/)
    end

    it 'refuses to attach to no job at all' do
      expect { factory(registry: registry_with(:main)).build_for(nil, session_id: SESSION_ID) }
        .to raise_error(HarnessError, /no job to attach a harness to/)
    end

    # A second harness job is the point of this class: a non-main kind gets an
    # agent, and its own job id keeps its conversation in its OWN job dir.
    it 'gives a non-main job its own agent, wired to its own job id' do
      registry = registry_with(:main, :sub_agent)
      child    = registry.job(1)

      harness = factory(registry: registry).build_for(child, session_id: SESSION_ID)

      expect(child.kind).to eq(:sub_agent)
      expect(child.harness).to be(harness)
      expect(harness.session_manager.job_id).to eq(1)
      expect(registry.job(0).harness).to be_nil
    end
  end

  # The run's owner adds a job AND its agent in one call, and the call is the
  # SAME for the main turn and for a second agent - only `kind` differs.
  describe '#add_harness_job (a job and its agent in one step)' do
    it 'adds the job to the registry and gives it its own harness' do
      registry = JobRegistry.new
      job      = factory(registry: registry)
                   .add_harness_job(kind: :main, session_id: SESSION_ID)

      expect(registry.jobs.map(&:id)).to eq([job.id])
      expect(registry.foreground).to eq(job.id)
      expect(job.kind).to eq(:main)
      expect(job.harness).to be_a(Harness)
      expect(job.harness.session_manager.job_id).to eq(job.id)
    end

    it 'adds a second harness job of its own kind under the SAME session id' do
      registry = JobRegistry.new
      build    = factory(registry: registry)
      main     = build.add_harness_job(kind: :main, session_id: SESSION_ID)
      child    = build.add_harness_job(kind: :sub_agent, session_id: SESSION_ID)

      expect(registry.jobs.map(&:id)).to eq([main.id, child.id])
      expect(child.id).to eq(1)
      expect(child.kind).to eq(:sub_agent)
      expect(child.harness).to be_a(Harness)
      expect(child.harness).not_to be(main.harness)
      expect(child.harness.session_manager.job_id).to eq(1)
      # One uuid for the run: both agents address the same system session dir.
      expect(child.harness.session.session_id).to eq(main.harness.session.session_id)
      # Adding a job does not switch the foreground.
      expect(registry.foreground).to eq(main.id)
    end

    # A job's agent sees the run's real working directory: a sub-agent works IN
    # the project, and its own saved dir is reached through the locator + job id
    # (SessionManager#write_own_job_session), not by being rooted there.
    it 'builds a job harness over the run workdir, not over a saved dir' do
      registry = JobRegistry.new
      build    = factory(registry: registry)
      main     = build.add_harness_job(kind: :main, session_id: SESSION_ID)
      child    = build.add_harness_job(kind: :sub_agent, session_id: SESSION_ID)

      expect(main.harness.file_list.workdir).to eq(workdir)
      expect(child.harness.file_list.workdir).to eq(workdir)
      expect(child.harness.session_manager.job_id).to eq(1)
      # The two agents share one session dir but write into different job dirs.
      expect(child.harness.session.session_id).to eq(main.harness.session.session_id)
    end

    it 'hands the job its own resume data, never the system record' do
      registry = JobRegistry.new
      resume   = { created_at: Time.now.iso8601,
                   messages: [{ role: 'user', content: 'job chain' }] }
      job      = factory(registry: registry)
                   .add_harness_job(kind: :sub_agent, session_id: SESSION_ID,
                                    resume_data: resume)

      expect(job.harness.session.messages.map { |m| m[:content] })
        .to include('job chain')
    end
  end

  describe 'the system writer a job delegates to' do
    it 'hands the system saver to the job harness it builds' do
      registry = registry_with(:main)
      saver    = SystemSaver.new(SessionLocator.new(workdir), registry)
      harness  = factory(registry: registry, system_saver: saver)
                   .build_for(registry.jobs.first, session_id: SESSION_ID)

      expect(harness.session_manager.system_saver).to be(saver)
    end
  end

  # The one writer every job delegates its system half to. Built over the run's
  # registry so a job harness cannot write a one-job system.json: with no
  # registry the record falls back to a degenerate single job, and a resume of a
  # multi-job run would rebuild only job 0.
  describe 'the run system saver the factory builds' do
    it 'builds one over the run registry when the caller passed none' do
      registry  = JobRegistry.new
      build     = factory(registry: registry)
      main      = build.add_harness_job(kind: :main, session_id: SESSION_ID)
      child     = build.add_harness_job(kind: :sub_agent, session_id: SESSION_ID)
      saver     = main.harness.session_manager.system_saver

      expect(saver).to be(child.harness.session_manager.system_saver)
      expect(saver.registry).to be(registry)
    end

    it 'uses the saver the caller passed instead of building a second one' do
      registry = registry_with(:main)
      saver    = SystemSaver.new(SessionLocator.new(workdir), registry)
      harness  = factory(registry: registry, system_saver: saver)
                   .build_for(registry.jobs.first, session_id: SESSION_ID)

      expect(harness.session_manager.system_saver).to be(saver)
    end
  end
end
