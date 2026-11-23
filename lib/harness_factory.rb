# frozen_string_literal: true

require_relative "file_list"
require_relative "harness_error"
require_relative "harness"
require_relative "session_locator"
require_relative "system_saver"

# Builds the Harness that lives INSIDE one job (issue #548), and creates the job
# it lives in. A Harness is one LLM tool-loop and belongs to a Job (#286), so
# "give this job an agent" and "add another agent to this run" are one owner's
# business - the system's owner - not the CLI's, and not something a Harness can
# do for itself.
#
# Every harness a run has is created here, the main turn included: there is no
# special first agent. A second harness job is add_harness_job; the main turn is
# the same call with kind: :main. That is the whole point of the class - the path
# a new agent takes is the path the first one already took, so the first one
# cannot drift from it.
#
# WHY A FileList OF ITS OWN (not the run's): the agent's grants and its consent
# state must belong to that agent alone, so each job gets a fresh FileList over
# the run workdir rather than sharing the run's. Rooting it deeper (at the job's
# saved dir) nests every path derived from it - the log, the image dir - and a
# run has ONE log, so the root stays the run workdir and each job's own saved
# dir is reached through the locator plus its job id (SessionManager#save_job_session).
# Design: doc/session_layers_design.md, doc/harness_job_design.md.
class HarnessFactory
  def initialize(registry:, locator:, settings:, file_list:, system_saver:, logger: nil)
    @registry     = registry
    @locator      = locator
    @settings     = settings
    @file_list    = file_list
    @system_saver = system_saver
    @logger       = logger
  end

  attr_reader :registry, :locator, :settings, :file_list, :system_saver

  # Add a job to the run's registry AND give it its own agent, in one step.
  # A job is named by its directory under the locator's session id, never by a
  # second copy of the run's UUID (doc/session_layers_design.md). `kind` is any Job::KINDS value;
  # the main turn and a new sub-agent differ only by it.
  # Returns the Job: the caller asked for a job, and the agent it got is
  # `job.harness` - the Job is the registry-side handle that stays useful.
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

  # Build this job's own Harness and attach it. `resume_data` is this job's OWN
  # saved half (its chain, active model, param overrides), never the system
  # record - a system record fed to a job Harness would restore one agent's
  # conversation into every job.
  # Public so the run owner can give a job that already exists (a rebuilt saved
  # job) its agent, which is exactly what a layered resume has to do for every
  # saved job - not only for the foreground one.
  def build_for(job, resume_data: nil, base_file_list: nil)
    raise HarnessError, "no job to attach a harness to" if job.nil?
    raise HarnessError, "job #{job.id} already has a harness" if job.harness

    harness = Harness.new(
      job_file_list(base_file_list),
      settings: @settings,
      locator: @locator,
      resume_data:,
      logger: @logger)
    # A resumed job's model comes from its own saved half (Harness#apply_resume_state).
    # A job built fresh - a /jobs add - seeds from settings alone, where using the
    # config DEFAULT profile leaves the SELECTION nil: without this the job's own
    # profile id and the selection it then saves would both be nil, and a resume
    # could not look that profile up again.
    harness.model_config.active_profile_id ||= @settings.resolved_profile_id
    harness.model_config.active_profile_name ||= @settings.resolved_profile_name
    harness.model_config.model ||= @settings.active_profile&.model
    attach(harness, job)
    harness
  end

  private

  # The job agent's own FileList, rooted at the run workdir. Harness keys the
  # log path, the image content dir and a resumed grant restore off its
  # workdir, and a run has ONE log for every job (one Logger object per path is
  # a measured requirement, doc/session_layers_design.md) - a deeper root would
  # fork that file per job.
  # The initial (main) job reuses the run's OWN FileList: its access grants and
  # digest cache are system-wide state the CLI (and the commands) already hold on
  # that object, so the main turn must keep it. A SECOND agent gets a fresh list
  # rooted at the same run workdir (per-job isolation). Passing base_file_list:
  # to build_for marks a job as that initial one.
  def job_file_list(base_file_list = nil)
    return base_file_list if base_file_list

    FileList.new(
      [],
      workdir: @locator.workdir,
      protected_dirs: @settings.protected_dirs)
  end

  # The wiring one job's agent cannot invent for itself: which job dir its save
  # writes under. The system half is written once by the run owner over this
  # factory's @system_saver, so a job manager never holds a saver of its own.
  def attach(harness, job)
    manager             = harness.session_manager
    manager.job_id      = job.id
    job.attach_harness(harness)
  end
end
