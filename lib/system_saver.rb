# frozen_string_literal: true

require_relative "system_record"

# Writes a whole layered system once - each job's conversation, system.json and
# each job's replay.json - from the registry the system's owner holds, so a
# per-job SessionManager never assembles a file it does not own. It is also the
# read side of the same layered record: a resume restores job state through it.
# Design: doc/session_layers_design.md.
class SystemSaver
  def initialize(locator, registry)
    @locator  = locator
    @record   = SystemRecord.new(registry)
    @registry = registry
  end

  attr_reader :registry

  def foreground_job
    @record.foreground_job
  end

  def write_system_files(id, session_h, harness)
    @record.write_system_files(@locator, id, session_h, harness)
  end

  # The saved conversations of the jobs the system's own resume_data does not
  # carry - every saved job except the foreground one (issue #548 increment 3).
  # The saved system id is passed in: this object is built before the CLI has
  # resolved one, and a resume reads the jobs of the session it resumed.
  def job_restores(saved_system_id)
    @locator.job_restores(saved_system_id)
  end

  # Re-attach each saved job's own status and shown tail to the job this run has
  # under that id. A saved id with no live Job (a job the drop rule removed, or
  # one nothing rebuilt) restores nothing and reports nil. Restoring a job to
  # :finished makes it a retention candidate again, as it was in the saved run.
  def restore_job_states(saved_system_id)
    job_restores(saved_system_id).filter_map do |restore|
      @registry&.restore_job(
        restore[:id],
        status: restore[:status],
        replay_tail: restore[:replay_tail])
    end
  end

  # Saved job ids with no live Job under them: dropped by the retention rule, or
  # not rebuilt by this resume. The edges naming them stay dangling.
  def dropped_job_ids(saved_system_id)
    job_restores(saved_system_id).map { |restore| restore[:id] }.reject do |job_id|
      @registry&.job(job_id)
    end
  end

  # The system half is written on every call, even when no job chain is
  # non-empty: the caller has already decided the run is worth saving (a
  # settings-only change has an empty chain but must still persist).
  def save_run(run_id)
    fg = @registry.foreground_job
    @registry.jobs.each do |job|
      harness = job.harness
      next if harness.nil? || harness.session.empty?
      next if !job.equal?(fg) && !job.finished?

      harness.session_manager.job_id = job.id
      harness.session_manager.save_job_session(run_id)
    end

    harness = fg&.harness
    return run_id if harness.nil?

    session_h = harness.session.to_h(harness.file_list)
    write_system_files(run_id, session_h, harness)
    run_id
  end
end
