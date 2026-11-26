# frozen_string_literal: true

require_relative "file_list"
require_relative "harness_error"
require_relative "harness"
require_relative "tool_manifest"
require_relative "session_locator"
require_relative "system_saver"

# Build harness
class HarnessFactory
  def initialize(registry:, locator:, settings:, file_list:, system_saver:, logger: nil)
    @registry     = registry
    @locator      = locator
    @settings     = settings
    @file_list    = file_list
    @system_saver = system_saver
    @logger       = logger
  end

  attr_reader :registry, :locator, :settings, :file_list, :system_saver, :logger

  def add_harness_job(
    kind:,
    dependencies: [],
    requested_by: nil,
    resume_data: nil,
    base_file_list: nil,
    id: nil
  )
    job = @registry.add_job(kind:, dependencies:, requested_by:, id:)
    build_for(job, resume_data:, base_file_list:) && job
  end

  def build_for(job, resume_data: nil, base_file_list: nil)
    raise HarnessError, "no job to attach a harness to" if job.nil?
    raise HarnessError, "job #{job.id} already has a harness" if job.harness

    harness = Harness.new(
      job_file_list(base_file_list),
      settings: @settings,
      locator: @locator,
      resume_data:,
      logger: @logger,
      manifest: manifest_for(job.kind))

    harness.model_config.active_profile_id ||= @settings.resolved_profile_id
    harness.model_config.active_profile_name ||= @settings.resolved_profile_name
    harness.model_config.model ||= @settings.active_profile&.model

    attach(harness, job)

    harness
  end

  private

  def manifest_for(kind)
    raise HarnessError, "no tool manifest for job kind #{kind}" \
      unless ToolManifest.manifests.key?(kind.to_sym)

    kind
  end

  def job_file_list(base_file_list = nil)
    return base_file_list if base_file_list

    FileList.new(
      [],
      workdir: @locator.workdir,
      protected_dirs: @settings.protected_dirs)
  end

  def attach(harness, job)
    manager             = harness.session_manager
    manager.job_id      = job.id
    job.attach_harness(harness)
  end
end
