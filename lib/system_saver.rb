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

  # A standalone (single-job) save: assemble the one-job run this save IS and
  # write it in the same two steps save_run uses, so every save - interactive
  # or standalone - produces the same complete layered record. It mutates no
  # registry: a SessionManager built for a harness on its own has no run.
  def save_standalone(run_id, harness)
    session_h = harness.session.to_h(harness.file_list)
    harness.session_manager.job_id = 0
    harness.session_manager.save_job_session(run_id)
    SystemRecord.new(nil).write_system_files(@locator, run_id, session_h)
    run_id
  end

  def foreground_job
    @record.foreground_job
  end

  def write_system_files(id, session_h)
    @record.write_system_files(@locator, id, session_h)
  end

  # The saved conversations of the jobs the system's own resume_data does not
  # carry - every saved job except the foreground one (issue #548 increment 3).
  # The saved system id is passed in: this object is built before the CLI has
  # resolved one, and a resume reads the jobs of the session it resumed.
  def job_restores(saved_system_id)
    @locator.job_restores(saved_system_id)
  end

  # The FOREGROUND job's own saved conversation half (its chain + per-agent
  # model/param state), read straight from jobs/<id>/session.json. resume_data
  # no longer folds it in (#548); the system owner reads it here to rebuild the
  # foreground job as its own agent. {} when the job has no saved conversation
  # (its dir was dropped) so the caller falls back to a fresh main turn.
  # resume_data carries the SYSTEM half; the job file carries the CONVERSATION
  # half - disjoint keys composed here, not a locator-side foreground fold.
  def resume_main(saved_system_id, job_id, system_record)
    job_path = @locator.job_session_file_path(saved_system_id, job_id)
    return system_record unless File.file?(job_path)

    system_record.merge(@locator.read_job_session(saved_system_id, job_id))
  end

  # The saved shown tail of a job (its own replay.json), for the foreground
  # buffer a resumed run redraws. [] when the job has no replay.json.
  def replay_tail_of(saved_system_id, job_id)
    tail_path = @locator.job_replay_file_path(saved_system_id, job_id)
    return [] unless File.file?(tail_path)

    JSON.parse(File.read(tail_path), symbolize_names: true)
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
    # A save is the SYSTEM's write: system.json plus every retained job's own
    # files, in ONE call by the run's owner. A SessionManager never assembles
    # this - system.json carries the SYSTEM's access list and digest cache, and
    # each job Harness has its own SessionFileCache.
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
    write_system_files(run_id, session_h)
    run_id
  end
end
