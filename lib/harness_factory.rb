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
  # `session_id` is the SYSTEM id whose sessions/<id>/jobs/<job>/ tree this job's
  # files live under - a job is named by its directory, never by a second copy of
  # the run's UUID (doc/session_layers_design.md). `kind` is any Job::KINDS value;
  # the main turn and a new sub-agent differ only by it.
  # Returns the Job: the caller asked for a job, and the agent it got is
  # `job.harness` - the Job is the registry-side handle that stays useful.
  def add_harness_job(
    kind:,
    session_id:,
    dependencies: [],
    requested_by: nil,
    resume_data: nil
  )
    job = @registry.add_job(kind:, dependencies:, requested_by:)
    build_for(job, session_id:, resume_data:) && job
  end

  # Build this job's own Harness and attach it. `resume_data` is this job's OWN
  # saved half (its chain, active model, param overrides), never the system
  # record - a system record fed to a job Harness would restore one agent's
  # conversation into every job.
  def build_for(job, session_id:, resume_data: nil)
    raise HarnessError, "no job to attach a harness to" if job.nil?
    raise HarnessError, "job #{job.id} already has a harness" if job.harness

    harness = Harness.new(
      job_file_list,
      settings: @settings,
      session_id:,
      resume_data:,
      logger: @logger)
    attach(harness, job)
    harness
  end

  private

  # The job agent's own FileList, rooted at the run workdir. Harness keys the
  # log path, the image content dir and a resumed grant restore off its
  # workdir, and a run has ONE log for every job (one Logger object per path is
  # a measured requirement, doc/session_layers_design.md) - a deeper root would
  # fork that file per job.
  def job_file_list
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
