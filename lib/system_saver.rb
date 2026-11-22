# frozen_string_literal: true

require "json"
require "fileutils"
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

  # Every job with a saved conversation dir: its own chain half, kind, status and
  # shown tail. The saved system id is passed in: this object is built before the
  # CLI has resolved one, and a resume reads the jobs of the session it resumed.
  def job_restores(saved_system_id)
    @locator.job_restores(saved_system_id)
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

  # Remove ONE job from a saved system (issue #558): unlink its index entry
  # from system.json, then remove its jobs/<id>/ dir. The order is the point
  # (doc/session_layers_design.md "The drop rule"): unlink the index entry
  # FIRST so a crash between the two leaves an orphan directory (recoverable)
  # rather than a dangling id that a resume tries to rebuild. Only a SYSTEM dir
  # is touched; a #207 flat session has no jobs index. A system with no saved
  # files yet (a job never saved) just drops from the live registry.
  def remove_job(saved_system_id, job_id)
    path = @locator.system_file_path(saved_system_id)
    if File.file?(path)
      system = JSON.parse(File.read(path), symbolize_names: true)
      system[:jobs] = Array(system[:jobs]).reject do |entry|
        (entry[:id] || entry["id"]) == job_id
      end
      File.write(path, JSON.generate(system))
    end

    FileUtils.rm_rf(@locator.job_dir_path(saved_system_id, job_id))
    registry&.remove_job(registry&.job(job_id))
    job_id
  end

  # The system half is written on every call, even when no job chain is
  # non-empty: the caller has already decided the run is worth saving (a
  # settings-only change has an empty chain but must still persist).
  def save_run(run_id)
    # A save is the SYSTEM's write: system.json plus every retained job's own
    # files, in ONE call by the run's owner. A SessionManager never assembles
    # this - system.json carries the SYSTEM's access list and digest cache, and
    # each job Harness has its own SessionFileCache.
    #
    # Every job with an agent is written, whatever its status: a job that ran a
    # turn and was never :done is still :pending, so gating on finished? left
    # background chains unwritten and the resume with nothing to rebuild (#548).
    # Marking such a job :finished so it would save is the wrong fix - Job#finish
    # delivers its result to a live requester. A job with an empty chain is still
    # written: its job.json and model state have to survive, and whether the run
    # is worth saving at all is JobRegistry#any_job_has_session_state?'s question.
    #
    # THREADING: reading a job's messages from the main thread is safe only when
    # no thread is mutating them, and a save point has none - the exit save runs
    # after every job thread is joined, and a mid-run save of a RUNNING job goes
    # through Job#request_save so that job writes its own jobs/<id>/session.json
    # on its own thread.
    @registry.jobs.each do |job|
      harness = job.harness
      next if harness.nil?

      harness.session_manager.job_id = job.id
      harness.session_manager.save_job_session(run_id)
    end

    # The system half describes the system through its foreground job: the
    # foreground carries the run's own FileList, so its to_h is where the system's
    # access list, digest cache and workdir come from.
    harness = @registry.foreground_job&.harness
    return run_id if harness.nil?

    write_system_files(run_id, harness.session.to_h(harness.file_list))
    run_id
  end
end
