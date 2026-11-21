# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'json'
require 'spec_helper'
require 'file_list'
require 'harness'
require 'harness_factory'
require 'job_registry'
require 'session_locator'
require 'session_logger'
require 'system_settings'

# HarnessFactory is the basis for MORE THAN ONE agent per run (issue #548): a Job
# is created empty and RECEIVES its Harness, and the per-agent wiring a job cannot
# invent for itself (which job dir its save writes under, which system writer it
# delegates to) is done in one place.
RSpec.describe HarnessFactory do
  let(:workdir) { Dir.mktmpdir('factory-spec') }
  after { FileUtils.remove_entry(workdir) if File.directory?(workdir) }

  before { allow_any_instance_of(SandboxGemfile).to receive(:lock_seeded?).and_return(true) }

  def settings
    SystemSettings.from_options(
      workdir: workdir, system_file: Harness::DEFAULT_SYSTEM_PROMPT_FILE)
  end

  def factory(system_saver: nil)
    file_list = FileList.new([], workdir: workdir)
    described_class.new(
      settings: settings,
      file_list: file_list,
      logger: nil,
      system_saver: system_saver)
  end

  def registry_with(*kinds)
    JobRegistry.new.tap do |registry|
      kinds.each { |kind| registry.add_job(kind:) }
    end
  end

  describe 'a job RECEIVES its harness (the basis for a second agent)' do
    it 'attaches a built harness to the job and wires the job id onto its save' do
      registry = registry_with(:main)
      job      = registry.jobs.first
      harness  = factory.build_for(job, session_id: 'aaaaaaaa-0000-0000-0000-000000000000')

      expect(job.harness).to be(harness)
      expect(harness.session_manager.job_id).to eq(job.id)
      # The Harness reached the job, not a CLI-held reference (#286).
      expect(registry.foreground_job.harness).to be(harness)
    end

    it 'refuses to build a second harness for a job that already has one' do
      job = registry_with(:main).jobs.first
      factory.build_for(job, session_id: 'bbbbbbbb-0000-0000-0000-000000000000')

      expect do
        factory.build_for(job, session_id: 'bbbbbbbb-0000-0000-0000-000000000000')
      end.to raise_error(HarnessError, /job 0 already has a harness/)
    end

    it 'refuses to attach to no job at all' do
      expect { factory.build_for(nil, session_id: 'cccccccc-0000-0000-0000-000000000000') }
        .to raise_error(HarnessError, /no job to attach a harness to/)
    end

    # A second harness job is the point of this class: a non-main kind gets an
    # agent, and its own session id keeps its conversation in its OWN job dir.
    it 'gives a non-main job its own agent, wired to its own job id' do
      registry = registry_with(:main, :sub_agent)
      child    = registry.job(1)

      harness = factory.build_for(child, session_id: 'dddddddd-0000-0000-0000-000000000000')

      expect(child.kind).to eq(:sub_agent)
      expect(child.harness).to be(harness)
      expect(harness.session_manager.job_id).to eq(1)
      expect(registry.job(0).harness).to be_nil
    end
  end

  describe 'the system writer a job delegates to' do
    it 'hands the system saver to the job harness it builds' do
      registry = registry_with(:main)
      saver    = SystemSaver.new(SessionLocator.new(workdir), registry)
      harness  = factory(system_saver: saver)
                   .build_for(registry.jobs.first,
                              session_id: 'eeeeeeee-0000-0000-0000-000000000000')

      expect(harness.session_manager.system_saver).to be(saver)
    end
  end
end
