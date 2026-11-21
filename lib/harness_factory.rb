# frozen_string_literal: true

require_relative "harness_error"
require_relative "harness"

# Builds the Harness that lives INSIDE one job (issue #548, the basis for more
# than one agent per run). A Harness is one LLM tool-loop and belongs to a Job
# (#286), so "give this job an agent" is one owner's business - the system's
# owner - not the CLI's, and not something a Harness can do for itself.
#
# Today the CLI builds exactly ONE Harness and hands it to job 0. Adding a second
# harness job (a command or sub-agent job) and restoring a saved system's jobs
# both need a job to be able to RECEIVE an agent, with the per-agent wiring done
# in one place: the job id its save writes under, and the system's own writer its
# SessionManager must be handed instead of reaching for.
# Design: doc/session_layers_design.md, doc/harness_job_design.md.
class HarnessFactory
  def initialize(settings:, file_list:, logger:, system_saver: nil)
    @settings     = settings
    @file_list    = file_list
    @logger       = logger
    @system_saver = system_saver
  end

  attr_reader :settings, :file_list, :system_saver

  # Build this job's own Harness and attach it.
  # `session_id` is the SYSTEM id the job's files live under: a job is named by
  # its directory and never by a second copy of the run's UUID
  # (doc/session_layers_design.md), and Harness#initialize raises when a
  # resume_data id disagrees with the id it is built under.
  # `resume_data` is this job's OWN saved half (its chain, active model, param
  # overrides), never the system record.
  def build_for(job, session_id:, resume_data: nil)
    raise HarnessError, "no job to attach a harness to" if job.nil?
    raise HarnessError, "job #{job.id} already has a harness" if job.harness

    harness = Harness.new(
      @file_list,
      settings: @settings,
      session_id:,
      resume_data:,
      logger: @logger)
    attach(harness, job)
    harness
  end

  private

  # The wiring one job's agent cannot invent for itself: which job dir its save
  # writes under, and the system's own writer it delegates the system half to.
  # Both land here so a second harness job is wired exactly like job 0 is.
  def attach(harness, job)
    manager        = harness.session_manager
    manager.job_id = job.id
    manager.system_saver = @system_saver if @system_saver
    job.attach_harness(harness)
  end
end
